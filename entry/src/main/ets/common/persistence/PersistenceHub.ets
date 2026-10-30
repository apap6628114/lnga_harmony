/**
 * 持久化中心（PersistenceHub）— 统一治理的编排层。
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §1.2 / §4。职责：
 * 1. 持有 Preferences 与文件两种存储后端，按域元数据路由读写；
 * 2. 统一域载荷的读取容错（坏数据不抛错）与写入保护（pending 双键）；
 * 3. 汇总域健康（体积/条目/失败）供数据管理页展示；
 * 4. 提供迁移/导出导入所需的原始键访问与 flush 编排。
 *
 * 不做的事：不解释域内业务语义（那是各 Store 的职责）、不决定何时加载（AppStore 编排）。
 *
 * ## RAW 与 ENVELOPE 两种载荷
 *
 * - RAW（存量域默认）：键下直接是业务 JSON（如 `SettingsState` 序列化结果）。读取时 JSON.parse
 *   后原样返回，写入时原样落盘。用于让 15 个既有 Store **只换键、不动载荷**接入治理。
 * - ENVELOPE（账号镜像域）：`{schemaVersion, domain, updatedAt, ownerUid, payload}`。账号归属与
 *   版本校验由本层统一执行，Store 只消费 payload。
 */

import { PreferencesStore } from '../infra/PreferencesStore'
import { SerialQueue } from '../infra/SerialQueue'
import { Logger, DOMAIN_INFRA, formatError } from '../utils/Logger'
import { DomainHealthTracker } from './DomainHealth'
import { PersistenceCatalog } from './PersistenceCatalog'
import { isLegacyKey } from './DomainMigrators'
import { JsonFileBackend, PreferencesBackend } from './StorageBackends'
import { PersistenceMetaStore } from './PersistenceMetaStore'
import {
  DomainEnvelope,
  DomainSpec,
  MigrationStatus,
  PERSISTENCE_DATA_VERSION,
  StorageKind
} from './PersistenceTypes'

const logger = new Logger(DOMAIN_INFRA, 'PersistenceHub')

/**
 * 统一持久化中心。
 */
export class PersistenceHub {
  private store: PreferencesStore | null = null
  private queue: SerialQueue | null = null
  private filesDir: string = ''
  private prefBackend: PreferencesBackend | null = null
  private fileBackend: JsonFileBackend | null = null
  private metaStoreRef: PersistenceMetaStore | null = null
  private initialized: boolean = false
  /** 域 ID → 最近一次成功写入时间（毫秒；导出 updatedAt 使用）。 */
  private lastWriteAt: Map<string, number> = new Map<string, number>()
  /** 域健康跟踪器。 */
  readonly health: DomainHealthTracker = new DomainHealthTracker()

  /**
   * 初始化（幂等；重复调用会用新依赖覆盖并重置后端）。
   *
   * @param store - 偏好存储
   * @param queue - 串行写队列（与各 Store 共享同一队列，保证写入顺序）
   * @param filesDir - 应用沙箱 filesDir（文件域根目录）
   */
  async init(store: PreferencesStore, queue: SerialQueue, filesDir: string): Promise<void> {
    this.store = store
    this.queue = queue
    this.filesDir = filesDir
    this.prefBackend = new PreferencesBackend(store)
    this.fileBackend = new JsonFileBackend(filesDir)
    this.metaStoreRef = new PersistenceMetaStore(store)
    this.initialized = true
    // 启动自检：清理上次进程中断遗留的 `.pending` 临时键（设计文档 §4.5）
    const specs: DomainSpec[] = PersistenceCatalog.byStorage(StorageKind.PREFERENCES)
    await this.prefBackend.cleanupPending(specs)
    logger.info('initialized (filesDir=%{public}s)', filesDir)
  }

  /** 是否已初始化。 */
  get isInitialized(): boolean {
    return this.initialized
  }

  /** Preferences 后端。 */
  get preferences(): PreferencesBackend {
    if (this.prefBackend === null) {
      throw new Error('PersistenceHub 未初始化')
    }
    return this.prefBackend
  }

  /** 文件后端。 */
  get files(): JsonFileBackend {
    if (this.fileBackend === null) {
      throw new Error('PersistenceHub 未初始化')
    }
    return this.fileBackend
  }

  /** 数据版本锚点存储。 */
  get metaStore(): PersistenceMetaStore {
    if (this.metaStoreRef === null) {
      throw new Error('PersistenceHub 未初始化')
    }
    return this.metaStoreRef
  }

  /** 应用沙箱 filesDir（未初始化时为空串）。 */
  get appFilesDir(): string {
    return this.filesDir
  }

  /**
   * 读取域的载荷。
   *
   * @param spec - 域元数据（PREFERENCES 介质）
   * @returns 载荷对象；不存在/损坏/版本不符返回 null（同时记录健康与日志，不抛错）
   */
  async readPayload(spec: DomainSpec): Promise<Object | null> {
    if (spec.storage !== StorageKind.PREFERENCES) {
      return null
    }
    const raw: string | null = await this.preferences.readRaw(spec)
    if (raw === null) {
      this.health.updateSize(spec.id, 0, 0)
      return null
    }
    try {
      const parsed: Object = JSON.parse(raw)
      if (parsed === null || parsed === undefined) {
        this.health.recordLoad(spec.id, false, 0, new Error('载荷为空'))
        return null
      }
      if (spec.rawPayload) {
        this.health.recordLoad(spec.id, true, 0, null)
        this.health.updateSize(spec.id, countItems(parsed), raw.length)
        return parsed
      }
      return this.readEnvelope(spec, parsed)
    } catch (e) {
      logger.warn('域载荷解析失败 domain=%{public}s: %{public}s', spec.id, formatError(e))
      this.health.recordLoad(spec.id, false, 0, e)
      return null
    }
  }

  /**
   * 解析并校验统一域信封。
   *
   * @param spec - 域元数据
   * @param parsed - 已 JSON.parse 的对象
   * @returns 信封内的 payload；结构/版本非法返回 null
   */
  private readEnvelope(spec: DomainSpec, parsed: Object): Object | null {
    if (Array.isArray(parsed) || typeof parsed !== 'object') {
      this.health.recordLoad(spec.id, false, 0, new Error('信封不是对象'))
      return null
    }
    const record: Record<string, Object> = parsed as Record<string, Object>
    const domain: string = String(record['domain'] ?? '')
    if (domain.length > 0 && domain !== spec.id) {
      this.health.recordLoad(spec.id, false, 0, new Error('信封域 ID 错配：' + domain))
      return null
    }
    const version: number = Number(record['schemaVersion'] ?? 0)
    if (version > spec.schemaVersion) {
      // 新版本 App 写入的数据：旧版本不解析（宁可空域，不可误读）
      logger.warn('域版本高于当前，跳过 domain=%{public}s saved=%{public}d current=%{public}d',
        spec.id, version, spec.schemaVersion)
      this.health.recordLoad(spec.id, false, 0, new Error('域版本过新'))
      return null
    }
    const payload: Object | undefined = record['payload']
    if (payload === undefined || payload === null) {
      this.health.recordLoad(spec.id, false, 0, new Error('信封缺少 payload'))
      return null
    }
    this.health.recordLoad(spec.id, true, 0, null)
    this.health.updateSize(spec.id, countItems(payload), JSON.stringify(payload).length)
    return payload
  }

  /**
   * 读取账号镜像域的信封元信息（ownerUid / updatedAt）。
   *
   * @param spec - 域元数据
   * @returns 信封元信息；不存在/非法返回 null
   */
  async readEnvelopeMeta(spec: DomainSpec): Promise<DomainEnvelope | null> {
    if (spec.storage !== StorageKind.PREFERENCES) {
      return null
    }
    const raw: string | null = await this.preferences.readRaw(spec)
    if (raw === null) {
      return null
    }
    try {
      const parsed: Object = JSON.parse(raw)
      if (Array.isArray(parsed) || typeof parsed !== 'object') {
        return null
      }
      const record: Record<string, Object> = parsed as Record<string, Object>
      const envelope: DomainEnvelope = new DomainEnvelope()
      envelope.schemaVersion = Number(record['schemaVersion'] ?? 0)
      envelope.domain = String(record['domain'] ?? '')
      envelope.updatedAt = Number(record['updatedAt'] ?? 0)
      envelope.ownerUid = String(record['ownerUid'] ?? (record['uid'] ?? ''))
      const payload: Object | undefined = record['payload']
      envelope.payload = payload !== undefined && payload !== null ? payload : new Object()
      return envelope
    } catch (e) {
      return null
    }
  }

  /**
   * 写入域载荷。
   *
   * @param spec - 域元数据（PREFERENCES 介质）
   * @param payload - 载荷对象
   * @param ownerUid - 账号镜像域的归属账号（其余域传空串）
   * @param flush - 是否立即刷盘
   * @returns 是否写入成功
   */
  async writePayload(
    spec: DomainSpec,
    payload: Object,
    ownerUid: string = '',
    flush: boolean = false
  ): Promise<boolean> {
    if (spec.storage !== StorageKind.PREFERENCES) {
      return false
    }
    let content: string = ''
    try {
      if (spec.rawPayload) {
        content = JSON.stringify(payload)
      } else {
        const envelope: DomainEnvelope = new DomainEnvelope()
        envelope.schemaVersion = spec.schemaVersion
        envelope.domain = spec.id
        envelope.updatedAt = Date.now()
        envelope.ownerUid = ownerUid
        envelope.payload = payload
        content = JSON.stringify(envelope)
      }
    } catch (e) {
      logger.error('域载荷序列化失败 domain=%{public}s: %{public}s', spec.id, formatError(e))
      this.health.recordWrite(spec.id, false, 0, e)
      return false
    }
    const ok: boolean = await this.preferences.writeRaw(spec, content, flush)
    this.health.recordWrite(spec.id, ok, content.length, ok ? null : new Error('写盘失败'))
    if (ok) {
      this.lastWriteAt.set(spec.id, Date.now())
    }
    return ok
  }

  /**
   * 删除域数据（磁盘）。
   *
   * @param spec - 域元数据
   * @returns 是否实际删除
   */
  async removeDomain(spec: DomainSpec): Promise<boolean> {
    if (spec.storage === StorageKind.PREFERENCES) {
      const removed: boolean = await this.preferences.deleteDomain(spec)
      this.lastWriteAt.delete(spec.id)
      this.health.reset(spec.id)
      return removed
    }
    const count: number = this.files.clearDir(spec)
    this.health.reset(spec.id)
    return count > 0
  }

  /**
   * 返回域最近一次成功写入时间。
   *
   * @param domainId - 域 ID
   * @returns 时间戳；从未写入返回 0
   */
  lastWriteTime(domainId: string): number {
    const value: number | undefined = this.lastWriteAt.get(domainId)
    return value === undefined ? 0 : value
  }

  /**
   * 返回域估算体积（Preferences：原始字符串长度；文件：目录大小）。
   *
   * @param spec - 域元数据
   * @returns 字节数
   */
  async estimateBytes(spec: DomainSpec): Promise<number> {
    if (spec.storage === StorageKind.JSON_FILES) {
      return this.files.dirSizeBytes(spec)
    }
    const raw: string | null = await this.preferences.readRaw(spec)
    return raw === null ? 0 : raw.length
  }

  /**
   * 返回 Preferences 全部键名（迁移检测枚举旧键用）。
   *
   * @returns 键名数组
   */
  async listPreferenceKeys(): Promise<string[]> {
    return await this.preferences.listKeys()
  }

  /**
   * 刷盘（经写队列排空后 flush；后台/导出前/导入后调用）。
   */
  async flush(): Promise<void> {
    if (this.store === null) {
      return
    }
    try {
      if (this.queue !== null) {
        await this.queue.enqueue(async (): Promise<void> => {})
      }
      await this.store.flush()
    } catch (e) {
      logger.warn('flush 失败: %{public}s', formatError(e))
    }
  }

  /**
   * 删除全部旧格式键（「清空本地数据」时调用）。
   *
   * 不删旧键的话，清空后下次启动的迁移检测会把旧数据重新迁移回来（用户看到"清空后又出现"）。
   *
   * @returns 删除的键数
   */
  async removeLegacyKeys(): Promise<number> {
    if (!this.initialized || this.store === null) {
      return 0
    }
    const store: PreferencesStore = this.store
    const keys: string[] = await this.listPreferenceKeys()
    let removed: number = 0
    for (let i: number = 0; i < keys.length; i++) {
      if (!isLegacyKey(keys[i])) {
        continue
      }
      if (await store.deleteKey(keys[i], false)) {
        removed++
      }
    }
    if (removed > 0) {
      await store.flush()
    }
    return removed
  }

  /**
   * 删除旧文件目录（`filesDir/drafts`、`filesDir/saved_threads`，递归）。
   *
   * @returns 删除的文件数
   */
  removeLegacyFileDirs(): number {
    if (!this.initialized || this.fileBackend === null) {
      return 0
    }
    let removed: number = 0
    removed += this.fileBackend.clearAbsoluteDir(this.filesDir + '/drafts')
    removed += this.fileBackend.clearAbsoluteDir(this.filesDir + '/saved_threads')
    return removed
  }

  /**
   * 记录一次"迁移已完成"到内存写入时间（导出 updatedAt 用）。
   *
   * @param domainId - 域 ID
   * @param time - 时间戳
   */
  markMigrated(domainId: string, time: number): void {
    this.lastWriteAt.set(domainId, time)
  }

  /**
   * 返回全部域的估算体积汇总（数据管理页）。
   *
   * @returns 域 ID → 字节数
   */
  async estimateAll(): Promise<Record<string, number>> {
    const result: Record<string, number> = {}
    const specs: DomainSpec[] = PersistenceCatalog.all()
    for (let i: number = 0; i < specs.length; i++) {
      result[specs[i].id] = await this.estimateBytes(specs[i])
    }
    return result
  }

  /**
   * 当前数据版本（meta 缺失返回 0，供启动检测）。
   *
   * @returns 数据版本
   */
  async currentDataVersion(): Promise<number> {
    if (!this.initialized) {
      return 0
    }
    const meta = await this.metaStore.load()
    if (meta === null) {
      return 0
    }
    return meta.dataVersion >= PERSISTENCE_DATA_VERSION ? PERSISTENCE_DATA_VERSION : meta.dataVersion
  }

  /**
   * 迁移是否已全部完成（meta 状态为 completed/not-required）。
   *
   * @returns 是否完成
   */
  async isMigrationSettled(): Promise<boolean> {
    if (!this.initialized) {
      return false
    }
    const meta = await this.metaStore.load()
    if (meta === null) {
      return false
    }
    return meta.migration.status === MigrationStatus.COMPLETED ||
      meta.migration.status === MigrationStatus.NOT_REQUIRED
  }
}

/**
 * 估算载荷的条目数（仅用于健康展示；无法判断时返回 1）。
 *
 * @param payload - 域载荷
 * @returns 条目数
 */
function countItems(payload: Object): number {
  if (Array.isArray(payload)) {
    return (payload as Object[]).length
  }
  if (payload !== null && payload !== undefined && typeof payload === 'object') {
    const keys: string[] = Object.keys(payload as Record<string, Object>)
    return keys.length
  }
  return 1
}

/** 全局唯一持久化中心（由 AppStore 在 init 时初始化）。 */
export const persistenceHub: PersistenceHub = new PersistenceHub()
