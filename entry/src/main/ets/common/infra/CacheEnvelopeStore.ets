import { PreferencesStore } from './PreferencesStore'
import { SerialQueue } from './SerialQueue'
import { PersistenceCatalog } from '../persistence/PersistenceCatalog'
import { DomainEnvelope, DomainScope, DomainSpec } from '../persistence/PersistenceTypes'

/** 统一信封 payload 内的条目数组字段名（旧版信封把 `items` 放在顶层，同名）。 */
const ITEMS_KEY: string = 'items'

/**
 * 统一域信封读写工具（原「按账号隔离的偏好持久化缓存信封」）。
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §4.1。改造后：
 * - **键不再拼 uid**：`key()` 从 `PersistenceCatalog` 取 `v2.<domainId>`（域注册表是唯一真相），
 *   uid 参数仅为兼容既有调用点保留；
 * - **落盘形态统一为域信封**：
 *   `{ schemaVersion, domain, updatedAt, ownerUid, payload: { items: T[] } }`；
 * - **账号归属软隔离**：仅 `ACCOUNT_MIRROR` 域校验 `ownerUid`（切号后读到上一个账号的镜像判非法，
 *   由调用方清空并按当前账号重建）；`DEVICE` 域（AI 会话 / AI 工具缓存 / 跟踪帖子）忽略账号，
 *   任何账号都可读写；
 * - **读取容错**：除新信封外，还接受迁移器直接搬运的裸载荷 `{ items: T[] }` 与旧版信封
 *   `{ schemaVersion, uid, items }`，避免"迁移已搬键、Store 却读不懂"的跨阶段空档；
 *   下一次写入即升级为新信封。
 *
 * schemaVersion 一律取域注册表声明的版本（当前全部为 1），Store 侧不再各自维护版本常量。
 * 读取时不因版本号更旧而拒绝（旧格式由迁移器转换），只在缺版本号/结构非法时判非法。
 */
export class CacheEnvelopeStore<T> {
  /** 域 ID（`PersistenceCatalog` 的域标识，如 `notifications`）。 */
  private readonly domainId: string
  /** 单条缓存项的字段类型校验规则（由各 Store 提供）。 */
  private readonly validateItem: (value: Object) => boolean

  /**
   * 构造缓存信封工具。
   *
   * @param domainId - 域 ID（键与 schemaVersion 均从域注册表读取）
   * @param validateItem - 单条缓存项校验函数
   */
  constructor(domainId: string, validateItem: (value: Object) => boolean) {
    this.domainId = domainId
    this.validateItem = validateItem
  }

  /**
   * 返回域的元数据。
   *
   * @returns 域元数据；未在注册表登记时返回 null
   */
  private spec(): DomainSpec | null {
    return PersistenceCatalog.byId(this.domainId)
  }

  /**
   * 返回当前域的 Preferences 键。
   *
   * **uid 参数仅为兼容既有调用点保留**：键名不再拼账号（`v2.<domainId>`）。
   *
   * @param uid - 旧调用点传入的用户 ID（已忽略）
   * @returns 完整键；域未登记时为空串（调用方据此跳过读写）
   */
  key(uid: string = ''): string {
    const spec: DomainSpec | null = this.spec()
    return spec === null ? '' : spec.fullKey()
  }

  /**
   * 判断本域是否为「账号镜像」域（需要 `ownerUid` 软隔离）。
   *
   * @returns 是否为账号镜像域
   */
  private isMirror(): boolean {
    const spec: DomainSpec | null = this.spec()
    return spec !== null && spec.scope === DomainScope.ACCOUNT_MIRROR
  }

  /**
   * 返回域 schema 版本（域未登记时为 1）。
   *
   * @returns schema 版本
   */
  private schemaVersion(): number {
    const spec: DomainSpec | null = this.spec()
    return spec === null ? 1 : spec.schemaVersion
  }

  /**
   * 从落盘对象中解析出条目数组（**只校验结构，不校验账号归属**）。
   *
   * @param saved - 落盘对象
   * @returns 条目数组；结构非法时返回 null
   */
  private structuralItems(saved: Object | null): Object[] | null {
    if (saved === null || saved === undefined || typeof saved !== 'object' || Array.isArray(saved)) {
      return null
    }
    const record: Record<string, Object> = saved as Record<string, Object>
    const rawPayload: Object | undefined = record['payload']
    if (rawPayload !== undefined && rawPayload !== null && typeof rawPayload === 'object' &&
      !Array.isArray(rawPayload)) {
      // ---- 新信封：{schemaVersion, domain, updatedAt, ownerUid, payload:{items}} ----
      const domain: string = String(record['domain'] ?? '')
      if (domain.length > 0 && domain !== this.domainId) {
        return null
      }
      const version: number = Number(record['schemaVersion'] ?? 0)
      if (!(version >= 1)) {
        return null
      }
      const payload: Record<string, Object> = rawPayload as Record<string, Object>
      const rawItems: Object | undefined = payload[ITEMS_KEY]
      return Array.isArray(rawItems) ? rawItems as Object[] : null
    }
    // ---- 兼容：迁移器搬运的裸载荷 {items:T[]} / 旧版信封 {schemaVersion,uid,items} ----
    const legacyItems: Object | undefined = record[ITEMS_KEY]
    return Array.isArray(legacyItems) ? legacyItems as Object[] : null
  }

  /**
   * 从落盘对象中解析出条目数组（结构 + 账号归属校验）。
   *
   * @param saved - 落盘对象
   * @param uid - 当前用户 ID（账号镜像域校验归属用；设备级域忽略）
   * @returns 条目数组；结构非法或归属不符时返回 null
   */
  private parseItems(saved: Object | null, uid: string): Object[] | null {
    const items: Object[] | null = this.structuralItems(saved)
    if (items === null || !this.isMirror()) {
      return items
    }
    const record: Record<string, Object> = saved as Record<string, Object>
    const rawPayload: Object | undefined = record['payload']
    const hasNewEnvelope: boolean = rawPayload !== undefined && rawPayload !== null &&
      typeof rawPayload === 'object' && !Array.isArray(rawPayload)
    // 新信封的归属字段是 ownerUid；兼容形态（旧信封/裸载荷）仍是 uid
    const ownerKey: string = hasNewEnvelope ? 'ownerUid' : 'uid'
    const ownerUid: string = String(record[ownerKey] ?? '')
    if (ownerUid.length > 0 && ownerUid !== uid) {
      return null
    }
    return items
  }

  /**
   * 判断缓存是否严格符合当前结构和账号归属。
   *
   * @param saved - 本地缓存对象
   * @param uid - 缓存所属用户 ID（账号镜像域校验用；设备级域忽略）
   * @returns 是否为有效缓存
   */
  isValidEnvelope(saved: Object | null, uid: string): boolean {
    const items: Object[] | null = this.parseItems(saved, uid)
    if (items === null) {
      return false
    }
    for (let index: number = 0; index < items.length; index++) {
      if (!this.validateItem(items[index])) {
        return false
      }
    }
    return true
  }

  /**
   * 宽容加载：信封级校验（结构 / 域名 / 归属）通过后，逐条校验并
   * **跳过坏条目**，而不是让一条坏数据把整封缓存判死。
   *
   * 用于「可重建、但丢失代价高」的数据（如 AI 会话）：一条字段缺失的记录
   * 不应该让其余 19 条会话一起消失。严格语义仍由 {@link load} 保留。
   *
   * @param store - 偏好存储
   * @param uid - 当前用户 ID
   * @returns 通过校验的 items；信封级非法时返回 null
   */
  async loadTolerant(store: PreferencesStore, uid: string): Promise<T[] | null> {
    const key: string = this.key(uid)
    if (key.length === 0) {
      return null
    }
    const saved: Object | null = await store.getJSON<Object>(key)
    const items: Object[] | null = this.parseItems(saved, uid)
    if (items === null) {
      return null
    }
    const valid: T[] = []
    for (let index: number = 0; index < items.length; index++) {
      if (this.validateItem(items[index])) {
        valid.push(items[index] as T)
      }
    }
    return valid
  }

  /**
   * 从已通过校验的信封中取出 items 数组副本。
   *
   * **不做账号归属校验**（归属校验在 {@link load} / {@link isValidEnvelope} 完成）；
   * 保留本方法是为了兼容既有单测与调试入口。
   *
   * @param saved - 已通过 isValidEnvelope 的缓存对象
   * @returns items 数组副本
   */
  extractItems(saved: Object): T[] {
    const items: Object[] | null = this.structuralItems(saved)
    return items === null ? [] : (items as T[]).slice()
  }

  /**
   * 加载当前域缓存；结构非法（信封/域名/归属/字段校验不通过）时返回 null，
   * 合法时返回 items 数组副本（可能为空数组，与"非法"严格区分）。
   *
   * @param store - 偏好存储
   * @param uid - 当前用户 ID
   * @returns items 数组；结构非法时返回 null
   */
  async load(store: PreferencesStore, uid: string): Promise<T[] | null> {
    const key: string = this.key(uid)
    if (key.length === 0) {
      return null
    }
    const saved: Object | null = await store.getJSON<Object>(key)
    // 只解析一次：结构 + 归属校验与条目抽取共用同一份结果，避免二次解析时丢失 uid 上下文
    const items: Object[] | null = this.parseItems(saved, uid)
    if (items === null) {
      return null
    }
    const valid: T[] = []
    for (let index: number = 0; index < items.length; index++) {
      if (!this.validateItem(items[index])) {
        return null
      }
      valid.push(items[index] as T)
    }
    return valid
  }

  /**
   * 将当前 items 快照写入当前域键（串行写队列 + 延迟刷盘）。
   *
   * 账号镜像域在未登录（uid 为空）时跳过写入：空 ownerUid 会让后续登录读取判非法，
   * 等于把缓存抹掉；设备级域不受账号影响，未登录也照常落盘。
   *
   * @param uid - 当前用户 ID（账号镜像域写入 ownerUid；设备级域忽略）
   * @param items - 待持久化的 items 快照
   * @param store - 偏好存储
   * @param queue - 串行写队列
   */
  persist(uid: string, items: T[], store: PreferencesStore, queue: SerialQueue): void {
    const key: string = this.key(uid)
    if (key.length === 0) {
      return
    }
    const mirror: boolean = this.isMirror()
    if (mirror && uid.length === 0) {
      return
    }
    const payload: Record<string, Object> = {}
    payload[ITEMS_KEY] = items.slice()
    const envelope: DomainEnvelope = new DomainEnvelope()
    envelope.schemaVersion = this.schemaVersion()
    envelope.domain = this.domainId
    envelope.updatedAt = Date.now()
    envelope.ownerUid = mirror ? uid : ''
    envelope.payload = payload
    const serializedSnapshot: string = JSON.stringify(envelope)
    queue.enqueue(async (): Promise<void> => {
      await store.putString(key, serializedSnapshot, false)
      store.scheduleFlush()
    })
  }
}
