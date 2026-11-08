import { display, CustomContentDialog, LengthMetrics } from '@kit.ArkUI'
import { common, Context } from '@kit.AbilityKit'

import { appStore } from '../store/AppStore'
import { AiAgentPreset, PRESET_ENTRY_THREAD } from '../model/AiAgentPreset'
import { routerStore, Screen, ThreadSource } from '../store/RouterStore'
import { votePost } from '../service/api/FavoriteApi'
import { getActiveDomain } from '../service/api/MiscApi'
import { ThreadResult } from '../model/ThreadResult'
import type { PostReplyResult } from '../model/ThreadResult'
import type { ThreadInfo } from '../model/Thread'
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
  findRootPidByPid,
  needsRootQuoteContext,
  resolveFloorSubject
} from '../common/utils/ThreadTreeBuilder'
import { threadTreeFetchService, ThreadTreeFetchResult, ThreadTreeCommit } from '../service/ThreadTreeFetchService'
import { ThreadTreeDataSource } from '../common/datasource/ThreadTreeDataSource'
import {
  LocateSource,
  LocateState,
  LocateTarget,
  TreeBannerMode,
  TreePagePhase
} from '../model/ThreadTreeLocate'
import {
  canActivateTarget,
  canOverrideTarget,
  decideTargetState,
  formatCompactProgress,
  formatLoadingText,
  formatTargetLabel,
  formatWaitTargetText,
  resolveBannerMode,
  shouldShowBanner
} from '../common/utils/ThreadTreeLocatePolicy'
import {
  computeTreeRowDiff,
  RowDiffResult
} from '../common/utils/ThreadTreeRowDiff'
import {
  mergeTreePage,
  LocalMergeResult,
  MergePageDecision,
  resolveMergePage
} from '../common/utils/ThreadTreeLocalMerge'

const logger = new Logger(DOMAIN_UI, 'ThreadTreePanel')

/** 根节点跨重建保留的状态（展开态与展开代际）。 */
class RootState {
  expanded: boolean = false
  rev: number = 0
}

/** 增量提交前的视口锚点（插入到锚点之前时用于补偿）。 */
class RowAnchor {
  valid: boolean = false
  pid: number = -1
  oldIndex: number = -1
  offset: number = 0
}

/** 提交类型：决定回复/编辑成功后局部刷新抓哪一页。 */
class TreeSubmitKind {
  /** 楼层回复 / 主题回复：新楼层必在末页 */
  static readonly REPLY: number = 0
  /** 编辑：被编辑楼层在其所属页 */
  static readonly EDIT: number = 1
}

/**
 * 一次「提交成功」的上下文（回复与编辑共用同一套局部刷新流程）。
 *
 * 只承载**已有的事实**（服务端返回的新 pid、编辑目标 pid、提交正文），
 * 不含任何对楼层号/正文的猜测——局部合并的数据一律来自服务端那一页。
 */
class TreeSubmitContext {
  /** 提交类型，见 {@link TreeSubmitKind} */
  kind: number = TreeSubmitKind.REPLY

  /** 服务端返回的新楼层 pid（回复；响应未携带时为 0） */
  newPid: number = 0

  /** 编辑目标楼层 pid（编辑；回复为 0） */
  editPid: number = 0

  /** 用户提交的正文（编辑的旧缓存保护用；其余场景空串） */
  text: string = ''

  /** 成功提示文案 */
  toast: string = ''
}

/**
 * 进入阶段加载态的延迟淡入时间（ms）。
 *
 * 与列表页（`ThreadPanel.loadPosts` 的 REPLACE 分支）同一节奏：第 1 页在 400ms 内
 * 到达时（含 90 秒缓存命中）用户直接看到内容，不会先闪一下 loading；超过才淡入。
 */
const ENTERING_LOADING_DELAY_MS: number = 400

/**
 * 点击「停止」后「正在停止…」的展示时长（ms）。
 *
 * 冻结与取消是同步的（不等在途请求），这道延迟只给点击一个**可见反馈**：胶囊先变
 * 「正在停止…」，随后转入常驻 `LOADED`（`12/29`）。过渡期间不接受任何提交。
 */
const TREE_STOP_SETTLE_MS: number = 300


/**
 * 进度胶囊的 HDS 材质块尺寸、间距与字号（vp）。
 *
 * 与列表页右下角页码指示器**同款**（`ThreadPanel.PAGE_BAR_*`）：材质块高 40（与回复按钮等高、
 * 底边对齐，真机实测见 `docs/IMMERSIVE_LIGHT_DESIGN.md` §12.9），两端内边距 10，内容再做
 * -4vp 垂直补偿（HDS 内容区与材质块不同心）。
 *
 * **间距全部显式**：图标 / 数字 / 动作之间统一 `TREE_BANNER_GAP`；数字宽度由
 * `MeasureUtils.measureText` 实测（不是估算），材质块宽度 = 各段相加，内容正好铺满。
 */
const TREE_BANNER_H: number = 40
const TREE_BANNER_PAD: number = 10
const TREE_BANNER_CONTENT_OFFSET_Y: number = -4
const TREE_BANNER_FONT: number = 14
/** 加载图标（`LoadingProgress`）与失败前缀 `!` 的宽度。 */
const TREE_BANNER_ICON_W: number = 14
/** 图标 / 数字 / 动作之间的统一间距。 */
const TREE_BANNER_GAP: number = 6
/** 停止图标尺寸（同时也是它占用的行内布局宽度，视觉间距因此精确等于 GAP）。 */
const TREE_BANNER_STOP_ICON: number = 16
/** 「重试」文字宽度（2 个 14fp 汉字）；布局宽 = 文字宽，视觉间距同样精确等于 GAP。 */
const TREE_BANNER_RETRY_W: number = 28
/**
 * 动作触摸区边长（vp）：布局宽只取图标/文字的实际宽度（保证视觉间距精准），
 * 热区用 `responseRegion` 外扩到 40×40，不参与布局。
 */
const TREE_BANNER_TOUCH: number = 40

/**
 * 帖子「两层递进树」阅读页面（与列表页互斥的独立页面组件）。
 *
 * 与自然列表页（ThreadPanel）**数据隔离**：本页面自己抓取全帖、自己展示加载进度、
 * 自己持有树模型与数据源，不读写 ThreadPanel 的分页窗口，也不与其共享渲染状态。
 * 但**功能面与列表页对齐**（`docs/THREAD_TREE_DESIGN.md` §3.6）：
 * 更多菜单与列表页同构（收藏 / 离线保存 / 跟踪 / 只看楼主 / 切换阅读方式 /
 * 从网页打开 / 分享），并各自维护阅读记录与阅读进度。
 *
 * 进入方式（两种阅读样式**互斥**，切换一律用 `navigateActivity(screen, true)` 原地替换栈条目）：
 * - 列表页更多菜单「切换为递进树阅读」：替换当前列表页（列表页实例随替换销毁），
 *   返回直接回主题列表，不会再退回列表阅读；
 * - 设置「帖子默认样式 = 递进树」：打开帖子时直接挂载本页（仍是同一个 `Screen.thread` 条目）；
 * - 本页「切换为列表阅读」：终止全帖抓取并替换为列表页（加载中也可用，见更多菜单）。
 *
 * 全帖抓取可能持续数十秒（4 路并发 + 限流）。本页采用**增量加载**
 * （`docs/THREAD_TREE_INCREMENTAL_LOAD_DESIGN.md`）：
 * - 第 1 页到达即渲染，后续按页号顺序增量追加；
 * - 加载期间底部进度胶囊（与列表页页码条同款 HDS 材质）显示 `n/N` + 停止，可随时停止；
 *   **胶囊只做进度，不承载定位动作**；
 * - 定位（恢复进度 / 路由 pid / 点击未加载楼层）统一为「待定位目标」，到达后由 Toast
 *   提供「前往查看」；未到达时不提供任何跳转动作；
 * - 失败时保留已渲染内容 + 错误条；第 1 页到达前的加载屏与列表页同构（只有居中加载圈，
 *   400ms 延迟淡入，无任何页内出口，退出走返回键）。
 *
 * 部分数据**不做断点续传、也不挂常驻提醒**：停止是用户自己的决定，不再重复告知；
 * 只在列表尾部用一句中性的「已加载 n/N 页」标识内容边界（替代「已加载全部回复」）。
 * 想拿全内容可重新进入帖子整帖重抓（内容已可见时的失败态也提供重试）。
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

  /** 抓取失败原因（错误态文案 / 错误条文案）。 */
  @State errorMsg: string = ''
  /** 抓取进度：总页数（第 1 页返回后确定；`formatLoadingText` 的兜底值）。 */
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
   * 当前树是否只覆盖**部分页**（用户主动停止，或某页失败但已有内容可读）。
   *
   * 刻意**不做常驻提醒**：中断是用户自己的操作，页面上不再挂横幅/弹 Toast；
   * 这个标志只用于两件事：
   * 1. 列表尾部把「已加载全部回复」换成中性的「已加载 n/N 页」（内容边界，不是警告）；
   * 2. 树内跳转/阅读进度恢复找不到楼层时，把「不存在」改述为「不在已加载页内」。
   *
   * 不提供断点续传：补齐内容只能重新进入帖子整帖重抓（或走错误态重试）。
   */
  @State partialData: boolean = false
  /** 部分数据下已覆盖页数（与服务端总页数共同构成 n/N）。 */
  @State partialLoadedPages: number = 0
  /** 部分数据下的服务端总页数。 */
  @State partialTotalPages: number = 0
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

  // ==================== 增量加载（docs/THREAD_TREE_INCREMENTAL_LOAD_DESIGN.md） ====================

  /** 页面加载阶段，见 `TreePagePhase`。 */
  @State phase: number = TreePagePhase.ENTERING
  /** 已提交页数（连续前缀）：页面可见内容的边界。 */
  @State committedPages: number = 0
  /** 是否正在停止（点了停止、等待收尾的短暂过渡）。 */
  @State stopping: boolean = false
  /** 进度胶囊当前状态，见 `TreeBannerMode`。 */
  @State bannerMode: number = TreeBannerMode.HIDDEN
  /** 胶囊是否可见（叠加 300ms 延迟门禁后的结果）。 */
  @State bannerVisible: boolean = false
  /** 目标状态，见 `LocateState`。 */
  @State targetState: number = LocateState.NONE
  /** 目标展示标签（「上次阅读位置」/「第 812 楼」）。 */
  @State targetLabel: string = ''
  /**
   * 进入阶段加载态的不透明度（与列表页 `ThreadPanel.loadingContentOpacity` 同构）。
   *
   * `ENTERING` 从 0 开始，400ms 后仍在加载才淡入：第 1 页（含 90 秒缓存命中）在 400ms
   * 内到达时用户直接看到内容，不会先闪一下 loading。离开 `ENTERING` 后由 `phase` 门禁
   * 停止渲染，数值留待下次 `loadTree` 重置。
   */
  @State enteringLoadingOpacity: number = 0
  /** 本次加载失败原因（错误条文案）。 */
  @State bannerErrorText: string = ''
  /**
   * 胶囊数字区的实测宽度（vp，`MeasureUtils.measureText`）。
   *
   * 按**当前文本**（`committed/total`）测量：数字与停止图标之间恒定 `GAP`，不预留未来位数
   * （预留会让 `8/5138` 这类早期进度右侧空出一段）。测量失败（UI 上下文未就绪）时由
   * {@link bannerTextWidth} 按字符类型兜底，不会出现宽度为 0 的胶囊。
   */
  @State bannerTextW: number = 0
  /** 上次测量用的文本（同一文本不重复测量；测量失败不缓存，下次重试）。 */
  private bannerMeasuredText: string = ''

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
  /** 是否等待 List 挂载后定位（保留给「前往」前的挂载判定）。 */
  private navigationPending: boolean = false
  /** 高亮清除计时器。 */
  private highlightTimer: number = -1
  /** 当前高亮楼层 pid。 */
  private highlightPid: number = 0
  /** 抓取代际：刷新/销毁时递增，使旧结果失效。 */
  private fetchGeneration: number = 0
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
  /** 当前帖子的树内进度恢复是否已经处理过（防止刷新时重复恢复）。 */
  private readingResumeHandled: boolean = false
  /** `onScrollIndex` 最近上报的视口中心行下标（进度锚点取中心行）。 */
  private lastScrollCenter: number = 0
  /** `onScrollIndex` 最近上报的首个可见行下标（判断用户是否已开始阅读）。 */
  private lastScrollStart: number = 0

  // ==================== 增量加载内部状态 ====================

  /** 当前待定位目标（同一时刻只有一个）。 */
  private pendingTarget: LocateTarget | null = null
  /** 停止/失败后冻结：迟到的结果不得再提交。 */
  private frozen: boolean = false
  /** 用户是否真正移动过视口（手势滚动或点过「前往」）：进度记录的必要条件。 */
  private viewportMoved: boolean = false
  /** 是否有一次增量提交已排程（合并同一宏任务内的多次回调）。 */
  private commitScheduled: boolean = false  /** 待提交的楼层前缀（服务层 collected 的同一引用）。 */
  private pendingCommitPosts: PostInfo[] = []
  /** 待提交的已提交页数。 */
  private pendingCommitPages: number = 0
  /** 待提交载荷里的主题元数据。 */
  private pendingCommitThreadInfo: ThreadInfo | null = null
  /** 待提交载荷里的版块名。 */
  private pendingCommitForumName: string = ''
  /** 待提交载荷里的服务端总楼层数（写浏览历史用）。 */
  private pendingCommitTotalRows: number = 0
  /** 是否因滚动/定位事务推迟了提交。 */
  private commitDeferred: boolean = false
  /** 用户是否正在拖拽/惯性滚动（期间不提交，避免插入行打断手势）。 */
  private scrolling: boolean = false
  /** 全量楼层 pid 集合（未过滤，判定目标是否「被只看楼主过滤」用）。 */
  private allPids: Set<number> = new Set<number>()

  /** 就绪 Toast 的延时器。 */
  private targetToastTimer: number = -1
  /** 就绪 Toast 因用户正在滚动而挂起（`onScrollStop` 补发）。 */
  private targetToastPending: boolean = false
  /** 挂起的 Toast 是否是「查看全部」（只看楼主过滤）。 */
  private targetToastFiltered: boolean = false
  /** 排程提交的定时器（刷新/切帖时必须能取消）。 */
  private commitTimer: number = -1
  /** 停止过渡计时器：「正在停止…」→ `STOPPED`（`LOADED`）。切页/刷新时取消。 */
  private stopSettleTimer: number = -1
  /** 用户主动停止：收尾结果只记日志，不再改状态。 */
  private stoppedByUser: boolean = false
  /** 进入阶段加载态延迟淡入计时器（400ms；离开 `ENTERING` 后回调自然作废）。 */
  private enteringLoadingTimer: number = -1
  /** 锚点事务：是否待恢复。 */
  private appendAnchorPending: boolean = false
  /** 锚点事务：锚点楼层 pid。 */
  private appendAnchorPid: number = -1
  /** 锚点事务：锚点行相对视口顶部的偏移。 */
  private appendAnchorOffset: number = 0
  /** 锚点事务：已安排恢复任务。 */
  private appendAnchorScheduled: boolean = false
  /** 最后一次提交前的行序列（diff 用）。 */
  private lastRows: ThreadTreeRow[] = []
  /** 锚点补偿中（抑制进度记录与「用户已滚动」）。 */
  private compensating: boolean = false

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
    clearTimeout(this.enteringLoadingTimer)
    this.enteringLoadingTimer = -1
    clearTimeout(this.targetToastTimer)
    this.targetToastTimer = -1
    clearTimeout(this.commitTimer)
    this.commitTimer = -1
    clearTimeout(this.stopSettleTimer)
    this.stopSettleTimer = -1
    this.commitScheduled = false
    this.targetToastPending = false
    this.appendAnchorPending = false
    this.appendAnchorScheduled = false
    // 使在途的定位目标失效：页面销毁后不得再定位
    this.pendingTarget = null
    this.targetState = LocateState.NONE
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
    if (this.highlightTimer >= 0) {
      clearTimeout(this.highlightTimer)
      this.highlightTimer = -1
    }
    this.highlightPid = 0
    this.readingResumeHandled = false
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
    // 增量状态：切帖必须整体归零，避免旧目标/旧行序列污染新帖
    this.pendingTarget = null
    this.targetState = LocateState.NONE
    this.targetLabel = ''
    this.lastRows = []
    this.allPids = new Set<number>()
    this.pendingCommitPosts = []
    this.pendingCommitPages = 0
    this.commitScheduled = false
    this.commitDeferred = false
    clearTimeout(this.commitTimer)
    this.commitTimer = -1
    clearTimeout(this.stopSettleTimer)
    this.stopSettleTimer = -1
    clearTimeout(this.targetToastTimer)
    this.targetToastTimer = -1
    this.targetToastPending = false
    this.frozen = false
    this.stopping = false
    this.stoppedByUser = false
    this.viewportMoved = false
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
    this.frozen = true
    threadTreeFetchService.cancel(this.treeOwner)
    this.navigationPending = false
    this.commitScheduled = false
    this.commitDeferred = false
    this.appendAnchorPending = false
    this.appendAnchorScheduled = false
    clearTimeout(this.commitTimer)
    this.commitTimer = -1
    clearTimeout(this.stopSettleTimer)
    this.stopSettleTimer = -1
    clearTimeout(this.enteringLoadingTimer)
    this.enteringLoadingTimer = -1
    clearTimeout(this.targetToastTimer)
    this.targetToastTimer = -1
    this.targetToastPending = false
    if (this.highlightTimer >= 0) {
      clearTimeout(this.highlightTimer)
      this.highlightTimer = -1
    }
    this.highlightPid = 0
    this.listMounted = false
  }

  // ==================== 加载 ====================

  /**
   * 加载全帖并增量建树（页面进入、错误态重试、回复后刷新共用）。
   *
   * 增量模型下本方法只负责「重置 + 启动」：第 1 页到达后由 {@link onFetchCommit}
   * 立即建树，后续页按水位继续提交；全部结束（或停止/失败）时由 {@link finishFetch}
   * 收尾。不再有「看完整个加载态再一次性建树」。
   *
   * @param keepSubject - 是否保留当前标题（刷新场景）；同时作为 `forceRefresh`
   *   传给抓取服务：刷新/重试必须绕过短时缓存，首次进入允许复用缓存（90 秒内秒开）
   */
  private loadTree(keepSubject: boolean): void {
    this.fetchGeneration++
    const generation: number = this.fetchGeneration
    clearTimeout(this.progressRecordTimer)
    this.progressRecordTimer = -1

    clearTimeout(this.targetToastTimer)
    this.targetToastTimer = -1
    clearTimeout(this.commitTimer)
    this.commitTimer = -1
    clearTimeout(this.stopSettleTimer)
    this.stopSettleTimer = -1
    this.targetToastPending = false
    this.stoppedByUser = false
    this.stopping = false
    this.frozen = false
    this.commitScheduled = false
    this.commitDeferred = false
    this.scrolling = false
    this.compensating = false
    this.appendAnchorPending = false
    this.appendAnchorScheduled = false
    this.appendAnchorPid = -1
    this.appendAnchorOffset = 0
    this.pendingCommitPosts = []
    this.pendingCommitPages = 0
    this.lastRows = []
    this.allPids = new Set<number>()
    this.viewportMoved = false
    this.readingResumeHandled = false
    this.bannerErrorText = ''
    this.bannerVisible = false
    this.bannerMode = TreeBannerMode.HIDDEN
    this.bannerTextW = 0
    this.bannerMeasuredText = ''
    this.phase = TreePagePhase.ENTERING
    this.committedPages = 0
    if (this.pendingTarget === null) {
      this.targetState = LocateState.NONE
      this.targetLabel = ''
    } else {
      // 刷新保留了目标：状态重判（胶囊只显示进度，不画目标刻度）
      this.targetState = LocateState.WAITING
    }
    if (this.threadTid.length === 0) {
      threadTreeFetchService.cancel(this.treeOwner)
      // 没有 tid 不可能有内容：直接落错误态，不能停在 ENTERING 的加载屏上
      this.phase = TreePagePhase.FAILED
      this.errorMsg = '缺少帖子 ID'
      return
    }
    this.registerEnteringTarget(generation)
    // 刷新场景：记住当前中心楼层，作为「刷新前的位置」目标（不覆盖已有目标）
    const refreshAnchorPid: number = keepSubject ? this.currentCenterPid() : -1
    if (refreshAnchorPid >= 0) {
      this.registerTarget(refreshAnchorPid, -1, -1, LocateSource.RESUME, true)
    }
    const fetchTid: string = this.threadTid
    this.errorMsg = ''
    this.progressTotal = 0
    // 进入阶段的加载屏与列表页同节奏：400ms 后才淡入，快路径不闪
    this.resetEnteringLoading()
    this.treeReady = false
    this.treeDataSource.clear()
    // 上一轮的缺页/部分数据提示属于旧结果：新一轮抓取重新判定
    this.skippedPageHint = ''
    this.partialData = false
    this.partialLoadedPages = 0
    this.partialTotalPages = 0
    logger.info('tree-panel load start tid=%{public}s gen=%{public}d refresh=%{public}s',
      fetchTid, generation, String(keepSubject))
    threadTreeFetchService.fetchAll(this.treeOwner, fetchTid, (_done: number, total: number): void => {
      if (generation !== this.fetchGeneration) {
        return
      }
      this.progressTotal = total
      if (this.totalPages <= 0) {
        // 总页数还没随提交落地（第 1 页未回）：先用 onProgress 的 total 兜底刷新，
        // 否则胶囊要等到首次提交才出现
        this.refreshBanner()
      }
    }, keepSubject, (commit: ThreadTreeCommit): void => {
      this.onFetchCommit(commit, generation)
    }).then((result: ThreadTreeFetchResult): void => {
      this.finishFetch(result, generation)
    }).catch((error: Object): void => {
      if (generation !== this.fetchGeneration) {
        return
      }
      this.stopping = false
      this.frozen = true
      this.phase = TreePagePhase.FAILED
      this.errorMsg = formatError(error)
      this.bannerErrorText = this.errorMsg
      this.refreshBanner()
      logger.error('tree-panel load failed tid=%{public}s: %{public}s', fetchTid, formatError(error))
    })
  }

  /**
   * 重置进入阶段的加载态：回到不可见，并在 400ms 后仍在 `ENTERING` 时淡入。
   *
   * 与列表页 `ThreadPanel` 的首屏加载同一节奏：第 1 页在 400ms 内到达时（含 90 秒缓存
   * 命中）用户直接看到内容，不会先闪一下 loading。计时器回调里判 `phase`，离开
   * `ENTERING`（第 1 页已提交 / 失败 / 停止）后自然作废，无需在每条路径上逐个清理。
   */
  private resetEnteringLoading(): void {
    clearTimeout(this.enteringLoadingTimer)
    this.enteringLoadingTimer = -1
    this.enteringLoadingOpacity = 0
    this.enteringLoadingTimer = setTimeout((): void => {
      this.enteringLoadingTimer = -1
      if (this.phase !== TreePagePhase.ENTERING) {
        return
      }
      this.getUIContext()?.animateTo({ duration: 150, curve: Curve.EaseInOut }, (): void => {
        this.enteringLoadingOpacity = 1
      })
    }, ENTERING_LOADING_DELAY_MS)
  }

  /**
   * 进入时登记定位目标：路由 pid 优先，其次上次阅读进度。
   *
   * 两种来源共用同一套「等待→就绪→用户决定」机制（§3.6），只有文案不同。
   *
   * @param generation - 抓取代际（异步读进度后校验）
   */
  private registerEnteringTarget(generation: number): void {
    if (this.threadPid.length > 0) {
      const routePid: number = parseInt(this.threadPid, 10)
      if (Number.isFinite(routePid) && routePid >= 0) {
        this.registerTarget(routePid, -1, -1, LocateSource.ROUTE, true)
        return
      }
    }
    if (!this.isResumeAllowedSource()) {
      return
    }
    if (!appStore.settings.recordReadingProgress || appStore.auth.uid.length === 0) {
      return
    }
    this.readResumeTarget(generation)
  }

  /**
   * 异步读取树内阅读进度并登记为目标（读到后再判定，不阻塞首屏）。
   *
   * **登记后必须再补一次就绪提示**（{@link promptTargetReady}）：进度来自 Preferences
   * 读盘，而抓取服务命中 {@link TREE_CACHE_TTL_MS} 短时缓存时，第 1 页会在 `loadTree`
   * 的同步阶段就回调 `onCommit`（见 `ThreadTreeFetchService.fetchAll` 的缓存分支），
   * 树会**先于**本次读盘建好。此时登记瞬间目标就已经在树里（`READY` / `FILTERED`），
   * 再也不会经过 `WAITING → READY` 的状态变化，`evaluatePendingTarget` 的 changed 分支
   * 永远不会触发——就绪 Toast 静默丢失，用户没有任何入口回到上次阅读位置。
   *
   * @param generation - 抓取代际
   */
  private async readResumeTarget(generation: number): Promise<void> {
    const uid: string = appStore.auth.uid
    const tid: string = this.threadTid
    let entry: ThreadTreeProgressEntry | null = null
    try {
      entry = await appStore.getTreeReadingProgress(uid, tid)
    } catch (e) {
      logger.warn('tree-panel resume read failed tid=%{public}s: %{public}s', tid, formatError(e))
      return
    }
    if (generation !== this.fetchGeneration || tid !== this.threadTid) {
      return
    }
    if (appStore.auth.uid !== uid) {
      return
    }
    if (entry === null || entry.pid < 0) {
      return
    }
    this.readingResumeHandled = true
    const registered: boolean = this.registerTarget(entry.pid, entry.page, entry.rootPid,
      LocateSource.RESUME, false)
    if (!registered) {
      // 已被更高优先级的目标（路由 / 用户点击）占用：提示归那个目标
      return
    }
    this.promptTargetReady()
  }

  /**
   * 登记（或替换）待定位目标。
   *
   * @param pid - 目标楼层 pid（`0` 是主楼的合法值）
   * @param page - 目标页码（未知传 -1）
   * @param rootPid - 已知所属根（未知传 -1）
   * @param source - 来源，见 `LocateSource`
   * @param force - 为 true 时绕过优先级（内部用途：刷新锚点、进入时的路由目标）
   * @returns 是否登记成功（被更高优先级的目标挡住时为 false，调用方据此决定要不要补提示）
   */
  private registerTarget(pid: number, page: number, rootPid: number, source: string,
    force: boolean): boolean {
    if (pid < 0) {
      return false
    }
    const currentSource: string = this.pendingTarget !== null ? this.pendingTarget.source : ''
    if (!force && !canOverrideTarget(source, currentSource)) {
      return false
    }
    const target: LocateTarget = new LocateTarget()
    target.pid = pid
    target.page = page
    target.rootPid = rootPid
    target.source = source
    target.label = formatTargetLabel(source, -1)
    this.pendingTarget = target
    this.targetLabel = target.label
    this.targetState = decideTargetState(this.allPids.has(pid),
      this.treeModel !== null && this.treeModel.postByPid.has(pid), page, this.committedPages,
      this.phase === TreePagePhase.COMPLETE)
    logger.info('tree-panel target register pid=%{public}d page=%{public}d source=%{public}s state=%{public}d',
      pid, page, source, this.targetState)
    this.refreshBanner()
    return true
  }

  /**
   * 接收一次水位提交（服务层回调）。
   *
   * 只做轻量登记与排程：真正的重建在 {@link flushCommit} 里合并到一帧，
   * 避免一次推进多页时重复重建。
   *
   * @param commit - 提交载荷
   * @param generation - 抓取代际
   */
  private onFetchCommit(commit: ThreadTreeCommit, generation: number): void {
    if (generation !== this.fetchGeneration || this.frozen) {
      return
    }
    this.committedPages = commit.committedPages
    if (commit.totalPages > 0) {
      this.totalPages = commit.totalPages
    }
    this.pendingCommitPosts = commit.posts
    this.pendingCommitPages = commit.committedPages
    this.pageByPid = commit.pageByPid
    this.pendingCommitThreadInfo = commit.threadInfo
    this.pendingCommitTotalRows = commit.totalRows
    this.pendingCommitForumName = commit.forumName
    this.scheduleCommit()
  }

  /** 排程一次提交（合并同一宏任务内的多次回调）。 */
  private scheduleCommit(): void {
    if (this.commitScheduled) {
      return
    }
    this.commitScheduled = true
    const generation: number = this.fetchGeneration
    this.commitTimer = setTimeout((): void => {
      this.commitTimer = -1
      this.commitScheduled = false
      // 排程期间可能已刷新/切帖：旧排程必须作废，否则会用空的前缀提交
      if (generation !== this.fetchGeneration) {
        return
      }
      this.flushCommit()
    }, 0)
  }

  /**
   * 执行排程中的提交。
   *
   * 用户正在拖拽/惯性滚动、或定位事务进行中时**推迟**：在用户手指下插入行会打断
   * 手势，`scrollToIndex` 也会用被挤偏的 index。推迟期间内容不丢，条件满足后立即补上。
   */
  private flushCommit(): void {
    if (this.frozen) {
      return
    }
    if (this.pendingCommitPages <= 0) {
      return
    }
    if (this.scrolling) {
      this.commitDeferred = true
      return
    }
    this.commitDeferred = false
    this.applyCommit(this.pendingCommitPosts, this.pendingCommitPages)
  }

  /**
   * 应用一次水位提交：首次建树 + 后续增量重建。
   *
   * @param posts - 已提交的连续前缀
   * @param committedPages - 已提交页数
   */
  private applyCommit(posts: PostInfo[], committedPages: number): void {
    const isFirst: boolean = !this.treeReady
    this.allPosts = posts
    this.rebuildAllPidIndex(posts)
    // 抓取请求固定用空黑名单（保证引用图完整），遮蔽标记在提交时按当前黑名单统一补齐
    applyBlacklistStateToPosts(this.allPosts, appStore.settingsStore.getBlacklistIds())
    this.committedPages = committedPages
    if (isFirst) {
      this.applyThreadInfo(true, this.pendingCommitThreadInfo)
      // 首次提交只登记目标，不滚动：增量模型下「跳转」必须等目标真正进入树
      this.recordBrowseHistoryOfCommit(posts)
      this.syncTrackedOnOpen()
      this.phase = TreePagePhase.STREAMING
    }
    this.rebuildTreePreservingState()
    this.applyRowsToDataSource()
    this.treeReady = true
    if (isFirst) {
      this.lastScrollStart = 0
      this.lastScrollCenter = 0
    }
    this.evaluatePendingTarget()
    logger.info('tree-panel commit tid=%{public}s pages=%{public}d posts=%{public}d rows=%{public}d first=%{public}s',
      this.threadTid, committedPages, posts.length, this.treeDataSource.totalCount(), String(isFirst))
  }

  /**
   * 重建全量楼层 pid 索引（判定「目标是否被只看楼主过滤」用）。
   *
   * @param posts - 已提交楼层
   */
  private rebuildAllPidIndex(posts: PostInfo[]): void {
    const pids: Set<number> = new Set<number>()
    for (let i: number = 0; i < posts.length; i++) {
      pids.add(posts[i].pid)
    }
    this.allPids = pids
  }

  /**
   * 首次提交时写浏览历史（与列表页同一份台账）。
   *
   * `pagination.totalRows` 必须用服务端总数：增量首次提交只有 20 楼左右，
   * 用已加载楼层数会把帖子在历史里记成"20 楼"。
   *
   * @param posts - 已提交楼层
   */
  private recordBrowseHistoryOfCommit(posts: PostInfo[]): void {
    if (!appStore.auth.isAuthenticated) {
      return
    }
    const info: ThreadInfo | null = this.pendingCommitThreadInfo
    if (info === null) {
      return
    }
    const historyResult: ThreadResult = new ThreadResult()
    historyResult.ok = true
    historyResult.threadInfo = info
    historyResult.forumName = this.pendingCommitForumName
    historyResult.posts = posts
    historyResult.pagination.page = 1
    historyResult.pagination.totalPages = this.totalPages
    historyResult.pagination.totalRows = this.pendingCommitTotalRows > 0
      ? this.pendingCommitTotalRows : posts.length
    appStore.addBrowseHistoryFromThread(appStore.auth.uid, historyResult, this.threadTid)
  }

  /**
   * 抓取结束（完成 / 停止 / 失败 / 被抢占）时的收尾。
   *
   * 增量模型下「结束」只影响状态与提示，**不会**把已经渲染的内容拿掉；
   * 失败时保留内容 + 错误条（见 `docs/THREAD_TREE_INCREMENTAL_LOAD_DESIGN.md` §3.8）。
   *
   * @param result - 抓取结果
   * @param generation - 抓取代际
   */
  private finishFetch(result: ThreadTreeFetchResult, generation: number): void {
    if (generation !== this.fetchGeneration) {
      logger.warn('tree-panel finish stale tid=%{public}s gen=%{public}d', this.threadTid, generation)
      return
    }
    this.commitScheduled = false
    this.commitDeferred = false
    // 用户已点停止：状态在 {@link stopLoading} 里即时落定，这里只记日志
    if (this.stoppedByUser) {
      logger.info('tree-panel stop settled tid=%{public}s pages=%{public}d cancelled=%{public}s',
        this.threadTid, this.committedPages, String(result.cancelled))
      return
    }
    // 被其他页面/任务抢占（平板多列）：不是用户的阅读决定，内容保留、只切错误条
    if (result.cancelled && !result.ok) {
      this.frozen = true
      this.phase = TreePagePhase.FAILED
      this.bannerErrorText = '加载被其他操作中断'
      this.errorMsg = this.bannerErrorText
      this.clearPendingTarget(LocateState.NONE)
      this.refreshBanner()
      logger.info('tree-panel preempted tid=%{public}s loaded=%{public}d',
        this.threadTid, result.loadedPages)
      return
    }
    if (result.ok) {
      if (result.threadInfo !== null) {
        this.pendingCommitThreadInfo = result.threadInfo
      }
      if (result.totalRows > 0) {
        this.pendingCommitTotalRows = result.totalRows
      }
      if (result.forumName.length > 0) {
        this.pendingCommitForumName = result.forumName
      }
      this.pageByPid = result.pageByPid
      this.totalPages = result.totalPages
      // 结果里的 posts 是权威前缀。两种情况下必须在这里补一次 apply：
      // 1) 还没建过树（缓存命中时 onCommit 排程的 setTimeout 晚于本微任务，
      //    若只按 loadedPages 判定会永远跳过，页面空白）；
      // 2) 最后一页只走了结果、没走 onCommit。
      // 收尾是最后一次提交，直接应用（中途提交才遵守拖拽互斥）。
      if (!this.treeReady || result.loadedPages > this.committedPages) {
        this.pendingCommitPosts = result.posts
        this.pendingCommitPages = result.loadedPages
        this.applyCommit(result.posts, result.loadedPages)
      }
    }
    this.frozen = true
    if (!result.ok) {
      this.phase = TreePagePhase.FAILED
      this.errorMsg = result.error.length > 0 ? result.error : '加载失败'
      this.bannerErrorText = this.errorMsg
      if (this.treeReady) {
        this.partialData = true
        this.partialLoadedPages = result.loadedPages
        this.partialTotalPages = result.totalPages
      }
      this.applySkippedPages(result.skippedPages, false)
      this.clearPendingTarget(LocateState.NONE)
      this.refreshBanner()
      logger.warn('tree-panel load failed tid=%{public}s loaded=%{public}d',
        this.threadTid, result.loadedPages)
      return
    }
    if (result.partial) {
      // 有内容但没抓全：**不是**用户停止（用户停止已在 stopLoading 落定），
      // 而是某页失败或被抢占 —— 保留内容 + 错误条 + 重试（§3.8）。
      this.phase = TreePagePhase.FAILED
      this.partialData = true
      this.partialLoadedPages = result.loadedPages
      this.partialTotalPages = result.totalPages
      this.bannerErrorText = result.cancelled
        ? '加载被其他操作中断'
        : (result.error.length > 0 ? result.error : '加载未完成')
      this.errorMsg = this.bannerErrorText
      this.applySkippedPages(result.skippedPages, false)
      this.clearPendingTarget(LocateState.NONE)
    } else {
      this.phase = TreePagePhase.COMPLETE
      this.partialData = false
      this.partialLoadedPages = 0
      this.partialTotalPages = 0
      this.applySkippedPages(result.skippedPages, true)
      // 目标仍未就绪（所在页被跳过）已经没有机会了；READY 的保留给 Toast 点击
      if (this.targetState !== LocateState.READY) {
        this.clearPendingTarget(LocateState.MISSING)
      }
    }
    this.evaluatePendingTarget()
    this.refreshBanner()
    logger.info(
      'tree-panel load done tid=%{public}s posts=%{public}d roots=%{public}d rows=%{public}d ' +
        'quotes=%{public}d authorOnly=%{public}s partial=%{public}s',
      this.threadTid, result.posts.length, this.treeModel !== null ? this.treeModel.roots.length : 0,
      this.treeDataSource.totalCount(), this.treeModel !== null ? this.treeModel.quoteCount : 0,
      String(this.authorOnly), String(result.partial)
    )
  }

  /**
   * 重建树并保留展开状态（增量提交的核心）。
   *
   * `buildThreadTree` 每次都会 new 全新 root（`expanded=false`、`rev=0`），
   * 直接替换会把用户展开过的根折叠回去。这里按 `rootPid` 从旧模型回填。
   */
  private rebuildTreePreservingState(): void {
    const model: ThreadTreeModel | null = this.treeModel
    const keep: Map<number, RootState> = new Map<number, RootState>()
    if (model !== null) {
      for (let i: number = 0; i < model.roots.length; i++) {
        const root: ThreadTreeRoot = model.roots[i]
        const state: RootState = new RootState()
        state.expanded = root.expanded
        state.rev = root.rev
        keep.set(root.post.pid, state)
      }
    }
    const posts: PostInfo[] = this.filteredPosts()
    const next: ThreadTreeModel = buildThreadTree(posts, this.totalPages)
    this.pageByPid.forEach((page: number, pid: number): void => {
      next.pageByPid.set(pid, page)
    })
    // 只看楼主：被过滤父楼层的根行补回引用上下文
    this.restoreRootQuoteContext(next)
    // 回填展开状态（按 pid，不按位置：位置会随增量插入漂移）
    if (keep.size > 0) {
      for (let i: number = 0; i < next.roots.length; i++) {
        const root: ThreadTreeRoot = next.roots[i]
        const state: RootState | undefined = keep.get(root.post.pid)
        if (state !== undefined && state.expanded) {
          root.expanded = true
          root.rev = state.rev
        }
      }
    }
    // 统一次摊平：build 内部已摊平过一次，但上面改过 displayContent / expanded
    flattenThreadTree(next)
    // 高亮态跨重建保留：行键含 `_h` 后缀，重建丢掉高亮会让 diff 认不出旧行 → 整表 RELOAD
    if (this.highlightPid > 0) {
      for (let i: number = 0; i < next.rows.length; i++) {
        const row: ThreadTreeRow = next.rows[i]
        if (row.post !== null && row.post.pid === this.highlightPid) {
          row.highlighted = true
          break
        }
      }
    }
    this.treeModel = next
  }

  /**
   * 把当前模型的行同步到数据源（增量通知 + 锚点补偿）。
   *
   * 纯插入 → `onDatasetChange` 的 ADD（让 `maintainVisibleContentPosition` 生效）；
   * 无法用增量表达（展开/折叠、只看楼主切换）→ RELOAD 兜底。
   */
  private applyRowsToDataSource(skipAnchor: boolean = false): void {
    const model: ThreadTreeModel | null = this.treeModel
    if (model === null) {
      this.treeDataSource.replaceAll([])
      this.lastRows = []
      return
    }
    const next: ThreadTreeRow[] = model.rows
    const old: ThreadTreeRow[] = this.lastRows
    const anchor: RowAnchor = skipAnchor ? new RowAnchor() : this.captureAnchor(old)
    if (old.length === 0) {
      this.treeDataSource.replaceAll(next)
      this.lastRows = next
      return
    }
    const diff: RowDiffResult = computeTreeRowDiff(old, next,
      (row: ThreadTreeRow): string => this.rowKey(row))
    if (diff.needReload) {
      this.treeDataSource.replaceAll(next)
    } else if (diff.ops.length > 0) {
      this.treeDataSource.applyRowOps(next, diff.ops)
    } else {
      this.lastRows = next
      return
    }
    this.lastRows = next
    this.scheduleAnchorRestore(anchor)
  }

  /**
   * 记录提交前的视口锚点（首个可见行 + 其相对视口顶部的偏移）。
   *
   * @param oldRows - 提交前的行序列
   * @returns 锚点；不可用时 `valid = false`
   */
  private captureAnchor(oldRows: ThreadTreeRow[]): RowAnchor {
    const anchor: RowAnchor = new RowAnchor()
    if (!this.listMounted || oldRows.length === 0) {
      return anchor
    }
    const index: number = Math.max(0, Math.min(this.lastScrollStart, oldRows.length - 1))
    const row: ThreadTreeRow = oldRows[index]
    if (row.post === null) {
      return anchor
    }
    anchor.pid = row.post.pid
    anchor.oldIndex = index
    try {
      anchor.offset = this.scroller.getItemRect(index).y
    } catch (e) {
      anchor.offset = 0
    }
    anchor.valid = true
    return anchor
  }

  /**
   * 提交后恢复视口：只在「锚点之前插入了行」时滚动补偿。
   *
   * 公式与普通列表页的前插锚点一致（`THREAD_DESIGN.md` §4.5），但字段与实现都在树页内。
   *
   * @param anchor - 提交前记录的锚点
   */
  private scheduleAnchorRestore(anchor: RowAnchor): void {
    if (!anchor.valid || anchor.pid < 0) {
      return
    }
    this.appendAnchorPid = anchor.pid
    this.appendAnchorOffset = anchor.offset
    this.appendAnchorPending = true
    if (this.appendAnchorScheduled) {
      return
    }
    this.appendAnchorScheduled = true
    setTimeout((): void => {
      this.appendAnchorScheduled = false
      if (!this.appendAnchorPending || !this.listMounted) {
        this.appendAnchorPending = false
        return
      }
      const pid: number = this.appendAnchorPid
      const oldIndex: number = anchor.oldIndex
      const offset: number = this.appendAnchorOffset
      this.appendAnchorPending = false
      this.appendAnchorPid = -1
      this.appendAnchorOffset = 0
      const newIndex: number = this.treeDataSource.findIndexByPid(pid)
      // 只有「锚点之前插入了行」才需要补偿；newIndex 变小说明行被删除/重排，
      // 滚动反而会把用户带偏（§4.5）
      if (newIndex < 0 || newIndex <= oldIndex) {
        return
      }
      const contentStart: number = NAV_BAR_H + this.statusBarHeight
      const restoreOffset: number = contentStart - offset
      const extra: LengthMetrics = new LengthMetrics(restoreOffset)
      this.compensating = true
      this.scroller.scrollToIndex(newIndex, false, ScrollAlign.START, { extraOffset: extra })
      setTimeout((): void => {
        this.compensating = false
      }, 0)
      logger.info('tree-panel anchor restore pid=%{public}d %{public}d->%{public}d offset=%{public}s',
        pid, oldIndex, newIndex, String(restoreOffset))
    }, 0)
  }

  /**
   * 按当前模型判定待定位目标的状态（§3.6.3 判定表）。
   */
  private evaluatePendingTarget(): void {
    const target: LocateTarget | null = this.pendingTarget
    if (target === null) {
      this.refreshBanner()
      return
    }
    const inTree: boolean = this.treeModel !== null && this.treeModel.postByPid.has(target.pid)
    const inAll: boolean = this.allPids.has(target.pid)
    const complete: boolean = this.phase === TreePagePhase.COMPLETE
    const nextState: number = decideTargetState(inAll, inTree, target.page,
      this.committedPages, complete)
    const changed: boolean = nextState !== this.targetState
    this.targetState = nextState
    if (inAll) {
      const post: PostInfo | null = this.findPostInAll(target.pid)
      if (post !== null) {
        this.targetLabel = formatTargetLabel(target.source, post.lou)
      }
    }
    if (changed) {
      logger.info('tree-panel target state pid=%{public}d state=%{public}d', target.pid, nextState)
      if (nextState === LocateState.READY) {
        // 就绪提示由 Toast 承担（胶囊只做进度，不承载「前往」）
        this.showTargetToast(false)
      } else if (nextState === LocateState.FILTERED) {
        this.showTargetToast(true)
      } else if (nextState === LocateState.MISSING) {
        // 楼层确实不在：静默清除，不弹「已删除」这类负面提示
        this.clearPendingTarget(LocateState.MISSING)
        return
      }
    }
    this.refreshBanner()
  }

  /**
   * 在已提交楼层里按 pid 查找（全量，未过滤）。
   *
   * @param pid - 目标楼层 pid
   * @returns 楼层；未命中返回 null
   */
  private findPostInAll(pid: number): PostInfo | null {
    for (let i: number = 0; i < this.allPosts.length; i++) {
      if (this.allPosts[i].pid === pid) {
        return this.allPosts[i]
      }
    }
    return null
  }

  /**
   * 「登记即就绪」时补发一次就绪提示（§3.6.5 主通道）。
   *
   * 正常路径里目标以 `WAITING` 登记，随后水位推进时才变为 `READY` / `FILTERED`，
   * 由 {@link evaluatePendingTarget} 的状态变化分支提示一次。但缓存命中时树会先于
   * 进度读盘建好（见 {@link readResumeTarget}），登记瞬间就已经可操作、之后状态不再
   * 变化——必须在这里补一次，否则用户永远看不到「前往查看 / 查看全部」。
   *
   * 两条路径互斥：状态一旦可操作就不会再「变成同一个状态」，不会重复弹。
   */
  private promptTargetReady(): void {
    if (this.pendingTarget === null) {
      return
    }
    if (this.targetState === LocateState.READY) {
      this.showTargetToast(false)
      return
    }
    if (this.targetState === LocateState.FILTERED) {
      this.showTargetToast(true)
    }
  }

  /**
   * 目标可操作时弹一次 Toast（「前往查看」/「查看全部」）。
   *
   * 胶囊在「已到」之后立刻回到纯进度（结束后只显示 `N/X`），不承载任何定位动作，
   * 因此定位入口只由 Toast 承担。
   * 用户正在滚动时不弹：手势中弹窗会被误触，也打断阅读。
   *
   * @param filtered - 目标是否被「只看楼主」过滤
   */
  private showTargetToast(filtered: boolean): void {
    const target: LocateTarget | null = this.pendingTarget
    if (target === null) {
      return
    }
    // 用户正在拖拽/惯性滚动：挂起到 onScrollStop 补发，不能直接丢掉
    // （就绪只会在状态变化时判定一次，丢掉就再也没有第二次机会）
    if (this.scrolling) {
      this.targetToastPending = true
      this.targetToastFiltered = filtered
      return
    }
    this.targetToastPending = false
    const baseText: string = filtered
      ? (target.source === LocateSource.RESUME ? '上次阅读位置不在只看楼主视图内' : '目标楼层不在只看楼主视图内')
      : (target.source === LocateSource.RESUME ? '检测到上次阅读进度' : '目标楼层已加载')
    const action: string = filtered ? '查看全部' : '前往查看'
    clearTimeout(this.targetToastTimer)
    this.targetToastTimer = setTimeout((): void => {
      this.targetToastTimer = -1
      if (this.pendingTarget === null) {
        return
      }
      // Toast 可能晚于状态变化：触发时再校验一次
      if (filtered && this.targetState !== LocateState.FILTERED) {
        return
      }
      if (!filtered && this.targetState !== LocateState.READY) {
        return
      }
      const text: string = !filtered && this.skippedPageHint.length > 0
        ? baseText + '（' + this.skippedPageHint + '）'
        : baseText
      appStore.showToastAction(text, action, (): void => {
        this.activatePendingTarget()
      })
    }, 0)
  }

  /**
   * 用户确认前往：展开所属根 → 居中 → 高亮 → 清除目标。
   */
  private activatePendingTarget(): void {
    const target: LocateTarget | null = this.pendingTarget
    if (target === null) {
      return
    }
    if (this.targetState === LocateState.FILTERED) {
      // 「查看全部」：关闭只看楼主后立即定位（用户已经表达了要去的意图）
      const pid: number = target.pid
      const page: number = target.page
      const source: string = target.source
      this.clearPendingTarget(LocateState.NONE)
      if (this.authorOnly) {
        this.toggleAuthorOnly()
      }
      this.registerTarget(pid, page, -1, source, true)
      if (this.targetState === LocateState.READY) {
        this.activatePendingTarget()
      }
      return
    }
    if (!canActivateTarget(this.targetState)) {
      return
    }
    const index: number = this.resolveTargetIndex(target)
    const pid: number = target.pid
    this.clearPendingTarget(LocateState.NONE)
    if (index < 0) {
      appStore.showToast(this.missingFloorHint())
      return
    }
    this.viewportMoved = true
    this.scroller.scrollToIndex(index, false, ScrollAlign.CENTER)
    this.highlightRow(pid)
    appStore.showToast(target.source === LocateSource.RESUME ? '已恢复上次阅读位置' : '已定位到该楼层')
  }

  /**
   * 目标行在数据源中的下标（必要时展开所属根）。
   *
   * @param target - 目标
   * @returns 行下标；不可定位返回 -1
   */
  private resolveTargetIndex(target: LocateTarget): number {
    let index: number = this.treeDataSource.findIndexByPid(target.pid)
    if (index >= 0) {
      return index
    }
    this.appendAnchorPending = false
    this.ensureRowVisible(target.pid)
    index = this.treeDataSource.findIndexByPid(target.pid)
    return index
  }

  /**
   * 清除待定位目标。
   *
   * 没有「忽略目标」的独立入口：用户要放弃等待就点胶囊的「停止」（`stopLoading` 里同样清目标），
   * 所以 `DISMISSED` 状态当前没有入口。
   *
   * @param state - 清除后的状态（`NONE` / `MISSING`）
   */
  private clearPendingTarget(state: number): void {

    clearTimeout(this.targetToastTimer)
    this.targetToastTimer = -1
    this.pendingTarget = null
    this.targetState = state
    this.targetLabel = ''
    this.refreshBanner()
  }

  /**
   * 刷新胶囊状态与可见性（所有状态变化的唯一出口）。
   *
   * 加载结束（完成/停止）转为常驻的 `LOADED`（只显示 `N/X`）；只有 `ENTERING` 不渲染。
   * 末尾同步刷新数字区实测宽度，保证材质块宽度与内容一致。
   */
  private refreshBanner(): void {
    const hasTarget: boolean = this.pendingTarget !== null
    const state: number = hasTarget ? this.targetState : LocateState.NONE
    const mode: number = resolveBannerMode(this.phase, state, this.stopping)
    this.bannerMode = mode
    this.bannerVisible = shouldShowBanner(mode, this.totalPages)
    this.updateBannerTextWidth()
  }

  /**
   * 停止加载（底部进度胶囊「停止」）。
   *
   * 立即反馈（胶囊转「正在停止…」）但不等待网络：服务层在途请求自然收尾，
   * 页面在 {@link finishFetch} 里落定。**终止后不提供继续**。
   */
  private stopLoading(): void {
    if (this.stopping) {
      return
    }
    if (this.phase !== TreePagePhase.STREAMING && this.phase !== TreePagePhase.ENTERING) {
      return
    }
    // 点击即冻结：不再接受任何提交，不等在途请求（最坏要等单页 15s 超时）。
    // 服务层随后返回的结果只记日志（finishFetch 见 stoppedByUser 直接 return）。
    this.stoppedByUser = true
    this.frozen = true
    clearTimeout(this.commitTimer)
    this.commitTimer = -1
    this.commitScheduled = false
    this.commitDeferred = false
    this.pendingCommitPages = 0
    threadTreeFetchService.cancel(this.treeOwner)
    this.clearPendingTarget(LocateState.NONE)
    if (!this.treeReady) {
      // 内容还没上屏：直接落错误态（全屏，没有胶囊可展示过渡）
      this.phase = TreePagePhase.FAILED
      this.errorMsg = '已停止加载'
      this.bannerErrorText = this.errorMsg
      this.refreshBanner()
      logger.info('tree-panel stop tid=%{public}s pages=%{public}d/%{public}d',
        this.threadTid, this.committedPages, this.totalPages)
      return
    }
    // 有内容：先给「正在停止…」的可见反馈（`TREE_STOP_SETTLE_MS`），再落定到 STOPPED/LOADED
    this.stopping = true
    this.refreshBanner()
    this.stopSettleTimer = setTimeout((): void => {
      this.stopSettleTimer = -1
      this.settleStopped()
    }, TREE_STOP_SETTLE_MS)
  }

  /**
   * 停止过渡结束：落定 `STOPPED`，胶囊转入常驻 `LOADED`（`12/29`），尾部标注已加载范围。
   *
   * 过渡期间（`stopping = true`）胶囊显示「正在停止…」，`frozen` 已阻止任何提交；
   * 这里只改页面状态，不碰服务层（取消早已完成）。
   */
  private settleStopped(): void {
    this.stopping = false
    if (this.phase !== TreePagePhase.STOPPED) {
      this.phase = TreePagePhase.STOPPED
      this.partialData = true
      this.partialLoadedPages = this.committedPages
      this.partialTotalPages = this.totalPages
    }
    this.refreshBanner()
    logger.info('tree-panel stop settled tid=%{public}s pages=%{public}d/%{public}d',
      this.threadTid, this.committedPages, this.totalPages)
  }

  /**
   * 应用本次抓取的缺页信息：写入常驻提示，必要时弹一次 Toast。
   *
   * 提示不只用 Toast 承载（见 {@link skippedPageHint} 字段说明）：Toast 会被后续
   * 提示覆盖，常驻文案保证「树少了哪几页」在页面上始终可查。
   *
   * 增量模型下只在 `COMPLETE` 时弹 Toast：`STOPPED` / `FAILED` 用户已经放弃等待，
   * 再弹一条只是噪音，尾部常驻文案足够。
   *
   * @param skippedPages - 被跳过的页码（升序）
   * @param showToast - 是否弹 Toast
   */
  private applySkippedPages(skippedPages: number[], showToast: boolean): void {
    this.skippedPageHint = this.buildSkippedPagesHint(skippedPages)
    if (this.skippedPageHint.length === 0 || !showToast) {
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
      // 判定逻辑抽在 ThreadTreeBuilder.needsRootQuoteContext（纯函数，可单测）：
      // 只有标题的根行不补引用上下文，避免与标题重复。
      if (!needsRootQuoteContext(root, model, this.authorOnly)) {
        continue
      }
      root.displayContent = root.post.content
      changed = true
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
   * 应用主题元数据（标题 / fid / 楼主标识）。
   *
   * @param keepSubject - 是否保留当前标题
   * @param info - 主题元数据（可为 null）
   */
  private applyThreadInfo(keepSubject: boolean, info: ThreadInfo | null): void {
    if (info === null) {
      // 拿不到主题信息：保留路由带来的楼主身份（若有），两者都不可用时才关闭只看楼主
      this.disableAuthorOnlyIfUnavailable()
      return
    }
    this.threadFid = info.fid
    const fetchAuthorId: number = info.authorid
    const fetchAuthorKey: string = info.authorKey
    // 服务端结果优先；它没给（uid=0 / authorKey 为空）时回落到路由身份，
    // 否则「只看楼主」与标题屏蔽会在加载完成后反而被关闭
    this.threadAuthorId = fetchAuthorId !== 0 ? String(fetchAuthorId) : this.authorIdInit
    this.threadAuthorKey = fetchAuthorKey.length > 0 ? fetchAuthorKey : this.authorKeyInit
    this.hasThreadAuthorKey = this.isAuthorKeyUsable(this.threadAuthorKey)
    this.disableAuthorOnlyIfUnavailable()
    if (keepSubject && this.threadSubject.length > 0 && this.threadSubject !== '递进树') {
      return
    }
    const subject: string = unescapeHtml(info.subject)
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
   * 确保指定楼层行在树中可见（被折叠时展开其所属根）。
   *
   * @param pid - 目标楼层 pid
   * @returns 树模型中有该楼层时为 true
   */
  private ensureRowVisible(pid: number): boolean {
    const model: ThreadTreeModel | null = this.treeModel
    // pid = 0 是主楼的合法值（HTML 通道），只有负数才是「无目标」
    if (model === null || pid < 0) {
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
    this.lastRows = model.rows
    return this.treeDataSource.findIndexByPid(pid) >= 0
  }

  /**
   * 展开某根全部子节点（折叠行点击）。
   *
   * 展开会改变行数、且插入点在点击行下方（视口上方不受影响），因此走 RELOAD 即可；
   * 但必须同步 `lastRows`，否则下一次增量 diff 会拿旧序列计算而误判。
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
    this.lastRows = model.rows
  }

  /**
   * 树内跳转到指定楼层（子节点头部「→」/ 同帖链接）。
   *
   * 增量模型下「跳转到尚未加载的楼层」不是报错，而是**登记为等待目标**：
   * 加载到那一页后再给「前往」（§3.6.2 规则 8）。只有在不会再加载时
   * （已停止/已完成）才直接给结论。
   *
   * @param pid - 目标楼层 pid
   */
  private treeJumpToPid(pid: number): void {
    const model: ThreadTreeModel | null = this.treeModel
    if (model === null) {
      return
    }
    if (pid < 0) {
      this.scroller.scrollToIndex(0, false, ScrollAlign.START)
      return
    }
    if (this.treeDataSource.findIndexByPid(pid) >= 0) {
      const index: number = this.treeDataSource.findIndexByPid(pid)
      this.scroller.scrollToIndex(index, false, ScrollAlign.CENTER)
      this.highlightRow(pid)
      return
    }
    if (this.phase === TreePagePhase.STREAMING) {
      // 还没加载到：登记为目标，胶囊立刻给出「在等什么」，不再说"不存在"
      const mappedPage: number | undefined = this.pageByPid.get(pid)
      const targetPage: number = mappedPage !== undefined ? mappedPage : -1
      this.registerTarget(pid, targetPage, -1, LocateSource.USER, true)
      const progressText: string = targetPage > 0
        ? '该楼层在第 ' + String(targetPage) + ' 页，已加载到 ' + String(this.committedPages) + ' 页'
        : '该楼层尚未加载，已加载到 ' + String(this.committedPages) + ' 页'
      appStore.showToast(progressText)
      return
    }
    if (this.ensureRowVisible(pid)) {
      const index: number = this.treeDataSource.findIndexByPid(pid)
      if (index >= 0) {
        this.scroller.scrollToIndex(index, false, ScrollAlign.CENTER)
        this.highlightRow(pid)
        return
      }
    }
    appStore.showToast(this.missingFloorHint())
  }

  /**
   * 树内跳转命中不到楼层时的提示文案（四态，§3.6.2）：
   * 加载中还没到 / 被只看楼主过滤 / 已停止且不在已加载页内 / 确实不存在。
   *
   * 增量模型下最常见的「找不到」是**还没加载**，不能谎报已删除。
   *
   * @returns 提示文案
   */
  private missingFloorHint(): string {
    if (this.phase === TreePagePhase.STREAMING || this.phase === TreePagePhase.ENTERING) {
      return '该楼层尚未加载，正在加载中…'
    }
    if (this.authorOnly) {
      return '该楼层不在只看楼主视图内，可切换为全部楼层'
    }
    if (this.phase === TreePagePhase.STOPPED || this.phase === TreePagePhase.FAILED) {
      return '该楼层不在已加载的 ' + String(this.committedPages) + '/' +
        String(this.totalPages) + ' 页内，可重新进入帖子获取全部'
    }
    return '该楼层不存在或已删除'
  }

  /**
   * 高亮命中的子节点行，2 秒后清除。
   *
   * 只改 `highlighted`，**不递增 `rev`**：`rowKey` 已含 `_h` 后缀，键会因高亮变化；
   * 而 `rev` 是「所属根的展开代际」（`flattenThreadTree` 用它统一给整组行换键），
   * 给单个子行 `rev++` 会让 `lastRows` 与下一次重建的行键分叉，把增量 diff 逼成整表
   * RELOAD。`updateAt` 带新键即可精确重建这一行。
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
    this.highlightPid = pid
    this.treeDataSource.updateAt(index, row, this.rowKey(row))
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
      this.treeDataSource.updateAt(currentIndex, current, this.rowKey(current))
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
   * 树内阅读进度记录是否有效（开关开启、已登录、树已就绪、目标不在等待中、用户移动过视口）。
   *
   * @returns 是否可以记录
   */
  private shouldRecordProgress(): boolean {
    // 目标还在等数据：等待期用户往下翻只是「先看看」，不能因此把上次进度覆盖成第 3 页。
    // 只拦 WAITING —— 目标已就绪/被过滤时用户已经能去，若继续阻塞记录，用户不点 Toast
    // 就会整场都不落盘（目标也可能一直挂着）。
    if (this.targetState === LocateState.WAITING) {
      return false
    }
    // 用户没有真正移动过视口：停在顶部不算「读到这」
    if (!this.viewportMoved) {
      return false
    }
    return appStore.settings.recordReadingProgress &&
      appStore.auth.uid.length > 0 &&
      this.treeReady &&
      // 导航事务进行中，rows 与 lastScrollCenter 可能暂时不同步
      !this.navigationPending &&
      // 锚点补偿是程序化滚动，不能当成阅读位置
      !this.compensating
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
    // 页码未知时写 -1：写 1 会让下次恢复误判「目标页已提交」，把好好的楼层判成不存在
    entry.page = mappedPage !== undefined && mappedPage > 0 ? mappedPage : -1
    appStore.saveTreeReadingProgress(appStore.auth.uid, entry)
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

  // ==================== 交互 ====================

  /**
   * 提交成功后的刷新入口：能局部合并就只抓一页，否则退回整帖重抓。
   *
   * 不 await：编辑器不必等补页完成才关闭；合并过程抛错会自动退回整帖重抓。
   *
   * @param ctx - 提交上下文
   */
  private consumeSubmitResult(ctx: TreeSubmitContext): void {
    appStore.showToast(ctx.toast)
    this.mergeAfterSubmit(ctx).catch((e: Error): void => {
      logger.warn('tree-panel local merge failed: %{public}s', formatError(e))
      this.loadTree(true)
    })
  }

  /**
   * 用「一页服务端数据」局部刷新树（回复 / 编辑共用）。
   *
   * 前置条件（任一不满足即退回整帖重抓）：
   * - 树已完整加载到末页：否则这页会打破 `allPosts` 的连续前缀，
   *   `pageByPid` / 定位判定 / 进度胶囊全部失真；
   * - 编辑目标页已知（`pageByPid` 命中）；
   * - 补页往返期间没有切帖/离开（抓取代际未变）。
   *
   * 抓末页用 `'e'` 而不是本地 `totalPages`：新回复可能把末页顶到下一页。
   *
   * @param ctx - 提交上下文
   */
  private async mergeAfterSubmit(ctx: TreeSubmitContext): Promise<void> {
    if (this.phase !== TreePagePhase.COMPLETE || this.committedPages < this.totalPages
      || this.treeModel === null) {
      this.loadTree(true)
      return
    }
    let page: string = 'e'
    if (ctx.kind === TreeSubmitKind.EDIT) {
      const mapped: number | undefined = this.pageByPid.get(ctx.editPid)
      if (mapped === undefined || mapped <= 0) {
        // 页码未知：不猜，整帖重抓
        this.loadTree(true)
        return
      }
      page = String(mapped)
    }
    const generation: number = this.fetchGeneration
    const result: ThreadResult = await threadTreeFetchService.fetchSinglePage(this.threadTid, page)
    if (generation !== this.fetchGeneration || this.treeModel === null) {
      return
    }
    if (!result.ok) {
      this.loadTree(true)
      return
    }
    // 页号/水位一致性：补页只允许覆盖「已提交页 + 1」，越界说明中间页有缺口或分页已变
    const isEdit: boolean = ctx.kind === TreeSubmitKind.EDIT
    const decision: MergePageDecision = resolveMergePage(isEdit, page, result.pagination.page,
      this.committedPages)
    if (!decision.accept) {
      logger.warn('tree-panel merge page rejected tid=%{public}s page=%{public}s: %{public}s',
        this.threadTid, page, decision.reason)
      this.loadTree(true)
      return
    }
    this.applyMergedPage(result, decision.pageNo, ctx)
  }

  /**
   * 把补页结果合并进当前树并做增量通知。
   *
   * 只做「新增 + 同 pid 替换」，不删除不移动——否则行 diff 会退化为整表 RELOAD
   * （见 `ThreadTreeLocalMerge` 文件头）。页号已由 `resolveMergePage` 校验。
   *
   * @param result - 补页结果（末页或编辑目标所在页）
   * @param pageNo - 该页页码（已校验）
   * @param ctx - 提交上下文
   */
  private applyMergedPage(result: ThreadResult, pageNo: number, ctx: TreeSubmitContext): void {
    const isEdit: boolean = ctx.kind === TreeSubmitKind.EDIT
    const guardPid: number = isEdit ? ctx.editPid : 0
    const guardContent: string = isEdit ? ctx.text.replace(/\n/g, '<br/>') : ''
    const merged: LocalMergeResult = mergeTreePage(this.allPosts, result.posts, guardPid, guardContent)
    this.allPosts = merged.posts
    // 拷贝后写：this.pageByPid 可能直接指向抓取服务/缓存的 Map，原地 set 会污染它们
    const nextPageByPid: Map<number, number> = new Map<number, number>()
    this.pageByPid.forEach((value: number, pid: number): void => {
      nextPageByPid.set(pid, value)
    })
    for (let i: number = 0; i < result.posts.length; i++) {
      nextPageByPid.set(result.posts[i].pid, pageNo)
    }
    this.pageByPid = nextPageByPid
    this.committedPages = Math.max(this.committedPages, pageNo)
    // 只在 COMPLETE 下合并：**不采纳**「服务端说还有更多页」——那会让完成态与已提交页数
    // 脱节（胶囊显示未加载页）。多出来的页留给下一次补页或重新进入。
    this.totalPages = Math.max(this.totalPages, this.committedPages)
    // 抓取请求固定用空黑名单，提交时按当前黑名单统一补齐（与 applyCommit 同口径）
    applyBlacklistStateToPosts(this.allPosts, appStore.settingsStore.getBlacklistIds())
    this.rebuildAllPidIndex(this.allPosts)
    this.rebuildTreePreservingState()
    // 回复要主动定位 → 关掉锚点补偿；编辑原地生效 → 保留锚点（重排时补偿不跳）
    this.applyRowsToDataSource(!isEdit)
    this.refreshBanner()
    logger.info('tree-panel merge tid=%{public}s page=%{public}d added=%{public}d replaced=%{public}d',
      this.threadTid, pageNo, merged.addedPids.length, merged.replacedPids.length)
    const target: number = isEdit ? ctx.editPid : ctx.newPid
    if (target <= 0 || !merged.contains(target)) {
      if (isEdit) {
        // 编辑目标不在返回页：本地正文仍是旧版、pageByPid 也可能已错，只能整帖重抓纠正
        logger.warn('tree-panel edit target missing page=%{public}d pid=%{public}d',
          pageNo, ctx.editPid)
        this.loadTree(true)
        return
      }
      // 服务端还没刷出这一楼（审核 / CDN 延迟）：不制造幽灵数据，也不整帖重抓
      appStore.showToast('内容已提交，稍后刷新可见')
      return
    }
    if (isEdit) {
      // 编辑原地生效，不移动视口
      return
    }
    if (this.treeModel === null || !this.treeModel.postByPid.has(target)) {
      // 数据合并成功但树里不可见：只看楼主把非楼主楼层过滤掉了
      appStore.showToast('已回复，当前只看楼主视图不显示你的回复')
      return
    }
    this.focusPost(target)
  }

  /**
   * 定位并高亮指定楼层（必要时展开所属根）。
   *
   * 用户正在拖拽/惯性滚动时不抢手势：只高亮，不滚动。
   *
   * @param pid - 目标楼层 pid
   */
  private focusPost(pid: number): void {
    let index: number = this.treeDataSource.findIndexByPid(pid)
    if (index < 0) {
      if (!this.ensureRowVisible(pid)) {
        return
      }
      index = this.treeDataSource.findIndexByPid(pid)
    }
    if (index < 0) {
      return
    }
    if (!this.scrolling) {
      this.viewportMoved = true
      this.scroller.scrollToIndex(index, false, ScrollAlign.CENTER)
    }
    this.highlightRow(pid)
  }

  /**
   * 发送楼层回复 / 主题回复（编辑器在全局浮层中）。
   *
   * 成功后只抓末页做局部合并（`consumeSubmitResult`），不再重建整帖。
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
    const ctx: TreeSubmitContext = new TreeSubmitContext()
    ctx.kind = TreeSubmitKind.REPLY
    const parsedPid: number = result.pid.length > 0 ? parseInt(result.pid, 10) : 0
    ctx.newPid = Number.isFinite(parsedPid) && parsedPid > 0 ? parsedPid : 0
    ctx.toast = '回复成功'
    this.consumeSubmitResult(ctx)
  }

  /**
   * 发送编辑修改。
   *
   * 成功后只抓被编辑楼层所在页做局部合并（`consumeSubmitResult`），不再重建整帖。
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
    const target: PostInfo | null = replyManager.targetPost
    const ctx: TreeSubmitContext = new TreeSubmitContext()
    ctx.kind = TreeSubmitKind.EDIT
    ctx.editPid = target !== null ? target.pid : 0
    ctx.text = text
    ctx.toast = '编辑成功'
    this.consumeSubmitResult(ctx)
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
        if (Number.isFinite(linkPidNumber) && linkPidNumber >= 0) {
          // 与子节点「→」同一入口：已加载就定位，未加载就登记为等待目标
          this.treeJumpToPid(linkPidNumber)
          return
        }
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
    const subject: string = resolveFloorSubject(p)
    let source: string = displayContent.length > 0 ? displayContent : p.content
    if (subject.length > 0) {
      // 标题-only 楼层（displayContent 为空）：标题就是该层唯一文字，不念 Reply-to 头
      source = displayContent.length > 0 ? subject + '。' + source : subject
    }
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
    const subject: string = resolveFloorSubject(p)
    const bodyText: string = bbNodesToPlainText(getCachedBBNodes(p.content))
    const plainText: string = subject.length > 0 ? subject + '\n' + bodyText : bodyText
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
   * 与列表页（`ThreadPanel.moreMenuItems`）**同序同构**，只有一处按阅读样式命名：
   * 「切换为递进树阅读 / 切换为列表阅读」。这样两页的多功能下拉在用户看来是同一个菜单，
   * 切换阅读方式不会丢掉收藏、离线保存、跟踪等入口。
   *
   * 顺序按「保存订阅 → 阅读视图 → 外部动作」三段：收藏 / 离线保存 / 跟踪 →
   * 只看楼主 / 切换阅读方式 → 从网页打开 / 分享。
   *
   * **不提供菜单内刷新**：树页刷新要重抓全帖（4 路并发 + 限流，长帖可达数十秒，期间整页为
   * 加载态），代价在整份菜单里最高，不放进多功能下拉；需要重抓时重新进入帖子（内容已可见
   * 时的失败态另有错误条重试），部分数据也不引入断点续传。
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
   *
   * 重建走增量管线（保留展开状态 + 目标判定）；只看楼主切换会改变行数，
   * diff 会退化为 RELOAD，因此这里显式记录锚点并在重建后居中。
   */
  private toggleAuthorOnly(): void {
    if (!this.hasThreadAuthorKey) {
      appStore.showToast('无法识别楼主，暂不支持只看楼主')
      return
    }
    const anchorPid: number = this.currentCenterPid()
    this.authorOnly = !this.authorOnly
    // 树尚未就绪（首次加载/刷新中）：只更新状态，后续提交会按新状态建树
    if (!this.treeReady || this.treeModel === null) {
      return
    }
    this.rebuildTreePreservingState()
    // 只看楼主切换后自己会按中心行定位，跳过锚点补偿，避免「补偿 + 居中」双跳
    this.applyRowsToDataSource(true)
    this.evaluatePendingTarget()
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
   * 入口只有更多菜单「切换为列表阅读」（`ENTERING` 阶段菜单就可用，因此加载中的
   * 用户同样能切走；页内不再有「以常规列表打开」按钮）：
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
        if (this.phase === TreePagePhase.ENTERING) {
          this.LoadingState()
        } else if (this.phase === TreePagePhase.FAILED && !this.treeReady) {
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

      if (this.treeReady) {
        this.BottomBar()
      }
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg).alignContent(Alignment.BottomEnd)
  }

  /**
   * 进入阶段（第 1 页未回）的加载态。
   *
   * 与列表页 `ThreadPanel.LoadingState` **完全同构**：只有居中加载圈，不提供任何页内
   * 出口——退出走标题栏返回 / 系统返回手势（`aboutToDisappear` 里的 `cancelWork()`
   * 会终止在途抓取、不泄漏请求），切换列表走更多菜单「切换为列表阅读」（`ENTERING`
   * 阶段即可用）。增量模型下这一屏通常只出现不到一秒（第 1 页一到即切到树），因此再叠
   * 一道 400ms 延迟淡入（`enteringLoadingOpacity`）：缓存命中 / 快路径完全不闪 loading。
   */
  @Builder
  LoadingState() {
    Column() {
      Column() {
        LoadingStateView()
      }.opacity(this.enteringLoadingOpacity)
    }
    .width('100%').layoutWeight(1)
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .padding({ top: NAV_BAR_H + this.statusBarHeight })
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
  }

  /**
   * 无内容可展示时的失败态（第 1 页失败 / 停止在第一页到达前）。
   *
   * 已经有内容时**不再进这一屏**：内容保留，由底部进度胶囊的错误态告知（§3.8）。
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
    }
    .width('100%').layoutWeight(1)
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .padding({ top: NAV_BAR_H + this.statusBarHeight })
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
  }

  /**
   * 加载进度胶囊（与列表页页码指示器**同款**：页面底部、HDS 沉浸光感材质）。
   *
   * 位置与 `ThreadPanel.BottomBar` 的页码条一致——底部栏内、回复按钮左侧，材质块高 40、
   * 与回复按钮底边对齐。表达只剩「进度数字 + 动作」，没有进度条与目标刻度：
   * - 加载中 / 等待定位目标 → `12/29` + 停止（等待目标没有独立的取消入口，停止即放弃）；
   * - 停止中 → `正在停止…`；
   * - 失败 → `加载失败` + 重试（详细原因见尾部文案与无障碍描述）。
   *
   * **加载结束（完成/停止）后转为常驻的 `LOADED`**（`ThreadTreeLocatePolicy.resolveBannerMode`
   * 返回 `LOADED`）：只显示 `N/X`，没有图标、没有动作；只有 `ENTERING` 不渲染。
   *
   * 视觉不写长句——「在等什么」「为什么失败」只进 `accessibilityText`，这是数字 + 动作
   * 指示器的最小表达。HDS 硬约束见 `docs/IMMERSIVE_LIGHT_DESIGN.md` §12.9：`barWidth` 显式、
   * 内容宽度与材质块对齐（数字宽实测、动作按实际宽度紧跟，**不用 SpaceBetween 把动作推到最右**）、
   * 动作不传宿主 `onTap`（命中区只包住图标/文字，避免点数字也触发「停止」）、
   * 动作容器写 `'100%'` 高度（写死 40 会被 HDS 内容区顶偏）、内容整体 `offset` 垂直补偿。
   */
  @Builder
  ProgressBanner() {
    Stack() {
      HdsMaterialHost({ barWidth: this.bannerBarWidth(), barHeight: TREE_BANNER_H }) {
        Row({ space: TREE_BANNER_GAP }) {
          if (this.bannerMode === TreeBannerMode.ERROR) {
            Text('!').fontSize(TREE_BANNER_FONT).fontColor(AppColors.destructive)
              .fontWeight(FontWeight.Bold).width(TREE_BANNER_ICON_W)
              .textAlign(TextAlign.Center)
          } else if (this.bannerMode !== TreeBannerMode.LOADED) {
            LoadingProgress().width(TREE_BANNER_ICON_W).height(TREE_BANNER_ICON_W)
              .color(UIMaterialManager.adaptiveForeground)
          }
          Text(this.bannerText())
            .fontSize(TREE_BANNER_FONT)
            .fontColor(this.bannerMode === TreeBannerMode.ERROR
              ? AppColors.destructive : UIMaterialManager.adaptiveForeground)
            .width(this.bannerTextWidth())
            .textAlign(TextAlign.Start)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.bannerMode === TreeBannerMode.LOADING ||
            this.bannerMode === TreeBannerMode.LOADING_WAIT) {
            // 停止：SVG 图标。**布局宽 = 图标宽**（视觉间距精确等于 GAP），
            // 40×40 热区用 responseRegion 外扩、不占布局（容器高走 '100%'，见文件头 §12.9 的坑）
            Stack() {
              Image($r('app.media.icon_stop'))
                .width(TREE_BANNER_STOP_ICON).height(TREE_BANNER_STOP_ICON)
                .fillColor(UIMaterialManager.adaptiveForeground)
                .draggable(false)
            }
            .width(TREE_BANNER_STOP_ICON).height('100%')
            .alignContent(Alignment.Center)
            .hitTestBehavior(HitTestMode.Block)
            .responseRegion({
              x: -(TREE_BANNER_TOUCH - TREE_BANNER_STOP_ICON) / 2,
              y: 0,
              width: TREE_BANNER_TOUCH,
              height: TREE_BANNER_TOUCH
            })
            .onClick((): void => {
              this.stopLoading()
            })
          } else if (this.bannerMode === TreeBannerMode.ERROR) {
            Text('重试')
              .fontSize(TREE_BANNER_FONT)
              .fontColor(AppColors.destructive)
              .fontWeight(FontWeight.Medium)
              .width(TREE_BANNER_RETRY_W).height('100%')
              .textAlign(TextAlign.Center)
              .hitTestBehavior(HitTestMode.Block)
              .responseRegion({
                x: -(TREE_BANNER_TOUCH - TREE_BANNER_RETRY_W) / 2,
                y: 0,
                width: TREE_BANNER_TOUCH,
                height: TREE_BANNER_TOUCH
              })
              .onClick((): void => {
                this.loadTree(true)
              })
          }
        }
        // 内容宽度 = 材质块宽度（首尾各离边 TREE_BANNER_PAD）；写 '100%' 会跟着 HDS 页签项偏移（§12.9）。
        // 各段宽度都是显式值（数字实测、动作为图标/文字实际宽），Row 的 space 提供统一间距。
        .width(this.bannerBarWidth())
        .height('100%')
        .constraintSize({ minHeight: TREE_BANNER_H })
        .padding({ left: TREE_BANNER_PAD, right: TREE_BANNER_PAD, top: 0, bottom: 0 })
        .alignItems(VerticalAlign.Center)
        .offset({ y: TREE_BANNER_CONTENT_OFFSET_Y })
        .accessibilityText(this.bannerAccessibilityText())
      }
    }
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
  }

  /**
   * 材质块宽度（vp）：显式数值，由内容各段相加（HDS 悬浮栏不能由内容撑开，§12.9）。
   *
   * - `LOADED`：数字区 + 两端 padding（无图标、无动作）；
   * - 加载中：图标 + 间距 + 数字区 + 间距 + 停止按钮；
   * - 停止中：图标 + 间距 + 数字区；
   * - 失败：图标 + 间距 + 数字区 + 间距 + 重试按钮。
   *
   * @returns 材质块宽度
   */
  private bannerBarWidth(): number {
    let width: number = TREE_BANNER_PAD * 2 + this.bannerTextWidth()
    if (this.bannerMode !== TreeBannerMode.LOADED) {
      width += TREE_BANNER_ICON_W + TREE_BANNER_GAP
    }
    if (this.bannerMode === TreeBannerMode.LOADING || this.bannerMode === TreeBannerMode.LOADING_WAIT) {
      width += TREE_BANNER_GAP + TREE_BANNER_STOP_ICON
    } else if (this.bannerMode === TreeBannerMode.ERROR) {
      width += TREE_BANNER_GAP + TREE_BANNER_RETRY_W
    }
    return width
  }

  /**
   * 数字区 / 文案宽度（vp）。
   *
   * 优先用 {@link bannerTextW}（`MeasureUtils.measureText` 实测）；测量尚未完成（UI 上下文
   * 未就绪）时按字符类型兜底，保证胶囊不会缩成 0 宽。
   *
   * @returns 文本宽度
   */
  private bannerTextWidth(): number {
    if (this.bannerTextW > 0) {
      return this.bannerTextW
    }
    return this.estimateTextWidth(this.bannerMeasureText())
  }

  /**
   * 兜底估算（仅在 `measureText` 失败时使用）：CJK 按 14vp/字、其余按 8vp/字。
   *
   * 宁可略宽也不能偏窄——偏窄会让文字被省略。旧实现统一按 8vp/字，中文文案
   * （「加载失败」「正在停止…」）会被估成实际宽度的一半。
   *
   * @param text - 待估算文本
   * @returns 估算宽度（vp）
   */
  private estimateTextWidth(text: string): number {
    let width: number = 0
    for (let i: number = 0; i < text.length; i++) {
      width += text.charCodeAt(i) > 255 ? 14 : 8
    }
    return width
  }

  /**
   * 用于测量宽度的文本。
   *
   * 数字态按**当前文本**（`committed/total`）测量：数字与停止图标之间恒定 `GAP`，
   * 不预留未来位数。按 `total/total` 预留会让 `8/5138` 这类早期进度在数字右侧空出一大段
   * （5138 页的帖已实测到）。数字进位（9→10 等）时胶囊随内容变宽、动作右移，属正常排版。
   *
   * @returns 待测量文本（空串表示无需测量）
   */
  private bannerMeasureText(): string {
    if (this.bannerMode === TreeBannerMode.ERROR) {
      return '加载失败'
    }
    if (this.bannerMode === TreeBannerMode.STOPPING) {
      return '正在停止…'
    }
    const total: number = this.totalPages > 0 ? this.totalPages : this.progressTotal
    if (total <= 0) {
      return ''
    }
    return formatCompactProgress(this.committedPages, total)
  }

  /**
   * 重新测量文案宽度（状态或总页数变化时由 {@link refreshBanner} 调用）。
   *
   * 同一文本不重复测量（每次进度提交都会走一遍 refreshBanner）；测量失败不缓存文本，
   * 下次刷新会重试。
   */
  private updateBannerTextWidth(): void {
    const text: string = this.bannerMeasureText()
    if (text.length === 0) {
      this.bannerTextW = 0
      this.bannerMeasuredText = ''
      return
    }
    if (text === this.bannerMeasuredText && this.bannerTextW > 0) {
      return
    }
    const width: number = this.measureTextVp(text)
    this.bannerTextW = width
    this.bannerMeasuredText = width > 0 ? text : ''
  }

  /**
   * 用 UIContext 的 `MeasureUtils.measureText` 实测文本宽度并换算成 vp。
   *
   * 与 `Text` 渲染用同一套字体度量，宽度不是估算值——这是材质块能贴合内容的前提。
   * 测量失败（UI 上下文未就绪 / 字体服务异常）返回 0，由 {@link bannerTextWidth} 兜底。
   *
   * @param text - 待测量文本
   * @returns 宽度（vp）；失败为 0
   */
  private measureTextVp(text: string): number {
    try {
      const px: number = this.getUIContext().getMeasureUtils().measureText({
        textContent: text,
        fontSize: TREE_BANNER_FONT
      })
      return Math.ceil(this.getUIContext().px2vp(px))
    } catch (e) {
      logger.warn('tree-panel measure banner text failed: %{public}s', formatError(e))
      return 0
    }
  }

  /**
   * 胶囊主文案（**视觉极简**：只有「已提交页/总页数」，失败时只有「加载失败」）。
   *
   * @returns 文案
   */
  private bannerText(): string {
    if (this.bannerMode === TreeBannerMode.ERROR) {
      return '加载失败'
    }
    if (this.bannerMode === TreeBannerMode.STOPPING) {
      return '正在停止…'
    }
    // 总页数在第 1 页提交前未知：用 onProgress 的 total 兜底，避免闪出「12/0」
    const total: number = this.totalPages > 0 ? this.totalPages : this.progressTotal
    return formatCompactProgress(this.committedPages, total)
  }

  /** @returns 主动作文案（空串表示无；胶囊不提供「前往」，那是 Toast 的职责） */
  private bannerPrimaryAction(): string {
    if (this.bannerMode === TreeBannerMode.LOADING || this.bannerMode === TreeBannerMode.LOADING_WAIT) {
      return '停止'
    }
    if (this.bannerMode === TreeBannerMode.ERROR) {
      return '重试'
    }
    return ''
  }

  /**
   * 胶囊的无障碍描述。
   *
   * @returns 描述文本
   */
  private bannerAccessibilityText(): string {
    const text: string = this.bannerA11yText()
    const action: string = this.bannerPrimaryAction()
    if (action.length === 0) {
      return text
    }
    return text + '，双击' + action
  }

  /**
   * 胶囊的**完整语义**（读屏用）。
   *
   * 视觉层只显示 `12/29`（见 {@link bannerText}），读屏用户拿不到视觉上下文，
   * 必须用完整句子补回「在加载什么、在等什么、为什么失败」——同一份口径，两种表达。
   *
   * @returns 完整描述
   */
  private bannerA11yText(): string {
    if (this.bannerMode === TreeBannerMode.ERROR) {
      return this.bannerErrorText.length > 0 ? this.bannerErrorText : '加载失败'
    }
    if (this.bannerMode === TreeBannerMode.LOADING_WAIT) {
      const label: string = this.targetLabel.length > 0 ? this.targetLabel : '目标楼层'
      return formatWaitTargetText(label, this.committedPages, this.totalPages)
    }
    if (this.bannerMode === TreeBannerMode.LOADING || this.bannerMode === TreeBannerMode.LOADING_WAIT ||
      this.bannerMode === TreeBannerMode.LOADED) {
      return formatLoadingText(this.committedPages, this.totalPages)
    }
    return this.bannerText()
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
    // 只对 LazyForEach 的**增量插入/删除**生效（`onDataReloaded` 不生效）：
    // 这也是数据源必须改走 `onDatasetChange` 的原因
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
         `common/media/ImageAnalyzerSession.ets`。
         锚点补偿是程序化滚动，不是用户主动滚动，不应收起选取态。 */
      if (!this.compensating) {
        dismissAnalyzerSessions()
      }
    })
    .onScrollIndex((start: number, _end: number, center: number): void => {
      this.lastScrollStart = start
      this.lastScrollCenter = center
      // 锚点补偿/框架锚定引起的滚动不是用户操作：不能据此认为「用户已移动视口」
      if (!this.compensating && !this.navigationPending) {
        // 首行超过一屏时 start 恒为 0，必须同时看 center 才能识别「用户真的滚动了」
        if (start > 0 || center > 0) {
          this.viewportMoved = true
        }
        this.scheduleProgressRecord()
      }
    })
    .onScrollStart((): void => {
      this.scrolling = true
    })
    .onScrollStop((): void => {
      this.scrolling = false
      // 拖拽期间被推迟的增量提交在这里补上（只有真的被推迟过才重排，
      // 否则每次滚动停止都会重放一次同样的重建）
      if (this.commitDeferred) {
        this.commitDeferred = false
        this.scheduleCommit()
      }
      // 就绪 Toast 也可能因滚动被挂起：停手后补发
      if (this.targetToastPending) {
        this.showTargetToast(this.targetToastFiltered)
      }
    })
    .onAppear((): void => {
      this.listMounted = true
      this.syncTitleScrollEffect()
    })
    .onDisAppear((): void => {
      this.listMounted = false
      // 列表在拖拽中被卸载时 onScrollStop 不会再触发，必须复位，否则提交永远被推迟
      this.scrolling = false
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
   * - 部分数据（用户停止 / 页面失败）：文案给出已加载范围；
   * - 有缺页（服务端空页）：把缺页信息并入文案（Toast 会被后续提示覆盖）。
   */
  @Builder
  LoadEndFooter() {
    ListItem() {
      Column() {
        Row({ space: 8 }) {
          if (this.phase === TreePagePhase.STREAMING) {
            LoadingProgress().width(14).height(14).color(AppColors.textTertiary)
          }
          Text(this.loadEndText()).fontSize(13).fontColor(AppColors.textTertiary)
        }
        .width('100%').justifyContent(FlexAlign.Center)
      }
      .width('100%').height(NAV_BAR_H).justifyContent(FlexAlign.Center)
    }
  }

  /**
   * 列表尾部文案（四态，见设计 §3.10）。
   *
   * 加载中给「正在加载 n/N 页…」，完成给「已加载全部回复」，停止/失败给中性的
   * 已加载范围。缺页提示在这里也要保留：Toast 是单条替换语义、会被后续提示覆盖，
   * 尾部是读完最后一行时唯一还能看到的常驻位置。
   *
   * @returns 尾部文案
   */
  private loadEndText(): string {
    if (this.phase === TreePagePhase.STREAMING || this.phase === TreePagePhase.ENTERING) {
      const total: number = this.totalPages > 0 ? this.totalPages : this.progressTotal
      if (total > 0) {
        return '正在加载 ' + String(this.committedPages) + '/' + String(total) + ' 页…'
      }
      return '正在加载…'
    }
    if (this.phase === TreePagePhase.FAILED && this.treeReady) {
      const progress: string = '已加载 ' + String(this.committedPages) + '/' +
        String(this.totalPages) + ' 页'
      if (this.skippedPageHint.length > 0) {
        return progress + '（' + this.skippedPageHint + '）'
      }
      return progress + '（加载中断）'
    }
    if (this.phase === TreePagePhase.STOPPED) {
      const progress: string = '已加载 ' + String(this.committedPages) + '/' +
        String(this.totalPages) + ' 页'
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
   * 底部悬浮栏：加载进度胶囊 + 回复按钮。
   *
   * 与列表页 `ThreadPanel.BottomBar` 同构（页码条 + 回复按钮）：两块都是 HDS 材质宿主、
   * 高 40、`Row({ space: 8 })` 并排、底边对齐；右/左手握持只影响整排的起始侧。
   * 进度胶囊在加载中与加载结束后**都常驻**（结束后只显示 `N/X`），宽度随内容变化：
   * 右手握持时回复按钮固定贴右、胶囊只在它左侧伸缩（回复按钮不位移）；左手握持整排从左排起，
   * 胶囊变窄时回复按钮会左移（与列表页页码条同一行为）。
   */
  @Builder
  BottomBar() {
    Row({ space: 8 }) {
      if (this.bannerVisible) {
        this.ProgressBanner()
      }
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
    .alignItems(VerticalAlign.Center)
    .justifyContent(this.holdingStatus === HoldingHandStatus.LEFT_HAND_HELD ? FlexAlign.Start : FlexAlign.End)
  }
}
