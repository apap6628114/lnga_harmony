import { display, CustomContentDialog } from '@kit.ArkUI'
import { common, Context } from '@kit.AbilityKit'

import { appStore } from '../store/AppStore'
import { AiAgentPreset, PRESET_ENTRY_THREAD } from '../model/AiAgentPreset'
import { routerStore, Screen, ThreadSource } from '../store/RouterStore'
import { votePost } from '../service/api/FavoriteApi'
import { getActiveDomain } from '../service/api/MiscApi'
import { ThreadResult } from '../model/ThreadResult'
import type { PostReplyResult } from '../model/ThreadResult'
import type { PostInfo } from '../model/PostInfo'
import { VoteResult } from '../model/NgaApiResults'
import { FavoriteMembershipState } from '../model/Favorite'
import { getCachedBBNodes } from '../parser/bbcode/BBCodeCache'
import { AppColors, NAV_BAR_H } from '../common/constants/Constants'
import { PanelNavBar, NavBarMenuItem } from '../common/components/PanelNavBar'
import { PostItem } from '../common/components/PostItem'
import { LoadingStateView, ErrorStateView } from '../common/components/PageStateView'
import { HdsMaterialHost } from '../common/components/HdsMaterialHost'
import { ThreadTreeChildItem } from '../common/components/thread-tree/ThreadTreeChildItem'
import { ThreadTreeMoreItem } from '../common/components/thread-tree/ThreadTreeMoreItem'
import { floatingLayerStore, FloatingPage } from '../store/FloatingLayerStore'
import { replyManager } from '../common/managers/ReplyManager'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { TtsMediaMetadata } from '../common/media/TtsAvSessionController'
import { TtsPlayer } from '../common/media/TtsPlayer'
import { sharePost, shareThread } from '../common/utils/ShareUtils'
import { openImageViewer as sharedOpenImageViewer, handleForumLink } from '../common/utils/LinkUtils'
import { Logger, DOMAIN_UI, formatError } from '../common/utils/Logger'
import { getActiveAiValidationMessage } from '../service/ai/ActiveAiService'
import { bbNodesToPlainText } from '../common/utils/Utils'
import { UIMaterialManager } from '../common/managers/UIMaterialManager'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'
import { applyBlacklistStateToPosts } from '../common/utils/BlacklistUtils'
import { dismissAnalyzerSessions } from '../common/media/ImageAnalyzerSession'
import { HoldingHandMonitor, HoldingHandStatus } from '../common/managers/HoldingHandMonitor'
import { SaveThreadContent } from '../common/dialogs/SaveThreadDialogs'
import { ThreadTrackContent } from '../common/dialogs/ThreadTrackDialogs'
import { savedThreadService, SaveThreadOutcome } from '../service/SavedThreadService'
import { TrackRequest, TrackResult } from '../store/TrackedThreadStore'
import { TrackedThread, TRACK_DEFAULT_KEEP_DAYS, TRACK_MAX_COUNT } from '../model/TrackedThread'
import { ThreadTreeProgressEntry } from '../store/ThreadTreeProgressStore'
import {
  ThreadTreeModel,
  ThreadTreeRow,
  ThreadTreeRowKind,
  ThreadTreeChild,
  ThreadTreeQuoteRef,
  ThreadTreeRoot
} from '../model/ThreadTree'
import {
  buildThreadTree,
  flattenThreadTree,
  expandRoot,
  findRootPidByPid
} from '../common/utils/ThreadTreeBuilder'
import { threadTreeFetchService, ThreadTreeFetchResult } from '../service/ThreadTreeFetchService'
import { ThreadTreeDataSource } from '../common/datasource/ThreadTreeDataSource'

const logger = new Logger(DOMAIN_UI, 'ThreadTreePanel')

/**
 * 「检测到上次阅读进度」提示的**保护窗口**（ms）。
 *
 * 与 `ToastManager.actionDurationMs`（4000）对齐并略长一点：提示消失后按钮已不可点，
 * 此时必须解除「禁止记录进度」的保护，否则用户忽略提示继续阅读时整场都不会落盘
 * （首行超过一屏时 `onScrollIndex` 的 start 恒为 0，不能靠滚动解除）。
 */
const PROGRESS_PROMPT_PROTECT_MS: number = 4300

/**
 * 帖子「两层递进树」阅读页面（与列表页互斥的独立页面组件）。
 *
 * 与自然列表页（ThreadPanel）**数据隔离**：本页面自己抓取全帖、自己展示加载进度、
 * 自己持有树模型与数据源，不读写 ThreadPanel 的分页窗口，也不与其共享渲染状态。
 * 但**功能面与列表页对齐**（`docs/THREAD_TREE_DESIGN.md` §3.6）：
 * 更多菜单与列表页同构（收藏 / 离线保存 / 跟踪 / 刷新 / 只看楼主 / 切换阅读方式 /
 * 从网页打开 / 分享），并各自维护阅读记录与阅读进度。
 *
 * 进入方式（两种阅读样式**互斥**，切换一律用 `navigateActivity(screen, true)` 原地替换栈条目）：
 * - 列表页更多菜单「切换为递进树阅读」：替换当前列表页（列表页实例随替换销毁），
 *   返回直接回主题列表，不会再退回列表阅读；
 * - 设置「帖子默认样式 = 递进树」：打开帖子时直接挂载本页（仍是同一个 `Screen.thread` 条目）；
 * - 本页「切换为列表阅读」/ 加载中的「以常规列表打开」：终止全帖抓取并替换为列表页。
 *
 * 全帖抓取可能持续数十秒（4 路并发 + 限流），因此**加载期有三种出口**（不强迫用户等完整抓取）：
 * - 「查看已加载 n/N 页」：中断抓取，把已抓楼层送进树（`partialData`）；
 * - 「取消」：放弃这次阅读并退出（`routerStore.back()`）；
 * - 「以常规列表打开」：换成列表样式阅读。
 *
 * 部分数据**不做断点续传、也不挂常驻提醒**：中断是用户自己的决定，不需要再被告知一次；
 * 只在列表尾部用一句中性的「已加载 n/N 页」标识内容边界（替代「已加载全部回复」），
 * 不弹 Toast、不加横幅。想拿全内容走「刷新递进树」整帖重抓。
 */
@Component
export struct ThreadTreePanel {
  /** 主题 ID。 */
  @Prop @Watch('onThreadChanged') threadTid: string = ''
  /** 初始定位楼层 pid（空串表示无定位意图：由树页自己的阅读进度决定，无记录则顶部）。 */
  @Prop threadPid: string = ''
  /** 路由带来的「只看楼主」初始态（列表页切换阅读方式时沿用当前过滤状态）。 */
  @Prop authorOnlyInit: boolean = false
  /**
   * 路由带来的楼主 uid（列表页切换过来时已知）。
   *
   * 全帖抓取返回前用它维持「只看楼主」与标题屏蔽；切回列表时也原样透传，
   * 避免加载中切换丢失过滤状态。抓取结果返回后以服务端 `threadInfo` 为准。
   */
  @Prop authorIdInit: string = ''
  /** 路由带来的楼主稳定作者标识（匿名帖本地过滤用，语义见 `PostInfo.authorKey`）。 */
  @Prop authorKeyInit: string = ''
  /** 打开帖子的路由来源（决定是否允许恢复树内阅读进度，与列表页同一白名单）。 */
  @Prop threadSource: string = ''
  /** 路由请求的初始页码（> 1 表示有明确翻页意图，不恢复进度）。 */
  @Prop threadPage: number = 1

  /** 全帖抓取中。 */
  @State isLoading: boolean = true
  /** 抓取失败。 */
  @State hasError: boolean = false
  /** 抓取失败原因。 */
  @State errorMsg: string = ''
  /** 抓取进度：已完成页数。 */
  @State progressDone: number = 0
  /** 抓取进度：总页数（第 1 页返回后确定）。 */
  @State progressTotal: number = 0
  /** 页面标题（加载完成后取主题标题）。 */
  @State threadSubject: string = '递进树'
  /** 树模型是否可渲染。 */
  @State treeReady: boolean = false
  /**
   * 本次抓取缺页的常驻提示（空串表示没有缺页）。
   *
   * 由 {@link buildSkippedPagesHint} 生成，同时用于：
   * - 列表尾部「已加载全部回复（第 X 页缺少楼层）」；
   * - 阅读进度恢复提示的补充说明（见 {@link resumeTreeProgress}）。
   *
   * 不只用一次性 Toast：Toast 是单条替换语义，紧接着弹出的「检测到上次阅读进度」
   * 会把它顶掉（`ToastManager.showImpl` 每次展示都会覆盖上一条），用户就会在
   * 不知情的情况下读一份缺页的树。
   */
  @State skippedPageHint: string = ''
  /**
   * 当前树是否只覆盖**部分页**（加载中人工中断，或某页失败后用户选择查看已加载数据）。
   *
   * 刻意**不做常驻提醒**：中断是用户自己的操作，页面上不再挂横幅/弹 Toast；
   * 这个标志只用于两件事：
   * 1. 列表尾部把「已加载全部回复」换成中性的「已加载 n/N 页」（内容边界，不是警告）；
   * 2. 树内跳转/阅读进度恢复找不到楼层时，把「不存在」改述为「不在已加载页内」。
   *
   * 不提供断点续传：补齐内容走「刷新递进树」整帖重抓。
   */
  @State partialData: boolean = false
  /** 部分数据下已覆盖页数（与服务端总页数共同构成 n/N）。 */
  @State partialLoadedPages: number = 0
  /** 部分数据下的服务端总页数。 */
  @State partialTotalPages: number = 0
  /** 是否正在中断加载（已请求取消，等待在途页返回后提交部分数据）。 */
  @State interrupting: boolean = false
  /** 错误态是否提供「查看已加载 n/N 页」入口（失败前已抓到楼层时为 true）。 */
  @State hasPartialFallback: boolean = false
  /** 已点赞楼层 pid 集合。 */
  @State votedUpPids: Set<string> = new Set()
  /** 已点踩楼层 pid 集合。 */
  @State votedDownPids: Set<string> = new Set()
  /** 标题栏渐变模糊进度。 */
  @State titleScrollEffectProgress: number = 0
  /** List 视口高度（标题模糊映射用）。 */
  @State listViewportHeight: number = 1
  /** AI 任务候选（多任务时的选择弹窗）。 */
  @State aiTasks: AiAgentPreset[] = []
  /** 当前主题的收藏状态（更多菜单文案与激活态）。 */
  @State favoriteState: FavoriteMembershipState = FavoriteMembershipState.UNKNOWN
  /** 当前是否只看楼主（树内按楼主过滤重建）。 */
  @State authorOnly: boolean = false
  /** 握姿：决定底部回复按钮贴左还是贴右。 */
  @State holdingStatus: HoldingHandStatus = appStore.settings.holdingHand as HoldingHandStatus
  /** 跟踪对话框中选中的跟踪时长（天），由 ThreadTrackContent 回写。 */
  @State private trackKeepDays: number = TRACK_DEFAULT_KEEP_DAYS
  /** 保存帖子弹窗：页范围是否合法（由 SaveThreadContent 回写）。 */
  @State private saveRangeValid: boolean = false
  /** 保存帖子弹窗：选定起始页（由 SaveThreadContent 回写，非法为 -1）。 */
  @State private saveStartPage: number = -1
  /** 保存帖子弹窗：选定结束页（由 SaveThreadContent 回写，非法为 -1）。 */
  @State private saveEndPage: number = -1

  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @StorageProp('navBarHeight') navBarHeight: number = 0
  /**
   * 主题收藏关系变更版本号。
   *
   * 只用于建立响应式依赖：收藏可能在收藏夹面板等处被修改，回到本页时更多菜单的
   * 文案（收藏到… / 管理收藏）必须取到最新状态。
   */
  @StorageProp('favoriteTopicVersion') @Watch('onFavoriteTopicVersionChange') favoriteTopicVersion: number = 0
  /**
   * 跟踪列表版本号。
   *
   * 与列表页同源：跟踪状态可能在对话框/收藏面板等处变化，菜单激活态不能停在旧值。
   */
  @StorageProp('trackedThreadVersion') trackedThreadVersion: number = 0
  /** 黑名单变更版本号：楼层仍需按最新黑名单遮蔽正文。 */
  @StorageProp('blacklistVersion') @Watch('onBlacklistVersionChange') blacklistVersion: number = 0

  /** 全帖楼层（未过滤；「只看楼主」切换时据此重建）。 */
  private allPosts: PostInfo[] = []
  /** 服务端总页数（取自抓取结果）。 */
  private totalPages: number = 0
  /** 楼层 pid → 服务端页码（切回列表模式与进度记录用）。 */
  private pageByPid: Map<number, number> = new Map()
  /** 树模型（独立于任何分页窗口）。 */
  private treeModel: ThreadTreeModel | null = null
  /** 树 List 数据源（扁平可见行）。 */
  private treeDataSource: ThreadTreeDataSource = new ThreadTreeDataSource()
  /** 树 List 滚动控制器。 */
  private scroller: Scroller = new Scroller()
  /** 树 List 是否已挂载（挂载前 scrollToIndex 静默无效）。 */
  private listMounted: boolean = false
  /** 待定位楼层 pid（0 表示顶部）。 */
  private navigationPid: number = 0
  /** 是否等待 List 挂载后定位。 */
  private navigationPending: boolean = false
  /** 是否已为定位安排下一帧任务。 */
  private navigationScheduled: boolean = false
  /** 高亮清除计时器。 */
  private highlightTimer: number = -1
  /** 当前高亮楼层 pid。 */
  private highlightPid: number = 0
  /** 抓取代际：刷新/销毁时递增，使旧结果失效。 */
  private fetchGeneration: number = 0
  /**
   * 整页加载失败但已抓到楼层时的暂存结果（错误态「查看已加载」用）。
   *
   * 刻意**不自动提交**：失败中断留下的残缺树不能静默展示（用户会以为帖子就这些），
   * 但直接丢弃又浪费已抓内容，因此挂在错误态由用户主动选择。
   */
  private failedPartialResult: ThreadTreeFetchResult | null = null
  /**
   * 失败暂存结果对应的刷新锚点与标题策略。
   *
   * 刷新失败时 `loadTree` 已经把树清空，但失败结果里可能仍有已抓楼层；用户点
   * 「查看已加载」提交时如果只用 `-1`，`resolveNavigationPid` 会退回路由 pid（通常 0），
   * 表现为**刷失败后看部分数据会跳回顶部**。这里把失败时算好的锚点与
   * `keepSubject` 一并暂存，提交时原样透传。
   */
  private failedPartialAnchorPid: number = -1
  private failedPartialKeepSubject: boolean = false
  /**
   * 本页面实例标识（抓取服务的 owner）。
   *
   * 用于精确取消与串行化：同一帖子「返回再进入」会出现新旧两个页面实例，
   * 旧实例的销毁回调晚于新实例启动时不能误杀新任务（见 ThreadTreeFetchService 注释）。
   */
  private treeOwner: string = ''
  /** 主题 fid（回复/编辑协议用）。 */
  private threadFid: number = 0
  /** 楼主 uid（跟踪任务与只看楼主过滤用）。 */
  private threadAuthorId: string = ''
  /** 楼主稳定作者标识（`authorKey` 语义，见 PostInfo）。 */
  private threadAuthorKey: string = ''
  /** 是否已取得可用楼主标识。 */
  private hasThreadAuthorKey: boolean = false
  /** AI 任务选择弹窗控制器。 */
  private aiTaskDialogController?: CustomDialogController
  /** 待处理 AI 任务的楼层。 */
  private aiTaskPost: PostInfo | null = null
  /** 保存帖子弹窗控制器。 */
  private saveDialogController?: CustomDialogController
  /** 跟踪帖子更新弹窗控制器。 */
  private trackDialogController?: CustomDialogController

  /** 是否已完成首次进入（@Watch 可能早于 aboutToAppear 触发）。 */
  private hasInitiallyLoaded: boolean = false
  /** 握持状态监视器。 */
  private holdingMonitor: HoldingHandMonitor = new HoldingHandMonitor()
  /** 是否已收到过握持状态（首次直接生效，后续带动画）。 */
  private holdingDetected: boolean = false

  /**
   * 树内阅读进度的延迟保存计时器（滚动停顿 800ms 后落盘，离开页面时立即补记）。
   *
   * 与列表页 `ThreadPanel.progressRecordTimer` 同构，但记录的是**树内锚点行**
   * （pid / 所属根 / 服务端页码），见 {@link recordTreeProgress}。
   */
  private progressRecordTimer: number = -1
  /** 「检测到上次阅读进度」提示的保护窗口计时器（到时解除禁止记录）。 */
  private progressPromptTimer: number = -1
  /** 首屏完成后是否仍在等待读取并恢复上阅读进度。 */
  private readingResumePending: boolean = false
  /** 当前帖子的树内进度恢复是否已经处理过（防止刷新时重复恢复）。 */
  private readingResumeHandled: boolean = false
  /** 待用户确认的树内进度：Toast「前往查看」点击后执行定位；只影响定位动作，不作为记录开关。 */
  private pendingResumeEntry: ThreadTreeProgressEntry | null = null
  /**
   * 刷新期间用户点击「前往查看」的延迟定位目标 pid。
   *
   * 刷新会卸载 List（`listMounted=false`），此时不能立即滚动；先记住目标，等新一轮
   * 树加载完成、List 重新挂载后作为定位锚点消费。
   */
  private deferredResumePid: number = -1
  /** 首次导航/恢复是否已执行过（未执行前不记录进度，避免把首行误记成阅读位置）。 */
  private navigationApplied: boolean = false
  /** `onScrollIndex` 最近上报的视口中心行下标（进度锚点取中心行）。 */
  private lastScrollCenter: number = 0
  /** `onScrollIndex` 最近上报的首个可见行下标（判断用户是否已开始阅读）。 */
  private lastScrollStart: number = 0

  aboutToAppear(): void {
    this.hasInitiallyLoaded = true
    /*
     * 一次性引导的置位（见 `ThreadPanel.maybeShowTreeReadingGuide`）：
     * 直接以递进树进入的用户**已经在用它**，再弹「存在递进树模式」只是打扰；
     * 这里静默置位，保证之后即使切到列表阅读也不会再被引导一次。
     */
    if (!appStore.treeGuideAcknowledged) {
      appStore.acknowledgeTreeGuide().catch((e: Error): void => {
        logger.warn('acknowledge tree guide failed: %{public}s', formatError(e))
      })
    }
    this.treeOwner = 'tree-' + String(Date.now()) + '-' + String(Math.floor(Math.random() * 1000000))
    this.authorOnly = this.authorOnlyInit
    // 全帖抓取返回前先用路由带来的楼主身份（列表页切换过来时已知）：
    // 加载中再切回列表也要能沿用「只看楼主」，抓取结果返回后以服务端 threadInfo 为准
    this.threadAuthorId = this.authorIdInit
    this.threadAuthorKey = this.authorKeyInit
    this.hasThreadAuthorKey = this.isAuthorKeyUsable(this.authorKeyInit)
    this.loadTree(false)
    this.loadPersistedVotes()
    this.syncFavoriteState()
    appStore.favoriteStore.ensureFolders()
    this.startHoldingHandMonitoring()
  }

  aboutToDisappear(): void {
    // 先补记最终阅读位置（此时树模型与滚动状态仍有效），再清理资源
    this.recordTreeProgress()
    clearTimeout(this.progressRecordTimer)
    this.progressRecordTimer = -1
    clearTimeout(this.progressPromptTimer)
    this.progressPromptTimer = -1
    // 使在途的进度恢复读取/已弹出的提示失效：页面销毁后不得再定位
    this.readingResumePending = false
    this.pendingResumeEntry = null
    this.deferredResumePid = -1
    this.stopHoldingHandMonitoring()
    this.cancelWork()
    this.aiTaskDialogController = undefined
    this.saveDialogController = undefined
    this.trackDialogController = undefined
  }

  /**
   * 切换帖子（同一页面实例被复用到另一个 tid）：补记旧帖进度并重置页面态。
   */
  private onThreadChanged(): void {
    if (!this.hasInitiallyLoaded) {
      this.hasInitiallyLoaded = true
      return
    }
    // 切换前补记旧帖的最终阅读位置（此时 treeModel/allPosts 仍是旧帖数据）
    this.recordTreeProgress()
    clearTimeout(this.progressRecordTimer)
    this.progressRecordTimer = -1
    clearTimeout(this.progressPromptTimer)
    this.progressPromptTimer = -1
    if (this.highlightTimer >= 0) {
      clearTimeout(this.highlightTimer)
      this.highlightTimer = -1
    }
    this.highlightPid = 0
    this.readingResumeHandled = false
    this.readingResumePending = false
    this.pendingResumeEntry = null
    this.deferredResumePid = -1
    this.navigationApplied = false
    this.allPosts = []
    this.pageByPid = new Map<number, number>()
    this.treeModel = null
    this.treeReady = false
    this.treeDataSource.clear()
    this.totalPages = 0
    this.skippedPageHint = ''
    this.partialData = false
    this.partialLoadedPages = 0
    this.partialTotalPages = 0
    this.interrupting = false
    this.hasPartialFallback = false
    this.failedPartialResult = null
    this.failedPartialAnchorPid = -1
    this.failedPartialKeepSubject = false
    this.threadFid = 0
    // 与 aboutToAppear 同源：先回到路由身份（可能为空），抓取结果返回后再覆盖
    this.threadAuthorId = this.authorIdInit
    this.threadAuthorKey = this.authorKeyInit
    this.hasThreadAuthorKey = this.isAuthorKeyUsable(this.authorKeyInit)
    this.authorOnly = this.authorOnlyInit
    this.threadSubject = '递进树'
    this.titleScrollEffectProgress = 0
    this.lastScrollStart = 0
    this.lastScrollCenter = 0
    this.navigationPending = false
    this.navigationScheduled = false
    this.votedUpPids = new Set<string>()
    this.votedDownPids = new Set<string>()
    this.syncFavoriteState()
    this.loadTree(false)
    this.loadPersistedVotes()
  }

  /**
   * 取消在途抓取并清空所有延迟任务。
   */
  private cancelWork(): void {
    this.fetchGeneration++
    threadTreeFetchService.cancel(this.treeOwner)
    this.navigationPending = false
    this.navigationScheduled = false
    if (this.highlightTimer >= 0) {
      clearTimeout(this.highlightTimer)
      this.highlightTimer = -1
    }
    this.highlightPid = 0
    this.listMounted = false
  }

  // ==================== 加载 ====================

  /**
   * 加载全帖并重建树（页面进入、「刷新递进树」、回复后刷新共用）。
   *
   * 加载期有三种出口（见 {@link LoadingState}）：查看已加载 / 取消 / 以常规列表打开。
   * 部分数据不做断点续传：想拿全内容走本方法（刷新）整帖重抓。
   *
   * @param keepSubject - 是否保留当前标题并回到当前阅读位置（刷新场景）；
   *   false 表示首次加载，定位使用路由传入的 pid。该标志同时作为 `forceRefresh`
   *   传给抓取服务：刷新/重试必须绕过短时缓存，首次进入则允许复用缓存（90 秒内秒开）
   */
  private loadTree(keepSubject: boolean): void {
    // 代际先推进、旧任务先取消：即使本次因 tid 为空直接早退，在途的旧结果也不得再提交
    this.fetchGeneration++
    const generation: number = this.fetchGeneration
    clearTimeout(this.progressRecordTimer)
    this.progressRecordTimer = -1
    this.navigationApplied = false
    this.failedPartialResult = null
    this.failedPartialAnchorPid = -1
    this.failedPartialKeepSubject = false
    this.hasPartialFallback = false
    this.interrupting = false
    if (this.threadTid.length === 0) {
      threadTreeFetchService.cancel(this.treeOwner)
      this.isLoading = false
      this.hasError = true
      this.errorMsg = '缺少帖子 ID'
      return
    }
    // 刷新时以当前视口中心行为锚点，避免重建后跳回路由进入时的位置
    const refreshAnchorPid: number = keepSubject ? this.currentCenterPid() : -1
    const fetchTid: string = this.threadTid
    this.isLoading = true
    this.hasError = false
    this.errorMsg = ''
    this.progressDone = 0
    this.progressTotal = 0
    this.treeReady = false
    this.treeDataSource.clear()
    // 上一轮的缺页/部分数据提示属于旧结果：新一轮抓取重新判定
    this.skippedPageHint = ''
    this.partialData = false
    this.partialLoadedPages = 0
    this.partialTotalPages = 0
    logger.info('tree-panel load start tid=%{public}s gen=%{public}d refresh=%{public}s',
      fetchTid, generation, String(keepSubject))
    threadTreeFetchService.fetchAll(this.treeOwner, fetchTid, (done: number, total: number): void => {
      if (generation !== this.fetchGeneration) {
        return
      }
      this.progressDone = done
      this.progressTotal = total
    }, keepSubject).then((result: ThreadTreeFetchResult): void => {
      if (generation !== this.fetchGeneration) {
        logger.warn('tree-panel load stale tid=%{public}s gen=%{public}d', fetchTid, generation)
        return
      }
      // 用户是否主动点了「查看已加载」：必须在清空 interrupting 之前取快照。
      // 服务层的 cancelled 也可能是「被新任务抢占」——平板三列下从板块列打开另一个帖子时，
      // 本页被路由覆盖但仍存活、自身代际不变，B 页面的 fetchAll 会把本页任务置为取消。
      // 那种取消不是用户的阅读决定，不能替用户提交部分树或写历史/弹提示。
      const userInterrupted: boolean = this.interrupting
      this.interrupting = false
      if (result.cancelled && !userInterrupted) {
        // 被其他页面/任务抢占：不替用户自动提交部分树、不写历史、不弹提示，
        // 但数据不丢——已抓完就正常建树；只抓到一部分就挂在错误态的「查看已加载」入口上
        this.deferredResumePid = -1
        if (result.ok && !result.partial) {
          this.commitFetchResult(result, keepSubject, refreshAnchorPid)
          logger.info('tree-panel preempted but complete tid=%{public}s', fetchTid)
          return
        }
        this.isLoading = false
        this.hasError = true
        this.errorMsg = '加载被其他操作中断'
        if (result.ok && result.partial) {
          this.failedPartialResult = result
          this.failedPartialAnchorPid = refreshAnchorPid
          this.failedPartialKeepSubject = keepSubject
          this.hasPartialFallback = true
          this.partialLoadedPages = result.loadedPages
          this.partialTotalPages = result.totalPages
        }
        logger.info('tree-panel load preempted tid=%{public}s gen=%{public}d loaded=%{public}d',
          fetchTid, generation, result.loadedPages)
        return
      }
      if (!result.ok) {
        // 没有可提交楼层：取消（第 1 页返回前中断）或首屏失败
        this.isLoading = false
        this.deferredResumePid = -1
        this.hasError = true
        this.errorMsg = result.cancelled ? '已取消加载递进树'
          : (result.error.length > 0 ? result.error : '加载失败')
        return
      }
      if (result.partial && !result.cancelled) {
        // 抓取中途失败但已有楼层：不自动提交残缺树（会误导「帖子就这些」），
        // 停在错误态并提供「查看已加载 n/N 页」由用户主动选择
        this.isLoading = false
        this.deferredResumePid = -1
        this.hasError = true
        this.errorMsg = result.error.length > 0 ? result.error : '加载未完成'
        this.failedPartialResult = result
        this.failedPartialAnchorPid = refreshAnchorPid
        this.failedPartialKeepSubject = keepSubject
        this.hasPartialFallback = true
        this.partialLoadedPages = result.loadedPages
        this.partialTotalPages = result.totalPages
        logger.warn('tree-panel partial fallback tid=%{public}s loaded=%{public}d/%{public}d',
          fetchTid, result.loadedPages, result.totalPages)
        return
      }
      // 完整结果，或用户主动中断（cancelled）后拿到了已抓楼层：直接建树
      this.commitFetchResult(result, keepSubject, refreshAnchorPid)
    }).catch((error: Object): void => {
      if (generation !== this.fetchGeneration) {
        return
      }
      this.interrupting = false
      this.isLoading = false
      this.deferredResumePid = -1
      this.hasError = true
      this.errorMsg = formatError(error)
      logger.error('tree-panel load failed tid=%{public}s: %{public}s', fetchTid, formatError(error))
    })
  }

  /**
   * 提交一次抓取结果并重建树（完整、人工中断、错误态查看已加载三条路径共用）。
   *
   * @param result - 抓取结果（`ok` 必须为 true）
   * @param keepSubject - 是否保留当前标题
   * @param anchorPid - 定位锚点（-1 表示按路由 pid / 阅读进度决定）
   */
  private commitFetchResult(result: ThreadTreeFetchResult, keepSubject: boolean,
    anchorPid: number): void {
    this.applyThreadInfo(keepSubject, result)
    this.allPosts = result.posts
    // 抓取请求固定用空黑名单（保证引用图完整），遮蔽标记在提交时按当前黑名单统一补齐；
    // 缓存命中时也走这里，避免复用上一次的黑名单快照
    applyBlacklistStateToPosts(this.allPosts, appStore.settingsStore.getBlacklistIds())
    this.totalPages = result.totalPages
    this.pageByPid = result.pageByPid
    // 旧树的可见中心/首行不再适用于新 rows，重置后再由本轮的 onScrollIndex 更新
    this.lastScrollStart = 0
    this.lastScrollCenter = 0
    this.rebuildTree()
    this.treeReady = true
    this.isLoading = false
    this.interrupting = false
    this.applyPartialState(result)
    // 有页被跳过时记录缺页提示并弹一次 Toast；部分数据不弹「已加载 n/N 页」——
    // 中断是用户自己的决定，不再用 Toast 重复告知；缺页提示仍保留（那才是未知信息）
    this.applySkippedPages(result.skippedPages)
    // 阅读记录（浏览历史）与列表页同源：树模式打开同一帖子同样计入「看过」
    this.recordBrowseHistory(result)
    // 被跟踪的帖子：打开即推进已读基准（与列表页同一入口语义）
    this.syncTrackedOnOpen()
    this.navigationPid = this.resolveNavigationPid(anchorPid)
    this.navigationPending = true
    this.navigationScheduled = false
    this.scheduleNavigation()
    // 路由自带定位意图时不恢复进度（避免两种定位意图打架）
    if (anchorPid < 0 && this.threadPid.length === 0) {
      this.tryRestoreTreeProgress()
    }
    logger.info(
      'tree-panel load done tid=%{public}s posts=%{public}d roots=%{public}d rows=%{public}d ' +
        'quotes=%{public}d authorOnly=%{public}s partial=%{public}s',
      this.threadTid, result.posts.length, this.treeModel !== null ? this.treeModel.roots.length : 0,
      this.treeDataSource.totalCount(), this.treeModel !== null ? this.treeModel.quoteCount : 0,
      String(this.authorOnly), String(result.partial)
    )
  }

  /**
   * 应用结果的部分数据状态（只服务列表尾部文案与「未加载页」相关的提示口径）。
   *
   * 不做任何常驻提醒：横幅、Toast 都不发；中断是用户自己的决定。
   *
   * @param result - 已提交的抓取结果
   */
  private applyPartialState(result: ThreadTreeFetchResult): void {
    this.partialData = result.partial
    this.partialLoadedPages = result.loadedPages
    this.partialTotalPages = result.totalPages
  }

  /**
   * 应用本次抓取的缺页信息：写入常驻提示并在需要时弹一次 Toast。
   *
   * 提示不只用 Toast 承载（见 {@link skippedPageHint} 字段说明）：Toast 会被后续
   * 提示覆盖，常驻文案保证「树少了哪几页」在页面上始终可查。
   *
   * @param skippedPages - 被跳过的页码（升序）
   */
  private applySkippedPages(skippedPages: number[]): void {
    this.skippedPageHint = this.buildSkippedPagesHint(skippedPages)
    if (this.skippedPageHint.length === 0) {
      return
    }
    appStore.showToast(this.skippedPageHint + '，已跳过')
  }

  /**
   * 生成缺页提示文案（Toast / 列表尾部 / 进度提示共用同一份）。
   *
   * Toast 一行放得下 3 个页码；更多时只报总数 + 前 3 个示例。
   *
   * @param skippedPages - 被跳过的页码（升序）
   * @returns 文案；没有缺页时为空串
   */
  private buildSkippedPagesHint(skippedPages: number[]): string {
    if (skippedPages.length === 0) {
      return ''
    }
    const shown: string[] = []
    const limit: number = Math.min(skippedPages.length, 3)
    for (let i: number = 0; i < limit; i++) {
      shown.push(String(skippedPages[i]))
    }
    if (skippedPages.length <= limit) {
      return '第 ' + shown.join('、') + ' 页缺少楼层'
    }
    return '共 ' + String(skippedPages.length) + ' 页缺少楼层（如第 ' + shown.join('、') + ' 页）'
  }

  /**
   * 按当前过滤状态重建树模型并替换数据源。
   *
   * 「只看楼主」在树内不是列表级过滤，而是**用楼主楼层重建一棵树**：被过滤掉的
   * 非楼主楼层不再参与父子关系，原来回复它们的楼主楼层按「引用目标不在树内」提升为根
   * （`buildThreadTree` 的既有语义），因此不会出现悬空子行或错误的折叠计数。
   */
  private rebuildTree(): void {
    const posts: PostInfo[] = this.filteredPosts()
    const model: ThreadTreeModel = buildThreadTree(posts, this.totalPages)
    this.pageByPid.forEach((page: number, pid: number): void => {
      model.pageByPid.set(pid, page)
    })
    // buildThreadTree 内部已 flatten；只看楼主补回根行引用上下文时才需要再摊平一次
    if (this.restoreRootQuoteContext(model)) {
      flattenThreadTree(model)
    }
    this.treeModel = model
    this.treeDataSource.replaceAll(model.rows)
  }

  /**
   * 只看楼主模式下，给「被引用楼层已被过滤掉」的根行补回引用上下文。
   *
   * 树页根行用 `PostItem` 渲染，正文默认是剥离引用区后的内容（`displayContent`）；
   * 过滤后原本作为父节点的非楼主楼层不在树里，根行只剩一张没有任何“回复了谁”
   * 提示的卡片，与列表页的只看楼主不一致。这里让这类根行保留原始正文（含引用块），
   * 由卡片内的引用块继续表达被回复对象。
   *
   * 只有同时满足三个条件才改：只看楼主开启、该行是根、引用目标不在当前树模型中
   * （被过滤/被删/跨帖）。主楼引用（`targetPid === 0`）不处理。
   *
   * @param model - 刚构建好的树模型（roots / rows 已就绪）
   * @returns 是否修改了根行正文（调用方据此决定是否需要重新摊平）
   */
  private restoreRootQuoteContext(model: ThreadTreeModel): boolean {
    if (!this.authorOnly) {
      return false
    }
    let changed: boolean = false
    for (let i: number = 0; i < model.roots.length; i++) {
      const root: ThreadTreeRoot = model.roots[i]
      const ref: ThreadTreeQuoteRef | null = root.ref
      if (ref === null || ref.isTopicRef || ref.targetPid <= 0) {
        continue
      }
      if (model.postByPid.has(ref.targetPid)) {
        continue
      }
      if (root.displayContent !== root.post.content) {
        root.displayContent = root.post.content
        changed = true
      }
    }
    return changed
  }

  /**
   * 取当前参与建树的楼层（只看楼主时仅保留主楼与楼主楼层）。
   *
   * @returns 楼层数组
   */
  private filteredPosts(): PostInfo[] {
    if (!this.authorOnly || !this.hasThreadAuthorKey) {
      return this.allPosts
    }
    const filtered: PostInfo[] = []
    for (let i: number = 0; i < this.allPosts.length; i++) {
      const post: PostInfo = this.allPosts[i]
      // 主楼恒保留：它是树的第一行，且 `buildThreadTree` 靠 `lou === 0` 识别
      if (post.lou === 0 || this.isTopicAuthorPost(post)) {
        filtered.push(post)
      }
    }
    if (filtered.length === this.allPosts.length) {
      return this.allPosts
    }
    return filtered
  }

  /**
   * 应用全帖抓取结果里的主题元数据（标题 / fid / 楼主标识）。
   *
   * @param keepSubject - 是否保留当前标题
   * @param result - 抓取结果
   */
  private applyThreadInfo(keepSubject: boolean, result: ThreadTreeFetchResult): void {
    if (result.threadInfo === null) {
      // 拿不到主题信息：保留路由带来的楼主身份（若有），两者都不可用时才关闭只看楼主
      this.disableAuthorOnlyIfUnavailable()
      return
    }
    this.threadFid = result.threadInfo.fid
    const fetchAuthorId: number = result.threadInfo.authorid
    const fetchAuthorKey: string = result.threadInfo.authorKey
    // 服务端结果优先；它没给（uid=0 / authorKey 为空）时回落到路由身份，
    // 否则「只看楼主」与标题屏蔽会在加载完成后反而被关闭
    this.threadAuthorId = fetchAuthorId !== 0 ? String(fetchAuthorId) : this.authorIdInit
    this.threadAuthorKey = fetchAuthorKey.length > 0 ? fetchAuthorKey : this.authorKeyInit
    this.hasThreadAuthorKey = this.isAuthorKeyUsable(this.threadAuthorKey)
    this.disableAuthorOnlyIfUnavailable()
    if (keepSubject && this.threadSubject.length > 0 && this.threadSubject !== '递进树') {
      return
    }
    const subject: string = unescapeHtml(result.threadInfo.subject)
    this.threadSubject = subject.length > 0 ? subject : '递进树'
  }

  /**
   * 楼主标识不可用时关闭「只看楼主」并提示。
   *
   * 路由可能带着 `authorOnlyInit=true` 进入（从列表页切换阅读方式），但树页的过滤依赖
   * 楼主稳定标识（抓取结果里的 `threadInfo.authorKey`，返回前用路由带来的 `authorKeyInit`）；
   * 两者都拿不到时若仍显示激活态，菜单与实际内容会互相矛盾（显示全部楼层却标着“只看楼主”）。
   */
  private disableAuthorOnlyIfUnavailable(): void {
    if (!this.authorOnly || this.hasThreadAuthorKey) {
      return
    }
    this.authorOnly = false
    appStore.showToast('无法识别楼主，已显示全部楼层')
  }

  /**
   * 把这次全帖抓取计入浏览历史（与列表页 `addBrowseHistoryFromThread` 同一份台账）。
   *
   * 抓取结果是树页面自己的聚合结构，这里按 `ThreadResult` 的同形状字段组装后交给
   * `HistoryStore`：`threadInfo.replies` 即已读基线，主题列表据此判定「看过后有新回复」。
   *
   * @param result - 全帖抓取结果
   */
  private recordBrowseHistory(result: ThreadTreeFetchResult): void {
    if (!appStore.auth.isAuthenticated) {
      return
    }
    const historyResult: ThreadResult = new ThreadResult()
    historyResult.ok = true
    historyResult.threadInfo = result.threadInfo
    historyResult.forumName = result.forumName
    historyResult.posts = result.posts
    historyResult.pagination.page = 1
    historyResult.pagination.totalPages = result.totalPages
    historyResult.pagination.totalRows = result.posts.length
    appStore.addBrowseHistoryFromThread(appStore.auth.uid, historyResult, this.threadTid)
  }

  /**
   * 楼主标识是否可用于身份比较。
   *
   * @param authorKey - 稳定作者标识
   * @returns 可用于比较时为 true
   */
  private isAuthorKeyUsable(authorKey: string): boolean {
    if (authorKey.length === 0) {
      return false
    }
    const numeric: number = Number(authorKey)
    return isNaN(numeric) || numeric > 0
  }

  /**
   * 当前楼层是否楼主所发（匿名帖用稳定 authorKey 判定）。
   *
   * @param post - 楼层
   * @returns 是楼主所发时为 true
   */
  private isTopicAuthorPost(post: PostInfo): boolean {
    return this.hasThreadAuthorKey && post.authorKey === this.threadAuthorKey
  }

  // ==================== 树定位 ====================

  /**
   * 在树 List 挂载后安排下一帧定位。
   */
  private scheduleNavigation(): void {
    if (!this.navigationPending || this.navigationScheduled || !this.listMounted) {
      return
    }
    this.navigationScheduled = true
    setTimeout((): void => {
      this.navigationScheduled = false
      this.applyNavigation()
    }, 0)
  }

  /**
   * 计算本轮加载完成后的定位锚点。
   *
   * 优先级：刷新期间用户点击「前往查看」的延迟目标 → 刷新前视口中心 → 路由 pid。
   *
   * @param refreshAnchorPid - 刷新前的中心行 pid；首次加载传 -1
   * @returns 目标 pid（0 表示定位顶部）
   */
  private resolveNavigationPid(refreshAnchorPid: number): number {
    if (this.deferredResumePid >= 0) {
      const deferred: number = this.deferredResumePid
      this.deferredResumePid = -1
      return deferred
    }
    if (refreshAnchorPid >= 0) {
      return refreshAnchorPid
    }
    const parsed: number = this.threadPid.length > 0 ? parseInt(this.threadPid, 10) : 0
    return Number.isFinite(parsed) ? parsed : 0
  }

  /**
   * 执行树定位：目标行不可见时先展开其所属根，再居中滚动。
   */
  private applyNavigation(): void {
    if (!this.navigationPending || !this.listMounted) {
      return
    }
    this.navigationPending = false
    const pid: number = this.navigationPid
    this.navigationApplied = true
    if (pid <= 0) {
      this.scroller.scrollToIndex(0, false, ScrollAlign.START)
      return
    }
    let index: number = this.treeDataSource.findIndexByPid(pid)
    if (index < 0 && this.ensureRowVisible(pid)) {
      index = this.treeDataSource.findIndexByPid(pid)
    }
    if (index >= 0) {
      this.scroller.scrollToIndex(index, false, ScrollAlign.CENTER)
    } else {
      this.scroller.scrollToIndex(0, false, ScrollAlign.START)
    }
  }

  /**
   * 确保指定楼层行在树中可见（被折叠时展开其所属根）。
   *
   * @param pid - 目标楼层 pid
   * @returns 树模型中有该楼层时为 true
   */
  private ensureRowVisible(pid: number): boolean {
    const model: ThreadTreeModel | null = this.treeModel
    if (model === null || pid <= 0) {
      return false
    }
    if (this.treeDataSource.findIndexByPid(pid) >= 0) {
      return true
    }
    const rootPid: number = findRootPidByPid(model, pid)
    if (rootPid < 0) {
      return false
    }
    if (rootPid === pid) {
      return true
    }
    expandRoot(model, rootPid)
    flattenThreadTree(model)
    this.treeDataSource.replaceAll(model.rows)
    return this.treeDataSource.findIndexByPid(pid) >= 0
  }

  /**
   * 展开某根全部子节点（折叠行点击）。
   *
   * @param rootPid - 根节点 pid
   */
  private expandTreeRoot(rootPid: number): void {
    const model: ThreadTreeModel | null = this.treeModel
    if (model === null || !expandRoot(model, rootPid)) {
      return
    }
    flattenThreadTree(model)
    this.treeDataSource.replaceAll(model.rows)
  }

  /**
   * 树内跳转到指定楼层（子节点头部「→」/ 同帖链接）。
   *
   * @param pid - 目标楼层 pid
   */
  private treeJumpToPid(pid: number): void {
    const model: ThreadTreeModel | null = this.treeModel
    if (model === null) {
      return
    }
    if (pid <= 0) {
      this.scroller.scrollToIndex(0, false, ScrollAlign.START)
      return
    }
    if (!this.ensureRowVisible(pid)) {
      appStore.showToast(this.missingFloorHint())
      return
    }
    const index: number = this.treeDataSource.findIndexByPid(pid)
    if (index < 0) {
      return
    }
    this.scroller.scrollToIndex(index, false, ScrollAlign.CENTER)
    this.highlightRow(pid)
  }

  /**
   * 树内跳转命中不到楼层时的提示文案。
   *
   * 部分数据下 `postByPid` 只含已加载页的楼层，同帖链接「→」指到未加载页时不能
   * 断言「不存在或已删除」——那不是事实，用户该做的是刷新拿全内容。
   *
   * @returns 提示文案
   */
  private missingFloorHint(): string {
    if (this.partialData) {
      return '该楼层不在已加载的 ' + String(this.partialLoadedPages) + '/' +
        String(this.partialTotalPages) + ' 页内，可刷新递进树获取全部'
    }
    return '该楼层不存在或已删除'
  }

  /**
   * 高亮命中的子节点行，2 秒后清除。
   *
   * @param pid - 命中楼层 pid
   */
  private highlightRow(pid: number): void {
    const row: ThreadTreeRow | null = this.treeDataSource.findRowByPid(pid)
    if (row === null || row.kind !== ThreadTreeRowKind.CHILD) {
      return
    }
    const index: number = this.treeDataSource.findIndexByPid(pid)
    if (index < 0) {
      return
    }
    if (this.highlightTimer >= 0) {
      clearTimeout(this.highlightTimer)
      this.highlightTimer = -1
    }
    row.highlighted = true
    row.rev++
    this.highlightPid = pid
    this.treeDataSource.updateAt(index, row)
    this.highlightTimer = setTimeout((): void => {
      this.highlightTimer = -1
      const targetPid: number = this.highlightPid
      this.highlightPid = 0
      if (targetPid <= 0) {
        return
      }
      const current: ThreadTreeRow | null = this.treeDataSource.findRowByPid(targetPid)
      if (current === null) {
        return
      }
      const currentIndex: number = this.treeDataSource.findIndexByPid(targetPid)
      if (currentIndex < 0) {
        return
      }
      current.highlighted = false
      current.rev++
      this.treeDataSource.updateAt(currentIndex, current)
    }, 2000)
  }

  /**
   * 视口中心锚点行下标；中心落在折叠行时向上下就近取一个楼层行。
   *
   * @returns 行下标；无可用行返回 -1
   */
  private resolveAnchorIndex(): number {
    const model: ThreadTreeModel | null = this.treeModel
    if (model === null || model.rows.length === 0) {
      return -1
    }
    const rows: ThreadTreeRow[] = model.rows
    const index: number = Math.max(0, Math.min(this.lastScrollCenter, rows.length - 1))
    if (rows[index].post !== null) {
      return index
    }
    for (let i: number = index - 1; i >= 0; i--) {
      if (rows[i].post !== null) {
        return i
      }
    }
    for (let i: number = index + 1; i < rows.length; i++) {
      if (rows[i].post !== null) {
        return i
      }
    }
    return -1
  }

  /**
   * 当前视口中心楼层的 pid（切换阅读方式、刷新定位用）。
   *
   * @returns 楼层 pid；无可定位行时返回 -1
   */
  private currentCenterPid(): number {
    const model: ThreadTreeModel | null = this.treeModel
    const index: number = this.resolveAnchorIndex()
    if (model === null || index < 0) {
      return -1
    }
    const post: PostInfo | null = model.rows[index].post
    return post !== null ? post.pid : -1
  }

  /**
   * 由树行构造子节点组件入参（引用头缺作者名时用目标楼层补齐）。
   *
   * @param row - 树行（`kind === CHILD`）
   * @returns 子节点数据
   */
  private buildTreeChild(row: ThreadTreeRow): ThreadTreeChild {
    const child: ThreadTreeChild = new ThreadTreeChild()
    if (row.post !== null) {
      child.post = row.post
    }
    if (row.ref !== null) {
      child.ref = row.ref
      const model: ThreadTreeModel | null = this.treeModel
      if (child.ref.targetAuthor.length === 0 && child.ref.targetPid > 0 && model !== null) {
        const target: PostInfo | undefined = model.postByPid.get(child.ref.targetPid)
        if (target !== undefined) {
          const filled: ThreadTreeQuoteRef = new ThreadTreeQuoteRef()
          filled.targetPid = child.ref.targetPid
          filled.targetPage = child.ref.targetPage
          filled.targetUid = child.ref.targetUid.length > 0 ? child.ref.targetUid : String(target.authorid)
          filled.targetAuthor = target.author
          filled.rawHeader = child.ref.rawHeader
          filled.isTopicRef = child.ref.isTopicRef
          filled.external = child.ref.external
          child.ref = filled
        }
      }
    }
    child.highlighted = row.highlighted
    return child
  }

  /**
   * 取子节点对应的被回复楼层号。
   *
   * @param ref - 引用关系
   * @returns 楼层号（0=楼主；-1=未知）
   */
  private targetLou(ref: ThreadTreeQuoteRef | null): number {
    if (ref === null || ref.targetPid <= 0 || this.treeModel === null) {
      return -1
    }
    const target: PostInfo | undefined = this.treeModel.postByPid.get(ref.targetPid)
    return target !== undefined ? target.lou : -1
  }

  /**
   * 树行 LazyForEach 键值。
   *
   * @param row - 树行
   * @returns 稳定键值
   */
  private rowKey(row: ThreadTreeRow): string {
    const pid: number = row.post !== null ? row.post.pid : row.rootPid
    const highlight: string = row.highlighted ? '_h' : ''
    return String(row.kind) + '_' + String(pid) + '_' + String(row.rev) + highlight
  }

  // ==================== 阅读进度（树内锚点） ====================

  /**
   * 树内阅读进度记录是否有效（开关开启、已登录、树已就绪、首轮定位已完成）。
   *
   * @returns 是否可以记录
   */
  private shouldRecordProgress(): boolean {
    return appStore.settings.recordReadingProgress &&
      appStore.auth.uid.length > 0 &&
      this.treeReady &&
      // 首轮定位/滚动尚未执行：此时 lastScrollCenter 还是默认的 0，记录会把顶部主楼
      // 误当成阅读位置（覆盖上次进度）
      this.navigationApplied &&
      // 导航事务进行中，rows 与 lastScrollCenter 可能暂时不同步
      !this.navigationPending &&
      // 进度读取窗口内不落盘（首屏自动定位会先停在顶部）
      !this.readingResumePending &&
      // 恢复提示可见窗口内不落盘；提示消失（PROGRESS_PROMPT_PROTECT_MS）后解除，
      // 避免用户忽略提示继续阅读时整场都不记录
      this.pendingResumeEntry === null
  }

  /**
   * 滚动过程中节流调度一次进度记录（停顿后落盘，避免高频写入）。
   */
  private scheduleProgressRecord(): void {
    if (!this.shouldRecordProgress()) return
    clearTimeout(this.progressRecordTimer)
    this.progressRecordTimer = setTimeout((): void => {
      this.progressRecordTimer = -1
      this.recordTreeProgress()
    }, 800)
  }

  /**
   * 记录当前树内阅读位置。
   *
   * 锚点取视口中心行（与还原时的居中定位同源对称）。与列表页不同，树视图没有分页窗口，
   * 定位依据是**扁平可见行**，因此记录的是：
   * - `pid` / `rootPid`：锚点楼层及所属根（恢复时先展开根再居中）；
   * - `page`：锚点楼层所属服务端页码（诊断快照；切换阅读方式不携带位置）。
   *
   * 刻意不记录扁平行下标：它会随折叠/展开与只看楼主过滤漂移，无法作为可靠的定位依据。
   */
  private recordTreeProgress(): void {
    if (!this.shouldRecordProgress()) return
    const model: ThreadTreeModel | null = this.treeModel
    if (model === null) return
    const index: number = this.resolveAnchorIndex()
    if (index < 0) return
    const row: ThreadTreeRow = model.rows[index]
    const post: PostInfo | null = row.post
    if (post === null) return
    const entry = new ThreadTreeProgressEntry()
    const postTid: number = post.tid
    entry.tid = postTid > 0 ? String(postTid) : this.threadTid
    entry.pid = post.pid
    entry.rootPid = row.rootPid
    const mappedPage: number | undefined = this.pageByPid.get(post.pid)
    entry.page = mappedPage !== undefined && mappedPage > 0 ? mappedPage : 1
    appStore.saveTreeReadingProgress(appStore.auth.uid, entry)
  }

  /**
   * 首次进入当前帖子时尝试恢复上一次的树内阅读位置。
   *
   * 与列表页同一交互：不静默定位，读取通过校验后仅弹「前往查看」Toast，由用户点击执行。
   * 门禁与列表页对齐：路由自带楼层/page 定位意图、或来源不是「继续阅读」语义
   * （链接/通知/搜索等）时不恢复。从列表页「切换阅读方式」进入时路由不带位置，
   * 因此同样恢复树页自己的进度——两种样式各记各的，互不覆盖。
   */
  private tryRestoreTreeProgress(): void {
    if (this.readingResumeHandled || this.readingResumePending) return
    if (this.threadTid.length === 0) return
    if (this.threadPid.length > 0) return
    if (this.threadPage > 1) return
    if (!this.isResumeAllowedSource()) return
    if (!appStore.settings.recordReadingProgress || appStore.auth.uid.length === 0) return
    this.readingResumePending = true
    this.resumeTreeProgress()
  }

  /**
   * 是否允许恢复阅读进度：与列表页共用「继续阅读」语义的来源白名单。
   *
   * @returns 来源是否允许恢复
   */
  private isResumeAllowedSource(): boolean {
    return this.threadSource === ThreadSource.DEFAULT ||
      this.threadSource === ThreadSource.TOPIC_LIST ||
      this.threadSource === ThreadSource.BROWSE_HISTORY
  }

  /**
   * 异步读取并校验树内进度；读取期间可能已切帖/销毁，需逐一校验。
   */
  private async resumeTreeProgress(): Promise<void> {
    const uid: string = appStore.auth.uid
    const tid: string = this.threadTid
    let entry: ThreadTreeProgressEntry | null = null
    try {
      entry = await appStore.getTreeReadingProgress(uid, tid)
    } catch (e) {
      // 读盘异常不能让 readingResumePending 永久为 true：否则本页整场都不会记录进度
      this.readingResumePending = false
      logger.warn('tree-progress read failed tid=%{public}s: %{public}s', tid, formatError(e))
      return
    }
    if (!this.readingResumePending || tid !== this.threadTid) return
    // 读取期间账号可能已登出或切换：进度按账号隔离，身份不一致时丢弃，避免跨账号恢复
    if (appStore.auth.uid !== uid) {
      this.readingResumePending = false
      return
    }
    if (!appStore.settings.recordReadingProgress) {
      this.readingResumePending = false
      return
    }
    this.readingResumePending = false
    if (entry === null || entry.pid < 0) {
      this.readingResumeHandled = true
      return
    }
    // 读取期间用户已经开始滚动阅读：不打断当前阅读
    if (this.lastScrollStart > 0 && this.listMounted) {
      this.readingResumeHandled = true
      return
    }
    this.readingResumeHandled = true
    this.pendingResumeEntry = entry
    // 提示可见窗口结束后自动解除“禁止落盘”保护，并用同一个计时器覆盖 Toast 的可点窗口：
    // Toast 是全局组件、动作按钮没有关闭回调，只有计时器能保证保护窗口不会永久挂住
    clearTimeout(this.progressPromptTimer)
    this.progressPromptTimer = setTimeout((): void => {
      this.progressPromptTimer = -1
      this.pendingResumeEntry = null
    }, PROGRESS_PROMPT_PROTECT_MS)
    // 缺页提示并入同一条 Toast：Toast 是单条替换语义，紧随其后的这条会把刚才的
    // 缺页提示顶掉；合并后两条信息都不丢（常驻文案仍在 skippedPageHint 里可查）。
    // 部分数据（用户主动中断）不并入提示——中断是用户自己的操作，不再重复告知。
    const resumeText: string = this.skippedPageHint.length > 0
      ? '检测到上次阅读进度（' + this.skippedPageHint + '）'
      : '检测到上次阅读进度'
    appStore.showToastAction(resumeText, '前往查看', (): void => {
      this.goToResumedPosition()
    })
  }

  /**
   * 用户点击 Toast「前往查看」后执行树内定位。
   *
   * Toast 是全局组件，回调可能晚于面板销毁、帖子切换或正在进行的刷新触发，
   * 入口重新校验：进度未失效、帖子/开关仍与记录时一致；刷新中则延迟到新一轮加载完成。
   */
  private goToResumedPosition(): void {
    clearTimeout(this.progressPromptTimer)
    this.progressPromptTimer = -1
    const entry: ThreadTreeProgressEntry | null = this.pendingResumeEntry
    this.pendingResumeEntry = null
    if (entry === null) return
    if (!this.listMounted) {
      if (this.isLoading) {
        // 刷新中 List 被卸载：记住目标，等新树就绪后由 resolveNavigationPid 消费
        this.deferredResumePid = entry.pid
        appStore.showToast('正在刷新，完成后将恢复阅读位置')
        return
      }
      logger.warn('tree-progress resume unmounted tid=%{public}s pid=%{public}d',
        this.threadTid, entry.pid)
      appStore.showToast('帖子页面已关闭')
      return
    }
    if (this.threadTid !== entry.tid) return
    if (!appStore.settings.recordReadingProgress || appStore.auth.uid.length === 0) return
    this.applyTreeResume(entry)
  }

  /**
   * 执行树内恢复定位：先按 pid 找行（被折叠则展开所属根）。
   *
   * 找不到时分两种口径：完整树里找不到是「已不可用」；部分数据里更可能只是
   * **那几页还没加载**，不能谎报楼层不存在（见 {@link missingFloorHint} 的同口径处理）。
   *
   * 不再用记录时的扁平行下标兜底：下标会随折叠/展开与只看楼主过滤漂移，
   * 按下标取到的很可能是另一个楼层，会静默把用户带到错误位置。
   *
   * @param entry - 树内进度条目
   */
  private applyTreeResume(entry: ThreadTreeProgressEntry): void {
    logger.info(
      'tree-progress resume tid=%{public}s pid=%{public}d root=%{public}d page=%{public}d',
      this.threadTid, entry.pid, entry.rootPid, entry.page
    )
    let index: number = -1
    if (entry.pid >= 0) {
      index = this.treeDataSource.findIndexByPid(entry.pid)
      if (index < 0 && entry.pid > 0) {
        // 记录时所属根优先：折叠状态下锚点子行不在可见行里，先展开该根
        if (entry.rootPid >= 0) {
          this.expandTreeRoot(entry.rootPid)
          index = this.treeDataSource.findIndexByPid(entry.pid)
        }
        // 根 pid 失效（帖子结构变化）时再按模型重新查所属根
        if (index < 0 && this.ensureRowVisible(entry.pid)) {
          index = this.treeDataSource.findIndexByPid(entry.pid)
        }
      }
    }
    if (index < 0) {
      this.navigationApplied = true
      appStore.showToast(this.partialData
        ? '上次阅读位置不在已加载的 ' + String(this.partialLoadedPages) + '/' +
          String(this.partialTotalPages) + ' 页内，可刷新后恢复'
        : '原阅读位置已不可用')
      this.scroller.scrollToIndex(0, false, ScrollAlign.START)
      return
    }
    this.navigationApplied = true
    this.scroller.scrollToIndex(index, false, ScrollAlign.CENTER)
    this.highlightRow(entry.pid)
    appStore.showToast('已恢复上次阅读位置')
  }

  // ==================== 交互 ====================

  /**
   * 加载中人工中断：请求取消并等待在途页返回，随后由抓取结果的 `cancelled` 分支
   * 提交已抓到的楼层（见 {@link loadTree}）。
   *
   * 取消不是「立即返回」：服务端在途请求没有真正的中止手段，服务会在当前批次请求
   * 收尾后返回（通常 1~3 秒，最坏为单页超时的 15 秒）。这段时间页面显示
   * 「正在中断加载…」并收起三个操作按钮，避免重复触发。
   */
  private beginViewLoaded(): void {
    if (this.progressDone <= 0 || this.interrupting) {
      return
    }
    this.interrupting = true
    threadTreeFetchService.cancel(this.treeOwner)
    logger.info('tree-panel interrupt tid=%{public}s done=%{public}d/%{public}d',
      this.threadTid, this.progressDone, this.progressTotal)
  }

  /**
   * 加载中取消：终止抓取并退出递进树页面。
   *
   * 递进树条目替代了列表页，页面栈里没有「原来的视图」可退：取消的语义就是放弃这次
   * 阅读，与系统返回一致。已抓数据直接丢弃（想留着看请用「查看已加载」）。
   */
  private cancelLoadingAndExit(): void {
    this.cancelWork()
    routerStore.back()
  }

  /**
   * 错误态「查看已加载」：把失败前抓到的楼层提交成部分树。
   *
   * 数据来自 {@link failedPartialResult}（失败时暂存、不自动提交）；提交后与人工中断
   * 的部分树完全同构：尾部标注已加载范围。定位锚点与标题策略沿用失败时暂存的
   * 值——刷新失败后再看部分数据仍旧停在刷新前的阅读位置，不会跳回顶部。
   */
  private commitFailedPartial(): void {
    const result: ThreadTreeFetchResult | null = this.failedPartialResult
    if (result === null) {
      return
    }
    const anchorPid: number = this.failedPartialAnchorPid
    const keepSubject: boolean = this.failedPartialKeepSubject
    this.failedPartialResult = null
    this.failedPartialAnchorPid = -1
    this.failedPartialKeepSubject = false
    this.hasPartialFallback = false
    this.hasError = false
    this.errorMsg = ''
    this.commitFetchResult(result, keepSubject, anchorPid)
  }

  /**
   * 回复/编辑发送成功后刷新全帖树。
   *
   * @param successText - 成功提示
   */
  private refreshAfterSubmit(successText: string): void {
    appStore.showToast(successText)
    this.loadTree(true)
  }

  /**
   * 发送楼层回复 / 主题回复（编辑器在全局浮层中）。
   *
   * @param text - 回复正文
   * @param isAnony - 是否匿名
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
    this.refreshAfterSubmit('回复成功')
  }

  /**
   * 发送编辑修改。
   *
   * @param text - 新正文
   * @param isAnony - 是否匿名
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
    this.refreshAfterSubmit('编辑成功')
  }

  /**
   * 打开楼层回复编辑器。
   *
   * @param post - 目标楼层
   */
  private openFloorReply(post: PostInfo): void {
    let page: number = 1
    const mapped: number | undefined = this.pageByPid.get(post.pid)
    if (mapped !== undefined && mapped > 0) {
      page = mapped
    }
    replyManager.startFloorReply(post, Number(this.threadTid), this.threadFid, page)
    floatingLayerStore.replyDialogTitle = replyManager.dialogTitle
    floatingLayerStore.replyOnSend = (text: string, isAnony: boolean): Promise<void> => {
      return this.handleReplySend(text, isAnony)
    }
    floatingLayerStore.editMode = false
    floatingLayerStore.push(FloatingPage.REPLY_DIALOG)
  }

  /**
   * 打开编辑编辑器。
   *
   * @param post - 目标楼层
   */
  private openEdit(post: PostInfo): void {
    replyManager.startEdit(post, Number(this.threadTid), this.threadFid)
    floatingLayerStore.replyDialogTitle = replyManager.dialogTitle
    floatingLayerStore.editMode = true
    floatingLayerStore.editInitialContent = unescapeHtml(post.content).replace(/<br\s*\/?>/gi, '\n')
    floatingLayerStore.replyOnSend = (_text: string, _isAnony: boolean): Promise<void> => {
      return this.handleEditSend(_text, _isAnony)
    }
    floatingLayerStore.push(FloatingPage.REPLY_DIALOG)
  }

  /**
   * 打开主题回复编辑器。
   */
  private openThreadReply(): void {
    replyManager.startThreadReply(Number(this.threadTid), this.threadFid)
    floatingLayerStore.replyDialogTitle = replyManager.dialogTitle
    floatingLayerStore.editMode = false
    floatingLayerStore.replyOnSend = (text: string, isAnony: boolean): Promise<void> => {
      return this.handleReplySend(text, isAnony)
    }
    floatingLayerStore.push(FloatingPage.REPLY_DIALOG)
  }

  /**
   * 点赞 / 点踩。
   *
   * @param post - 楼层
   * @param value - 1=赞，-1=踩
   * @returns 投票结果
   */
  private async handleVote(post: PostInfo, value: number): Promise<VoteResult> {
    if (!appStore.auth.isAuthenticated) {
      appStore.showToast('请先登录')
      const denied: VoteResult = new VoteResult()
      denied.error = '请先登录'
      return denied
    }
    const pidKey: string = String(post.pid)
    const wasUp: boolean = this.votedUpPids.has(pidKey)
    const wasDown: boolean = this.votedDownPids.has(pidKey)
    const result: VoteResult = await votePost(appStore.auth.token, Number(this.threadTid), post.pid, value)
    if (!result.ok) {
      appStore.showToast(result.error || '操作失败')
      return result
    }
    const expectedState: number = value === 1 ? (wasUp ? 0 : 1) : (wasDown ? 0 : -1)
    const effectiveState: number = result.ok ? expectedState : result.state
    const upPids: Set<string> = new Set(this.votedUpPids)
    const downPids: Set<string> = new Set(this.votedDownPids)
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
    /*
     * 同步楼层分数（与列表页 `ThreadPaginationManager.updateVoteScore` 同一增量规则）：
     * `PostVoteBar` 只在当前组件实例内维护乐观分数，滚动离场后再复用会从
     * `post.score/score_2` 重新同步；不回写模型楼层就会让已生效的投票在 UI 上“退回去”。
     *
     * 注意：回调里的 `post` 是行组件的 @Prop 拷贝，必须按 pid 回写 `allPosts` 里的
     * 真源对象（列表页更新的是分页窗口里的模型对象，同理）。
     */
    const isUp: boolean = upPids.has(pidKey)
    const isDown: boolean = downPids.has(pidKey)
    const scoreDelta: number = (isUp ? 1 : 0) - (wasUp ? 1 : 0)
    const score2Delta: number = (isDown ? 1 : 0) - (wasDown ? 1 : 0)
    post.score += scoreDelta
    post.score_2 += score2Delta
    const canonical: PostInfo | null = this.findAllPostByPid(post.pid)
    if (canonical !== null && canonical !== post) {
      canonical.score += scoreDelta
      canonical.score_2 += score2Delta
    }
    if (result.message.length > 0) {
      appStore.showToast(result.message)
    }
    return result
  }

  /**
   * 在全帖楼层（未过滤）中按 pid 查找真源对象。
   *
   * 只看楼主时锚点可能不在树模型里，因此优先查 `allPosts`，再回退树模型。
   *
   * @param pid - 楼层 pid
   * @returns 楼层对象；未找到返回 null
   */
  private findAllPostByPid(pid: number): PostInfo | null {
    for (let i: number = 0; i < this.allPosts.length; i++) {
      if (this.allPosts[i].pid === pid) {
        return this.allPosts[i]
      }
    }
    const model: ThreadTreeModel | null = this.treeModel
    if (model !== null) {
      const post: PostInfo | undefined = model.postByPid.get(pid)
      return post !== undefined ? post : null
    }
    return null
  }

  /**
   * 读取本账号在当前帖子的历史投票记录。
   */
  private async loadPersistedVotes(): Promise<void> {
    if (!appStore.auth.isAuthenticated) {
      return
    }
    const result = await appStore.loadVoteRecord(appStore.auth.uid, this.threadTid)
    this.votedUpPids = result[0]
    this.votedDownPids = result[1]
  }

  /**
   * 打开用户资料卡（屏幕内收敛位置）。
   *
   * @param uid - 用户 uid
   * @param screenX - 点击点 x
   * @param screenY - 点击点 y
   */
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
    floatingLayerStore.openProfileCard(uid, posX, posY)
  }

  /**
   * 打开图片查看器。
   *
   * @param urls - 图片地址集
   * @param index - 起始下标
   */
  private openImageViewer(urls: string[], index: number): void {
    sharedOpenImageViewer(urls, index)
  }

  /**
   * 正文链接：同帖楼层链接在树内定位，其余交给全局链接处理器。
   *
   * @param href - 链接
   */
  private handleLinkClick(href: string): void {
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
      if (linkTid === this.threadTid && linkPid.length > 0) {
        const linkPidNumber: number = parseInt(linkPid, 10)
        if (this.treeModel !== null && this.treeModel.postByPid.has(linkPidNumber)) {
          this.treeJumpToPid(linkPidNumber)
          return
        }
        // 目标不在树里时不能一律说「不在递进树中」：部分数据下它可能只是还没加载
        appStore.showToast(this.missingFloorHint())
        return
      }
    }
    handleForumLink(href, this.getUIContext().getHostContext() as common.UIAbilityContext, (uid: string) => {
      this.showProfileCard(uid, 200, 200)
    })
  }

  /**
   * 朗读楼层正文。
   *
   * @param p - 楼层
   * @param displayContent - 树模式正文（已剥离引用区）；传空串时读原始 content
   */
  private readAloud(p: PostInfo, displayContent: string = ''): void {
    const source: string = displayContent.length > 0 ? displayContent : p.content
    const plainText: string = bbNodesToPlainText(getCachedBBNodes(source))
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
  }

  /**
   * 打开 AI 任务选择（帖子入口）。
   *
   * @param p - 楼层
   */
  private beginAiSummarize(p: PostInfo): void {
    const aiValidationMessage: string = getActiveAiValidationMessage()
    if (aiValidationMessage.length > 0) {
      appStore.showToast(aiValidationMessage)
      return
    }
    const plainText: string = bbNodesToPlainText(getCachedBBNodes(p.content))
    if (plainText.trim().length === 0) {
      appStore.showToast('该楼层没有可处理的内容')
      return
    }
    const tasks: AiAgentPreset[] = appStore.settingsStore.listAiPresetsByEntry(PRESET_ENTRY_THREAD)
    this.aiTaskPost = p
    if (tasks.length === 0) {
      this.launchAiTask(null, p, 'AI 助手')
      return
    }
    if (tasks.length === 1) {
      this.launchAiTask(tasks[0], p, tasks[0].name)
      return
    }
    const next: AiAgentPreset[] = []
    for (let i: number = 0; i < tasks.length; i++) {
      next.push(tasks[i])
    }
    this.aiTasks = next
    this.aiTaskDialogController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: CustomContentDialog({
        primaryTitle: '选择 AI 任务',
        contentBuilder: (): void => { this.aiTaskContent() },
        buttons: [{ value: '取消' }]
      }),
      autoCancel: true
    })
    this.aiTaskDialogController.open()
  }

  /**
   * 启动 AI 任务（跳转 AI 对话页，由任务读取楼层内容）。
   *
   * @param preset - 任务（null 表示自由对话）
   * @param p - 楼层
   * @param title - 页面标题
   */
  private launchAiTask(preset: AiAgentPreset | null, p: PostInfo, title: string): void {
    TtsPlayer.stop()
    const presetId: string = preset !== null ? preset.id : ''
    const floorText: string = '当前帖子第 ' + p.lou.toString() + ' 楼（作者 ' + p.author + '）'
    const prompt: string = preset === null
      ? '请读取' + floorText + '的内容并总结；需要正文或其它楼层时，调用读帖工具读取。'
      : '请读取' + floorText + '的内容，按任务要求完成；需要正文或其它楼层时，调用读帖工具读取。'
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ai/AiChatPage',
      params: {
        presetId: presetId,
        title: title,
        tid: this.threadTid,
        pid: p.pid.toString(),
        threadTitle: this.threadSubject,
        initialPrompt: prompt
      }
    })
  }

  /** AI 任务选择弹窗内容。 */
  @Builder
  aiTaskContent() {
    Column() {
      ForEach(this.aiTasks, (task: AiAgentPreset) => {
        Row() {
          Column() {
            Text(task.name).fontSize(15).fontColor(AppColors.textPrimary)
            if (task.description.length > 0) {
              Text(task.description)
                .fontSize(11).fontColor(AppColors.textTertiary).lineHeight(16)
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 2 })
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text('›').fontSize(18).fontColor(AppColors.chevron)
        }
        .width('100%')
        .padding({ top: 10, bottom: 10 })
        .alignItems(VerticalAlign.Center)
        .onClick((): void => {
          this.aiTaskDialogController?.close()
          const post: PostInfo | null = this.aiTaskPost
          if (post !== null) {
            this.launchAiTask(task, post, task.name)
          }
        })
      }, (task: AiAgentPreset): string => task.id)
    }
    .width('100%')
  }

  // ==================== 收藏 / 保存 / 跟踪（与列表页同一套入口） ====================

  /**
   * 响应主题收藏关系变化并刷新当前收藏状态。
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
   * 打开当前主题的收藏夹多选页面。
   */
  private openFavoriteFolders(): void {
    if (this.threadTid.length === 0) {
      return
    }
    routerStore.navigateActivity(Screen.favoriteFolders(this.threadTid))
  }

  /**
   * 打开「保存帖子」对话框（选择保存的页范围）。
   */
  private openSaveThreadDialog(): void {
    if (this.threadTid.length === 0) {
      return
    }
    this.saveRangeValid = false
    this.saveStartPage = -1
    this.saveEndPage = -1
    this.saveDialogController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: CustomContentDialog({
        primaryTitle: '保存帖子',
        contentBuilder: (): void => { this.saveThreadContent() },
        buttons: [
          { value: '取消' },
          {
            value: '保存',
            fontColor: AppColors.white,
            background: AppColors.primary,
            action: (): void => {
              // 官方对话框模板的按钮不支持动态 disabled，页范围合法性在提交时判定
              if (!this.saveRangeValid || this.saveStartPage < 1 || this.saveEndPage < this.saveStartPage) {
                appStore.showToast('页范围无效')
                return
              }
              this.startSaveThread(this.threadTid, this.saveStartPage, this.saveEndPage)
            }
          }
        ]
      }),
      autoCancel: true
    })
    this.saveDialogController?.open()
  }

  /** 保存帖子弹窗的自定义内容（官方 CustomContentDialog 的 contentBuilder）。 */
  @Builder
  saveThreadContent() {
    SaveThreadContent({
      tid: this.threadTid,
      initialSubject: this.threadSubject === '递进树' ? '' : this.threadSubject,
      onRangeChange: (canSave: boolean, startPage: number, endPage: number): void => {
        this.saveRangeValid = canSave
        this.saveStartPage = startPage
        this.saveEndPage = endPage
      }
    })
  }

  /**
   * 启动后台保存任务；结果以 Toast 提示（进度由全局指示组件展示）。
   *
   * @param tid - 主题 ID
   * @param startPage - 起始页
   * @param endPage - 结束页
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

  /**
   * 当前帖子是否正在跟踪（更多菜单「跟踪帖子更新」的激活态）。
   *
   * @returns 是否已跟踪
   */
  private isTrackingCurrentThread(): boolean {
    const version: number = this.trackedThreadVersion
    return version >= 0 && appStore.isThreadTracked(this.threadTid)
  }

  /**
   * 当前帖子的楼主昵称（添加跟踪时写入，避免检查回填前显示「未知作者」）。
   *
   * @returns 楼主昵称；未知时返回空串
   */
  private resolveThreadAuthorName(): string {
    for (let i: number = 0; i < this.allPosts.length; i++) {
      if (this.allPosts[i].lou === 0) {
        return this.allPosts[i].author
      }
    }
    return ''
  }

  /**
   * 打开「跟踪帖子更新」对话框（更多菜单入口）。
   */
  private openTrackDialog(): void {
    if (this.threadTid.length === 0) {
      return
    }
    if (!appStore.auth.isAuthenticated) {
      appStore.showToast('请先登录')
      return
    }
    const existing: TrackedThread | null = appStore.getTrackedThread(this.threadTid)
    const isTracked: boolean = existing !== null
    this.trackKeepDays = isTracked && existing !== null && existing.keepDays > 0
      ? existing.keepDays
      : TRACK_DEFAULT_KEEP_DAYS
    this.trackDialogController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: CustomContentDialog({
        primaryTitle: '跟踪帖子更新',
        contentBuilder: (): void => { this.trackContent() },
        buttons: [
          { value: '取消' },
          {
            value: isTracked ? '保存' : '开始跟踪',
            fontColor: AppColors.white,
            background: AppColors.primary,
            action: (): void => {
              this.startTrackThread()
            }
          }
        ]
      }),
      autoCancel: true
    })
    this.trackDialogController?.open()
  }

  /** 跟踪对话框的自定义内容（官方 CustomContentDialog 的 contentBuilder）。 */
  @Builder
  trackContent() {
    ThreadTrackContent({
      tid: this.threadTid,
      onKeepDaysChange: (days: number): void => {
        this.trackKeepDays = days
      },
      onStopTrack: (): void => {
        this.trackDialogController?.close()
        appStore.untrackThread(this.threadTid)
        appStore.showToast('已停止跟踪')
      }
    })
  }

  /**
   * 提交跟踪设置：未跟踪则新建，已跟踪则只更新跟踪天数（不动已读基准）。
   */
  private startTrackThread(): void {
    if (!appStore.canTrackMoreThreads() && !appStore.isThreadTracked(this.threadTid)) {
      appStore.showToast('最多同时跟踪 ' + String(TRACK_MAX_COUNT) + ' 个帖子')
      return
    }
    const request: TrackRequest = new TrackRequest()
    request.tid = this.threadTid
    // 标题占位值（'递进树'）不作为真实标题入库，交给检查回填
    request.subject = this.threadSubject === '递进树' ? '' : this.threadSubject
    request.author = this.resolveThreadAuthorName()
    request.authorid = Number(this.threadAuthorId) > 0 ? Number(this.threadAuthorId) : 0
    request.fid = this.threadFid
    request.forumName = ''
    request.keepDays = this.trackKeepDays
    appStore.trackThread(request).then((result: TrackResult): void => {
      if (result.ok) {
        appStore.showToast(result.created ? '已开始跟踪' : '跟踪设置已更新')
      } else {
        appStore.showToast(result.error || '跟踪失败')
      }
    })
  }

  /**
   * 帖子页打开被跟踪的帖子后推进已读基准（与列表页同一语义）。
   */
  private syncTrackedOnOpen(): void {
    if (this.threadTid.length === 0 || !appStore.auth.isAuthenticated) {
      return
    }
    if (!appStore.isThreadTracked(this.threadTid)) {
      return
    }
    appStore.markTrackedSeenOnOpen(this.threadTid).catch((error: Object): void => {
      logger.warn('跟踪已读推进失败 tid=%{public}s: %{public}s', this.threadTid, formatError(error))
    })
  }

  /**
   * 响应黑名单变化，即时刷新树内楼层的遮蔽标记（行组件订阅同一版本号，会自行重绘）。
   */
  private onBlacklistVersionChange(): void {
    applyBlacklistStateToPosts(this.allPosts, appStore.settingsStore.getBlacklistIds())
  }

  /**
   * 获取当前可显示的主题标题（楼主被屏蔽时与列表页同一占位文案）。
   *
   * @returns 可显示标题
   */
  private getVisibleThreadSubject(): string {
    if (this.blacklistVersion >= 0 && appStore.settingsStore.isBlacklisted(this.threadAuthorId)) {
      return '该用户已被屏蔽'
    }
    return this.threadSubject
  }

  // ==================== 握持状态 ====================

  /**
   * 握持状态变化回调：首次检测直接生效，后续变化带 300ms 动画过渡。
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

  // ==================== 标题滚动效果 ====================

  /**
   * 按 List 滚动偏移同步标题栏渐变进度。
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
   * 标题区渐变模糊的停靠点。
   *
   * @returns 停靠点数组
   */
  private getTitleBlurStops(): FractionStop[] {
    return TitleScrollEffect.getBlurStops(this.listViewportHeight, this.statusBarHeight)
  }

  // ==================== 菜单 ====================

  /**
   * 更多菜单项。
   *
   * 与列表页（`ThreadPanel.moreMenuItems`）**同序同构**，只有两处按阅读样式命名：
   * 「刷新帖子 / 刷新递进树」与「切换为递进树阅读 / 切换为列表阅读」。这样两页的
   * 多功能下拉在用户看来是同一个菜单，切换阅读方式不会丢掉收藏、离线保存、跟踪等入口。
   *
   * 顺序按「保存订阅 → 阅读视图 → 外部动作」三段：收藏 / 离线保存 / 跟踪 →
   * 只看楼主 / 切换阅读方式 / 刷新 → 从网页打开 / 分享。刷新固定在本组末尾——
   * 树页「刷新递进树」要**重抓全帖**（4 路并发 + 限流，长帖可达数十秒，期间整页为加载态），
   * 是本菜单里代价最大的动作，不能紧跟在高频的「跟踪」下方，避免误触。
   * 部分数据不提供「补齐剩余页」：用户用「刷新递进树」整帖重抓，不引入断点续传。
   *
   * 回调一律写成**箭头函数**：菜单项在 `PanelNavBar` 实例上渲染，只有箭头函数才能把
   * `this` 固定在本组件上（见 `NavBarMenuItem` 的说明）。
   *
   * @returns 菜单项
   */
  private moreMenuItems(): NavBarMenuItem[] {
    const items: NavBarMenuItem[] = []
    items.push({
      label: this.getFavoriteMenuLabel(),
      action: (): void => {
        this.openFavoriteFolders()
      }
    })
    items.push({
      label: '离线保存帖子',
      action: (): void => {
        this.openSaveThreadDialog()
      }
    })
    items.push({
      label: '跟踪帖子更新',
      active: this.isTrackingCurrentThread(),
      action: (): void => {
        this.openTrackDialog()
      }
    })
    items.push({
      label: '只看楼主',
      active: this.authorOnly,
      action: (): void => {
        this.toggleAuthorOnly()
      }
    })
    items.push({
      label: '切换为列表阅读',
      action: (): void => {
        this.replaceWithListReading()
      }
    })
    // 刷新排在阅读视图组末尾（理由见方法头：树页刷新是全帖重抓，代价最大）
    items.push({
      label: '刷新递进树',
      action: (): void => {
        this.loadTree(true)
      }
    })
    items.push({
      label: '从网页打开',
      action: (): void => {
        const threadUrl: string = getActiveDomain() + '/read.php?tid=' + this.threadTid
        routerStore.navigateActivity(Screen.webview(threadUrl))
      }
    })
    items.push({
      label: '分享帖子',
      action: (): void => {
        let hostCtx: Context | undefined = this.getUIContext().getHostContext()
        if (hostCtx !== undefined) {
          let ctx: Context = hostCtx
          shareThread(ctx, Number(this.threadTid), this.threadSubject)
        }
      }
    })
    return items
  }

  /**
   * 切换「只看楼主」：用过滤后的楼层重建树，尽量停留在当前中心楼层。
   */
  private toggleAuthorOnly(): void {
    if (!this.hasThreadAuthorKey) {
      appStore.showToast('无法识别楼主，暂不支持只看楼主')
      return
    }
    const anchorPid: number = this.currentCenterPid()
    this.authorOnly = !this.authorOnly
    // 树尚未就绪（首次加载/刷新中）：只更新状态，加载完成时按新状态建树
    if (!this.treeReady || this.treeModel === null) {
      return
    }
    this.rebuildTree()
    if (!this.listMounted) {
      return
    }
    if (anchorPid >= 0) {
      const index: number = this.treeDataSource.findIndexByPid(anchorPid)
      if (index >= 0) {
        this.scroller.scrollToIndex(index, false, ScrollAlign.CENTER)
        return
      }
    }
    this.scroller.scrollToIndex(0, false, ScrollAlign.START)
  }

  /**
   * 终止递进树工作并切换为列表阅读。
   *
   * 更多菜单「切换为列表阅读」与加载态「以常规列表打开」共用：
   * 1. 先 `cancelWork()`：取消在途抓取并推进抓取代际，在途页结果不再提交任何状态；
   * 2. 再 `navigateActivity(screen, true)` **原地替换**当前栈条目——递进树条目随替换移除、
   *    页面实例销毁，栈里只保留列表页一种阅读样式，返回不会退回递进树。
   *
   * **不携带树内楼层**：列表页恢复它自己的 `reading_progress`（与树页的
   * `tree_reading_progress` 分离）；只透传「只看楼主」、楼主身份与路由来源，
   * 保证过滤状态与来源语义（阅读进度恢复白名单等）一致。
   */
  private replaceWithListReading(): void {
    // 替换发生在下一帧；先终止抓取，避免在途页结果提交到即将销毁的组件
    this.cancelWork()
    routerStore.navigateActivity(
      Screen.threadList(this.threadTid, this.authorOnly, this.threadAuthorId, this.threadAuthorKey,
        this.threadSource),
      true
    )
  }

  // ==================== UI ====================

  build() {
    Stack() {
      Column() {
        if (this.isLoading) {
          this.LoadingState()
        } else if (this.hasError) {
          this.ErrorState()
        } else if (this.treeReady) {
          this.TreeList()
        }
      }
      .width('100%').height('100%')

      PanelNavBar({
        title: this.getVisibleThreadSubject(),
        rightIcon: $r('app.media.icon_more'),
        scrollEffectProgress: this.titleScrollEffectProgress,
        hasMenu: true,
        menuItemsProvider: (): NavBarMenuItem[] => this.moreMenuItems()
      })
        .width('100%').position({ x: 0, y: 0 })

      if (this.treeReady && !this.isLoading) {
        this.BottomBar()
      }
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg).alignContent(Alignment.BottomEnd)
  }

  /**
   * 全帖抓取中的加载态：进度 + 三种出口。
   *
   * 三个操作是**并列的三种意图**（不是主次按钮堆叠）：
   * 1. 「查看已加载 n/N 页」——中断抓取，把已经拿到的楼层送进树（数据没白等）；
   * 2. 「取消」——放弃这次阅读并退出（递进树条目替代了列表页，没有「原视图」可退，
   *    取消即返回上一层，见 {@link cancelLoadingAndExit}）；
   * 3. 「以常规列表打开」——换一种阅读样式，重新从列表页加载（见 {@link replaceWithListReading}）。
   *
   * 第 1 页尚未返回时（`progressDone = 0`）「查看已加载」禁用：此时没有可展示的数据，
   * 但按钮保留在原位，避免布局跳动。取消与切列表在总页数未知时同样可用——首屏请求
   * 也可能卡满超时，不能只在拿到 totalPages 之后才允许退出。
   *
   * 请求取消后（`interrupting`）收起三个按钮、显示「正在中断加载…」：在途请求没有真正的
   * 中止手段，服务要等当前批次收尾，重复点击没有意义。
   */
  @Builder
  LoadingState() {
    Column() {
      LoadingStateView()
      Column({ space: 10 }) {
        if (this.progressTotal > 0) {
          Text('正在加载全部楼层 ' + String(this.progressDone) + '/' + String(this.progressTotal) + ' 页')
            .fontSize(14).fontColor(AppColors.textSecondary)
          Progress({
            value: this.progressDone,
            total: this.progressTotal,
            type: ProgressType.Linear
          })
            .width(180).height(4)
            .color(AppColors.primary)
            .borderRadius(2)
        } else {
          Text('正在加载帖子…')
            .fontSize(14).fontColor(AppColors.textSecondary)
        }
        // 动作区固定高度：中断态只显示一行提示，若不占位会让整块内容在「点中断」瞬间
        // 上下跳动；高度按「主按钮 32 + 间距 10 + 次级行 26」取 68
        Column({ space: 10 }) {
          if (this.interrupting) {
            Row({ space: 8 }) {
              LoadingProgress().width(16).height(16).color(AppColors.textTertiary)
              Text('正在中断加载…').fontSize(13).fontColor(AppColors.textSecondary)
            }
            .height(32)
          } else {
            Button(this.viewLoadedLabel())
              .fontSize(14).height(32).padding({ left: 16, right: 16 })
              .backgroundColor(this.canViewLoaded() ? AppColors.primary : AppColors.bgSecondary)
              .fontColor(this.canViewLoaded() ? AppColors.white : AppColors.textSecondary)
              .enabled(this.canViewLoaded())
              .onClick((): void => {
                this.beginViewLoaded()
              })
            Row({ space: 8 }) {
              Text('取消')
                .fontSize(14).fontColor(AppColors.destructive)
                .padding({ top: 6, bottom: 6, left: 12, right: 12 })
                .onClick((): void => {
                  this.cancelLoadingAndExit()
                })
              Text('以常规列表打开')
                .fontSize(14).fontColor(AppColors.primary)
                .padding({ top: 6, bottom: 6, left: 12, right: 12 })
                .onClick((): void => {
                  this.replaceWithListReading()
                })
            }
          }
        }
        .height(68)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
      .margin({ top: 20 })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%').layoutWeight(1)
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .padding({ top: NAV_BAR_H + this.statusBarHeight })
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
  }

  /**
   * 加载失败态：原因 + 重试；失败前已抓到楼层时追加「查看已加载」。
   *
   * 部分结果不自动提交（残缺树会让人误以为帖子就这些），但也不丢弃——
   * 由用户主动选择是否先读已抓到的部分。
   */
  @Builder
  ErrorState() {
    Column() {
      ErrorStateView({
        msg: this.errorMsg,
        onRetry: (): Promise<void> => {
          this.loadTree(true)
          return Promise.resolve()
        }
      })
      if (this.hasPartialFallback) {
        Button('查看已加载的 ' + String(this.partialLoadedPages) + '/' +
          String(this.partialTotalPages) + ' 页')
          .fontSize(13).height(30).padding({ left: 14, right: 14 })
          .backgroundColor(AppColors.bgSecondary)
          .fontColor(AppColors.textPrimary)
          .margin({ top: 8 })
          .onClick((): void => {
            this.commitFailedPartial()
          })
      }
    }
    .width('100%').layoutWeight(1)
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .padding({ top: NAV_BAR_H + this.statusBarHeight })
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
  }

  /**
   * 「查看已加载」按钮文案（总页数已知时带上进度）。
   *
   * @returns 按钮文案
   */
  private viewLoadedLabel(): string {
    if (this.progressTotal > 0) {
      return '查看已加载 ' + String(this.progressDone) + '/' + String(this.progressTotal) + ' 页'
    }
    if (this.progressDone > 0) {
      return '查看已加载 ' + String(this.progressDone) + ' 页'
    }
    return '查看已加载'
  }

  /**
   * 是否已有可提交的楼层（第 1 页返回后才可能出现）。
   *
   * @returns 可点击「查看已加载」时为 true
   */
  private canViewLoaded(): boolean {
    return this.progressDone > 0
  }

  /**
   * 根节点行：完整楼层卡片（与自然列表同一套 PostItem）。
   *
   * @param post - 楼层
   * @param displayContent - 树模式正文（已剥离引用区）
   */
  @Builder
  postCell(post: PostInfo, displayContent: string) {
    PostItem({
      post: post,
      displayContent: displayContent,
      showContent: displayContent.length > 0,
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
        this.openFloorReply(p)
      },
      onEdit: (p: PostInfo): void => {
        this.openEdit(p)
      },
      onShare: (p: PostInfo): void => {
        let hostCtx: Context | undefined = this.getUIContext().getHostContext()
        if (hostCtx !== undefined) {
          let ctx: Context = hostCtx
          sharePost(ctx, p, this.threadSubject)
        }
      },
      onSummarize: (p: PostInfo): void => {
        this.beginAiSummarize(p)
      },
      onReadAloud: (p: PostInfo): void => {
        this.readAloud(p, displayContent)
      },
      isTopicAuthor: this.isTopicAuthorPost(post),
      isOwnPost: appStore.auth.isAuthenticated && String(post.authorid) === appStore.auth.uid,
    })
  }

  /**
   * 两层树列表（独立 List / 数据源，不参与任何分页窗口）。
   */
  @Builder
  TreeList() {
    List({ scroller: this.scroller }) {
      LazyForEach(this.treeDataSource, (row: ThreadTreeRow) => {
        ListItem() {
          if (row.kind === ThreadTreeRowKind.ROOT && row.post !== null) {
            this.postCell(row.post, row.displayContent)
          } else if (row.kind === ThreadTreeRowKind.CHILD && row.post !== null) {
            ThreadTreeChildItem({
              child: this.buildTreeChild(row),
              targetLou: this.targetLou(row.ref),
              displayContent: row.displayContent,
              showContent: row.displayContent.length > 0,
              showReplyTo: row.showReplyTo,
              isVotedUp: this.votedUpPids.has(String(row.post.pid)),
              isVotedDown: this.votedDownPids.has(String(row.post.pid)),
              holdingHand: this.holdingStatus,
              isTopicAuthor: this.isTopicAuthorPost(row.post),
              isOwnPost: appStore.auth.isAuthenticated && String(row.post.authorid) === appStore.auth.uid,
              highlight: row.highlighted,
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
              onJumpToPid: (pid: number): void => {
                this.treeJumpToPid(pid)
              },
              onVote: (p: PostInfo, value: number): Promise<VoteResult> => {
                return this.handleVote(p, value)
              },
              onReply: (p: PostInfo): void => {
                this.openFloorReply(p)
              },
              onEdit: (p: PostInfo): void => {
                this.openEdit(p)
              },
              onShare: (p: PostInfo): void => {
                let hostCtx: Context | undefined = this.getUIContext().getHostContext()
                if (hostCtx !== undefined) {
                  let ctx: Context = hostCtx
                  sharePost(ctx, p, this.threadSubject)
                }
              },
              onSummarize: (p: PostInfo): void => {
                this.beginAiSummarize(p)
              },
              onReadAloud: (p: PostInfo): void => {
                this.readAloud(p, row.displayContent)
              },
            })
          } else {
            ThreadTreeMoreItem({
              totalCount: row.totalCount,
              onExpand: (): void => {
                this.expandTreeRoot(row.rootPid)
              }
            })
          }
        }
      }, (row: ThreadTreeRow) => this.rowKey(row))
      this.LoadEndFooter()
    }
    .width('100%').layoutWeight(1)
    .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .cachedCount(6)
    // 折叠行展开（整体 replaceAll）时保持可见内容位置，避免插入子行后视口跳动
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
      /* 正文图的识图选取态不允许跨滚动存活（与列表页一致）：系统在滚动过程中只是把文本
         菜单临时收起、松手又放出来，只有主动拆掉分析器才收得干净。详见
         `common/media/ImageAnalyzerSession.ets`。 */
      dismissAnalyzerSessions()
    })
    .onScrollIndex((start: number, _end: number, center: number): void => {
      this.lastScrollStart = start
      this.lastScrollCenter = center
      // 树内阅读进度：以视口中心行为锚点（与恢复时的居中定位同源对称）
      this.scheduleProgressRecord()
    })
    .onAppear((): void => {
      this.listMounted = true
      this.syncTitleScrollEffect()
      this.scheduleNavigation()
    })
    .onDisAppear((): void => {
      this.listMounted = false
    })
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
  }

  /**
   * 列表尾部提示（与列表页 `LoadMoreFooter` 的完成态文案一致）。
   *
   * 树页一次性抓完全帖，不存在「加载更多」的中间态；到达末尾即在最后一行下方
   * 明确提示已到结尾，避免用户继续下拉等待不存在的分页。
   *
   * 两种不完整情况都在这条常驻行里表达（读完全程时一定看得见）：
   * - 部分数据（中断/失败后查看已加载）：文案给出已加载范围；
   * - 有缺页（服务端空页）：把缺页信息并入文案（Toast 会被后续提示覆盖）。
   */
  @Builder
  LoadEndFooter() {
    ListItem() {
      Column() {
        Row() {
          Text(this.loadEndText()).fontSize(13).fontColor(AppColors.textTertiary)
        }
        .width('100%').justifyContent(FlexAlign.Center)
      }
      .width('100%').height(NAV_BAR_H).justifyContent(FlexAlign.Center)
    }
  }

  /**
   * 列表尾部文案：部分数据时给已加载范围并附缺页提示，完整时给完成文案。
   *
   * 缺页提示在这里也要保留：Toast 是单条替换语义、会被后续提示覆盖，
   * 尾部是读完最后一行时唯一还能看到的常驻位置。
   *
   * @returns 尾部文案
   */
  private loadEndText(): string {
    if (this.partialData) {
      const progress: string = '已加载 ' + String(this.partialLoadedPages) +
        '/' + String(this.partialTotalPages) + ' 页'
      if (this.skippedPageHint.length > 0) {
        return progress + '（' + this.skippedPageHint + '）'
      }
      return progress
    }
    if (this.skippedPageHint.length === 0) {
      return '已加载全部回复'
    }
    return '已加载全部回复（' + this.skippedPageHint + '）'
  }

  /**
   * 底部悬浮回复按钮（回复主题）。
   */
  @Builder
  BottomBar() {
    Row({ space: 8 }) {
      HdsMaterialHost({
        barWidth: 40,
        barHeight: 40,
        onTap: (): void => {
          this.openThreadReply()
        }
      }) {
        Stack() {
          Image($r('app.media.icon_reply'))
            .width(20).height(20).fillColor(UIMaterialManager.adaptiveForeground)
            .draggable(false)
        }
        .width('100%').height('100%').alignContent(Alignment.Center)
      }
    }
    .width('100%').padding({ left: 16, right: 16, bottom: 16 + this.navBarHeight })
    .justifyContent(this.holdingStatus === HoldingHandStatus.LEFT_HAND_HELD ? FlexAlign.Start : FlexAlign.End)
  }
}
