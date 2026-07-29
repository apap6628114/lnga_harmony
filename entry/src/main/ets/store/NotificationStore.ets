import { clearNotifications, getNotifications } from '../service/api/MessageApi'
import { BaseStore } from './BaseStore'
import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import {
  KEY_NOTIFICATION_VERSION,
  KEY_UNREAD_MESSAGE_COUNT,
  KEY_UNREAD_NOTI_COUNT
} from '../common/constants/AppStorageKeys'
import { bumpAppStorageVersion } from '../common/utils/AppStorageVersion'
import {
  countUnseenMessageNotifications,
  countUnseenNotifications,
  isMessageNotificationType,
  markAllNotificationsSeen,
  markMessageNotificationsSeen,
  markNotificationSeen,
  mergeNotifications
} from '../common/utils/NotificationPolicy'
import { Logger, DOMAIN_STORE, formatError } from '../common/utils/Logger'
import type { NgaNotification } from '../model/Notification'
import type { NotificationsResult } from '../model/NgaApiResults'
import type { AuthState } from './AuthStore'

/** 通知缓存结构版本。 */
const NOTIFICATION_CACHE_SCHEMA_VERSION: number = 3

/** 本地最多保留的通知数量。 */
const MAX_CACHED_NOTIFICATIONS: number = 200

/** 普通刷新最短成功间隔。 */
const NOTIFICATION_REFRESH_DELAY: number = 30 * 1000

/** 前台通知轮询间隔，与 MNGA 的发布配置保持一致。 */
const NOTIFICATION_POLL_INTERVAL: number = 60 * 1000

/** 通知 Store 日志实例。 */
const logger: Logger = new Logger(DOMAIN_STORE, 'NotificationStore')

/**
 * 新版通知缓存信封。
 */
class NotificationCacheEnvelope {
  /** 缓存结构版本。 */
  schemaVersion: number = NOTIFICATION_CACHE_SCHEMA_VERSION
  /** 缓存所属用户 ID。 */
  uid: string = ''
  /** 标准化通知列表。 */
  items: NgaNotification[] = []
  /** 最近更新时间。 */
  updatedAt: number = 0
}

/**
 * 通知缓存、本地查看状态与红点管理。
 */
export class NotificationStore extends BaseStore<Object> {
  /** BaseStore 状态占位对象。 */
  override state: Object = new Object()
  /** 全部未查看通知数量。 */
  unreadNotiCount: number = 0
  /** 未查看私信通知数量。 */
  unreadMessageCount: number = 0
  /** 当前账号的本地通知缓存。 */
  private cachedNotifications: NgaNotification[] = []
  /** 上一次成功刷新时间。 */
  private lastSuccessfulQueryTime: number = 0
  /** 当前正在执行的刷新任务。 */
  private refreshPromise: Promise<boolean> | null = null
  /** 前台轮询定时器。 */
  private pollingTimer: number = -1
  /** 是否允许继续调度前台轮询。 */
  private pollingEnabled: boolean = false

  /**
   * 注入持久化、写队列和认证依赖并加载当前账号缓存。
   *
   * @param store - 偏好存储
   * @param queue - 串行写队列
   * @param auth - 当前认证状态
   */
  async init(store: PreferencesStore, queue: SerialQueue, auth: AuthState): Promise<void> {
    this.stopPolling()
    this.setDeps(store, queue, auth)
    this.cachedNotifications = []
    this.lastSuccessfulQueryTime = 0
    this.refreshPromise = null
    if (auth.uid) {
      await this.loadCachedNotifications()
    } else {
      this.publishState()
    }
  }

  /**
   * 重置内存状态和全局红点。
   */
  reset(): void {
    this.stopPolling()
    this.cachedNotifications = []
    this.unreadNotiCount = 0
    this.unreadMessageCount = 0
    this.lastSuccessfulQueryTime = 0
    this.refreshPromise = null
    AppStorage.setOrCreate(KEY_UNREAD_NOTI_COUNT, 0)
    AppStorage.setOrCreate(KEY_UNREAD_MESSAGE_COUNT, 0)
    bumpAppStorageVersion(KEY_NOTIFICATION_VERSION)
    super.reset()
  }

  /**
   * 启动前台通知轮询，并立即执行一次普通刷新。
   */
  startPolling(): void {
    if (!this.auth || !this.auth.isAuthenticated || !this.auth.uid) {
      this.stopPolling()
      return
    }
    if (this.pollingEnabled) {
      return
    }
    this.pollingEnabled = true
    this.refreshNotifications(false)
    this.scheduleNextPoll()
  }

  /**
   * 停止前台通知轮询。
   */
  stopPolling(): void {
    this.pollingEnabled = false
    if (this.pollingTimer >= 0) {
      clearTimeout(this.pollingTimer)
      this.pollingTimer = -1
    }
  }

  /**
   * 调度下一次前台通知刷新。
   */
  private scheduleNextPoll(): void {
    if (!this.pollingEnabled || this.pollingTimer >= 0) {
      return
    }
    this.pollingTimer = setTimeout((): void => {
      this.pollingTimer = -1
      if (!this.pollingEnabled) {
        return
      }
      this.refreshNotifications(false)
      this.scheduleNextPoll()
    }, NOTIFICATION_POLL_INTERVAL)
  }

  /**
   * 兼容既有调用的普通通知刷新入口。
   */
  async refreshUnreadCount(): Promise<void> {
    await this.refreshNotifications(false)
  }

  /**
   * 刷新通知；并发调用会复用同一请求。
   *
   * @param force - 是否忽略成功刷新间隔
   */
  async refreshNotifications(force: boolean = false): Promise<boolean> {
    if (!this.auth || !this.auth.isAuthenticated || !this.auth.uid) {
      return false
    }
    if (this.refreshPromise) {
      return await this.refreshPromise
    }

    const now: number = Date.now()
    if (!force && now - this.lastSuccessfulQueryTime < NOTIFICATION_REFRESH_DELAY) {
      return true
    }

    const requestGeneration: number = this.generation
    const requestUid: string = this.auth.uid
    const requestToken: string = this.auth.token
    const task: Promise<boolean> = this.performRefresh(requestGeneration, requestUid, requestToken)
    this.refreshPromise = task
    try {
      return await task
    } finally {
      if (this.refreshPromise === task) {
        this.refreshPromise = null
      }
    }
  }

  /**
   * 执行一次通知请求并在身份仍有效时合并结果。
   *
   * @param requestGeneration - 请求发起时的 Store generation
   * @param requestUid - 请求发起时的用户 ID
   * @param requestToken - 请求发起时的认证 token
   */
  private async performRefresh(
    requestGeneration: number,
    requestUid: string,
    requestToken: string
  ): Promise<boolean> {
    try {
      const result: NotificationsResult = await getNotifications(requestToken)
      if (!this.isRequestCurrent(requestGeneration, requestUid, requestToken)) {
        return false
      }
      if (!result.ok) {
        logger.warn('通知刷新失败: %{public}s', result.error)
        return false
      }

      this.lastSuccessfulQueryTime = Date.now()
      if (result.malformedCount > 0 || result.unsupportedCount > 0) {
        logger.warn(
          '通知解析存在异常: malformed=%{public}d unsupported=%{public}d',
          result.malformedCount,
          result.unsupportedCount
        )
      }
      if (result.data.length === 0) {
        return true
      }

      this.cachedNotifications = mergeNotifications(
        this.cachedNotifications,
        result.data,
        MAX_CACHED_NOTIFICATIONS
      )
      this.publishState()
      this.persistCachedNotifications()
      return true
    } catch (error) {
      logger.warn('通知刷新异常: %{public}s', formatError(error as Object))
      return false
    }
  }

  /**
   * 判断异步请求是否仍属于当前账号和当前 Store 生命周期。
   *
   * @param requestGeneration - 请求发起时的 Store generation
   * @param requestUid - 请求发起时的用户 ID
   * @param requestToken - 请求发起时的认证 token
   * @returns 请求是否仍可回写
   */
  private isRequestCurrent(
    requestGeneration: number,
    requestUid: string,
    requestToken: string
  ): boolean {
    return this.isCurrent(requestGeneration) &&
      this.auth.uid === requestUid &&
      this.auth.token === requestToken &&
      this.auth.isAuthenticated
  }

  /**
   * 获取当前通知缓存的只读数组快照。
   *
   * @returns 通知数组快照
   */
  getCachedNotifications(): NgaNotification[] {
    return this.cachedNotifications.slice()
  }

  /**
   * 将指定通知标记为已查看并持久化。
   *
   * @param notificationId - 本地稳定通知 ID
   */
  markSeen(notificationId: string): void {
    if (!markNotificationSeen(this.cachedNotifications, notificationId)) {
      return
    }
    this.publishState()
    this.persistCachedNotifications()
  }

  /**
   * 将全部通知标记为已查看。
   */
  markAllSeen(): void {
    if (!markAllNotificationsSeen(this.cachedNotifications)) {
      this.publishState()
      return
    }
    this.publishState()
    this.persistCachedNotifications()
  }

  /**
   * 将私信类通知标记为已查看。
   */
  markMessagesSeen(): void {
    if (!markMessageNotificationsSeen(this.cachedNotifications)) {
      this.publishState()
      return
    }
    this.publishState()
    this.persistCachedNotifications()
  }

  /**
   * 请求服务端清空通知，成功后再清空本地状态。
   *
   * @returns 是否清空成功
   */
  async clearAllNotifications(): Promise<boolean> {
    if (!this.auth || !this.auth.isAuthenticated || !this.auth.uid) {
      return false
    }
    const requestGeneration: number = this.generation
    const requestUid: string = this.auth.uid
    const requestToken: string = this.auth.token
    try {
      const result = await clearNotifications(requestToken)
      if (!this.isRequestCurrent(requestGeneration, requestUid, requestToken)) {
        return false
      }
      if (!result.ok) {
        logger.warn('清空通知失败: %{public}s', result.error)
        return false
      }
      this.generation++
      this.refreshPromise = null
      this.cachedNotifications = []
      this.publishState()
      this.persistCachedNotifications()
      return true
    } catch (error) {
      logger.warn('清空通知异常: %{public}s', formatError(error as Object))
      return false
    }
  }

  /**
   * 返回当前账号的通知缓存键。
   *
   * @returns 通知缓存键
   */
  private notificationsKey(): string {
    return `cached_notifications_${this.auth.uid}`
  }

  /**
   * 加载新版缓存；旧格式或非法缓存直接覆盖为空。
   */
  private async loadCachedNotifications(): Promise<void> {
    const saved: Object | null = await this.store.getJSON<Object>(this.notificationsKey())
    if (!this.isValidCacheEnvelope(saved)) {
      this.cachedNotifications = []
      this.publishState()
      this.persistCachedNotifications()
      return
    }

    const savedRecord: Record<string, Object> = saved as Record<string, Object>
    this.cachedNotifications = (savedRecord['items'] as NgaNotification[]).slice()
    this.publishState()
  }

  /**
   * 判断缓存是否严格符合当前结构版本和账号。
   *
   * @param saved - 本地缓存对象
   * @returns 是否为有效新版缓存
   */
  private isValidCacheEnvelope(saved: Object | null): boolean {
    if (!saved || typeof saved !== 'object' || Array.isArray(saved)) {
      return false
    }
    const record: Record<string, Object> = saved as Record<string, Object>
    if (Number(record['schemaVersion'] ?? 0) !== NOTIFICATION_CACHE_SCHEMA_VERSION) {
      return false
    }
    if (String(record['uid'] ?? '') !== this.auth.uid) {
      return false
    }
    const rawItems: Object | undefined = record['items']
    if (!Array.isArray(rawItems)) {
      return false
    }
    const items: Object[] = rawItems as Object[]
    for (let index: number = 0; index < items.length; index++) {
      if (!this.isValidCachedNotification(items[index])) {
        return false
      }
    }
    return true
  }

  /**
   * 判断单条缓存通知是否具有新版必要字段。
   *
   * @param value - 缓存通知对象
   * @returns 是否有效
   */
  private isValidCachedNotification(value: Object): boolean {
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      return false
    }
    const record: Record<string, Object> = value as Record<string, Object>
    const commonFieldsValid: boolean = typeof record['notificationId'] === 'string' &&
      String(record['notificationId']).length > 0 &&
      typeof record['type'] === 'number' &&
      typeof record['userId'] === 'string' &&
      typeof record['userName'] === 'string' &&
      typeof record['title'] === 'string' &&
      typeof record['timeStamp'] === 'string' &&
      typeof record['seen'] === 'boolean' &&
      typeof record['serverUnreadHint'] === 'number'
    if (!commonFieldsValid) {
      return false
    }
    const type: number = Number(record['type'])
    if (isMessageNotificationType(type)) {
      return typeof record['mid'] === 'string' && String(record['mid']).length > 0
    }
    if (type === 17) {
      return typeof record['tid'] === 'string' && String(record['tid']).length > 0 &&
        typeof record['pid'] === 'string' && String(record['pid']).length > 0 &&
        typeof record['page'] === 'string'
    }
    if (type === 1 || type === 2 || type === 7 || type === 8) {
      return typeof record['tid'] === 'string' && String(record['tid']).length > 0 &&
        typeof record['replyPid'] === 'string' && String(record['replyPid']).length > 0 &&
        typeof record['repliedPid'] === 'string' &&
        typeof record['page'] === 'string'
    }
    return false
  }

  /**
   * 发布统一红点和通知版本。
   */
  private publishState(): void {
    this.unreadNotiCount = countUnseenNotifications(this.cachedNotifications)
    this.unreadMessageCount = countUnseenMessageNotifications(this.cachedNotifications)
    AppStorage.setOrCreate(KEY_UNREAD_NOTI_COUNT, this.unreadNotiCount)
    AppStorage.setOrCreate(KEY_UNREAD_MESSAGE_COUNT, this.unreadMessageCount)
    bumpAppStorageVersion(KEY_NOTIFICATION_VERSION)
  }

  /**
   * 将当前缓存快照写入当前账号缓存键。
   */
  private persistCachedNotifications(): void {
    if (!this.auth.uid) {
      return
    }
    const keySnapshot: string = this.notificationsKey()
    const envelope: NotificationCacheEnvelope = new NotificationCacheEnvelope()
    envelope.uid = this.auth.uid
    envelope.items = this.cachedNotifications.slice()
    envelope.updatedAt = Date.now()
    const serializedSnapshot: string = JSON.stringify(envelope)
    this.writeQueue.enqueue(async (): Promise<void> => {
      await this.store.putString(keySnapshot, serializedSnapshot, false)
      this.store.scheduleFlush()
    })
  }
}
