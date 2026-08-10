import { display, LengthMetrics } from '@kit.ArkUI'
import { common, Context } from '@kit.AbilityKit'
import { motion } from '@kit.MultimodalAwarenessKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { taskpool } from '@kit.ArkTS'

import { appStore } from '../store/AppStore'
import { routerStore, Screen } from '../store/RouterStore'
import { getThread } from '../service/api/ThreadApi'
import { votePost } from '../service/api/FavoriteApi'
import { getActiveDomain } from '../service/api/MiscApi'
import type { ThreadResult, PostReplyResult } from '../model/ThreadResult'
import type { PostInfo } from '../model/PostInfo'
import type { VoteResult } from '../model/NgaApiResults'
import { FavoriteMembershipState } from '../model/Favorite'
import { getCachedBBNodes } from '../parser/bbcode/BBCodeCache'
import { preWarmPosts } from '../common/utils/PostWarmup'
import {
  AppColors,
  NAV_BAR_H,
  ThreadNavMode
} from '../common/constants/Constants'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { PostItem } from '../common/components/PostItem'
import { PostInfoDataSource } from '../common/datasource/LazyDataSource'
import { LoadingStateView, ErrorStateView } from '../common/components/PageStateView'
import { floatingLayerStore, FloatingPage } from '../store/FloatingLayerStore'
import { replyManager, ReplyType } from '../common/managers/ReplyManager'
import { withTimeout } from '../common/utils/TimeoutUtils'
import { bbNodesToPlainText } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { TtsMediaMetadata } from '../common/media/TtsAvSessionController'
import { TtsPlayer } from '../common/media/TtsPlayer'
import { shareThread, sharePost } from '../common/utils/ShareUtils'
import { openImageViewer as sharedOpenImageViewer, handleForumLink } from '../common/utils/LinkUtils'
import { ThreadPaginationManager } from '../common/managers/ThreadPaginationManager'
import type { ThreadInfo } from '../model/Thread'
import { Logger, DOMAIN_UI, formatError } from '../common/utils/Logger'
import { getActiveAiValidationMessage } from '../service/ai/ActiveAiService'
import { applyBlacklistStateToPosts } from '../common/utils/BlacklistUtils'
import { UIMaterialManager } from '../common/managers/UIMaterialManager'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'

const logger = new Logger(DOMAIN_UI, 'ThreadPanel')

/** 设备握持状态。 */
enum HoldingHandStatus {
  /** 未检测到握持。 */
  NOT_HELD = 0,
  /** 左手握持。 */
  LEFT_HAND_HELD = 1,
  /** 右手握持。 */
  RIGHT_HAND_HELD = 2,
  /** 双手握持。 */
  BOTH_HANDS_HELD = 3,
  /** 无法识别的握持状态。 */
  UNKNOWN_STATUS = 16
}

/** 帖子页面结果写入连续窗口的方式。 */
enum ThreadLoadMode {
  /** 用目标页重建窗口。 */
  REPLACE = 0,
  /** 将下一相邻页追加到窗口末尾。 */
  APPEND = 1,
  /** 将上一相邻页插入窗口开头。 */
  PREPEND = 2
}

/** 用户通过底部分页控件发起跳页的来源。 */
enum PageNavigationSource {
  /** 点击相邻页码按钮。 */
  PAGER_BUTTON = 0,
  /** 从页码选择器中选择页面。 */
  PAGE_PICKER = 1
}

const PAGE_LOAD_AHEAD_ITEMS: number = 3

/** 带请求页码的预取结果。 */
class FetchPageResult {
  /** 请求页码。 */
  page: number = 0

  /** 页面接口结果。 */
  result: ThreadResult | null = null
}

/**
 * 帖子详情面板。
 *
 * 修改滚动、分页或标题栏布局前必须先阅读 `docs/THREAD_DESIGN.md`。
 * 固定透明标题栏覆盖全屏列表，顶部安全区只由 `contentStartOffset` 表达；
 * 禁止重新引入伪列表占位项或全局索引补偿。
 */
@Component
export struct ThreadPanel {
  @State holdingStatus: HoldingHandStatus = appStore.settings.holdingHand as HoldingHandStatus
  @State holdingDetected: boolean = false

  @Prop @Watch('onThreadChanged') threadTid: string = ''
  /** 路由请求的初始页码。 */
  @Prop threadPage: number = 1
  @Prop threadPid: string = ''
  @Prop @Watch('onScrollToPid') navEntryId: number = 0
  @State isLoading: boolean = true
  @State hasError: boolean = false
  @State errorMsg: string = ''
  private postsDataSource: PostInfoDataSource = new PostInfoDataSource()
  @State displayPage: number = 1
  @State isLoadingMore: boolean = false
  @State isLoadingPrevious: boolean = false
  @State authorOnly: boolean = false
  @State favoriteState: FavoriteMembershipState = FavoriteMembershipState.UNKNOWN
  /** 主题收藏关系变更版本号。 */
  @StorageProp('favoriteTopicVersion') @Watch('onFavoriteTopicVersionChange') favoriteTopicVersion: number = 0
  @State threadSubject: string = '帖子'
  @State threadFid: number = 0
  @State threadAuthorId: string = ''
  @State votedUpPids: Set<string> = new Set()
  @State votedDownPids: Set<string> = new Set()
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @StorageProp('navBarHeight') navBarHeight: number = 0
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 黑名单变更版本号。 */
  @StorageProp('blacklistVersion') @Watch('onBlacklistVersionChange') blacklistVersion: number = 0
  @State showMoreMenu: boolean = false
  @State showPagePicker: boolean = false
  private pagePickerTotalPages: number = 0
  private pagePickerCurrentPage: number = 0
  private pagePickerOnSelect: ((page: number) => void) | null = null
  private scroller: Scroller = new Scroller()
  /** List 当前视口高度，用于将固定 vp 标题区换算为渐变模糊比例。 */
  @State listViewportHeight: number = 1

  /**
   * 按 List 的绝对滚动偏移同步标题栏视觉效果。
   *
   * `onDidScroll` 上报的是帧间增量，不能直接用作标题栏状态；滚动进度在前 20vp
   * 内从 0 线性变化到 1，回到顶部或发生顶部回弹时归零。
   */
  private syncTitleScrollEffect(): void {
    const progress: number = TitleScrollEffect.getProgress(
      this.scroller.currentOffset().yOffset,
      this.statusBarHeight
    )
    if (TitleScrollEffect.shouldUpdateProgress(this.titleScrollEffectProgress, progress)) {
      this.titleScrollEffectProgress = progress
    }
  }

  /**
   * 获取正文渐变模糊的空间停靠点。
   *
   * 标题区内保持最大模糊，标题底部以下 32vp 连续衰减到零；最后一个停靠点
   * 固定为 1，确保不同窗口高度下的位置严格递增。
   *
   * @returns 渐变模糊强度与位置组成的停靠点
   */
  private getTitleBlurStops(): FractionStop[] {
    return TitleScrollEffect.getBlurStops(this.listViewportHeight, this.statusBarHeight)
  }

  /** onScrollIndex 最近上报的首个可见列表项下标，用于判断是否靠近顶部。 */
  private lastScrollStart: number = 0

  /** onScrollIndex 最近上报的末个可见列表项下标，用于判断是否靠近底部。 */
  private lastScrollEnd: number = 0

  /** 尚未交给帖子接口定位的路由目标楼层。 */
  private pendingTargetPid: string = ''

  /** 整页未命中目标 pid 后是否已发起单帖兜底请求，防止重复兜底。 */
  private singlePostFallback: boolean = false

  /** 单帖兜底前整页窗口的真实总页数（单帖视图 __ROWS=1 会把 totalPages 重置为 1）。 */
  private fallbackPrevTotalPages: number = 0

  /** 单帖兜底前记录的被引楼层所在页（单帖视图 __PAGE=1，用于恢复显示页）。 */
  private fallbackPrevPage: number = 0

  @State mgr: ThreadPaginationManager = new ThreadPaginationManager()

  /** 每个预取页对应的会话代际，用于去重并隔离重置前后的请求。 */
  private prefetchGenerationByPage: Map<number, number> = new Map()

  /** 最近一次替换加载的目标页，用于失败重试。 */
  private lastReplacePage: number = 1

  /** 替换加载完成后是否仍等待 List 挂载并执行定位。 */
  private listNavigationPending: boolean = false

  /** 待执行 List 定位所属的分页会话代际。 */
  private listNavigationGeneration: number = -1

  /** 待定位页面，用于诊断请求页与服务端实际页差异。 */
  private listNavigationPage: number = 1

  /** 待定位楼层；空字符串表示定位到页面开头。 */
  private listNavigationPid: string = ''

  /** 是否已经为当前 List 导航安排下一帧任务。 */
  private listNavigationScheduled: boolean = false

  /** 当前 List 是否已经挂载并与 Scroller 建立绑定。 */
  private listMounted: boolean = false

  /** 前插帖子后是否仍等待恢复原可见帖子锚点。 */
  private prependAnchorPending: boolean = false

  /** 前插锚点所属的分页会话代际。 */
  private prependAnchorGeneration: number = -1

  /** 前插前首个可见帖的 pid。 */
  private prependAnchorPid: number = -1

  /** 前插前锚点帖子相对 List 顶部的纵向位置。 */
  private prependAnchorOffset: number = 0

  /** 触发前插的页面，用于运行态诊断。 */
  private prependAnchorPage: number = 1

  /** 是否已经为当前前插锚点安排恢复任务。 */
  private prependAnchorScheduled: boolean = false

  @State loadingContentOpacity: number = 0
  private loadingDelayTimer: number = -1

  private holdingCallback: Callback<HoldingHandStatus> = (data: HoldingHandStatus): void => {
    if (this.holdingDetected) {
      this.getUIContext()?.animateTo({ duration: 300, curve: Curve.EaseInOut }, (): void => {
        this.holdingStatus = data
      })
    } else {
      this.holdingStatus = data
      this.holdingDetected = true
    }
    if (appStore.settings.holdingHand !== data) {
      appStore.settingsStore.setHoldingHand(data)
    }
  }

  private startHoldingHandMonitoring(): void {
    if (!appStore.settings.smartGrip) return
    try {
      motion.on('holdingHandChanged', this.holdingCallback)
    } catch (err) {
      logger.error('startHolding fail: %{public}d', (err as BusinessError).code)
    }
  }

  private stopHoldingHandMonitoring(): void {
    try {
      motion.off('holdingHandChanged', this.holdingCallback)
    } catch (err) {
      logger.error('stopHolding fail: %{public}d', (err as BusinessError).code)
    }
  }

  private showProfileCard(uid: string, screenX: number, screenY: number): void {
    const cardW: number = 280
    const cardH: number = 400
    const pad: number = 8
    let posX: number = screenX
    let posY: number = screenY
    try {
      const context = this.getUIContext()
      const displayInfo = display.getDefaultDisplaySync()
      const screenW = context.px2vp(displayInfo.width)
      const screenH = context.px2vp(displayInfo.height)
      posX = Math.max(pad, Math.min(screenX - cardW / 2, screenW - cardW - pad))
      posY = Math.max(pad, Math.min(screenY + pad, screenH - cardH - pad))
    } catch (e) {
      posX = screenX - cardW / 2
      posY = screenY + pad
    }
    floatingLayerStore.profileCardUid = uid
    floatingLayerStore.profileCardX = posX
    floatingLayerStore.profileCardY = posY
    floatingLayerStore.push(FloatingPage.PROFILE_CARD)
  }

  private hasInitiallyLoaded: boolean = false

  aboutToAppear(): void {
    this.hasInitiallyLoaded = true
    const initialPage: number = Math.max(this.threadPage, 1)
    this.pendingTargetPid = this.threadPid
    this.singlePostFallback = false
    this.displayPage = initialPage
    if (this.threadTid) {
      this.loadPosts(initialPage, ThreadLoadMode.REPLACE)
    }
    this.syncFavoriteState()
    appStore.favoriteStore.ensureFolders()
    this.loadPersistedVotes()
    this.startHoldingHandMonitoring()
  }

  aboutToDisappear(): void {
    this.stopHoldingHandMonitoring()
    clearTimeout(this.loadingDelayTimer)
    this.loadingDelayTimer = -1
    this.prefetchGenerationByPage.clear()
    this.listNavigationPending = false
    this.listNavigationScheduled = false
    this.listNavigationGeneration = -1
    this.listNavigationPid = ''
    this.listMounted = false
    this.prependAnchorPending = false
    this.prependAnchorGeneration = -1
    this.prependAnchorPid = -1
    this.prependAnchorOffset = 0
    this.prependAnchorScheduled = false
    this.mgr.reset()
  }

  private onThreadChanged(): void {
    if (!this.hasInitiallyLoaded) {
      this.hasInitiallyLoaded = true
      return
    }
    const initialPage: number = Math.max(this.threadPage, 1)
    this.pendingTargetPid = this.threadPid
    this.singlePostFallback = false
    this.fallbackPrevTotalPages = 0
    this.fallbackPrevPage = 0
    this.displayPage = initialPage
    this.isLoading = true
    this.isLoadingMore = false
    this.isLoadingPrevious = false
    this.hasError = false
    this.authorOnly = false
    this.syncFavoriteState()
    this.votedUpPids = new Set()
    this.votedDownPids = new Set()
    this.loadPosts(initialPage, ThreadLoadMode.REPLACE)
    this.loadPersistedVotes()
  }

  /**
   * 响应黑名单变化，保留楼层结构并即时刷新内容遮蔽状态。
   */
  private onBlacklistVersionChange(): void {
    applyBlacklistStateToPosts(this.mgr.posts, appStore.settingsStore.getBlacklistIds())
  }

  /**
   * 响应主题收藏关系变化并刷新当前帖子收藏状态。
   */
  private onFavoriteTopicVersionChange(): void {
    this.syncFavoriteState()
  }

  /**
   * 从全局收藏 Store 同步当前帖子收藏状态。
   */
  private syncFavoriteState(): void {
    this.favoriteState = this.threadTid.length > 0
      ? appStore.favoriteStore.getTopicFavoriteState(this.threadTid)
      : FavoriteMembershipState.UNKNOWN
  }

  /**
   * 返回当前可信收藏状态对应的菜单文案。
   *
   * @returns 收藏操作菜单文案
   */
  private getFavoriteMenuLabel(): string {
    if (this.favoriteState === FavoriteMembershipState.FAVORED) {
      return '管理收藏'
    }
    if (this.favoriteState === FavoriteMembershipState.NOT_FAVORED) {
      return '收藏到…'
    }
    return '收藏夹…'
  }

  /**
   * 获取当前可显示的主题标题。
   *
   * @returns 屏蔽作者时返回占位文案，否则返回原主题标题
   */
  private getVisibleThreadSubject(): string {
    if (this.blacklistVersion >= 0 &&
      appStore.settingsStore.isBlacklisted(this.threadAuthorId)) {
      return '该用户已被屏蔽'
    }
    return this.threadSubject
  }

  private async loadPersistedVotes(): Promise<void> {
    if (!appStore.auth.isAuthenticated) return
    const result = await appStore.loadVoteRecord(appStore.auth.uid, this.threadTid)
    this.votedUpPids = result[0]
    this.votedDownPids = result[1]
  }

  /**
   * 将目标楼层瞬时定位到视口中央。
   */
  private onScrollToPid(): void {
    if (this.threadPid.length === 0 || this.mgr.posts.length === 0) {
      return
    }
    const positioned: boolean = this.scrollToPid(this.threadPid)
    logger.info(
      'floor-nav direct tid=%{public}s pid=%{public}s positioned=%{public}s gen=%{public}d window=%{public}d-%{public}d',
      this.threadTid, this.threadPid, String(positioned), this.mgr.getGeneration(),
      this.mgr.loadedPageStart, this.mgr.loadedPageEnd
    )
  }

  /**
   * 按 pid 将楼层定位到视口中央。
   *
   * @param pid - 目标楼层 pid
   * @returns 是否找到并发出了定位命令
   */
  private scrollToPid(pid: string): boolean {
    const pidNumber: number = parseInt(pid, 10)
    const postIndex: number = this.mgr.findPostIndex(pidNumber)
    if (postIndex < 0) {
      return false
    }
    this.scroller.scrollToIndex(postIndex, false, ScrollAlign.CENTER)
    return true
  }

  /**
   * 处理底部分页控件发起的页面跳转。
   *
   * @param targetPage - 目标页
   * @param source - 跳页来源
   */
  private navigateToPage(targetPage: number, source: PageNavigationSource): void {
    const boundedPage: number = Math.max(1, Math.min(targetPage, this.mgr.totalPages))
    logger.info(
      'page-nav request source=%{public}s tid=%{public}s display=%{public}d target=%{public}d bounded=%{public}d ' +
        'gen=%{public}d window=%{public}d-%{public}d visible=%{public}d-%{public}d',
      this.getNavigationSourceName(source), this.threadTid, this.displayPage, targetPage, boundedPage,
      this.mgr.getGeneration(), this.mgr.loadedPageStart, this.mgr.loadedPageEnd,
      this.lastScrollStart, this.lastScrollEnd
    )
    // 用户主动跳页不再携带路由进入时的目标楼层意图
    this.pendingTargetPid = ''
    this.singlePostFallback = false
    this.fallbackPrevTotalPages = 0
    this.fallbackPrevPage = 0
    this.loadPosts(boundedPage, ThreadLoadMode.REPLACE)
  }

  /**
   * 返回可读的跳页来源名称。
   *
   * @param source - 跳页来源
   * @returns 日志名称
   */
  private getNavigationSourceName(source: PageNavigationSource): string {
    return source === PageNavigationSource.PAGE_PICKER ? 'page-picker' : 'pager-button'
  }

  /**
   * 返回可读的加载模式名称。
   *
   * @param mode - 加载模式
   * @returns 日志名称
   */
  private getLoadModeName(mode: ThreadLoadMode): string {
    if (mode === ThreadLoadMode.REPLACE) return 'replace'
    if (mode === ThreadLoadMode.APPEND) return 'append'
    return 'prepend'
  }

  /**
   * 为替换加载登记 List 挂载后的定位意图。
   *
   * @param generation - 分页会话代际
   * @param page - 服务端实际页码
   * @param pid - 目标楼层 pid
   */
  private prepareListNavigation(generation: number, page: number, pid: string): void {
    this.listNavigationPending = true
    this.listNavigationScheduled = false
    this.listNavigationGeneration = generation
    this.listNavigationPage = page
    this.listNavigationPid = pid
    logger.info(
      'list-nav prepared tid=%{public}s page=%{public}d pid=%{public}s gen=%{public}d posts=%{public}d',
      this.threadTid, page, pid, generation, this.mgr.posts.length
    )
  }

  /**
   * 取消指定会话尚未执行的 List 定位。
   *
   * @param generation - 分页会话代际
   * @param reason - 取消原因
   */
  private cancelListNavigation(generation: number, reason: string): void {
    if (this.listNavigationGeneration !== generation) return
    logger.warn(
      'list-nav cancel tid=%{public}s page=%{public}d pid=%{public}s gen=%{public}d reason=%{public}s',
      this.threadTid, this.listNavigationPage, this.listNavigationPid, generation, reason
    )
    this.listNavigationPending = false
    this.listNavigationScheduled = false
    this.listNavigationGeneration = -1
    this.listNavigationPid = ''
  }

  /**
   * 在 List 挂载后安排下一帧定位，确保 Scroller 已绑定到真实组件。
   */
  private scheduleListNavigation(): void {
    if (!this.listNavigationPending || this.listNavigationScheduled || !this.listMounted) return
    const generation: number = this.listNavigationGeneration
    this.listNavigationScheduled = true
    logger.info(
      'list-nav schedule tid=%{public}s page=%{public}d pid=%{public}s gen=%{public}d',
      this.threadTid, this.listNavigationPage, this.listNavigationPid, generation
    )
    setTimeout((): void => {
      if (this.listNavigationGeneration !== generation) {
        return
      }
      this.listNavigationScheduled = false
      if (!this.listMounted) {
        logger.info(
          'list-nav wait-mount tid=%{public}s page=%{public}d pid=%{public}s gen=%{public}d',
          this.threadTid, this.listNavigationPage, this.listNavigationPid, generation
        )
        return
      }
      this.applyListNavigation(generation)
    }, 0)
  }

  /**
   * 执行已经完成挂载的 List 定位，并恢复滚动分页协调。
   *
   * @param generation - 定位所属的分页会话代际
   */
  private applyListNavigation(generation: number): void {
    if (!this.listNavigationPending || generation !== this.mgr.getGeneration()) {
      logger.warn(
        'list-nav discard tid=%{public}s pendingGen=%{public}d currentGen=%{public}d pending=%{public}s',
        this.threadTid, generation, this.mgr.getGeneration(), String(this.listNavigationPending)
      )
      return
    }
    const targetPid: string = this.listNavigationPid
    let positioned: boolean = false
    let targetIndex: number = 0
    if (targetPid.length > 0) {
      const pidNumber: number = parseInt(targetPid, 10)
      const postIndex: number = this.mgr.findPostIndex(pidNumber)
      if (postIndex >= 0) {
        targetIndex = postIndex
        positioned = this.scrollToPid(targetPid)
      }
    }
    if (!positioned && targetPid.length > 0 && !this.singlePostFallback) {
      // 整页未命中目标楼层（页码过期或楼层被删）：发起一次单帖兜底请求，
      // 服务端返回仅含目标楼的单帖视图，其内必含该 pid。
      this.listNavigationPending = false
      this.listNavigationScheduled = false
      this.listNavigationGeneration = -1
      this.listNavigationPid = ''
      this.singlePostFallback = true
      this.fallbackPrevTotalPages = this.mgr.totalPages
      this.fallbackPrevPage = this.listNavigationPage
      logger.warn(
        'list-nav fallback tid=%{public}s pid=%{public}s page=%{public}d gen=%{public}d',
        this.threadTid, targetPid, this.listNavigationPage, generation
      )
      this.loadPosts(1, ThreadLoadMode.REPLACE)
      return
    }
    if (!positioned && targetPid.length > 0) {
      // 单帖兜底已尝试仍失败（服务端返回空或该楼层已删除）
      appStore.showToast('该楼层不存在或已删除')
    }
    if (!positioned) {
      this.scroller.scrollToIndex(0, false, ScrollAlign.START)
      positioned = true
    }
    this.listNavigationPending = false
    this.listNavigationGeneration = -1
    this.listNavigationPid = ''
    this.pendingTargetPid = ''
    this.singlePostFallback = false
    if (this.fallbackPrevPage > 0) {
      this.displayPage = this.fallbackPrevPage
    }
    this.fallbackPrevTotalPages = 0
    this.fallbackPrevPage = 0
    logger.info(
      'list-nav applied tid=%{public}s page=%{public}d pid=%{public}s index=%{public}d positioned=%{public}s ' +
        'gen=%{public}d window=%{public}d-%{public}d',
      this.threadTid, this.listNavigationPage, targetPid, targetIndex, String(positioned), generation,
      this.mgr.loadedPageStart, this.mgr.loadedPageEnd
    )
    this.scheduleReconcile(generation)
  }

  /**
   * 在提交上一页前记录当前首个可见帖子，作为数据前插后的稳定视口锚点。
   *
   * @param page - 即将提交的上一页页码
   * @returns 是否成功记录了可恢复的帖子锚点
   */
  private preparePrependAnchor(page: number): boolean {
    const postCount: number = this.mgr.posts.length
    if (postCount <= 0) return false
    const anchorListIndex: number = Math.max(0, Math.min(this.lastScrollStart, postCount - 1))
    const anchorPostIndex: number = anchorListIndex
    const anchorPid: number = this.mgr.posts[anchorPostIndex].pid
    let anchorOffset: number = 0
    try {
      anchorOffset = this.scroller.getItemRect(anchorListIndex).y
    } catch (error) {
      logger.warn(
        'prepend-anchor rect-failed tid=%{public}s page=%{public}d index=%{public}d error=%{public}s',
        this.threadTid, page, anchorListIndex, formatError(error)
      )
    }
    this.prependAnchorPending = true
    this.prependAnchorGeneration = this.mgr.getGeneration()
    this.prependAnchorPid = anchorPid
    this.prependAnchorOffset = anchorOffset
    this.prependAnchorPage = page
    this.prependAnchorScheduled = false
    logger.info(
      'prepend-anchor prepared tid=%{public}s page=%{public}d pid=%{public}d index=%{public}d ' +
        'offset=%{public}s gen=%{public}d visible=%{public}d-%{public}d',
      this.threadTid, page, anchorPid, anchorListIndex, String(anchorOffset),
      this.prependAnchorGeneration, this.lastScrollStart, this.lastScrollEnd
    )
    return true
  }

  /**
   * 取消尚未完成的前插锚点恢复。
   *
   * @param reason - 取消原因
   */
  private cancelPrependAnchor(reason: string): void {
    if (!this.prependAnchorPending) return
    logger.warn(
      'prepend-anchor cancel tid=%{public}s page=%{public}d pid=%{public}d gen=%{public}d reason=%{public}s',
      this.threadTid, this.prependAnchorPage, this.prependAnchorPid,
      this.prependAnchorGeneration, reason
    )
    this.prependAnchorPending = false
    this.prependAnchorGeneration = -1
    this.prependAnchorPid = -1
    this.prependAnchorOffset = 0
    this.prependAnchorScheduled = false
  }

  /**
   * 在前插数据完成布局后安排帖子锚点恢复。
   */
  private schedulePrependAnchorRestore(): void {
    if (!this.prependAnchorPending || this.prependAnchorScheduled || !this.listMounted) return
    const generation: number = this.prependAnchorGeneration
    this.prependAnchorScheduled = true
    setTimeout((): void => {
      if (!this.prependAnchorPending || generation !== this.prependAnchorGeneration) return
      if (!this.listMounted) {
        this.prependAnchorScheduled = false
        return
      }
      const anchorPostIndex: number = this.mgr.findPostIndex(this.prependAnchorPid)
      if (anchorPostIndex < 0) {
        this.cancelPrependAnchor('pid-missing')
        this.scheduleReconcile(generation)
        return
      }
      const targetListIndex: number = anchorPostIndex
      const contentStartOffset: number = NAV_BAR_H + this.statusBarHeight
      const restoreOffset: number = contentStartOffset - this.prependAnchorOffset
      const extraOffset: LengthMetrics = new LengthMetrics(restoreOffset)
      this.scroller.scrollToIndex(targetListIndex, false, ScrollAlign.START, { extraOffset: extraOffset })
      logger.info(
        'prepend-anchor restore tid=%{public}s page=%{public}d pid=%{public}d index=%{public}d ' +
          'offset=%{public}s restoreOffset=%{public}s gen=%{public}d',
        this.threadTid, this.prependAnchorPage, this.prependAnchorPid,
        targetListIndex, String(this.prependAnchorOffset), String(restoreOffset), generation
      )
      setTimeout((): void => {
        if (!this.prependAnchorPending || generation !== this.prependAnchorGeneration) return
        if (!this.listMounted) {
          this.prependAnchorScheduled = false
          return
        }
        const restoredPostIndex: number = this.mgr.findPostIndex(this.prependAnchorPid)
        const restoredListIndex: number = restoredPostIndex >= 0 ? restoredPostIndex : targetListIndex
        this.lastScrollStart = restoredListIndex
        this.lastScrollEnd = restoredListIndex
        if (restoredPostIndex >= 0) {
          this.displayPage = this.mgr.getDisplayPage(restoredPostIndex)
        }
        logger.info(
          'prepend-anchor applied tid=%{public}s page=%{public}d pid=%{public}d index=%{public}d ' +
            'display=%{public}d gen=%{public}d window=%{public}d-%{public}d',
          this.threadTid, this.prependAnchorPage, this.prependAnchorPid, restoredListIndex,
          this.displayPage, generation, this.mgr.loadedPageStart, this.mgr.loadedPageEnd
        )
        this.prependAnchorPending = false
        this.prependAnchorGeneration = -1
        this.prependAnchorPid = -1
        this.prependAnchorOffset = 0
        this.prependAnchorScheduled = false
        this.scheduleReconcile(generation)
      }, 0)
    }, 0)
  }

  /**
   * 根据最近一次可见范围协调双向加载。
   *
   * 帖子占据 `[0, postCount - 1]`，末项之后还有底部状态项。
   * 两个方向拥有独立的请求状态，因此跳页后同时靠近窗口两端时也可安全并行。
   */
  private reconcile(): void {
    if (appStore.settings.threadNavMode === ThreadNavMode.PAGE) return
    if (this.listNavigationPending || this.prependAnchorPending) {
      if (logger.isVerbose()) {
        logger.verbose(
          'reconcile paused tid=%{public}s gen=%{public}d listNav=%{public}s prependAnchor=%{public}s ' +
            'visible=%{public}d-%{public}d',
          this.threadTid, this.mgr.getGeneration(), String(this.listNavigationPending),
          String(this.prependAnchorPending), this.lastScrollStart, this.lastScrollEnd
        )
      }
      return
    }
    const postCount: number = this.postsDataSource.totalCount()
    if (postCount <= 0) return
    const nextThreshold: number = Math.max(postCount - PAGE_LOAD_AHEAD_ITEMS, 0)
    if (logger.isVerbose()) {
      logger.verbose(
        'reconcile tid=%{public}s gen=%{public}d visible=%{public}d-%{public}d nextThreshold=%{public}d ' +
          'window=%{public}d-%{public}d posts=%{public}d nextLoading=%{public}s prevLoading=%{public}s',
        this.threadTid, this.mgr.getGeneration(), this.lastScrollStart, this.lastScrollEnd,
        nextThreshold, this.mgr.loadedPageStart, this.mgr.loadedPageEnd, postCount,
        String(this.isLoadingMore), String(this.isLoadingPrevious)
      )
    }
    if (this.lastScrollEnd >= nextThreshold) {
      this.tryLoadNext()
    }
    if (this.lastScrollStart < PAGE_LOAD_AHEAD_ITEMS) {
      this.tryLoadPrev()
    }
  }

  /**
   * 在当前会话的下一帧再次协调边界加载。
   *
   * 空页或完全重复页不会触发 LazyForEach 的索引变化，需要显式推进到下一相邻页。
   *
   * @param generation - 发起调度时的分页会话代际
   */
  private scheduleReconcile(generation: number): void {
    setTimeout((): void => {
      if (generation === this.mgr.getGeneration()) {
        this.reconcile()
      }
    }, 0)
  }

  /**
   * 构造页码选择器的数据源。
   *
   * @returns 从 1 到总页数的连续页码
   */
  private buildPageArray(): number[] {
    const arr: number[] = []
    for (let i: number = 1; i <= this.pagePickerTotalPages; i++) {
      arr.push(i)
    }
    return arr
  }

  /**
   * 请求并完成一页帖子的通用预处理。
   *
   * @param targetPage - 请求页码
   * @param requestPid - 需要服务端定位的楼层 pid
   * @param timeoutMs - 请求超时时间
   * @param priority - BBCode 预热优先级
   * @param previousPosts - 替换前的帖子，用于补全跨页引用
   * @returns 页面接口结果
   */
  private async fetchPostsPage(
    targetPage: number,
    requestPid: string,
    timeoutMs: number,
    priority: taskpool.Priority,
    previousPosts?: PostInfo[]
  ): Promise<ThreadResult> {
    const noteMap: Record<string, string> = appStore.settingsStore.getNoteMap()
    const isNegativeAuthor: boolean = this.authorOnly && this.threadAuthorId !== '' && Number(this.threadAuthorId) <= 0
    const result: ThreadResult = await withTimeout<ThreadResult>(getThread(
      appStore.auth.token, this.threadTid, requestPid,
      this.authorOnly && !isNegativeAuthor ? this.threadAuthorId : '', String(targetPage),
      appStore.settingsStore.getBlacklistIds(), appStore.settingsStore.getEnabledKeywords(),
      noteMap
    ), timeoutMs)
    if (!result.ok) {
      return result
    }
    applyBlacklistStateToPosts(result.posts, appStore.settingsStore.getBlacklistIds())
    if (isNegativeAuthor) {
      result.posts = result.posts.filter((post: PostInfo): boolean => String(post.authorid) === this.threadAuthorId)
    }
    try {
      await preWarmPosts(result.posts, false, priority)
    } catch (error) {
      logger.warn('preWarmPosts failed: %{public}s', formatError(error))
    }
    this.processPostsQuoteInjection(result.posts, previousPosts)
    return result
  }

  /**
   * 加载一页帖子并按替换、后置或前置模式提交到连续窗口。
   *
   * 只有替换操作会推进分页会话代际；同一会话内的前置和后置请求可以并行，
   * 且分别维护自己的 loading 状态。
   *
   * @param targetPage - 请求页码
   * @param mode - 提交模式
   */
  private async loadPosts(targetPage: number, mode: ThreadLoadMode): Promise<void> {
    const previousPosts: PostInfo[] = mode === ThreadLoadMode.REPLACE ? this.mgr.posts.slice() : []
    const previousGeneration: number = this.mgr.getGeneration()
    const previousStart: number = this.mgr.loadedPageStart
    const previousEnd: number = this.mgr.loadedPageEnd
    if (mode === ThreadLoadMode.REPLACE) {
      if (this.listNavigationPending) {
        this.cancelListNavigation(this.listNavigationGeneration, 'superseded')
      }
      this.cancelPrependAnchor('replace')
      this.lastReplacePage = targetPage
      this.mgr.reset()
      this.prefetchGenerationByPage.clear()
      this.postsDataSource.clear()
      this.isLoading = true
      this.loadingContentOpacity = 0
      clearTimeout(this.loadingDelayTimer)
      this.loadingDelayTimer = setTimeout((): void => {
        if (this.isLoading) {
          this.getUIContext()?.animateTo({ duration: 150, curve: Curve.EaseInOut }, (): void => {
            this.loadingContentOpacity = 1
          })
        }
      }, 400)
      this.isLoadingMore = false
      this.isLoadingPrevious = false
      this.hasError = false
      this.lastScrollStart = 0
      this.lastScrollEnd = 0
      this.titleScrollEffectProgress = 0
    } else if (mode === ThreadLoadMode.APPEND) {
      this.isLoadingMore = true
    } else {
      this.isLoadingPrevious = true
    }

    const generation: number = this.mgr.getGeneration()
    // 本次 REPLACE 的定位意图：路由进入（含引用跳转）携带目标 pid；
    // 请求参数默认不带 pid（服务端带 pid 返回单帖视图，丢失页码与楼层）。
    // 仅单帖兜底时携带 pid，由服务端返回包含目标楼的单帖数据。
    const navPid: string = mode === ThreadLoadMode.REPLACE ? this.pendingTargetPid : ''
    const requestPid: string = mode === ThreadLoadMode.REPLACE && this.singlePostFallback ? navPid : ''
    let windowAdvanced: boolean = false
    logger.info(
      'page-load start mode=%{public}s tid=%{public}s requested=%{public}d pid=%{public}s gen=%{public}d ' +
        'previousGen=%{public}d previousWindow=%{public}d-%{public}d display=%{public}d',
      this.getLoadModeName(mode), this.threadTid, targetPage, requestPid, generation,
      previousGeneration, previousStart, previousEnd, this.displayPage
    )

    try {
      const result: ThreadResult = await this.fetchPostsPage(
        targetPage, requestPid, 15000, taskpool.Priority.HIGH, previousPosts
      )
      if (generation !== this.mgr.getGeneration()) {
        logger.warn(
          'page-load stale mode=%{public}s tid=%{public}s requested=%{public}d capturedGen=%{public}d currentGen=%{public}d',
          this.getLoadModeName(mode), this.threadTid, targetPage, generation, this.mgr.getGeneration()
        )
        return
      }

      if (result.ok) {
        const resolvedPage: number = result.pagination.page > 0 ? result.pagination.page : targetPage
        logger.info(
          'page-load response mode=%{public}s tid=%{public}s requested=%{public}d resolved=%{public}d ' +
            'total=%{public}d posts=%{public}d gen=%{public}d',
          this.getLoadModeName(mode), this.threadTid, targetPage, resolvedPage,
          result.pagination.totalPages, result.posts.length, generation
        )
        if (result.threadInfo !== null) {
          const info: ThreadInfo = result.threadInfo
          this.threadSubject = unescapeHtml(info.subject) || '帖子'
          this.threadFid = info.fid
          if (info.authorid > 0 || this.threadAuthorId === '') {
            this.threadAuthorId = String(info.authorid)
          }
        }

        if (mode === ThreadLoadMode.REPLACE) {
          this.mgr.replaceWith(result.posts, resolvedPage, result.pagination.totalPages)
          if (this.singlePostFallback && this.fallbackPrevTotalPages > 0) {
            // 单帖视图把 totalPages 重置为 1：恢复兜底前整页窗口的真实总页数，
            // 否则分页器消失且 hasNextPage 恒假，用户被困在单帖窗口无法扩展
            this.mgr.totalPages = this.fallbackPrevTotalPages
          }
          this.postsDataSource.replaceAll(result.posts)
          this.displayPage = resolvedPage
          if (appStore.auth.isAuthenticated) {
            appStore.addBrowseHistoryFromThread(appStore.auth.uid, result, this.threadTid)
          }
          this.prepareListNavigation(generation, resolvedPage, navPid)
        } else if (mode === ThreadLoadMode.APPEND) {
          const previousEnd: number = this.mgr.loadedPageEnd
          const added: PostInfo[] = this.mgr.appendPosts(
            result.posts, resolvedPage, result.pagination.totalPages
          )
          windowAdvanced = this.mgr.loadedPageEnd !== previousEnd
          if (added.length > 0) {
            this.postsDataSource.appendAll(added)
          }
        } else {
          const previousStart: number = this.mgr.loadedPageStart
          const anchorPrepared: boolean = this.preparePrependAnchor(resolvedPage)
          const added: PostInfo[] = this.mgr.prependPosts(
            result.posts, resolvedPage, result.pagination.totalPages
          )
          windowAdvanced = this.mgr.loadedPageStart !== previousStart
          if (added.length > 0) {
            this.postsDataSource.prependAll(added)
            if (anchorPrepared) {
              this.schedulePrependAnchorRestore()
            }
          } else if (anchorPrepared) {
            this.cancelPrependAnchor('no-inserted-posts')
          }
        }
        logger.info(
          'page-load commit mode=%{public}s tid=%{public}s requested=%{public}d resolved=%{public}d ' +
            'gen=%{public}d window=%{public}d-%{public}d posts=%{public}d advanced=%{public}s',
          this.getLoadModeName(mode), this.threadTid, targetPage, resolvedPage, generation,
          this.mgr.loadedPageStart, this.mgr.loadedPageEnd, this.mgr.posts.length, String(windowAdvanced)
        )
        this.triggerPrefetches()
      } else {
        logger.error(
          'page-load response-error mode=%{public}s tid=%{public}s requested=%{public}d gen=%{public}d error=%{public}s',
          this.getLoadModeName(mode), this.threadTid, targetPage, generation, result.error || '加载失败'
        )
        if (mode === ThreadLoadMode.REPLACE) {
          this.hasError = true
          this.errorMsg = result.error || '加载失败'
          this.postsDataSource.clear()
          this.cancelListNavigation(generation, 'response-error')
        }
      }
    } catch (error) {
      if (generation !== this.mgr.getGeneration()) {
        logger.warn(
          'page-load exception stale mode=%{public}s tid=%{public}s requested=%{public}d ' +
            'capturedGen=%{public}d currentGen=%{public}d error=%{public}s',
          this.getLoadModeName(mode), this.threadTid, targetPage, generation,
          this.mgr.getGeneration(), formatError(error)
        )
        return
      }
      if (mode === ThreadLoadMode.REPLACE) {
        this.hasError = true
        this.errorMsg = formatError(error) || '加载失败'
        this.postsDataSource.clear()
        this.cancelListNavigation(generation, 'exception')
      } else {
        logger.error('loadPosts failed: %{public}s', formatError(error))
      }
    } finally {
      if (generation !== this.mgr.getGeneration()) return
      if (mode === ThreadLoadMode.REPLACE) {
        clearTimeout(this.loadingDelayTimer)
        this.loadingDelayTimer = -1
        this.loadingContentOpacity = 0
        this.isLoading = false
        this.scheduleListNavigation()
      } else if (mode === ThreadLoadMode.APPEND) {
        this.isLoadingMore = false
      } else {
        this.isLoadingPrevious = false
      }
      if (windowAdvanced) {
        this.scheduleReconcile(generation)
      }
      logger.info(
        'page-load end mode=%{public}s tid=%{public}s requested=%{public}d gen=%{public}d ' +
          'window=%{public}d-%{public}d loading=%{public}s navPending=%{public}s error=%{public}s',
        this.getLoadModeName(mode), this.threadTid, targetPage, generation,
        this.mgr.loadedPageStart, this.mgr.loadedPageEnd, String(this.isLoading),
        String(this.listNavigationPending), String(this.hasError)
      )
    }
  }

  /**
   * 为快速回复和被截断的引用补全原楼层内容。
   *
   * @param posts - 需要处理的页面帖子
   * @param prevPosts - 替换前的帖子，用于查找跨页引用
   */
  private processPostsQuoteInjection(posts: PostInfo[], prevPosts?: PostInfo[]): void {
    const origByPid: Map<number, string> = new Map()
    /** 收集楼层与贴条的原始正文。 */
    const collectToMap = (arr: PostInfo[]): void => {
      for (const p of arr) {
        origByPid.set(p.pid, p.content)
        if (p.comments) {
          for (const c of p.comments) {
            origByPid.set(c.pid, c.content)
          }
        }
      }
    }
    collectToMap(posts)
    collectToMap(this.mgr.posts)
    if (prevPosts) {
      collectToMap(prevPosts)
    }
    /** 为快速回复格式注入被引用楼层的正文。 */
    const injectReplyQuote = (target: PostInfo): void => {
      if (target.content.startsWith('[quote]')) return
      const headerRegex: RegExp = /\[b\]Reply to \[pid=(\d+),(\d+),(\d+)\]Reply\[\/pid\] Post by \[uid=(\d+)\](.*?)\[\/uid\] \(([^)]+)\)/i
      const headerMatch: RegExpMatchArray | null = target.content.match(headerRegex)
      if (!headerMatch) return
      const refPid: number = parseInt(headerMatch[1], 10)
      const rawContent: string | undefined = origByPid.get(refPid)
      if (!rawContent) return
      let cleaned: string = rawContent
        .replace(/\[b\]Reply to \[pid=.*?\[\/pid\]\s*\[\/b\]/s, '')
        .replace(/\[pid=.*?Reply\[\/pid\]\s*\[b\]Post by.*?\(.*?\):\[\/b\]/s, '')
        .replace(/\[quote\]/g, '')
        .replace(/\[\/quote\]/g, '')
        .replace(/<br\s*\/?>/gi, '')
        .trim()
      if (cleaned.length === 0) return
      const closeBIdx: number = target.content.indexOf('[/b]')
      const replyText: string = closeBIdx >= 0 ? target.content.substring(closeBIdx + 4) : ''
      target.content = `[quote][pid=${headerMatch[1]},${headerMatch[2]},${headerMatch[3]}]Reply[/pid] [b]Post by [uid=${headerMatch[4]}]${headerMatch[5]}[/uid] (${headerMatch[6]}):[/b]\n${cleaned}[/quote]\n<br/><br/>${replyText}`
    }
    /** 用已加载的完整原文修复服务端截断的引用正文。 */
    const fixTruncatedQuote = (target: PostInfo): void => {
      if (!target.content.startsWith('[quote]')) return
      const pidInQuote: RegExpMatchArray | null = target.content.match(/\[pid=(\d+),(\d+),(\d+)\]/)
      if (!pidInQuote) return
      const refPid: number = parseInt(pidInQuote[1], 10)
      const fullContent: string | undefined = origByPid.get(refPid)
      if (!fullContent) return
      const afterQuote: number = target.content.indexOf('[quote]') + 7
      const headerEnd: number = target.content.indexOf('[/b]', afterQuote)
      const quoteEnd: number = target.content.indexOf('[/quote]', afterQuote)
      if (headerEnd < 0 || quoteEnd < 0) return
      const existingBody: string = target.content.substring(headerEnd + 4, quoteEnd)
        .replace(/<br\s*\/?>/gi, '').trim()
      let cleanedFull: string = fullContent
        .replace(/\[b\]Reply to \[pid=.*?\[\/pid\]\s*\[\/b\]/s, '')
        .replace(/\[pid=.*?Reply\[\/pid\]\s*\[b\]Post by.*?\(.*?\):\[\/b\]/s, '')
        .replace(/\[quote\]/g, '').replace(/\[\/quote\]/g, '')
        .replace(/<br\s*\/?>/gi, '')
        .trim()
      if (cleanedFull.length === 0) return
      if (existingBody === cleanedFull) return
      if (!cleanedFull.startsWith(existingBody)) return
      target.content = target.content.substring(0, headerEnd + 4) + '\n' + cleanedFull + target.content.substring(quoteEnd)
    }
    for (const p of posts) {
      injectReplyQuote(p)
      fixTruncatedQuote(p)
      if (p.comments) {
        for (const c of p.comments) {
          injectReplyQuote(c)
          fixTruncatedQuote(c)
        }
      }
    }
  }

  /**
   * 启动当前连续窗口两侧的按页预取。
   */
  private triggerPrefetches(): void {
    if (appStore.settings.threadNavMode === ThreadNavMode.PAGE) return
    if (appStore.settings.prefetchPageCount <= 0) return
    this.prefetchAroundWindow()
  }

  /**
   * 并行预取连续窗口两侧的页面。
   *
   * 预取可以乱序完成，但结果只进入按页缓存；可见列表只能由紧邻窗口边界的页面扩展，
   * 因而不会出现前向或后向缺页。
   */
  private async prefetchAroundWindow(): Promise<void> {
    const generation: number = this.mgr.getGeneration()
    const prefetchCount: number = appStore.settings.prefetchPageCount
    const firstPage: number = Math.max(this.mgr.loadedPageStart - prefetchCount, 1)
    const lastPage: number = Math.min(this.mgr.loadedPageEnd + prefetchCount, this.mgr.totalPages)
    const pagesToFetch: number[] = []
    for (let page: number = firstPage; page <= lastPage; page++) {
      const inFlightGeneration: number | undefined = this.prefetchGenerationByPage.get(page)
      if (this.mgr.isPageLoaded(page) || this.mgr.hasPrefetchedPage(page) || inFlightGeneration === generation) {
        continue
      }
      this.prefetchGenerationByPage.set(page, generation)
      pagesToFetch.push(page)
    }
    if (pagesToFetch.length === 0) return
    if (logger.isVerbose()) {
      logger.verbose(
        'prefetch start tid=%{public}s gen=%{public}d window=%{public}d-%{public}d range=%{public}d-%{public}d count=%{public}d',
        this.threadTid, generation, this.mgr.loadedPageStart, this.mgr.loadedPageEnd,
        firstPage, lastPage, pagesToFetch.length
      )
    }

    try {
      const requests: Promise<FetchPageResult | null>[] = []
      for (let i: number = 0; i < pagesToFetch.length; i++) {
        const page: number = pagesToFetch[i]
        requests.push(this.fetchPostsPage(page, '', 10000, taskpool.Priority.MEDIUM)
          .then((result: ThreadResult): FetchPageResult => {
            const pageResult: FetchPageResult = new FetchPageResult()
            pageResult.page = page
            pageResult.result = result
            return pageResult
          })
          .catch((): null => null))
      }
      const results: (FetchPageResult | null)[] = await Promise.all(requests)
      if (generation !== this.mgr.getGeneration()) return
      for (let i: number = 0; i < results.length; i++) {
        const pageResult: FetchPageResult | null = results[i]
        if (pageResult === null || pageResult.result === null || !pageResult.result.ok) {
          continue
        }
        const resolvedPage: number = pageResult.result.pagination.page > 0
          ? pageResult.result.pagination.page
          : pageResult.page
        if (!this.mgr.isPageLoaded(resolvedPage)) {
          this.mgr.setPrefetchedPage(
            resolvedPage,
            pageResult.result.posts,
            pageResult.result.pagination.totalPages
          )
        }
      }
    } finally {
      for (let i: number = 0; i < pagesToFetch.length; i++) {
        const page: number = pagesToFetch[i]
        if (this.prefetchGenerationByPage.get(page) === generation) {
          this.prefetchGenerationByPage.delete(page)
        }
      }
      if (generation === this.mgr.getGeneration()) {
        if (logger.isVerbose()) {
          logger.verbose(
            'prefetch end tid=%{public}s gen=%{public}d window=%{public}d-%{public}d',
            this.threadTid, generation, this.mgr.loadedPageStart, this.mgr.loadedPageEnd
          )
        }
        this.reconcile()
      }
    }
  }

  /**
   * 在接近窗口末尾时提交或请求紧邻的下一页。
   */
  private tryLoadNext(): void {
    if (appStore.settings.threadNavMode === ThreadNavMode.PAGE) return
    if (this.isLoadingMore || !this.mgr.hasNextPage()) return
    const generation: number = this.mgr.getGeneration()
    const nextPage: number = this.mgr.getNextPage()
    logger.info(
      'page-edge next tid=%{public}s page=%{public}d source=%{public}s gen=%{public}d ' +
        'window=%{public}d-%{public}d visible=%{public}d-%{public}d',
      this.threadTid, nextPage, this.mgr.hasPrefetchedPage(nextPage) ? 'cache' : 'network',
      generation, this.mgr.loadedPageStart, this.mgr.loadedPageEnd,
      this.lastScrollStart, this.lastScrollEnd
    )
    if (this.mgr.hasPrefetchedPage(nextPage)) {
      this.isLoadingMore = true
      const previousEnd: number = this.mgr.loadedPageEnd
      const added: PostInfo[] = this.mgr.commitPrefetchedNextPage()
      if (added.length > 0) {
        this.postsDataSource.appendAll(added)
      }
      this.isLoadingMore = false
      this.triggerPrefetches()
      if (this.mgr.loadedPageEnd !== previousEnd) {
        this.scheduleReconcile(generation)
      }
      return
    }
    this.loadPosts(nextPage, ThreadLoadMode.APPEND)
  }

  /**
   * 在接近窗口开头时提交或请求紧邻的上一页。
   *
   * 视口锚点完全交给 List.maintainVisibleContentPosition，避免额外滚动造成二次位移。
   */
  private tryLoadPrev(): void {
    if (appStore.settings.threadNavMode === ThreadNavMode.PAGE) return
    if (this.isLoadingPrevious || !this.mgr.hasPreviousPage()) return
    const generation: number = this.mgr.getGeneration()
    const previousPage: number = this.mgr.getPreviousPage()
    logger.info(
      'page-edge previous tid=%{public}s page=%{public}d source=%{public}s gen=%{public}d ' +
        'window=%{public}d-%{public}d visible=%{public}d-%{public}d',
      this.threadTid, previousPage, this.mgr.hasPrefetchedPage(previousPage) ? 'cache' : 'network',
      generation, this.mgr.loadedPageStart, this.mgr.loadedPageEnd,
      this.lastScrollStart, this.lastScrollEnd
    )
    if (this.mgr.hasPrefetchedPage(previousPage)) {
      this.isLoadingPrevious = true
      const previousStart: number = this.mgr.loadedPageStart
      const anchorPrepared: boolean = this.preparePrependAnchor(previousPage)
      const added: PostInfo[] = this.mgr.commitPrefetchedPreviousPage()
      if (added.length > 0) {
        this.postsDataSource.prependAll(added)
        if (anchorPrepared) {
          this.schedulePrependAnchorRestore()
        }
      } else if (anchorPrepared) {
        this.cancelPrependAnchor('no-inserted-posts')
      }
      this.isLoadingPrevious = false
      this.triggerPrefetches()
      if (this.mgr.loadedPageStart !== previousStart) {
        this.scheduleReconcile(generation)
      }
      return
    }
    this.loadPosts(previousPage, ThreadLoadMode.PREPEND)
  }

  private async handleReplySend(text: string, isAnony: boolean): Promise<void> {
    try {
      const result: PostReplyResult = await replyManager.send(text, isAnony)
      if (result.ok) {
        const isComment: boolean = replyManager.type === ReplyType.COMMENT
        appStore.showToast(isComment ? '贴条成功' : '回复成功')
        if (this.mgr.loadedPageEnd >= this.mgr.totalPages) {
          this.pendingTargetPid = ''
          this.singlePostFallback = false
          await this.loadPosts(1, ThreadLoadMode.REPLACE)
        }
      } else {
        appStore.showToast(result.error || '操作失败')
      }
    } catch (e) {
      appStore.showToast((e as Error).message || '操作失败')
    }
  }

  private async handleEditSend(text: string, isAnony: boolean): Promise<void> {
    try {
      const result: PostReplyResult = await replyManager.send(text, isAnony)
      if (result.ok) {
        appStore.showToast('编辑成功')
        this.pendingTargetPid = ''
        this.singlePostFallback = false
        await this.loadPosts(1, ThreadLoadMode.REPLACE)
      } else {
        appStore.showToast(result.error || '编辑失败')
      }
    } catch (e) {
      appStore.showToast((e as Error).message || '编辑失败')
    }
  }

  /**
   * 打开当前主题的收藏夹多选页面。
   */
  private openFavoriteFolders(): void {
    if (this.threadTid.length === 0) {
      return
    }
    this.showMoreMenu = false
    routerStore.navigateActivity(Screen.favoriteFolders(this.threadTid))
  }

  private async handleVote(post: PostInfo, value: number): Promise<void> {
    if (!appStore.auth.isAuthenticated) {
      appStore.showToast('请先登录')
      return
    }
    const pidKey: string = String(post.pid)
    const wasUp: boolean = this.votedUpPids.has(pidKey)
    const wasDown: boolean = this.votedDownPids.has(pidKey)
    const result: VoteResult = await votePost(appStore.auth.token, Number(this.threadTid), post.pid, value)
    if (result.ok) {
      const upPids = new Set(this.votedUpPids)
      const downPids = new Set(this.votedDownPids)
      if (result.message.indexOf('取消了对这个帖子的支持') >= 0) {
        upPids.delete(pidKey)
      } else if (result.message.indexOf('取消了对这个帖子的反对') >= 0) {
        downPids.delete(pidKey)
      } else if (result.message.indexOf('表示支持') >= 0) {
        upPids.add(pidKey)
        downPids.delete(pidKey)
      } else if (result.message.indexOf('表示反对') >= 0) {
        downPids.add(pidKey)
        upPids.delete(pidKey)
      }
      this.votedUpPids = upPids
      this.votedDownPids = downPids
      appStore.saveVoteRecord(appStore.auth.uid, this.threadTid, upPids, downPids)
      const isUp: boolean = upPids.has(pidKey)
      const isDown: boolean = downPids.has(pidKey)
      const scoreDelta: number = (isUp ? 1 : 0) - (wasUp ? 1 : 0)
      const score2Delta: number = (isDown ? 1 : 0) - (wasDown ? 1 : 0)
      const voteIdx: number = this.mgr.updateVoteScore(post.pid, scoreDelta, score2Delta)
      if (voteIdx >= 0) {
        this.postsDataSource.updateAt(voteIdx, this.mgr.posts[voteIdx])
      }
      if (result.message.length > 0) {
        appStore.showToast(result.message)
      }
    } else {
      appStore.showToast(result.error || '操作失败')
    }
  }

  private openImageViewer(urls: string[], index: number): void {
    sharedOpenImageViewer(urls, index)
  }

  private handleLinkClick(href: string): void {
    // 同主题引用且目标楼层已在当前加载窗口：页内直接定位，
    // 避免整页重载与服务端单帖视图（最常见引用场景零网络请求）。
    if (href.startsWith('#/thread?')) {
      const query: string = href.substring(href.indexOf('?') + 1)
      let linkTid: string = ''
      let linkPid: string = ''
      const parts: string[] = query.split('&')
      for (let i: number = 0; i < parts.length; i++) {
        const kv: string[] = parts[i].split('=')
        if (kv.length === 2) {
          if (kv[0] === 'tid') linkTid = kv[1]
          if (kv[0] === 'pid') linkPid = kv[1]
        }
      }
      if (linkTid === this.threadTid && linkPid.length > 0 && this.listMounted &&
        !this.listNavigationPending && !this.prependAnchorPending) {
        const linkPidNumber: number = parseInt(linkPid, 10)
        if (this.mgr.findPostIndex(linkPidNumber) >= 0) {
          logger.info(
            'quote-jump local tid=%{public}s pid=%{public}s gen=%{public}d window=%{public}d-%{public}d',
            this.threadTid, linkPid, this.mgr.getGeneration(),
            this.mgr.loadedPageStart, this.mgr.loadedPageEnd
          )
          this.scrollToPid(linkPid)
          return
        }
      }
    }
    handleForumLink(href, this.getUIContext().getHostContext() as common.UIAbilityContext, (uid: string) => {
      this.showProfileCard(uid, 200, 200)
    })
  }

  build() {
    Stack() {
      Column() {

      if (this.isLoading) {
        Column() {
          Column() {
            LoadingStateView()
          }.opacity(this.loadingContentOpacity)
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .padding({ top: NAV_BAR_H + this.statusBarHeight })
        .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
      } else if (this.hasError) {
        Column() {
          ErrorStateView({
            msg: this.errorMsg,
            onRetry: (): Promise<void> => this.loadPosts(this.lastReplacePage, ThreadLoadMode.REPLACE)
          })
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .padding({ top: NAV_BAR_H + this.statusBarHeight })
        .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
      } else {
        List({ scroller: this.scroller }) {
          LazyForEach(this.postsDataSource, (post: PostInfo) => {
            ListItem() {
              PostItem({
                post: post,
                isVotedUp: this.votedUpPids.has(String(post.pid)),
                isVotedDown: this.votedDownPids.has(String(post.pid)),
                holdingHand: this.holdingStatus,
                onImageClick: (urls: string[], index: number): void => {
                  this.openImageViewer(urls, index)
                },
                onLinkClick: (href: string): void => {
                  this.handleLinkClick(href)
                },
                onVideoClick: (url: string): void => {
                  this.handleLinkClick(url)
                },
                onProfileClick: (uid: string, screenX: number, screenY: number): void => {
                  this.showProfileCard(uid, screenX, screenY)
                },
                onVote: (p: PostInfo, value: number): void => {
                  this.handleVote(p, value)
                },
                onReply: (p: PostInfo): void => {
                  replyManager.startFloorReply(p, Number(this.threadTid), this.threadFid, this.displayPage)
                  floatingLayerStore.replyDialogTitle = replyManager.dialogTitle
                  floatingLayerStore.replyOnSend = (text: string, isAnony: boolean): Promise<void> => {
                    return this.handleReplySend(text, isAnony)
                  }
                  floatingLayerStore.editMode = false
                  floatingLayerStore.push(FloatingPage.REPLY_DIALOG)
                },
                onEdit: (p: PostInfo): void => {
                  replyManager.startEdit(p, Number(this.threadTid), this.threadFid)
                  floatingLayerStore.replyDialogTitle = replyManager.dialogTitle
                  floatingLayerStore.editMode = true
                  floatingLayerStore.editInitialContent = unescapeHtml(p.content).replace(/<br\s*\/?>/gi, '\n')
                  floatingLayerStore.replyOnSend = (_text: string, _isAnony: boolean): Promise<void> => {
                    return this.handleEditSend(_text, _isAnony)
                  }
                  floatingLayerStore.push(FloatingPage.REPLY_DIALOG)
                },
                onShare: (p: PostInfo): void => {
                  let hostCtx: Context | undefined = this.getUIContext().getHostContext()
                  if (hostCtx !== undefined) {
                    let ctx: Context = hostCtx
                    sharePost(ctx, p, this.threadSubject)
                  }
                },
                onSummarize: (p: PostInfo): void => {
                  const aiValidationMessage: string = getActiveAiValidationMessage()
                  if (aiValidationMessage.length > 0) {
                    appStore.showToast(aiValidationMessage)
                    return
                  }
                  const plainText: string = bbNodesToPlainText(getCachedBBNodes(p.content))
                  if (plainText.trim().length === 0) {
                    appStore.showToast('该楼层没有可总结的内容')
                    return
                  }
                  let prompt: string = ''
                  prompt += '【帖子信息】\n'
                  prompt += '标题：' + this.threadSubject + '\n'
                  prompt += '楼层：#' + p.lou.toString() + '  作者：' + p.author + '\n\n'
                  prompt += '【正文内容】\n'
                  prompt += plainText
                  TtsPlayer.stop()
                  this.getUIContext().getRouter().pushUrl({
                    url: 'pages/ai/AiChatPage',
                    params: {
                      initialPrompt: prompt,
                      title: 'AI 帖子总结',
                      scenario: 'post_summary'
                    }
                  })
                },
                onReadAloud: (p: PostInfo): void => {
                  const plainText: string = bbNodesToPlainText(getCachedBBNodes(p.content))
                  if (plainText.trim().length === 0) {
                    appStore.showToast('该楼层没有可朗读的内容')
                    return
                  }
                  const floorName: string = p.lou === 0 ? '楼主' : '第' + p.lou.toString() + '楼'
                  const metadata: TtsMediaMetadata = {
                    assetId: 'thread-' + this.threadTid + '-post-' + p.pid.toString(),
                    title: this.threadSubject.trim().length > 0 ? this.threadSubject : '帖子朗读',
                    artist: p.author,
                    album: floorName
                  }
                  TtsPlayer.speak(plainText, p.pid, true, metadata)
                },
                isTopicAuthor: String(post.authorid) === this.threadAuthorId,
                isOwnPost: appStore.auth.isAuthenticated && String(post.authorid) === appStore.auth.uid,
              })
            }
          }, (post: PostInfo) => String(post.pid))
          ListItem() {
            Column() {
              Row() {
                if (this.isLoadingMore) {
                  LoadingProgress().width(16).height(16).color(AppColors.textTertiary)
                  Text('加载更多...').fontSize(13).fontColor(AppColors.textTertiary).margin({ left: 8 })
                } else if (this.mgr.loadedPageEnd >= this.mgr.totalPages && this.mgr.posts.length > 0) {
                  Text('已加载全部回复').fontSize(13).fontColor(AppColors.textTertiary)
                }
              }.width('100%').justifyContent(FlexAlign.Center)
            }.width('100%').height(NAV_BAR_H).justifyContent(FlexAlign.Center)
          }
        }
        .width('100%').layoutWeight(1)
        .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
        .scrollBar(BarState.Off)
        .divider({ strokeWidth: 0.5, color: AppColors.separator })
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(6)
        .maintainVisibleContentPosition(true)
        .linearGradientBlur(
          TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),
          {
            fractionStops: this.getTitleBlurStops(),
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
          this.listMounted = true
          this.syncTitleScrollEffect()
          logger.info(
            'list lifecycle appear tid=%{public}s gen=%{public}d window=%{public}d-%{public}d posts=%{public}d ' +
              'navPending=%{public}s anchorPending=%{public}s',
            this.threadTid, this.mgr.getGeneration(), this.mgr.loadedPageStart, this.mgr.loadedPageEnd,
            this.mgr.posts.length, String(this.listNavigationPending), String(this.prependAnchorPending)
          )
          this.scheduleListNavigation()
          this.schedulePrependAnchorRestore()
        })
        .onDisAppear((): void => {
          this.listMounted = false
          logger.info(
            'list lifecycle disappear tid=%{public}s gen=%{public}d loading=%{public}s error=%{public}s ' +
              'navPending=%{public}s anchorPending=%{public}s',
            this.threadTid, this.mgr.getGeneration(), String(this.isLoading), String(this.hasError),
            String(this.listNavigationPending), String(this.prependAnchorPending)
          )
        })
        .onScrollIndex((start: number, end: number, center: number): void => {
          if (this.prependAnchorPending) {
            if (logger.isVerbose()) {
              logger.verbose(
                'scroll-index ignored prepend-anchor tid=%{public}s gen=%{public}d start=%{public}d ' +
                  'end=%{public}d center=%{public}d anchorPid=%{public}d',
                this.threadTid, this.mgr.getGeneration(), start, end, center, this.prependAnchorPid
              )
            }
            return
          }
          this.lastScrollStart = start
          this.lastScrollEnd = end
          this.displayPage = this.mgr.getDisplayPage(center)
          if (logger.isVerbose()) {
            logger.verbose(
              'scroll-index tid=%{public}s gen=%{public}d start=%{public}d end=%{public}d center=%{public}d ' +
                'display=%{public}d window=%{public}d-%{public}d posts=%{public}d navPending=%{public}s',
              this.threadTid, this.mgr.getGeneration(), start, end, center, this.displayPage,
              this.mgr.loadedPageStart, this.mgr.loadedPageEnd, this.mgr.posts.length,
              String(this.listNavigationPending)
            )
          }
          this.reconcile()
        })
        .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
      }
    }
    .width('100%').height('100%')

      PanelNavBar({
        title: this.getVisibleThreadSubject(),
        rightIcon: $r('app.media.icon_more'),
        scrollEffectProgress: this.titleScrollEffectProgress,
        onRightClick: (): void => {
          this.showMoreMenu = !this.showMoreMenu
        }
      })
        .width('100%').position({ x: 0, y: 0 })

      Row() {
        if (this.mgr.totalPages > 1) {
          Row() {
            if (this.mgr.totalPages === 2) {
              Stack() {
                Text('1').fontSize(14)
                  .fontColor(this.displayPage === 1
                    ? UIMaterialManager.adaptiveForeground : UIMaterialManager.adaptiveSecondaryForeground)
                  .fontWeight(this.displayPage === 1 ? FontWeight.Bold : FontWeight.Regular)
                if (this.displayPage === 1) {
                  Text('•').fontSize(10).fontColor(UIMaterialManager.adaptiveForeground)
                    .position({ x: '50%', y: 22 }).translate({ x: '-50%' })
                }
              }.width(24).height(28)
                .onClick(() => this.navigateToPage(1, PageNavigationSource.PAGER_BUTTON))
              Divider().vertical(true).height(16).color(AppColors.dividerStrong)
              Stack() {
                Text('2').fontSize(14)
                  .fontColor(this.displayPage === 2
                    ? UIMaterialManager.adaptiveForeground : UIMaterialManager.adaptiveSecondaryForeground)
                  .fontWeight(this.displayPage === 2 ? FontWeight.Bold : FontWeight.Regular)
                if (this.displayPage === 2) {
                  Text('•').fontSize(10).fontColor(UIMaterialManager.adaptiveForeground)
                    .position({ x: '50%', y: 22 }).translate({ x: '-50%' })
                }
              }.width(24).height(28)
                .onClick(() => this.navigateToPage(2, PageNavigationSource.PAGER_BUTTON))
            } else if (this.displayPage === 1) {
              Stack() {
                Text('1').fontSize(14).fontColor(UIMaterialManager.adaptiveForeground).fontWeight(FontWeight.Bold)
                Text('•').fontSize(10).fontColor(UIMaterialManager.adaptiveForeground)
                  .position({ x: '50%', y: 22 }).translate({ x: '-50%' })
              }.width(24).height(28)
                .onClick(() => this.navigateToPage(1, PageNavigationSource.PAGER_BUTTON))
              Divider().vertical(true).height(16).color(AppColors.dividerStrong)
              Stack() {
                Text('2').fontSize(14).fontColor(UIMaterialManager.adaptiveSecondaryForeground).fontWeight(FontWeight.Regular)
              }.width(24).height(28)
                .onClick(() => this.navigateToPage(2, PageNavigationSource.PAGER_BUTTON))
            } else if (this.displayPage === this.mgr.totalPages) {
              Stack() {
                Text(String(this.mgr.totalPages - 1)).fontSize(14)
                  .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
                  .fontWeight(FontWeight.Regular)
              }.width(24).height(28)
                .onClick(() => this.navigateToPage(
                  this.mgr.totalPages - 1, PageNavigationSource.PAGER_BUTTON
                ))
              Divider().vertical(true).height(16).color(AppColors.dividerStrong)
              Stack() {
                Text(String(this.mgr.totalPages)).fontSize(14).fontColor(UIMaterialManager.adaptiveForeground)
                  .fontWeight(FontWeight.Bold)
                Text('•').fontSize(10).fontColor(UIMaterialManager.adaptiveForeground)
                  .position({ x: '50%', y: 22 }).translate({ x: '-50%' })
              }.width(24).height(28)
                .onClick(() => this.navigateToPage(this.mgr.totalPages, PageNavigationSource.PAGER_BUTTON))
            } else {
              Stack() {
                Text(String(this.displayPage - 1)).fontSize(14)
                  .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
                  .fontWeight(FontWeight.Regular)
              }.width(24).height(28)
                .onClick(() => this.navigateToPage(this.displayPage - 1, PageNavigationSource.PAGER_BUTTON))
              Divider().vertical(true).height(16).color(AppColors.dividerStrong)
              Stack() {
                Text(String(this.displayPage)).fontSize(14).fontColor(UIMaterialManager.adaptiveForeground)
                  .fontWeight(FontWeight.Bold)
                Text('•').fontSize(10).fontColor(UIMaterialManager.adaptiveForeground)
                  .position({ x: '50%', y: 22 }).translate({ x: '-50%' })
              }.width(24).height(28)
                .onClick(() => this.navigateToPage(this.displayPage, PageNavigationSource.PAGER_BUTTON))
              Divider().vertical(true).height(16).color(AppColors.dividerStrong)
              Stack() {
                Text(String(this.displayPage + 1)).fontSize(14)
                  .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
                  .fontWeight(FontWeight.Regular)
              }.width(24).height(28)
                .onClick(() => this.navigateToPage(this.displayPage + 1, PageNavigationSource.PAGER_BUTTON))
            }
            if (this.mgr.totalPages > 2) {
              Divider().vertical(true).height(16).color(AppColors.dividerStrong)
              Text('到').fontSize(13).fontColor(UIMaterialManager.adaptiveForeground)
                .padding({ left: 4, right: 2 })
                .onClick(() => {
                  this.pagePickerCurrentPage = this.displayPage
                  this.pagePickerTotalPages = this.mgr.totalPages
                  this.pagePickerOnSelect = (page: number): void => {
                    if (page !== this.displayPage) {
                      this.navigateToPage(page, PageNavigationSource.PAGE_PICKER)
                    }
                  }
                  this.showPagePicker = true
                })
            }
          }
          .padding({ left: 8, right: 8, top: 0, bottom: 0 })
          .height(40).alignItems(VerticalAlign.Center)
          .backgroundColor(Color.Transparent).borderRadius(20)
          .shadow({ radius: 16, color: AppColors.shadow, offsetY: 4 })
          .systemMaterial(UIMaterialManager.fabMaterial)
          .margin({ right: 8 })
        }

        Stack() {
          Image($r('app.media.icon_reply'))
            .width(20).height(20).fillColor(UIMaterialManager.adaptiveForeground)
        }
        .width(40).height(40).borderRadius(20)
        .backgroundColor(Color.Transparent)
        .shadow({ radius: 16, color: AppColors.shadow, offsetY: 4 })
        .systemMaterial(UIMaterialManager.fabMaterial)
        .onClick(() => {
          replyManager.startThreadReply(Number(this.threadTid), this.threadFid)
          floatingLayerStore.replyDialogTitle = replyManager.dialogTitle
          floatingLayerStore.editMode = false
          floatingLayerStore.replyOnSend = (text: string, isAnony: boolean): Promise<void> => {
            return this.handleReplySend(text, isAnony)
          }
          floatingLayerStore.push(FloatingPage.REPLY_DIALOG)
        })
      }
      .width('100%').padding({ left: 16, right: 16, bottom: 16 + this.navBarHeight }).alignItems(VerticalAlign.Center)
      .justifyContent(this.holdingStatus === HoldingHandStatus.LEFT_HAND_HELD ? FlexAlign.Start : FlexAlign.End)

      if (this.showMoreMenu) {
        Stack() {
          Column() {}.width('100%').height('100%').onClick(() => { this.showMoreMenu = false })

          Column() {
            Column() {
              Text(this.getFavoriteMenuLabel()).fontSize(15)
                .fontColor(AppColors.textPrimary)
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .width('100%')
                .onClick(() => {
                  this.openFavoriteFolders()
                })
            }
            .width('100%')

            Divider().width('100%').color(AppColors.separator)

            Column() {
              Text('只看楼主').fontSize(15)
                .fontColor(this.authorOnly ? AppColors.primary : AppColors.textPrimary)
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .width('100%')
                .onClick(() => {
                  this.authorOnly = !this.authorOnly
                  this.showMoreMenu = false
                  this.pendingTargetPid = ''
                  this.singlePostFallback = false
                  this.loadPosts(1, ThreadLoadMode.REPLACE)
                })
            }
            .width('100%')

            Divider().width('100%').color(AppColors.separator)

            Column() {
              Text('从网页打开').fontSize(15)
                .fontColor(AppColors.textPrimary)
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .width('100%')
                .onClick(() => {
                  this.showMoreMenu = false
                  const baseUrl: string = getActiveDomain()
                  const threadUrl: string = baseUrl + '/read.php?tid=' + this.threadTid
                  routerStore.navigateActivity(Screen.webview(threadUrl))
                })
            }
            .width('100%')

            Divider().width('100%').color(AppColors.separator)

            Column() {
              Text('分享帖子').fontSize(15)
                .fontColor(AppColors.textPrimary)
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .width('100%')
                .onClick(() => {
                  this.showMoreMenu = false
                  let hostCtx: Context | undefined = this.getUIContext().getHostContext()
                  if (hostCtx !== undefined) {
                    let ctx: Context = hostCtx
                    shareThread(ctx, Number(this.threadTid), this.threadSubject)
                  }
                })
            }
            .width('100%')
          }
          .width(150)
          .backgroundColor(Color.Transparent)
          .borderRadius(10)
          .shadow({ radius: 16, color: AppColors.shadowLight, offsetY: 4 })
          .systemMaterial(UIMaterialManager.surfaceMaterial)
          .position({ top: this.statusBarHeight + NAV_BAR_H + 6, right: 16 })
        }
        .width('100%').height('100%')
        .transition(TransitionEffect.OPACITY.animation({ duration: 150 }))
      }

      if (this.showPagePicker) {
        Stack() {
          Column().width('100%').height('100%').onClick(() => { this.showPagePicker = false })
          Column() {
            Text('选择页面').fontSize(14).fontColor(AppColors.textPrimary).fontWeight(FontWeight.Bold)
              .padding({ top: 12, bottom: 8 }).width('100%').textAlign(TextAlign.Center)
            Divider().color(AppColors.separator)
            Scroll() {
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Start }) {
                ForEach(this.buildPageArray(), (p: number) => {
                  Text(String(p)).fontSize(15)
                    .fontColor(p === this.pagePickerCurrentPage ? AppColors.primary : AppColors.textPrimary)
                    .fontWeight(p === this.pagePickerCurrentPage ? FontWeight.Bold : FontWeight.Regular)
                    .width(40).height(40).textAlign(TextAlign.Center).borderRadius(20)
                    .border({
                      width: p === this.pagePickerCurrentPage ? 1.5 : 0,
                      color: AppColors.primary
                    })
                    .backgroundColor(Color.Transparent)
                    .onClick(() => {
                      if (this.pagePickerOnSelect) {
                        this.pagePickerOnSelect(p)
                      }
                      this.showPagePicker = false
                    })
                }, (p: number) => String(p))
              }.width('100%')
            }.width('100%').height(120).align(Alignment.TopStart)
          }
          .width(220).height(180).padding({ left: 10, right: 10 })
          .backgroundColor(Color.Transparent).borderRadius(12)
          .shadow({ radius: 16, color: AppColors.shadow, offsetY: 4 })
          .systemMaterial(UIMaterialManager.surfaceMaterial)
          .position(
            this.holdingStatus === HoldingHandStatus.LEFT_HAND_HELD
              ? { bottom: 64 + this.navBarHeight, left: 16 }
              : { bottom: 64 + this.navBarHeight, right: 16 }
          )
        }
        .width('100%').height('100%')
        .transition(TransitionEffect.OPACITY.animation({ duration: 150 }))
      }

    }
    .width('100%').height('100%').backgroundColor(AppColors.bg).alignContent(Alignment.BottomEnd)
    .id('threadPanelRoot')
  }
}
