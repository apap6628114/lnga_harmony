/**
 * 通知面板
 */

import { appStore } from '../store/AppStore'
import { routerStore, Screen } from '../store/RouterStore'
import type {
  MessageNotification,
  NotificationInfo,
  ReplyNotification,
  UpvoteNotification
} from '../model/Notification'
import { AppColors, NOTI_TYPE_MAP, getNotiIcon } from '../common/constants/Constants'
import { formatTime } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { BreakpointType } from '../common/constants/Constants'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { Avatar } from '../common/components/Avatar'
import { NotificationDataSource } from '../common/datasource/LazyDataSource'
import { LoadingStateView, ErrorStateView, EmptyStateView } from '../common/components/PageStateView'
import { PageScope } from '../common/concurrency/PageScope'
import { KEY_IMMERSIVE_MATERIAL_ENABLED } from '../common/constants/AppStorageKeys'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'

@Component
export struct NotificationPanel {
  @State notifications: NotificationInfo[] = []
  @State isLoading: boolean = true
  @State hasError: boolean = false
  @State errorMsg: string = ''
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 是否启用沉浸式材质。 */
  @StorageProp(KEY_IMMERSIVE_MATERIAL_ENABLED) materialEnabled: boolean = true
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 列表当前视口高度。 */
  @State listViewportHeight: number = 1
  /** 通知 Store 的页面刷新信号。 */
  @StorageProp('notificationVersion') @Watch('onNotificationVersionChange') notificationVersion: number = 0
  private notificationsDataSource: NotificationDataSource = new NotificationDataSource()
  private scroller: Scroller = new Scroller()
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
    this.syncFromStore()
    this.loadNotifications(currentGeneration)
  }

  /** 结束当前页面出现周期，使未完成的异步回调失效。 */
  aboutToDisappear(): void {
    this.scope.end()
  }

  /** 通知 Store 发布新版本时同步页面快照。 */
  private onNotificationVersionChange(): void {
    this.syncFromStore()
  }

  /** 从通知 Store 同步列表快照和懒加载数据源。 */
  private syncFromStore(): void {
    this.notifications = appStore.getCachedNotifications() as NotificationInfo[]
    this.notificationsDataSource.replaceAll(this.notifications)
    if (this.notifications.length === 0) {
      this.titleScrollEffectProgress = 0
    }
  }

  /**
   * 刷新通知并仅在当前页面出现周期内更新页面快照。
   *
   * @param appearanceGeneration - 请求发起时的页面出现周期版本号
   */
  private async loadNotifications(appearanceGeneration: number): Promise<void> {
    this.isLoading = this.notifications.length === 0
    this.hasError = false
    const success: boolean = await appStore.refreshNotifications(true)
    if (!this.scope.isActive(appearanceGeneration)) {
      return
    }
    this.syncFromStore()
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

  /** 判断当前列表是否包含未读通知。 */
  private hasUnreadNotifications(): boolean {
    return this.notifications.some((notification: NotificationInfo) => !notification.seen)
  }

  /** 将当前账号的全部通知标记为已读。 */
  private handleMarkAllSeen(): void {
    if (!this.hasUnreadNotifications()) {
      return
    }
    appStore.markAllNotificationsSeen()
    this.syncFromStore()
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
      this.syncFromStore()
      routerStore.navigateActivity(Screen.messageDetail(message.mid))
    } else if (notification.type === 17) {
      const upvote: UpvoteNotification = notification as UpvoteNotification
      if (upvote.tid.length > 0) {
        appStore.markNotificationSeen(notification.notificationId)
        this.syncFromStore()
        routerStore.navigateActivity(
          Screen.thread(upvote.tid, this.resolvePage(upvote.page), this.normalizeTargetPid(upvote.pid))
        )
      }
    } else {
      const reply: ReplyNotification = notification as ReplyNotification
      if (reply.tid.length > 0) {
        const targetPid: string = this.resolveReplyTargetPid(reply)
        appStore.markNotificationSeen(notification.notificationId)
        this.syncFromStore()
        routerStore.navigateActivity(Screen.thread(reply.tid, this.resolvePage(reply.page), targetPid))
      }
    }
  }

  build() {
    Stack() {
      Column() {
        if (this.isLoading) {
          Row().width('100%').height(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          Column() {
            LoadingStateView()
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else if (this.hasError) {
          Row().width('100%').height(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          Column() {
            ErrorStateView({ msg: this.errorMsg, onRetry: () => this.loadNotifications(this.scope.begin()) })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else if (this.notifications.length === 0) {
          Row().width('100%').height(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          Column() {
            EmptyStateView({ msg: '暂无通知', icon: $r('app.media.icon_bell') })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else {
          List({ scroller: this.scroller }) {
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
                .backgroundColor(AppColors.bg)
                .onClick(() => this.handleNotificationClick(n))
              }
            }, (n: NotificationInfo) => `${n.notificationId}_${n.seen}`)
          }
          .width('100%').layoutWeight(1)
          .divider({ strokeWidth: 0.5, color: AppColors.separator })
          .lanes(new BreakpointType(1, 1, 1).getValue(this.currentBreakpoint), 12)
          .edgeEffect(EdgeEffect.Spring)
          .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          .linearGradientBlur(
            TitleScrollEffect.getBlurRadius(this.materialEnabled, this.titleScrollEffectProgress),
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
        }
      }
      .width('100%').height('100%')

      PanelNavBar({
        title: '通知',
        scrollEffectProgress: this.titleScrollEffectProgress,
        rightIcon: $r('app.media.icon_nav_mark_all_read'),
        rightIconColor: this.hasUnreadNotifications() ? AppColors.primary : AppColors.textTertiary,
        rightIconAccessibilityText: '全部标记为已读',
        onRightClick: (): void => { this.handleMarkAllSeen() }
      })
        .width('100%').position({ x: 0, y: 0 })
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg)
  }
}
