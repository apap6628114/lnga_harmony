/**
 * 通知面板 - 消息 / 关注动态 双筛选
 *
 * 标题区与帖子 UI（TopicListPanel）保持一致：左侧返回 + 标题「通知」，
 * 筛选项（消息/动态）作为列表首个元素随内容滚动穿越标题区。
 * - 消息：通知中心数据（回复/私信/点赞提醒），点击已读 / 全部已读；
 * - 动态：关注动态流，数据来自 FollowActivityStore（轮询/条件抓取/缓存），
 *   已读规则与消息一致：点开帖子才标记已读，右上角「全部已读」作用于当前 Tab 的系统。
 */

import { appStore } from '../store/AppStore'
import { routerStore, Screen, ThreadSource } from '../store/RouterStore'
import type {
  MessageNotification,
  NotificationInfo,
  ReplyNotification,
  UpvoteNotification
} from '../model/Notification'
import { FollowedActivity, FollowedActivityType } from '../model/Follow'
import { AppColors, BreakpointType, NOTI_TYPE_MAP, getNotiIcon } from '../common/constants/Constants'
import { formatTime } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { Avatar } from '../common/components/Avatar'
import { NotificationDataSource, FollowedActivityDataSource } from '../common/datasource/LazyDataSource'
import { LoadingStateView, ErrorStateView, EmptyStateView } from '../common/components/PageStateView'
import { PageScope } from '../common/concurrency/PageScope'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'
import {
  SegmentButton,
  SegmentButtonOptions,
  SegmentButtonItemTuple,
  SegmentButtonTextItem
} from '@kit.ArkUI'

/** 通知页筛选 Tab。 */
const TAB_MESSAGES: number = 0
const TAB_ACTIVITIES: number = 1

@Component
export struct NotificationPanel {
  /** 初始筛选 Tab（0=消息，1=动态）。 */
  @Prop initialTab: number = 0
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
  /** 当前筛选 Tab。 */
  @State activeTab: number = 0
  /** 筛选条分段按钮选项（原生 SegmentButton，胶囊单选）。 */
  @State tabOptions: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [
      { text: '消息' },
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
  /** 消息 Tab 未读数量（以括号文本拼入按钮文案，0 不显示）。 */
  @StorageProp('unreadNotiCount') @Watch('onUnreadCountChange') unreadNotiCount: number = 0
  /** 动态 Tab 未读数量（以括号文本拼入按钮文案，0 不显示）。 */
  @StorageProp('unreadActivityCount') @Watch('onUnreadCountChange') unreadActivityCount: number = 0
  private notificationsDataSource: NotificationDataSource = new NotificationDataSource()
  private activitiesDataSource: FollowedActivityDataSource = new FollowedActivityDataSource()
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
    const initialTab: number = this.initialTab === TAB_ACTIVITIES ? TAB_ACTIVITIES : TAB_MESSAGES
    this.activeTab = initialTab
    this.tabSelected = [initialTab]
    this.rebuildTabOptions()
    this.syncNotificationsFromStore()
    this.syncActivitiesFromStore()
    if (initialTab === TAB_ACTIVITIES) {
      this.loadActivities(currentGeneration)
    } else {
      this.loadNotifications(currentGeneration)
    }
  }

  /** 结束当前页面出现周期，使未完成的异步回调失效。 */
  aboutToDisappear(): void {
    this.scope.end()
  }

  /** 通知 Store 发布新版本时同步页面快照。 */
  private onNotificationVersionChange(): void {
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

  /** 从通知 Store 同步列表快照和懒加载数据源。 */
  private syncNotificationsFromStore(): void {
    this.notifications = appStore.getCachedNotifications() as NotificationInfo[]
    this.notificationsDataSource.replaceAll(this.notifications)
    if (this.notifications.length === 0) {
      this.titleScrollEffectProgress = 0
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
   * 列表滚动处理：动态 tab 下接近底部时触发分页加载。
   *
   * 数据项从列表索引 1 开始（索引 0 为筛选条占位），触发阈值
   * `endIndex >= 数据项数 - 2` 即等价换算的「数据项索引距尾部 3 项内」，
   * 与帖子列表范本的「距尾部 3 项内预加载」语义一致（无 off-by-one）。
   *
   * @param _startIndex - 当前可见起点列表索引（未使用）
   * @param endIndex - 当前可见终点列表索引（含筛选条占位）
   */
  private handleScrollIndex(_startIndex: number, endIndex: number): void {
    if (this.activeTab !== TAB_ACTIVITIES) {
      return
    }
    const total: number = this.activitiesDataSource.totalCount()
    if (total > 0 && endIndex >= total - 2) {
      this.loadMoreActivities()
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

  /** 判断当前选中 Tab 的系统是否存在未读项。 */
  private hasCurrentTabUnread(): boolean {
    if (this.activeTab === TAB_MESSAGES) {
      return this.hasUnreadNotifications()
    }
    return this.hasUnreadActivities()
  }

  /**
   * 将当前选中 Tab 代表的系统全部标记为已读。
   *
   * 消息 tab：通知中心全部已读；动态 tab：关注动态全部已读。
   */
  private handleMarkAllSeen(): void {
    if (this.activeTab === TAB_MESSAGES) {
      if (!this.hasUnreadNotifications()) {
        return
      }
      appStore.markAllNotificationsSeen()
      this.syncNotificationsFromStore()
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
   * 未读数变化时重建筛选条文案（消息(9) / 动态(99+) 形式）。
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
   * 标记并打开一条具体通知。
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
        routerStore.navigateActivity(
          Screen.thread(upvote.tid, this.resolvePage(upvote.page), this.normalizeTargetPid(upvote.pid),
            ThreadSource.NOTIFICATION)
        )
      }
    } else {
      const reply: ReplyNotification = notification as ReplyNotification
      if (reply.tid.length > 0) {
        const targetPid: string = this.resolveReplyTargetPid(reply)
        appStore.markNotificationSeen(notification.notificationId)
        this.syncNotificationsFromStore()
        routerStore.navigateActivity(Screen.thread(reply.tid, this.resolvePage(reply.page), targetPid,
          ThreadSource.NOTIFICATION))
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

  /** 跳转到动态对应的帖子（回复定位楼层）；点开即标记该动态已读。 */
  private openActivity(activity: FollowedActivity): void {
    if (activity.tid.length === 0) {
      return
    }
    this.markActivitySeen(activity.id)
    if (activity.pid.length > 0 && activity.pid !== '0') {
      routerStore.navigateActivity(Screen.thread(activity.tid, 1, activity.pid))
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
        rightIcon: $r('app.media.icon_nav_mark_all_read'),
        rightIconColor: this.hasCurrentTabUnread()
          ? AppColors.primary : AppColors.textTertiary,
        rightIconAccessibilityText: '全部标记为已读',
        onRightClick: (): void => {
          this.handleMarkAllSeen()
        }
      })
        .width('100%').position({ x: 0, y: 0 })
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg)
  }
}
