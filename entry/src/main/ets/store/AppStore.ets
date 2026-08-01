import { Context } from '@kit.AbilityKit'
import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { AuthStore } from './AuthStore'
import { SettingsStore } from './SettingsStore'
import { CategoryStore } from './CategoryStore'
import { ProfileStore } from './ProfileStore'
import { NotificationStore } from './NotificationStore'
import { VoteStore } from './VoteStore'
import { HistoryStore } from './HistoryStore'
import { FavoriteStore } from './FavoriteStore'
import { floatingLayerStore } from './FloatingLayerStore'
import { ToastManager } from '../common/feedback/ToastManager'

import type { AuthState, Session } from './AuthStore'
import { routerStore } from './RouterStore'
import type { SettingsState } from './settings/SettingsState'
import type { BrowseHistoryEntry } from './HistoryStore'
import type { ToastState } from '../common/feedback/ToastManager'
import type { ProfileData } from '../model/User'
import type { ThreadResult } from '../model/ThreadResult'
import type { NgaNotification } from '../model/Notification'
import type { Category } from '../model/Forum'

import { Logger, DOMAIN_APP, formatError } from '../common/utils/Logger'
import { shouldEnableNotificationPolling } from '../common/utils/NotificationPolicy'

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

  // ---------- Sub Stores ----------
  readonly authStore: AuthStore = new AuthStore()
  readonly settingsStore: SettingsStore = new SettingsStore()
  readonly categoryStore: CategoryStore = new CategoryStore()
  readonly profileStore: ProfileStore = new ProfileStore()
  readonly notificationStore: NotificationStore = new NotificationStore()
  readonly voteStore: VoteStore = new VoteStore()
  readonly historyStore: HistoryStore = new HistoryStore()
  /** NGA 主题收藏夹与收藏关系状态。 */
  readonly favoriteStore: FavoriteStore = new FavoriteStore()
  readonly toastManager: ToastManager = new ToastManager()

  // ============== Init & Lifecycle ==============

  async init(context: Context): Promise<void> {
    this.initialized = false
    this.initializationFinished = false
    this.notificationStore.stopPolling()
    try {
      this.context = context
      await this.store.init(context, 'nga_app_store')

      // 子 Store 中不依赖 uid 的先初始化（同步赋值引用）
      await this.voteStore.init(this.store, this.writeQueue)
      await this.historyStore.init(this.store, this.writeQueue)

      // 认证 + 分类（部分依赖 uid）
      await this.authStore.init(this.store, this.writeQueue)
      await this.categoryStore.init(this.store, this.writeQueue, this.authStore.state)

      // 用户数据（依赖 uid）
      if (this.authStore.state.uid) {
        await this.loadUserData()
      }
      this.settingsStore.applyCurrentTheme()
      this.initialized = true
      this.reconcileNotificationPolling()

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
    this.notificationStore.stopPolling()
    const uidChanged = await this.authStore.setAuth(token, uid, nickName, avatarUrl)
    if (uidChanged) {
      await this.loadUserData()
      this.settingsStore.applyCurrentTheme()
    }
    this.reconcileNotificationPolling()
  }

  clearAuth(): void {
    this.notificationStore.stopPolling()
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
    this.voteStore.reset()
    this.historyStore.reset()
    this.favoriteStore.reset()
    floatingLayerStore.clear()
    routerStore.reset()
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
   * 更新 Ability 前台状态并统一协调通知轮询。
   *
   * @param active - Ability 是否处于前台
   */
  setNotificationForegroundActive(active: boolean): void {
    this.foregroundActive = active
    this.reconcileNotificationPolling()
  }
  /**
   * 根据初始化、认证与前台状态启动或停止通知轮询。
   */
  private reconcileNotificationPolling(): void {
    if (shouldEnableNotificationPolling(
      this.foregroundActive,
      this.initialized,
      this.auth.isAuthenticated
    )) {
      this.notificationStore.startPolling()
      return
    }
    this.notificationStore.stopPolling()
  }
  getCachedNotifications(): NgaNotification[] { return this.notificationStore.getCachedNotifications() }
  /** 将指定通知标记为已查看。 */
  markNotificationSeen(notificationId: string): void { this.notificationStore.markSeen(notificationId) }
  /** 将全部通知标记为已查看。 */
  markAllNotificationsSeen(): void { this.notificationStore.markAllSeen() }
  /** 将私信通知标记为已查看。 */
  markMessageNotificationsSeen(): void { this.notificationStore.markMessagesSeen() }

  // ---------- Facade: Vote ----------

  loadVoteRecord(uid: string, tid: string): Promise<Set<string>[]> {
    return this.voteStore.loadVoteRecord(uid, tid)
  }
  saveVoteRecord(uid: string, tid: string, upPids: Set<string>, downPids: Set<string>): Promise<void> {
    return this.voteStore.saveVoteRecord(uid, tid, upPids, downPids)
  }
  removeVoteRecord(uid: string, tid: string): Promise<void> { return this.voteStore.removeVoteRecord(uid, tid) }
  clearVoteRecords(uid: string): Promise<void> { return this.voteStore.clearVoteRecords(uid) }

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

  // ---------- Facade: Toast ----------

  get toast(): ToastState {
    return this.toastManager.state
  }

  showToast(msg: string): void { this.toastManager.show(msg) }
}

export const appStore = new AppStoreClass()
