/**
 * 搜索面板
 */

import { appStore } from '../store/AppStore'
import { routerStore, Screen, ThreadSource } from '../store/RouterStore'
import { floatingLayerStore, FloatingPage } from '../store/FloatingLayerStore'
import { display } from '@kit.ArkUI'
import { getTopicList, createTopicListParams, searchForum } from '../service/api/ForumApi'
import { searchUser } from '../service/api/UserApi'
import type { TopicListParams } from '../service/api/ForumApi'
import type { TopicListResult, SearchForumResult, SearchUserResult } from '../model/NgaApiResults'
import type { ForumSearchItem } from '../model/Forum'
import type { SearchUserItem } from '../model/User'
import { AppColors, FONT_COLORS, TITLE_BLUR_FADE_DISTANCE } from '../common/constants/Constants'
import { NGA_IMG4_BASE } from '../common/constants/NgaDomains'
import { formatTime } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { ThreadDataSource } from '../common/datasource/LazyDataSource'
import { AnonymousName } from '../common/components/AnonymousName'
import { BoardIcon } from '../common/components/BoardIcon'
import { Avatar } from '../common/components/Avatar'
import { PageScope } from '../common/concurrency/PageScope'
import { LoadingStateView, ErrorStateView, EmptyStateView } from '../common/components/PageStateView'
import { SegmentButton, SegmentButtonOptions, SegmentButtonItemTuple } from '@kit.ArkUI'
import {
  ReadingFontRole,
  ReadingLineHeightRole,
  ReadingTypography
} from '../common/typography/ReadingTypography'
import { UIMaterialManager } from '../common/managers/UIMaterialManager'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'

@Component
export struct SearchPanel {
  /** 限定搜索的版块 fid；0 表示全局搜索。切回全局时（变为 0）若已有提交词则自动重搜。 */
  @Prop @Watch('onBoardScopeChange') boardFid: number = 0
  /** 限定搜索的专题版块 stid；为空时按 fid 搜索。 */
  @Prop boardStid: string = ''
  /** 限定搜索的版块名（UI 提示用）。 */
  @Prop boardName: string = ''
  /** 从版块内搜索一键切回全局搜索。 */
  onExitBoardScope?: () => void

  @State keyword: string = ''
  @State submitted: string = ''
  @State currentTab: number = 0
  /** 分类分段按钮选中项（SegmentButton 双向绑定，与 currentTab 同步）。 */
  @State tabSelected: number[] = [0]
  /** 分类分段按钮选项（胶囊单选，配色与帖子列表排序条一致）。 */
  @State tabOptions: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [
      { text: '主题' },
      { text: '板块' },
      { text: '用户' },
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
  @State isLoading: boolean = false
  @State threads: object[] = []
  @State forums: object[] = []
  @State users: object[] = []
  @State currentPage: number = 1
  @State totalPages: number = 0
  @State isLoadingMore: boolean = false
  /** 最近一次搜索是否失败（区别于"无结果"，用于失败空态与保留旧结果）。 */
  @State searchFailed: boolean = false
  /** 失败空态的文案（区分服务端业务错误与网络错误）。 */
  @State errorText: string = '搜索失败，请检查网络后重试'
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @StorageProp('topicFontSize') topicFontSize: number = 15
  /** 黑名单变更版本号。 */
  @StorageProp('blacklistVersion') blacklistVersion: number = 0

  private scroller: Scroller = new Scroller()
  private forumsDataSource: ThreadDataSource = new ThreadDataSource()
  private threadsDataSource: ThreadDataSource = new ThreadDataSource()
  private usersDataSource: ThreadDataSource = new ThreadDataSource()
  /** 页面出现会话作用域，驱动异步回调的存活与代际校验。 */
  private scope: PageScope = new PageScope()
  /** 输入即搜索的防抖定时器 ID（-1 表示无挂起定时器）。 */
  private debounceTimer: number = -1
  /** 顶部固定区（搜索框+分段+提示条）实测高度：onAreaChange 驱动，列表按此避让。 */
  @State fixedHeaderHeight: number = 0
  /** 搜索区渐变模糊与偏色的滚动联动进度（对齐帖子列表标题区）。 */
  @State titleScrollEffectProgress: number = 0
  /** 列表当前视口高度。 */
  @State listViewportHeight: number = 1

  aboutToAppear(): void {
    this.scope.begin()
  }

  /** 结束页面出现会话，使未完成的异步回调失效；并清理挂起的防抖定时器。 */
  aboutToDisappear(): void {
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer)
      this.debounceTimer = -1
    }
    this.scope.end()
  }

  /**
   * 输入即搜索：停止输入 300ms 后自动提交。
   *
   * 防抖期间用户按回车（handleSubmit）或清空输入（✕）会先取消挂起定时器；
   * 自动提交仅在新关键词与已提交关键词不同时触发，避免重复请求。
   */
  private scheduleAutoSubmit(): void {
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer)
    }
    this.debounceTimer = setTimeout((): void => {
      this.debounceTimer = -1
      const kw = this.keyword.trim()
      if (kw.length === 0 || kw === this.submitted) {
        return
      }
      this.handleSubmit()
    }, 300)
  }

  /**
   * 按列表绝对滚动偏移同步搜索区模糊/偏色效果（对齐帖子列表标题区）。
   *
   * Scroller 未绑定到任何列表（如切换 tab 的间隙）时 currentOffset 为
   * undefined，此时直接返回，等待 onAppear 重新同步。
   */
  private syncTitleScrollEffect(): void {
    const offset = this.scroller.currentOffset()
    if (!offset) {
      return
    }
    const progress: number = TitleScrollEffect.getProgress(
      offset.yOffset,
      this.statusBarHeight,
      this.fixedHeaderHeight
    )
    if (TitleScrollEffect.shouldUpdateProgress(this.titleScrollEffectProgress, progress)) {
      this.titleScrollEffectProgress = progress
    }
  }

  private getSubjectFontColor(titleFont: string): ResourceColor {
    const num = Number(titleFont) || 0
    const color = num & 0x1f
    if (FONT_COLORS[color]) return FONT_COLORS[color]
    return AppColors.textPrimary
  }

  private isSubjectBold(titleFont: string): boolean {
    return (Number(titleFont) & 32) !== 0
  }

  private isSubjectItalic(titleFont: string): boolean {
    return (Number(titleFont) & 64) !== 0
  }

  private getTypeTags(type: number): string {
    if (type & 1024) return '[锁定]'
    return ''
  }

  /**
   * 判断搜索结果中的主题作者是否已被屏蔽。
   *
   * @param thread - 主题列表项
   * @returns 作者是否在实时黑名单中
   */
  private isAuthorBlacklisted(thread: Record<string, Object>): boolean {
    return this.blacklistVersion >= 0 &&
      appStore.settingsStore.isBlacklisted(String(thread['authorId'] ?? ''))
  }

  /**
   * 判断搜索结果摘要对应的回复作者是否已被屏蔽。
   *
   * @param thread - 主题列表项
   * @returns 摘要作者是否在实时黑名单中
   */
  private isPreviewAuthorBlacklisted(thread: Record<string, Object>): boolean {
    const authorId: string = String(thread['previewAuthorId'] ?? '')
    return this.blacklistVersion >= 0 &&
      authorId.length > 0 &&
      appStore.settingsStore.isBlacklisted(authorId)
  }

  private handleSubmit(): void {
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer)
      this.debounceTimer = -1
    }
    const kw = this.keyword.trim()
    if (!kw) return
    this.submitted = kw
    this.threads = []
    this.forums = []
    this.users = []
    this.threadsDataSource.clear()
    this.forumsDataSource.clear()
    this.usersDataSource.clear()
    this.currentPage = 1
    this.totalPages = 0
    this.searchFailed = false
    this.titleScrollEffectProgress = 0
    this.doSearch(1)
  }

  private async doSearch(page: number): Promise<void> {
    // 每次搜索开启新会话，旧搜索的过期回调将被丢弃
    const gen: number = this.scope.begin()
    if (page === 1) { this.isLoading = true } else { this.isLoadingMore = true }
    try {
      if (this.currentTab === 1) {
        const result: SearchForumResult = await searchForum(appStore.auth.token, this.submitted)
        if (!this.scope.isActive(gen)) {
          return
        }
        if (result.ok) {
          this.forums = result.data as object[]
          this.forumsDataSource.replaceAll(this.forums)
        } else {
          this.searchFailed = true
          this.errorText = result.error.length > 0 ? result.error : '搜索失败，请重试'
          appStore.showToast(this.errorText)
        }
      } else if (this.currentTab === 2) {
        const result: SearchUserResult = await searchUser(appStore.auth.token, this.submitted)
        if (!this.scope.isActive(gen)) {
          return
        }
        if (result.ok) {
          this.users = result.data as object[]
          this.usersDataSource.replaceAll(this.users)
        } else {
          this.searchFailed = true
          this.errorText = result.error.length > 0 ? result.error : '搜索失败，请重试'
          appStore.showToast(this.errorText)
        }
      } else {
        const params: TopicListParams = createTopicListParams()
        params.page = String(page)
        params.key = this.submitted
        // 对齐 MNGA TopicSearchRequest：主题搜索为"标题+正文"一体（thread.php content=1）
        params.content = '1'
        // 注：MNGA search_topic 恒传 recommend（默认 false→"0"）；服务端缺省与
        // recommend=0 等价，且官方 thread.php 通道的 recommend 非空分支仅发
        // recommend（实测 order_by/user 不影响结果，见 AppTopicListQuery），
        // 搜索场景故不传，行为等价。
        // 版块内搜索：限定当前版块（对齐 MNGA TopicSearchRequest.id）；
        // fid 可为负数（NGA 专题版块标识），仅 0 表示全局
        if (this.boardFid !== 0) params.fid = String(this.boardFid)
        if (this.boardStid.length > 0) params.stid = this.boardStid
        const result: TopicListResult = await getTopicList(appStore.auth.token, params, appStore.settingsStore.getBlacklistIds(), appStore.settingsStore.getEnabledKeywords())
        if (!this.scope.isActive(gen)) {
          return
        }
        if (result.ok && result.data) {
          const newItems: object[] = result.data.threadPageList
          if (page === 1) {
            this.threads = newItems
            this.threadsDataSource.replaceAll(newItems)
          } else if (newItems.length === 0) {
            // 空页终止兜底：服务端无更多数据时封顶，避免依赖 totalPages 缺失导致死循环
            this.currentPage = page
            this.totalPages = page
          } else {
            // 追加而非全量重建，避免每翻一页 O(n) 拷贝
            for (let i = 0; i < newItems.length; i++) { this.threads.push(newItems[i]) }
            this.threadsDataSource.appendAll(newItems)
            this.currentPage = page
          }
          if (newItems.length > 0 || page === 1) {
            this.totalPages = result.data.pagination.totalPages
          }
          this.searchFailed = false
        } else {
          this.searchFailed = true
          this.errorText = result.error.length > 0 ? result.error : '搜索失败，请重试'
          appStore.showToast(this.errorText)
        }
      }
    } catch (e) {
      // 失败可见：Toast 提示，且保留旧结果不清空。
      // 代际校验：旧会话（切 tab/连续提交后）的迟到失败不得污染新会话状态
      if (!this.scope.isActive(gen)) {
        return
      }
      this.searchFailed = true
      this.errorText = '搜索失败，请检查网络后重试'
      appStore.showToast(this.errorText)
    }
    if (!this.scope.isActive(gen)) {
      return
    }
    this.isLoading = false
    this.isLoadingMore = false
  }

  private handleTabChange(index: number): void {
    if (this.currentTab === index) return
    this.currentTab = index
    this.tabSelected = [index]
    this.threads = []
    this.forums = []
    this.users = []
    this.threadsDataSource.clear()
    this.forumsDataSource.clear()
    this.usersDataSource.clear()
    this.currentPage = 1
    this.totalPages = 0
    this.searchFailed = false
    this.titleScrollEffectProgress = 0
    if (this.submitted) { this.doSearch(1) }
  }

  /**
   * 搜索范围变化（切回全局）时，若输入区已有提交关键词，
   * 立即以全局范围重新发起搜索，避免显示与范围不一致的旧结果。
   */
  private onBoardScopeChange(): void {
    if (this.boardFid === 0 && this.submitted.length > 0) {
      this.threads = []
      this.forums = []
      this.users = []
      this.threadsDataSource.clear()
      this.forumsDataSource.clear()
      this.usersDataSource.clear()
      this.currentPage = 1
      this.totalPages = 0
      this.searchFailed = false
      this.titleScrollEffectProgress = 0
      this.doSearch(1)
    }
  }

  /**
   * 弹出用户资料小卡片（与帖子列表/黑名单一致的用户资料浮层）。
   *
   * @param uid - 目标用户 ID
   * @param windowX - 触发点窗口 X 坐标
   * @param windowY - 触发点窗口 Y 坐标
   */
  private showProfileCard(uid: string, windowX: number, windowY: number): void {
    const cardW: number = 280
    const cardH: number = 400
    const pad: number = 8
    let posX: number = windowX
    let posY: number = windowY
    try {
      const context = this.getUIContext()
      const displayInfo = display.getDefaultDisplaySync()
      const screenW = context.px2vp(displayInfo.width)
      const screenH = context.px2vp(displayInfo.height)
      posX = Math.max(pad, Math.min(windowX - cardW / 2, screenW - cardW - pad))
      posY = Math.max(pad, Math.min(windowY + pad, screenH - cardH - pad))
    } catch (e) {
      posX = windowX - cardW / 2
      posY = windowY + pad
    }
    floatingLayerStore.profileCardUid = uid
    floatingLayerStore.profileCardX = posX
    floatingLayerStore.profileCardY = posY
    floatingLayerStore.push(FloatingPage.PROFILE_CARD)
  }

  build() {
    Stack() {
      Column() {
        if (this.submitted.length === 0) {
          Column() {
            EmptyStateView({ msg: '搜索主题、板块或用户', icon: $r('app.media.icon_search') })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .padding({ top: this.fixedHeaderHeight })
      } else if (this.isLoading) {
        Column() {
          LoadingStateView({ tip: '搜索中...' })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        .padding({ top: this.fixedHeaderHeight })
      } else if (this.searchFailed) {
        Column() {
          ErrorStateView({
            msg: this.errorText,
            onRetry: (): void => { this.doSearch(1) }
          })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        .padding({ top: this.fixedHeaderHeight })
      } else if (this.currentTab === 1) {
        if (this.forums.length === 0) {
          Column() {
            EmptyStateView({ msg: '未找到相关板块', icon: $r('app.media.icon_globe') })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .padding({ top: this.fixedHeaderHeight })
        } else {
          List({ scroller: this.scroller }) {
            LazyForEach(this.forumsDataSource, (forum: object) => {
              ListItem() {
                Row() {
                  Stack() {
                    BoardIcon({ url: `${NGA_IMG4_BASE}/ngabbs/nga_classic/f/app/${(forum as ForumSearchItem).fid}.png`, iconSize: 40, iconRadius: 10 })
                  }
                  .width(40).height(40).borderRadius(10).backgroundColor(AppColors.bgSecondary).margin({ right: 12 })
                  Column() {
                    Text(unescapeHtml((forum as ForumSearchItem).name)).fontSize(15).fontColor(AppColors.textPrimary)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    if ((forum as ForumSearchItem).info.length > 0) {
                      Text(unescapeHtml((forum as ForumSearchItem).info)).fontSize(12).fontColor(AppColors.textTertiary)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 2 })
                    }
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 }).alignItems(VerticalAlign.Center)
                .onClick(() => {
                  const fid = Number((forum as ForumSearchItem).fid)
                  const name = (forum as ForumSearchItem).name
                  routerStore.navigateForum(fid, name)
                })
              }
            }, (forum: object) => (forum as ForumSearchItem).fid)
          }.width('100%').layoutWeight(1).divider({ strokeWidth: 0.5, color: AppColors.separator })
          .contentStartOffset(this.fixedHeaderHeight)
          .linearGradientBlur(
            TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),
            {
              fractionStops: TitleScrollEffect.getBlurStops(
                this.listViewportHeight, this.statusBarHeight, this.fixedHeaderHeight),
              direction: GradientDirection.Bottom
            }
          )
          .edgeEffect(EdgeEffect.Spring)
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
      } else if (this.currentTab === 2) {
        if (this.users.length === 0) {
          Column() {
            EmptyStateView({ msg: '未找到相关用户，可尝试输入用户名或 UID', icon: $r('app.media.icon_person') })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .padding({ top: this.fixedHeaderHeight })
        } else {
          List({ scroller: this.scroller }) {
            LazyForEach(this.usersDataSource, (user: object) => {
              ListItem() {
                Row() {
                  Avatar({
                    avatar: (user as SearchUserItem).avatarUrl,
                    uid: (user as SearchUserItem).uid,
                    name: (user as SearchUserItem).userName,
                    avatarSize: 40
                  })
                  Column() {
                    Text((user as SearchUserItem).userName).fontSize(15).fontColor(AppColors.textPrimary)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`UID: ${(user as SearchUserItem).uid}`)
                      .fontSize(13).fontColor(AppColors.textTertiary).margin({ top: 2 })
                  }
                  .layoutWeight(1).margin({ left: 12 }).alignItems(HorizontalAlign.Start)
                  .onClick((event: ClickEvent) => {
                    this.showProfileCard((user as SearchUserItem).uid, event.windowX, event.windowY)
                  })

                  Stack() {
                    Image($r('app.media.icon_chevron_down')).width(18).height(18)
                      .fillColor(AppColors.textTertiary).rotate({ angle: -90 })
                  }
                  .width(40).height(40)
                  .onClick((event: ClickEvent) => {
                    this.showProfileCard((user as SearchUserItem).uid, event.windowX, event.windowY)
                  })
                }
                .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 }).alignItems(VerticalAlign.Center)
              }
            }, (user: object) => (user as SearchUserItem).uid)
          }.width('100%').layoutWeight(1).divider({ strokeWidth: 0.5, color: AppColors.separator })
          .contentStartOffset(this.fixedHeaderHeight)
          .linearGradientBlur(
            TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),
            {
              fractionStops: TitleScrollEffect.getBlurStops(
                this.listViewportHeight, this.statusBarHeight, this.fixedHeaderHeight),
              direction: GradientDirection.Bottom
            }
          )
          .edgeEffect(EdgeEffect.Spring)
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
      } else {
        if (this.threads.length === 0) {
          Column() {
            EmptyStateView({ msg: '未找到相关结果', icon: $r('app.media.icon_search') })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .padding({ top: this.fixedHeaderHeight })
        } else {
          List({ scroller: this.scroller }) {
            LazyForEach(this.threadsDataSource, (thread: object) => {
              ListItem() {
                this.SearchTopicCard(thread as Record<string, Object>)
              }
            }, (thread: object) => String((thread as Record<string, Object>)['tid'] ?? ''))
            ListItem() {
              Row() {
                if (this.isLoadingMore) {
                  LoadingProgress().width(16).height(16).color(AppColors.textTertiary)
                  Text('加载更多...').fontSize(13).fontColor(AppColors.textTertiary).margin({ left: 8 })
                } else if (this.currentPage >= this.totalPages && this.threads.length > 0) {
                  Text('— 已到底 —').fontSize(12).fontColor(AppColors.textTertiary)
                }
              }.width('100%').justifyContent(FlexAlign.Center).padding(16)
            }
          }.width('100%').layoutWeight(1).divider({ strokeWidth: 0.5, color: AppColors.separator })
          .contentStartOffset(this.fixedHeaderHeight)
          .linearGradientBlur(
            TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),
            {
              fractionStops: TitleScrollEffect.getBlurStops(
                this.listViewportHeight, this.statusBarHeight, this.fixedHeaderHeight),
              direction: GradientDirection.Bottom
            }
          )
          .edgeEffect(EdgeEffect.Spring)
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
          .onReachEnd(() => { if (!this.isLoadingMore && this.currentPage < this.totalPages) { this.doSearch(this.currentPage + 1) } })
        }
      }
      }
      .width('100%').height('100%')

      Column() {
        if (this.titleScrollEffectProgress > 0) {
          // 搜索区背板：对齐帖子标题区——透明承载，滚动时叠加向下衰减的主题同色偏色。
          // 必须绝对定位（不参与布局）：若作为布局子元素，其高度依赖 fixedHeaderHeight
          // 会形成自引用膨胀（偏色撑高固定区 → 高度更新 → 更高），导致模糊区域失控。
          Column()
            .width('100%')
            .height(this.fixedHeaderHeight + TITLE_BLUR_FADE_DISTANCE)
            .linearGradient({
              angle: 180,
              colors: [
                [$r('app.color.title_backdrop_tint'), 0],
                [
                  $r('app.color.title_backdrop_tint'),
                  this.fixedHeaderHeight / (this.fixedHeaderHeight + TITLE_BLUR_FADE_DISTANCE)
                ],
                [$r('app.color.title_backdrop_clear'), 1]
              ]
            })
            .opacity(TitleScrollEffect.getBackdropOpacity(this.titleScrollEffectProgress))
            .hitTestBehavior(HitTestMode.None)
            .position({ x: 0, y: 0 })
        }

        Row() {
          // 返回按钮（对齐帖子标题区：圆形光感底板 + 按压反馈）
          Row() {
            Stack() {
              Image($r('app.media.icon_back')).width(18).height(18)
                .fillColor(UIMaterialManager.adaptiveForeground)
            }
            .width(36).height(36).borderRadius(18)
            .backgroundColor(Color.Transparent)
            .systemMaterial(UIMaterialManager.fabMaterial)
            .accessibilityText('返回')
            .onClick(() => routerStore.back())
          }
          .width(54).height(44).justifyContent(FlexAlign.Center)
          .margin({ left: 8, right: 10 })

          Row() {
            Image($r('app.media.icon_search')).width(16).height(16)
              .fillColor(UIMaterialManager.adaptiveSecondaryForeground).margin({ right: 8 })
            TextInput({ text: this.keyword, placeholder: this.boardFid !== 0 ? `在「${this.boardName}」内搜索` : '搜索板块、主题、内容...' })
              .layoutWeight(1).fontSize(15).backgroundColor(Color.Transparent).type(InputType.Normal)
              .fontColor(UIMaterialManager.inputForeground)
              .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
              .caretColor(UIMaterialManager.inputForeground)
              .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
              .onChange((value: string) => {
                this.keyword = value
                this.scheduleAutoSubmit()
              })
              .onSubmit(() => this.handleSubmit())
            if (this.keyword.length > 0) {
              Image($r('app.media.icon_close')).width(16).height(16)
                .fillColor(UIMaterialManager.adaptiveSecondaryForeground)
                .margin({ left: 8 })
                .onClick(() => {
                  if (this.debounceTimer >= 0) {
                    clearTimeout(this.debounceTimer)
                    this.debounceTimer = -1
                  }
                  this.keyword = ''; this.submitted = ''; this.threads = []; this.forums = []; this.users = []; this.threadsDataSource.clear(); this.forumsDataSource.clear(); this.usersDataSource.clear(); this.currentPage = 1; this.totalPages = 0; this.searchFailed = false; this.titleScrollEffectProgress = 0
                })
            }
          }.layoutWeight(1).height(44).padding({ left: 14, right: 14 })
          .backgroundColor(Color.Transparent).borderRadius(22).alignItems(VerticalAlign.Center)
          // 不设 border：材质与边框同设违反沉浸光感契约（IMMERSIVE_LIGHT_DESIGN 第 4 节）
          .systemMaterial(UIMaterialManager.inputMaterial)
          .margin({ right: 16 })
        }.width('100%').padding({ top: 8 + this.statusBarHeight, bottom: 8 }).alignItems(VerticalAlign.Center)

        if (this.boardFid !== 0) {
          Row() {
            Text(`在「${this.boardName}」内搜索`)
              .fontSize(12).fontColor(AppColors.textTertiary).layoutWeight(1)
              .textAlign(TextAlign.Start).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('切回全部')
              .fontSize(12).fontColor(AppColors.primary).margin({ left: 12 })
              .onClick(() => {
                if (this.onExitBoardScope) { this.onExitBoardScope() }
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 4 })
        }

        Row() {
          SegmentButton({
            options: this.tabOptions,
            selectedIndexes: $tabSelected,
            onItemClicked: (index: number): void => {
              this.handleTabChange(index)
            }
          })
        }
        .width('100%')
        .padding({ left: '4%', right: '4%' })
        .margin({ top: 6, bottom: 8 })
      }
      .width('100%')
      .backgroundColor(Color.Transparent)
      // 背板透明：模糊由列表内容自身的 linearGradientBlur 渐变承担（对齐帖子列表标题区设计）
      .position({ x: 0, y: 0 })
      .onAreaChange((_oldValue: Area, newValue: Area): void => {
        // 实测顶部固定区高度，内容区据此精确避让（避免列表被固定区遮挡/错位）
        if (typeof newValue.height === 'number' && newValue.height !== this.fixedHeaderHeight) {
          this.fixedHeaderHeight = newValue.height
          // 高度变化会改变 contentStartOffset/getProgress 基准，立即重算一次滚动进度
          this.syncTitleScrollEffect()
        }
      })
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg)
  }

  @Builder
  SearchTopicCard(thread: Record<string, Object>) {
    Column() {
      Row() {
        if (this.isAuthorBlacklisted(thread)) {
          Text('该用户已被屏蔽')
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_TITLE, this.topicFontSize))
            .fontColor(AppColors.textTertiary)
            .layoutWeight(1)
        } else {
          Text(this.getTypeTags(Number(thread['type'] ?? 0)))
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_TITLE, this.topicFontSize))
            .fontColor(AppColors.textTertiary)
          Text(unescapeHtml(String(thread['subject'] ?? '')))
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_TITLE, this.topicFontSize))
            .fontColor(this.getSubjectFontColor(String(thread['titleFont'] ?? '')))
            .fontWeight(this.isSubjectBold(String(thread['titleFont'] ?? '')) ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(this.isSubjectItalic(String(thread['titleFont'] ?? '')) ? FontStyle.Italic : FontStyle.Normal)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        }
      }.width('100%').alignItems(VerticalAlign.Top)

      if (thread['previewSnippet']) {
        if (this.isPreviewAuthorBlacklisted(thread)) {
          Text('该用户已被屏蔽')
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_SUMMARY, this.topicFontSize))
            .fontColor(AppColors.textTertiary)
            .margin({ top: 6 })
            .width('100%')
        } else {
          Text(unescapeHtml(String(thread['previewSnippet'] ?? '')))
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_SUMMARY, this.topicFontSize))
            .fontColor(AppColors.textSecondary)
            .maxLines(2)
            .lineHeight(ReadingTypography.lineHeight(
              ReadingLineHeightRole.TOPIC_SUMMARY,
              ReadingTypography.fontSize(ReadingFontRole.TOPIC_SUMMARY, this.topicFontSize)
            ))
            .textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 6 }).width('100%')
        }
      }

      Row() {
        Row() {
          AnonymousName({ author: String(thread['author'] ?? ''), isAnonymous: thread['isAnonymity'] as boolean, fontSize: 12 })
          if (appStore.settingsStore.getNote(String(thread['authorId'] ?? '')).length > 0) {
            Text('(' + appStore.settingsStore.getNote(String(thread['authorId'] ?? '')) + ')')
              .fontSize(11).fontColor(AppColors.warning).margin({ left: 3 })
          }
          Text(` · ${formatTime(Number(thread['postDate'] ?? 0))}`)
            .fontSize(12).fontColor(AppColors.textTertiary)
          // 跨版块搜索结果补展示所属版块（同版块内搜索时 parent 为空，不重复显示）
          if (String(thread['board'] ?? '').length > 0) {
            Text(` · ${unescapeHtml(String(thread['board'] ?? ''))}`)
              .fontSize(12).fontColor(AppColors.textTertiary)
          }
        }
        Row() { Image($r('app.media.icon_chat_bubble')).width(12).height(12).fillColor(AppColors.textTertiary); Text(` ${thread['replies'] ?? 0}`).fontSize(12).fontColor(AppColors.textTertiary) }
      }.width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ top: 8 })
    }
    .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 }).alignItems(HorizontalAlign.Start)
    .onClick(() => {
      const tid = String(thread['tid'] ?? '')
      if (tid) {
        routerStore.navigateActivity(Screen.thread(tid, 1, '', ThreadSource.SEARCH))
      }
    })
  }
}
