/**
 * 通知面板 - 消息 / 私信 / 关注动态 三筛选
 *
 * 标题区与帖子 UI（TopicListPanel）保持一致：左侧返回 + 标题「通知」，
 * 筛选项（消息/私信/动态）作为列表首个元素随内容滚动穿越标题区。
 * - 消息：通知中心非私信数据（回复/点赞提醒），点击已读 / 全部已读；
 * - 私信：私信会话列表（getMessageList，滚动分页），会话行已读按可索引 ID
 *   （私信通知 notificationId 内含 mid）精确表达，点击会话标记该会话已读；
 * - 动态：关注动态流，数据来自 FollowActivityStore（轮询/条件抓取/缓存），
 *   已读规则与消息一致：点开帖子才标记已读，右上角「全部已读」作用于当前 Tab 的系统。
 *
 * 楼层定位：官方 APP 的支持或反对通知（type=17）不返回页码（about_id4 恒 0），
 * 关注动态亦无页码字段——这两类入口点击后先经 locatePidPage 二分定位目标楼层
 * 所在页，再以正确页码打开帖子（openThreadAfterPidLookup，与回帖列表/链接
 * 入口同一模式）；回复/评论类通知携带服务端页码，直接按页码打开。
 */

import { appStore } from '../store/AppStore'
import { routerStore, Screen, ThreadSource } from '../store/RouterStore'
import type {
  MessageNotification,
  NgaNotification,
  NotificationInfo,
  ReplyNotification,
  UpvoteNotification
} from '../model/Notification'
import { FollowedActivity, FollowedActivityType } from '../model/Follow'
import type { MessageThreadInfo } from '../model/Message'
import type { MessageListResult } from '../model/MessageResult'
import { getMessageList } from '../service/api/MessageApi'
import { locatePidPage } from '../service/api/ThreadApi'
import { pidLocateProgress } from '../common/media/PidLocateProgress'
import { AppColors, BreakpointType, NOTI_TYPE_MAP, getNotiIcon } from '../common/constants/Constants'
import { formatTime } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { Avatar } from '../common/components/Avatar'
import { ComposeMessageSheet } from '../common/components/ComposeMessageSheet'
import {
  NotificationDataSource,
  FollowedActivityDataSource,
  MessageThreadDataSource
} from '../common/datasource/LazyDataSource'
import { LoadingStateView, ErrorStateView, EmptyStateView } from '../common/components/PageStateView'
import { PageScope } from '../common/concurrency/PageScope'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'
import { isMessageNotificationType } from '../common/utils/NotificationPolicy'
import {
  SegmentButton,
  SegmentButtonOptions,
  SegmentButtonItemTuple,
  SegmentButtonTextItem
} from '@kit.ArkUI'

/** 通知页筛选 Tab。 */
export const TAB_MESSAGES: number = 0
export const TAB_PRIVATE: number = 1
export const TAB_ACTIVITIES: number = 2

/** 私信列表快照复用窗口：成功刷新后窗口内切 Tab 不重复请求（详情返回强制刷新不受限）。 */
const PRIVATE_REFRESH_WINDOW_MS: number = 30 * 1000

@Component
export struct NotificationPanel {
  /** 初始筛选 Tab（0=消息，1=私信，2=动态）。 */
  @Prop initialTab: number = 0
  /** 直达写私信的初始收件人（非空时强制私信 Tab 并弹出写私信面板）。 */
  @Prop composeToInit: string = ''
  @State notifications: NotificationInfo[] = []
  @State isLoading: boolean = true
  @State hasError: boolean = false
  @State errorMsg: string = ''
  /** 关注动态缓存快照（消息 tab 之外的列表数据）。 */
  @State activities: FollowedActivity[] = []
  /** 动态首屏是否加载中。 */
  @State activitiesLoading: boolean = true
  /** 动态加载是否失败。 */
  @State activitiesError: boolean = false
  /** 动态分页加载更多进行中（仅用于 footer 显示；store 内部有并发防护）。 */
  @State isLoadingMore: boolean = false
  /** 私信会话列表快照。 */
  @State threads: MessageThreadInfo[] = []
  /** 私信首屏是否加载中。 */
  @State privateLoading: boolean = true
  /** 私信加载是否失败。 */
  @State privateError: boolean = false
  /** 私信分页加载更多进行中。 */
  @State privateLoadingMore: boolean = false
  /** 私信会话列表下一页页码（<=0 表示没有更多）。 */
  @State privateNextPage: number = 0
  /** 私信通知快照（可索引 ID 已读表达的数据源：会话行未读点与私信全部已读）。 */
  @State messageNotifications: MessageNotification[] = []
  /** 写私信面板是否可见。 */
  @State showCompose: boolean = false
  /** 当前筛选 Tab。 */
  @State activeTab: number = 0
  /** 筛选条分段按钮选项（原生 SegmentButton，胶囊单选）。 */
  @State tabOptions: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [
      { text: '消息' },
      { text: '私信' },
      { text: '动态' }
    ] as SegmentButtonItemTuple,
    multiply: false,
    fontColor: AppColors.textSecondary,
    selectedFontColor: AppColors.primary,
    fontSize: 13,
    selectedFontSize: 13,
    fontWeight: FontWeight.Normal,
    selectedFontWeight: FontWeight.Bold,
    backgroundColor: AppColors.bgSecondary,
    selectedBackgroundColor: AppColors.primaryLight,
  })
  /** 筛选条分段按钮选中项（SegmentButton 双向绑定，单选取 [index]）。 */
  @State tabSelected: number[] = [0]
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 列表当前视口高度。 */
  @State listViewportHeight: number = 1
  /** 通知 Store 的页面刷新信号。 */
  @StorageProp('notificationVersion') @Watch('onNotificationVersionChange') notificationVersion: number = 0
  /** 动态 Store 的页面刷新信号（仅数据合并时触发）。 */
  @StorageProp('activityVersion') @Watch('onActivityVersionChange') activityVersion: number = 0
  /** 私信会话列表刷新信号（详情页关闭时 bump，驱动私信 Tab 静默刷新）。 */
  @StorageProp('messageVersion') @Watch('onMessageVersionChange') messageVersion: number = 0
  /** 消息 Tab 未读数量（以括号文本拼入按钮文案，0 不显示）。 */
  @StorageProp('unreadNotiCount') @Watch('onUnreadCountChange') unreadNotiCount: number = 0
  /** 私信 Tab 未读数量（私信通知未读数，以括号文本拼入按钮文案，0 不显示）。 */
  @StorageProp('unreadMessageCount') @Watch('onUnreadCountChange') unreadMessageCount: number = 0
  /** 动态 Tab 未读数量（以括号文本拼入按钮文案，0 不显示）。 */
  @StorageProp('unreadActivityCount') @Watch('onUnreadCountChange') unreadActivityCount: number = 0
  private notificationsDataSource: NotificationDataSource = new NotificationDataSource()
  private activitiesDataSource: FollowedActivityDataSource = new FollowedActivityDataSource()
  private threadsDataSource: MessageThreadDataSource = new MessageThreadDataSource()
  /** mid → 是否存在未读私信通知（syncMessageNotificationsFromStore 时重建，行查询 O(1)）。 */
  private unreadByMid: Map<string, boolean> = new Map<string, boolean>()
  /** 私信列表最近一次成功刷新时间戳（快照复用窗口判定）。 */
  private lastPrivateRefreshMs: number = 0
  /**
   * 楼层定位查找代际：连点多条通知/动态时只执行最新一次跳转；面板离开时自增作废。
   * 切 Tab（handleTabClicked）刻意不作废：Tab 切换不改变用户点击通知/动态的跳转意图，
   * 在途查找完成后仍应打开目标帖子（与 TopicListPanel 切版块放弃定位的语义不同）。
   */
  private pidLookupGeneration: number = 0
  /** 当前楼层定位指示器代际（pidLocateProgress.begin() 返回值，-1 表示未接管）。 */
  private pidLocateGeneration: number = -1
  private scroller: Scroller = new Scroller()
  /** 筛选条在窗口中的底部纵坐标（onAreaChange 实时采集，供状态视图撑满估算）。 */
  private sortBarBottomY: number = 0
  /** 页面出现会话作用域，驱动异步回调的存活与代际校验。 */
  private scope: PageScope = new PageScope()

  /** 按列表绝对滚动偏移同步标题栏视觉效果。 */
  private syncTitleScrollEffect(): void {
    const progress: number = TitleScrollEffect.getProgress(
      this.scroller.currentOffset().yOffset,
      this.statusBarHeight
    )
    if (TitleScrollEffect.shouldUpdateProgress(this.titleScrollEffectProgress, progress)) {
      this.titleScrollEffectProgress = progress
    }
  }

  aboutToAppear(): void {
    const currentGeneration: number = this.scope.begin()
    let initialTab: number = this.initialTab
    if (this.composeToInit.length > 0) {
      // 直达写私信：强制进入私信 Tab 并弹出写私信面板
      initialTab = TAB_PRIVATE
    }
    if (initialTab !== TAB_MESSAGES && initialTab !== TAB_PRIVATE && initialTab !== TAB_ACTIVITIES) {
      initialTab = TAB_MESSAGES
    }
    this.activeTab = initialTab
    this.tabSelected = [initialTab]
    this.rebuildTabOptions()
    this.syncNotificationsFromStore()
    this.syncActivitiesFromStore()
    this.syncMessageNotificationsFromStore()
    if (initialTab === TAB_ACTIVITIES) {
      this.loadActivities(currentGeneration)
    } else if (initialTab === TAB_PRIVATE) {
      if (this.composeToInit.length > 0) {
        this.showCompose = true
      }
      this.loadPrivateMessages(currentGeneration)
    } else {
      this.loadNotifications(currentGeneration)
    }
  }

  /** 结束当前页面出现周期，使未完成的异步回调失效。 */
  aboutToDisappear(): void {
    this.scope.end()
    // 使在途的楼层定位查找失效：面板离开后不得再执行过期跳转
    this.pidLookupGeneration++
    pidLocateProgress.hide(this.pidLocateGeneration)
    this.pidLocateGeneration = -1
  }

  /** 通知 Store 发布新版本时同步页面快照（私信通知快照任何 Tab 都同步，供会话行已读索引）。 */
  private onNotificationVersionChange(): void {
    this.syncMessageNotificationsFromStore()
    if (this.activeTab === TAB_MESSAGES) {
      this.syncNotificationsFromStore()
    }
  }

  /** 动态 Store 发布新版本时同步页面快照（数据合并增量更新）。 */
  private onActivityVersionChange(): void {
    if (this.activeTab === TAB_ACTIVITIES) {
      this.syncActivitiesFromStore()
    }
  }

  /**
   * 私信详情页关闭后强制静默刷新会话列表（忽略快照复用窗口，保证回复后列表最新）。
   *
   * 先同步通知快照（含会话行未读刷新）：本地已读状态立即生效，不依赖网络刷新结果；
   * 再强制拉取会话列表（回复后 lasttime/posts 等字段变化由 mergePrivateSnapshot 落行）。
   */
  private onMessageVersionChange(): void {
    if (this.activeTab === TAB_PRIVATE) {
      this.syncMessageNotificationsFromStore()
      this.loadPrivateMessages(this.scope.begin(), true)
    }
  }

  /** 从通知 Store 同步列表快照和懒加载数据源（消息 Tab 仅展示非私信通知）。 */
  private syncNotificationsFromStore(): void {
    this.notifications = appStore.getCachedNonMessageNotifications() as NotificationInfo[]
    this.notificationsDataSource.replaceAll(this.notifications)
    if (this.notifications.length === 0) {
      this.titleScrollEffectProgress = 0
    }
  }

  /**
   * 从通知 Store 同步私信通知快照（可索引 ID 已读表达的数据源）。
   *
   * 私信会话行的未读点与私信 Tab「全部已读」可用性均由该快照推导；
   * 任何通知版本变化（轮询合并 / 单条已读 / 全部已读）都需刷新它。
   * 同步时同时重建 mid → 未读 Map，行查询从 O(n) 降为 O(1)；
   * 私信 Tab 下额外强制刷新会话行（unreadByMid 非响应式，见 refreshThreadUnreadRows）。
   */
  private syncMessageNotificationsFromStore(): void {
    const cached: NgaNotification[] = appStore.getCachedNotifications()
    const result: MessageNotification[] = []
    const unreadMap: Map<string, boolean> = new Map<string, boolean>()
    for (let index: number = 0; index < cached.length; index++) {
      const item: NgaNotification = cached[index]
      if (isMessageNotificationType(item.type)) {
        const message: MessageNotification = item as MessageNotification
        result.push(message)
        if (!message.seen) {
          unreadMap.set(message.mid, true)
        }
      }
    }
    this.messageNotifications = result
    this.unreadByMid = unreadMap
    if (this.activeTab === TAB_PRIVATE && this.threadsDataSource.totalCount() > 0) {
      this.refreshThreadUnreadRows()
    }
  }

  /**
   * 强制刷新私信会话行的未读表现（未读点、标题字色/字重）。
   *
   * 行未读状态由 unreadByMid（非响应式 Map）在 build 时推导，重建 Map 本身
   * 不会驱动 LazyForEach 重算行 key（key 含未读位，见行渲染处）；对每行
   * updateAt 发出数据变更通知后，未读位发生变化的行才会重建并呈现最新状态。
   */
  private refreshThreadUnreadRows(): void {
    const total: number = this.threadsDataSource.totalCount()
    for (let index: number = 0; index < total; index++) {
      this.threadsDataSource.updateAt(index, this.threadsDataSource.getData(index))
    }
  }

  /**
   * 从动态 Store 同步内存真源快照，尽量做增量更新避免打断滚动。
   *
   * displayActivities 是内存唯一真源（首屏缓存 + 分页追加），按 id 序列比较
   * 三种同步形态：
   * - 快照以旧列表开头（旧列表是快照的前缀）→ 尾部追加（loadMore）→ appendAll；
   * - 快照以旧列表结尾（旧列表是快照的后缀）→ 头部新增（轮询命中新动态）→ prependAll；
   * - 其余情况（首次加载、重排、截断等）→ replaceAll。
   */
  private syncActivitiesFromStore(): void {
    const snapshot: FollowedActivity[] = appStore.getDisplayActivities()
    this.activities = snapshot
    const oldCount: number = this.activitiesDataSource.totalCount()
    if (oldCount === 0 || snapshot.length === 0) {
      this.activitiesDataSource.replaceAll(snapshot)
      return
    }
    if (snapshot.length > oldCount && this.idsMatch(snapshot, 0, oldCount)) {
      // 尾部追加：分页加载的新段（仅追加，不打断当前视口）
      const added: FollowedActivity[] = []
      for (let index: number = oldCount; index < snapshot.length; index++) {
        added.push(snapshot[index])
      }
      this.activitiesDataSource.appendAll(added)
      return
    }
    if (snapshot.length > oldCount && this.idsMatch(snapshot, snapshot.length - oldCount, oldCount)) {
      // 头部新增：轮询命中的新动态段
      const added: FollowedActivity[] = []
      for (let index: number = 0; index < snapshot.length - oldCount; index++) {
        added.push(snapshot[index])
      }
      this.activitiesDataSource.prependAll(added)
      return
    }
    this.activitiesDataSource.replaceAll(snapshot)
  }

  /**
   * 判断快照从 snapshotStart 起与旧数据源 id 序列是否逐项一致。
   *
   * @param snapshot - 新快照
   * @param snapshotStart - 快照比较起点
   * @param count - 比较条数
   * @returns 是否逐项一致
   */
  private idsMatch(snapshot: FollowedActivity[], snapshotStart: number, count: number): boolean {
    for (let index: number = 0; index < count; index++) {
      if (snapshot[snapshotStart + index].id !== this.activitiesDataSource.getData(index).id) {
        return false
      }
    }
    return true
  }

  /**
   * 刷新通知并仅在当前页面出现周期内更新页面快照。
   *
   * @param appearanceGeneration - 请求发起时的页面出现周期版本号
   */
  private async loadNotifications(appearanceGeneration: number): Promise<void> {
    this.isLoading = this.notifications.length === 0
    this.hasError = false
    this.titleScrollEffectProgress = 0
    const success: boolean = await appStore.refreshNotifications(true)
    if (!this.scope.isActive(appearanceGeneration)) {
      return
    }
    this.syncNotificationsFromStore()
    if (!success) {
      if (this.notifications.length > 0) {
        appStore.showToast('刷新通知失败')
      } else {
        this.hasError = true
        this.errorMsg = '加载失败'
      }
    }
    this.isLoading = false
  }

  /**
   * 刷新关注动态并仅在当前页面出现周期内更新页面快照。
   *
   * @param appearanceGeneration - 请求发起时的页面出现周期版本号
   */
  private async loadActivities(appearanceGeneration: number): Promise<void> {
    if (!appStore.auth.isAuthenticated) {
      // 未登录：不发请求，登录引导空态由 UI 分支负责
      this.activitiesLoading = false
      return
    }
    this.activitiesLoading = this.activities.length === 0
    this.activitiesError = false
    this.titleScrollEffectProgress = 0
    const success: boolean = await appStore.refreshActivities(true)
    if (!this.scope.isActive(appearanceGeneration)) {
      return
    }
    this.syncActivitiesFromStore()
    if (!success) {
      if (this.activities.length > 0) {
        appStore.showToast('刷新动态失败')
      } else {
        this.activitiesError = true
        this.errorMsg = '加载失败'
      }
    }
    this.activitiesLoading = false
  }

  /**
   * 加载关注动态下一页（委托 store：并发防护与账号代际校验均在 store 内）。
   */
  private async loadMoreActivities(): Promise<void> {
    if (this.isLoadingMore) {
      return
    }
    const totalPages: number = appStore.getActivityTotalPages()
    if (totalPages > 0 && appStore.getActivityLoadedPages() >= totalPages) {
      return
    }
    this.isLoadingMore = true
    try {
      await appStore.loadMoreActivities()
    } finally {
      if (this.scope.isAlive()) {
        this.isLoadingMore = false
      }
    }
  }

  /**
   * 刷新私信会话列表并仅在当前页面出现周期内更新页面快照。
   *
   * 有数据时静默刷新（不显示全屏加载态），无数据时显示首屏加载态；
   * 成功后同步通知状态（与私信列表面板行为一致）。
   * 快照复用窗口（PRIVATE_REFRESH_WINDOW_MS）内切 Tab 直接复用现有列表
   * 不发请求；force=true（详情返回 messageVersion 信号）时强制刷新。
   *
   * @param appearanceGeneration - 请求发起时的页面出现周期版本号
   * @param force - 是否忽略快照复用窗口强制请求
   */
  private async loadPrivateMessages(appearanceGeneration: number, force: boolean = false): Promise<void> {
    if (!appStore.auth.isAuthenticated) {
      // 未登录：不发请求，登录引导空态由 UI 分支负责
      this.privateLoading = false
      return
    }
    if (!force && this.threads.length > 0 &&
      Date.now() - this.lastPrivateRefreshMs < PRIVATE_REFRESH_WINDOW_MS) {
      // 快照复用窗口内：直接使用现有列表（不打断滚动、不重复请求）
      this.privateLoading = false
      return
    }
    this.privateLoading = this.threads.length === 0
    this.privateError = false
    this.titleScrollEffectProgress = 0
    try {
      const result: MessageListResult = await getMessageList(appStore.auth.token, '1')
      if (!this.scope.isActive(appearanceGeneration)) {
        return
      }
      if (result.ok && result.data) {
        this.mergePrivateSnapshot(result.data.messageEntryList, result.data.nextPage)
        this.lastPrivateRefreshMs = Date.now()
        this.privateLoading = false
        await appStore.refreshNotifications(true)
        return
      }
      if (this.threads.length === 0) {
        this.privateError = true
        this.errorMsg = '加载失败'
      } else {
        appStore.showToast('刷新私信失败')
      }
    } catch (e) {
      if (this.scope.isActive(appearanceGeneration)) {
        if (this.threads.length === 0) {
          this.privateError = true
          this.errorMsg = '加载失败'
        } else {
          appStore.showToast('刷新私信失败')
        }
      }
    }
    if (this.scope.isActive(appearanceGeneration)) {
      this.privateLoading = false
    }
  }

  /**
   * 增量合并私信快照：旧列表与快照前缀（mid 序列）一致时逐行更新变化字段、
   * 尾部追加新增会话，保留滚动位置与已分页上下文；否则整体替换并重置分页游标。
   *
   * 快照可能短于旧列表（分页后刷新仅返回第 1 页）：前缀一致时仅更新重叠部分，
   * 已分页尾部保留。合并后 this.threads 恒等于 dataSource 内容
   * （threads 仅作空态/加载态判定，行渲染走 dataSource）。
   *
   * @param snapshot - 本次拉取的第 1 页会话快照
   * @param nextPage - 本次拉取的下一页游标
   */
  private mergePrivateSnapshot(snapshot: MessageThreadInfo[], nextPage: number): void {
    const oldCount: number = this.threadsDataSource.totalCount()
    const overlap: number = oldCount > 0 && snapshot.length > 0
      ? Math.min(oldCount, snapshot.length) : 0
    if (overlap > 0 && this.threadIdsMatch(snapshot, 0, overlap)) {
      for (let index: number = 0; index < overlap; index++) {
        const current: MessageThreadInfo = this.threadsDataSource.getData(index)
        const next: MessageThreadInfo = snapshot[index]
        if (current.subject !== next.subject || current.lasttime !== next.lasttime ||
          current.posts !== next.posts || current.from_username !== next.from_username ||
          current.last_from_username !== next.last_from_username) {
          this.threadsDataSource.updateAt(index, next)
        }
      }
      if (snapshot.length > oldCount) {
        const added: MessageThreadInfo[] = []
        for (let index: number = oldCount; index < snapshot.length; index++) {
          added.push(snapshot[index])
        }
        this.threadsDataSource.appendAll(added)
      }
      // 分页上下文保留：游标取较大值（快照为第 1 页，旧列表已分页则继续旧游标）
      if (nextPage > this.privateNextPage) {
        this.privateNextPage = nextPage
      }
    } else {
      this.threadsDataSource.replaceAll(snapshot)
      this.privateNextPage = nextPage
    }
    const merged: MessageThreadInfo[] = []
    for (let index: number = 0; index < this.threadsDataSource.totalCount(); index++) {
      merged.push(this.threadsDataSource.getData(index))
    }
    this.threads = merged
  }

  /**
   * 判断快照从 snapshotStart 起与旧数据源 mid 序列是否逐项一致。
   *
   * @param snapshot - 新快照
   * @param snapshotStart - 快照比较起点
   * @param count - 比较条数
   * @returns 是否逐项一致
   */
  private threadIdsMatch(snapshot: MessageThreadInfo[], snapshotStart: number, count: number): boolean {
    for (let index: number = 0; index < count; index++) {
      if (snapshot[snapshotStart + index].mid !== this.threadsDataSource.getData(index).mid) {
        return false
      }
    }
    return true
  }

  /**
   * 加载私信会话列表下一页（服务端 nextPage 驱动，尾部追加不打断滚动）。
   *
   * 请求捕获当前代际：期间发生首屏/静默刷新（begin 新代际）或切 Tab 时
   * 结果将被丢弃，避免与 replaceAll/增量合并竞态；追加前按 mid 去重，
   * 防止游标回退造成的重复会话。
   */
  private async loadMorePrivateMessages(): Promise<void> {
    if (this.privateLoadingMore || this.privateNextPage <= 0) {
      return
    }
    if (!appStore.auth.isAuthenticated) {
      return
    }
    this.privateLoadingMore = true
    const generation: number = this.scope.begin()
    try {
      const result: MessageListResult = await getMessageList(appStore.auth.token, String(this.privateNextPage))
      if (!this.scope.isActive(generation)) {
        return
      }
      if (result.ok && result.data) {
        const knownMids: Set<string> = new Set<string>()
        for (let index: number = 0; index < this.threadsDataSource.totalCount(); index++) {
          knownMids.add(String(this.threadsDataSource.getData(index).mid))
        }
        const added: MessageThreadInfo[] = []
        for (let index: number = 0; index < result.data.messageEntryList.length; index++) {
          const item: MessageThreadInfo = result.data.messageEntryList[index]
          if (!knownMids.has(String(item.mid))) {
            knownMids.add(String(item.mid))
            added.push(item)
          }
        }
        if (added.length > 0) {
          this.threadsDataSource.appendAll(added)
          const merged: MessageThreadInfo[] = []
          for (let index: number = 0; index < this.threadsDataSource.totalCount(); index++) {
            merged.push(this.threadsDataSource.getData(index))
          }
          this.threads = merged
        }
        this.privateNextPage = result.data.nextPage
      } else {
        appStore.showToast('加载更多失败')
      }
    } catch (e) {
      appStore.showToast('加载更多失败')
    } finally {
      if (this.scope.isAlive()) {
        this.privateLoadingMore = false
      }
    }
  }

  /**
   * 列表滚动处理：动态 tab 下接近底部时触发分页加载，私信 tab 下触发会话分页。
   *
   * 数据项从列表索引 1 开始（索引 0 为筛选条占位），触发阈值
   * `endIndex >= 数据项数 - 2` 即等价换算的「数据项索引距尾部 3 项内」，
   * 与帖子列表范本的「距尾部 3 项内预加载」语义一致（无 off-by-one）。
   *
   * @param _startIndex - 当前可见起点列表索引（未使用）
   * @param endIndex - 当前可见终点列表索引（含筛选条占位）
   */
  private handleScrollIndex(_startIndex: number, endIndex: number): void {
    if (this.activeTab === TAB_ACTIVITIES) {
      const total: number = this.activitiesDataSource.totalCount()
      if (total > 0 && endIndex >= total - 2) {
        this.loadMoreActivities()
      }
      return
    }
    if (this.activeTab === TAB_PRIVATE) {
      const total: number = this.threadsDataSource.totalCount()
      if (total > 0 && endIndex >= total - 2) {
        this.loadMorePrivateMessages()
      }
    }
  }

  /** 判断当前动态列表是否包含未读动态。 */
  private hasUnreadActivities(): boolean {
    return this.activities.some((activity: FollowedActivity) => !activity.seen)
  }

  /**
   * 将单条动态标记为已读（点开帖子即已读，与消息规则一致）。
   *
   * store 与页面数据源可能持有不同引用：轮询合并会用 incoming 新对象替换
   * displayActivities 中同 id 条目，而无新增时不 bump 版本（页面快照保持旧引用
   * 以保护滚动）。因此除委托 store 外，还需对命中行强制置 seen 再 updateAt，
   * 保证行立即呈现已读（不能依赖「store 已改同一引用」的假设）。
   *
   * @param id - 动态 id
   */
  private markActivitySeen(id: string): void {
    const ids: Set<string> = new Set<string>()
    ids.add(id)
    appStore.markActivitiesSeen(ids)
    for (let index: number = 0; index < this.activitiesDataSource.totalCount(); index++) {
      const item: FollowedActivity = this.activitiesDataSource.getData(index)
      if (item !== undefined && item !== null && item.id === id) {
        if (!item.seen) {
          item.seen = true
        }
        this.activitiesDataSource.updateAt(index, item)
        return
      }
    }
  }

  /** 判断当前列表是否包含未读通知。 */
  private hasUnreadNotifications(): boolean {
    return this.notifications.some((notification: NotificationInfo) => !notification.seen)
  }

  /** 判断私信通知快照是否包含未读项（私信 Tab 全部已读可用性与标题栏按钮颜色）。 */
  private hasUnreadMessageNotifications(): boolean {
    return this.messageNotifications.some((notification: MessageNotification) => !notification.seen)
  }

  /**
   * 判断私信会话行是否存在未读（按可索引 ID 表达：该 mid 是否有未读私信通知）。
   *
   * @param mid - 私信会话 ID
   * @returns 是否存在未读私信通知
   */
  private hasUnreadForThread(mid: string): boolean {
    return this.unreadByMid.get(mid) === true
  }

  /** 判断当前选中 Tab 的系统是否存在未读项。 */
  private hasCurrentTabUnread(): boolean {
    if (this.activeTab === TAB_MESSAGES) {
      return this.hasUnreadNotifications()
    }
    if (this.activeTab === TAB_PRIVATE) {
      return this.hasUnreadMessageNotifications()
    }
    return this.hasUnreadActivities()
  }

  /**
   * 将当前选中 Tab 代表的系统全部标记为已读。
   *
   * 消息 tab：非私信通知全部已读；私信 tab：私信通知全部已读；
   * 动态 tab：关注动态全部已读。
   */
  private handleMarkAllSeen(): void {
    if (this.activeTab === TAB_MESSAGES) {
      if (!this.hasUnreadNotifications()) {
        return
      }
      appStore.markNonMessageNotificationsSeen()
      this.syncNotificationsFromStore()
      return
    }
    if (this.activeTab === TAB_PRIVATE) {
      if (!this.hasUnreadMessageNotifications()) {
        return
      }
      appStore.markMessageNotificationsSeen()
      this.syncMessageNotificationsFromStore()
      return
    }
    if (!this.hasUnreadActivities()) {
      return
    }
    // 先基于当前快照收集所有未读下标，再委托 store 全部置已读
    // （store 与行内元素同引用，已读后不可再依赖 !item.seen 事后判断）
    const unreadIndexes: number[] = []
    const total: number = this.activitiesDataSource.totalCount()
    for (let index: number = 0; index < total; index++) {
      const item: FollowedActivity = this.activitiesDataSource.getData(index)
      if (item !== undefined && item !== null && !item.seen) {
        unreadIndexes.push(index)
      }
    }
    appStore.markAllActivitiesSeen()
    // 对收集的下标强制置 seen 再 updateAt：store 与页面数据源可能引用不一致
    // （轮询合并会替换 displayActivities 中的对象而页面快照保持旧引用），
    // 不能依赖「元素 seen 已被 store 改掉」的假设
    for (let index: number = 0; index < unreadIndexes.length; index++) {
      const rowIndex: number = unreadIndexes[index]
      const item: FollowedActivity = this.activitiesDataSource.getData(rowIndex)
      if (item !== undefined && item !== null) {
        if (!item.seen) {
          item.seen = true
        }
        this.activitiesDataSource.updateAt(rowIndex, item)
      }
    }
    // 触发 @State 引用变化，让 hasCurrentTabUnread() 重算（标题栏按钮颜色更新）
    this.activities = this.activities.slice()
  }

  /** 筛选条切换：切换数据源并触发对应列表刷新。 */
  private handleTabClicked(index: number): void {
    if (this.activeTab === index) {
      return
    }
    this.activeTab = index
    this.tabSelected = [index]
    const generation: number = this.scope.begin()
    if (index === TAB_MESSAGES) {
      this.syncNotificationsFromStore()
      this.loadNotifications(generation)
    } else if (index === TAB_PRIVATE) {
      this.syncMessageNotificationsFromStore()
      this.loadPrivateMessages(generation)
    } else {
      this.syncActivitiesFromStore()
      this.loadActivities(generation)
    }
    // 内容已切换，滚动回到顶部（等待列表重建完成）
    setTimeout((): void => {
      if (this.scope.isAlive()) {
        this.scroller.scrollEdge(Edge.Top)
      }
    }, 0)
  }

  /**
   * 标记并打开一个私信会话：按可索引 ID 精确标记该会话的私信通知已读，
   * 刷新快照（行未读点消失）后进入私信详情。
   *
   * @param thread - 被点击的私信会话
   */
  private handleThreadClick(thread: MessageThreadInfo): void {
    const mid: string = String(thread.mid)
    appStore.markMessageNotificationsSeenByMid(mid)
    this.syncMessageNotificationsFromStore()
    routerStore.navigateActivity(Screen.messageDetail(mid))
  }

  /**
   * 未读数变化时重建筛选条文案（消息(9) / 私信(3) / 动态(99+) 形式）。
   */
  private onUnreadCountChange(): void {
    this.rebuildTabOptions()
  }

  /**
   * 重建筛选条分段按钮文案：未读数以括号文本拼入按钮文本，未读为 0 时不带后缀。
   */
  private rebuildTabOptions(): void {
    this.tabOptions = SegmentButtonOptions.capsule({
      buttons: [
        { text: this.badgeLabel('消息', this.unreadNotiCount) },
        { text: this.badgeLabel('私信', this.unreadMessageCount) },
        { text: this.badgeLabel('动态', this.unreadActivityCount) }
      ] as SegmentButtonItemTuple,
      multiply: false,
      fontColor: AppColors.textSecondary,
      selectedFontColor: AppColors.primary,
      fontSize: 13,
      selectedFontSize: 13,
      fontWeight: FontWeight.Normal,
      selectedFontWeight: FontWeight.Bold,
      backgroundColor: AppColors.bgSecondary,
      selectedBackgroundColor: AppColors.primaryLight,
    })
  }

  /**
   * 生成带未读后缀的 Tab 文案。
   *
   * @param base - 基础文案
   * @param count - 未读数
   * @returns 未读大于 0 时为 `${base}(数量)`，否则为 base 本身
   */
  private badgeLabel(base: string, count: number): string {
    return count > 0 ? `${base}(${this.formatBadgeCount(count)})` : base
  }

  /**
   * 将未读数格式化为 Tab 文案后缀（0 隐藏、超过 99 显示 99+）。
   *
   * @param count - 未读数
   * @returns 角标文本
   */
  private formatBadgeCount(count: number): string {
    if (count <= 0) {
      return ''
    }
    return count > 99 ? '99+' : String(count)
  }

  /**
   * 获取通知行的主要标题。
   *
   * 注意：私信通知（type 10/11）已迁出消息 Tab，`category === 'message'`
   * 分支为防御性保留（当前不可达），维护时勿据此以为消息 Tab 仍含私信。
   *
   * @param notification - 通知记录
   * @returns 主题标题或通知类别标题
   */
  private getNotificationTitle(notification: NotificationInfo): string {
    if (notification.title.length > 0) {
      return unescapeHtml(notification.title)
    }
    const info = NOTI_TYPE_MAP[notification.type]
    if (info && info.category === 'message') {
      return '私信'
    }
    return '通知'
  }

  /**
   * 获取通知行的动作说明。
   *
   * @param notification - 通知记录
   * @returns 用户可读的通知动作
   */
  private getNotificationAction(notification: NotificationInfo): string {
    const info = NOTI_TYPE_MAP[notification.type]
    return info ? info.label : '通知'
  }

  /**
   * 获取通知行的次要描述。
   *
   * @param notification - 通知记录
   * @returns 发起用户、用户备注和通知动作组成的描述
   */
  private getNotificationDescription(notification: NotificationInfo): string {
    const action: string = this.getNotificationAction(notification)
    if (notification.userName.length === 0) {
      return action
    }
    const userName: string = unescapeHtml(notification.userName)
    const note: string = appStore.settingsStore.getNote(notification.userId)
    const actor: string = note.length > 0 ? `${userName} (${note})` : userName
    return `${actor} ${action}`
  }

  /**
   * 将服务端页码提示转换为可用页码。
   *
   * @param page - 服务端页码字符串
   * @returns 至少为 1 的整数页码
   */
  private resolvePage(page: string): number {
    const parsedPage: number = Number(page)
    if (!Number.isFinite(parsedPage) || parsedPage < 1) {
      return 1
    }
    return Math.floor(parsedPage)
  }

  /**
   * 获取帖子互动通知应定位的楼层。
   *
   * @param notification - 帖子互动通知
   * @returns 目标楼层 ID
   */
  private resolveReplyTargetPid(notification: ReplyNotification): string {
    return this.normalizeTargetPid(notification.replyPid)
  }

  /**
   * 将主楼 PID 提示转换为主题顶部导航。
   *
   * @param pid - NGA 楼层 ID
   * @returns 可传给帖子路由的目标楼层 ID
   */
  private normalizeTargetPid(pid: string): string {
    return pid === '0' ? '' : pid
  }

  /**
   * 服务端提示页码是否可信（正整数）。
   *
   * 官方 APP 通知中仅帖子互动类（回复/评论）携带页码；支持或反对（type=17）
   * 实测 about_id4 恒为 0，不提供页码线索，必须走 pid→页码预查找。
   *
   * @param page - 服务端页码字符串
   * @returns 是否为可信页码
   */
  private hasValidPage(page: string): boolean {
    const parsedPage: number = Number(page)
    // 与服务端页码语义对齐：仅正整数可信（非整数/科学计数/溢出均不可信，
    // 避免与 resolvePage 的向下取整产生不一致而重新落入单帖兜底路径）
    return Number.isInteger(parsedPage) && parsedPage >= 1
  }

  /**
   * 仅携带 pid 的通知/动态：先完成 pid→页码数据查找，再以正确页码打开帖子。
   *
   * 与回帖列表/链接入口同一模式。官方 APP 的支持或反对通知（about_id4 恒 0）
   * 与关注动态（无页码字段）不携带楼层页码：若直接按第 1 页打开，ThreadPanel
   * 页内找不到目标 pid 会触发单帖兜底——服务端单帖视图把 lou 重置为 0，
   * UI 误标「楼主」并错乱拼接后续相邻页。先二分定位页码即可让整页加载后
   * 页内正常定位。
   * 查找失败（楼层已删除/请求异常）时退化为不带定位意图地打开第 1 页。
   * 带代际防重入：连点多条时只执行最新一次；面板离开后在途查找作废。
   *
   * @param tid - 主题 ID
   * @param pid - 目标楼层 pid（已归一，非 '0'）
   * @param source - 打开帖子的路由来源（ThreadSource 枚举值；动态入口无对应来源传空串）
   */
  private async openThreadAfterPidLookup(tid: string, pid: string, source: string): Promise<void> {
    const generation: number = ++this.pidLookupGeneration
    // 接管全局定位指示器：总步数由 locatePidPage 在末页请求后确定（1 + ⌈log₂总页数⌉）
    const progressGeneration: number = pidLocateProgress.begin()
    this.pidLocateGeneration = progressGeneration
    try {
      const page: number = await locatePidPage(appStore.auth.token, tid, parseInt(pid, 10),
        (done: number, total: number): void => {
          // 过期查找的进度回调不得污染最新一次显示（本地代际 + 全局代际双校验）
          if (generation !== this.pidLookupGeneration) {
            return
          }
          pidLocateProgress.show(progressGeneration, done, total)
        })
      if (generation !== this.pidLookupGeneration) {
        // 已有更新的点击或面板已离开：丢弃过期结果（指示器由最新一次调用接管）
        return
      }
      if (page > 0) {
        routerStore.navigateActivity(Screen.thread(tid, page, pid, source))
      } else {
        // 定位失败（楼层已删除/请求异常）：打开帖子首页并告知
        appStore.showToast('未能定位到该楼层，已打开帖子首页')
        routerStore.navigateActivity(Screen.thread(tid, 1, '', source))
      }
    } finally {
      // 无论查找成功/失败/异常，均归还指示器（过期查找由新接管者负责，此处代际校验避免误伤）
      if (generation === this.pidLookupGeneration) {
        pidLocateProgress.hide(progressGeneration)
        this.pidLocateGeneration = -1
      }
    }
  }

  /**
   * 标记并打开一条具体通知。
   *
   * 注意：私信通知（type 10/11）已迁出消息 Tab，`category === 'message'`
   * 分支为防御性保留（当前不可达），私信会话入口在私信 Tab 的会话行。
   *
   * @param notification - 被点击的通知
   */
  private handleNotificationClick(notification: NotificationInfo): void {
    const info = NOTI_TYPE_MAP[notification.type]
    if (info && info.category === 'message') {
      const message: MessageNotification = notification as MessageNotification
      if (message.mid.length === 0) {
        return
      }
      appStore.markNotificationSeen(notification.notificationId)
      this.syncNotificationsFromStore()
      routerStore.navigateActivity(Screen.messageDetail(message.mid))
    } else if (notification.type === 17) {
      const upvote: UpvoteNotification = notification as UpvoteNotification
      if (upvote.tid.length > 0) {
        appStore.markNotificationSeen(notification.notificationId)
        this.syncNotificationsFromStore()
        const targetPid: string = this.normalizeTargetPid(upvote.pid)
        if (targetPid.length > 0 && !this.hasValidPage(upvote.page)) {
          // 官方 APP 支持或反对通知不返回楼层页码：先 pid→页码预查找再打开
          this.openThreadAfterPidLookup(upvote.tid, targetPid, ThreadSource.NOTIFICATION)
        } else {
          routerStore.navigateActivity(
            Screen.thread(upvote.tid, this.resolvePage(upvote.page), targetPid,
              ThreadSource.NOTIFICATION)
          )
        }
      }
    } else {
      const reply: ReplyNotification = notification as ReplyNotification
      if (reply.tid.length > 0) {
        const targetPid: string = this.resolveReplyTargetPid(reply)
        appStore.markNotificationSeen(notification.notificationId)
        this.syncNotificationsFromStore()
        if (targetPid.length > 0 && !this.hasValidPage(reply.page)) {
          // 服务端未提供页码时先 pid→页码预查找，与支持或反对通知同一模式
          this.openThreadAfterPidLookup(reply.tid, targetPid, ThreadSource.NOTIFICATION)
        } else {
          routerStore.navigateActivity(Screen.thread(reply.tid, this.resolvePage(reply.page), targetPid,
            ThreadSource.NOTIFICATION))
        }
      }
    }
  }

  /** 生成动态的可见动作描述（对齐 NGA 网页端语义）。 */
  private describeAction(activity: FollowedActivity): string {
    const isReply: boolean = activity.pid.length > 0 && activity.pid !== '0'
    if (activity.type === FollowedActivityType.POST_TOPIC) {
      return isReply ? '发布了回复' : '发布了主题'
    }
    if (activity.type === FollowedActivityType.POST_REPLY) {
      return '回复了帖子'
    }
    if (activity.type === FollowedActivityType.FAVOR) {
      return isReply ? '收藏了回复' : '收藏了主题'
    }
    return '发布了动态'
  }

  /** 动态主题标题（data[4] 缺失时以 tid 兜底）。 */
  private activitySubject(activity: FollowedActivity): string {
    const subject: string = unescapeHtml(activity.subject)
    return subject.length > 0 ? subject : `主题 ${activity.tid}`
  }

  /** 动态行为者显示名（data[1] 缺失时以 uid 兜底）。 */
  private activityActor(activity: FollowedActivity): string {
    const name: string = unescapeHtml(activity.actorName)
    return name.length > 0 ? name : `用户 ${activity.actorUid}`
  }

  /** 动态类型图标。 */
  private activityIcon(activity: FollowedActivity): Resource {
    if (activity.type === FollowedActivityType.FAVOR) {
      return $r('app.media.icon_star')
    }
    if (activity.type === FollowedActivityType.POST_REPLY) {
      return $r('app.media.icon_reply')
    }
    return $r('app.media.icon_chat_bubble')
  }

  /**
   * 私信会话的展示发送者名。
   *
   * 系统消息会话（官方接口 from_uid=0）的 from_username / last_from_username
   * 均为空串（实测 APP 签名接口与网页版一致），此处兜底为「系统消息」，
   * 避免会话行副文本渲染成「· N条消息」缺人名。
   *
   * @param thread - 私信会话
   * @returns 展示名
   */
  private threadActorName(thread: MessageThreadInfo): string {
    const name: string = unescapeHtml(thread.last_from_username || thread.from_username)
    return name.length > 0 ? name : '系统消息'
  }

  /** 跳转到动态对应的帖子（回复定位楼层）；点开即标记该动态已读。 */
  private openActivity(activity: FollowedActivity): void {
    if (activity.tid.length === 0) {
      return
    }
    this.markActivitySeen(activity.id)
    if (activity.pid.length > 0 && activity.pid !== '0') {
      // 关注动态不携带楼层页码：先 pid→页码预查找再打开，避免单帖兜底错乱
      this.openThreadAfterPidLookup(activity.tid, activity.pid, '')
    } else {
      routerStore.navigateActivity(Screen.thread(activity.tid))
    }
  }

  /** 状态视图撑满筛选条下方的列表可视区高度。 */
  private getStateViewHeight(): number {
    // 筛选条底部坐标尚未实测（首帧）时用标题区高度 + 筛选条占位估算兜底，避免高度跳变
    const topOffset: number = this.sortBarBottomY > 0
      ? this.sortBarBottomY
      : TitleScrollEffect.getContentStartOffset(this.statusBarHeight) + 50
    return Math.max(this.listViewportHeight - topOffset, 400)
  }

  build() {
    Stack() {
      Column() {
        List({ scroller: this.scroller }) {
          ListItem() {
            Row() {
              SegmentButton({
                options: this.tabOptions,
                selectedIndexes: $tabSelected,
                onItemClicked: (index: number): void => {
                  this.handleTabClicked(index)
                }
              })
            }
            .width('100%')
            .padding({ left: '4%', right: '4%' })
            .margin({ top: 8, bottom: 6 })
            .onAreaChange((_oldValue: Area, newValue: Area): void => {
              // 采集筛选条底部纵坐标：供状态视图撑满筛选条下方的列表可视区
              if (typeof newValue.globalPosition.y === 'number' && typeof newValue.height === 'number') {
                this.sortBarBottomY = newValue.globalPosition.y + newValue.height
              }
            })
          }

          if (this.activeTab === TAB_MESSAGES) {
            if (this.isLoading) {
              ListItem() {
                Column() {
                  LoadingStateView()
                }
                .width('100%').height(this.getStateViewHeight())
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
              }
            } else if (this.hasError) {
              ListItem() {
                Column() {
                  ErrorStateView({ msg: this.errorMsg, onRetry: () => this.loadNotifications(this.scope.begin()) })
                }
                .width('100%').height(this.getStateViewHeight())
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
              }
            } else if (this.notifications.length === 0) {
              ListItem() {
                Column() {
                  EmptyStateView({ msg: '暂无通知', icon: $r('app.media.icon_bell') })
                }
                .width('100%').height(this.getStateViewHeight())
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
              }
            } else {
              LazyForEach(this.notificationsDataSource, (n: NotificationInfo) => {
                ListItem() {
                  Row() {
                    Circle()
                      .width(7)
                      .height(7)
                      .fill(AppColors.primary)
                      .opacity(n.seen ? 0 : 1)
                      .margin({ right: 9 })
                    if (n.userName.length > 0) {
                      Avatar({ name: n.userName, uid: n.userId, avatarSize: 40 })
                        .opacity(n.seen ? 0.72 : 1)
                        .margin({ right: 10 })
                    } else {
                      Stack() {
                        Image(getNotiIcon(n.type))
                          .width(20)
                          .height(20)
                          .fillColor(n.seen ? AppColors.textTertiary : AppColors.primary)
                      }
                      .width(40)
                      .height(40)
                      .backgroundColor(AppColors.bgSecondary)
                      .borderRadius(20)
                      .margin({ right: 10 })
                    }
                    Column() {
                      Row() {
                        Text(this.getNotificationTitle(n))
                          .fontSize(15)
                          .fontColor(n.seen ? AppColors.textSecondary : AppColors.textPrimary)
                          .fontWeight(n.seen ? FontWeight.Normal : FontWeight.Medium)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .layoutWeight(1)
                        Text(formatTime(Number(n.timeStamp)))
                          .fontSize(12)
                          .fontColor(AppColors.textTertiary)
                          .margin({ left: 12 })
                      }.width('100%').alignItems(VerticalAlign.Center)
                      Text(this.getNotificationDescription(n))
                        .fontSize(13)
                        .fontColor(n.seen ? AppColors.textTertiary : AppColors.textSecondary)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ top: 5 })
                        .width('100%')
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                  }.width('100%').padding({ left: 16, right: 16, top: 13, bottom: 13 })
                  .alignItems(VerticalAlign.Center)
                  // 行背景透明，露出 Stack 的 bg（与帖子列表 TopicCard 的透明策略一致）：
                  // 实色行滚动侵入标题区时会被 linearGradientBlur 在行边缘产生模糊过渡带，
                  // 与压暗层衰减叠加形成硬边界/色带；透明行让标题区内外底色恒为 Stack bg，无缝融合。
                  .onClick(() => this.handleNotificationClick(n))
                }
              }, (n: NotificationInfo) => `${n.notificationId}_${n.seen}`)
            }
          } else if (this.activeTab === TAB_PRIVATE) {
            if (!appStore.auth.isAuthenticated) {
              ListItem() {
                Column() {
                  EmptyStateView({ msg: '登录后查看私信', icon: $r('app.media.icon_mail') })
                }
                .width('100%').height(this.getStateViewHeight())
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
              }
            } else if (this.privateLoading) {
              ListItem() {
                Column() {
                  LoadingStateView()
                }
                .width('100%').height(this.getStateViewHeight())
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
              }
            } else if (this.privateError) {
              ListItem() {
                Column() {
                  ErrorStateView({ msg: this.errorMsg, onRetry: () => this.loadPrivateMessages(this.scope.begin()) })
                }
                .width('100%').height(this.getStateViewHeight())
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
              }
            } else if (this.threads.length === 0) {
              ListItem() {
                Column() {
                  EmptyStateView({ msg: '暂无私信', icon: $r('app.media.icon_mail') })
                }
                .width('100%').height(this.getStateViewHeight())
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
              }
            } else {
              LazyForEach(this.threadsDataSource, (thread: MessageThreadInfo) => {
                ListItem() {
                  Row() {
                    Circle()
                      .width(7)
                      .height(7)
                      .fill(AppColors.primary)
                      .opacity(this.hasUnreadForThread(String(thread.mid)) ? 1 : 0)
                      .margin({ right: 9 })
                    Avatar({ name: this.threadActorName(thread), avatarSize: 40 })
                      .margin({ right: 10 })
                    Column() {
                      Row() {
                        Text(unescapeHtml(thread.subject))
                          .fontSize(15)
                          .fontColor(this.hasUnreadForThread(String(thread.mid))
                            ? AppColors.textPrimary : AppColors.textSecondary)
                          .fontWeight(this.hasUnreadForThread(String(thread.mid))
                            ? FontWeight.Medium : FontWeight.Normal)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .layoutWeight(1)
                        Text(formatTime(Number(thread.lasttime)))
                          .fontSize(12)
                          .fontColor(AppColors.textTertiary)
                          .margin({ left: 12 })
                      }.width('100%').alignItems(VerticalAlign.Center)
                      Text(`${this.threadActorName(thread)} · ${thread.posts}条消息`)
                        .fontSize(13)
                        .fontColor(AppColors.textTertiary)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ top: 5 })
                        .width('100%')
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                  }.width('100%').padding({ left: 16, right: 16, top: 13, bottom: 13 })
                  .alignItems(VerticalAlign.Center)
                  .onClick(() => { this.handleThreadClick(thread) })
                }
              }, (thread: MessageThreadInfo) =>
                `${String(thread.mid)}_${this.hasUnreadForThread(String(thread.mid)) ? '1' : '0'}`)

              ListItem() {
                Row() {
                  if (this.privateLoadingMore) {
                    LoadingProgress().width(16).height(16).color(AppColors.textTertiary)
                    Text('加载更多...').fontSize(13).fontColor(AppColors.textTertiary).margin({ left: 8 })
                  } else if (this.privateNextPage <= 0) {
                    Text('— 已到底 —').fontSize(12).fontColor(AppColors.textTertiary)
                  }
                }
                .width('100%').justifyContent(FlexAlign.Center).padding(16)
              }
            }
          } else {
            if (!appStore.auth.isAuthenticated) {
              ListItem() {
                Column() {
                  EmptyStateView({ msg: '登录后查看关注动态', icon: $r('app.media.icon_people') })
                }
                .width('100%').height(this.getStateViewHeight())
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
              }
            } else if (this.activitiesLoading) {
              ListItem() {
                Column() {
                  LoadingStateView()
                }
                .width('100%').height(this.getStateViewHeight())
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
              }
            } else if (this.activitiesError) {
              ListItem() {
                Column() {
                  ErrorStateView({ msg: this.errorMsg, onRetry: () => this.loadActivities(this.scope.begin()) })
                }
                .width('100%').height(this.getStateViewHeight())
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
              }
            } else if (this.activities.length === 0) {
              ListItem() {
                Column() {
                  EmptyStateView({ msg: '暂无关注动态，先去关注感兴趣的用户吧', icon: $r('app.media.icon_people') })
                }
                .width('100%').height(this.getStateViewHeight())
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
              }
            } else {
              LazyForEach(this.activitiesDataSource, (activity: FollowedActivity) => {
                ListItem() {
                  Row() {
                    Circle()
                      .width(7)
                      .height(7)
                      .fill(AppColors.primary)
                      .opacity(activity.seen ? 0 : 1)
                      .margin({ right: 9 })
                    Stack() {
                      Image(this.activityIcon(activity))
                        .width(20)
                        .height(20)
                        .fillColor(activity.seen ? AppColors.textTertiary : AppColors.primary)
                    }
                    .width(40)
                    .height(40)
                    .backgroundColor(AppColors.bgSecondary)
                    .borderRadius(20)
                    .margin({ right: 10 })
                    Column() {
                      Row() {
                        Text(this.activitySubject(activity))
                          .fontSize(15)
                          .fontColor(activity.seen ? AppColors.textSecondary : AppColors.textPrimary)
                          .fontWeight(activity.seen ? FontWeight.Normal : FontWeight.Medium)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .layoutWeight(1)
                        Text(formatTime(activity.timestamp))
                          .fontSize(12)
                          .fontColor(AppColors.textTertiary)
                          .margin({ left: 12 })
                      }.width('100%').alignItems(VerticalAlign.Center)
                      Text(`${this.activityActor(activity)} · ${this.describeAction(activity)}`)
                        .fontSize(13)
                        .fontColor(activity.seen ? AppColors.textTertiary : AppColors.textSecondary)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ top: 5 })
                        .width('100%')
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                  }.width('100%').padding({ left: 16, right: 16, top: 13, bottom: 13 })
                  .alignItems(VerticalAlign.Center)
                  // 行背景透明，露出 Stack 的 bg（与帖子列表 TopicCard 的透明策略一致）
                  .onClick(() => { this.openActivity(activity) })
                }
              }, (activity: FollowedActivity) => `${activity.id}_${activity.seen}`)

              ListItem() {
                Row() {
                  if (this.isLoadingMore) {
                    LoadingProgress().width(16).height(16).color(AppColors.textTertiary)
                    Text('加载更多...').fontSize(13).fontColor(AppColors.textTertiary).margin({ left: 8 })
                  } else if (appStore.getActivityTotalPages() > 0 &&
                    appStore.getActivityLoadedPages() >= appStore.getActivityTotalPages()) {
                    Text('— 已到底 —').fontSize(12).fontColor(AppColors.textTertiary)
                  }
                }
                .width('100%').justifyContent(FlexAlign.Center).padding(16)
              }
            }
          }
        }
        .width('100%').layoutWeight(1)
        .scrollBar(BarState.Off)
        .divider({ strokeWidth: 0.5, color: AppColors.separator })
        .lanes(new BreakpointType(1, 1, 1).getValue(this.currentBreakpoint), 12)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(3)
        .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
        .linearGradientBlur(
          TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),
          {
            fractionStops: TitleScrollEffect.getBlurStops(this.listViewportHeight, this.statusBarHeight),
            direction: GradientDirection.Bottom
          }
        )
        .onAreaChange((_oldValue: Area, newValue: Area): void => {
          if (typeof newValue.height === 'number' && newValue.height > 0 &&
            newValue.height !== this.listViewportHeight) {
            this.listViewportHeight = newValue.height
          }
        })
        .onDidScroll((): void => {
          this.syncTitleScrollEffect()
        })
        .onAppear((): void => {
          this.syncTitleScrollEffect()
        })
        .onScrollIndex((start: number, end: number): void => {
          this.handleScrollIndex(start, end)
        })
      }
      .width('100%').height('100%')

      PanelNavBar({
        title: '通知',
        scrollEffectProgress: this.titleScrollEffectProgress,
        // 私信 tab：主图标为写私信，次图标为全部已读；其余 tab 主图标为全部已读
        rightIcon: this.activeTab === TAB_PRIVATE
          ? $r('app.media.icon_compose') : $r('app.media.icon_nav_mark_all_read'),
        rightIconColor: this.activeTab === TAB_PRIVATE
          ? '' : (this.hasCurrentTabUnread() ? AppColors.primary : AppColors.textTertiary),
        rightIconAccessibilityText: this.activeTab === TAB_PRIVATE ? '写私信' : '全部标记为已读',
        onRightClick: (): void => {
          if (this.activeTab === TAB_PRIVATE) {
            this.showCompose = true
          } else {
            this.handleMarkAllSeen()
          }
        },
        secondaryRightIcon: this.activeTab === TAB_PRIVATE
          ? $r('app.media.icon_nav_mark_all_read') : '',
        secondaryRightIconColor: this.activeTab === TAB_PRIVATE
          ? (this.hasCurrentTabUnread() ? AppColors.primary : AppColors.textTertiary) : '',
        secondaryRightIconAccessibilityText: '全部标记为已读',
        onSecondaryRightClick: (): void => {
          this.handleMarkAllSeen()
        }
      })
        .width('100%').position({ x: 0, y: 0 })

      ComposeMessageSheet({
        showCompose: $showCompose,
        composeToInit: this.composeToInit,
        onSent: (): void => {
          this.loadPrivateMessages(this.scope.begin())
        }
      })
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg)
  }
}
