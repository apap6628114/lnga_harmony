import { fetchFollowedActivity } from '../service/api/FollowApi'
import { BaseStore } from './BaseStore'
import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import {
  KEY_ACTIVITY_VERSION,
  KEY_UNREAD_ACTIVITY_COUNT
} from '../common/constants/AppStorageKeys'
import { bumpAppStorageVersion } from '../common/utils/AppStorageVersion'
import {
  appendDedupe,
  countUnseenActivities,
  markActivitiesSeenByIds,
  markAllActivitiesSeen,
  mergeActivities
} from '../common/utils/FollowActivityPolicy'
import { Logger, DOMAIN_STORE, formatError } from '../common/utils/Logger'
import type { FollowedActivity } from '../model/Follow'
import type { FollowedActivityListResult } from '../model/Follow'
import type { AuthState } from './AuthStore'

/** 动态缓存结构版本。 */
const ACTIVITY_CACHE_SCHEMA_VERSION: number = 2

/** 本地最多保留的动态数量（与通知缓存上限保持一致）。 */
const MAX_CACHED_ACTIVITIES: number = 200

/** 内存真源 displayActivities 的容量上限（首屏缓存 + 分页追加）。 */
const MAX_DISPLAY_ACTIVITIES: number = 10000

/** 普通刷新最短成功间隔。 */
const ACTIVITY_REFRESH_DELAY: number = 30 * 1000

/** 前台动态轮询间隔，与通知轮询保持一致。 */
const ACTIVITY_POLL_INTERVAL: number = 60 * 1000

/** 动态 Store 日志实例。 */
const logger: Logger = new Logger(DOMAIN_STORE, 'FollowActivityStore')

/**
 * 关注动态缓存信封。
 */
class FollowActivityCacheEnvelope {
  /** 缓存结构版本。 */
  schemaVersion: number = ACTIVITY_CACHE_SCHEMA_VERSION
  /** 缓存所属用户 ID。 */
  uid: string = ''
  /** 动态列表。 */
  items: FollowedActivity[] = []
  /** 最近更新时间。 */
  updatedAt: number = 0
}

/**
 * 关注动态缓存、本地已读状态与红点管理。
 *
 * 机制与 NotificationStore 对齐：
 * - 定时抓取：前台 60s 轮询
 * - 条件抓取：非强制刷新受 30s 最小成功间隔约束，并发调用复用同一请求
 * - 缓存：按账号隔离的偏好持久化信封（schemaVersion=2），仅保存 displayActivities
 *   前 200 条窗口快照；分页追加的后续页仅内存持有
 * - 红点：unreadActivityCount 写入 AppStorage，供入口角标/徽章展示
 *
 * 方案 C 数据流（displayActivities 为内存唯一真源）：
 * - displayActivities：首屏缓存 + 分页追加的全量内存列表（上限 10000），排序为
 *   timestamp 倒序 + id 稳定第二键；轮询/首屏合并后 bump activityVersion
 * - cachedActivities：displayActivities 前 200 条快照，仅作持久化窗口；每次成功的
 *   刷新/分页/已读操作都会同步窗口并落盘
 * - loadMoreActivities：store 内并发防护（loadingMore）+ 账号代际校验
 *   （generation/uid/token 三重校验），成功后尾部追加去重并 bump 版本驱动面板 appendAll
 * - 已读变化只更新未读数（不 bump 缓存版本），避免列表整体重建打断滚动
 */
export class FollowActivityStore extends BaseStore<Object> {
  /** BaseStore 状态占位对象。 */
  override state: Object = new Object()
  /** 未读动态数量。 */
  unreadActivityCount: number = 0
  /** 当前账号的本地动态缓存（持久化窗口 = displayActivities 前 200 条快照）。 */
  private cachedActivities: FollowedActivity[] = []
  /** 内存全量真源：首屏缓存 + 分页追加，上限 MAX_DISPLAY_ACTIVITIES。 */
  private displayActivities: FollowedActivity[] = []
  /** 已加载页数（首屏=1）。 */
  private loadedPages: number = 1
  /** 服务端总页数（0=未知/未确认）。 */
  private totalPages: number = 0
  /** 分页加载进行中（store 内并发防护）。 */
  private loadingMore: boolean = false
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
    this.cachedActivities = []
    this.displayActivities = []
    this.loadedPages = 1
    this.totalPages = 0
    this.loadingMore = false
    this.lastSuccessfulQueryTime = 0
    this.refreshPromise = null
    if (auth.uid) {
      await this.loadCachedActivities()
    } else {
      this.publishUnreadOnly()
    }
  }

  /**
   * 重置内存状态和全局红点。
   */
  reset(): void {
    this.stopPolling()
    this.cachedActivities = []
    this.displayActivities = []
    this.loadedPages = 1
    this.totalPages = 0
    this.loadingMore = false
    this.unreadActivityCount = 0
    this.lastSuccessfulQueryTime = 0
    this.refreshPromise = null
    AppStorage.setOrCreate(KEY_UNREAD_ACTIVITY_COUNT, 0)
    bumpAppStorageVersion(KEY_ACTIVITY_VERSION)
    super.reset()
  }

  /**
   * 启动前台动态轮询，并立即执行一次普通刷新。
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
    this.refreshActivities(false)
    this.scheduleNextPoll()
  }

  /**
   * 停止前台动态轮询。
   */
  stopPolling(): void {
    this.pollingEnabled = false
    if (this.pollingTimer >= 0) {
      clearTimeout(this.pollingTimer)
      this.pollingTimer = -1
    }
  }

  /**
   * 调度下一次前台动态刷新。
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
      this.refreshActivities(false)
      this.scheduleNextPoll()
    }, ACTIVITY_POLL_INTERVAL)
  }

  /**
   * 刷新关注动态；并发调用会复用同一请求。
   *
   * @param force - 是否忽略成功刷新间隔
   */
  async refreshActivities(force: boolean = false): Promise<boolean> {
    if (!this.auth || !this.auth.isAuthenticated || !this.auth.uid) {
      return false
    }
    if (this.refreshPromise) {
      return await this.refreshPromise
    }

    const now: number = Date.now()
    if (!force && now - this.lastSuccessfulQueryTime < ACTIVITY_REFRESH_DELAY) {
      return true
    }

    const requestGeneration: number = this.generationGuard.current()
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
   * 执行一次动态请求（page=1）并在身份仍有效时合并进 displayActivities。
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
      const result: FollowedActivityListResult = await fetchFollowedActivity(requestToken, 1)
      if (!this.isRequestCurrent(requestGeneration, requestUid, requestToken)) {
        return false
      }
      if (!result.ok) {
        logger.warn('动态刷新失败: %{public}s', result.error)
        return false
      }

      this.lastSuccessfulQueryTime = Date.now()
      if (result.pages > 0) {
        this.totalPages = result.pages
      }
      if (result.data.length === 0) {
        return true
      }

      // displayActivities 为内存唯一真源：合并去重、保留已读、timestamp 倒序 + id 稳定排序
      const previousIds: Set<string> = new Set<string>()
      for (let index: number = 0; index < this.displayActivities.length; index++) {
        previousIds.add(this.displayActivities[index].id)
      }
      this.displayActivities = mergeActivities(
        this.displayActivities,
        result.data,
        MAX_DISPLAY_ACTIVITIES
      )
      // 新 id 出现即视为有新动态（display 只增不减；用 id 集合判定而非长度比较，
      // 避免 10000 截断边界上长度不变但内容已变化时漏判）
      let hasNewActivity: boolean = false
      for (let index: number = 0; index < this.displayActivities.length; index++) {
        if (!previousIds.has(this.displayActivities[index].id)) {
          hasNewActivity = true
          break
        }
      }
      // 持久化窗口 = display 前 200 条快照；每次成功都落盘
      // （字段回填/截断也可能改变缓存内容，保证内存与磁盘一致）
      this.cachedActivities = this.displayActivities.slice(0, MAX_CACHED_ACTIVITIES)
      this.persistCachedActivities()
      if (hasNewActivity) {
        // 仅内容变化（出现新动态 id）时发布列表版本信号；
        // 轮询无新增时不打扰正在浏览的列表（避免深滚加载更多页被重建）
        this.publishDataState()
      } else {
        // 无新增也可能有字段回填，只同步未读数、不 bump 版本
        this.publishUnreadOnly()
      }
      return true
    } catch (error) {
      logger.warn('动态刷新异常: %{public}s', formatError(error as Object))
      return false
    }
  }

  /**
   * 加载关注动态下一页并追加进 displayActivities。
   *
   * 守卫与校验全部收敛在 store 内：并发防护（loadingMore）、总页数边界、
   * 账号代际校验（generation/uid/token 三重）；失败静默返回 false，
   * 滚动到底部可再次触发。成功后尾部追加去重（不做重排）并 bump 版本，
   * 驱动面板 appendAll 增量追加。
   *
   * @returns 分页是否成功追加
   */
  async loadMoreActivities(): Promise<boolean> {
    if (this.loadingMore) {
      return false
    }
    if (this.totalPages > 0 && this.loadedPages >= this.totalPages) {
      return false
    }
    if (!this.auth || !this.auth.isAuthenticated || !this.auth.uid) {
      return false
    }
    this.loadingMore = true
    const requestGeneration: number = this.generationGuard.current()
    const requestUid: string = this.auth.uid
    const requestToken: string = this.auth.token
    try {
      const result: FollowedActivityListResult = await fetchFollowedActivity(
        requestToken,
        this.loadedPages + 1
      )
      if (!this.isRequestCurrent(requestGeneration, requestUid, requestToken)) {
        return false
      }
      if (!result.ok) {
        logger.warn('动态分页加载失败: %{public}s', result.error)
        return false
      }
      this.loadedPages += 1
      if (result.pages > 0) {
        this.totalPages = result.pages
      }
      // 分页顺序追加去重，不重排（首屏排序由 mergeActivities 保证）
      this.displayActivities = appendDedupe(this.displayActivities, result.data)
      // 分页追加可能扩展持久化窗口（首屏不足 200 条时），同步窗口并落盘
      this.cachedActivities = this.displayActivities.slice(0, MAX_CACHED_ACTIVITIES)
      this.persistCachedActivities()
      // bump 版本信号驱动面板 appendAll（尾部追加不打断滚动）
      this.publishDataState()
      return true
    } catch (error) {
      logger.warn('动态分页加载异常: %{public}s', formatError(error as Object))
      return false
    } finally {
      this.loadingMore = false
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
   * 获取当前动态内存真源的只读数组快照（数组副本、元素与真源同引用）。
   *
   * @returns 动态数组快照
   */
  getDisplayActivities(): FollowedActivity[] {
    return this.displayActivities.slice()
  }

  /**
   * 获取当前动态缓存的只读数组快照（持久化窗口，兼容既有调用）。
   *
   * @returns 动态数组快照
   */
  getCachedActivities(): FollowedActivity[] {
    return this.cachedActivities.slice()
  }

  /**
   * 返回服务端总页数（0=未知/未确认）。
   *
   * @returns 总页数
   */
  getTotalPages(): number {
    return this.totalPages
  }

  /**
   * 返回已加载页数（首屏=1）。
   *
   * @returns 已加载页数
   */
  getLoadedPages(): number {
    return this.loadedPages
  }

  /**
   * 返回分页加载是否进行中。
   *
   * @returns 是否加载中
   */
  isLoadingMoreState(): boolean {
    return this.loadingMore
  }

  /**
   * 将指定 id 集合的动态标记为已读并持久化（不触发列表版本刷新）。
   *
   * @param ids - 需要标记为已读的动态 id 集合
   */
  markSeenByIds(ids: Set<string>): void {
    if (!markActivitiesSeenByIds(this.displayActivities, ids)) {
      return
    }
    this.cachedActivities = this.displayActivities.slice(0, MAX_CACHED_ACTIVITIES)
    this.publishUnreadOnly()
    this.persistCachedActivities()
  }

  /**
   * 将所有动态标记为已读并持久化。
   */
  markAllSeen(): void {
    if (!markAllActivitiesSeen(this.displayActivities)) {
      this.publishUnreadOnly()
      return
    }
    this.cachedActivities = this.displayActivities.slice(0, MAX_CACHED_ACTIVITIES)
    this.publishUnreadOnly()
    this.persistCachedActivities()
  }

  /**
   * 返回当前账号的动态缓存键。
   *
   * @returns 动态缓存键
   */
  private activitiesKey(): string {
    return `cached_activities_${this.auth.uid}`
  }

  /**
   * 加载动态缓存；旧格式或非法缓存直接覆盖为空。
   * 启动时无分页：displayActivities 以缓存窗口为起点，loadedPages=1、totalPages=0。
   */
  private async loadCachedActivities(): Promise<void> {
    const saved: Object | null = await this.store.getJSON<Object>(this.activitiesKey())
    if (!this.isValidCacheEnvelope(saved)) {
      this.cachedActivities = []
      this.displayActivities = []
      this.loadedPages = 1
      this.totalPages = 0
      this.publishUnreadOnly()
      this.persistCachedActivities()
      return
    }

    const savedRecord: Record<string, Object> = saved as Record<string, Object>
    this.cachedActivities = (savedRecord['items'] as FollowedActivity[]).slice()
    this.displayActivities = this.cachedActivities.slice()
    this.loadedPages = 1
    this.totalPages = 0
    this.publishUnreadOnly()
  }

  /**
   * 判断缓存是否严格符合当前结构版本和账号。
   *
   * @param saved - 本地缓存对象
   * @returns 是否为有效缓存
   */
  private isValidCacheEnvelope(saved: Object | null): boolean {
    if (!saved || typeof saved !== 'object' || Array.isArray(saved)) {
      return false
    }
    const record: Record<string, Object> = saved as Record<string, Object>
    if (Number(record['schemaVersion'] ?? 0) !== ACTIVITY_CACHE_SCHEMA_VERSION) {
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
      if (!this.isValidCachedActivity(items[index])) {
        return false
      }
    }
    return true
  }

  /**
   * 判断单条缓存动态是否具有必要字段。
   *
   * @param value - 缓存动态对象
   * @returns 是否有效
   */
  private isValidCachedActivity(value: Object): boolean {
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      return false
    }
    const record: Record<string, Object> = value as Record<string, Object>
    // 全字段类型校验：subject 等展示字段非 string 会在 unescapeHtml 崩溃，
    // 启动时宁可丢弃整条缓存也不能带病运行
    return typeof record['id'] === 'string' &&
      String(record['id']).length > 0 &&
      typeof record['type'] === 'number' &&
      typeof record['actorUid'] === 'string' &&
      typeof record['actorName'] === 'string' &&
      typeof record['tid'] === 'string' &&
      typeof record['pid'] === 'string' &&
      typeof record['fid'] === 'string' &&
      typeof record['subject'] === 'string' &&
      typeof record['timestamp'] === 'number' &&
      typeof record['replyTarget'] === 'string' &&
      typeof record['favorTableId'] === 'string' &&
      typeof record['summary'] === 'string' &&
      typeof record['seen'] === 'boolean'
  }

  /**
   * 数据合并后发布统一红点和缓存版本（驱动列表刷新）。
   */
  private publishDataState(): void {
    this.unreadActivityCount = countUnseenActivities(this.displayActivities)
    AppStorage.setOrCreate(KEY_UNREAD_ACTIVITY_COUNT, this.unreadActivityCount)
    bumpAppStorageVersion(KEY_ACTIVITY_VERSION)
  }

  /**
   * 仅已读变化时发布红点（不 bump 缓存版本，避免列表整体重建）。
   */
  private publishUnreadOnly(): void {
    this.unreadActivityCount = countUnseenActivities(this.displayActivities)
    AppStorage.setOrCreate(KEY_UNREAD_ACTIVITY_COUNT, this.unreadActivityCount)
  }

  /**
   * 将当前缓存窗口快照写入当前账号缓存键。
   */
  private persistCachedActivities(): void {
    if (!this.auth.uid) {
      return
    }
    const keySnapshot: string = this.activitiesKey()
    const envelope: FollowActivityCacheEnvelope = new FollowActivityCacheEnvelope()
    envelope.uid = this.auth.uid
    envelope.items = this.cachedActivities.slice()
    envelope.updatedAt = Date.now()
    const serializedSnapshot: string = JSON.stringify(envelope)
    this.writeQueue.enqueue(async (): Promise<void> => {
      await this.store.putString(keySnapshot, serializedSnapshot, false)
      this.store.scheduleFlush()
    })
  }
}
