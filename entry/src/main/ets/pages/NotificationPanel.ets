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
import { formatTime, escHtml } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { BreakpointType } from '../common/constants/Constants'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { Avatar } from '../common/components/Avatar'
import { NotificationDataSource } from '../common/datasource/LazyDataSource'
import { LoadingStateView, ErrorStateView, EmptyStateView } from '../common/components/PageStateView'

interface FilterMode {
  key: number
  label: string
}

const FILTER_MODES: FilterMode[] = [
  { key: 0, label: '全部' },
  { key: 1, label: '回复' },
  { key: 2, label: '@我' },
  { key: 3, label: '私信' }
]
const FILTER_TYPES: number[][] = [[], [1, 2, 17], [7, 8], [10, 11]]

@Component
export struct NotificationPanel {
  @State notifications: NotificationInfo[] = []
  @State isLoading: boolean = true
  @State hasError: boolean = false
  @State errorMsg: string = ''
  @State activeFilter: number = 0
  @State clearing: boolean = false
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 通知 Store 的页面刷新信号。 */
  @StorageProp('notificationVersion') @Watch('onNotificationVersionChange') notificationVersion: number = 0
  private notificationsDataSource: NotificationDataSource = new NotificationDataSource()
  private scroller: Scroller = new Scroller()
  /** 当前页面出现周期版本号。 */
  private appearanceGeneration: number = 0

  aboutToAppear(): void {
    this.appearanceGeneration++
    const currentGeneration: number = this.appearanceGeneration
    this.syncFromStore()
    this.loadNotifications(currentGeneration)
  }

  /** 结束当前页面出现周期，使未完成的异步回调失效。 */
  aboutToDisappear(): void {
    this.appearanceGeneration++
  }

  /** 通知 Store 发布新版本时同步页面快照。 */
  private onNotificationVersionChange(): void {
    this.syncFromStore()
  }

  /** 从通知 Store 同步列表快照和懒加载数据源。 */
  private syncFromStore(): void {
    this.notifications = appStore.getCachedNotifications() as NotificationInfo[]
    this.updateFilteredDataSource()
  }

  /**
   * 刷新通知并仅在当前页面出现周期内更新页面快照。
   *
   * @param appearanceGeneration - 请求发起时的页面出现周期版本号
   */
  private async loadNotifications(appearanceGeneration: number = this.appearanceGeneration): Promise<void> {
    this.isLoading = this.notifications.length === 0
    this.hasError = false
    const success: boolean = await appStore.refreshNotifications(true)
    if (appearanceGeneration !== this.appearanceGeneration) {
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

  private getFilteredNotifications(): NotificationInfo[] {
    const list = this.notifications
    if (!list) return []
    const types = FILTER_TYPES[this.activeFilter]
    if (types.length === 0) return list
    return list.filter((n: NotificationInfo) => types.includes(n.type))
  }

  private getEmptyText(): string {
    const texts: string[] = ['暂无通知', '暂无回复通知', '暂无@消息', '暂无私信通知']
    return texts[this.activeFilter] || '暂无通知'
  }

  private updateFilteredDataSource(): void {
    this.notificationsDataSource.replaceAll(this.getFilteredNotifications())
  }

  private async handleClearAll(): Promise<void> {
    if (this.clearing) return
    this.clearing = true
    const success: boolean = await appStore.clearAllNotifications()
    if (success) {
      this.syncFromStore()
    } else {
      appStore.showToast('清除失败')
    }
    this.clearing = false
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
        Row().width('100%').height(44 + this.statusBarHeight)
        Row() {
          ForEach(FILTER_MODES, (mode: FilterMode) => {
            Text(mode.label)
              .fontSize(13)
              .fontColor(this.activeFilter === mode.key ? AppColors.textPrimary : AppColors.textTertiary)
              .fontWeight(this.activeFilter === mode.key ? FontWeight.Bold : FontWeight.Normal)
              .backgroundColor(this.activeFilter === mode.key ? AppColors.bg : Color.Transparent)
              .borderRadius(7)
              .padding({ left: 12, right: 12, top: 5, bottom: 5 })
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                if (this.activeFilter !== mode.key) {
                  this.activeFilter = mode.key
                  this.updateFilteredDataSource()
                }
              })
          })
        }
        .width('92%')
        .margin({ top: 8, bottom: 4 })
        .padding(3)
        .backgroundColor(AppColors.bgSecondary)
        .borderRadius(10)

        if (this.isLoading) {
          Column() {
            LoadingStateView()
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else if (this.hasError) {
          Column() {
            ErrorStateView({ msg: this.errorMsg, onRetry: () => this.loadNotifications() })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else if (this.getFilteredNotifications().length === 0) {
          Column() {
            EmptyStateView({ msg: this.getEmptyText(), icon: $r('app.media.icon_bell') })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else {
          List({ scroller: this.scroller }) {
            LazyForEach(this.notificationsDataSource, (n: NotificationInfo) => {
              ListItem() {
                Row() {
                  Circle()
                    .width(8)
                    .height(8)
                    .fill(AppColors.primary)
                    .opacity(n.seen ? 0 : 1)
                    .margin({ right: 8 })
                  if (n.type === 17) {
                    Image(getNotiIcon(n.type)).width(20).height(20).fillColor(AppColors.primary)
                      .margin({ right: 10 })
                  } else if (n.userName.length > 0) {
                    Avatar({ name: n.userName, uid: n.userId, avatarSize: 40 })
                      .margin({ right: 10 })
                  } else {
                    Image(getNotiIcon(n.type)).width(20).height(20).fillColor(AppColors.textSecondary)
                      .margin({ right: 8 })
                  }
                  Column() {
                    Row() {
                      Row() {
                        if (n.userName.length > 0) {
                          Text(unescapeHtml(n.userName)).fontSize(15).fontColor(AppColors.primary)
                            .fontWeight(n.seen ? FontWeight.Normal : FontWeight.Bold)
                          if (appStore.settingsStore.getNote(n.userId).length > 0) {
                            Text('(' + appStore.settingsStore.getNote(n.userId) + ')')
                              .fontSize(11).fontColor(AppColors.warning).margin({ left: 3 })
                          }
                          Text('').margin({ right: 4 })
                        }
                        Text(escHtml(NOTI_TYPE_MAP[n.type] ? NOTI_TYPE_MAP[n.type].label : '通知'))
                          .fontSize(15).fontColor(AppColors.textSecondary)
                          .fontWeight(n.seen ? FontWeight.Normal : FontWeight.Bold)
                      }.layoutWeight(1)
                      if (!n.seen) {
                        Text('未读')
                          .fontSize(10)
                          .fontColor(AppColors.primary)
                          .backgroundColor(AppColors.primaryLight)
                          .borderRadius(6)
                          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                          .margin({ left: 6, right: 8 })
                      }
                      Text(formatTime(Number(n.timeStamp))).fontSize(12).fontColor(AppColors.textTertiary)
                        .fontWeight(n.seen ? FontWeight.Normal : FontWeight.Bold)
                    }.width('100%').alignItems(VerticalAlign.Center)
                    if (n.title.length > 0) {
                      Text(unescapeHtml(n.title)).fontSize(14).fontColor(AppColors.textPrimary)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 4 })
                        .width('100%')
                        .fontWeight(n.seen ? FontWeight.Normal : FontWeight.Bold)
                    }
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .alignItems(VerticalAlign.Center)
                .backgroundColor(n.seen ? AppColors.bg : AppColors.primaryLight)
                .onClick(() => this.handleNotificationClick(n))
              }
            }, (n: NotificationInfo) => n.notificationId)
          }
          .width('100%').layoutWeight(1)
          .divider({ strokeWidth: 0.5, color: AppColors.separator })
          .lanes(new BreakpointType(1, 1, 1).getValue(this.currentBreakpoint), 12)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%').height('100%')

      PanelNavBar({ title: '通知', rightLabel: '清空', rightLabelColor: this.clearing ? AppColors.textTertiary : AppColors.primary, onRightClick: (): void => { this.handleClearAll() } })
        .width('100%').position({ x: 0, y: 0 })
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg)
  }
}
