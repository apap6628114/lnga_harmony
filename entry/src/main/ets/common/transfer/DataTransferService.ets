/**
 * 数据导入导出服务（DataTransferService）— 容器编排层。
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §6。职责：
 * 1. 导出：按域从 `PersistenceHub` 读载荷 → 组装容器 → 计算校验和 → 可选加密；
 * 2. 导入：识别容器（明文/加密/旧存档）→ 逐域合并计划 → 用户确认后写盘 → 可撤销；
 * 3. 脱敏：settings 域的 AI API Key 导出时剥离、导入时保留本机值（见 §6.6 安全清单）；
 * 4. 文件域（草稿/离线存档）逐文件转换为数组载荷，与 Preferences 域统一处理。
 *
 * 依赖约定：
 * - 合并语义在 `DomainMergers.mergePayload`（纯函数，可单测）；
 * - 加密在 `TransferCrypto`（AAD 与凭证链路隔离）；
 * - 域清单唯一真相是 `PersistenceCatalog`。
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'
import { PreferencesStore } from '../infra/PreferencesStore'
import { Logger, DOMAIN_STORE, formatError } from '../utils/Logger'
import { DomainIds, PersistenceCatalog } from '../persistence/PersistenceCatalog'
import { PersistenceHub } from '../persistence/PersistenceHub'
import {
  BACKUP_FORMAT_VERSION,
  BACKUP_MAGIC,
  BACKUP_MAX_FILE_BYTES,
  DomainScope,
  DomainSpec,
  ExportPolicy,
  IMPORT_UNDO_TTL_MS,
  ImportPolicy,
  PERSISTENCE_DATA_VERSION,
  PERSISTENCE_KEY_NAMESPACE,
  StorageKind
} from '../persistence/PersistenceTypes'
import {
  BackupContainer,
  BackupDomainEntry,
  BackupExportOptions,
  BackupExportResult,
  ImportPlan,
  ImportPlanEntry,
  ImportResult,
  UndoResult
} from './TransferTypes'
import { decryptBackup, encryptBackup, isEncryptedBackup } from './TransferCrypto'
import { mergePayload, MergeResult } from './DomainMergers'

const logger = new Logger(DOMAIN_STORE, 'DataTransferService')

/**
 * 文件域写入统计。
 */
class FileApplyResult {
  /** 成功写入的文件数。 */
  written: number = 0
  /** 写入失败/被跳过的文件数。 */
  failed: number = 0
}

/** 撤销快照键后缀（`v2.<domain>.undo`）。 */
const UNDO_KEY_SUFFIX: string = '.undo'

/** 凭证导出文件的 magic（识别后给出明确引导，不在数据导入里尝试解析）。 */
const CREDENTIAL_EXPORT_MAGIC: string = 'NGA_CREDENTIAL_EXPORT'

/**
 * 单域载荷字符数上限（约 8MB 字符）。
 *
 * 导入文件是外部不可信输入：单域超大载荷会在"解析 → 合并 → 序列化"链条里被反复复制，
 * 可能打爆内存。超过上限的域直接跳过（导入计划里显示跳过原因）。
 */
const MAX_DOMAIN_PAYLOAD_CHARS: number = 8 * 1024 * 1024

/** settings 域导出时脱敏的数组字段 → 需要清空的敏感字段名。 */
const SETTINGS_PROFILE_ARRAY_FIELDS: string[] = ['aiProfiles', 'aiSearchProfiles']
const SENSITIVE_KEY_FIELDS: string[] = ['apiKey', 'toolsApiKey']

/**
 * 容器解析结果。
 */
export class ParseOutcome {
  /** 是否解析成功。 */
  ok: boolean = false
  /** 是否需要口令（加密容器且未提供）。 */
  needPassword: boolean = false
  /** 明文容器。 */
  container: BackupContainer | null = null
  /** 错误信息。 */
  error: string = ''
}

/**
 * 数据导入导出服务。
 */
export class DataTransferService {
  private hub: PersistenceHub | null = null
  private store: PreferencesStore | null = null
  private appVersionName: string = ''
  private appVersionCode: number = 0
  /** 最近一次成功导入的时间（撤销窗口判定）。 */
  private lastImportAt: number = 0
  /** 撤销快照到期清理定时器（-1 = 无待执行）。 */
  private undoCleanupTimer: number = -1
  /** 当前登录 uid 提供者（账号镜像域导出归属校验用；未注入时视为未登录）。 */
  private uidProvider: () => string = (): string => ''

  /**
   * 注入依赖（AppStore.init 时调用）。
   *
   * @param hub - 持久化中心
   * @param store - 偏好存储（撤销快照旁路键）
   * @param appVersionName - 应用版本名
   * @param appVersionCode - 应用版本号
   * @param uidProvider - 当前登录 uid 提供者（可选；用于排除他人账号的镜像缓存导出）
   */
  init(
    hub: PersistenceHub,
    store: PreferencesStore,
    appVersionName: string,
    appVersionCode: number,
    uidProvider?: () => string
  ): void {
    this.hub = hub
    this.store = store
    this.appVersionName = appVersionName
    this.appVersionCode = appVersionCode
    if (uidProvider !== undefined) {
      this.uidProvider = uidProvider
    }
  }

  // ================= 导出 =================

  /**
   * 生成导出内容（明文或加密文本），由 UI 负责用 picker 保存到文件。
   *
   * @param options - 导出选项
   * @returns 导出结果
   */
  async exportBackup(options: BackupExportOptions): Promise<BackupExportResult> {
    const result: BackupExportResult = new BackupExportResult()
    if (this.hub === null) {
      result.error = '存储未就绪'
      return result
    }
    if (options.domainIds.length === 0) {
      result.error = '未选择任何数据'
      return result
    }
    if (options.encrypt && options.password.trim().length < 8) {
      result.error = '加密密码至少需要 8 位'
      return result
    }
    try {
      // 先把内存中的最新改动落盘，再读域载荷（避免导出落后于界面）
      await this.hub.flush()
      const container: BackupContainer = new BackupContainer()
      container.magic = BACKUP_MAGIC
      container.formatVersion = BACKUP_FORMAT_VERSION
      container.dataVersion = PERSISTENCE_DATA_VERSION
      container.exportedAt = Date.now()
      container.appVersionName = this.appVersionName
      container.appVersionCode = this.appVersionCode
      container.deviceTag = 'phone'
      const specs: DomainSpec[] = PersistenceCatalog.all()
      for (let i: number = 0; i < specs.length; i++) {
        const spec: DomainSpec = specs[i]
        if (options.domainIds.indexOf(spec.id) < 0) {
          continue
        }
        if (spec.exportPolicy === ExportPolicy.NEVER) {
          continue
        }
        const entry: BackupDomainEntry | null = await this.buildDomainEntry(spec)
        if (entry !== null) {
          container.domains.push(entry)
        }
      }
      if (container.domains.length === 0) {
        result.error = '所选数据均为空，没有可导出的内容'
        return result
      }
      container.checksum = await sha256Hex(JSON.stringify(container.domains))
      let content: string = JSON.stringify(container)
      if (options.encrypt) {
        content = await encryptBackup(content, options.password)
        result.encrypted = true
      }
      const bytes: number = utf8Bytes(content)
      if (bytes > BACKUP_MAX_FILE_BYTES) {
        result.error = '导出内容超过 64MB 上限，请减少勾选或先清理缓存'
        return result
      }
      result.ok = true
      result.content = content
      result.domainCount = container.domains.length
      result.bytes = bytes
      logger.info('export ok domains=%{public}d bytes=%{public}d encrypted=%{public}s',
        result.domainCount, bytes, String(result.encrypted))
      return result
    } catch (e) {
      logger.error('导出失败: %{public}s', formatError(e))
      result.error = e instanceof Error ? e.message : '导出失败'
      return result
    }
  }

  /**
   * 构建单个域的导出片段。
   *
   * @param spec - 域元数据
   * @returns 域片段；无数据或归属校验不通过返回 null
   */
  private async buildDomainEntry(spec: DomainSpec): Promise<BackupDomainEntry | null> {
    if (this.hub === null) {
      return null
    }
    /*
     * 账号镜像域导出前校验归属：磁盘上的通知/动态/收藏关系缓存可能属于上一个登录账号
     * （切换账号后不删旧快照）。用户勾选导出时若把别人的账号状态写进备份文件，
     * 属于跨账号数据外带——归属不符直接跳过。
     */
    if (spec.scope === DomainScope.ACCOUNT_MIRROR) {
      const envelope = await this.hub.readEnvelopeMeta(spec)
      const ownerUid: string = envelope === null ? '' : envelope.ownerUid
      const currentUid: string = this.uidProvider()
      if (ownerUid.length > 0 && ownerUid !== currentUid) {
        logger.info('skip exporting mirror domain owned by another account: %{public}s', spec.id)
        return null
      }
    }
    let payload: Object | null = null
    if (spec.storage === StorageKind.JSON_FILES) {
      payload = this.exportFileDomain(spec)
    } else {
      payload = await this.hub.readPayload(spec)
    }
    if (payload === null || payload === undefined) {
      return null
    }
    if (spec.id === 'settings') {
      payload = redactSettingsPayload(payload)
    }
    const entry: BackupDomainEntry = new BackupDomainEntry()
    entry.id = spec.id
    entry.label = spec.label
    entry.schemaVersion = spec.schemaVersion
    entry.updatedAt = this.hub.lastWriteTime(spec.id)
    entry.payload = payload
    return entry
  }

  /**
   * 导出文件域：把目录下全部 JSON 文件读成数组载荷。
   *
   * @param spec - 文件域元数据
   * @returns 载荷数组；目录为空返回 null
   */
  private exportFileDomain(spec: DomainSpec): Object | null {
    if (this.hub === null) {
      return null
    }
    const names: string[] = this.hub.files.listFiles(spec)
    const items: Object[] = []
    for (let i: number = 0; i < names.length; i++) {
      if (!names[i].endsWith('.json')) {
        continue
      }
      const raw: string | null = this.hub.files.readFile(spec, names[i])
      if (raw === null) {
        continue
      }
      try {
        const parsed: Object = JSON.parse(raw)
        if (parsed !== null && parsed !== undefined) {
          items.push(parsed)
        }
      } catch (e) {
        logger.warn('跳过无法解析的域文件 domain=%{public}s name=%{public}s', spec.id, names[i])
      }
    }
    return items.length > 0 ? items : null
  }

  // ================= 导入：解析 =================

  /**
   * 解析导入内容（自动识别加密容器 / 明文容器 / 旧版离线存档）。
   *
   * @param content - 文件文本
   * @param password - 口令（加密容器需要；非加密传空串）
   * @returns 解析结果
   */
  async parseBackup(content: string, password: string): Promise<ParseOutcome> {
    const outcome: ParseOutcome = new ParseOutcome()
    if (content.length === 0) {
      outcome.error = '文件为空'
      return outcome
    }
    if (utf8Bytes(content) > BACKUP_MAX_FILE_BYTES) {
      outcome.error = '文件超过 64MB 上限，已拒绝导入'
      return outcome
    }
    // 旧版离线存档兼容（无 magic，含 threads 数组）
    const legacy: BackupContainer | null = tryConvertLegacySavedThreadExport(content)
    if (legacy !== null) {
      outcome.ok = true
      outcome.container = legacy
      return outcome
    }
    let plaintext: string = content
    if (isEncryptedBackup(content)) {
      if (password.trim().length === 0) {
        outcome.needPassword = true
        outcome.error = '该文件已加密，请输入导出时设置的密码'
        return outcome
      }
      try {
        plaintext = await decryptBackup(content, password)
      } catch (e) {
        outcome.error = e instanceof Error ? e.message : '解密失败（密码错误或文件损坏）'
        return outcome
      }
    }
    let parsed: Object
    try {
      parsed = JSON.parse(plaintext) as Object
    } catch (e) {
      outcome.error = '文件不是有效的 JSON（可能已损坏）'
      return outcome
    }
    const container: BackupContainer | null = normalizeContainer(parsed, outcome)
    if (container === null || !outcome.ok) {
      return outcome
    }
    // 校验和（旧文件可能没有 checksum，跳过）
    if (container.checksum.length > 0) {
      const actual: string = await sha256Hex(JSON.stringify(container.domains))
      if (actual !== container.checksum) {
        outcome.ok = false
        outcome.container = null
        outcome.error = '文件校验和不匹配（内容可能被修改或损坏）'
        return outcome
      }
    }
    outcome.ok = true
    outcome.container = container
    return outcome
  }

  // ================= 导入：计划 =================

  /**
   * 构建导入计划（逐域合并、统计变更，供用户确认）。
   *
   * @param container - 已解析容器
   * @returns 导入计划
   */
  async buildImportPlan(container: BackupContainer): Promise<ImportPlan> {
    const plan: ImportPlan = new ImportPlan()
    plan.formatVersion = container.formatVersion
    plan.dataVersion = container.dataVersion
    plan.exportedAt = container.exportedAt
    plan.appVersionName = container.appVersionName
    if (container.formatVersion > BACKUP_FORMAT_VERSION) {
      plan.error = '备份文件来自更新的应用版本，请先升级应用'
      return plan
    }
    if (container.dataVersion > PERSISTENCE_DATA_VERSION) {
      plan.error = '备份文件的数据版本高于当前应用，无法导入'
      return plan
    }
    if (this.hub === null) {
      plan.error = '存储未就绪'
      return plan
    }
    for (let i: number = 0; i < container.domains.length; i++) {
      const incoming: BackupDomainEntry = container.domains[i]
      const entry: ImportPlanEntry = new ImportPlanEntry()
      entry.domainId = incoming.id
      entry.label = incoming.label.length > 0 ? incoming.label : incoming.id
      const spec: DomainSpec | null = PersistenceCatalog.byId(incoming.id)
      if (spec === null) {
        entry.willSkip = true
        entry.reason = '未知数据域（可能来自更新的版本）'
        plan.entries.push(entry)
        continue
      }
      entry.policy = spec.importPolicy
      if (spec.importPolicy === ImportPolicy.NEVER) {
        entry.willSkip = true
        entry.reason = '该数据域不允许导入'
        plan.entries.push(entry)
        continue
      }
      if (spec.importPolicy === ImportPolicy.SKIP) {
        entry.willSkip = true
        entry.reason = '缓存类数据，导入已跳过'
        plan.entries.push(entry)
        continue
      }
      if (incoming.schemaVersion > spec.schemaVersion) {
        entry.willSkip = true
        entry.reason = '数据格式版本高于当前应用，已跳过'
        plan.entries.push(entry)
        continue
      }
      try {
        const local: Object | null = await this.readDomainPayload(spec)
        entry.localPayload = local
        /*
         * settings 的 AI API Key 在导出时被脱敏为空（§6.6），导入前必须把本机同 id 配置的密钥
         * 还原回去，否则"导入设置后 AI 配置不可用"。还原只影响合并输入，不改变导入文件本身。
         */
        const incomingPayload: Object = spec.id === DomainIds.SETTINGS
          ? restoreLocalSecrets(local, incoming.payload)
          : incoming.payload
        const merged: MergeResult = mergePayload(spec.id, local, incomingPayload)
        entry.mergedPayload = merged.merged
        entry.added = merged.added
        entry.updated = merged.updated
        entry.total = merged.added + merged.updated
        entry.willSkip = false
        plan.entries.push(entry)
      } catch (e) {
        entry.willSkip = true
        entry.reason = '合并失败：' + (e instanceof Error ? e.message : '未知错误')
        plan.entries.push(entry)
      }
    }
    plan.ok = plan.changedDomainCount() > 0
    if (!plan.ok && plan.error.length === 0) {
      plan.error = '备份文件没有可导入的新数据'
    }
    return plan
  }

  // ================= 导入：应用 =================

  /**
   * 应用导入计划（写盘 + 撤销快照）。
   *
   * @param plan - 已确认的计划
   * @returns 执行结果
   */
  async applyImport(plan: ImportPlan): Promise<ImportResult> {
    const result: ImportResult = new ImportResult()
    if (this.hub === null) {
      result.error = '存储未就绪'
      return result
    }
    if (!plan.ok) {
      result.error = plan.error.length > 0 ? plan.error : '导入计划不可执行'
      return result
    }
    const undoAt: number = Date.now()
    let failed: string = ''
    for (let i: number = 0; i < plan.entries.length; i++) {
      const entry: ImportPlanEntry = plan.entries[i]
      if (entry.willSkip) {
        result.skippedDomains++;
        continue
      }
      const spec: DomainSpec | null = PersistenceCatalog.byId(entry.domainId)
      if (spec === null) {
        result.skippedDomains++;
        continue
      }
      try {
        // 撤销快照（本机导入前载荷）
        await this.writeUndoSnapshot(spec, entry.localPayload, undoAt)
        if (spec.storage === StorageKind.JSON_FILES) {
          const fileResult: FileApplyResult = this.applyFileDomain(spec, entry.mergedPayload)
          if (fileResult.failed > 0) {
            // 文件域写入失败必须上报（此前静默跳过，用户会以为导入成功）
            throw new Error('文件写入失败 ' + String(fileResult.failed) + ' 个：' + spec.id)
          }
        } else {
          const ok: boolean = await this.hub.writePayload(spec, entry.mergedPayload, '', true)
          if (!ok) {
            throw new Error('写盘失败：' + spec.id)
          }
        }
        result.appliedDomains++;
        result.added += entry.added
        result.updated += entry.updated
      } catch (e) {
        if (failed.length === 0) {
          failed = (e instanceof Error ? e.message : '未知错误')
        }
        logger.error('导入域失败 domain=%{public}s: %{public}s', spec.id, formatError(e))
      }
    }
    await this.hub.flush()
    this.lastImportAt = undoAt
    /* 撤销窗口到期后立即清理快照（否则明文隐私数据会驻留 Preferences 直到下次冷启动） */
    this.scheduleUndoCleanup()
    result.ok = failed.length === 0
    result.error = failed
    result.undoAvailable = result.appliedDomains > 0
    logger.info('import ok=%{public}s domains=%{public}d added=%{public}d updated=%{public}d',
      String(result.ok), result.appliedDomains, result.added, result.updated)
    return result
  }

  /**
   * 应用文件域导入（逐条覆盖写）。
   *
   * @param spec - 文件域元数据
   * @param payload - 数组载荷
   * @returns 写入统计（写入失败必须被调用方感知，不能静默当成功）
   */
  private applyFileDomain(spec: DomainSpec, payload: Object): FileApplyResult {
    const result: FileApplyResult = new FileApplyResult()
    if (this.hub === null) {
      result.failed++
      return result
    }
    if (payload === null || payload === undefined || !Array.isArray(payload)) {
      // 非数组载荷（如本机无数据时的空对象快照）视为 0 条，不算失败
      return result
    }
    const items: Object[] = payload as Object[]
    for (let i: number = 0; i < items.length; i++) {
      const item: Object = items[i]
      if (item === null || item === undefined || Array.isArray(item) || typeof item !== 'object') {
        result.failed++
        continue
      }
      const record: Record<string, Object> = item as Record<string, Object>
      const key: string = spec.id === 'saved_threads' ? readString(record['tid']) : readString(record['key'])
      if (!isSafeDomainFileName(key)) {
        result.failed++
        continue
      }
      if (this.hub.files.writeFileAtomic(spec, key + '.json', JSON.stringify(item))) {
        result.written++
      } else {
        result.failed++
      }
    }
    return result
  }

  /**
   * 写入撤销快照（`v2.<domain>.undo`）。
   *
   * @param spec - 域元数据
   * @param localPayload - 本机导入前载荷（null 表示原先无数据）
   * @param undoAt - 快照时间
   */
  private async writeUndoSnapshot(spec: DomainSpec, localPayload: Object | null, undoAt: number): Promise<void> {
    if (this.store === null) {
      return
    }
    const snapshot: Record<string, Object> = {}
    snapshot['undoAt'] = undoAt
    snapshot['payload'] = localPayload !== null ? localPayload : new Object()
    snapshot['hadData'] = localPayload !== null
    const key: string = this.undoKey(spec)
    await this.store.putString(key, JSON.stringify(snapshot), false)
  }

  /**
   * 撤销最近一次导入（10 分钟内有效）。
   *
   * @returns 撤销结果
   */
  async undoImport(): Promise<UndoResult> {
    const result: UndoResult = new UndoResult()
    if (this.hub === null || this.store === null) {
      result.error = '存储未就绪'
      return result
    }
    const now: number = Date.now()
    const specs: DomainSpec[] = PersistenceCatalog.all()
    let restored: number = 0
    for (let i: number = 0; i < specs.length; i++) {
      const spec: DomainSpec = specs[i]
      if (spec.importPolicy === ImportPolicy.NEVER || spec.importPolicy === ImportPolicy.SKIP) {
        continue
      }
      const key: string = this.undoKey(spec)
      const raw: string = await this.store.getString(key, '')
      if (raw.length === 0) {
        continue
      }
      try {
        const parsed: Object = JSON.parse(raw)
        const record: Record<string, Object> = parsed as Record<string, Object>
        const undoAt: number = readNumber(record['undoAt'], 0)
        if (now - undoAt > IMPORT_UNDO_TTL_MS) {
          // 过期快照：清理，不恢复
          await this.store.deleteKey(key, false)
          continue
        }
        const payload: Object | undefined = record['payload']
        const hadData: boolean = record['hadData'] === true
        if (payload !== undefined && payload !== null) {
          if (spec.storage === StorageKind.JSON_FILES) {
            /*
             * 文件域撤销：先清空目录再回写快照。导入可能新增了本机原本没有的文件，
             * 只做"覆盖写"会留下导入产物，撤销不彻底。
             */
            this.hub.files.clearDir(spec)
            this.applyFileDomain(spec, payload)
          } else {
            await this.hub.writePayload(spec, payload, '', true)
          }
          restored++;
        }
        if (!hadData) {
          // 导入前本机无数据：撤销等价于清空（文件域已在上面清空，这里兜底 Preferences 域）
          if (spec.storage !== StorageKind.JSON_FILES) {
            await this.hub.removeDomain(spec)
          }
        }
        await this.store.deleteKey(key, false)
      } catch (e) {
        logger.warn('撤销域失败 domain=%{public}s: %{public}s', spec.id, formatError(e))
      }
    }
    await this.store.flush()
    result.ok = true
    result.restoredDomains = restored
    if (restored === 0) {
      result.error = '没有可撤销的导入记录（已超过 10 分钟或未执行过导入）'
    }
    return result
  }

  /**
   * 是否存在可撤销快照（数据管理页按钮可见性）。
   *
   * @returns 是否存在
   */
  async hasUndoSnapshot(): Promise<boolean> {
    if (this.store === null) {
      return false
    }
    const now: number = Date.now()
    const specs: DomainSpec[] = PersistenceCatalog.all()
    for (let i: number = 0; i < specs.length; i++) {
      const raw: string = await this.store.getString(this.undoKey(specs[i]), '')
      if (raw.length === 0) {
        continue
      }
      try {
        const parsed: Object = JSON.parse(raw)
        const record: Record<string, Object> = parsed as Record<string, Object>
        const undoAt: number = readNumber(record['undoAt'], 0)
        if (now - undoAt <= IMPORT_UNDO_TTL_MS) {
          return true
        }
      } catch (e) {
        // 坏快照忽略
      }
    }
    return false
  }

  /**
   * 清理过期撤销快照（启动维护任务调用）。
   *
   * @returns 清理的键数
   */
  async cleanupExpiredUndo(): Promise<number> {
    if (this.store === null) {
      return 0
    }
    const now: number = Date.now()
    let removed: number = 0
    const specs: DomainSpec[] = PersistenceCatalog.all()
    for (let i: number = 0; i < specs.length; i++) {
      const key: string = this.undoKey(specs[i])
      const raw: string = await this.store.getString(key, '')
      if (raw.length === 0) {
        continue
      }
      try {
        const parsed: Object = JSON.parse(raw)
        const record: Record<string, Object> = parsed as Record<string, Object>
        const undoAt: number = readNumber(record['undoAt'], 0)
        // 超过撤销窗口（10 分钟）即失效并清理：快照含明文隐私数据，不应长期驻留
        if (now - undoAt > IMPORT_UNDO_TTL_MS) {
          if (await this.store.deleteKey(key, false)) {
            removed++;
          }
        }
      } catch (e) {
        if (await this.store.deleteKey(key, false)) {
          removed++;
        }
      }
    }
    if (removed > 0) {
      await this.store.flush()
    }
    return removed
  }

  /**
   * 读取域当前载荷（文件域返回数组）。
   *
   * @param spec - 域元数据
   * @returns 载荷；无数据返回 null
   */
  private async readDomainPayload(spec: DomainSpec): Promise<Object | null> {
    if (this.hub === null) {
      return null
    }
    if (spec.storage === StorageKind.JSON_FILES) {
      return this.exportFileDomain(spec)
    }
    return await this.hub.readPayload(spec)
  }

  /**
   * 撤销快照键。
   *
   * ⚠️ 不能用 `spec.fullKey()`：文件域（drafts/saved_threads）的 `fullKey()` 返回空串，
   * 两个文件域会共用同一个 `.undo` 键、互相覆盖——撤销时用错误域的快照恢复会**清空本机草稿**
   * （clearDir 后写 0 个文件）。文件域必须用域 ID 生成独立键。
   *
   * @param spec - 域元数据
   * @returns 键名
   */
  private undoKey(spec: DomainSpec): string {
    if (spec.storage === StorageKind.JSON_FILES) {
      return PERSISTENCE_KEY_NAMESPACE + spec.id + UNDO_KEY_SUFFIX
    }
    return spec.fullKey() + UNDO_KEY_SUFFIX
  }

  /**
   * 安排一次撤销快照到期清理（导入成功后调用；重复导入会重置定时器）。
   */
  private scheduleUndoCleanup(): void {
    if (this.undoCleanupTimer >= 0) {
      clearTimeout(this.undoCleanupTimer)
    }
    this.undoCleanupTimer = setTimeout((): void => {
      this.undoCleanupTimer = -1
      this.cleanupExpiredUndo().catch((): void => {})
    }, IMPORT_UNDO_TTL_MS + 60 * 1000)
  }

  /**
   * 清理全部撤销快照（「清空本地数据」时调用；快照含明文隐私内容，不能残留）。
   *
   * @returns 删除的键数
   */
  async clearAllUndoSnapshots(): Promise<number> {
    if (this.undoCleanupTimer >= 0) {
      clearTimeout(this.undoCleanupTimer)
      this.undoCleanupTimer = -1
    }
    if (this.store === null) {
      return 0
    }
    let removed: number = 0
    const specs: DomainSpec[] = PersistenceCatalog.all()
    for (let i: number = 0; i < specs.length; i++) {
      if (await this.store.deleteKey(this.undoKey(specs[i]), false)) {
        removed++
      }
    }
    if (removed > 0) {
      await this.store.flush()
    }
    return removed
  }
}

/**
 * 归一化容器结构（逐字段重建 + 版本校验 + 域条目过滤）。
 *
 * @param parsed - 已解析对象
 * @param outcome - 解析结果（写入错误信息）
 * @returns 容器；非法返回 null
 */
function normalizeContainer(parsed: Object, outcome: ParseOutcome): BackupContainer | null {
  if (parsed === null || parsed === undefined || Array.isArray(parsed) || typeof parsed !== 'object') {
    outcome.error = '文件内容不是有效的数据备份'
    return null
  }
  const record: Record<string, Object> = parsed as Record<string, Object>
  const magic: string = readString(record['magic'])
  if (magic === CREDENTIAL_EXPORT_MAGIC) {
    outcome.error = '这是账号加密凭证文件，请在「登录页 → 导入凭据文件」中使用'
    return null
  }
  if (magic !== BACKUP_MAGIC) {
    outcome.error = '文件不是 NGA 数据备份（magic 不匹配）'
    return null
  }
  const container: BackupContainer = new BackupContainer()
  container.magic = magic
  container.formatVersion = readNumber(record['formatVersion'], 0)
  container.dataVersion = readNumber(record['dataVersion'], 0)
  container.exportedAt = readNumber(record['exportedAt'], 0)
  container.appVersionName = readString(record['appVersionName'])
  container.appVersionCode = readNumber(record['appVersionCode'], 0)
  container.deviceTag = readString(record['deviceTag'])
  container.checksum = readString(record['checksum'])
  // 格式版本必须是正整数：负数/小数/0 都视为非法（防手工构造绕过版本上限判断）
  if (container.formatVersion < 1 || Math.floor(container.formatVersion) !== container.formatVersion) {
    outcome.error = '备份文件的格式版本非法'
    return null
  }
  if (container.dataVersion < 0 || Math.floor(container.dataVersion) !== container.dataVersion) {
    outcome.error = '备份文件的数据版本非法'
    return null
  }
  const rawDomains: Object | undefined = record['domains']
  if (rawDomains === undefined || rawDomains === null || !Array.isArray(rawDomains)) {
    outcome.error = '备份文件缺少数据域列表'
    return null
  }
  const domains: Object[] = rawDomains as Object[]
  if (domains.length === 0) {
    outcome.error = '备份文件中没有任何数据域'
    return null
  }
  if (domains.length > 64) {
    outcome.error = '数据域数量异常'
    return null
  }
  const seenIds: Set<string> = new Set<string>()
  for (let i: number = 0; i < domains.length; i++) {
    const item: Object = domains[i]
    if (item === null || item === undefined || Array.isArray(item) || typeof item !== 'object') {
      continue
    }
    const entryRecord: Record<string, Object> = item as Record<string, Object>
    const id: string = readString(entryRecord['id'])
    if (id.length === 0 || id.length > 64) {
      continue
    }
    // 重复域 ID：只保留首个，防"同一域两次应用导致统计/合并语义错乱"
    if (seenIds.has(id)) {
      continue
    }
    const payload: Object | undefined = entryRecord['payload']
    if (payload === undefined || payload === null) {
      continue
    }
    let payloadSize: number = 0
    try {
      payloadSize = JSON.stringify(payload).length
    } catch (e) {
      continue
    }
    // 单域载荷体积上限（Preferences 单值 16MB 的一半，防超大域在内存中反复序列化）
    if (payloadSize > MAX_DOMAIN_PAYLOAD_CHARS) {
      continue
    }
    seenIds.add(id)
    const entry: BackupDomainEntry = new BackupDomainEntry()
    entry.id = id
    entry.label = readString(entryRecord['label'])
    entry.schemaVersion = readNumber(entryRecord['schemaVersion'], 0)
    entry.updatedAt = readNumber(entryRecord['updatedAt'], 0)
    entry.payload = payload
    container.domains.push(entry)
  }
  if (container.domains.length === 0) {
    outcome.error = '数据域列表为空或全部无效'
    return null
  }
  return container
}

/**
 * 尝试把旧版离线存档导出文件（`SavedThreadExportFile`，无 magic）转换为容器。
 *
 * @param content - 文件文本
 * @returns 容器；不是旧存档返回 null
 */
function tryConvertLegacySavedThreadExport(content: string): BackupContainer | null {
  try {
    const parsed: Object = JSON.parse(content) as Object
    if (parsed === null || parsed === undefined || Array.isArray(parsed) || typeof parsed !== 'object') {
      return null
    }
    const record: Record<string, Object> = parsed as Record<string, Object>
    if (readString(record['magic']).length > 0) {
      return null
    }
    const threads: Object | undefined = record['threads']
    if (threads === undefined || threads === null || !Array.isArray(threads) ||
      (threads as Object[]).length === 0) {
      return null
    }
    const container: BackupContainer = new BackupContainer()
    container.magic = BACKUP_MAGIC
    container.formatVersion = BACKUP_FORMAT_VERSION
    container.dataVersion = PERSISTENCE_DATA_VERSION
    container.exportedAt = readNumber(record['exportedAt'], Date.now())
    container.appVersionName = 'legacy-saved-thread-export'
    container.deviceTag = 'phone'
    const entry: BackupDomainEntry = new BackupDomainEntry()
    entry.id = 'saved_threads'
    entry.label = '离线保存的帖子（旧版导出文件）'
    entry.schemaVersion = 1
    entry.updatedAt = container.exportedAt
    entry.payload = threads
    container.domains.push(entry)
    return container
  } catch (e) {
    return null
  }
}

/**
 * settings 导出脱敏：清空 AI 配置中的 API Key（文件可能被分享/明文保存）。
 *
 * 注意：只改导出副本，不动内存与磁盘上的真实配置。
 *
 * @param payload - settings 载荷
 * @returns 脱敏后的副本
 */
function redactSettingsPayload(payload: Object): Object {
  let copy: Object
  try {
    copy = JSON.parse(JSON.stringify(payload))
  } catch (e) {
    return payload
  }
  if (copy === null || copy === undefined || Array.isArray(copy) || typeof copy !== 'object') {
    return payload
  }
  const record: Record<string, Object> = copy as Record<string, Object>
  for (let i: number = 0; i < SETTINGS_PROFILE_ARRAY_FIELDS.length; i++) {
    const field: string = SETTINGS_PROFILE_ARRAY_FIELDS[i]
    const raw: Object | undefined = record[field]
    if (raw === undefined || raw === null || !Array.isArray(raw)) {
      continue
    }
    const items: Object[] = raw as Object[]
    for (let j: number = 0; j < items.length; j++) {
      const item: Object = items[j]
      if (item === null || item === undefined || Array.isArray(item) || typeof item !== 'object') {
        continue
      }
      const profile: Record<string, Object> = item as Record<string, Object>
      for (let k: number = 0; k < SENSITIVE_KEY_FIELDS.length; k++) {
        const keyField: string = SENSITIVE_KEY_FIELDS[k]
        if (profile[keyField] !== undefined) {
          profile[keyField] = ''
        }
      }
    }
  }
  return copy
}

/**
 * 校验文件域名（草稿键 / tid），防路径穿越。
 *
 * @param name - 业务键
 * @returns 是否安全
 */
function isSafeDomainFileName(name: string): boolean {
  if (name.length === 0 || name.length > 96) {
    return false
  }
  if (name.indexOf('/') >= 0 || name.indexOf('\\') >= 0 || name.indexOf('..') >= 0) {
    return false
  }
  return true
}

/**
 * 计算字符串的 SHA-256（`sha256:<hex>`）。
 *
 * @param text - 待摘要文本
 * @returns 摘要字符串
 */
async function sha256Hex(text: string): Promise<string> {
  const encoder: util.TextEncoder = util.TextEncoder.create()
  const bytes: Uint8Array = encoder.encodeInto(text)
  const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256')
  await md.update({ data: bytes })
  const digest: cryptoFramework.DataBlob = await md.digest()
  return 'sha256:' + bytesToHex(digest.data)
}

/**
 * 字节数组转小写十六进制。
 *
 * @param data - 字节数组
 * @returns 十六进制字符串
 */
function bytesToHex(data: Uint8Array): string {
  const hexChars: string = '0123456789abcdef'
  let result: string = ''
  for (let i: number = 0; i < data.length; i++) {
    const value: number = data[i]
    result += hexChars.charAt((value >> 4) & 0x0F)
    result += hexChars.charAt(value & 0x0F)
  }
  return result
}

/**
 * 估算 UTF-8 字节数（通过 TextEncoder 精确计算）。
 *
 * @param text - 文本
 * @returns 字节数
 */
function utf8Bytes(text: string): number {
  try {
    const encoder: util.TextEncoder = util.TextEncoder.create()
    return encoder.encodeInto(text).length
  } catch (e) {
    return text.length * 3
  }
}

/**
 * 防御性读取字符串。
 *
 * @param value - 原始值
 * @returns 字符串
 */
function readString(value: Object | undefined): string {
  return typeof value === 'string' ? value as string : ''
}

/**
 * 防御性读取数值。
 *
 * @param value - 原始值
 * @param fallback - 兜底值
 * @returns 有限数值
 */
function readNumber(value: Object | undefined, fallback: number): number {
  if (typeof value !== 'number' || !isFinite(value as number)) {
    return fallback
  }
  return value as number
}

/**
 * 判断对象是否为普通对象（非数组、非 null）。
 *
 * @param value - 待判断值
 * @returns 普通对象；否则 null
 */
function asRecord(value: Object | undefined | null): Record<string, Object> | null {
  if (value === undefined || value === null || Array.isArray(value) || typeof value !== 'object') {
    return null
  }
  return value as Record<string, Object>
}

/**
 * settings 导入前还原本机敏感字段（AI API Key）。
 *
 * 导出链路把 `aiProfiles[].apiKey` / `.toolsApiKey` / `aiSearchProfiles[].apiKey` 脱敏为空
 * （设计文档 §6.6）；导入时若照抄空值，会把本机可用的密钥清掉、AI 功能直接不可用。
 * 规则：**导入条目该字段为空、且本机同 id 条目非空时，保留本机值**；导入条目自带密钥则不覆盖。
 *
 * @param localPayload - 本机 settings 载荷（可能为 null）
 * @param incomingPayload - 导入的 settings 载荷
 * @returns 还原密钥后的导入副本（不修改入参）
 */
function restoreLocalSecrets(localPayload: Object | null, incomingPayload: Object): Object {
  const incomingRecord: Record<string, Object> | null = asRecord(incomingPayload)
  if (incomingRecord === null) {
    return incomingPayload
  }
  let copy: Record<string, Object>
  try {
    copy = JSON.parse(JSON.stringify(incomingRecord)) as Record<string, Object>
  } catch (e) {
    return incomingPayload
  }
  const localRecord: Record<string, Object> | null = asRecord(localPayload)
  restoreSecretFields(copy['aiProfiles'], localRecord === null ? undefined : localRecord['aiProfiles'])
  restoreSecretFields(copy['aiSearchProfiles'],
    localRecord === null ? undefined : localRecord['aiSearchProfiles'])
  return copy
}

/**
 * 对一组 profile 数组还原敏感字段（按 `id` 匹配本机条目）。
 *
 * @param incomingValue - 导入的 profile 数组
 * @param localValue - 本机的 profile 数组
 */
function restoreSecretFields(incomingValue: Object | undefined, localValue: Object | undefined): void {
  if (incomingValue === undefined || incomingValue === null || !Array.isArray(incomingValue)) {
    return
  }
  const localItems: Object[] = localValue !== undefined && localValue !== null && Array.isArray(localValue)
    ? localValue as Object[] : []
  const incomingItems: Object[] = incomingValue as Object[]
  for (let i: number = 0; i < incomingItems.length; i++) {
    const incomingProfile: Record<string, Object> | null = asRecord(incomingItems[i])
    if (incomingProfile === null) {
      continue
    }
    const id: string = readString(incomingProfile['id'])
    if (id.length === 0) {
      continue
    }
    let localProfile: Record<string, Object> | null = null
    for (let j: number = 0; j < localItems.length; j++) {
      const candidate: Record<string, Object> | null = asRecord(localItems[j])
      if (candidate !== null && readString(candidate['id']) === id) {
        localProfile = candidate
        break
      }
    }
    if (localProfile === null) {
      continue
    }
    /*
     * 端点一致性校验：只有"同一个服务端点"才允许把本机密钥回填给导入条目。
     * 否则恶意/误导入的 settings 包可以复用本机 id 但把 endpoint 指向第三方，
     * 导致本机真实 API Key 被发往该端点。
     */
    if (!isSameAiEndpoint(incomingProfile, localProfile)) {
      continue
    }
    restoreFieldIfEmpty(incomingProfile, localProfile, 'apiKey')
    restoreFieldIfEmpty(incomingProfile, localProfile, 'toolsApiKey')
  }
}

/**
 * 判断导入条目与本机条目的 AI 服务端点是否一致。
 *
 * 导入条目未声明端点（旧格式）时视为一致（由本机端点决定）；
 * 任一侧声明了端点且二者不同 → 不一致，拒绝回填密钥。
 *
 * @param incoming - 导入条目
 * @param local - 本机条目
 * @returns 端点是否一致
 */
function isSameAiEndpoint(incoming: Record<string, Object>, local: Record<string, Object>): boolean {
  const incomingEndpoint: string = readString(incoming['endpoint']).trim()
  const localEndpoint: string = readString(local['endpoint']).trim()
  if (incomingEndpoint.length > 0 && incomingEndpoint !== localEndpoint) {
    return false
  }
  const incomingTools: string = readString(incoming['toolsEndpoint']).trim()
  const localTools: string = readString(local['toolsEndpoint']).trim()
  if (incomingTools.length > 0 && incomingTools !== localTools) {
    return false
  }
  return true
}

/**
 * 导入字段为空时用本机值补齐。
 *
 * @param incoming - 导入条目
 * @param local - 本机条目
 * @param field - 字段名
 */
function restoreFieldIfEmpty(
  incoming: Record<string, Object>,
  local: Record<string, Object>,
  field: string
): void {
  const incomingValue: string = readString(incoming[field])
  if (incomingValue.length > 0) {
    return
  }
  const localValue: string = readString(local[field])
  if (localValue.length > 0) {
    incoming[field] = localValue
  }
}

/** 全局唯一数据导入导出服务。 */
export const dataTransferService: DataTransferService = new DataTransferService()
