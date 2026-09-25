/**
 * 跟踪帖子 Store — 跟踪任务管理、定时检查、未读红点与失效清理。
 *
 * 机制与 NotificationStore / FollowActivityStore 对齐（共用同一套骨架）：
 * - 定时抓取：前台 10 分钟轮询（PollingController 调度），一轮内逐帖串行检查、
 *   帖间留 {@link TRACK_CHECK_GAP} 间隔，避免请求突发触发风控；
 * - 条件抓取：非强制刷新受 30s 最小成功间隔约束，并发调用复用同一请求
 *   （BaseStore.runGuardedRefresh 统一协调）；全量检查另有 refreshing 并发闸门；
 * - 缓存：按账号隔离的偏好持久化信封（CacheEnvelopeStore）；
 * - 红点：unreadTrackCount 写入 AppStorage，供「跟踪」Tab 角标与入口铃铛合并计数；
 * - 有效性：请求回写前做 generation/uid/token 四重校验（BaseStore.isRequestCurrent）。
 *
 * 三个停止出口（见 TrackStopReason）：帖子失效、满 keepDays 天无新回复、用户主动移除。
 * 前两者移除后经 onStopNotice 交给 AppStore 弹 Toast；网络失败只累计 failCount，
 * 绝不停止跟踪（避免断网期间把跟踪列表清空）。
 *
 * 检查**只认总回复数增加**：首次成功检查只建立基准（seenReplies = totalReplies），
 * 不产生红点；删除楼层导致回复数减少时同步基准、不报更新。
 */

import { BaseStore } from './BaseStore'
import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { PollingController } from '../common/concurrency/PollingController'
import { CacheEnvelopeStore } from '../common/infra/CacheEnvelopeStore'
import { bumpAppStorageVersion } from '../common/utils/AppStorageVersion'
import { KEY_TRACKED_THREAD_VERSION, KEY_UNREAD_TRACK_COUNT } from '../common/constants/AppStorageKeys'
import {
  applyStatus,
  countUnreadTracked,
  isValidCachedTrackedThread,
  sortTrackedThreads,
  TrackApplyOutcome
} from '../common/utils/ThreadTrackPolicy'
import { fetchThreadTrackStatus } from '../service/api/ThreadTrackApi'
import { Logger, DOMAIN_STORE, formatError } from '../common/utils/Logger'
import {
  TrackedThread,
  ThreadTrackStatus,
  TrackStopNotice,
  TRACK_CHECK_GAP,
  TRACK_DEFAULT_KEEP_DAYS,
  TRACK_MAX_COUNT,
  TRACK_MIN_CHECK_INTERVAL,
  TRACK_POLL_INTERVAL
} from '../model/TrackedThread'
import type { AuthState } from './AuthStore'

/** 跟踪缓存结构版本。v2：新增 `seenLastPostTs`（已读时的服务端最后回复时间）。 */
const TRACKED_THREAD_SCHEMA_VERSION: number = 2

/** 全量检查的最短成功间隔（前台轮询按此节流；本功能无下拉刷新入口）。 */
const TRACK_REFRESH_DELAY: number = 30 * 1000

const logger: Logger = new Logger(DOMAIN_STORE, 'TrackedThreadStore')

/** 新增/更新跟踪任务的入参。 */
export class TrackRequest {
  /** NGA 主题 ID。 */
  tid: string = ''
  /** 主题标题（调用方已知时传入，未知留空由检查回填）。 */
  subject: string = ''
  /** 楼主昵称。 */
  author: string = ''
  /** 楼主用户 ID。 */
  authorid: number = 0
  /** 版块 ID。 */
  fid: number = 0
  /** 版块名。 */
  forumName: string = ''
  /** 跟踪时长（天）。 */
  keepDays: number = TRACK_DEFAULT_KEEP_DAYS
}

/** 新增/更新跟踪任务的结果。 */
export class TrackResult {
  /** 是否成功。 */
  ok: boolean = false
  /** 是否新建（false 表示更新了已有跟踪的天数）。 */
  created: boolean = false
  /** 失败原因。 */
  error: string = ''
}

/**
 * 等待指定毫秒（一轮检查中帖间留白用）。
 *
 * @param ms - 等待时长
 */
function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms)
  })
}

export class TrackedThreadStore extends BaseStore<Object> {
  /** BaseStore 状态占位对象。 */
  override state: Object = new Object()
  /** 有未读更新的跟踪任务数（红点与角标）。 */
  unreadTrackCount: number = 0
  /**
   * 停止跟踪通知回调（由 AppStore 注入为 Toast）。
   *
   * 只承载「帖子失效」「长期无新回复」两种自动停止；用户主动移除不通知。
   */
  onStopNotice?: (notice: TrackStopNotice) => void

  /** 跟踪任务列表（内存真源，未排序）。 */
  private items: TrackedThread[] = []
  /** 前台轮询调度器。 */
  private pollingController!: PollingController
  /** 按账号隔离的缓存信封工具。 */
  private cacheEnvelope!: CacheEnvelopeStore<TrackedThread>
  /** 全量检查并发闸门。 */
  private refreshing: boolean = false
  /** 单帖检查在途集合（同一 tid 的检查互斥，见 refreshOne）。 */
  private checkingTids: Set<string> = new Set<string>()

  constructor() {
    super()
    // 轮询回调丢弃 Promise 也必须兜住异常：否则一次意外异常会变成未处理的 Promise 拒绝，
    // 且 PollingController 的下一轮调度无法自愈
    this.pollingController = new PollingController(TRACK_POLL_INTERVAL, (): void => {
      this.refresh(false).catch((error: Object): void => {
        logger.warn('跟踪轮询异常: %{public}s', formatError(error))
      })
    })
    this.cacheEnvelope = new CacheEnvelopeStore<TrackedThread>(
      TRACKED_THREAD_SCHEMA_VERSION,
      'tracked_threads',
      (value: Object): boolean => isValidCachedTrackedThread(value)
    )
  }

  /**
   * 注入持久化、写队列和认证依赖并加载当前账号的跟踪列表。
   *
   * @param store - 偏好存储
   * @param queue - 串行写队列
   * @param auth - 当前认证状态
   */
  async init(store: PreferencesStore, queue: SerialQueue, auth: AuthState): Promise<void> {
    this.stopPolling()
    this.setDeps(store, queue, auth)
    this.items = []
    this.refreshing = false
    this.checkingTids.clear()
    this.clearRefreshState()
    if (auth.uid) {
      await this.loadCachedItems()
    } else {
      this.publishUnread()
    }
  }

  /**
   * 重置内存状态与全局红点。
   */
  reset(): void {
    this.stopPolling()
    this.items = []
    this.unreadTrackCount = 0
    this.refreshing = false
    this.checkingTids.clear()
    AppStorage.setOrCreate(KEY_UNREAD_TRACK_COUNT, 0)
    bumpAppStorageVersion(KEY_TRACKED_THREAD_VERSION)
    super.reset()
  }

  /**
   * 启动前台跟踪轮询（启动即执行一次检查）。
   */
  startPolling(): void {
    if (!this.auth || !this.auth.isAuthenticated || !this.auth.uid) {
      this.stopPolling()
      return
    }
    this.pollingController.start()
  }

  /**
   * 停止前台跟踪轮询。
   */
  stopPolling(): void {
    this.pollingController.stop()
  }

  // ==================== 查询 ====================

  /**
   * 跟踪任务快照（有未读的排前，其次按最后活动时间倒序）。
   *
   * @returns 排序后的新数组
   */
  getItems(): TrackedThread[] {
    return sortTrackedThreads(this.items)
  }

  /**
   * 跟踪任务数量。
   *
   * @returns 数量
   */
  count(): number {
    return this.items.length
  }

  /**
   * 按 tid 取跟踪任务。
   *
   * @param tid - NGA 主题 ID
   * @returns 跟踪任务；未跟踪时返回 null
   */
  getByTid(tid: string): TrackedThread | null {
    for (let index: number = 0; index < this.items.length; index++) {
      if (this.items[index].tid === tid) {
        return this.items[index]
      }
    }
    return null
  }

  /**
   * 该帖子是否正在跟踪。
   *
   * @param tid - NGA 主题 ID
   * @returns 是否已跟踪
   */
  isTracked(tid: string): boolean {
    return this.getByTid(tid) !== null
  }

  /**
   * 是否还能新增跟踪任务。
   *
   * @returns 未达上限时为 true
   */
  canTrackMore(): boolean {
    return this.items.length < TRACK_MAX_COUNT
  }

  // ==================== 增删 ====================

  /**
   * 新增或更新跟踪任务。
   *
   * 已跟踪同一帖子时只更新跟踪天数（用户重新打开对话框改天数保存的场景），
   * 不影响已读基准与未读状态。新增成功后立即异步做一次检查建立基准，
   * 使列表尽快显示真实回复数与剩余天数。
   *
   * @param request - 跟踪入参
   * @returns 结果（含是否新建）
   */
  async track(request: TrackRequest): Promise<TrackResult> {
    const result: TrackResult = new TrackResult()
    const tid: string = request.tid.trim()
    if (tid.length === 0) {
      result.error = '缺少帖子标识'
      return result
    }
    if (!this.auth || !this.auth.isAuthenticated || !this.auth.uid) {
      result.error = '请先登录'
      return result
    }
    const keepDays: number = request.keepDays > 0 ? request.keepDays : TRACK_DEFAULT_KEEP_DAYS
    const existing: TrackedThread | null = this.getByTid(tid)
    if (existing !== null) {
      existing.keepDays = keepDays
      if (existing.subject.length === 0 && request.subject.length > 0) {
        existing.subject = request.subject
      }
      if (existing.author.length === 0 && request.author.length > 0) {
        existing.author = request.author
      }
      if (existing.fid === 0 && request.fid !== 0) {
        existing.fid = request.fid
      }
      if (existing.forumName.length === 0 && request.forumName.length > 0) {
        existing.forumName = request.forumName
      }
      this.persist()
      this.publishData()
      result.ok = true
      result.created = false
      return result
    }
    if (this.items.length >= TRACK_MAX_COUNT) {
      result.error = '最多同时跟踪 ' + String(TRACK_MAX_COUNT) + ' 个帖子'
      return result
    }

    const item: TrackedThread = new TrackedThread()
    item.tid = tid
    item.subject = request.subject
    item.author = request.author
    item.authorid = request.authorid
    item.fid = request.fid
    item.forumName = request.forumName
    item.createdAt = Date.now()
    item.keepDays = keepDays
    item.lastCheckAt = 0
    item.totalReplies = 0
    item.seenReplies = 0
    item.seenLastPostTs = 0
    item.lastPostTs = 0
    item.locked = false
    item.failCount = 0
    item.lastError = ''
    this.items.push(item)
    this.persist()
    this.publishData()
    result.ok = true
    result.created = true
    // 立即建立基准（不阻塞调用方）：首次成功检查只写基准，不产生未读
    this.refreshOne(tid).catch((error: Object): void => {
      logger.warn('新增跟踪后首次检查失败 tid=%{public}s: %{public}s', tid, formatError(error))
    })
    return result
  }

  /**
   * 移除一个跟踪任务（用户主动移除，不提示）。
   *
   * @param tid - NGA 主题 ID
   */
  untrack(tid: string): void {
    const next: TrackedThread[] = []
    for (let index: number = 0; index < this.items.length; index++) {
      if (this.items[index].tid !== tid) {
        next.push(this.items[index])
      }
    }
    if (next.length === this.items.length) {
      return
    }
    this.items = next
    this.persist()
    this.publishData()
  }

  /**
   * 移除全部跟踪任务（用户主动全部移除，不提示）。
   */
  untrackAll(): void {
    if (this.items.length === 0) {
      return
    }
    this.items = []
    this.persist()
    this.publishData()
  }

  // ==================== 已读 ====================

  /**
   * 将单个跟踪任务标记为已读（基准推进到服务端最新回复数）。
   *
   * 只发布未读数、不 bump 列表版本：调用页面自行 updateAt 命中行，
   * 避免整列表重建打断滚动（与关注动态已读同一模式）。
   *
   * @param tid - NGA 主题 ID
   * @returns 是否命中并更新
   */
  markSeen(tid: string): boolean {
    const item: TrackedThread | null = this.getByTid(tid)
    if (item === null) {
      return false
    }
    const changed: boolean = item.seenReplies !== item.totalReplies
    if (changed) {
      item.seenReplies = item.totalReplies
    }
    // 已读时点的服务端最后回复时间无论基准是否变化都要记录：它是「检查到的新回复
    // 用户是否已看过」的判据（时钟无关）
    item.seenLastPostTs = item.lastPostTs
    this.persist()
    if (changed) {
      this.publishUnread()
    }
    return changed
  }

  /**
   * 将全部跟踪任务标记为已读（「跟踪」Tab 全部已读）。
   *
   * @returns 是否有任务被更新
   */
  markAllSeen(): boolean {
    if (this.items.length === 0) {
      return false
    }
    let changed: boolean = false
    for (let index: number = 0; index < this.items.length; index++) {
      const item: TrackedThread = this.items[index]
      if (item.seenReplies !== item.totalReplies) {
        item.seenReplies = item.totalReplies
        changed = true
      }
      item.seenLastPostTs = item.lastPostTs
    }
    this.persist()
    if (changed) {
      this.publishUnread()
    }
    return changed
  }

  /**
   * 用户在帖子页打开被跟踪的帖子：先把基准推进到服务端最新回复数。
   *
   * 顺序是先检查、后置已读——用户此刻看到的就是服务端最新内容，若先按旧基准
   * 标已读、检查再发现新回复，会立刻冒出"刚看过却又有红点"的假未读。
   * 检查失败或节流命中时，退回用当前已知回复数标已读，并记录已读时点的服务端最后回复
   * 时间（`seenLastPostTs` 会让后续检查把这批回复认定为"用户已看过"）。
   *
   * @param tid - NGA 主题 ID
   */
  async seenOnOpen(tid: string): Promise<void> {
    if (this.getByTid(tid) === null) {
      return
    }
    await this.refreshOne(tid)
    const item: TrackedThread | null = this.getByTid(tid)
    if (item === null) {
      return
    }
    const changed: boolean = item.seenReplies !== item.totalReplies
    if (changed) {
      item.seenReplies = item.totalReplies
    }
    item.seenLastPostTs = item.lastPostTs
    this.persist()
    if (changed) {
      this.publishUnread()
      bumpAppStorageVersion(KEY_TRACKED_THREAD_VERSION)
    }
  }

  // ==================== 检查 ====================

  /**
   * 全量检查一轮（前台轮询 / 页面触发）。
   *
   * @param force - 是否忽略最小成功间隔
   * @returns 本轮是否成功执行（无跟踪任务时视为成功）
   */
  async refresh(force: boolean = false): Promise<boolean> {
    return this.runGuardedRefresh(force, TRACK_REFRESH_DELAY,
      (generation: number, uid: string, token: string): Promise<boolean> =>
        this.performRefresh(generation, uid, token))
  }

  /**
   * 检查单个帖子（点开「跟踪」Tab 条目时调用，按最小检查间隔节流）。
   *
   * @param tid - NGA 主题 ID
   */
  async refreshOne(tid: string): Promise<void> {
    if (!this.auth || !this.auth.isAuthenticated || !this.auth.uid) {
      return
    }
    const item: TrackedThread | null = this.getByTid(tid)
    if (item === null) {
      return
    }
    const now: number = Date.now()
    if (item.lastCheckAt > 0 && now - item.lastCheckAt < TRACK_MIN_CHECK_INTERVAL) {
      return
    }
    // 同一帖子的检查互斥：`track()` 后的首次检查与「打开帖子」触发的检查可能几乎同时到达
    // （此时 lastCheckAt 仍为 0，最小间隔节流拦不住），并发会让两次都按「首次基准」处理
    if (this.checkingTids.has(tid)) {
      return
    }
    this.checkingTids.add(tid)
    try {
      const generation: number = this.generationGuard.current()
      const uid: string = this.auth.uid
      const token: string = this.auth.token
      const status: ThreadTrackStatus = await fetchThreadTrackStatus(token, tid)
      if (!this.isRequestCurrent(generation, uid, token)) {
        return
      }
      const target: TrackedThread | null = this.getByTid(tid)
      if (target === null) {
        // 检查期间已被用户移除
        return
      }
      const wasBaseline: boolean = target.lastCheckAt === 0
      const outcome: TrackApplyOutcome = applyStatus(target, status, Date.now())
      if (status.ok && wasBaseline) {
        // 首次成功检查只建立基准：刚添加的帖子不产生未读红点
        target.seenReplies = target.totalReplies
      }
      this.persist()
      if (outcome.shouldStop) {
        this.stopByOutcome(target, outcome)
        return
      }
      if (outcome.changed) {
        this.publishData()
      }
    } finally {
      this.checkingTids.delete(tid)
    }
  }

  /**
   * 执行一次全量检查。
   *
   * @param requestGeneration - 请求发起时的 Store generation
   * @param requestUid - 请求发起时的用户 ID
   * @param requestToken - 请求发起时的认证 token
   * @returns 是否完成（无任务、被复用或被并发闸门挡住时按成功返回）
   */
  private async performRefresh(requestGeneration: number, requestUid: string,
    requestToken: string): Promise<boolean> {
    if (this.refreshing) {
      return true
    }
    const snapshot: TrackedThread[] = this.items.slice()
    if (snapshot.length === 0) {
      return true
    }
    this.refreshing = true
    let changed: boolean = false
    let succeeded: number = 0
    const stoppedTids: string[] = []
    const stoppedNotices: TrackStopNotice[] = []
    try {
      for (let index: number = 0; index < snapshot.length; index++) {
        const scanned: TrackedThread = snapshot[index]
        if (!this.isRequestCurrent(requestGeneration, requestUid, requestToken)) {
          return false
        }
        // 检查期间可能被用户移除：跳过已不在列表中的任务
        const item: TrackedThread | null = this.getByTid(scanned.tid)
        if (item === null) {
          continue
        }
        if (index > 0) {
          await sleep(TRACK_CHECK_GAP)
        }
        const status: ThreadTrackStatus = await fetchThreadTrackStatus(requestToken, item.tid)
        if (!this.isRequestCurrent(requestGeneration, requestUid, requestToken)) {
          return false
        }
        const target: TrackedThread | null = this.getByTid(item.tid)
        if (target === null) {
          continue
        }
        const wasBaseline: boolean = target.lastCheckAt === 0
        const outcome: TrackApplyOutcome = applyStatus(target, status, Date.now())
        if (status.ok) {
          succeeded++
          if (wasBaseline) {
            target.seenReplies = target.totalReplies
          }
        }
        changed = changed || outcome.changed
        if (outcome.shouldStop) {
          // 只收集，循环结束后统一移除/落盘/发布：一轮里多个任务同时失效时，
          // 逐项落盘会做 N 次全量序列化写盘与 N 次 UI 版本 bump
          stoppedTids.push(target.tid)
          stoppedNotices.push(new TrackStopNotice(
            target.tid, target.subject, outcome.stopReason, outcome.detail
          ))
        }
      }
    } catch (error) {
      logger.warn('跟踪检查异常: %{public}s', formatError(error as Object))
      return false
    } finally {
      this.refreshing = false
    }
    if (stoppedTids.length > 0) {
      this.applyStopped(stoppedTids, stoppedNotices)
    } else if (changed) {
      this.persist()
      this.publishData()
    }
    if (succeeded > 0) {
      logger.info('跟踪检查完成: 任务=%{public}d 成功=%{public}d 停止=%{public}d',
        snapshot.length, succeeded, stoppedTids.length)
    }
    return true
  }

  /**
   * 批量停止跟踪：一次移除、一次落盘、一次发布，再逐个回调提示。
   *
   * @param tids - 待移除的帖子 ID 列表
   * @param notices - 与 tids 一一对应的停止通知
   */
  private applyStopped(tids: string[], notices: TrackStopNotice[]): void {
    if (tids.length === 0) {
      return
    }
    const removed: Set<string> = new Set<string>()
    for (let index: number = 0; index < tids.length; index++) {
      removed.add(tids[index])
    }
    const next: TrackedThread[] = []
    for (let index: number = 0; index < this.items.length; index++) {
      if (!removed.has(this.items[index].tid)) {
        next.push(this.items[index])
      }
    }
    this.items = next
    this.persist()
    this.publishData()
    for (let index: number = 0; index < notices.length; index++) {
      const notice: TrackStopNotice = notices[index]
      if (this.onStopNotice) {
        this.onStopNotice(notice)
      }
      logger.info('停止跟踪 tid=%{public}s reason=%{public}d detail=%{public}s',
        notice.tid, notice.reason, notice.detail)
    }
  }

  /**
   * 按检查结论停止跟踪：移除任务、落盘、发布状态并回调提示。
   *
   * @param item - 被停止的跟踪任务
   * @param outcome - 检查结论
   */
  private stopByOutcome(item: TrackedThread, outcome: TrackApplyOutcome): void {
    const notice: TrackStopNotice = new TrackStopNotice(
      item.tid, item.subject, outcome.stopReason, outcome.detail
    )
    const next: TrackedThread[] = []
    for (let index: number = 0; index < this.items.length; index++) {
      if (this.items[index].tid !== item.tid) {
        next.push(this.items[index])
      }
    }
    this.items = next
    this.persist()
    this.publishData()
    if (this.onStopNotice) {
      this.onStopNotice(notice)
    }
    logger.info('停止跟踪 tid=%{public}s reason=%{public}d detail=%{public}s',
      item.tid, outcome.stopReason, outcome.detail)
  }

  // ==================== 持久化与发布 ====================

  /**
   * 加载当前账号的跟踪缓存；信封非法时以空列表覆盖。
   */
  private async loadCachedItems(): Promise<void> {
    const cached: TrackedThread[] | null = await this.cacheEnvelope.load(this.store, this.auth.uid)
    if (cached === null) {
      this.items = []
      this.publishUnread()
      this.persist()
      return
    }
    this.items = cached
    this.publishUnread()
  }

  /**
   * 落盘跟踪列表快照。
   */
  private persist(): void {
    this.cacheEnvelope.persist(this.auth.uid, this.items, this.store, this.writeQueue)
  }

  /**
   * 发布未读数与列表版本（数据变化时调用）。
   */
  private publishData(): void {
    this.publishUnread()
    bumpAppStorageVersion(KEY_TRACKED_THREAD_VERSION)
  }

  /**
   * 只发布未读数（已读变化时不 bump 列表版本，见 markSeen 说明）。
   */
  private publishUnread(): void {
    this.unreadTrackCount = countUnreadTracked(this.items)
    AppStorage.setOrCreate(KEY_UNREAD_TRACK_COUNT, this.unreadTrackCount)
  }
}
