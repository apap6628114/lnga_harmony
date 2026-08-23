import { Context } from '@kit.AbilityKit'
import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { AuthStore } from './AuthStore'
import { SettingsStore } from './SettingsStore'
import { CategoryStore } from './CategoryStore'
import { ProfileStore } from './ProfileStore'
import { NotificationStore } from './NotificationStore'
import { FollowActivityStore } from './FollowActivityStore'
import { VoteStore } from './VoteStore'
import { HistoryStore } from './HistoryStore'
import { FavoriteStore } from './FavoriteStore'
import { SavedThreadStore } from './SavedThreadStore'
import { ReadingProgressStore } from './ReadingProgressStore'
import { floatingLayerStore } from './FloatingLayerStore'
import { ToastManager } from '../common/feedback/ToastManager'

import type { AuthState } from './AuthStore'
import type { Session } from './SessionRegistry'
import { routerStore } from './RouterStore'
import type { SettingsState } from './settings/SettingsState'
import type { BrowseHistoryEntry } from './HistoryStore'
import type { ReadingProgressEntry } from './ReadingProgressStore'
import type { ToastState } from '../common/feedback/ToastManager'
import type { ProfileData } from '../model/User'
import type { ThreadResult } from '../model/ThreadResult'
import type { NgaNotification } from '../model/Notification'
import type { FollowedActivity } from '../model/Follow'
import type { Category } from '../model/Forum'

import { Logger, DOMAIN_APP, formatError } from '../common/utils/Logger'
import { shouldEnablePolling } from '../common/concurrency/PollingController'

/**
 * 前台轮询参与者（注册表项）：一对启停回调。
 * 由 AppStore 统一登记社交类 Store 的前台轮询启停。
 */
class PollingParticipant {
  readonly start: () => void
  readonly stop: () => void

  constructor(start: () => void, stop: () => void) {
    this.start = start
    this.stop = stop
  }
}

const logger = new Logger(DOMAIN_APP, 'AppStore')

/**
 * AppStore — 全局状态管理 Facade
 *
 * 各领域职责已拆分到独立 Store，AppStore 只做编排和委托。
 */
class AppStoreClass {
  // ---------- Infrastructure ----------
  private store: PreferencesStore = new PreferencesStore()
  private writeQueue: SerialQueue = new SerialQueue()
  private context?: Context
  /** AppStore 及用户相关 Store 是否完成初始化。 */
  private initialized: boolean = false
  /** AppStore 初始化流程是否已经结束。 */
  private initializationFinished: boolean = false
  /** Ability 当前是否处于前台。 */
  private foregroundActive: boolean = false
  /** 前台轮询参与者注册表（新增轮询 Store 时在此登记即可统一启停）。 */
  private pollingParticipants: PollingParticipant[] = []

  constructor() {
    this.pollingParticipants = [
      new PollingParticipant(
        (): void => { this.notificationStore.startPolling() },
        (): void => { this.notificationStore.stopPolling() }
      ),
      new PollingParticipant(
        (): void => { this.followActivityStore.startPolling() },
        (): void => { this.followActivityStore.stopPolling() }
      )
    ]
  }

  // ---------- Sub Stores ----------
  readonly authStore: AuthStore = new AuthStore()
  readonly settingsStore: SettingsStore = new SettingsStore()
  readonly categoryStore: CategoryStore = new CategoryStore()
  readonly profileStore: ProfileStore = new ProfileStore()
  readonly notificationStore: NotificationStore = new NotificationStore()
  /** 关注动态缓存、已读与红点管理（机制与通知系统对齐）。 */
  readonly followActivityStore: FollowActivityStore = new FollowActivityStore()
  readonly voteStore: VoteStore = new VoteStore()
  readonly historyStore: HistoryStore = new HistoryStore()
  /** NGA 主题收藏夹与收藏关系状态。 */
  readonly favoriteStore: FavoriteStore = new FavoriteStore()
  /** 保存的帖子离线存档（文件系统持久化，不按账号区分）。 */
  readonly savedThreadStore: SavedThreadStore = new SavedThreadStore()
  /** 帖子阅读进度（按账号隔离，用于下次进入时恢复阅读位置）。 */
  readonly readingProgressStore: ReadingProgressStore = new ReadingProgressStore()
  readonly toastManager: ToastManager = new ToastManager()

  // ============== Init & Lifecycle ==============

  async init(context: Context): Promise<void> {
    this.initialized = false
    this.initializationFinished = false
    this.stopAllPolling()
    try {
      this.context = context
      await this.store.init(context, 'nga_app_store')

      // 存档与登录态无关，随应用启动即初始化（不按账号区分）
      await this.savedThreadStore.init(context)

      // 子 Store 中不依赖 uid 的先初始化（同步赋值引用）
      await this.voteStore.init(this.store, this.writeQueue)
      await this.historyStore.init(this.store, this.writeQueue)
      await this.readingProgressStore.init(this.store, this.writeQueue)

      // 认证 + 分类（部分依赖 uid）
      await this.authStore.init(this.store, this.writeQueue)
      await this.categoryStore.init(this.store, this.writeQueue, this.authStore.state)

      // 用户数据（依赖 uid）
      if (this.authStore.state.uid) {
        await this.loadUserData()
      }
      this.settingsStore.applyCurrentTheme()
      this.initialized = true
      this.reconcilePolling()

      logger.info('AppStore initialized')
    } catch (e) {
      logger.error('AppStore init failed: %{public}s', formatError(e))
      throw new Error(formatError(e))
    } finally {
      this.initializationFinished = true
    }
  }

  /** 返回 AppStore 及全部用户 Store 是否完成初始化。 */
  get isInitialized(): boolean {
    return this.initialized
  }

  /** 返回 AppStore 初始化流程是否已经成功或失败地结束。 */
  get isInitializationFinished(): boolean {
    return this.initializationFinished
  }

  private async loadUserData(): Promise<void> {
    await this.settingsStore.init(this.store, this.writeQueue, this.authStore.state, this.context)
    await this.profileStore.init(this.store, this.writeQueue, this.authStore.state)
    await this.notificationStore.init(this.store, this.writeQueue, this.authStore.state)
    await this.followActivityStore.init(this.store, this.writeQueue, this.authStore.state)
    await this.favoriteStore.init(this.store, this.writeQueue, this.authStore.state)
  }

  /** 后台时刷盘 */
  async flushAll(): Promise<void> {
    await this.writeQueue.enqueue(async (): Promise<void> => {})
    await this.store.flush()
  }

  // ---------- Facade: Auth ----------

  get auth(): AuthState {
    return this.authStore.state
  }

  async setAuth(token: string, uid: string, nickName: string, avatarUrl: string): Promise<void> {
    this.stopAllPolling()
    const uidChanged = await this.authStore.setAuth(token, uid, nickName, avatarUrl)
    if (uidChanged) {
      await this.loadUserData()
      this.settingsStore.applyCurrentTheme()
    }
    this.reconcilePolling()
  }

  clearAuth(): void {
    this.stopAllPolling()
    // ⚠️ 以下顺序有严格依赖：cancel/reset 必须在 authStore.clearAuth() 之前，
    // 否则后者 enqueue 的 persistAuth 写入任务会被取消。
    // 先取消队列中所有待执行的任务（如已入队的 history/vote 旧 uid 写入）
    this.writeQueue.cancel()
    this.writeQueue.reset()
    // 再清空认证状态（会 enqueue 写入空 auth，此时 queue 已重置为干净状态）
    this.authStore.clearAuth()
    this.settingsStore.reset()
    this.categoryStore.reset()
    this.profileStore.reset()
    this.notificationStore.reset()
    this.followActivityStore.reset()
    this.voteStore.reset()
    this.historyStore.reset()
    this.readingProgressStore.reset()
    this.favoriteStore.reset()
    floatingLayerStore.clear()
    routerStore.reset()
    // 与 setAuth 对称：退出后统一协调轮询状态（此时未认证 → 停止轮询，幂等无害）
    this.reconcilePolling()
  }

  createSession(uid: string, cid: string, nickName: string, avatarUrl: string): Promise<string> {
    return this.authStore.createSession(uid, cid, nickName, avatarUrl)
  }

  getSession(token: string): Session | null {
    return this.authStore.getSession(token)
  }

  updateSession(token: string, nickName?: string, avatarUrl?: string): Promise<void> {
    return this.authStore.updateSession(token, nickName, avatarUrl)
  }

  destroySession(token: string): Promise<void> {
    return this.authStore.destroySession(token)
  }

  // ---------- Facade: Settings ----------

  get settings(): SettingsState {
    return this.settingsStore.state
  }

  /** 若自动签到实际成功，则显示全局成功提示。 */
  autoCheckinIfNeeded(): void {
    const requestUid: string = this.auth.uid
    this.settingsStore.autoCheckinIfNeeded().then((checked: boolean): void => {
      // 签到请求期间可能已退出或切换账号：身份不一致时不再提示
      if (checked && this.auth.uid === requestUid && this.auth.isAuthenticated) {
        this.showToast('自动签到成功')
      }
    }).catch((): void => {})
  }

  // ---------- Facade: Categories ----------

  get cachedCategories(): Category[] {
    return this.categoryStore.cachedCategories
  }

  get categoriesLoaded(): boolean {
    return this.categoryStore.categoriesLoaded
  }

  get categoriesError(): string {
    return this.categoryStore.categoriesError
  }

  ensureCategories(): void { this.categoryStore.ensureCategories() }

  // ---------- Facade: Profile ----------

  getCachedProfile(uid: string): ProfileData | null { return this.profileStore.getCachedProfile(uid) }
  ensureProfile(uid: string): void { this.profileStore.ensureProfile(uid) }
  invalidateProfile(uid: string): void { this.profileStore.invalidateProfile(uid) }

  // ---------- Facade: Notifications ----------

  get unreadNotiCount(): number {
    return this.notificationStore.unreadNotiCount
  }

  /** 返回未查看私信通知数量。 */
  get unreadMessageCount(): number {
    return this.notificationStore.unreadMessageCount
  }

  refreshUnreadCount(): Promise<void> { return this.notificationStore.refreshUnreadCount() }
  /** 刷新通知并返回请求是否成功。 */
  refreshNotifications(force: boolean = false): Promise<boolean> {
    return this.notificationStore.refreshNotifications(force)
  }
  /**
   * 更新 Ability 前台状态并统一协调社交轮询（消息 / 动态）。
   *
   * @param active - Ability 是否处于前台
   */
  setForegroundActive(active: boolean): void {
    this.foregroundActive = active
    this.reconcilePolling()
  }
  /**
   * 根据初始化、认证与前台状态启动或停止全部前台轮询参与者。
   */
  private reconcilePolling(): void {
    if (shouldEnablePolling(
      this.foregroundActive,
      this.initialized,
      this.auth.isAuthenticated
    )) {
      this.startAllPolling()
      return
    }
    this.stopAllPolling()
  }

  /** 启动全部前台轮询参与者（幂等：各 Store 内部有启动守卫）。 */
  private startAllPolling(): void {
    for (let index: number = 0; index < this.pollingParticipants.length; index++) {
      this.pollingParticipants[index].start()
    }
  }

  /** 停止全部前台轮询参与者（幂等）。 */
  private stopAllPolling(): void {
    for (let index: number = 0; index < this.pollingParticipants.length; index++) {
      this.pollingParticipants[index].stop()
    }
  }
  getCachedNotifications(): NgaNotification[] { return this.notificationStore.getCachedNotifications() }
  /** 将指定通知标记为已查看。 */
  markNotificationSeen(notificationId: string): void { this.notificationStore.markSeen(notificationId) }
  /** 将全部非私信通知标记为已查看（消息 Tab 全部已读，不波及私信通知）。 */
  markNonMessageNotificationsSeen(): void { this.notificationStore.markNonMessageSeen() }
  /** 将私信通知标记为已查看。 */
  markMessageNotificationsSeen(): void { this.notificationStore.markMessagesSeen() }
  /** 将指定会话（mid）的私信通知标记为已查看（按可索引 ID 精确表达已读）。 */
  markMessageNotificationsSeenByMid(mid: string): void {
    this.notificationStore.markMessagesSeenByMid(mid)
  }
  /** 返回通知缓存中非私信通知的只读快照（消息 Tab 数据源）。 */
  getCachedNonMessageNotifications(): NgaNotification[] {
    return this.notificationStore.getCachedNonMessageNotifications()
  }

  // ---------- Facade: Follow Activities ----------

  /** 返回未读关注动态数量。 */
  get unreadActivityCount(): number {
    return this.followActivityStore.unreadActivityCount
  }

  /** 刷新关注动态并返回请求是否成功。 */
  refreshActivities(force: boolean = false): Promise<boolean> {
    return this.followActivityStore.refreshActivities(force)
  }
  /** 返回关注动态内存真源的只读数组快照（displayActivities 全量，含分页追加）。 */
  getDisplayActivities(): FollowedActivity[] {
    return this.followActivityStore.getDisplayActivities()
  }
  /** 返回关注动态缓存的只读数组快照（持久化窗口，兼容既有调用）。 */
  getCachedActivities(): FollowedActivity[] {
    return this.followActivityStore.getCachedActivities()
  }
  /** 加载关注动态下一页（store 内并发防护与账号代际校验）。 */
  loadMoreActivities(): Promise<boolean> {
    return this.followActivityStore.loadMoreActivities()
  }
  /** 返回关注动态服务端总页数（0=未知/未确认）。 */
  getActivityTotalPages(): number {
    return this.followActivityStore.getTotalPages()
  }
  /** 返回关注动态已加载页数（首屏=1）。 */
  getActivityLoadedPages(): number {
    return this.followActivityStore.getLoadedPages()
  }
  /** 返回关注动态分页是否加载中。 */
  getActivityLoadingMore(): boolean {
    return this.followActivityStore.isLoadingMoreState()
  }
  /** 将指定 id 集合的动态标记为已读（点开帖子即已读）。 */
  markActivitiesSeen(ids: Set<string>): void {
    this.followActivityStore.markSeenByIds(ids)
  }
  /** 将所有动态标记为已读。 */
  markAllActivitiesSeen(): void {
    this.followActivityStore.markAllSeen()
  }

  // ---------- Facade: Vote ----------

  loadVoteRecord(uid: string, tid: string): Promise<Set<string>[]> {
    return this.voteStore.loadVoteRecord(uid, tid)
  }
  saveVoteRecord(uid: string, tid: string, upPids: Set<string>, downPids: Set<string>): Promise<void> {
    return this.voteStore.saveVoteRecord(uid, tid, upPids, downPids)
  }
  removeVoteRecord(uid: string, tid: string): Promise<void> { return this.voteStore.removeVoteRecord(uid, tid) }
  clearVoteRecords(uid: string): Promise<void> { return this.voteStore.clearVoteRecords(uid) }
  loadPollVoted(uid: string): Promise<string[]> { return this.voteStore.loadPollVoted(uid) }
  markPollVoted(uid: string, tid: string): Promise<void> { return this.voteStore.markPollVoted(uid, tid) }

  // ---------- Facade: Browse History ----------

  getBrowseHistory(uid: string): Promise<BrowseHistoryEntry[]> { return this.historyStore.getBrowseHistory(uid) }
  addBrowseHistory(uid: string, entry: BrowseHistoryEntry): Promise<void> {
    return this.historyStore.addBrowseHistory(uid, entry)
  }
  addBrowseHistoryFromThread(uid: string, result: ThreadResult, tid: string): Promise<void> {
    return this.historyStore.addFromThreadResult(uid, result, tid)
  }
  removeBrowseHistory(uid: string, tid: string): Promise<void> { return this.historyStore.removeBrowseHistory(uid, tid) }
  clearBrowseHistory(uid: string): Promise<void> { return this.historyStore.clearBrowseHistory(uid) }

  // ---------- Facade: Reading Progress ----------

  /** 读取指定帖子的阅读进度（无记录返回 null）。 */
  getReadingProgress(uid: string, tid: string): Promise<ReadingProgressEntry | null> {
    return this.readingProgressStore.getProgress(uid, tid)
  }
  /** 写入（覆盖）指定帖子的阅读进度。 */
  saveReadingProgress(uid: string, entry: ReadingProgressEntry): Promise<void> {
    return this.readingProgressStore.setProgress(uid, entry)
  }

  // ---------- Facade: Toast ----------

  get toast(): ToastState {
    return this.toastManager.state
  }

  showToast(msg: string): void { this.toastManager.show(msg) }

  /**
   * 展示带动作按钮的 Toast（如回复成功后的「前往查看」）。
   *
   * @param msg - 主文案
   * @param actionText - 按钮文案
   * @param onAction - 点击回调；回调可能晚于 Toast 消失触发，闭包内不得依赖已销毁的组件实例
   */
  showToastAction(msg: string, actionText: string, onAction: () => void): void {
    this.toastManager.showAction(msg, actionText, onAction)
  }
}

export const appStore = new AppStoreClass()
