/**
 * 数据导入导出服务（DataTransferService）— 容器编排层。
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §6。职责：
 * 1. 导出：按域从 `PersistenceHub` 读载荷 → 组装容器 → 计算校验和 → 可选加密；
 * 2. 导入：识别容器（明文/加密/旧存档）→ 逐域合并计划 → 用户确认后写盘；
 * 3. 安全：凭证域永不进入数据包；未加密导出由用户显式确认（加密默认开启）；
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
  SkippedDomain
} from './TransferTypes'
import { decryptBackup, encryptBackup, isEncryptedBackup } from './TransferCrypto'
import { mergePayload, MergeResult } from './DomainMergers'
import { draftUidPart, isValidDraftKey, rewriteDraftKeyUidPart } from '../utils/DraftKeyUtils'

const logger = new Logger(DOMAIN_STORE, 'DataTransferService')

/**
 * 文件域导出结果（载荷 + 损坏文件计数）。
 */
class FileDomainExport {
  /** 域载荷（数组）；目录为空/全部损坏时为 null。 */
  payload: Object | null = null
  /** 无法解析而被跳过的文件数。 */
  damaged: number = 0
  /** 读取失败的文件数。 */
  unreadable: number = 0
}

/**
 * 单域导出结果：要么产出条目，要么给出跳过原因。
 *
 * 用「结果对象」而不是 `BackupDomainEntry | null`，是为了把**跳过原因**带回给
 * `exportBackup`，由 UI 展示「勾选了但未包含」的域清单（审计 EXP-01）。
 */
class DomainEntryOutcome {
  /** 域条目（跳过时为 null）。 */
  entry: BackupDomainEntry | null = null
  /** 跳过原因（成功时为空串）。 */
  reason: string = ''
}

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
 * 可能打爆内存。导出与导入**共用同一上限**：
 * - 导出：超限域不写入容器，并记录到 `BackupExportResult.omitted` 由 UI 提示；
 * - 导入：超限域不再静默丢弃，而是记入 `ParseOutcome.droppedDomains` 并生成导入计划的跳过条目。
 */
const MAX_DOMAIN_PAYLOAD_CHARS: number = 8 * 1024 * 1024

/** 单域上限的 MB 值（用于用户可见文案，必须与 `MAX_DOMAIN_PAYLOAD_CHARS` 保持一致）。 */
const MAX_DOMAIN_PAYLOAD_MB: number = MAX_DOMAIN_PAYLOAD_CHARS / (1024 * 1024)

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
  /**
   * 非阻断警告（如 checksum 不匹配）：解析成功但内容可疑，调用方应提示用户后继续。
   */
  warning: string = ''
  /**
   * 解析阶段被丢弃的域（载荷超限 / 缺少内容 / 重复域 ID）。
   *
   * 这些域不会出现在 `container.domains` 中；调用方必须把它们传给
   * `buildImportPlan`，让导入计划显示「跳过 + 原因」，禁止静默丢弃（审计 IMP-01）。
   */
  droppedDomains: SkippedDomain[] = []
}

/**
 * 数据导入导出服务。
 */
export class DataTransferService {
  private hub: PersistenceHub | null = null
  private store: PreferencesStore | null = null
  private appVersionName: string = ''
  private appVersionCode: number = 0
  /** 当前登录 uid 提供者（账号镜像域导出归属校验用；未注入时视为未登录）。 */
  private uidProvider: () => string = (): string => ''

  /**
   * 注入依赖（AppStore.init 时调用）。
   *
   * @param hub - 持久化中心
   * @param store - 偏好存储（历史撤销快照清理用）
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
      const startedAt: number = Date.now()
      const container: BackupContainer = new BackupContainer()
      container.magic = BACKUP_MAGIC
      container.formatVersion = BACKUP_FORMAT_VERSION
      container.dataVersion = PERSISTENCE_DATA_VERSION
      container.exportedAt = startedAt
      container.appVersionName = this.appVersionName
      container.appVersionCode = this.appVersionCode
      container.deviceTag = 'phone'
      const omitted: SkippedDomain[] = []
      const specs: DomainSpec[] = PersistenceCatalog.all()
      for (let i: number = 0; i < specs.length; i++) {
        const spec: DomainSpec = specs[i]
        if (options.domainIds.indexOf(spec.id) < 0) {
          continue
        }
        if (spec.exportPolicy === ExportPolicy.NEVER) {
          // 用户勾选了 NEVER 域（正常 UI 不会出现）：明确记入未包含清单，不静默忽略
          omitted.push(new SkippedDomain(spec.id, '该数据域按设计不参与导出（凭证/媒体缓存）', spec.label))
          continue
        }
        const outcome: DomainEntryOutcome = await this.buildDomainEntry(spec)
        if (outcome.entry !== null) {
          container.domains.push(outcome.entry)
        } else {
          omitted.push(new SkippedDomain(spec.id, outcome.reason, spec.label))
        }
      }
      result.omitted = omitted
      if (container.domains.length === 0) {
        result.error = omitted.length > 0
          ? '所选数据没有可导出的内容（' + omitted.length + ' 个域均无数据，详见未包含清单）'
          : '所选数据均为空，没有可导出的内容'
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
      logger.info('export ok domains=%{public}d omitted=%{public}d bytes=%{public}d encrypted=%{public}s costMs=%{public}d',
        result.domainCount, omitted.length, bytes, String(result.encrypted), Date.now() - startedAt)
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
   * @returns 导出结果（条目或跳过原因）；无数据/读取失败/超限/归属不符时 entry 为 null
   */
  private async buildDomainEntry(spec: DomainSpec): Promise<DomainEntryOutcome> {
    const outcome: DomainEntryOutcome = new DomainEntryOutcome()
    if (this.hub === null) {
      outcome.reason = '存储未就绪'
      return outcome
    }
    const currentUid: string = this.uidProvider()
    let updatedAt: number = 0
    /*
     * 账号镜像域导出前校验归属：磁盘上的通知/动态/收藏关系缓存可能属于上一个登录账号
     * （切换账号后不删旧快照）。用户勾选导出时若把别人的账号状态写进备份文件，
     * 属于跨账号数据外带——归属不符直接跳过（并把原因带回 UI）。
     */
    if (spec.scope === DomainScope.ACCOUNT_MIRROR) {
      const envelope = await this.hub.readEnvelopeMeta(spec)
      const ownerUid: string = envelope === null ? '' : envelope.ownerUid
      if (ownerUid.length > 0 && ownerUid !== currentUid) {
        logger.info('skip exporting mirror domain owned by another account: %{public}s', spec.id)
        outcome.reason = '该缓存属于其他登录账号，已跳过（防跨账号数据外带）'
        return outcome
      }
      updatedAt = envelope === null ? 0 : envelope.updatedAt
    } else if (spec.storage === StorageKind.PREFERENCES && !spec.rawPayload) {
      // ENVELOPE 域的信封里有真实写入时间；RAW 域日常写入不经 Hub，没有逐域时间（恒 0）
      const envelope = await this.hub.readEnvelopeMeta(spec)
      updatedAt = envelope === null ? 0 : envelope.updatedAt
    }
    let payload: Object | null = null
    if (spec.storage === StorageKind.JSON_FILES) {
      const fileExport: FileDomainExport = this.exportFileDomain(spec)
      payload = fileExport.payload
      if (payload === null) {
        outcome.reason = fileExport.damaged + fileExport.unreadable > 0
          ? '目录内有 ' + String(fileExport.damaged + fileExport.unreadable) + ' 个文件损坏/不可读，且无有效数据'
          : '无数据'
        return outcome
      }
      updatedAt = this.hub.files.latestMtimeMs(spec)
    } else {
      payload = await this.hub.readPayload(spec)
      if (payload === null || payload === undefined) {
        outcome.reason = '无数据或读取失败（磁盘数据可能损坏）'
        return outcome
      }
    }
    let payloadSize: number = 0
    try {
      payloadSize = JSON.stringify(payload).length
    } catch (e) {
      outcome.reason = '数据无法序列化'
      return outcome
    }
    if (payloadSize > MAX_DOMAIN_PAYLOAD_CHARS) {
      outcome.reason = '单域数据超过 ' + String(MAX_DOMAIN_PAYLOAD_MB)
        + 'MB 上限，未包含在备份中（请精简该域内容后分批导出）'
      return outcome
    }
    const entry: BackupDomainEntry = new BackupDomainEntry()
    entry.id = spec.id
    entry.label = spec.label
    entry.schemaVersion = spec.schemaVersion
    entry.updatedAt = updatedAt
    // 镜像域记录来源账号：导入到其他账号时据此跳过，避免把 A 的缓存标成 B 的（审计 DES-04）
    entry.ownerUid = spec.scope === DomainScope.ACCOUNT_MIRROR ? currentUid : ''
    entry.payload = payload
    outcome.entry = entry
    return outcome
  }

  /**
   * 导出文件域：把目录下全部 JSON 文件读成数组载荷。
   *
   * @param spec - 文件域元数据
   * @returns 载荷与损坏/不可读文件计数（目录为空或无有效文件时 payload 为 null）
   */
  private exportFileDomain(spec: DomainSpec): FileDomainExport {
    const result: FileDomainExport = new FileDomainExport()
    if (this.hub === null) {
      return result
    }
    const names: string[] = this.hub.files.listFiles(spec)
    const items: Object[] = []
    for (let i: number = 0; i < names.length; i++) {
      if (!names[i].endsWith('.json')) {
        continue
      }
      const raw: string | null = this.hub.files.readFile(spec, names[i])
      if (raw === null) {
        result.unreadable++
        continue
      }
      try {
        const parsed: Object = JSON.parse(raw)
        if (parsed !== null && parsed !== undefined) {
          items.push(parsed)
        }
      } catch (e) {
        result.damaged++
        logger.warn('跳过无法解析的域文件 domain=%{public}s name=%{public}s', spec.id, names[i])
      }
    }
    result.payload = items.length > 0 ? items : null
    return result
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
    /*
     * 诊断日志：真机导入失败时可用 `hdc hilog | grep DataTransferService` 定位阶段
     * （字符数/加密标志/是否旧存档/结构识别/checksum）。不打印任何业务内容。
     */
    logger.info('parseBackup: chars=%{public}d encrypted=%{public}s hasPassword=%{public}s',
      content.length, String(isEncryptedBackup(content)), String(password.length > 0))
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
      /*
       * 尾部截断的文件仍可能包含大量完整数据域（导出写入未写完时，前面已写入的域是完整的）。
       * 先尝试文本级修复：截取到最后一个完整的域对象、补齐容器尾部，再按正常流程导入。
       * 修复成功时给用户明确警告（并跳过 checksum）。
       */
      const repaired: string | null = repairTruncatedContainer(plaintext)
      if (repaired !== null) {
        try {
          const repairedParsed: Object = JSON.parse(repaired) as Object
          const repairedOutcome: ParseOutcome = new ParseOutcome()
          const repairedContainer: BackupContainer | null =
            normalizeContainer(repairedParsed, repairedOutcome)
          if (repairedContainer !== null) {
            logger.warn('parseBackup repaired truncated container: domains=%{public}d',
              repairedContainer.domains.length)
            repairedContainer.checksum = ''
            outcome.ok = true
            outcome.container = repairedContainer
            // 修复后的容器也可能有被丢弃的域：一并带到计划里展示
            outcome.droppedDomains = repairedOutcome.droppedDomains
            outcome.warning = '备份文件尾部不完整（可能导出未写完），已恢复其中 '
              + String(repairedContainer.domains.length) + ' 个完整数据域；建议恢复后重新导出'
            return outcome
          }
        } catch (e2) {
          // 修复失败：继续走原错误提示
        }
      }
      /*
       * 诊断：JSON.parse 的错误信息带出错位置（V8 语义），配合头部/尾部片段可判断
       * "文件尾部截断"还是"结构被改"。前 48 / 后 48 字符只用于判断是否 NGA_OH_BACKUP 容器，
       * 不含业务内容（magic/formatVersion/checksum）。
       */
      const tail: string = plaintext.length > 48 && plaintext.length - 48 > 48 ?
        plaintext.substring(plaintext.length - 48) : plaintext
      logger.warn('parseBackup json fail: len=%{public}d err=%{public}s head=%{public}s tail=%{public}s',
        plaintext.length,
        e instanceof Error ? e.message : 'unknown',
        plaintext.substring(0, Math.min(48, plaintext.length)),
        tail)
      outcome.error = '文件不是有效的 JSON（可能导出未写完或文件已损坏，共 '
        + String(plaintext.length) + ' 字符）'
      return outcome
    }
    const container: BackupContainer | null = normalizeContainer(parsed, outcome)
    /*
     * ⚠️ 不能写成 `|| !outcome.ok`：`normalizeContainer` 成功时只返回容器、**不会**设置
     * `outcome.ok`（`ParseOutcome.ok` 默认 false），加上 `!outcome.ok` 会让**所有明文备份**
     * 都被误判为"容器非法"（错误信息为空 → UI 只显示"解析失败"）。
     * 真机实测踩坑：备份文件完整、读取成功，却每次都提示解析失败，根因就是这里。
     */
    if (container === null) {
      logger.warn('parseBackup container invalid: %{public}s', outcome.error)
      return outcome
    }
    // 校验和（旧文件可能没有 checksum，跳过并提示；有则比对，不匹配降级为警告）
    if (container.checksum.length > 0) {
      const actual: string = await sha256Hex(JSON.stringify(container.domains))
      if (actual !== container.checksum) {
        /*
         * **降级为警告，不阻断导入**：checksum 只用于检测手改/截断，而截断在 JSON.parse 阶段
         * 已会失败；不同 ArkTS 版本对对象键序/数字格式的序列化差异不应让用户数据无法恢复。
         * （真机导出→导入实测反馈：严格校验会把合法备份挡在门外。）
         */
        logger.warn('backup checksum mismatch: expected=%{public}s actual=%{public}s',
          container.checksum, actual)
        appendWarning(outcome, '文件校验和与内容不一致（可能跨版本导出或被编辑），已按文件内容继续导入')
      }
    } else {
      appendWarning(outcome, '备份缺少校验和（旧格式），已跳过完整性校验')
    }
    if (outcome.droppedDomains.length > 0) {
      appendWarning(outcome, '有 ' + String(outcome.droppedDomains.length)
        + ' 个数据域因载荷过大或结构非法被跳过（见导入计划）')
    }
    outcome.ok = true
    outcome.container = container
    return outcome
  }

  // ================= 导入：计划 =================

  /**
   * 构建导入计划（逐域合并、统计变更，供用户确认）。
   *
   * 默认恢复备份中的**全部**域（`restoreCacheDomains = true`）——备份里出现某个域，
   * 说明用户在导出时主动勾选了它，导入时就应当恢复（"跟随导出选择"）。
   * 调用方只在用户明确关闭「恢复缓存类数据」时传 false。
   *
   * **域对等性红线**：备份里出现的每个域（以及解析阶段被丢弃的域）都必须生成一条计划条目，
   * 要么给出合并结果，要么给出跳过原因；不允许静默丢弃。
   *
   * @param container - 已解析容器
   * @param restoreCacheDomains - 是否恢复缓存类域（默认 true）
   * @param droppedDomains - 解析阶段被丢弃的域（`ParseOutcome.droppedDomains`；默认空）
   * @returns 导入计划
   */
  async buildImportPlan(container: BackupContainer, restoreCacheDomains: boolean = true,
    droppedDomains: SkippedDomain[] = []): Promise<ImportPlan> {
    const plan: ImportPlan = new ImportPlan()
    plan.formatVersion = container.formatVersion
    plan.dataVersion = container.dataVersion
    plan.exportedAt = container.exportedAt
    plan.appVersionName = container.appVersionName
    // 解析阶段被丢弃的域：即使容器里没有，也必须在计划里可见（审计 IMP-01）
    for (let i: number = 0; i < droppedDomains.length; i++) {
      const dropped: SkippedDomain = droppedDomains[i]
      const droppedEntry: ImportPlanEntry = new ImportPlanEntry()
      droppedEntry.domainId = dropped.domainId
      droppedEntry.label = dropped.label.length > 0 ? dropped.label : dropped.domainId
      droppedEntry.willSkip = true
      droppedEntry.reason = dropped.reason.length > 0 ? dropped.reason : '该数据域未通过解析校验'
      plan.entries.push(droppedEntry)
    }
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
    const currentUid: string = this.uidProvider()
    for (let i: number = 0; i < container.domains.length; i++) {
      const incoming: BackupDomainEntry = container.domains[i]
      const entry: ImportPlanEntry = new ImportPlanEntry()
      entry.domainId = incoming.id
      const spec: DomainSpec | null = PersistenceCatalog.byId(incoming.id)
      if (spec === null) {
        entry.label = incoming.label.length > 0 ? incoming.label : incoming.id
        entry.willSkip = true
        entry.reason = '未知数据域（可能来自更新的版本）'
        plan.entries.push(entry)
        continue
      }
      /*
       * 域名一律以 Catalog 为准，不信任备份里的 label：外部文件不可信，篡改 label 会把
       * 敏感域伪装成无害域（例如把 ai_sessions 显示成「主题」）诱导用户确认导入。
       */
      entry.label = spec.label
      entry.policy = spec.importPolicy
      if (spec.importPolicy === ImportPolicy.NEVER) {
        entry.willSkip = true
        entry.reason = '该数据域不允许导入'
        plan.entries.push(entry)
        continue
      }
      /*
       * 不可导出的媒体/缓存副本域（draft_media / moving_photo_cache）无论恢复开关如何都不导入：
       * 它们既不参与导出，出现在备份里只可能是构造/篡改包，强行写入只会产生"写盘成功但读不到"。
       */
      if (spec.exportPolicy === ExportPolicy.NEVER && spec.importPolicy === ImportPolicy.SKIP) {
        entry.willSkip = true
        entry.reason = '该数据域不参与导入（媒体/缓存副本不可移植）'
        plan.entries.push(entry)
        continue
      }
      /*
       * 账号镜像域（通知/动态/收藏关系）恢复时必须带当前账号归属；未登录（uid 为空）时写入的
       * ownerUid 为空，Store 读取会按归属校验判为非法——等于"导入成功但看不到数据"。
       * 因此未登录时直接跳过并说明，等登录后重新导入（或由服务端重建）。
       */
      if (spec.scope === DomainScope.ACCOUNT_MIRROR) {
        if (currentUid.length === 0) {
          entry.willSkip = true
          entry.reason = '未登录：账号镜像缓存需按账号归属恢复，请登录后重新导入'
          plan.entries.push(entry)
          continue
        }
        /*
         * 跨账号串号防护（审计 DES-04）：备份条目携带导出时的来源账号。来源账号存在且与当前
         * 账号不同时跳过——否则 A 的通知/动态会被标记成 B 的缓存直接展示（隐私串号）。
         * 旧版备份没有该字段（空串）时按「归属未知」宽容恢复，并在计划行给出说明。
         */
        if (incoming.ownerUid.length > 0 && incoming.ownerUid !== currentUid) {
          entry.willSkip = true
          entry.reason = '该缓存来自其他登录账号的备份，已跳过（可由服务端重建）'
          plan.entries.push(entry)
          continue
        }
        if (incoming.ownerUid.length === 0) {
          entry.reason = '来源账号未知（旧版备份），将按当前账号恢复'
        }
      }
      /*
       * 草稿键末尾是账号哈希：未登录时改写成 `anon` 后，登录后编辑器按当前 uid 哈希查找
       * 永远读不到（"导入成功但草稿消失"）。与镜像域同理，未登录时显式跳过并说明。
       */
      if (spec.id === DomainIds.DRAFTS && currentUid.length === 0) {
        entry.willSkip = true
        entry.reason = '未登录：草稿需要当前账号标识，请登录后重新导入'
        plan.entries.push(entry)
        continue
      }
      if (spec.importPolicy === ImportPolicy.SKIP && !restoreCacheDomains) {
        /*
         * 缓存类域默认跳过（它们可从服务端重建，覆盖本机缓存有风险）。
         * 但用户既然在导出时选择了它们，就必须给出"恢复"的入口——由 import 计划页的
         * 「恢复缓存类数据」开关把 restoreCacheDomains 传成 true，走下面的覆盖恢复分支。
         */
        entry.willSkip = true
        entry.reason = '缓存类数据，默认跳过（可开启「恢复缓存类数据」）'
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
        const incomingPayload: Object = spec.id === DomainIds.SETTINGS
          ? restoreLocalSecrets(local, incoming.payload)
          : incoming.payload
        const merged: MergeResult = mergePayload(spec.id, local, incomingPayload)
        entry.mergedPayload = merged.merged
        entry.added = merged.added
        entry.updated = merged.updated
        entry.total = merged.added + merged.updated
        entry.willSkip = false
        if (spec.importPolicy === ImportPolicy.SKIP) {
          /*
           * 缓存域走 mergePayload 的透传分支（整体覆盖），不会产生 added/updated；
           * 这里用备份内的条目数展示，让用户明确"恢复了多少条"。
           */
          entry.added = countPayloadEntries(merged.merged)
          entry.updated = 0
          entry.total = entry.added
        }
        plan.entries.push(entry)
      } catch (e) {
        entry.willSkip = true
        entry.reason = '合并失败：' + (e instanceof Error ? e.message : '未知错误')
        plan.entries.push(entry)
      }
    }
    plan.ok = plan.changedDomainCount() > 0
    if (!plan.ok && plan.error.length === 0) {
      plan.error = '备份文件没有可导入的新数据（所有数据域均已跳过或无变化，原因见列表）'
    }
    return plan
  }

  // ================= 导入：应用 =================

  /**
   * 应用导入计划（写盘）。
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
    /*
     * 排空在途写队列再写导入数据：各 Store 的日常写入经 SerialQueue 延迟落盘，
     * 若队列里还有「导入前」的旧内存快照写入，它们可能在导入写盘之后执行，反向覆盖
     * 刚导入的数据（导入写盘不经队列）。此竞态窗口极短但后果是数据静默丢失。
     */
    await this.hub.flush()
    let failed: string = ''
    const failedDomains: string[] = []
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
      /*
       * 合并结果与本机完全一致（added/updated 均为 0）：写盘只会刷新 mtime、增加 IO，
       * 且与计划页「无变化」的展示矛盾，直接跳过。缓存域的 added 是备份条目数（>0），
       * 不会被误跳过。
       */
      if (entry.added === 0 && entry.updated === 0) {
        result.skippedDomains++
        continue
      }
      try {
        if (spec.storage === StorageKind.JSON_FILES) {
          const fileResult: FileApplyResult = this.applyFileDomain(spec, entry.mergedPayload)
          if (fileResult.failed > 0) {
            // 文件域写入失败必须上报（此前静默跳过，用户会以为导入成功）
            throw new Error('文件写入失败 ' + String(fileResult.failed) + ' 个：' + spec.id)
          }
        } else {
          /*
           * 账号镜像域写入时必须带当前 uid 作为信封 ownerUid：否则恢复出来的镜像域
           * ownerUid 为空，CacheEnvelopeStore 的归属校验会把它判为非法（等于白恢复）。
           */
          const ownerUid: string = spec.scope === DomainScope.ACCOUNT_MIRROR ? this.uidProvider() : ''
          const ok: boolean = await this.hub.writePayload(spec, entry.mergedPayload, ownerUid, true)
          if (!ok) {
            throw new Error('写盘失败：' + spec.id)
          }
        }
        result.appliedDomains++;
        result.added += entry.added
        result.updated += entry.updated
      } catch (e) {
        failedDomains.push(spec.id)
        if (failed.length === 0) {
          failed = (e instanceof Error ? e.message : '未知错误')
        }
        logger.error('导入域失败 domain=%{public}s: %{public}s', spec.id, formatError(e))
      }
    }
    await this.hub.flush()
    result.ok = failed.length === 0
    result.error = failed
    result.failedDomains = failedDomains
    logger.info('import ok=%{public}s domains=%{public}d added=%{public}d updated=%{public}d failed=%{public}d',
      String(result.ok), result.appliedDomains, result.added, result.updated, failedDomains.length)
    return result
  }

  /**
   * 应用文件域导入（逐条覆盖写）。
   *
   * 写入前做与 Store 读取侧**同一规则**的条目校验（审计 IMP-02）：条目结构不合法的记录
   * 即使写盘成功，`SavedThreadStore.reload()` / `DraftStore.loadDraft()` 也会静默跳过，
   * 形成"导入成功但看不到"；这里直接计入失败，由导入结果上报。
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
      let key: string = spec.id === 'saved_threads' ? readString(record['tid']) : readString(record['key'])
      if (spec.id === 'drafts') {
        /*
         * 草稿键末尾是**导出账号**的 uid 短哈希（`draft_..._<uidPart>`）。导入到另一个账号时，
         * 编辑器用当前账号哈希构建键 → 找不到旧草稿（看起来"草稿丢失"）。
         * 导入时把末尾片段改写为当前账号哈希（未登录计划层已跳过草稿域），实现跨账号找回。
         */
        const currentUidPart: string = draftUidPart(this.uidProvider())
        const rewritten: string = rewriteDraftKeyUidPart(key, currentUidPart)
        if (rewritten !== key) {
          record['key'] = rewritten
          key = rewritten
        }
      }
      if (!isSafeDomainFileName(key) || !isValidFileDomainItem(spec.id, record)) {
        result.failed++
        continue
      }
      if (this.hub.files.writeFileAtomic(spec, key + '.json', JSON.stringify(record))) {
        result.written++
      } else {
        result.failed++
      }
    }
    return result
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
      return this.exportFileDomain(spec).payload
    }
    return await this.hub.readPayload(spec)
  }

  /**
   * 历史撤销快照键（仅用于清理旧版本残留）。
   *
   * 撤销导入功能已移除：新版本不再写入 `v2.<domain>.undo`，但旧版本可能留下明文快照，
   * 启动时与「清空本地数据」时统一删除（隐私残留清理）。
   *
   * ⚠️ 不能用 `spec.fullKey()`：文件域（drafts/saved_threads）的 `fullKey()` 返回空串，
   * 两个文件域会共用同一个 `.undo` 键，删除时无区别——清理场景下只求把所有残留键删干净，
   * 仍按域 ID 生成独立键以覆盖全部可能的历史键。
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
   * 清理全部历史撤销快照（旧版本残留；启动时与「清空本地数据」时调用）。
   *
   * @returns 删除的键数
   */
  async clearLegacyUndoSnapshots(): Promise<number> {
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
 * 统计载荷条目数（用于缓存域"覆盖恢复"的展示；透传合并不会产生 added/updated）。
 *
 * @param payload - 合并后载荷
 * @returns 条目数（数组长度 / 信封 items 长度 / 对象键数）
 */
function countPayloadEntries(payload: Object): number {
  if (payload === null || payload === undefined) {
    return 0
  }
  if (Array.isArray(payload)) {
    return (payload as Object[]).length
  }
  if (typeof payload === 'object') {
    const record: Record<string, Object> = payload as Record<string, Object>
    const items: Object | undefined = record['items']
    if (items !== undefined && items !== null && Array.isArray(items)) {
      return (items as Object[]).length
    }
    return Object.keys(record).length
  }
  return 1
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
      outcome.droppedDomains.push(new SkippedDomain('未知', '数据域条目不是有效对象'))
      continue
    }
    const entryRecord: Record<string, Object> = item as Record<string, Object>
    const id: string = readString(entryRecord['id'])
    if (id.length === 0 || id.length > 64) {
      outcome.droppedDomains.push(new SkippedDomain('未知', '数据域 ID 缺失或非法'))
      continue
    }
    // 重复域 ID：只保留首个，防"同一域两次应用导致统计/合并语义错乱"
    if (seenIds.has(id)) {
      outcome.droppedDomains.push(new SkippedDomain(id, '备份中存在重复的数据域（只保留首个）'))
      continue
    }
    const payload: Object | undefined = entryRecord['payload']
    if (payload === undefined || payload === null) {
      outcome.droppedDomains.push(new SkippedDomain(id, '数据域缺少内容'))
      continue
    }
    let payloadSize: number = 0
    try {
      payloadSize = JSON.stringify(payload).length
    } catch (e) {
      outcome.droppedDomains.push(new SkippedDomain(id, '数据域内容无法解析'))
      continue
    }
    // 单域载荷体积上限：导出与导入共用同一上限（导出超限域不写入，导入超限域计入计划跳过）
    if (payloadSize > MAX_DOMAIN_PAYLOAD_CHARS) {
      outcome.droppedDomains.push(new SkippedDomain(id,
        '单域数据超过 ' + String(MAX_DOMAIN_PAYLOAD_MB) + 'MB 上限，已跳过（可在备份端精简后重试）'))
      continue
    }
    seenIds.add(id)
    const entry: BackupDomainEntry = new BackupDomainEntry()
    entry.id = id
    entry.label = readString(entryRecord['label'])
    entry.schemaVersion = readNumber(entryRecord['schemaVersion'], 0)
    entry.updatedAt = readNumber(entryRecord['updatedAt'], 0)
    entry.ownerUid = readString(entryRecord['ownerUid'])
    entry.payload = payload
    container.domains.push(entry)
  }
  if (container.domains.length === 0) {
    if (outcome.droppedDomains.length > 0) {
      // 全部域都被解析阶段丢弃：把首个原因带进错误文案，UI 不再只有笼统的"解析失败"
      outcome.error = '备份中的数据域均无法导入：' + outcome.droppedDomains[0].reason
    } else {
      outcome.error = '数据域列表为空或全部无效'
    }
    return null
  }
  return container
}

/**
 * 尝试修复"尾部被截断"的明文备份容器。
 *
 * 导出写入未写完时，文件尾部缺失（可能缺少 `]}` 或 checksum 字段），但**前面已写入的域对象
 * 是完整 JSON**。本函数从 `"domains":[` 开始做括号级扫描，取到最后一个完整域对象结束位置，
 * 重建容器文本（`checksum` 置空以跳过校验）。无法修复时返回 null（调用方按原错误提示）。
 *
 * 只处理**合法头部 + 尾部截断**，不做任意内容猜测：头部必须是 `{"magic":"NGA_OH_BACKUP"`。
 *
 * @param text - 原始明文文本
 * @returns 修复后的容器文本；无法修复返回 null
 */
function repairTruncatedContainer(text: string): string | null {
  if (!text.startsWith('{"magic":"NGA_OH_BACKUP"')) {
    return null
  }
  const domainsKey: string = '"domains":'
  const keyIndex: number = text.indexOf(domainsKey)
  if (keyIndex < 0) {
    return null
  }
  let cursor: number = keyIndex + domainsKey.length
  while (cursor < text.length) {
    const c: string = text.charAt(cursor)
    if (c !== ' ' && c !== '\n' && c !== '\r' && c !== '\t') {
      break
    }
    cursor++
  }
  if (cursor >= text.length || text.charAt(cursor) !== '[') {
    return null
  }
  const arrayStart: number = cursor
  let depth: number = 0
  let inString: boolean = false
  let escaped: boolean = false
  let lastCompleteEnd: number = -1
  let arrayClosedEnd: number = -1
  let sawObject: boolean = false
  for (let i: number = arrayStart + 1; i < text.length; i++) {
    const c: string = text.charAt(i)
    if (inString) {
      if (escaped) {
        escaped = false
      } else if (c === '\\') {
        escaped = true
      } else if (c === '"') {
        inString = false
      }
      continue
    }
    if (c === '"') {
      inString = true
      continue
    }
    if (c === '{' || c === '[') {
      depth++
      continue
    }
    if (c === '}') {
      depth--
      if (depth === 0) {
        lastCompleteEnd = i + 1
        sawObject = true
      }
      continue
    }
    if (c === ']') {
      if (depth === 0) {
        // domains 数组完整闭合，但容器尾部（checksum/}）缺失：记录位置并重建
        arrayClosedEnd = i
        break
      }
      depth--
    }
  }
  let domainsEnd: number = arrayClosedEnd
  if (domainsEnd < 0) {
    if (!sawObject || lastCompleteEnd < 0) {
      return null
    }
    domainsEnd = lastCompleteEnd
  }
  const domainsJson: string = text.substring(arrayStart + 1, domainsEnd).trim()
  if (domainsJson.length === 0) {
    return null
  }
  const head: string = text.substring(0, arrayStart)
  return head + '[' + domainsJson + '],"checksum":""}'
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
 * 校验文件域条目是否会被对应 Store 正常读取（与 Store 读取侧**同一规则**）。
 *
 * 背景（审计 IMP-02）：`applyFileDomain` 之前只校验"是对象 + 文件名安全"，条目字段不合法时
 * 仍会写盘成功，但 `SavedThreadStore.reload()`（要求纯数字 tid + 非空 rawPages）与
 * `DraftStore.loadDraft()`（要求合法草稿键）会静默跳过这些文件——"导入成功但看不到"。
 * 这里在写入前拦截，由导入结果把失败数上报给用户。
 *
 * @param domainId - 域 ID
 * @param item - 条目对象（drafts 的 key 已按当前账号改写）
 * @returns 是否可被 Store 读取
 */
export function isValidFileDomainItem(domainId: string, item: Object): boolean {
  const record: Record<string, Object> | null = asRecord(item)
  if (record === null) {
    return false
  }
  if (domainId === 'saved_threads') {
    const tid: string = readString(record['tid'])
    if (!isNumericTid(tid)) {
      return false
    }
    const rawPages: Object | undefined = record['rawPages']
    return rawPages !== undefined && rawPages !== null && Array.isArray(rawPages) &&
      (rawPages as Object[]).length > 0
  }
  if (domainId === 'drafts') {
    return isValidDraftKey(readString(record['key']))
  }
  // 其它文件域（draft_media/moving_photo_cache 正常不会出现在备份里）：只要求对象
  return true
}

/**
 * 校验 NGA 主题 ID（纯数字，1~16 位；与 `SavedThreadStore.isValidTid` 同规则）。
 *
 * @param tid - 主题 ID
 * @returns 是否合法
 */
function isNumericTid(tid: string): boolean {
  if (tid.length === 0 || tid.length > 16) {
    return false
  }
  for (let i: number = 0; i < tid.length; i++) {
    const c: string = tid.charAt(i)
    if (c < '0' || c > '9') {
      return false
    }
  }
  return true
}

/**
 * 追加一条非阻断警告（多条警告用「；」连接，不覆盖已有内容）。
 *
 * @param outcome - 解析结果
 * @param warning - 警告文案
 */
function appendWarning(outcome: ParseOutcome, warning: string): void {
  if (warning.length === 0) {
    return
  }
  outcome.warning = outcome.warning.length > 0 ? outcome.warning + '；' + warning : warning
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
 * 导入前还原本机 AI API Key（**兼容旧备份**）。
 *
 * 2026-10-30 前的版本导出时会把 `aiProfiles[].apiKey` / `.toolsApiKey` / `aiSearchProfiles[].apiKey`
 * 脱敏为空；现在的版本已原样导出（用户可对加密文件负责）。保留本函数用于兼容旧备份文件：
 * 规则是"导入条目该字段为空、且本机同 id 条目非空时，保留本机值"；导入条目自带密钥则不覆盖。
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
