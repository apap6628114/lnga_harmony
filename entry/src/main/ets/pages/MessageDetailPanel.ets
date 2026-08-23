/**
 * 私信详情面板
 *
 * 数据顺序：官方 message/detail 接口返回倒序（新→旧，page=1 为最新一页，
 * nextPage=当前页+1 指向更早消息）。本面板渲染前反转为正序（旧→新），
 * 最新消息在列表底部，打开时定位到底部；向上滚动接近顶部时加载更早消息
 * （prependAll 头部插入并补偿滚动锚点），与帖子列表旧→新的阅读顺序一致。
 */

import { appStore } from '../store/AppStore'
import { getMessageDetail, sendMessage } from '../service/api/MessageApi'
import type { MessageArticle } from '../model/Message'
import { AppColors } from '../common/constants/Constants'
import { formatTime } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { Avatar } from '../common/components/Avatar'
import { MessageArticleDataSource } from '../common/datasource/LazyDataSource'
import { LoadingStateView, ErrorStateView, EmptyStateView } from '../common/components/PageStateView'
import { UIMaterialManager } from '../common/managers/UIMaterialManager'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'
import { KEY_MESSAGE_VERSION } from '../common/constants/AppStorageKeys'
import { bumpAppStorageVersion } from '../common/utils/AppStorageVersion'
import { BBCodeContentView } from '../common/components/BBCodeContentView'
import { getCachedBBNodes } from '../parser/bbcode/BBCodeCache'

@Component
export struct MessageDetailPanel {
  @Prop @Watch('onMidChanged') mid: string = ''
  @State messages: MessageArticle[] = []
  @State title: string = '私信详情'
  @State isLoading: boolean = true
  @State hasError: boolean = false
  @State replyText: string = ''
  @State sending: boolean = false
  /** 更早消息的下一页页码（<=0 表示没有更多）。 */
  @State nextPage: number = 0
  /** 加载更早消息进行中（防重入）。 */
  @State loadingMore: boolean = false
  @StorageProp('navBarHeight') navBarHeight: number = 0
  /** 状态栏高度。 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 列表当前视口高度。 */
  @State listViewportHeight: number = 1

  private scroller: Scroller = new Scroller()
  private messagesDataSource: MessageArticleDataSource = new MessageArticleDataSource()
  /** 加载更早消息前的首条可见列表索引（滚动锚点补偿用）。 */
  private firstVisibleIndex: number = 0
  /** 是否已离开列表顶部区域（初始布局帧不触发加载更早消息，避免破坏底部定位）。 */
  private earlierReady: boolean = false

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
    this.loadMessages()
  }

  /**
   * 关闭详情页时发布私信会话列表版本信号，
   * 驱动通知面板私信 Tab 静默刷新（回复/已读变化后列表及时同步）。
   */
  aboutToDisappear(): void {
    bumpAppStorageVersion(KEY_MESSAGE_VERSION)
  }

  private onMidChanged(): void {
    this.messages = []
    this.messagesDataSource.clear()
    this.hasError = false
    this.nextPage = 0
    this.loadingMore = false
    this.earlierReady = false
    this.titleScrollEffectProgress = 0
    this.loadMessages()
  }

  /**
   * 加载私信详情首页并定位到最新消息。
   *
   * 官方接口按新→旧返回，此处反转为旧→新（最新在底部），
   * 与帖子列表阅读顺序一致；加载完成后滚动到底部展示最新消息。
   */
  private async loadMessages(): Promise<void> {
    if (!this.mid) return
    this.isLoading = true
    this.hasError = false
    try {
      const result = await getMessageDetail(appStore.auth.token, this.mid, '1')
      if (result.ok && result.data) {
        const reversed: MessageArticle[] = this.reverseChronological(result.data.messageEntryList)
        this.messages = reversed
        this.messagesDataSource.replaceAll(reversed)
        this.nextPage = result.data.nextPage
        this.title = result.data.title || '私信详情'
        this.earlierReady = false
        setTimeout(() => {
          this.scroller.scrollEdge(Edge.Bottom)
        }, 300)
      } else {
        this.hasError = true
      }
    } catch (e) {
      this.hasError = true
    }
    this.isLoading = false
  }

  /**
   * 将接口返回的倒序（新→旧）消息列表反转为正序（旧→新）。
   *
   * @param list - 接口返回的消息列表
   * @returns 反转后的列表（新数组，不修改入参）
   */
  private reverseChronological(list: MessageArticle[]): MessageArticle[] {
    const reversed: MessageArticle[] = []
    for (let i = list.length - 1; i >= 0; i--) {
      reversed.push(list[i])
    }
    return reversed
  }

  /**
   * 加载更早一页消息（nextPage 指向更早），头部插入并补偿滚动锚点。
   *
   * 接口每页内部仍为新→旧，需反转后 prependAll，保证列表整体旧→新
   * （头部始终是最早消息）；按 id 去重防游标回退。插入后把视口锚点
   * 下移新增条数，避免内容跳动打断阅读位置。
   */
  private async loadMoreEarlier(): Promise<void> {
    if (this.loadingMore || this.nextPage <= 0) {
      return
    }
    if (!this.mid) {
      return
    }
    this.loadingMore = true
    const anchor: number = this.firstVisibleIndex
    try {
      const result = await getMessageDetail(appStore.auth.token, this.mid, String(this.nextPage))
      if (result.ok && result.data) {
        const knownIds: Set<string> = new Set<string>()
        for (let i: number = 0; i < this.messagesDataSource.totalCount(); i++) {
          knownIds.add(this.messagesDataSource.getData(i).id)
        }
        const pageReversed: MessageArticle[] = this.reverseChronological(result.data.messageEntryList)
        const added: MessageArticle[] = []
        for (let i: number = 0; i < pageReversed.length; i++) {
          const item: MessageArticle = pageReversed[i]
          if (!knownIds.has(item.id)) {
            knownIds.add(item.id)
            added.push(item)
          }
        }
        if (added.length > 0) {
          this.messagesDataSource.prependAll(added)
          const merged: MessageArticle[] = []
          for (let i: number = 0; i < this.messagesDataSource.totalCount(); i++) {
            merged.push(this.messagesDataSource.getData(i))
          }
          this.messages = merged
          setTimeout(() => {
            this.scroller.scrollToIndex(anchor + added.length)
          }, 50)
        }
        this.nextPage = result.data.nextPage
      } else {
        appStore.showToast('加载更早消息失败')
      }
    } catch (e) {
      appStore.showToast('加载更早消息失败')
    }
    this.loadingMore = false
  }

  private async handleReply(): Promise<void> {
    const content = this.replyText.trim()
    if (!content || !this.mid || this.sending) return

    this.sending = true
    try {
      // 官方 message/reply 的 subject 为必填参数：回复时以会话标题兜底
      // （title 为空态时保持空串，由服务端校验结果透出）
      const replySubject: string = this.title !== '私信详情' ? this.title : ''
      const result = await sendMessage(appStore.auth.token, '', this.mid, replySubject, content)
      if (result.ok) {
        this.replyText = ''
        appStore.showToast('回复成功')
        this.loadMessages()
      } else {
        appStore.showToast(result.error || '回复失败')
      }
    } catch (e) {
      appStore.showToast('回复失败')
    }
    this.sending = false
  }

  /** 判断消息是否为当前登录用户所发（官方接口 user.uid=0 为系统消息）。 */
  private isMyMessage(msg: MessageArticle): boolean {
    return msg.uid.length > 0 && msg.uid === appStore.auth.uid
  }

  /** 消息展示发送者名：#SYSTEM# 与空名统一为系统/未知文案。 */
  private actorName(msg: MessageArticle): string {
    const name: string = unescapeHtml(msg.author || msg.from)
    if (name.length === 0) {
      return '未知'
    }
    return name === '#SYSTEM#' ? '系统消息' : name
  }

  build() {
    Stack() {
      Column() {
        if (this.isLoading) {
          Column() {
            LoadingStateView()
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .padding({ top: TitleScrollEffect.getContentStartOffset(this.statusBarHeight) })
        } else if (this.hasError) {
          Column() {
            ErrorStateView({ msg: '加载失败', onRetry: () => this.loadMessages() })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .padding({ top: TitleScrollEffect.getContentStartOffset(this.statusBarHeight) })
        } else if (this.messages.length === 0) {
          Column() {
            EmptyStateView({ msg: '暂无消息', icon: $r('app.media.icon_chat_bubble') })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .padding({ top: TitleScrollEffect.getContentStartOffset(this.statusBarHeight) })
        } else {
          List({ scroller: this.scroller }) {
            LazyForEach(this.messagesDataSource, (msg: MessageArticle) => {
              ListItem() {
                if (this.isMyMessage(msg)) {
                  // 自己的消息：名字与时间居右，内容 BBCode 渲染（块级结构无法右对齐，统一左对齐）
                  Row() {
                    Column() {
                      Row() {
                        Text('我')
                          .fontSize(14).fontColor(AppColors.primary).fontWeight(FontWeight.Medium)
                        Text(formatTime(Number(msg.time))).fontSize(12).fontColor(AppColors.textTertiary)
                          .margin({ left: 8 })
                      }.width('100%').justifyContent(FlexAlign.End)
                      if (msg.formated_html_data) {
                        RichText(msg.formated_html_data).width('100%').margin({ top: 4 })
                      } else {
                        BBCodeContentView({
                          nodes: getCachedBBNodes(msg.content)
                        }).width('100%').margin({ top: 4 })
                      }
                    }
                    .layoutWeight(1).margin({ right: 10 }).alignItems(HorizontalAlign.Start)
                    Avatar({ name: '我', avatarSize: 36 })
                  }
                  .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 })
                  .alignItems(VerticalAlign.Top)
                } else {
                  // 对方/系统消息：头像居左，名字与内容居左
                  Row() {
                    Avatar({ name: this.actorName(msg), avatarSize: 36 })
                    Column() {
                      Row() {
                        Text(this.actorName(msg))
                          .fontSize(14).fontColor(AppColors.primary).fontWeight(FontWeight.Medium)
                        if (Number(msg.mute_time) > 0) {
                          Text('禁言中')
                            .fontSize(10).fontColor(AppColors.white)
                            .backgroundColor(AppColors.destructive).borderRadius(4)
                            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                            .margin({ left: 4 })
                        }
                        Text(formatTime(Number(msg.time))).fontSize(12).fontColor(AppColors.textTertiary)
                          .margin({ left: 8 })
                      }
                      if (msg.formated_html_data) {
                        RichText(msg.formated_html_data).width('100%').margin({ top: 4 })
                      } else {
                        BBCodeContentView({
                          nodes: getCachedBBNodes(msg.content)
                        }).width('100%').margin({ top: 4 })
                      }
                    }
                    .layoutWeight(1).margin({ left: 10 }).alignItems(HorizontalAlign.Start)
                  }
                  .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 })
                  .alignItems(VerticalAlign.Top)
                }
              }
            }, (msg: MessageArticle) => msg.id)
          }
          .width('100%').layoutWeight(1)
          .divider({ strokeWidth: 0.5, color: AppColors.separator })
          .edgeEffect(EdgeEffect.Spring)
          .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          .linearGradientBlur(
            TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),
            {
              fractionStops: TitleScrollEffect.getBlurStops(this.listViewportHeight, this.statusBarHeight),
              direction: GradientDirection.Bottom
            }
          )
          .onAreaChange((oldValue: Area, newValue: Area): void => {
            if (typeof newValue.height === 'number' && newValue.height !== this.listViewportHeight) {
              this.listViewportHeight = newValue.height
            }
          })
          .onDidScroll((): void => {
            this.syncTitleScrollEffect()
          })
          .onAppear((): void => {
            this.syncTitleScrollEffect()
          })
          .onScrollIndex((start: number, _end: number): void => {
            // 记录锚点；仅当列表曾处于非顶部区域（初始定位完成或用户滚动过）
            // 才在接近顶部（前 2 项内）预加载更早消息，避免首帧误触发
            this.firstVisibleIndex = start
            if (start > 1) {
              this.earlierReady = true
            }
            if (this.earlierReady && start <= 1) {
              this.loadMoreEarlier()
            }
          })
        }

        if (!this.isLoading && !this.hasError) {
          Row() {
            TextInput({ text: this.replyText, placeholder: '写回复...' })
              .layoutWeight(1).fontSize(15).borderRadius(12)
              .fontColor(UIMaterialManager.inputForeground)
              .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
              .caretColor(UIMaterialManager.inputForeground)
              .backgroundColor(Color.Transparent)
              .height(40).padding({ left: 12, right: 12 })
              .systemMaterial(UIMaterialManager.inputMaterial)
              .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
              .onChange((value: string) => { this.replyText = value })
              .onSubmit(() => this.handleReply())
            Button('发送')
              .fontSize(14).fontColor(AppColors.white)
              .backgroundColor(AppColors.primary)
              .borderRadius(12).height(40).padding({ left: 16, right: 16 }).margin({ left: 8 })
              .enabled(!this.sending && this.replyText.trim().length > 0)
              .onClick(() => this.handleReply())
          }
          .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 + this.navBarHeight })
          .backgroundColor(Color.Transparent)
          .border({ width: { top: 0.5 }, color: AppColors.separator })
          .alignItems(VerticalAlign.Center)
          .systemMaterial(UIMaterialManager.barMaterial)
        }
      }
      .width('100%').height('100%').backgroundColor(AppColors.bg)

      PanelNavBar({
        title: this.title !== '私信详情' ? this.title : '私信',
        scrollEffectProgress: this.titleScrollEffectProgress
      })
        .width('100%').position({ x: 0, y: 0 })
    }
    .width('100%').height('100%')
  }
}
