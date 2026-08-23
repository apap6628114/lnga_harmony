import { getNotifications } from '../service/api/MessageApi'
import { BaseStore } from './BaseStore'
import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { PollingController } from '../common/concurrency/PollingController'
import { CacheEnvelopeStore } from '../common/infra/CacheEnvelopeStore'
import {
  KEY_NOTIFICATION_VERSION,
  KEY_UNREAD_MESSAGE_COUNT,
  KEY_UNREAD_NOTI_COUNT
} from '../common/constants/AppStorageKeys'
import { bumpAppStorageVersion } from '../common/utils/AppStorageVersion'
import {
  countUnseenMessageNotifications,
  countUnseenNonMessageNotifications,
  filterNonMessageNotifications,
  isMessageNotificationType,
  markMessageNotificationsSeen,
  markMessageNotificationsSeenByMid,
  markNonMessageNotificationsSeen,
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

/** 前台通知轮询间隔（调整为 300s，降低高频轮询被服务端风控的风险）。 */
const NOTIFICATION_POLL_INTERVAL: number = 300 * 1000

/** 通知 Store 日志实例。 */
const logger: Logger = new Logger(DOMAIN_STORE, 'NotificationStore')

/**
 * 通知缓存、本地查看状态与红点管理。
 *
 * 机制（与 FollowActivityStore 共用同一套骨架）：
 * - 定时抓取：前台 300s 轮询（PollingController 调度）
 * - 条件抓取：非强制刷新受 30s 最小成功间隔约束，并发调用复用同一请求
 *   （runGuardedRefresh 统一协调）
 * - 缓存：按账号隔离的偏好持久化信封（CacheEnvelopeStore，schemaVersion=3），
 *   上限 200 条
 * - 有效性：请求回写前做 generation/uid/token 四重校验（BaseStore.isRequestCurrent）
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
  /** 前台轮询调度器（start 立即刷新一次 + 定时重复，普通刷新自带节流与并发复用）。 */
  private pollingController!: PollingController
  /** 按账号隔离的缓存信封工具（校验 / 加载 / 落盘统一封装）。 */
  private cacheEnvelope!: CacheEnvelopeStore<NgaNotification>

  constructor() {
    super()
    this.pollingController = new PollingController(NOTIFICATION_POLL_INTERVAL, (): void => {
      this.refreshNotifications(false)
    })
    this.cacheEnvelope = new CacheEnvelopeStore<NgaNotification>(
      NOTIFICATION_CACHE_SCHEMA_VERSION,
      'cached_notifications',
      (value: Object): boolean => isValidCachedNotification(value)
    )
  }

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
    this.clearRefreshState()
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
    this.pollingController.start()
  }

  /**
   * 停止前台通知轮询。
   */
  stopPolling(): void {
    this.pollingController.stop()
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
    return this.runGuardedRefresh(force, NOTIFICATION_REFRESH_DELAY,
      (generation: number, uid: string, token: string): Promise<boolean> =>
        this.performRefresh(generation, uid, token))
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
   * 获取当前通知缓存的只读数组快照。
   *
   * @returns 通知数组快照
   */
  getCachedNotifications(): NgaNotification[] {
    return this.cachedNotifications.slice()
  }

  /**
   * 获取当前通知缓存中非私信通知的只读数组快照。
   *
   * 消息 Tab 仅展示非私信通知；私信通知保留在缓存中作为私信未读数
   * 与私信 Tab 会话行已读（可索引 ID）的数据源。
   *
   * @returns 非私信通知数组快照
   */
  getCachedNonMessageNotifications(): NgaNotification[] {
    return filterNonMessageNotifications(this.cachedNotifications)
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
   * 将全部非私信通知标记为已查看（消息 Tab 全部已读不波及私信通知）。
   */
  markNonMessageSeen(): void {
    if (!markNonMessageNotificationsSeen(this.cachedNotifications)) {
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
   * 将指定会话（mid）的私信通知标记为已查看。
   *
   * 私信 Tab 会话行点击时调用：按可索引 ID（notificationId 内含 mid）
   * 精确标记该会话对应的私信通知，不波及其它会话。
   * 无状态变化（该会话通知已全部已读）时不发布任何信号。
   *
   * @param mid - 私信会话 ID
   */
  markMessagesSeenByMid(mid: string): void {
    if (!markMessageNotificationsSeenByMid(this.cachedNotifications, mid)) {
      return
    }
    this.publishState()
    this.persistCachedNotifications()
  }

  /**
   * 加载新版缓存；旧格式或非法缓存直接覆盖为空。
   */
  private async loadCachedNotifications(): Promise<void> {
    const items: NgaNotification[] | null = await this.cacheEnvelope.load(this.store, this.auth.uid)
    if (items === null) {
      this.cachedNotifications = []
      this.publishState()
      this.persistCachedNotifications()
      return
    }

    this.cachedNotifications = items
    this.publishState()
  }

  /**
   * 发布统一红点和通知版本。
   *
   * unreadNotiCount 语义为「非私信通知未读数」（消息 Tab 角标与铃铛计数）；
   * 私信未读数独立由 unreadMessageCount 承载。
   */
  private publishState(): void {
    this.unreadNotiCount = countUnseenNonMessageNotifications(this.cachedNotifications)
    this.unreadMessageCount = countUnseenMessageNotifications(this.cachedNotifications)
    AppStorage.setOrCreate(KEY_UNREAD_NOTI_COUNT, this.unreadNotiCount)
    AppStorage.setOrCreate(KEY_UNREAD_MESSAGE_COUNT, this.unreadMessageCount)
    bumpAppStorageVersion(KEY_NOTIFICATION_VERSION)
  }

  /**
   * 将当前缓存快照写入当前账号缓存键（委托缓存信封工具落盘）。
   */
  private persistCachedNotifications(): void {
    this.cacheEnvelope.persist(this.auth.uid, this.cachedNotifications, this.store, this.writeQueue)
  }
}

/**
 * 判断单条缓存通知是否具有新版必要字段。
 *
 * @param value - 缓存通知对象
 * @returns 是否有效
 */
function isValidCachedNotification(value: Object): boolean {
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
