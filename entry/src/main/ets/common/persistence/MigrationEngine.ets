/**
 * 迁移引擎（MigrationEngine）— 旧数据 → 新格式的编排器。
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §5。三条触发路径共用本引擎：
 * - P1 版本升级：启动时检测旧键（`LEGACY_RULES` 命中）；
 * - P2 系统备份恢复：恢复后的磁盘等价于旧版本数据目录，检测逻辑与 P1 相同；
 * - P3 用户导入：由 `DataTransferService` 调用各域升级函数（复用 `DomainMigrators`）。
 *
 * ## 核心保证
 *
 * 1. **幂等**：每域先检查新键是否已存在——存在则跳过（`SKIPPED`），不覆盖；
 * 2. **断点续跑**：每完成一域就把报告写入 `v2.meta`，进程被杀后下次从断点继续；
 * 3. **旧数据永不立即删除**：保留 `LEGACY_RETENTION_DAYS` 天（默认 30），到期由
 *    `cleanupLegacy()` 在二次校验通过后清理；
 * 4. **失败不阻塞**：单域失败只记录，不影响其它域与应用启动（启动关键路径不得抛错）。
 */

import { fileIo } from '@kit.CoreFileKit'
import { PreferencesStore } from '../infra/PreferencesStore'
import { Logger, DOMAIN_INFRA, formatError } from '../utils/Logger'
import { writeTextFully } from '../utils/FileUtils'
import {
  convertDomainValues,
  isMirrorDomain,
  isNewNamespaceKey,
  LegacyValue,
  MigrationContext,
  MigrationConvertResult,
  resolveLegacyRule
} from './DomainMigrators'
import { DomainHealthTracker } from './DomainHealth'
import { DomainIds, PersistenceCatalog } from './PersistenceCatalog'
import { PersistenceHub } from './PersistenceHub'
import {
  DomainSpec,
  LEGACY_RETENTION_DAYS,
  MIGRATION_BUDGET_MS,
  MigrationDomainResult,
  MigrationDomainStatus,
  MigrationReport,
  MigrationStatus,
  PERSISTENCE_DATA_VERSION,
  PersistenceMeta,
  StorageKind,
  shortError
} from './PersistenceTypes'

const logger = new Logger(DOMAIN_INFRA, 'MigrationEngine')

/** 草稿域旧目录名（相对 filesDir）。 */
const LEGACY_DRAFTS_DIR: string = 'drafts'
/** 草稿域新目录名（相对 filesDir/v2）。 */
const NEW_DRAFTS_DIR: string = 'drafts'
/** 存档域旧目录名（相对 filesDir）。 */
const LEGACY_SAVED_DIR: string = 'saved_threads'
/** 存档域新目录名（相对 filesDir/v2）。 */
const NEW_SAVED_DIR: string = 'saved_threads'

/**
 * 一条待迁移的旧键。
 */
export class LegacyKeyEntry {
  /** 旧键名。 */
  readonly key: string
  /** 从键名解析出的旧账号 uid（可能为空）。 */
  readonly uid: string

  /**
   * 构造旧键条目。
   *
   * @param key - 旧键名
   * @param uid - 旧账号 uid
   */
  constructor(key: string, uid: string) {
    this.key = key
    this.uid = uid
  }
}

/**
 * 单域迁移任务。
 */
export class MigrationTask {
  /** 域 ID。 */
  readonly domainId: string
  /** 该域的旧键集合。 */
  readonly keys: LegacyKeyEntry[]

  /**
   * 构造任务。
   *
   * @param domainId - 域 ID
   * @param keys - 旧键集合
   */
  constructor(domainId: string, keys: LegacyKeyEntry[]) {
    this.domainId = domainId
    this.keys = keys
  }
}

/**
 * 迁移计划（检测产物）。
 */
export class MigrationPlan {
  /** 迁移前的数据版本（0 = 无锚点/首次升级）。 */
  fromDataVersion: number = 0
  /** Preferences 域任务。 */
  tasks: MigrationTask[] = []
  /** 需要搬移的旧文件域（drafts / saved_threads）。 */
  fileDomains: string[] = []
  /** 全部旧键（用于清理期登记）。 */
  legacyKeys: string[] = []
  /** 全部旧文件路径（用于清理期登记）。 */
  legacyFiles: string[] = []

  /**
   * 是否存在待迁移内容。
   *
   * @returns 是否有任务
   */
  hasWork(): boolean {
    return this.tasks.length > 0 || this.fileDomains.length > 0
  }
}

/**
 * 检测结果（只读，驱动启动页/数据管理页提示）。
 */
export class MigrationInspection {
  /** 是否有待迁移的旧数据。 */
  pending: boolean = false
  /** 迁移是否已完成过（meta 存在且非失败/部分）。 */
  settled: boolean = false
  /** 待迁移的旧键数量。 */
  legacyKeyCount: number = 0
  /** 待迁移的旧文件域数量。 */
  legacyFileDomainCount: number = 0
  /** 报告（meta 中的上一次结果）。 */
  report: MigrationReport = new MigrationReport()
}

/**
 * 迁移引擎。
 */
export class MigrationEngine {
  private readonly hub: PersistenceHub
  private readonly store: PreferencesStore
  private readonly health: DomainHealthTracker
  private readonly appVersionName: string
  private readonly appVersionCode: number

  /**
   * 构造迁移引擎。
   *
   * @param hub - 持久化中心（新键读写 + 文件后端）
   * @param store - 偏好存储（旧键读取）
   * @param appVersionName - 应用版本名（写入 meta 诊断）
   * @param appVersionCode - 应用版本号
   */
  constructor(
    hub: PersistenceHub,
    store: PreferencesStore,
    appVersionName: string,
    appVersionCode: number
  ) {
    this.hub = hub
    this.store = store
    this.health = hub.health
    this.appVersionName = appVersionName
    this.appVersionCode = appVersionCode
  }

  /**
   * 只读检测：是否存在待迁移旧数据。
   *
   * @param currentUid - 当前登录 uid（多份旧键取舍依据）
   * @returns 检测结果
   */
  async inspect(currentUid: string): Promise<MigrationInspection> {
    const inspection: MigrationInspection = new MigrationInspection()
    const meta: PersistenceMeta | null = await this.hub.metaStore.load()
    if (meta !== null) {
      inspection.report = meta.migration
      inspection.settled = meta.migration.status === MigrationStatus.COMPLETED ||
        meta.migration.status === MigrationStatus.NOT_REQUIRED
    }
    const plan: MigrationPlan = await this.buildPlan(currentUid, meta)
    inspection.pending = plan.hasWork()
    inspection.legacyKeyCount = plan.legacyKeys.length
    inspection.legacyFileDomainCount = plan.fileDomains.length
    return inspection
  }

  /**
   * 构建迁移计划。
   *
   * @param currentUid - 当前登录 uid
   * @param meta - 已存在的锚点（可为 null）
   * @returns 计划
   */
  async buildPlan(currentUid: string, meta: PersistenceMeta | null): Promise<MigrationPlan> {
    const plan: MigrationPlan = new MigrationPlan()
    plan.fromDataVersion = meta !== null ? meta.dataVersion : 0
    const allKeys: string[] = await this.hub.listPreferenceKeys()
    /*
     * 已完整迁移过登记的旧键不重复入计划。
     *
     * 为什么需要：迁移成功后旧键要保留 30 天（回滚窗口），若不过滤，每次冷启动都会把旧键
     * 重新当成"待迁移"扫一遍（虽然逐域 SKIPPED 幂等，但白读一遍全部旧载荷 + 重写 meta）。
     * 只有旧版本 App 回滚写入的**新**旧键（不在登记列表里）才会被重新检测并迁移。
     */
    const settledKeys: Set<string> = new Set<string>()
    if (meta !== null && meta.migration.status === MigrationStatus.COMPLETED) {
      for (let i: number = 0; i < meta.migration.legacyKeys.length; i++) {
        settledKeys.add(meta.migration.legacyKeys[i])
      }
    }
    // 按域聚合旧键
    const byDomain: Map<string, LegacyKeyEntry[]> = new Map<string, LegacyKeyEntry[]>()
    for (let i: number = 0; i < allKeys.length; i++) {
      const key: string = allKeys[i]
      if (isNewNamespaceKey(key) || settledKeys.has(key)) {
        continue
      }
      const rule = resolveLegacyRule(key)
      if (rule === null) {
        continue
      }
      plan.legacyKeys.push(key)
      const entry: LegacyKeyEntry = new LegacyKeyEntry(key, rule.uidOf(key))
      const existing: LegacyKeyEntry[] | undefined = byDomain.get(rule.domainId)
      if (existing === undefined) {
        byDomain.set(rule.domainId, [entry])
      } else {
        existing.push(entry)
      }
    }
    byDomain.forEach((entries: LegacyKeyEntry[], domainId: string): void => {
      const spec: DomainSpec | null = PersistenceCatalog.byId(domainId)
      if (spec === null) {
        return
      }
      // 新键已存在：说明该域之前迁移过（或新版本已写入）。交给逐域执行时再判定"跳过/合并"，
      // 但不再把它的旧键算作"待迁移"以外的风险——保留在 legacyKeys 供清理期登记。
      plan.tasks.push(new MigrationTask(domainId, entries))
    })
    // 文件域检测：旧目录有文件、新目录缺失同名文件。
    // **已迁移过的文件域不再检测**（以 meta 的迁移报告为准）：否则升级后用户在新目录删掉的
    // 草稿/存档会被旧目录文件"复活"（旧目录要保留 30 天，期间每次启动都会重新复制回来）。
    const filesDir: string = this.hub.appFilesDir
    const settledFileDomains: Set<string> = settledFileDomainSet(meta)
    if (!settledFileDomains.has('drafts') &&
      this.hasLegacyFiles(filesDir, LEGACY_DRAFTS_DIR, NEW_DRAFTS_DIR)) {
      plan.fileDomains.push('drafts')
    }
    if (!settledFileDomains.has('saved_threads') &&
      this.hasLegacyFiles(filesDir, LEGACY_SAVED_DIR, NEW_SAVED_DIR)) {
      plan.fileDomains.push('saved_threads')
    }
    return plan
  }

  /**
   * 判断旧目录是否有"新目录缺失"的文件。
   *
   * @param filesDir - 应用 filesDir
   * @param legacyDir - 旧目录名（相对 filesDir）
   * @param newDir - 新目录名（相对 filesDir/v2）
   * @returns 是否需要迁移
   */
  private hasLegacyFiles(filesDir: string, legacyDir: string, newDir: string): boolean {
    try {
      const legacyPath: string = filesDir + '/' + legacyDir
      const newPath: string = filesDir + '/v2/' + newDir
      const legacyNames: string[] = this.listDir(legacyPath)
      if (legacyNames.length === 0) {
        return false
      }
      const newNames: string[] = this.listDir(newPath)
      const newSet: Set<string> = new Set<string>()
      for (let i: number = 0; i < newNames.length; i++) {
        newSet.add(newNames[i])
      }
      for (let i: number = 0; i < legacyNames.length; i++) {
        if (legacyNames[i].endsWith('.json') && !newSet.has(legacyNames[i])) {
          return true
        }
      }
      return false
    } catch (e) {
      return false
    }
  }

  /**
   * 列出目录下文件名（目录不存在返回空数组）。
   *
   * @param dirPath - 目录绝对路径
   * @returns 文件名数组
   */
  private listDir(dirPath: string): string[] {
    return listDirSafe(dirPath)
  }

  /**
   * 执行迁移计划（逐域、幂等、写 meta 断点）。
   *
   * @param plan - 计划
   * @param currentUid - 当前登录 uid
   * @returns 迁移报告
   */
  async run(plan: MigrationPlan, currentUid: string): Promise<MigrationReport> {
    const report: MigrationReport = new MigrationReport()
    report.status = MigrationStatus.PARTIAL
    report.fromDataVersion = plan.fromDataVersion
    report.startedAt = Date.now()
    const meta: PersistenceMeta = await this.ensureMeta(plan.fromDataVersion)
    /*
     * 旧键清理清单在**收尾时**按"本轮真正迁移成功"的域重建（见下方 migratedKeys）；
     * 中途断点先沿用历史清单，避免进程被杀后丢失已登记的旧键。
     */
    report.legacyKeys = meta.migration.legacyKeys.slice()
    const ctx: MigrationContext = new MigrationContext(currentUid, Date.now())
    const deadline: number = Date.now() + MIGRATION_BUDGET_MS

    // 逐域执行，收尾时按"实际迁移成功"重建旧键清理清单（见下方说明）
    const migratedKeys: string[] = []

    // ---- Preferences 域 ----
    for (let i: number = 0; i < plan.tasks.length; i++) {
      const task: MigrationTask = plan.tasks[i]
      if (Date.now() > deadline) {
        report.domains.push(new MigrationDomainResult(
          task.domainId, MigrationDomainStatus.DEFERRED, 0, '超出启动迁移预算'))
        continue
      }
      const result: MigrationDomainResult = await this.runTask(task, ctx)
      report.domains.push(result)
      if (result.status === MigrationDomainStatus.MIGRATED) {
        // 只有真正迁移成功（新键写入并通过读回校验）的域，旧键才允许进入 30 天后的清理清单。
        // SKIPPED/FAILED/DEFERRED 的旧键必须保留：它们仍是唯一副本，下次启动会重试迁移。
        for (let k: number = 0; k < task.keys.length; k++) {
          migratedKeys.push(task.keys[k].key)
        }
      }
      // 逐域落盘断点（失败也不打断后续域）
      meta.migration = report
      await this.hub.metaStore.save(meta)
      logger.info('migration domain=%{public}s status=%{public}s items=%{public}d',
        result.domain, result.status, result.items)
    }

    // ---- 文件域 ----
    for (let i: number = 0; i < plan.fileDomains.length; i++) {
      if (Date.now() > deadline) {
        report.domains.push(new MigrationDomainResult(
          plan.fileDomains[i], MigrationDomainStatus.DEFERRED, 0, '超出启动迁移预算'))
        continue
      }
      const result: MigrationDomainResult = this.runFileTask(plan.fileDomains[i], deadline)
      report.domains.push(result)
      meta.migration = report
      await this.hub.metaStore.save(meta)
      logger.info('migration file domain=%{public}s status=%{public}s items=%{public}d',
        result.domain, result.status, result.items)
    }

    // 旧键清理清单 = 历史已登记 + 本轮真正迁移成功的键（见上）
    report.legacyKeys = mergeLegacyKeys(meta.migration.legacyKeys, migratedKeys)

    // ---- 收尾 ----
    report.finishedAt = Date.now()
    report.status = summarize(report)
    /*
     * 凭证旧键**不保留 30 天**（与普通旧键不同）：`auth`/`sessions` 里是明文 token/cid，
     * 而本应用开启了系统云备份（`allowToBackupRestore: true`），长期驻留会让云端同时存在
     * 新旧两份凭证。新键已读回校验通过，旧键可立即删除；回滚旧版本需重新登录或用 .ngacred 导入。
     */
    await this.deleteLegacyCredentialKeys(report)
    report.legacyCleanupAt = report.finishedAt + LEGACY_RETENTION_DAYS * 24 * 60 * 60 * 1000
    if (report.status === MigrationStatus.COMPLETED) {
      logger.info('migration completed: %{public}d domains, %{public}d legacy keys',
        report.domains.length, report.legacyKeys.length)
    } else {
      logger.warn('migration %{public}s: %{public}d failed domains',
        report.status, report.count(MigrationDomainStatus.FAILED))
    }
    meta.migration = report
    meta.dataVersion = PERSISTENCE_DATA_VERSION
    if (report.status === MigrationStatus.COMPLETED) {
      meta.migratedAt = report.finishedAt
    }
    await this.hub.metaStore.save(meta)
    await this.hub.flush()
    return report
  }

  /**
   * 迁移完成后立即删除凭证旧键（`auth` / `sessions`）。
   *
   * 前置条件：对应新域必须可读（读回校验），否则保留旧键等待下次迁移重试。
   * 删除成功后从 `report.legacyKeys` 移除，避免旧数据清理阶段重复处理。
   *
   * @param report - 当前迁移报告（原地更新 legacyKeys）
   */
  private async deleteLegacyCredentialKeys(report: MigrationReport): Promise<void> {
    const credentialKeys: string[] = ['auth', 'sessions']
    let remaining: string[] = report.legacyKeys.slice()
    for (let i: number = 0; i < credentialKeys.length; i++) {
      const legacyKey: string = credentialKeys[i]
      if (remaining.indexOf(legacyKey) < 0) {
        continue
      }
      const domainId: string = legacyKey === 'auth' ? DomainIds.AUTH : DomainIds.SESSIONS
      const spec: DomainSpec | null = PersistenceCatalog.byId(domainId)
      if (spec === null) {
        continue
      }
      const current: Object | null = await this.hub.readPayload(spec)
      if (current === null) {
        // 新键不可读：保留旧键，等下次迁移重试
        continue
      }
      const deleted: boolean = await this.store.deleteKey(legacyKey, false)
      if (deleted) {
        const kept: string[] = []
        for (let j: number = 0; j < remaining.length; j++) {
          if (remaining[j] !== legacyKey) {
            kept.push(remaining[j])
          }
        }
        remaining = kept
        logger.info('legacy credential key removed after migration: %{public}s', legacyKey)
      }
    }
    report.legacyKeys = remaining
  }

  /**
   * 执行单个 Preferences 域迁移。
   *
   * @param task - 域任务
   * @param ctx - 迁移上下文
   * @returns 单域结果
   */
  private async runTask(task: MigrationTask, ctx: MigrationContext): Promise<MigrationDomainResult> {
    const domainId: string = task.domainId
    const spec: DomainSpec | null = PersistenceCatalog.byId(domainId)
    if (spec === null) {
      return new MigrationDomainResult(domainId, MigrationDomainStatus.FAILED, 0, '未注册的域')
    }
    const startedAt: number = Date.now()
    try {
      /*
       * 账号镜像域在未登录时**不迁移**：旧信封里的 uid 是历史账号，新 HUB 信封的 ownerUid 只能
       * 由本次会话 uid 提供；未登录时写空 ownerUid 会让任何后续账号都通过归属校验，
       * 造成"上一个账号的通知缓存被当前账号展示"的串号（镜像数据服务端可重建，丢弃无损失）。
       */
      if (isMirrorDomain(domainId) && ctx.currentUid.length === 0) {
        return new MigrationDomainResult(domainId, MigrationDomainStatus.SKIPPED, 0,
          '未登录：账号镜像缓存无归属，登录后由服务端重建', true)
      }
      // 1) 读取全部旧值（逐键容错：单键坏数据跳过）
      const values: LegacyValue[] = []
      for (let i: number = 0; i < task.keys.length; i++) {
        const raw: string = await this.store.getString(task.keys[i].key, '')
        if (raw.length === 0) {
          continue
        }
        try {
          const parsed: Object = JSON.parse(raw)
          values.push(new LegacyValue(task.keys[i].key, task.keys[i].uid, parsed))
        } catch (e) {
          logger.warn('迁移跳过坏旧值 key=%{public}s: %{public}s', task.keys[i].key, formatError(e))
        }
      }
      if (values.length === 0) {
        return new MigrationDomainResult(domainId, MigrationDomainStatus.SKIPPED, 0, '旧数据不可解析')
      }
      // 2) 转换
      const converted: MigrationConvertResult = convertDomainValues(domainId, values, ctx)
      if (converted.skippedReason.length > 0 && !converted.ok) {
        // 可重试的跳过（等登录后重试）标记 legacyRetained，导出/清空警示会统计该域
        return new MigrationDomainResult(domainId, MigrationDomainStatus.SKIPPED, 0,
          converted.skippedReason, converted.legacyRetained)
      }
      if (!converted.ok) {
        return new MigrationDomainResult(domainId, MigrationDomainStatus.FAILED, 0,
          converted.error.length > 0 ? converted.error : '转换失败')
      }
      // 3) 写入新键（已存在则跳过：不覆盖更新版本的数据）
      const existing: Object | null = await this.hub.readPayload(spec)
      if (existing !== null) {
        return new MigrationDomainResult(domainId, MigrationDomainStatus.SKIPPED, 0,
          '新键已存在，保留现有数据')
      }
      const ownerUid: string = isMirrorDomain(domainId) ? ctx.currentUid : ''
      const ok: boolean = await this.hub.writePayload(spec, converted.payload, ownerUid, true)
      if (!ok) {
        return new MigrationDomainResult(domainId, MigrationDomainStatus.FAILED, 0, '写入新键失败')
      }
      // 4) 读回校验（迁移必须可验证，不能只信任写调用）
      const verify: Object | null = await this.hub.readPayload(spec)
      if (verify === null) {
        return new MigrationDomainResult(domainId, MigrationDomainStatus.FAILED, 0, '读回校验失败')
      }
      this.hub.markMigrated(domainId, Date.now())
      logger.verbose('migrated domain=%{public}s items=%{public}d cost=%{public}dms',
        domainId, converted.items, Date.now() - startedAt)
      return new MigrationDomainResult(domainId, MigrationDomainStatus.MIGRATED, converted.items, '')
    } catch (e) {
      logger.error('迁移异常 domain=%{public}s: %{public}s', domainId, formatError(e))
      return new MigrationDomainResult(domainId, MigrationDomainStatus.FAILED, 0, shortError(e))
    }
  }

  /**
   * 执行单个文件域迁移（逐文件、坏文件跳过）。
   *
   * @param domainId - 域 ID（drafts / saved_threads）
   * @returns 单域结果
   */
  private runFileTask(domainId: string, deadline: number): MigrationDomainResult {
    const filesDir: string = this.hub.appFilesDir
    const isDrafts: boolean = domainId === 'drafts'
    const legacyDir: string = filesDir + '/' + (isDrafts ? LEGACY_DRAFTS_DIR : LEGACY_SAVED_DIR)
    const newDir: string = filesDir + '/v2/' + (isDrafts ? NEW_DRAFTS_DIR : NEW_SAVED_DIR)
    try {
      const names: string[] = this.listDir(legacyDir)
      if (names.length === 0) {
        return new MigrationDomainResult(domainId, MigrationDomainStatus.SKIPPED, 0, '旧目录为空')
      }
      ensureDirExists(newDir)
      const existing: string[] = this.listDir(newDir)
      const existingSet: Set<string> = new Set<string>()
      for (let i: number = 0; i < existing.length; i++) {
        existingSet.add(existing[i])
      }
      let migrated: number = 0
      let skipped: number = 0
      for (let i: number = 0; i < names.length; i++) {
        // 文件循环内也要检查启动预算：存档单帖可达数 MB，一次性同步复制会长时间阻塞主线程。
        // 超时即返回 DEFERRED，已复制的文件保留（下次启动按"新目录已有同名"跳过续跑）。
        if (Date.now() > deadline) {
          logger.warn('文件域迁移超出预算 domain=%{public}s migrated=%{public}d',
            domainId, migrated)
          return new MigrationDomainResult(domainId, MigrationDomainStatus.DEFERRED, migrated,
            '超出启动迁移预算（已迁移 ' + String(migrated) + ' 个，下次继续）')
        }
        const name: string = names[i]
        if (!name.endsWith('.json') || existingSet.has(name)) {
          continue
        }
        const raw: string | null = readTextSafe(legacyDir + '/' + name)
        if (raw === null) {
          skipped++;
          continue
        }
        try {
          const parsed: Object = JSON.parse(raw)
          if (!isFilePayloadValid(domainId, parsed)) {
            skipped++;
            continue
          }
        } catch (e) {
          skipped++;
          continue
        }
        if (writeTextAtomic(newDir, name, raw)) {
          migrated++;
        } else {
          skipped++;
        }
      }
      if (migrated === 0 && skipped > 0) {
        /*
         * 全部旧文件无效：按 SKIPPED 处理而不是 FAILED。
         * FAILED 会让迁移报告恒为 PARTIAL，MainPage 每次冷启动都弹"数据升级失败"模态框；
         * 而这些坏文件对用户没有价值，记日志即可（旧目录保留到清理期后由 cleanup 处理）。
         */
        logger.warn('文件域旧目录无可迁移的有效文件 domain=%{public}s skipped=%{public}d',
          domainId, skipped)
        return new MigrationDomainResult(domainId, MigrationDomainStatus.SKIPPED, 0,
          '旧目录 ' + String(skipped) + ' 个文件均无效，已忽略')
      }
      return new MigrationDomainResult(domainId, MigrationDomainStatus.MIGRATED, migrated,
        skipped > 0 ? ('跳过无效文件 ' + String(skipped) + ' 个') : '')
    } catch (e) {
      logger.error('文件域迁移异常 domain=%{public}s: %{public}s', domainId, formatError(e))
      return new MigrationDomainResult(domainId, MigrationDomainStatus.FAILED, 0, shortError(e))
    }
  }

  /**
   * 获取或创建元数据锚点。
   *
   * @param fromDataVersion - 迁移前版本
   * @returns 锚点
   */
  private async ensureMeta(fromDataVersion: number): Promise<PersistenceMeta> {
    const existing: PersistenceMeta | null = await this.hub.metaStore.load(true)
    if (existing !== null) {
      return existing
    }
    const meta: PersistenceMeta = new PersistenceMeta()
    meta.dataVersion = fromDataVersion
    meta.createdAt = Date.now()
    meta.appVersionName = this.appVersionName
    meta.appVersionCode = this.appVersionCode
    return meta
  }

  /**
   * 清理到期的旧数据（旧键 + 旧文件）。
   *
   * 二次校验：对应新域数据必须存在且可读，否则放弃清理（避免把失败迁移后的旧数据也删掉）。
   *
   * @param report - 迁移报告（提供 legacyKeys / legacyCleanupAt）
   * @param force - 是否忽略到期时间（用户点"立即清理"）
   * @returns 清理的条目数
   */
  async cleanupLegacy(report: MigrationReport, force: boolean): Promise<number> {
    if (report.legacyKeys.length === 0 && report.legacyCleanupAt === 0) {
      return 0
    }
    if (!force && Date.now() < report.legacyCleanupAt) {
      return 0
    }
    let removed: number = 0
    const legacyKeys: string[] = report.legacyKeys
    for (let i: number = 0; i < legacyKeys.length; i++) {
      const key: string = legacyKeys[i]
      const rule = resolveLegacyRule(key)
      if (rule === null) {
        continue
      }
      const spec: DomainSpec | null = PersistenceCatalog.byId(rule.domainId)
      if (spec === null || spec.storage !== StorageKind.PREFERENCES) {
        continue
      }
      // 二次校验：新域必须已可读
      const current: Object | null = await this.hub.readPayload(spec)
      if (current === null) {
        logger.warn('跳过旧键清理（新域不可读）key=%{public}s', key)
        continue
      }
      const deleted: boolean = await this.store.deleteKey(key, false)
      if (deleted) {
        removed++;
      }
    }
    // 文件域：新目录存在同名文件才删旧文件
    const filesDir: string = this.hub.appFilesDir
    removed += this.cleanupLegacyFiles(filesDir, LEGACY_DRAFTS_DIR, NEW_DRAFTS_DIR)
    removed += this.cleanupLegacyFiles(filesDir, LEGACY_SAVED_DIR, NEW_SAVED_DIR)
    await this.store.flush()
    if (removed > 0) {
      logger.info('legacy cleanup removed %{public}d entries', removed)
    }
    return removed
  }

  /**
   * 清理旧文件（新目录已有同名文件的才删）。
   *
   * @param filesDir - 应用 filesDir
   * @param legacyDir - 旧目录名
   * @param newDir - 新目录名
   * @returns 删除的文件数
   */
  private cleanupLegacyFiles(filesDir: string, legacyDir: string, newDir: string): number {
    const legacyPath: string = filesDir + '/' + legacyDir
    const newPath: string = filesDir + '/v2/' + newDir
    const legacyNames: string[] = this.listDir(legacyPath)
    if (legacyNames.length === 0) {
      return 0
    }
    const newNames: string[] = this.listDir(newPath)
    const newSet: Set<string> = new Set<string>()
    for (let i: number = 0; i < newNames.length; i++) {
      newSet.add(newNames[i])
    }
    let removed: number = 0
    for (let i: number = 0; i < legacyNames.length; i++) {
      const name: string = legacyNames[i]
      if (!name.endsWith('.json') || !newSet.has(name)) {
        continue
      }
      if (deleteFileSafe(legacyPath + '/' + name)) {
        removed++;
      }
    }
    return removed
  }

  /**
   * 判断新目录是否已存在指定文件（迁移检测用）。
   *
   * @param domainId - 域 ID
   * @returns 是否存在新文件
   */
  hasAnyNewFile(domainId: string): boolean {
    const filesDir: string = this.hub.appFilesDir
    const isDrafts: boolean = domainId === 'drafts'
    const newDir: string = filesDir + '/v2/' + (isDrafts ? NEW_DRAFTS_DIR : NEW_SAVED_DIR)
    return this.listDir(newDir).length > 0
  }
}

/**
 * 从迁移报告中提取"已完成迁移的文件域"集合。
 *
 * @param meta - 数据版本锚点；null 时返回空集合
 * @returns 已迁移的文件域 ID 集合
 */
function settledFileDomainSet(meta: PersistenceMeta | null): Set<string> {
  const result: Set<string> = new Set<string>()
  if (meta === null) {
    return result
  }
  const domains: MigrationDomainResult[] = meta.migration.domains
  for (let i: number = 0; i < domains.length; i++) {
    if (domains[i].status !== MigrationDomainStatus.MIGRATED) {
      continue
    }
    if (domains[i].domain === 'drafts' || domains[i].domain === 'saved_threads') {
      result.add(domains[i].domain)
    }
  }
  return result
}

/**
 * 合并两份旧键清单（去重、保持顺序：历史在前、本轮在后）。
 *
 * @param existing - 历史登记的旧键
 * @param incoming - 本轮检测到的旧键
 * @returns 合并后的清单
 */
function mergeLegacyKeys(existing: string[], incoming: string[]): string[] {
  const merged: string[] = []
  const seen: Set<string> = new Set<string>()
  for (let i: number = 0; i < existing.length; i++) {
    if (!seen.has(existing[i])) {
      seen.add(existing[i])
      merged.push(existing[i])
    }
  }
  for (let i: number = 0; i < incoming.length; i++) {
    if (!seen.has(incoming[i])) {
      seen.add(incoming[i])
      merged.push(incoming[i])
    }
  }
  return merged
}

/**
 * 汇总报告状态。
 *
 * @param report - 报告
 * @returns 总体状态
 */
function summarize(report: MigrationReport): string {
  const failed: number = report.count(MigrationDomainStatus.FAILED)
  const migrated: number = report.count(MigrationDomainStatus.MIGRATED)
  const deferred: number = report.count(MigrationDomainStatus.DEFERRED)
  if (failed === 0 && deferred === 0) {
    if (migrated === 0 && report.domains.length === 0) {
      return MigrationStatus.NOT_REQUIRED
    }
    return MigrationStatus.COMPLETED
  }
  if (failed === report.domains.length && migrated === 0) {
    return MigrationStatus.FAILED
  }
  return MigrationStatus.PARTIAL
}

/**
 * 校验文件域载荷是否合法（复用既有 Store 的判定规则）。
 *
 * @param domainId - 域 ID
 * @param parsed - 解析后的对象
 * @returns 是否合法
 */
function isFilePayloadValid(domainId: string, parsed: Object): boolean {
  if (parsed === null || parsed === undefined || typeof parsed !== 'object') {
    return false
  }
  const record: Record<string, Object> = parsed as Record<string, Object>
  if (domainId === 'saved_threads') {
    const tid: string = typeof record['tid'] === 'string' ? record['tid'] as string : ''
    if (tid.length === 0 || tid.length > 16) {
      return false
    }
    for (let i: number = 0; i < tid.length; i++) {
      const c: string = tid.charAt(i)
      if (c < '0' || c > '9') {
        return false
      }
    }
    const rawPages: Object | undefined = record['rawPages']
    return rawPages !== undefined && rawPages !== null && Array.isArray(rawPages) &&
      (rawPages as Object[]).length > 0
  }
  // drafts：key 非空即可（正文允许为空——用户可能只插入媒体）
  const key: string = typeof record['key'] === 'string' ? record['key'] as string : ''
  return key.length > 0
}

/**
 * 确保目录存在。
 *
 * @param dirPath - 目录绝对路径
 */
function ensureDirExists(dirPath: string): void {
  try {
    if (!fileIo.accessSync(dirPath)) {
      fileIo.mkdirSync(dirPath, true)
    }
  } catch (e) {
    // 目录已存在或创建失败：后续写入会返回失败并记录
  }
}

/**
 * 安全列目录。
 *
 * @param dirPath - 目录绝对路径
 * @returns 文件名数组
 */
function listDirSafe(dirPath: string): string[] {
  try {
    if (!fileIo.accessSync(dirPath)) {
      return []
    }
    return fileIo.listFileSync(dirPath)
  } catch (e) {
    return []
  }
}

/**
 * 安全读取文本文件。
 *
 * @param path - 绝对路径
 * @returns 内容；失败返回 null
 */
function readTextSafe(path: string): string | null {
  try {
    return fileIo.readTextSync(path)
  } catch (e) {
    return null
  }
}

/**
 * 原子写文本文件（临时文件 + rename）。
 *
 * @param dirPath - 目标目录
 * @param name - 文件名
 * @param content - 内容
 * @returns 是否成功
 */
function writeTextAtomic(dirPath: string, name: string, content: string): boolean {
  let file: fileIo.File | null = null
  const path: string = dirPath + '/' + name
  const tmpPath: string = path + '.tmp'
  try {
    file = fileIo.openSync(tmpPath,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC)
    // 旧存档单帖可达数 MB：单次 writeSync 不保证写完，截断的迁移结果会被 Store 判为坏文件
    if (!writeTextFully(file.fd, content)) {
      throw new Error('迁移文件写入不完整')
    }
    fileIo.closeSync(file)
    file = null
    fileIo.renameSync(tmpPath, path)
    return true
  } catch (e) {
    if (file !== null) {
      try {
        fileIo.closeSync(file)
      } catch (e2) {
      }
    }
    try {
      if (fileIo.accessSync(tmpPath)) {
        fileIo.unlinkSync(tmpPath)
      }
    } catch (e2) {
    }
    return false
  }
}

/**
 * 删除文件。
 *
 * @param path - 绝对路径
 * @returns 是否删除成功
 */
function deleteFileSafe(path: string): boolean {
  try {
    if (fileIo.accessSync(path)) {
      fileIo.unlinkSync(path)
      return true
    }
  } catch (e) {
    // 删除失败留给下次启动
  }
  return false
}
