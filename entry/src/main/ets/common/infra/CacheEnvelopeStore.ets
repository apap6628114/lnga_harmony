import { PreferencesStore } from './PreferencesStore'
import { SerialQueue } from './SerialQueue'

/**
 * 缓存信封（泛型 item 容器）。
 */
class CacheEnvelope<T> {
  schemaVersion: number = 0
  uid: string = ''
  items: T[] = []
  updatedAt: number = 0
}

/**
 * 按账号隔离的偏好持久化缓存信封工具 — 统一「校验 / 加载 / 落盘」机制。
 *
 * NotificationStore 与 FollowActivityStore 的本地缓存共用同一信封结构
 * {schemaVersion, uid, items, updatedAt} 与同一套处理语义：
 * - 严格校验：结构版本 + 账号归属 + 逐条字段类型校验，任一不满足即视为非法
 *   （由调用方决定整体清空兜底，本工具不负责业务状态复位）；
 * - 落盘：串行写队列 enqueue → putString(flush=false) → scheduleFlush，与既有实现一致。
 *
 * schemaVersion 与单条校验规则由各 Store 自行传入（结构演进互不影响），
 * 泛型 T 解耦了业务字段差异（通知以 notificationId 为 id、动态以 id 为 id 等）。
 */
export class CacheEnvelopeStore<T> {
  /** 缓存结构版本（各 Store 独立演进）。 */
  private readonly schemaVersion: number
  /** 缓存键前缀（最终键形如 `${keyPrefix}_${uid}`）。 */
  private readonly keyPrefix: string
  /** 单条缓存项的字段类型校验规则（由各 Store 提供）。 */
  private readonly validateItem: (value: Object) => boolean

  /**
   * 构造缓存信封工具。
   *
   * @param schemaVersion - 缓存结构版本
   * @param keyPrefix - 缓存键前缀
   * @param validateItem - 单条缓存项校验函数
   */
  constructor(schemaVersion: number, keyPrefix: string, validateItem: (value: Object) => boolean) {
    this.schemaVersion = schemaVersion
    this.keyPrefix = keyPrefix
    this.validateItem = validateItem
  }

  /**
   * 返回当前账号的缓存键。
   *
   * @param uid - 用户 ID
   * @returns 缓存键
   */
  key(uid: string): string {
    return `${this.keyPrefix}_${uid}`
  }

  /**
   * 判断缓存是否严格符合当前结构版本和账号。
   *
   * @param saved - 本地缓存对象
   * @param uid - 缓存所属用户 ID
   * @returns 是否为有效缓存
   */
  isValidEnvelope(saved: Object | null, uid: string): boolean {
    if (!saved || typeof saved !== 'object' || Array.isArray(saved)) {
      return false
    }
    const record: Record<string, Object> = saved as Record<string, Object>
    if (Number(record['schemaVersion'] ?? 0) !== this.schemaVersion) {
      return false
    }
    if (String(record['uid'] ?? '') !== uid) {
      return false
    }
    const rawItems: Object | undefined = record['items']
    if (!Array.isArray(rawItems)) {
      return false
    }
    const items: Object[] = rawItems as Object[]
    for (let index: number = 0; index < items.length; index++) {
      if (!this.validateItem(items[index])) {
        return false
      }
    }
    return true
  }

  /**
   * 从已通过校验的信封中取出 items 数组副本。
   *
   * @param saved - 已通过 isValidEnvelope 的信封对象
   * @returns items 数组副本
   */
  extractItems(saved: Object): T[] {
    const record: Record<string, Object> = saved as Record<string, Object>
    return (record['items'] as T[]).slice()
  }

  /**
   * 加载当前账号缓存；信封非法（结构/账号/字段校验不通过）时返回 null，
   * 合法时返回 items 数组副本（可能为空数组，与"非法"严格区分）。
   *
   * @param store - 偏好存储
   * @param uid - 缓存所属用户 ID
   * @returns items 数组；信封非法时返回 null
   */
  async load(store: PreferencesStore, uid: string): Promise<T[] | null> {
    const saved: Object | null = await store.getJSON<Object>(this.key(uid))
    if (!this.isValidEnvelope(saved, uid)) {
      return null
    }
    return this.extractItems(saved as Object)
  }

  /**
   * 将当前 items 快照写入当前账号缓存键（串行写队列 + 延迟刷盘）。
   *
   * @param uid - 缓存所属用户 ID
   * @param items - 待持久化的 items 快照
   * @param store - 偏好存储
   * @param queue - 串行写队列
   */
  persist(uid: string, items: T[], store: PreferencesStore, queue: SerialQueue): void {
    if (!uid) {
      return
    }
    const keySnapshot: string = this.key(uid)
    const envelope: CacheEnvelope<T> = new CacheEnvelope<T>()
    envelope.schemaVersion = this.schemaVersion
    envelope.uid = uid
    envelope.items = items.slice()
    envelope.updatedAt = Date.now()
    const serializedSnapshot: string = JSON.stringify(envelope)
    queue.enqueue(async (): Promise<void> => {
      await store.putString(keySnapshot, serializedSnapshot, false)
      store.scheduleFlush()
    })
  }
}
