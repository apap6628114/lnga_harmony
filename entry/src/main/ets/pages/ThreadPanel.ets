import { display, LengthMetrics } from '@kit.ArkUI'
import { common, Context } from '@kit.AbilityKit'
import { taskpool } from '@kit.ArkTS'

import { appStore } from '../store/AppStore'
import { routerStore, Screen, ThreadSource } from '../store/RouterStore'
import { getThread } from '../service/api/ThreadApi'
import { votePost } from '../service/api/FavoriteApi'
import { getActiveDomain } from '../service/api/MiscApi'
import type { ThreadResult, PostReplyResult } from '../model/ThreadResult'
import type { PostInfo } from '../model/PostInfo'
import { VoteResult } from '../model/NgaApiResults'
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
import { SaveThreadDialog } from '../common/dialogs/SaveThreadDialogs'
import { savedThreadService, SaveThreadOutcome, getSavedThreadResult } from '../service/SavedThreadService'
import { openImageViewer as sharedOpenImageViewer, handleForumLink } from '../common/utils/LinkUtils'
import { ThreadPaginationManager, MergePageResult } from '../common/managers/ThreadPaginationManager'
import type { ThreadInfo } from '../model/Thread'
import { Logger, DOMAIN_UI, formatError } from '../common/utils/Logger'
import { getActiveAiValidationMessage } from '../service/ai/ActiveAiService'
import { applyBlacklistStateToPosts } from '../common/utils/BlacklistUtils'
import { injectQuoteContent } from '../common/utils/QuoteInjection'
import { HoldingHandMonitor, HoldingHandStatus } from '../common/managers/HoldingHandMonitor'
import { UIMaterialManager } from '../common/managers/UIMaterialManager'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'
import {
  PAGE_PICKER_ELLIPSIS,
  PAGE_PICKER_MAX_DIRECT,
  buildPageArray,
  parsePageInput
} from '../common/utils/PagePicker'
import { ReadingProgressEntry } from '../store/ReadingProgressStore'

const logger = new Logger(DOMAIN_UI, 'ThreadPanel')

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
 * 编辑提交快照：记录编辑前后正文，供静默刷新区分「服务端确认的新内容」与
 * 「read.php/CDN 未失效的旧缓存」——旧缓存返回时跳过覆盖，防止乐观更新的
 * 新正文被回退成旧内容。
 */
class EditSnapshot {
  /** 被编辑楼层 pid。 */
  pid: number = 0

  /** 编辑前正文（服务端旧内容，用于识别未失效的缓存）。 */
  oldContent: string = ''

  /** 编辑后提交的正文（乐观更新写入的内容）。 */
  newContent: string = ''
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
  /** 打开帖子的路由来源（ThreadSource 枚举值），用于运行态诊断。 */
  @Prop threadSource: string = ''
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
  /** 保存帖子对话框控制器（更多菜单「保存帖子」入口）。 */
  private saveDialogController?: CustomDialogController
  private pagePickerTotalPages: number = 0
  private pagePickerCurrentPage: number = 0
  private pagePickerOnSelect: ((page: number) => void) | null = null
  /** 页码选择器输入框当前文本（仅页数多时显示，用于直达任意中间页）。 */
  private pagePickerInput: string = ''
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

  /**
   * onScrollIndex 最近上报的中心可见列表项下标。
   * 阅读进度记录以中心楼层为锚点：还原时对该 pid 居中定位（scrollToPid），
   * 记录与还原锚点同源对称，避免"记录视口顶部楼、还原时居中"导致锚点逐次上移。
   */
  private lastScrollCenter: number = 0

  /**
   * 阅读进度记录的延迟保存计时器。
   * 滚动过程中节流记录（滚动停顿后落盘），离开页面时立即补记一次。
   */
  private progressRecordTimer: number = -1

  /** 首次进入/切换帖子后是否仍在等待读取并恢复上次阅读进度。 */
  private readingResumePending: boolean = false

  /** 当前帖子的阅读进度恢复是否已经处理过（防止页面重新显示时重复恢复）。 */
  private readingResumeHandled: boolean = false

  /** 待用户确认的阅读进度：Toast「前往查看」点击后执行定位；切帖/销毁时失效。 */
  private pendingResumeEntry: ReadingProgressEntry | null = null

  /** 尚未交给帖子接口定位的路由目标楼层。 */
  private pendingTargetPid: string = ''

  /** 整页未命中目标 pid 后是否已发起单帖兜底请求，防止重复兜底。 */
  private singlePostFallback: boolean = false

  /**
   * 最近一次回复成功后静默刷新追加到窗口的新楼层 pid。
   * 「前往查看」优先于提交接口响应使用它——NGA 回复接口的响应不保证携带新楼层 pid，
   * 而刷新后追加到窗口末尾的最后一个帖子必然是新回复楼层。
   */
  private lastRepliedPid: string = ''

  /** 「前往查看」且无已知 pid 时，定位到服务端末页最后一个楼层。 */
  private pendingTargetLastPost: boolean = false

  /** 最近一次成功编辑的快照，用于防止静默刷新用旧缓存覆盖乐观更新正文。 */
  private lastEditSnapshot: EditSnapshot | null = null

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

  private holdingMonitor: HoldingHandMonitor = new HoldingHandMonitor()

  /**
   * 握持状态变化回调：首次检测直接生效，后续变化带 300ms 动画过渡，
   * 状态持久化由 {@link HoldingHandMonitor} 完成。
   *
   * @param data - 新的握持状态
   */
  private onHoldingChanged(data: HoldingHandStatus): void {
    if (this.holdingDetected) {
      this.getUIContext()?.animateTo({ duration: 300, curve: Curve.EaseInOut }, (): void => {
        this.holdingStatus = data
      })
    } else {
      this.holdingStatus = data
      this.holdingDetected = true
    }
  }

  private startHoldingHandMonitoring(): void {
    this.holdingMonitor.start((data: HoldingHandStatus): void => {
      this.onHoldingChanged(data)
    })
  }

  private stopHoldingHandMonitoring(): void {
    this.holdingMonitor.stop()
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
    logger.info(
      'thread open tid=%{public}s page=%{public}d pid=%{public}s source=%{public}s',
      this.threadTid, initialPage, this.threadPid, this.threadSource
    )
    if (this.threadTid) {
      this.loadPosts(initialPage, ThreadLoadMode.REPLACE)
    }
    this.syncFavoriteState()
    appStore.favoriteStore.ensureFolders()
    this.loadPersistedVotes()
    this.startHoldingHandMonitoring()
    this.tryRestoreReadingProgress()
  }

  aboutToDisappear(): void {
    // 先补记最终阅读位置（此时列表与滚动状态仍有效），再清理资源
    this.recordReadingProgress()
    clearTimeout(this.progressRecordTimer)
    this.progressRecordTimer = -1
    // 使在途的进度恢复读取失效：页面销毁后不得继续在已销毁组件上执行恢复定位
    this.readingResumePending = false
    // 使已弹出的「前往」恢复提示失效：Toast 回调晚于销毁触发时不得再定位
    this.pendingResumeEntry = null
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
    this.saveDialogController = undefined
  }

  private onThreadChanged(): void {
    if (!this.hasInitiallyLoaded) {
      this.hasInitiallyLoaded = true
      return
    }
    // 切换帖子前补记旧帖的最终阅读位置（此时 mgr.posts 仍是旧帖数据）
    this.recordReadingProgress()
    clearTimeout(this.progressRecordTimer)
    this.progressRecordTimer = -1
    this.readingResumeHandled = false
    this.readingResumePending = false
    // 切换帖子后旧帖的「前往」恢复提示失效，防止 Toast 回调定位到新帖
    this.pendingResumeEntry = null
    const initialPage: number = Math.max(this.threadPage, 1)
    this.pendingTargetPid = this.threadPid
    this.singlePostFallback = false
    this.fallbackPrevTotalPages = 0
    this.fallbackPrevPage = 0
    this.lastRepliedPid = ''
    this.pendingTargetLastPost = false
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
    this.tryRestoreReadingProgress()
  }

  // ============== 阅读进度记录与恢复 ==============

  /**
   * 阅读进度记录是否有效（开关开启、已登录、非单帖兜底视图且非离线存档模式）。
   *
   * 离线存档模式（ThreadSource.SAVED）不享受进度保存：本地快照与在线阅读
   * 位置语义不同，恢复/记录都会造成误导。
   *
   * @returns 是否可以记录
   */
  private shouldRecordProgress(): boolean {
    return appStore.settings.recordReadingProgress &&
      appStore.auth.uid.length > 0 &&
      !this.singlePostFallback &&
      !this.isSavedSource()
  }

  /**
   * 滚动过程中节流调度一次进度记录（停顿后落盘，避免高频写入）。
   */
  private scheduleProgressRecord(): void {
    if (!this.shouldRecordProgress()) return
    clearTimeout(this.progressRecordTimer)
    this.progressRecordTimer = setTimeout((): void => {
      this.progressRecordTimer = -1
      this.recordReadingProgress()
    }, 800)
  }

  /**
   * 记录当前阅读位置：锚点取视口中心楼层（与还原的居中定位同源对称），
   * 记录其页码与 pid（楼层级，不记录像素偏移）。
   *
   * tid 取锚点楼自身 tid：切换帖子（onThreadChanged）补记旧帖时，this.threadTid 已是新帖值，
   * 而 mgr.posts 仍是旧帖数据，必须用楼层 tid 才能记到旧帖名下；HTML 解析结果中的 __CURRENT_TID
   * 提取失败时楼层 tid 可能为 0，此时回退路由参数 this.threadTid 兜底。
   */
  private recordReadingProgress(): void {
    if (!this.shouldRecordProgress()) return
    const postCount: number = this.mgr.posts.length
    if (postCount <= 0 || this.mgr.totalPages <= 0) return
    const anchorIndex: number = Math.max(0, Math.min(this.lastScrollCenter, postCount - 1))
    const entry = new ReadingProgressEntry()
    const postTid: number = this.mgr.posts[anchorIndex].tid
    entry.tid = postTid > 0 ? String(postTid) : this.threadTid
    entry.page = this.mgr.getDisplayPage(anchorIndex)
    entry.pid = this.mgr.posts[anchorIndex].pid
    appStore.saveReadingProgress(appStore.auth.uid, entry)
  }

  /**
   * 首次进入当前帖子时尝试恢复上次阅读进度。
   *
   * 仅在"继续阅读"语义下生效，避免与来源自带的楼层定位概念冲突：
   * - 路由携带明确定位意图（目标 pid 或页码晚于第 1 页）时不恢复；
   * - 来源带楼层定位概念（通知 / 链接 / 搜索）时不恢复——这些来源的
   *   主楼哨兵 pid 会被 Screen.thread 归一为空串，仅靠路由参数无法识别，
   *   必须按来源白名单排除（如链接 pid 查找失败退化打开首页、通知主楼）。
   * 页面从 activity 栈重新显示不会重复恢复（readingResumeHandled 去重）。
   *
   * 恢复不静默定位：进度读取通过校验后仅弹「前往查看」Toast，由用户点击后
   * 经 goToResumedPosition 执行定位（与回复成功的「前往查看」同一交互模式）。
   */
  private tryRestoreReadingProgress(): void {
    if (this.readingResumeHandled || this.readingResumePending) return
    if (this.threadTid.length === 0) return
    if (!appStore.settings.recordReadingProgress || appStore.auth.uid.length === 0) return
    if (this.threadPid.length > 0 || this.threadPage > 1) return
    if (!this.isResumeAllowedSource()) return
    this.readingResumeHandled = true
    this.readingResumePending = true
    this.resumeReadingProgress()
  }

  /**
   * 是否允许恢复阅读进度：仅"继续阅读"语义的来源（主题列表、浏览历史、未标注默认入口）。
   *
   * @returns 来源是否允许恢复
   */
  private isResumeAllowedSource(): boolean {
    return this.threadSource === ThreadSource.DEFAULT ||
      this.threadSource === ThreadSource.TOPIC_LIST ||
      this.threadSource === ThreadSource.BROWSE_HISTORY
  }

  /**
   * 异步读取并校验阅读进度；读取期间可能已切换帖子或关闭开关，需逐一校验。
   */
  private async resumeReadingProgress(): Promise<void> {
    const uid: string = appStore.auth.uid
    const tid: string = this.threadTid
    const entry: ReadingProgressEntry | null = await appStore.getReadingProgress(uid, tid)
    if (!this.readingResumePending || tid !== this.threadTid) return
    // 读取期间账号可能已登出或切换：进度按账号隔离，身份不一致时丢弃，避免跨账号恢复
    if (appStore.auth.uid !== uid) return
    if (!appStore.settings.recordReadingProgress) return
    this.readingResumePending = false
    if (entry === null || entry.pid < 0 || entry.page < 1) return
    // 初始内容已提交且用户已经开始滚动阅读：不打断当前阅读
    if (this.mgr.posts.length > 0 && this.lastScrollStart > 0) return
    // 不静默定位：保存进度并弹 Toast，由用户点击「前往查看」后执行恢复定位。
    // 回调可能晚于面板销毁/切帖触发，由 goToResumedPosition 做一致性校验。
    this.pendingResumeEntry = entry
    appStore.showToastAction('检测到上次阅读进度', '前往查看', (): void => {
      this.goToResumedPosition()
    })
  }

  /**
   * 用户点击阅读进度 Toast 的「前往查看」后执行恢复定位。
   *
   * Toast 是全局组件（ToastManager），回调可能晚于面板销毁或帖子切换触发，
   * 因此入口必须重新校验：进度未被清空（未切帖/未销毁）、List 仍挂载、
   * 帖子/账号/开关仍与记录时一致，校验失败仅提示不定位。
   */
  private goToResumedPosition(): void {
    const entry: ReadingProgressEntry | null = this.pendingResumeEntry
    this.pendingResumeEntry = null
    if (entry === null) return
    if (!this.listMounted) {
      logger.warn(
        'progress-resume unmounted tid=%{public}s page=%{public}d pid=%{public}d',
        this.threadTid, entry.page, entry.pid
      )
      appStore.showToast('帖子页面已关闭')
      return
    }
    if (this.threadTid !== entry.tid) return
    if (!appStore.settings.recordReadingProgress || appStore.auth.uid.length === 0) return
    this.applyReadingResume(entry)
  }

  /**
   * 执行阅读进度恢复：锚点已在当前窗口时页内直接定位（楼层居中），
   * 否则按记录页码整页加载后经列表导航事务定位。
   *
   * 由 goToResumedPosition（用户点击 Toast「前往查看」）调用，不再静默触发。
   *
   * @param entry - 阅读进度条目
   */
  private applyReadingResume(entry: ReadingProgressEntry): void {
    logger.info(
      'progress resume tid=%{public}s page=%{public}d pid=%{public}d gen=%{public}d',
      this.threadTid, entry.page, entry.pid, this.mgr.getGeneration()
    )
    this.pendingTargetPid = String(entry.pid)
    this.singlePostFallback = false
    this.pendingTargetLastPost = false
    this.fallbackPrevTotalPages = 0
    this.fallbackPrevPage = 0
    // 锚点楼层已在当前窗口且 List 已挂载：直接页内定位，不重新请求。
    // 未挂载时 scrollToIndex 静默无效（THREAD_DESIGN §4.4），必须落入下方 REPLACE 事务
    if (this.listMounted && this.mgr.posts.length > 0 && this.mgr.findPostIndex(entry.pid) >= 0) {
      const positioned: boolean = this.scrollToPid(String(entry.pid))
      if (positioned) {
        appStore.showToast('已恢复上次阅读位置')
        return
      }
    }
    // 跨页恢复：REPLACE 会推进代际，使在途的初始加载请求作废，定位由列表导航事务完成
    this.loadPosts(entry.page, ThreadLoadMode.REPLACE)
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
    // 离线存档来源：标题前加 [离线] 前缀提醒（替代悬浮提示，不遮挡内容）
    if (this.isSavedSource()) {
      return '[离线] ' + this.threadSubject
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
    // 一并清除「前往查看」的末页末项定位意图，防止在途退化 REPLACE 被本次跳页误消费
    this.pendingTargetLastPost = false
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
   * 纯逻辑已下沉至 {@link buildPageArray}，本方法仅转发当前页选择器状态。
   *
   * @returns 页码与省略号哨兵组成的条目数组
   */
  private buildPageArray(): number[] {
    return buildPageArray(this.pagePickerTotalPages, this.pagePickerCurrentPage)
  }

  /**
   * 从页码选择器输入框读取页码并跳转。
   *
   * 仅在输入为 1..总页数 范围内的整数时生效，非法输入直接忽略。
   * 复用 {@link pagePickerOnSelect} 的回调（与点击页码按钮同一跳转入口）。
   */
  private jumpToPageByInput(): void {
    const raw: string = this.pagePickerInput.trim()
    if (raw.length === 0) {
      appStore.showToast('请输入页码')
      return
    }
    const parsed: number = parsePageInput(raw, this.pagePickerTotalPages)
    if (parsed < 0) {
      appStore.showToast('页码应在 1~' + this.pagePickerTotalPages + ' 之间')
      return
    }
    const target: number = parsed
    if (this.pagePickerOnSelect) {
      this.pagePickerOnSelect(target)
    }
    this.showPagePicker = false
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
    // 来源分流：保存的帖子离线存档从本地同形状 JSON 读取并解释，与在线走同一条渲染管线；
    // 其余来源保持服务器请求模式。
    const result: ThreadResult = this.threadSource === ThreadSource.SAVED
      ? await withTimeout<ThreadResult>(getSavedThreadResult(
        this.threadTid, targetPage,
        appStore.settingsStore.getBlacklistIds(), appStore.settingsStore.getEnabledKeywords(),
        noteMap, this.authorOnly ? this.threadAuthorId : ''
      ), timeoutMs)
      : await withTimeout<ThreadResult>(getThread(
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
      this.lastScrollCenter = 0
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
        this.pendingTargetLastPost = false
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
          if (this.pendingTargetLastPost && result.posts.length > 0) {
            // 无已知 pid 的「前往查看」：定位到服务端末页最后一个楼层（通常即刚回复的楼层）
            this.pendingTargetPid = String(result.posts[result.posts.length - 1].pid)
          }
          this.pendingTargetLastPost = false
          this.mgr.replaceWith(result.posts, resolvedPage, result.pagination.totalPages)
          if (this.singlePostFallback && this.fallbackPrevTotalPages > 0) {
            // 单帖视图把 totalPages 重置为 1：恢复兜底前整页窗口的真实总页数，
            // 否则分页器消失且 hasNextPage 恒假，用户被困在单帖窗口无法扩展
            this.mgr.totalPages = this.fallbackPrevTotalPages
          }
          this.postsDataSource.replaceAll(result.posts)
          this.displayPage = resolvedPage
          // 离线存档模式不写入浏览历史：历史条目后续会以在线通道打开，
          // 对已删除的存档帖子会形成永远加载失败的死链
          if (appStore.auth.isAuthenticated && !this.isSavedSource()) {
            appStore.addBrowseHistoryFromThread(appStore.auth.uid, result, this.threadTid)
          }
          this.prepareListNavigation(generation, resolvedPage, this.pendingTargetPid)
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
          this.pendingTargetLastPost = false
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
        this.pendingTargetLastPost = false
        return
      }
      if (mode === ThreadLoadMode.REPLACE) {
        this.pendingTargetLastPost = false
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
   * 纯逻辑已下沉至 {@link injectQuoteContent}，本方法仅转发当前窗口数据。
   *
   * @param posts - 需要处理的页面帖子
   * @param prevPosts - 替换前的帖子，用于查找跨页引用
   */
  private processPostsQuoteInjection(posts: PostInfo[], prevPosts?: PostInfo[]): void {
    injectQuoteContent(posts, this.mgr.posts, prevPosts)
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

  /**
   * 发送回复/贴条。
   *
   * 发送失败时抛出错误，使编辑器保留内容与草稿（与发新主题流程一致）；
   * 成功才由编辑器清除草稿并关闭。发送成功后不重建窗口、不发生位移，
   * 仅静默合并服务端最新数据；Toast 提供「前往查看」定位到新楼层。
   */
  private async handleReplySend(text: string, isAnony: boolean): Promise<void> {
    let result: PostReplyResult
    try {
      result = await replyManager.send(text, isAnony)
    } catch (e) {
      appStore.showToast((e as Error).message || '操作失败')
      throw new Error((e as Error).message || '操作失败')
    }
    if (!result.ok) {
      appStore.showToast(result.error || '操作失败')
      throw new Error(result.error || '操作失败')
    }
    const isComment: boolean = replyManager.type === ReplyType.COMMENT
    const targetPost: PostInfo | null = replyManager.targetPost
    // 定位目标：贴条定位到被贴楼层（postComment 响应不返回新 pid），回复定位到新楼层
    const navPid: string = isComment ? String(targetPost?.pid ?? '') : result.pid
    if ((navPid.length > 0 && navPid !== '0') || !isComment) {
      // 回复（非贴条）即使响应未携带 pid，「前往查看」也能经静默刷新结果兜底定位
      appStore.showToastAction(isComment ? '贴条成功' : '回复成功', '前往查看', () => {
        this.goToRepliedPost(navPid)
      })
    } else {
      // 贴条且目标楼层 pid 缺失（异常）：仅提示成功，不显示无效的「前往查看」
      appStore.showToast(isComment ? '贴条成功' : '回复成功')
    }
    // 静默刷新失败仅记录，不阻断编辑器关闭
    this.silentRefreshAfterPost(replyManager.type, String(targetPost?.pid ?? ''))
  }

  /**
   * 发送编辑修改。
   *
   * 发送失败时抛出错误，使编辑器保留内容与草稿（与发新主题流程一致）；
   * 成功才由编辑器清除草稿并关闭。发送成功后静默合并被编辑楼层所在页，
   * 不发生位移；Toast 提供「前往查看」定位到被编辑楼层。
   */
  private async handleEditSend(text: string, isAnony: boolean): Promise<void> {
    let result: PostReplyResult
    try {
      result = await replyManager.send(text, isAnony)
    } catch (e) {
      appStore.showToast((e as Error).message || '编辑失败')
      throw new Error((e as Error).message || '编辑失败')
    }
    if (!result.ok) {
      appStore.showToast(result.error || '编辑失败')
      throw new Error(result.error || '编辑失败')
    }
    const targetPost: PostInfo | null = replyManager.targetPost
    const editPid: string = String(targetPost?.pid ?? '')
    // 记录编辑快照（须在乐观更新改写 content 之前读取旧正文）：静默刷新若返回
    // read.php 旧缓存（内容与编辑前一致）则跳过覆盖，防止新正文被回退成旧内容
    if (targetPost !== null) {
      this.lastEditSnapshot = new EditSnapshot()
      this.lastEditSnapshot.pid = targetPost.pid
      this.lastEditSnapshot.oldContent = targetPost.content
      this.lastEditSnapshot.newContent = text.replace(/\n/g, '<br/>')
    }
    if (editPid.length > 0) {
      appStore.showToastAction('编辑成功', '前往查看', () => {
        this.goToRepliedPost(editPid)
      })
    } else {
      // 异常情况下无定位目标：仅提示成功
      appStore.showToast('编辑成功')
    }
    // 乐观更新：编辑成功后立即用编辑正文刷新本地楼层，不等静默刷新——刚提交后
    // read.php/CDN 缓存可能未失效，静默刷新拿到的仍是旧内容，乐观更新保证用户
    // 第一时间看到新正文。换行按 NGA content 约定转 <br/>，其余 BBCode 原样保留；
    // 静默刷新结果到达后以服务端内容为准覆盖（本方法不改 pid/楼层位置）。
    // uiRev 递增使 LazyForEach 键值（pid + uiRev）变化，触发该楼层组件重建刷新。
    if (targetPost !== null) {
      const optimisticIndex: number = this.mgr.findPostIndex(targetPost.pid)
      if (optimisticIndex >= 0) {
        const optimisticPost: PostInfo = this.mgr.posts[optimisticIndex]
        optimisticPost.uiRev++
        optimisticPost.content = text.replace(/\n/g, '<br/>')
        this.postsDataSource.updateAt(optimisticIndex, optimisticPost)
      }
    }
    // 静默刷新失败仅记录，不阻断编辑器关闭
    this.silentRefreshAfterPost(replyManager.type, editPid)
  }

  /**
   * 回复/贴条/编辑成功后的静默刷新：不重建窗口、不卸载 List、不发生位移。
   *
   * 与 REPLACE 整页重建不同，本路径在同一分页代际内把服务端最新一页合并进
   * 当前窗口（ThreadPaginationManager.mergePage），数据源只做原地更新与尾部
   * 追加，LazyForEach 的索引 key 保持稳定，滚动位置自然不动。
   *
   * 刷新范围：
   * - 回复（THREAD/FLOOR）：仅当窗口覆盖服务端末页时刷新末页；窗口停在中间页
   *   时新楼层不在窗口内、数据无变化，不发起请求。
   * - 贴条（COMMENT）/编辑（EDIT）：刷新被贴/被编辑楼层所在页（贴条挂在楼层
   *   评论里、编辑改变楼层内容，只有该页数据变化）。
   *
   * 服务端总页数增长时（新回复把末页顶到下一页），继续串行合并新末页。
   * 响应到达后校验请求代际，过期即丢弃（与 loadPosts 的 stale 检查一致）。
   * 本方法不抛异常：所有失败仅记录日志，不影响回复成功流程。
   *
   * @param type - 提交类型（决定刷新范围）
   * @param targetPostPid - 被贴条/被编辑楼层的 pid（仅 COMMENT/EDIT 使用）
   */
  private async silentRefreshAfterPost(type: ReplyType, targetPostPid: string): Promise<void> {
    // 离线存档模式：新楼层不在本地存档内，静默刷新无意义且每次多走两轮
    // 存档 REPLACE/merge（新 pid 必然未命中），直接短路。
    if (this.isSavedSource()) {
      return
    }
    let refreshPage: number = 0
    if (type === ReplyType.COMMENT || type === ReplyType.EDIT) {
      if (targetPostPid.length === 0) {
        return
      }
      const targetIndex: number = this.mgr.findPostIndex(parseInt(targetPostPid, 10))
      if (targetIndex < 0) {
        return
      }
      refreshPage = this.mgr.pageOfIndex[targetIndex]
    } else if (this.mgr.loadedPageEnd >= this.mgr.totalPages) {
      // 窗口覆盖服务端末页：新回复楼层落在末页（或服务端已翻到下一页）
      refreshPage = this.mgr.loadedPageEnd
    } else {
      // 窗口停在中间页：新楼层不在窗口内，数据无变化
      return
    }

    const generation: number = this.mgr.getGeneration()
    let page: number = refreshPage
    let attempts: number = 0
    try {
      while (attempts < 3) {
        attempts++
        let result: ThreadResult
        try {
          result = await this.fetchPostsPage(page, '', 15000, taskpool.Priority.HIGH, this.mgr.posts.slice())
        } catch (e) {
          logger.warn('回复后静默刷新请求失败: %{public}s', formatError(e))
          return
        }
        if (generation !== this.mgr.getGeneration()) {
          logger.warn(
            '回复后静默刷新过期丢弃 gen=%{public}d current=%{public}d',
            generation, this.mgr.getGeneration()
          )
          return
        }
        if (!result.ok) {
          logger.warn('回复后静默刷新响应失败: %{public}s', result.error || '未知错误')
          return
        }
        const resolvedPage: number = result.pagination.page > 0 ? result.pagination.page : page
        // 编辑场景：read.php/CDN 缓存可能未失效，返回的仍是编辑前旧正文。
        // 构造保护映射（pid → 刚提交的新正文），mergePage 见非新正文则跳过覆盖，
        // 保留乐观更新结果；缓存失效返回新正文时与保护值一致，正常覆盖确认。
        let protectedContent: Map<number, string> | undefined = undefined
        if (type === ReplyType.EDIT && this.lastEditSnapshot !== null) {
          protectedContent = new Map<number, string>()
          protectedContent.set(this.lastEditSnapshot.pid, this.lastEditSnapshot.newContent)
        }
        const mergeResult: MergePageResult = this.mgr.mergePage(
          result.posts, resolvedPage, result.pagination.totalPages, protectedContent
        )
        for (let i: number = 0; i < mergeResult.updatedIndices.length; i++) {
          const idx: number = mergeResult.updatedIndices[i]
          this.postsDataSource.updateAt(idx, this.mgr.posts[idx])
        }
        if (mergeResult.appendedPosts.length > 0) {
          this.postsDataSource.appendAll(mergeResult.appendedPosts)
          // 仅回复（THREAD/FLOOR）场景记录新楼层 pid 供「前往查看」兜底：
          // 追加到窗口末尾的最后一项通常即刚回复的楼层（并发回复时可能是他人楼层，属近似）；
          // EDIT/COMMENT 刷新的是目标楼层所在页，若该页恰为末页会把他人新回复一并追加，
          // 此时不得污染 lastRepliedPid，否则后续回复的「前往查看」会定位到错误楼层。
          if (type === ReplyType.THREAD || type === ReplyType.FLOOR) {
            this.lastRepliedPid = String(mergeResult.appendedPosts[mergeResult.appendedPosts.length - 1].pid)
          }
        }
        if (mergeResult.updatedIndices.length === 0 && mergeResult.appendedPosts.length === 0) {
          // 合并无效果：请求页与服务端确认页错位（mergePage 拒绝提交，常见于 HTML 模式
          // __PAGE 解析失败回退、只看楼主页码体系差异或服务端分页漂移），或服务端返回
          // 的内容与窗口内已有内容相同（编辑刚提交后 read.php 缓存未失效）。此时 UI 不会
          // 有可见变化，warn 便于运行时定位（对照「编辑后 UI 不刷新」报告）。
          logger.warn(
            'reply-silent-merge no-op type=%{public}s requested=%{public}d resolved=%{public}d ' +
              'total=%{public}d window=%{public}d-%{public}d posts=%{public}d gen=%{public}d',
            String(type), page, resolvedPage, this.mgr.totalPages,
            this.mgr.loadedPageStart, this.mgr.loadedPageEnd, result.posts.length, generation
          )
        }
        logger.info(
          'reply-silent-merge tid=%{public}s page=%{public}d total=%{public}d updated=%{public}d ' +
            'appended=%{public}d gen=%{public}d',
          this.threadTid, resolvedPage, this.mgr.totalPages, mergeResult.updatedIndices.length,
          mergeResult.appendedPosts.length, generation
        )
        if (this.mgr.totalPages <= page) {
          break
        }
        // 贴条/编辑只刷新目标楼层所在页：合并该页后即结束，不把窗口逐页推进到
        // 服务端末页（§5.1「贴条/编辑刷新目标楼层所在页」——目标楼层位置不随新回复
        // 变化，继续请求 E+1/E+2 只会把无关楼层整页追加进窗口，造成无谓加载与位移）。
        if (type === ReplyType.COMMENT || type === ReplyType.EDIT) {
          break
        }
        // 服务端已翻页（仅回复场景）：逐页推进到下一相邻页继续合并（mergePage 只接受
        // 窗口内页或相邻下一页，直接跳到最新总页数会跳过中间页导致新楼层漏合并）
        const nextPage: number = Math.min(this.mgr.totalPages, this.mgr.loadedPageEnd + 1)
        if (nextPage <= page) {
          // 窗口未推进但总页数增长（异常）：放弃后续页，避免死循环
          logger.warn(
            '回复后静默刷新窗口未推进 page=%{public}d total=%{public}d end=%{public}d',
            page, this.mgr.totalPages, this.mgr.loadedPageEnd
          )
          break
        }
        page = nextPage
      }
    } catch (e) {
      // 合并/数据源通知阶段的意外异常：仅记录，不影响回复成功流程与编辑器关闭
      logger.warn('回复后静默刷新合并失败: %{public}s', formatError(e))
      return
    }
    // 窗口边界可能推进，恢复边缘协调与预取
    this.triggerPrefetches()
    this.scheduleReconcile(generation)
  }

  /**
   * 「前往查看」：定位到回复/贴条/编辑的目标楼层。
   *
   * 目标 pid 解析链（按序取第一个非空值）：
   * 1. 调用方传入的候选 pid（回复场景为提交响应 pid，贴条/编辑为被贴/被编辑楼层 pid）；
   * 2. 静默刷新后追加到窗口末尾的新楼层 pid（`lastRepliedPid`）；
   * 3. 仍未知（刷新未完成/失败）时，加载服务端末页并定位其最后一个楼层——
   *    新回复通常就是末页末尾，作为无 pid 信息时的最终退化。
   *
   * 窗口内命中直接页内居中滚动（零请求）；未命中（中间页回复、刷新期间窗口
   * 变化、或被只看楼主过滤）时发起一次新的整页 REPLACE 定位事务——整页请求
   * 不携带 pid（服务端带 pid 返回单帖视图，不能建立普通窗口），由
   * applyListNavigation 在页内按 pid 定位，未命中再走一次单帖兜底。
   *
   * 回调可能晚于本面板销毁触发，因此入口先校验 List 挂载状态。
   *
   * @param candidatePid - 候选目标楼层 pid（可为空，见解析链）
   */
  private goToRepliedPost(candidatePid: string): void {
    if (this.isSavedSource()) {
      // 离线存档不含回复后的新楼层，直接提示，避免误导性的
      // 「该楼层不存在或已删除」单帖兜底
      appStore.showToast('离线存档不包含新楼层')
      return
    }
    if (!this.listMounted) {
      // 面板已销毁（Toast 是全局组件，闭包可能晚于页面生命周期触发）
      logger.warn(
        'goto-replied unmounted tid=%{public}s candidate=%{public}s last=%{public}s',
        this.threadTid, candidatePid, this.lastRepliedPid
      )
      appStore.showToast('帖子页面已关闭')
      return
    }
    let pid: string = candidatePid
    if (pid.length === 0) {
      pid = this.lastRepliedPid
    }
    // '0' 是异常的哨兵值（服务端 pid 不可能为 0），视为无 pid
    if (pid === '0') {
      pid = ''
    }
    logger.info(
      'goto-replied tid=%{public}s candidate=%{public}s resolved=%{public}s gen=%{public}d ' +
        'window=%{public}d-%{public}d posts=%{public}d authorOnly=%{public}s',
      this.threadTid, candidatePid, pid, this.mgr.getGeneration(),
      this.mgr.loadedPageStart, this.mgr.loadedPageEnd, this.mgr.posts.length, String(this.authorOnly)
    )
    if (pid.length > 0) {
      if (this.mgr.findPostIndex(parseInt(pid, 10)) >= 0) {
        this.scrollToPid(pid)
        return
      }
      if (this.authorOnly) {
        appStore.showToast('只看楼主模式下不可见')
        return
      }
      // 用户显式的新定位意图（§5.1 约束的是「回复后刷新不得继承旧 pid」，此处是新意图）
      this.pendingTargetPid = pid
      this.singlePostFallback = false
      this.loadPosts(Math.max(this.mgr.totalPages, 1), ThreadLoadMode.REPLACE)
      return
    }
    if (this.authorOnly) {
      appStore.showToast('只看楼主模式下不可见')
      return
    }
    // 无已知 pid：加载服务端末页并定位其最后一个楼层
    this.pendingTargetLastPost = true
    this.pendingTargetPid = ''
    this.singlePostFallback = false
    this.loadPosts(Math.max(this.mgr.totalPages, 1), ThreadLoadMode.REPLACE)
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

  /**
   * 是否由「保存的帖子」离线存档来源打开：本地存档模式下隐藏与在线
   * 收藏/保存冲突的功能入口（收藏到…、离线保存帖子）。
   *
   * @returns 是否离线存档来源
   */
  private isSavedSource(): boolean {
    return this.threadSource === ThreadSource.SAVED
  }

  /**
   * 打开「保存帖子」对话框（选择保存的页范围）。
   */
  private openSaveThreadDialog(): void {
    if (this.threadTid.length === 0) {
      return
    }
    this.showMoreMenu = false
    this.saveDialogController = new CustomDialogController({
      builder: SaveThreadDialog({
        tid: this.threadTid,
        initialSubject: this.threadSubject,
        onSave: (tid: string, startPage: number, endPage: number): void => {
          this.startSaveThread(tid, startPage, endPage)
        }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center
    })
    this.saveDialogController?.open()
  }

  /**
   * 启动后台保存任务；结果以 Toast 提示（进度由全局指示组件展示）。
   */
  private startSaveThread(tid: string, startPage: number, endPage: number): void {
    savedThreadService.saveThread(tid, startPage, endPage).then((outcome: SaveThreadOutcome): void => {
      if (outcome.ok) {
        appStore.showToast('已保存：' + outcome.message)
      } else if (outcome.cancelled) {
        appStore.showToast('已取消保存')
      } else {
        appStore.showToast('保存失败：' + outcome.message)
      }
    })
  }

  private async handleVote(post: PostInfo, value: number): Promise<VoteResult> {
    if (!appStore.auth.isAuthenticated) {
      appStore.showToast('请先登录')
      const result: VoteResult = new VoteResult()
      result.error = '请先登录'
      return result
    }
    const pidKey: string = String(post.pid)
    const wasUp: boolean = this.votedUpPids.has(pidKey)
    const wasDown: boolean = this.votedDownPids.has(pidKey)
    const result: VoteResult = await votePost(appStore.auth.token, Number(this.threadTid), post.pid, value)
    const expectedState: number = value === 1 ? (wasUp ? 0 : 1) : (wasDown ? 0 : -1)
    const effectiveState: number = result.ok ? expectedState : result.state
    if (result.ok) {
      const upPids = new Set(this.votedUpPids)
      const downPids = new Set(this.votedDownPids)
      if (effectiveState === 1) {
        upPids.add(pidKey)
        downPids.delete(pidKey)
      } else if (effectiveState === -1) {
        downPids.add(pidKey)
        upPids.delete(pidKey)
      } else {
        upPids.delete(pidKey)
        downPids.delete(pidKey)
      }
      this.votedUpPids = upPids
      this.votedDownPids = downPids
      appStore.saveVoteRecord(appStore.auth.uid, this.threadTid, upPids, downPids)
      const isUp: boolean = upPids.has(pidKey)
      const isDown: boolean = downPids.has(pidKey)
      const scoreDelta: number = (isUp ? 1 : 0) - (wasUp ? 1 : 0)
      const score2Delta: number = (isDown ? 1 : 0) - (wasDown ? 1 : 0)
      this.mgr.updateVoteScore(post.pid, scoreDelta, score2Delta)
      if (result.message.length > 0) {
        appStore.showToast(result.message)
      }
      return result
    } else {
      appStore.showToast(result.error || '操作失败')
      return result
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
        // 离线存档模式：引用目标不在已保存的窗口内，不跳出离线上下文在线打开
        if (this.isSavedSource()) {
          appStore.showToast('该楼层未包含在存档中')
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
        this.LoadingState()
      } else if (this.hasError) {
        this.ErrorState()
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
                onVote: (p: PostInfo, value: number): Promise<VoteResult> => {
                  return this.handleVote(p, value)
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
          }, (post: PostInfo) => String(post.pid) + '_' + String(post.uiRev))
          this.LoadMoreFooter()
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
          if (this.prependAnchorPending || this.listNavigationPending) {
            if (logger.isVerbose()) {
              logger.verbose(
                'scroll-index ignored tid=%{public}s gen=%{public}d start=%{public}d ' +
                  'end=%{public}d center=%{public}d navPending=%{public}s anchorPending=%{public}s',
                this.threadTid, this.mgr.getGeneration(), start, end, center,
                String(this.listNavigationPending), String(this.prependAnchorPending)
              )
            }
            // 定位/前插事务期间不更新可见索引、不协调边缘加载、不记录阅读进度，
            // 与 reconcile 的暂停语义保持一致（THREAD_DESIGN §5.2）
            return
          }
          this.lastScrollStart = start
          this.lastScrollEnd = end
          this.lastScrollCenter = center
          this.displayPage = this.mgr.getDisplayPage(center)
          if (logger.isVerbose()) {
            logger.verbose(
              'scroll-index tid=%{public}s gen=%{public}d start=%{public}d end=%{public}d center=%{public}d ' +
                'display=%{public}d window=%{public}d-%{public}d posts=%{public}d',
              this.threadTid, this.mgr.getGeneration(), start, end, center, this.displayPage,
              this.mgr.loadedPageStart, this.mgr.loadedPageEnd, this.mgr.posts.length
            )
          }
          this.reconcile()
          this.scheduleProgressRecord()
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

      this.BottomBar()

      if (this.showMoreMenu) {
        this.MoreMenu()
      }

      if (this.showPagePicker) {
        this.PagePicker()
      }

    }
    .width('100%').height('100%').backgroundColor(AppColors.bg).alignContent(Alignment.BottomEnd)
    .id('threadPanelRoot')
  }

  /**
   * 更多菜单浮层（原 build() 内联块，纯结构搬移，行为不变）。
   */
  @Builder
  MoreMenu() {
    Stack() {
      Column() {}.width('100%').height('100%').onClick(() => { this.showMoreMenu = false })

      Column() {
        if (this.isSavedSource()) {
          Column() {
            Text('在线模式打开').fontSize(15)
              .fontColor(AppColors.textPrimary)
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .width('100%')
              .onClick(() => {
                this.showMoreMenu = false
                // 不预检帖子是否失效：直接以在线模式打开（栈顶帖子条目自动替换），
                // 帖子若已删除由在线加载的错误态呈现
                routerStore.navigateActivity(Screen.thread(this.threadTid))
              })
          }
          .width('100%')

          Divider().width('100%').color(AppColors.separator)
        }

        if (!this.isSavedSource()) {
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
            Text('离线保存帖子').fontSize(15)
              .fontColor(AppColors.textPrimary)
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .width('100%')
              .onClick(() => {
                this.openSaveThreadDialog()
              })
          }
          .width('100%')

          Divider().width('100%').color(AppColors.separator)
        }

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
              this.pendingTargetLastPost = false
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

  /**
   * 页码选择器浮层（原 build() 内联块，纯结构搬移，行为不变）。
   */
  @Builder
  PagePicker() {
    Stack() {
      Column().width('100%').height('100%').onClick(() => { this.showPagePicker = false })
      Column() {
        Text('选择页面').fontSize(14).fontColor(AppColors.textPrimary).fontWeight(FontWeight.Bold)
          .padding({ top: 12, bottom: 8 }).width('100%').textAlign(TextAlign.Center)
        Divider().color(AppColors.separator)
        Scroll() {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Start }) {
            ForEach(this.buildPageArray(), (p: number) => {
              if (p === PAGE_PICKER_ELLIPSIS) {
                Text('…').fontSize(15)
                  .fontColor(AppColors.textSecondary)
                  .width(40).height(40).textAlign(TextAlign.Center)
              } else {
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
              }
            }, (p: number) => String(p))
          }.width('100%')
        }.width('100%')
          .height(this.pagePickerTotalPages > PAGE_PICKER_MAX_DIRECT ? 84 : 120)
          .align(Alignment.TopStart)
        if (this.pagePickerTotalPages > PAGE_PICKER_MAX_DIRECT) {
          Divider().color(AppColors.separator)
          Row() {
            TextInput({ text: this.pagePickerInput, placeholder: '输入页码' })
              .type(InputType.Number)
              .fontSize(14).backgroundColor(Color.Transparent)
              .fontColor(UIMaterialManager.inputForeground)
              .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
              .caretColor(UIMaterialManager.inputForeground)
              .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
              .onChange((value: string) => { this.pagePickerInput = value })
              .onSubmit(() => { this.jumpToPageByInput() })
              .height(32).layoutWeight(1)
            Text('跳转').fontSize(14).fontColor(AppColors.primary).fontWeight(FontWeight.Medium)
              .height(32).padding({ left: 10 })
              .onClick(() => { this.jumpToPageByInput() })
          }.width('100%').padding({ top: 8 }).alignItems(VerticalAlign.Center)
        }
      }
      .width(220).height(180).padding({ left: 10, right: 10, bottom: 8 })
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

  /**
   * 底部分页条与回复按钮浮层（原 build() 内联块，纯结构搬移，行为不变）。
   */
  @Builder
  BottomBar() {
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
                this.pagePickerInput = ''
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
  }


  /**
   * 加载中状态视图（原 build() 内联块，纯结构搬移，行为不变）。
   */
  @Builder
  LoadingState() {
    Column() {
      Column() {
        LoadingStateView()
      }.opacity(this.loadingContentOpacity)
    }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      .padding({ top: NAV_BAR_H + this.statusBarHeight })
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
  }

  /**
   * 加载失败状态视图（原 build() 内联块，纯结构搬移，行为不变）。
   */
  @Builder
  ErrorState() {
    Column() {
      ErrorStateView({
        msg: this.errorMsg,
        onRetry: (): Promise<void> => this.loadPosts(this.lastReplacePage, ThreadLoadMode.REPLACE)
      })
    }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      .padding({ top: NAV_BAR_H + this.statusBarHeight })
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
  }

  /**
   * 列表尾部加载/完成状态项（原 build() 内联块，纯结构搬移，行为不变）。
   */
  @Builder
  LoadMoreFooter() {
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
}
