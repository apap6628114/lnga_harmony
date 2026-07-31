/**
 * 私信列表面板
 */

import { appStore } from '../store/AppStore'
import { routerStore, Screen } from '../store/RouterStore'
import { getMessageList, sendMessage } from '../service/api/MessageApi'
import type { MessageListResult, MessageSendResult } from '../model/MessageResult'
import type { MessageThreadInfo } from '../model/Message'
import { AppColors, BreakpointType } from '../common/constants/Constants'
import { formatTime } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { Avatar } from '../common/components/Avatar'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { MessageThreadDataSource } from '../common/datasource/LazyDataSource'
import { LoadingStateView, ErrorStateView, EmptyStateView } from '../common/components/PageStateView'
import { PageScope } from '../common/concurrency/PageScope'

@Component
export struct MessageListPanel {
  @Prop composeToInit: string = ''
  @State threads: MessageThreadInfo[] = []
  @State isLoading: boolean = true
  @State hasError: boolean = false
  @State showCompose: boolean = false
  @State composeTo: string = ''
  @State composeSubject: string = ''
  @State composeContent: string = ''
  @State sending: boolean = false
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @StorageProp('navBarHeight') navBarHeight: number = 0
  private threadsDataSource: MessageThreadDataSource = new MessageThreadDataSource()
  /** 页面出现会话作用域，驱动异步回调的存活与代际校验。 */
  private scope: PageScope = new PageScope()

  aboutToAppear(): void {
    const currentGeneration: number = this.scope.begin()
    if (this.composeToInit.length > 0) {
      this.composeTo = this.composeToInit
      this.showCompose = true
    }
    this.loadMessages(currentGeneration)
  }

  /** 结束当前页面出现周期，使未完成的异步回调失效。 */
  aboutToDisappear(): void {
    this.scope.end()
  }

  /**
   * 在消息列表成功显示后刷新通知，但不改变具体通知的本地已读状态。
   *
   * @param appearanceGeneration - 消息列表成功时的页面出现周期版本号
   */
  private async refreshNotificationState(appearanceGeneration: number): Promise<void> {
    if (!this.scope.isActive(appearanceGeneration)) {
      return
    }
    await appStore.refreshNotifications(true)
  }

  /**
   * 加载私信列表，并仅在当前页面出现会话内更新界面和通知状态。
   *
   * @param appearanceGeneration - 请求发起时的页面出现会话代际
   */
  private async loadMessages(appearanceGeneration: number): Promise<void> {
    this.isLoading = true
    this.hasError = false
    try {
      const result: MessageListResult = await getMessageList(appStore.auth.token, '1')
      if (!this.scope.isActive(appearanceGeneration)) {
        return
      }
      if (result.ok && result.data) {
        this.threads = result.data.messageEntryList
        this.threadsDataSource.replaceAll(this.threads)
        this.isLoading = false
        await this.refreshNotificationState(appearanceGeneration)
        return
      } else {
        this.hasError = true
      }
    } catch (e) {
      if (this.scope.isActive(appearanceGeneration)) {
        this.hasError = true
      }
    }
    if (this.scope.isActive(appearanceGeneration)) {
      this.isLoading = false
    }
  }

  private async handleSend(): Promise<void> {
    const to = this.composeTo.trim()
    const subject = this.composeSubject.trim()
    const content = this.composeContent.trim()
    if (!to || !subject || !content) return

    this.sending = true
    try {
      const result: MessageSendResult = await sendMessage(appStore.auth.token, to, '', subject, content)
      if (result.ok) {
        appStore.showToast('发送成功')
        this.showCompose = false
        this.composeTo = ''
        this.composeSubject = ''
        this.composeContent = ''
        this.loadMessages(this.scope.begin())
      } else {
        appStore.showToast(result.error || '发送失败')
      }
    } catch (e) {
      appStore.showToast('发送失败')
    }
    this.sending = false
  }

  build() {
    Stack() {
      Column() {
        if (this.isLoading) {
          Row().width('100%').height(44 + this.statusBarHeight)
          Column() {
            LoadingStateView()
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else if (this.hasError) {
          Row().width('100%').height(44 + this.statusBarHeight)
          Column() {
            ErrorStateView({ msg: '加载失败', onRetry: () => this.loadMessages(this.scope.begin()) })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else if (this.threads.length === 0) {
          Row().width('100%').height(44 + this.statusBarHeight)
          Column() {
            EmptyStateView({ msg: '暂无私信', icon: $r('app.media.icon_mail') })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else {
          List() {
            ListItem() {
              Row().width('100%').height(44 + this.statusBarHeight)
            }
            LazyForEach(this.threadsDataSource, (thread: MessageThreadInfo) => {
              ListItem() {
                Row() {
                  Avatar({ name: thread.last_from_username || thread.from_username, avatarSize: 44 })
                  Column() {
                    Text(unescapeHtml(thread.subject)).fontSize(15).fontWeight(FontWeight.Medium)
                      .fontColor(AppColors.textPrimary).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`${unescapeHtml(thread.last_from_username || thread.from_username)} · ${thread.posts}条消息 · ${formatTime(Number(thread.lasttime))}`)
                      .fontSize(13).fontColor(AppColors.textTertiary).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 2 })
                  }.layoutWeight(1).margin({ left: 12 }).alignItems(HorizontalAlign.Start)
                  Text('›').fontSize(18).fontColor(AppColors.textTertiary)
                }
                .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 }).alignItems(VerticalAlign.Center)
                .onClick(() => {
                  routerStore.navigateActivity(Screen.messageDetail(String(thread.mid)))
                })
              }
            }, (thread: MessageThreadInfo) => String(thread.mid))
          }
          .width('100%').layoutWeight(1)
          .divider({ strokeWidth: 0.5, color: AppColors.separator })
          .lanes(new BreakpointType(1, 2, 2).getValue(this.currentBreakpoint), 12)
        }
      }
      .width('100%').height('100%')

      PanelNavBar({ title: '私信', rightIcon: $r('app.media.icon_compose'), onRightClick: (): void => { this.showCompose = true } })
        .width('100%').position({ x: 0, y: 0 })

      if (this.showCompose) {
        Column() {
        }
        .width('100%').height('100%')
        .position({ x: 0, y: 0 })
        .backgroundColor(AppColors.overlay)
        .onClick(() => { this.showCompose = false })

        Column() {
          Divider().width(36).height(4).borderRadius(2).color(AppColors.sheetIndicator).margin({ top: 8, bottom: 12 })
          Row() {
            Text('写私信').fontSize(17).fontWeight(FontWeight.Bold).layoutWeight(1)
            Text('✕').fontSize(20).fontColor(AppColors.textTertiary)
              .onClick(() => { this.showCompose = false })
          }.width('100%').padding({ left: 16, right: 16 })

          TextInput({ text: this.composeTo, placeholder: '收件人（用户名）' })
            .width('92%').height(44).fontSize(15).borderRadius(12)
            .backgroundColor(AppColors.bgSecondary).margin({ top: 12 })
            .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
            .onChange((value: string) => { this.composeTo = value })

          TextInput({ text: this.composeSubject, placeholder: '主题' })
            .width('92%').height(44).fontSize(15).borderRadius(12)
            .backgroundColor(AppColors.bgSecondary).margin({ top: 8 })
            .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
            .onChange((value: string) => { this.composeSubject = value })

          TextArea({ text: this.composeContent, placeholder: '内容' })
            .width('92%').height(100).fontSize(15).borderRadius(12)
            .backgroundColor(AppColors.bgSecondary).margin({ top: 8 })
            .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
            .onChange((value: string) => { this.composeContent = value })

          Button(this.sending ? '发送中...' : '发送')
            .width('92%').height(44).fontSize(16).fontColor(AppColors.white)
            .backgroundColor(AppColors.primary).borderRadius(12).margin({ top: 12, bottom: 20 })
            .enabled(!this.sending && this.composeTo.trim().length > 0 &&
              this.composeSubject.trim().length > 0 && this.composeContent.trim().length > 0)
            .onClick(() => this.handleSend())
        }
        .width('100%').backgroundColor(AppColors.bg)
        .borderRadius({ topLeft: 14, topRight: 14 }).alignItems(HorizontalAlign.Center)
        .padding({ bottom: this.navBarHeight })
        .position({ x: 0, y: '40%' })
      }
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg)
  }
}
