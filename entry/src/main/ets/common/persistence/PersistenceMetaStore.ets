/**
 * 全局数据版本锚点存储（`v2.meta`）。
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §5.1 / §5.3。锚点回答两个问题：
 * 1. 磁盘上的数据属于哪一代（`dataVersion`）；
 * 2. 上一次迁移做到哪一步（`migration` 报告，含已完成/失败域与旧键清单）。
 *
 * 读取必须绝对容错：meta 损坏不能让应用起不来（宁可当作"未迁移"重新检测）。
 */

import { PreferencesStore } from '../infra/PreferencesStore'
import { Logger, DOMAIN_INFRA, formatError } from '../utils/Logger'
import {
  MigrationDomainResult,
  MigrationReport,
  MigrationStatus,
  PERSISTENCE_DATA_VERSION,
  PERSISTENCE_META_KEY,
  PersistenceMeta,
  TRANSFER_HISTORY_MAX,
  TransferHistoryEntry,
  TransferHistoryKind
} from './PersistenceTypes'

const logger = new Logger(DOMAIN_INFRA, 'PersistenceMetaStore')

/**
 * 数据版本锚点读写。
 *
 * 注意：本类**不使用域信封**——meta 自身就是版本真相，套信封会形成"版本需要版本描述"的循环。
 */
export class PersistenceMetaStore {
  private readonly store: PreferencesStore
  /** 内存镜像（避免每次判断都读盘）。 */
  private cached: PersistenceMeta | null = null
  /** 是否已完成首次读取（区分"未读过"与"读到的确实是空"）。 */
  private loaded: boolean = false

  /**
   * 构造锚点存储。
   *
   * @param store - 偏好存储
   */
  constructor(store: PreferencesStore) {
    this.store = store
  }

  /**
   * 读取锚点（带内存缓存；首次读取后复用）。
   *
   * @param forceReload - 是否强制重新读盘
   * @returns 锚点；不存在或损坏时返回 null（调用方据此判断"需要迁移检测"）
   */
  async load(forceReload: boolean = false): Promise<PersistenceMeta | null> {
    if (this.loaded && !forceReload) {
      return this.cached
    }
    this.loaded = true
    this.cached = null
    const raw: string = await this.store.getString(PERSISTENCE_META_KEY, '')
    if (raw.length === 0) {
      return null
    }
    try {
      const parsed: Object = JSON.parse(raw)
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        return null
      }
      this.cached = normalizeMeta(parsed as Record<string, Object>)
      return this.cached
    } catch (e) {
      logger.warn('meta 解析失败，按未迁移处理: %{public}s', formatError(e))
      return null
    }
  }

  /**
   * 写入锚点（立即刷盘：它是迁移断点，丢了会导致重复迁移/迁移结果误判）。
   *
   * @param meta - 锚点数据
   * @returns 是否成功
   */
  async save(meta: PersistenceMeta): Promise<boolean> {
    try {
      const content: string = JSON.stringify(meta)
      await this.store.putString(PERSISTENCE_META_KEY, content, true)
      await this.store.flush()
      this.cached = meta
      this.loaded = true
      return true
    } catch (e) {
      logger.error('meta 写入失败: %{public}s', formatError(e))
      return false
    }
  }

  /**
   * 首次安装：创建锚点（dataVersion 直接置当前值，`migratedAt` 留 0 表示"无迁移"）。
   *
   * @param appVersionName - 应用版本名
   * @param appVersionCode - 应用版本号
   * @returns 新锚点
   */
  async createFresh(appVersionName: string, appVersionCode: number): Promise<PersistenceMeta> {
    const meta: PersistenceMeta = new PersistenceMeta()
    meta.dataVersion = PERSISTENCE_DATA_VERSION
    meta.createdAt = Date.now()
    meta.migratedAt = 0
    meta.appVersionName = appVersionName
    meta.appVersionCode = appVersionCode
    meta.migration = new MigrationReport()
    meta.migration.status = MigrationStatus.NOT_REQUIRED
    await this.save(meta)
    return meta
  }

  /**
   * 更新迁移报告（逐域落盘，作为断点）。
   *
   * @param meta - 当前锚点（原地修改并保存）
   * @param report - 最新报告
   * @param appVersionName - 应用版本名
   * @param appVersionCode - 应用版本号
   * @returns 是否保存成功
   */
  async saveReport(
    meta: PersistenceMeta,
    report: MigrationReport,
    appVersionName: string,
    appVersionCode: number
  ): Promise<boolean> {
    meta.migration = report
    meta.appVersionName = appVersionName
    meta.appVersionCode = appVersionCode
    if (report.status === MigrationStatus.COMPLETED) {
      meta.migratedAt = report.finishedAt
    }
    return await this.save(meta)
  }

  /**
   * 清除内存缓存（测试/重载用）。
   */
  invalidateCache(): void {
    this.cached = null
    this.loaded = false
  }

  /**
   * 返回已加载的锚点（不触发读盘）。
   *
   * @returns 锚点；未加载返回 null
   */
  peek(): PersistenceMeta | null {
    return this.cached
  }
}

/**
 * 把磁盘上的原始对象逐字段重建为锚点（缺字段/坏字段按默认值兜底）。
 *
 * 导出供单测：磁盘反序列化（`legacyRetained` / `transferHistory` 等新字段的兼容读取）
 * 是最容易回归的路径，必须能直接构造原始 JSON 对象断言（评审 R-C04）。
 *
 * @param raw - 原始 JSON 对象
 * @returns 锚点
 */
export function normalizeMeta(raw: Record<string, Object>): PersistenceMeta {
  const meta: PersistenceMeta = new PersistenceMeta()
  meta.dataVersion = readNumber(raw['dataVersion'], PERSISTENCE_DATA_VERSION)
  meta.createdAt = readNumber(raw['createdAt'], 0)
  meta.migratedAt = readNumber(raw['migratedAt'], 0)
  meta.appVersionName = readString(raw['appVersionName'])
  meta.appVersionCode = readNumber(raw['appVersionCode'], 0)
  meta.migration = normalizeReport(raw['migration'])
  meta.migrationNoticeAcknowledged = readBoolean(raw['migrationNoticeAcknowledged'], false)
  meta.treeGuideAcknowledged = readBoolean(raw['treeGuideAcknowledged'], false)
  meta.transferHistory = normalizeTransferHistory(raw['transferHistory'])
  return meta
}

/**
 * 逐字段重建导出/导入历史（坏条目丢弃、未知类型丢弃、超出上限截断）。
 *
 * @param raw - 原始数组（可能缺失/类型错误）
 * @returns 历史记录（最新在前，长度 ≤ `TRANSFER_HISTORY_MAX`）
 */
function normalizeTransferHistory(raw: Object | undefined): TransferHistoryEntry[] {
  const result: TransferHistoryEntry[] = []
  if (raw === undefined || raw === null || !Array.isArray(raw)) {
    return result
  }
  const items: Object[] = raw as Object[]
  for (let i: number = 0; i < items.length; i++) {
    if (result.length >= TRANSFER_HISTORY_MAX) {
      break
    }
    const item: Object = items[i]
    if (item === null || item === undefined || typeof item !== 'object' || Array.isArray(item)) {
      continue
    }
    const record: Record<string, Object> = item as Record<string, Object>
    const kind: string = readString(record['kind'])
    if (kind !== TransferHistoryKind.EXPORT && kind !== TransferHistoryKind.IMPORT) {
      continue
    }
    const entry: TransferHistoryEntry = new TransferHistoryEntry()
    entry.kind = kind
    entry.at = readNumber(record['at'], 0)
    entry.formatVersion = readNumber(record['formatVersion'], 0)
    entry.dataVersion = readNumber(record['dataVersion'], 0)
    entry.encrypted = readBoolean(record['encrypted'], false)
    entry.domainCount = readNumber(record['domainCount'], 0)
    entry.bytes = readNumber(record['bytes'], 0)
    entry.added = readNumber(record['added'], 0)
    entry.updated = readNumber(record['updated'], 0)
    entry.skippedDomains = readNumber(record['skippedDomains'], 0)
    entry.ok = readBoolean(record['ok'], false)
    const note: string = readString(record['note'])
    entry.note = note.length > 120 ? note.substring(0, 120) : note
    result.push(entry)
  }
  return result
}

/**
 * 防御性读取布尔值。
 *
 * @param value - 原始值
 * @param fallback - 非法时的兜底值
 * @returns 布尔值
 */
function readBoolean(value: Object | undefined, fallback: boolean): boolean {
  return typeof value === 'boolean' ? value as boolean : fallback
}

/**
 * 逐字段重建迁移报告。
 *
 * @param raw - 原始对象（可能缺失/类型错误）
 * @returns 迁移报告
 */
function normalizeReport(raw: Object | undefined): MigrationReport {
  const report: MigrationReport = new MigrationReport()
  if (raw === undefined || raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    return report
  }
  const record: Record<string, Object> = raw as Record<string, Object>
  const status: string = readString(record['status'])
  report.status = status.length > 0 ? status : MigrationStatus.UNKNOWN
  report.fromDataVersion = readNumber(record['fromDataVersion'], 0)
  report.startedAt = readNumber(record['startedAt'], 0)
  report.finishedAt = readNumber(record['finishedAt'], 0)
  report.legacyCleanupAt = readNumber(record['legacyCleanupAt'], 0)
  const domains: Object | undefined = record['domains']
  if (domains !== undefined && domains !== null && Array.isArray(domains)) {
    const items: Object[] = domains as Object[]
    for (let i: number = 0; i < items.length; i++) {
      const item: Object = items[i]
      if (item === null || item === undefined || typeof item !== 'object') {
        continue
      }
      const entry: Record<string, Object> = item as Record<string, Object>
      const result: MigrationDomainResult = new MigrationDomainResult()
      result.domain = readString(entry['domain'])
      result.status = readString(entry['status'])
      result.items = readNumber(entry['items'], 0)
      result.reason = readString(entry['reason'])
      result.legacyRetained = readBoolean(entry['legacyRetained'], false)
      if (result.domain.length > 0) {
        report.domains.push(result)
      }
    }
  }
  const legacy: Object | undefined = record['legacyKeys']
  if (legacy !== undefined && legacy !== null && Array.isArray(legacy)) {
    const keys: Object[] = legacy as Object[]
    for (let i: number = 0; i < keys.length; i++) {
      const key: string = readString(keys[i])
      if (key.length > 0) {
        report.legacyKeys.push(key)
      }
    }
  }
  return report
}

/**
 * 防御性读取字符串。
 *
 * @param value - 原始值
 * @returns 字符串（非法值返回空串）
 */
function readString(value: Object | undefined): string {
  return typeof value === 'string' ? value as string : ''
}

/**
 * 防御性读取数值。
 *
 * @param value - 原始值
 * @param fallback - 非法时的兜底值
 * @returns 有限数值
 */
function readNumber(value: Object | undefined, fallback: number): number {
  if (typeof value !== 'number' || !isFinite(value as number)) {
    return fallback
  }
  return value as number
}
