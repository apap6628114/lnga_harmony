import { BBNode, BBNodeType } from '../../model/BBCodeNode'
import { AppColors, ImageLoadStrategy } from '../constants/Constants'
import { getEmotionResource, isEmotionCategoryNeedDarkBg } from '../media/EmotionResources'
import { AudioPlayer } from '../media/AudioPlayer'
import { MutedVideo } from '../media/MutedVideo'
import { ImageSize, getCachedImageSize, setCachedImageSize } from '../media/ImageSizeUtil'
import { MovingPhotoPlayer } from '../media/MovingPhotoPlayer'
import { registerMovingPhoto } from '../media/MovingPhotoRegistry'
import {
  dismissAnalyzerSessions,
  registerAnalyzerSession,
  unregisterAnalyzerSession,
} from '../media/ImageAnalyzerSession'
import { createTextOnlyAnalyzerOptions } from '../media/ImageAnalyzerOptions'
import { fetchVideoSize, getCachedVideoSize } from '../media/VideoSizeUtil'
import { shouldUsePassive } from '../utils/NetworkUtil'
import { parsePreviewSize } from '../utils/TopicPreviewUtils'
import { LengthMetrics } from '@kit.ArkUI'
import {
  isInlineNode,
  isInlineRunsBlank,
  applyInlineFormatTags,
  applyTextStyleDeclaration,
  cloneInlineTextStyle,
  extractTextStyleAlign,
  flattenInlineNodes,
  InlineRun,
  InlineRunKind,
  InlineTextStyle,
} from './bbcode/bbcode-utils'
import {
  RenderContext,
  NodeGroup,
  splitQuoteChildren,
  isQuoteFromBlacklistedUser,
  QUOTE_BORDER_COLORS,
  QuoteSplit,
} from './bbcode/BBCodeRenderContext'
import {
  inlineFontSize,
  inlineLineHeight,
  fallbackFontSize,
  codeFontSize,
  codeLineHeight,
  inlineRunFontSize,
  inlineRunBaselineOffset,
  inlineEmotionSize,
  inlineGroupLineHeight,
} from './bbcode/BBCodeMetrics'
import {
  buildTableLayout,
  TableLayout,
  TableLayoutCell,
  TableLayoutRow,
} from './bbcode/table-layout'
import { appStore } from '../../store/AppStore'
import { decodeAnonymousName } from '../../parser/AnonymousParser'

/** 单个 BBCode 视图允许缓存的最大内联节点组数量。 */
const MAX_INLINE_RUN_CACHE_SIZE: number = 4096

/**
 * 正文图长按判定阈值（ms）：识图会话的主要入口。
 *
 * 取 400ms 是对 **ArkUI 长按手势默认阈值 500ms**（`LongPressGesture.md`：「默认最短长按时间为
 * 500 毫秒」）留的提前量——分析器内部的阈值官方**未公开**，只能按手势默认值推断。留提前量是为了
 * 应付"分析器接管这次按下之后本组件收不到 `Up`"：计时器必须先在 400ms 触发，会话才判得出来。
 * 万一分析器阈值更短、抢先投递 `Cancel`，由 {@link ANALYZER_CANCEL_FALLBACK_MS} 的补判兜住。
 */
const ANALYZER_LONG_PRESS_MS: number = 400

/**
 * `Cancel` 补判阈值（ms）：按下被别的角色接管时，按住超过它且期间没有位移，就按长按处理。
 *
 * **只对 `Cancel` 补判、不对 `Up` 补判**：`Cancel` 意味着这次按下不是点击，补判出来的会话最坏
 * 只是让"下一次单击图片"被吞一次（且滚动一开始就会被收掉）；若对 `Up` 也补判，一次三百毫秒的
 * 慢点击就会被当成取消，直接吞掉用户真正想看的那次点击。
 */
const ANALYZER_CANCEL_FALLBACK_MS: number = 250

/** 长按判定的移动容忍度（vp）：按下后位移超过它即按滚动 / 拖拽处理，不成立长按。 */
const ANALYZER_LONG_PRESS_SLOP: number = 10

/**
 * 拆除分析器后重新武装的延时（ms）。
 *
 * 必须跨帧：`false` → `true` 若落在同一帧的状态批处理里会被合并成空操作，分析器根本不会
 * 被拆掉。150ms 远小于"抬手再按下并保持 400ms"所需时间，用户感知不到这段窗口。
 *
 * 代价：一次取消会让该正文组件整树重渲染两次；因为无会话时不会走到这里（登记表空表早退），
 * 只有真正长按过识图的楼层会付这个成本。
 */
const ANALYZER_REARM_DELAY_MS: number = 150

/**
 * 单个内联节点组的样式安全缓存项。
 */
class InlineRunCacheEntry {
  /** 节点组最后一个节点的标识。 */
  lastNodeId: number
  /** 节点组长度。 */
  nodeCount: number
  /** 生成 Run 时使用的继承样式快照。 */
  style: InlineTextStyle
  /** 已完成继承合并的内联 Run。 */
  runs: InlineRun[]

  /**
   * 创建内联 Run 缓存项。
   *
   * @param lastNodeId 节点组最后一个节点的标识
   * @param nodeCount 节点组长度
   * @param style 继承样式快照
   * @param runs 已扁平化的 Run
   */
  constructor(lastNodeId: number, nodeCount: number, style: InlineTextStyle, runs: InlineRun[]) {
    this.lastNodeId = lastNodeId
    this.nodeCount = nodeCount
    this.style = style
    this.runs = runs
  }
}

/**
 * 将 BBCode 语义节点渲染为支持文字、链接、媒体和结构块的 ArkUI 组件。
 */
@Component
export struct BBCodeContentView {
  /** 待渲染的 BBCode 根节点。 */
  nodes: BBNode[] = []
  /** 当前已展开的折叠块键。 */
  @State collapseKeys: Set<string> = new Set()
  /** 已知图片尺寸缓存。 */
  @State private imageSizes: Map<string, ImageSize> = new Map()
  /** 已完成加载的图片地址。 */
  @State private loadedImages: Set<string> = new Set()
  /** 加载失败的图片地址。 */
  @State private failedImages: Set<string> = new Set()
  /** 已允许释放占位约束的图片地址。 */
  @State private releasedImages: Set<string> = new Set()
  /** 正在就地播放动态照片的封面地址（空串表示没有就地播放）。 */
  @State private playingMovingPhotoSrc: string = ''
  /** 已知视频尺寸缓存。 */
  @State private videoSizes: Map<string, ImageSize> = new Map()
  /** 当前生效的亮暗色模式。 */
  @StorageProp('effectiveColorMode') effectiveColorMode: string = 'light'
  /** 网络状态变化版本号。 */
  @StorageProp('networkChangeVersion') networkChangeVersion: number = 0
  /** 图片加载策略。 */
  @StorageProp('imageLoadStrategy') imageLoadStrategy: string = ImageLoadStrategy.ALWAYS
  /** 用户设置的正文基础字号。 */
  @StorageProp('contentFontSize') contentFontSize: number = 15
  /** 黑名单变更版本号。 */
  @StorageProp('blacklistVersion') @Watch('onBlacklistVersionChange') blacklistVersion: number = 0
  /** 是否隐藏加载失败的图片。 */
  hideFailedImages: boolean = false
  /** 图片点击回调。 */
  onImageClick: (urls: string[], index: number) => void = (_urls: string[], _index: number) => {}
  /** 链接点击回调。 */
  onLinkClick: (href: string) => void = (_href: string) => {}

  /**
   * 正文图是否允许系统 AI 图像分析（长按识图）。
   *
   * **取消选取态靠把它翻成 false 再翻回来**：`Image` 侧没有"清除选区"接口，关掉开关让
   * 分析器整体拆除是唯一可用的杠杆（见 `ImageAnalyzerSession` 文件头）。绑定的是同一个
   * 开关，因此**本组件内所有图**共用一次拆除动作。
   */
  @State private analyzerEnabled: boolean = true
  /** 当前是否处于识图会话中（长按成立置位，被取消后复位）。 */
  private analyzerSessionActive: boolean = false
  /** 会话归属的图片地址：单击**同一张**图只取消选取态，单击别的图照常进查看器。 */
  private analyzerSessionSrc: string = ''
  /** 会话句柄（登记表的注销凭据，0 表示无会话）。 */
  private analyzerSessionToken: number = 0
  /** 长按判定计时器句柄（-1 表示未在计时）。 */
  private longPressTimer: number = -1
  /** 长按判定的按下点（窗口坐标，vp）。 */
  private longPressX: number = 0
  /** 长按判定的按下点（窗口坐标，vp）。 */
  private longPressY: number = 0
  /** 长按判定计时归属的图片地址。 */
  private longPressSrc: string = ''
  /** 本次按下的起点时间（ns，取自 `TouchEvent.timestamp`），用于 `Cancel` 的时长补判。 */
  private longPressDownNs: number = 0
  /** 本次按下是否已位移超限（超限即滚动 / 拖拽，`Cancel` 不再补判为长按）。 */
  private longPressMoved: boolean = false
  /** 本次按下是否已由长按判定成立过会话：用于区分"这次按下就是长按"与"长按之后的又一次单击"。 */
  private longPressEstablished: boolean = false
  /**
   * 已在图片的 `Up` 上取消过会话，抑制紧随其后的 `onClick` 进查看器。
   *
   * 分析器浮层盖在图上，单击可能被它消费掉、`onClick` 根本不触发，所以取消不能只挂在 `onClick`
   * 上；在 `Up` 上取消之后必须再把这次点击按下去，否则"第一次点击只取消选取态"会退化成"取消并
   * 进查看器"。下一次按下即复位，标记不会外泄到后续触摸。
   */
  private suppressImageTap: boolean = false
  /** 本次触摸是否落在正文图上（由图片的 onTouch 维护，根容器在 Down 时取走）。 */
  private touchLandedOnImage: boolean = false
  /** 本次触摸是否**起始于**正文图（根容器在 Down 时快照，Up 时据此让位给图片自己的点击）。 */
  private touchStartedOnImage: boolean = false
  /** 重新武装分析器的计时器句柄（-1 表示未在计时）。 */
  private analyzerRearmTimer: number = -1

  /** 当前内容内可供图片查看器浏览的地址。 */
  private allImageUrls: string[] = []
  /** 按节点组与继承样式缓存的内联渲染结果。 */
  private inlineRunCache: Map<number, InlineRunCacheEntry> = new Map<number, InlineRunCacheEntry>()

  /**
   * 初始化节点分组并恢复已缓存的媒体尺寸（零网络请求）。
   *
   * 尺寸来源有两条**同步**通路，优先级自上而下：
   *  1. 进程级缓存（同会话内已加载过的图片 / 已探测过的视频）；
   *  2. NGA 附件文件名尺寸段 `S{base36宽}-{base36高}`（`parsePreviewSize`）。
   *
   * 两条都落空（外站图片 / 无尺寸段的老附件）才回落到 `onImageLoaded` 回填或
   * `fetchVideoSize` 元数据探测。**不回落到"预热请求"**：图片侧的 Range 预取会让请求数
   * 翻倍、易触发服务端节流，尺寸段已能覆盖绝大多数 NGA 附件。
   */
  aboutToAppear(): void {
    this.inlineRunCache.clear()
    this.cachedGroups = this.splitIntoGroups(this.nodes)
    this.groupsReady = true
    this.allImageUrls = this.getImageUrls()
    const urls: string[] = this.allImageUrls
    for (let i = 0; i < urls.length; i++) {
      const url: string = urls[i]
      const cached: ImageSize | null = getCachedImageSize(url)
      if (cached) {
        this.imageSizes.set(url, cached)
        this.releasedImages.add(url)
      } else {
        /* 尺寸段同步解出 → 首帧即按真实比例定高，`onComplete` 回填时 `imageSizes` 已有值，
           不再覆盖（见 `onImageLoaded` 的 has 守卫），正文因此不会出现高度跳变。 */
        const parsed: ImageSize | null = parsePreviewSize(url)
        if (parsed !== null) {
          this.imageSizes.set(url, parsed)
        }
      }
    }

    const vUrls: string[] = this.getVideoUrls()
    for (let i = 0; i < vUrls.length; i++) {
      const url: string = vUrls[i]
      const cached: ImageSize | null = getCachedVideoSize(url)
      if (cached) {
        this.videoSizes.set(url, cached)
        continue
      }
      /* 视频与图片同一套尺寸段规则，且尺寸段编码的是**旋转后的显示尺寸**（实测 6/6：
         编码 1280×720 + rotate 90° 的文件，尺寸段为 `Sk0-zk` = 720×1280），
         与 `AVMetadataExtractor` + `applyOrientation` 的语义完全一致。 */
      const parsed: ImageSize | null = parsePreviewSize(url)
      if (parsed !== null) {
        this.videoSizes.set(url, parsed)
      }
    }
    /* 仅对尺寸段解不出的视频（外站视频 / 无尺寸段老附件）发起元数据请求：
       该网络路径从"每个视频必经"降为"少数兜底"。 */
    for (let i = 0; i < vUrls.length; i++) {
      const url: string = vUrls[i]
      if (!this.videoSizes.has(url)) {
        fetchVideoSize(url).then((size: ImageSize | null) => {
          if (size) {
            this.setVideoSize(url, size)
          }
        })
      }
    }
  }

  /**
   * 组件销毁：注销可能仍挂着的识图会话，避免登记表持有已销毁组件的拆除回调。
   *
   * 列表回收楼层时正文组件会被整体销毁，而选取态会话是**跨组件**登记的（宿主列表滚动时
   * 仍可能触发它），因此这里必须显式退场。
   */
  aboutToDisappear(): void {
    this.clearAnalyzerTimers()
    unregisterAnalyzerSession(this.analyzerSessionToken)
    this.analyzerSessionToken = 0
    this.analyzerSessionActive = false
    this.analyzerSessionSrc = ''
  }

  /**
   * 响应黑名单变化，立即更新图片查看器允许访问的图片集合。
   */
  private onBlacklistVersionChange(): void {
    this.allImageUrls = this.getImageUrls()
  }

  /**
   * 记录图片加载失败。
   *
   * @param url 图片地址
   */
  private markImageFailed(url: string): void {
    if (!this.failedImages.has(url)) {
      this.failedImages.add(url)
    }
    this.loadedImages.add(url)
  }

  /**
   * 解除图片占位约束。
   *
   * @param url 图片地址
   */
  private releaseImage(url: string): void {
    this.releasedImages.add(url)
  }

  /**
   * 处理图片加载完成事件并补充实际尺寸。
   *
   * @param src 图片地址
   * @param imgWidth 实际宽度
   * @param imgHeight 实际高度
   */
  private onImageLoaded(src: string, imgWidth?: number, imgHeight?: number): void {
    this.loadedImages.add(src)
    if (imgWidth !== undefined && imgHeight !== undefined && imgWidth > 0 && imgHeight > 0) {
      if (!this.imageSizes.has(src)) {
        const size: ImageSize = new ImageSize()
        size.width = imgWidth
        size.height = imgHeight
        this.imageSizes.set(src, size)
        this.releasedImages.add(src)
        /* 回填进程级缓存：同会话内再次渲染该图片时直接复用，零额外请求 */
        setCachedImageSize(src, size)
      }
    }
  }

  /**
   * 返回图片宽高比，未知时使用安全占位比例。
   *
   * `aboutToAppear` 已按"缓存 → 尺寸段"顺序预填 `imageSizes`；这里的尺寸段兜底覆盖
   * 未被 `allImageUrls` 收集到的地址（例如折叠块内的图），保证**任何**能解出尺寸段的图片
   * 都走同步比例，而不是先按 16:9 撑开、再由 `onComplete` 回填引起高度跳变。
   *
   * @param src 图片地址
   * @returns 图片宽高比
   */
  private getImageAspectRatio(src: string): number {
    const size: ImageSize | undefined = this.imageSizes.get(src)
    if (size && size.width > 0 && size.height > 0) {
      return size.width / size.height
    }
    const parsed: ImageSize | null = parsePreviewSize(src)
    if (parsed !== null && parsed.width > 0 && parsed.height > 0) {
      return parsed.width / parsed.height
    }
    return 16 / 9
  }

  /**
   * 返回图片在查看器地址数组中的索引。
   *
   * @param src 图片地址
   * @returns 图片索引
   */
  private getImageIndex(src: string): number {
    for (let i = 0; i < this.allImageUrls.length; i++) {
      if (this.allImageUrls[i] === src) {
        return i
      }
    }
    return 0
  }

  /**
   * 正文根容器触摸：点击正文任意位置（含链接、折叠块、动态照片角标等可点元素）都取消识图选取态。
   *
   * 用 `onTouch` 而不是 `onClick`：点击本身是手势，父子组件绑定的同类手势会**竞争**且只有一个能
   * 响应（正文内每个可点元素都自带 onClick），而触摸事件沿响应链自叶向根**冒泡**，根容器必定收得到，
   * 一处即可覆盖全部可点元素。
   *
   * @param event 触摸事件
   */
  private onContentTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      /* 事件先到叶子、再冒泡到父级：图片节点的 onTouch 已先于本回调执行，因此这里取到的就是
         "本次触摸是否落在正文图上"。取走后立即复位，避免图片的 Up 被分析器吃掉时把标记留给
         下一次触摸（那会让随后点击正文文字被误判成"点在图上"而不取消）。 */
      this.touchStartedOnImage = this.touchLandedOnImage
      this.touchLandedOnImage = false
      /* 抑制标记只对"紧跟着那一次 Up 的点击"有效：新的一次按下即作废（分析器若把 Up 与 onClick
         一起吃掉，标记不会外泄到之后的点击上）。 */
      this.suppressImageTap = false
      return
    }
    if (event.type === TouchType.Up) {
      /* 落在正文图上的点击让位给图片自己的 onTouch / onClick（要区分"只取消选取态"与"进查看器"）；
         其余位置（正文文字、链接、折叠块、角标…）一律取消选取态。 */
      if (!this.touchStartedOnImage) {
        dismissAnalyzerSessions()
      }
      this.touchStartedOnImage = false
      return
    }
    if (event.type === TouchType.Cancel) {
      this.touchStartedOnImage = false
    }
  }

  /**
   * 正文图触摸：判定长按（识图会话的入口）并在抬手时收掉残留选区。
   *
   * 刻意**不注册 `LongPressGesture`**：绑定到组件上的长按手势会与分析器内部的长按**竞争**
   * （`draggable(false)` 之后这类手势是生效的），本组件赢下长按的同时也就掐掉了系统识图。
   * 改用 `onTouch` 计时：原始触摸事件不参与手势竞争，判定结果只用于后续"取消 / 进查看器"分流，
   * 不消费任何事件，识图本身仍完全由系统接管。
   *
   * @param event 触摸事件
   * @param src 本次触摸所在图片的地址
   */
  private onImageTouch(event: TouchEvent, src: string): void {
    if (event.type === TouchType.Down) {
      this.touchLandedOnImage = true
      this.longPressEstablished = false
      this.longPressMoved = false
      this.longPressDownNs = event.timestamp
      this.startLongPressTimer(event, src)
      return
    }
    if (event.type === TouchType.Move) {
      this.abortLongPressOnMove(event)
      return
    }
    /* Up / Cancel：这一次按下已经结束，没成立的长按不再成立。 */
    this.touchLandedOnImage = false
    const heldNs: number = event.timestamp - this.longPressDownNs
    this.clearLongPressTimer()
    if (event.type === TouchType.Cancel) {
      /* 按下被别的角色接管（分析器长按 / 容器手势）。分析器阈值未公开，若它短于本组件阈值，
         计时会被这次 Cancel 抢掉、会话永远判不出来——用"按住够久且没位移"补判一次。 */
      if (!this.longPressMoved && heldNs >= ANALYZER_CANCEL_FALLBACK_MS * 1000000) {
        this.establishAnalyzerSession(src)
      }
      return
    }
    /* Up：长按之后的**又一次**单击在这里就取消选取态。
       不能只挂在图片的 onClick 上：分析器浮层盖在图上，这次点击可能被它消费掉，那时 onClick
       不触发，选区就再也收不掉了。取消后抑制这次点击，保住"第一次点击只取消、不进查看器"。 */
    if (this.analyzerSessionActive && !this.longPressEstablished) {
      const isSessionOwner: boolean = this.analyzerSessionSrc === src
      this.endAnalyzerSession()
      if (isSessionOwner) {
        this.suppressImageTap = true
      }
    }
  }

  /**
   * 启动长按判定计时。
   *
   * @param event 触摸事件
   * @param src 本次触摸所在图片的地址
   */
  private startLongPressTimer(event: TouchEvent, src: string): void {
    this.clearLongPressTimer()
    const points: TouchObject[] = event.touches.length > 0 ? event.touches : event.changedTouches
    if (points.length === 0) {
      return
    }
    this.longPressX = points[0].windowX
    this.longPressY = points[0].windowY
    this.longPressSrc = src
    this.longPressTimer = setTimeout((): void => {
      this.longPressTimer = -1
      this.establishAnalyzerSession(this.longPressSrc)
    }, ANALYZER_LONG_PRESS_MS)
  }

  /**
   * 按下后位移超限即撤销长按判定：这次按下是滚动 / 拖拽，不是识图。
   *
   * @param event 触摸事件
   */
  private abortLongPressOnMove(event: TouchEvent): void {
    if (this.longPressTimer === -1) {
      return
    }
    const points: TouchObject[] = event.touches.length > 0 ? event.touches : event.changedTouches
    if (points.length === 0) {
      return
    }
    if (Math.abs(points[0].windowX - this.longPressX) > ANALYZER_LONG_PRESS_SLOP ||
      Math.abs(points[0].windowY - this.longPressY) > ANALYZER_LONG_PRESS_SLOP) {
      this.longPressMoved = true
      this.clearLongPressTimer()
    }
  }

  /** 撤销长按判定计时。 */
  private clearLongPressTimer(): void {
    if (this.longPressTimer !== -1) {
      clearTimeout(this.longPressTimer)
      this.longPressTimer = -1
    }
  }

  /** 撤销长按判定与重新武装计时（会话结束时使用）。 */
  private clearAnalyzerTimers(): void {
    this.clearLongPressTimer()
    if (this.analyzerRearmTimer !== -1) {
      clearTimeout(this.analyzerRearmTimer)
      this.analyzerRearmTimer = -1
    }
  }

  /**
   * 成立一次识图会话（长按计时触发，或 `Cancel` 时长补判触发）。
   *
   * @param src 会话归属的图片地址
   */
  private establishAnalyzerSession(src: string): void {
    this.longPressEstablished = true
    this.beginAnalyzerSession(src)
  }

  /**
   * 开启识图会话：登记到全局表，使宿主列表滚动、其它楼层的点击也能把它收掉。
   *
   * 同一正文里先后长按两张图时只接管登记、**不做拆除**：此刻新图的分析器可能刚刚起来，
   * 翻一次开关会连它一起拆掉；旧图残留的选区由系统在新的长按成立时自行处理。
   *
   * @param src 会话归属的图片地址
   */
  private beginAnalyzerSession(src: string): void {
    unregisterAnalyzerSession(this.analyzerSessionToken)
    this.analyzerSessionActive = true
    this.analyzerSessionSrc = src
    this.analyzerSessionToken = registerAnalyzerSession((): void => {
      this.endAnalyzerSession()
    })
  }

  /**
   * 结束识图会话并拆掉分析器：关一次开关（选取态与系统文本菜单一并消失），随后重新武装。
   *
   * 幂等：登记表里只会有存活会话，重复调用最多多翻一次开关，不改变最终状态。
   */
  private endAnalyzerSession(): void {
    unregisterAnalyzerSession(this.analyzerSessionToken)
    this.analyzerSessionToken = 0
    this.analyzerSessionActive = false
    this.analyzerSessionSrc = ''
    this.clearLongPressTimer()
    this.analyzerEnabled = false
    if (this.analyzerRearmTimer !== -1) {
      clearTimeout(this.analyzerRearmTimer)
    }
    this.analyzerRearmTimer = setTimeout((): void => {
      this.analyzerRearmTimer = -1
      this.analyzerEnabled = true
    }, ANALYZER_REARM_DELAY_MS)
  }

  /**
   * 正文图点击：会话归属的那张图优先"取消选取态"（这次点击不再进查看器），再点一次才进。
   *
   * 与系统图库 / 聊天软件一致：图上还留着选区时，第一次点击是"退出选取态"。
   * 点击**别的**图（含别的楼层）则先收掉选区、再照常进查看器（点的是另一张图，拦下来反而莫名其妙）。
   *
   * @param src 被点击图片的地址
   */
  private handleImageTap(src: string): void {
    if (this.suppressImageTap) {
      /* 图片 Up 上已经取消过会话（分析器浮层可能连 onClick 一起吃掉，所以取消不能只挂在这里）。 */
      this.suppressImageTap = false
      return
    }
    if (this.longPressEstablished) {
      /* 这一次点击属于**刚成立的那次长按**（长按抬手若仍被判成 click）：既不进查看器，
         也不能把刚建立的选区收掉——否则"长按选字"会被自己的抬手动作立刻取消。 */
      return
    }
    if (this.analyzerSessionActive && this.analyzerSessionSrc === src) {
      this.endAnalyzerSession()
      return
    }
    /* 其余情况先收掉**所有**选区——可能是别的楼层留下的：点别的图/别处文字都该把它收干净。 */
    dismissAnalyzerSessions()
    const urls: string[] = this.allImageUrls.length > 0 ? this.allImageUrls : [src]
    this.onImageClick(urls, this.getImageIndex(src))
  }

  /**
   * 写入视频尺寸。
   *
   * @param url 视频地址
   * @param size 视频尺寸
   */
  private setVideoSize(url: string, size: ImageSize): void {
    this.videoSizes.set(url, size)
  }

  /**
   * 返回视频宽高比，未知时使用安全占位比例。
   *
   * 与图片同一套来源顺序（缓存 → 尺寸段 → 兜底）：尺寸段编码的是**旋转后的显示尺寸**，
   * 因此 `MutedVideo` 首帧得到的就是正确比例，不必等 `fetchVideoSize` 回来再改
   * `aspectRatio`（那正是视频区高度跳变的来源）。
   *
   * @param src 视频地址
   * @returns 视频宽高比
   */
  private getVideoAspectRatio(src: string): number {
    const size: ImageSize | undefined = this.videoSizes.get(src)
    if (size && size.width > 0 && size.height > 0) {
      return size.width / size.height
    }
    const parsed: ImageSize | null = parsePreviewSize(src)
    if (parsed !== null && parsed.width > 0 && parsed.height > 0) {
      return parsed.width / parsed.height
    }
    return 16 / 9
  }

  /**
   * 收集当前节点树内允许访问的视频地址。
   *
   * @returns 视频地址数组
   */
  private getVideoUrls(): string[] {
    return this.collectVideoUrls(this.nodes, true)
  }

  /**
   * 递归收集视频地址。
   *
   * @param nodes 当前节点数组
   * @param skipBlacklistedQuotes 是否跳过黑名单引用
   * @returns 视频地址数组
   */
  private collectVideoUrls(nodes: BBNode[], skipBlacklistedQuotes: boolean): string[] {
    const urls: string[] = []
    for (let i = 0; i < nodes.length; i++) {
      const n = nodes[i]
      if (skipBlacklistedQuotes && n.type === BBNodeType.QUOTE && this.isQuoteBlacklisted(n)) {
        continue
      }
      if (n.type === BBNodeType.VIDEO && n.src.length > 0) {
        urls.push(n.src)
      }
      if (n.children.length > 0) {
        const childUrls = this.collectVideoUrls(n.children, skipBlacklistedQuotes)
        for (let j = 0; j < childUrls.length; j++) {
          urls.push(childUrls[j])
        }
      }
    }
    return urls
  }

  /**
   * 收集当前节点树内允许访问的图片地址。
   *
   * @returns 图片地址数组
   */
  private getImageUrls(): string[] {
    return this.collectUrls(this.nodes, true)
  }

  /**
   * 递归收集图片地址。
   *
   * @param nodes 当前节点数组
   * @param skipBlacklistedQuotes 是否跳过黑名单引用
   * @returns 图片地址数组
   */
  private collectUrls(nodes: BBNode[], skipBlacklistedQuotes: boolean): string[] {
    const urls: string[] = []
    for (let i = 0; i < nodes.length; i++) {
      const n = nodes[i]
      if (skipBlacklistedQuotes && n.type === BBNodeType.QUOTE && this.isQuoteBlacklisted(n)) {
        continue
      }
      if (n.type === BBNodeType.IMAGE && n.src.length > 0) {
        urls.push(n.src)
        if (n.videoSrc.length > 0) {
          /* 动态照片（NGA [b]MPHOTO[/b]）：登记「封面 → 动态视频」关系，
             查看器按当前封面地址反查后改用 MovingPhotoView 播放。 */
          registerMovingPhoto(n.src, n.videoSrc)
        }
      }
      if (n.children.length > 0) {
        const childUrls = this.collectUrls(n.children, skipBlacklistedQuotes)
        for (let j = 0; j < childUrls.length; j++) {
          urls.push(childUrls[j])
        }
      }
    }
    return urls
  }

  /**
   * 判断引用正文是否来自黑名单用户。
   *
   * @param node - 引用块节点
   * @returns 是否应遮蔽引用正文
   */
  private isQuoteBlacklisted(node: BBNode): boolean {
    return this.blacklistVersion >= 0 &&
      isQuoteFromBlacklistedUser(node.children, appStore.settingsStore.getBlacklistIds())
  }

  /** 构建 BBCode 根布局。 */
  build() {
    Column() {
      if (this.nodes.length > 0) {
        this.RenderChildren(this.nodes, new RenderContext())
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    /* 触摸事件沿响应链自叶向根冒泡，根容器一处即可覆盖正文内全部可点元素（见 `onContentTouch`）。 */
    .onTouch((event: TouchEvent): void => {
      this.onContentTouch(event)
    })
  }

  /**
   * 将连续内联节点和独立块节点分组。
   *
   * @param nodes 当前节点数组
   * @returns 渲染分组数组
   */
  private splitIntoGroups(nodes: BBNode[]): NodeGroup[] {
    const groups: NodeGroup[] = []
    let i = 0
    while (i < nodes.length) {
      if (isInlineNode(nodes[i].type)) {
        const inlineNodes: BBNode[] = []
        while (i < nodes.length && isInlineNode(nodes[i].type)) {
          inlineNodes.push(nodes[i])
          i++
        }
        const g = new NodeGroup()
        g.kind = 'inline'
        g.nodes = inlineNodes
        groups.push(g)
      } else {
        const g = new NodeGroup()
        g.kind = 'block'
        g.nodes = [nodes[i]]
        groups.push(g)
        i++
      }
    }
    return groups
  }

  /**
   * 判断两个继承文字样式是否产生相同的 Run。
   *
   * @param left 缓存中的样式快照
   * @param right 当前渲染上下文样式
   * @returns 是否可安全复用缓存
   */
  private areInlineStylesEqual(left: InlineTextStyle, right: InlineTextStyle): boolean {
    return left.bold === right.bold && left.italic === right.italic && left.underline === right.underline &&
      left.strikethrough === right.strikethrough && left.color === right.color &&
      left.scalePercent === right.scalePercent && left.fontFamily === right.fontFamily &&
      left.baseline === right.baseline
  }

  /**
   * 返回内联节点组的扁平化结果，相同节点与继承样式只计算一次。
   *
   * @param nodes 当前内联节点组
   * @param ctx 渲染上下文
   * @returns 可直接渲染的内联 Run
   */
  private getInlineRuns(nodes: BBNode[], ctx: RenderContext): InlineRun[] {
    if (nodes.length === 0) return []
    const key: number = nodes[0].id
    const cached: InlineRunCacheEntry | undefined = this.inlineRunCache.get(key)
    const lastNodeId: number = nodes[nodes.length - 1].id
    if (cached !== undefined && cached.lastNodeId === lastNodeId && cached.nodeCount === nodes.length &&
      this.areInlineStylesEqual(cached.style, ctx.inlineStyle)) return cached.runs
    const runs: InlineRun[] = flattenInlineNodes(nodes, ctx.inlineStyle)
    if (this.inlineRunCache.size >= MAX_INLINE_RUN_CACHE_SIZE) {
      this.inlineRunCache.clear()
    }
    this.inlineRunCache.set(key, new InlineRunCacheEntry(
      lastNodeId, nodes.length, cloneInlineTextStyle(ctx.inlineStyle), runs))
    return runs
  }

  /** 顶层节点的预计算渲染分组。 */
  private cachedGroups: NodeGroup[] = []
  /** 顶层渲染分组是否已准备完成。 */
  private groupsReady: boolean = false

  /**
   * 渲染一组 BBCode 子节点。
   *
   * @param nodes 子节点数组
   * @param ctx 渲染上下文
   */
  @Builder
  RenderChildren(nodes: BBNode[], ctx: RenderContext) {
    ForEach(nodes === this.nodes && this.groupsReady ? this.cachedGroups : this.splitIntoGroups(nodes), (group: NodeGroup) => {
      if (group.kind === 'inline') {
        if (!isInlineRunsBlank(this.getInlineRuns(group.nodes, ctx))) {
          Text() {
            ForEach(this.getInlineRuns(group.nodes, ctx), (run: InlineRun) => {
              this.RenderInlineRun(run, ctx)
            }, (run: InlineRun) => run.key)
          }
          .fontSize(inlineFontSize(ctx, this.contentFontSize))
          .fontColor(ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary)
          .fontStyle(ctx.inQuote ? FontStyle.Italic : FontStyle.Normal)
          .lineHeight(inlineGroupLineHeight(this.getInlineRuns(group.nodes, ctx), ctx, this.contentFontSize))
          .width('100%')
          .textAlign(ctx.textAlign)
        }
      } else {
        this.RenderBlockNode(group.nodes[0], ctx)
      }
    }, (group: NodeGroup) => 'g_' + group.nodes[0].id.toString())
  }

  /**
   * 渲染一个已扁平化的内联 Run。
   *
   * @param run 内联渲染单元
   * @param ctx 渲染上下文
   */
  @Builder
  RenderInlineRun(run: InlineRun, ctx: RenderContext) {
    if (run.kind === InlineRunKind.EMOTION) {
      if (getEmotionResource(run.emotionCat, run.emotionCode) !== null) {
        ImageSpan(getEmotionResource(run.emotionCat, run.emotionCode))
          .width(inlineEmotionSize(run, ctx, this.contentFontSize))
          .height(inlineEmotionSize(run, ctx, this.contentFontSize))
          .objectFit(ImageFit.Contain)
          .textBackgroundStyle(this.effectiveColorMode === 'dark' &&
            isEmotionCategoryNeedDarkBg(run.emotionCat)
            ? { color: Color.White } : { color: Color.Transparent })
      } else {
        Span(`[表情:${run.emotionCat}:${run.emotionCode}]`)
          .fontSize(fallbackFontSize(ctx, this.contentFontSize))
          .fontColor(AppColors.textTertiary)
      }
    } else if (run.kind === InlineRunKind.LINK) {
      // 匿名回复被引用时，引用头名字是 #anony_ 编码（与楼层作者同源），须解码为显示名
      Span(decodeAnonymousName(run.text))
        .fontWeight(run.style.bold ? FontWeight.Bold : FontWeight.Normal)
        .fontStyle(run.style.italic || ctx.inQuote ? FontStyle.Italic : FontStyle.Normal)
        .fontColor(AppColors.primary)
        .fontFamily(run.style.fontFamily)
        .fontSize(inlineRunFontSize(run, ctx, this.contentFontSize))
        .baselineOffset(new LengthMetrics(inlineRunBaselineOffset(run, ctx, this.contentFontSize)))
        .decoration({
          type: run.style.strikethrough ? TextDecorationType.LineThrough : TextDecorationType.Underline,
          color: AppColors.primary
        })
        .onClick(() => {
          if (run.href.length > 0) this.onLinkClick(run.href)
        })
    } else {
      Span(run.text)
        .fontWeight(run.style.bold ? FontWeight.Bold : FontWeight.Normal)
        .fontStyle(run.style.italic || ctx.inQuote ? FontStyle.Italic : FontStyle.Normal)
        .fontColor(run.style.color.length > 0 ? run.style.color :
          (ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary))
        .fontFamily(run.style.fontFamily)
        .fontSize(inlineRunFontSize(run, ctx, this.contentFontSize))
        .baselineOffset(new LengthMetrics(inlineRunBaselineOffset(run, ctx, this.contentFontSize)))
        .decoration({
          type: run.style.strikethrough ? TextDecorationType.LineThrough :
            run.style.underline ? TextDecorationType.Underline : TextDecorationType.None,
          color: run.style.color.length > 0 ? run.style.color :
            (ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary)
        })
    }
  }

  /**
   * 按语义类型分发一个块级节点。
   *
   * @param node 块级节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderBlockNode(node: BBNode, ctx: RenderContext) {
    if (node.type === BBNodeType.HR) {
      this.RenderHorizontalRule()
    } else if (node.type === BBNodeType.HEADING) {
      this.RenderHeading(node, this.makeHeadingCtx(node, ctx))
    } else if (node.type === BBNodeType.PARAGRAPH) {
      this.RenderParagraph(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.IMAGE) {
      this.RenderImage(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.QUOTE) {
      this.RenderQuote(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.COLLAPSE) {
      this.RenderCollapse(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.CODE) {
      this.RenderCode(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.LIST) {
      this.RenderList(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.VIDEO) {
      if (node.src.length > 0) {
        MutedVideo({ src: node.src, videoAspectRatio: this.getVideoAspectRatio(node.src) })
          .margin({ top: 6, bottom: 4 })
      }
    } else if (node.type === BBNodeType.AUDIO) {
      AudioPlayer({ src: node.src })
        .margin({ top: 6, bottom: 4 })
    } else if (node.type === BBNodeType.FLASH) {
      Text('[Flash 内容]')
        .fontSize(15).fontColor(AppColors.primary)
        .decoration({ type: TextDecorationType.Underline, color: AppColors.primary })
        .margin({ top: 6, bottom: 4 })
        .onClick(() => {
          if (node.href.length > 0) this.onLinkClick(node.href)
        })
    } else if (node.type === BBNodeType.DICE) {
      Row() {
        Image($r('app.media.icon_dice')).width(15).height(15).fillColor(AppColors.textPrimary).margin({ right: 4 })
        Text('骰子').fontSize(15).fontColor(AppColors.textPrimary)
      }
    } else if (node.type === BBNodeType.WARN) {
      this.RenderWarn(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.ALBUM) {
      this.RenderAlbum(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.FLOAT_LEFT) {
      this.RenderFloat(node, FlexAlign.Start, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.FLOAT_RIGHT) {
      this.RenderFloat(node, FlexAlign.End, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.ALIGN) {
      this.RenderAlign(node, ctx)
    } else if (node.type === BBNodeType.TABLE) {
      this.RenderTable(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.STYLE_DIV) {
      this.RenderStyleDiv(node, ctx)
    } else if (node.type === BBNodeType.POST_BY) {
      this.RenderReplyRef(node, this.makeBlockCtx(node, ctx))
    }
  }

  /** 渲染水平分隔线。 */
  @Builder
  RenderHorizontalRule() {
    Divider()
      .width('100%')
      .strokeWidth(1)
      .color(AppColors.separator)
      .margin({ top: 8, bottom: 8 })
  }

  /**
   * 渲染与 HTML `h4.subtitle` 对应的独立标题块。
   *
   * @param node 标题节点
   * @param ctx 标题后代的渲染上下文
   */
  @Builder
  RenderHeading(node: BBNode, ctx: RenderContext) {
    Column() {
      this.RenderChildren(node.children, ctx)
      Divider()
        .width('100%')
        .strokeWidth(1)
        .color(AppColors.separator)
        .margin({ top: 6 })
    }
    .width('100%')
    .alignItems(this.horizontalAlignForText(ctx.textAlign))
    .margin({ top: 10, bottom: 8 })
  }

  /**
   * 渲染独立段落。
   *
   * @param node 段落节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderParagraph(node: BBNode, ctx: RenderContext) {
    Column() {
      this.RenderChildren(node.children, ctx)
    }
    .width('100%')
    .alignItems(this.horizontalAlignForText(ctx.textAlign))
    .margin({ top: 2, bottom: 6 })
  }

  /**
   * 将跨越块节点的内联格式转为块后代可继承的渲染上下文。
   *
   * @param node 当前块节点
   * @param parent 父级渲染上下文
   * @returns 块节点自身使用的上下文
   */
  private makeBlockCtx(node: BBNode, parent: RenderContext): RenderContext {
    if (node.inheritedFormatTags.length === 0) return parent
    const result = new RenderContext()
    result.inQuote = parent.inQuote
    result.quoteDepth = parent.quoteDepth
    result.listDepth = parent.listDepth
    result.inlineStyle = applyInlineFormatTags(node.inheritedFormatTags, parent.inlineStyle)
    result.textAlign = parent.textAlign
    return result
  }

  /**
   * 创建列表项后代使用的上下文，并递增列表嵌套深度。
   *
   * @param parent 当前列表使用的渲染上下文
   * @returns 列表项后代上下文
   */
  private makeListItemCtx(parent: RenderContext): RenderContext {
    const result: RenderContext = new RenderContext()
    result.inQuote = parent.inQuote
    result.quoteDepth = parent.quoteDepth
    result.listDepth = parent.listDepth + 1
    result.inlineStyle = parent.inlineStyle
    result.textAlign = parent.textAlign
    return result
  }

  /**
   * 返回当前列表层级使用的项目符号。
   *
   * @param depth 当前列表嵌套深度
   * @returns 对应层级的项目符号
   */
  private listBullet(depth: number): string {
    if (depth === 0) return '•'
    if (depth === 1) return '◦'
    return '▪'
  }

  /**
   * 创建四级标题的粗体文字上下文，并保留外层跨块样式。
   *
   * @param node 标题节点
   * @param parent 父级渲染上下文
   * @returns 标题后代使用的渲染上下文
   */
  private makeHeadingCtx(node: BBNode, parent: RenderContext): RenderContext {
    const result: RenderContext = new RenderContext()
    result.inQuote = parent.inQuote
    result.quoteDepth = parent.quoteDepth
    result.listDepth = parent.listDepth
    result.inlineStyle = applyInlineFormatTags(node.inheritedFormatTags, parent.inlineStyle)
    result.inlineStyle.bold = true
    result.textAlign = parent.textAlign
    return result
  }

  /**
   * 渲染图片块。
   *
   * @param node 图片节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderImage(node: BBNode, ctx: RenderContext) {
    if (node.src.length > 0 && !(this.hideFailedImages && this.failedImages.has(node.src))) {
      this.RenderImageContent(node.src, ctx.inQuote, node.videoSrc)
    }
  }

  /**
   * 根据加载策略渲染图片内容或占位视图。
   *
   * @param src 图片地址
   * @param inQuote 是否位于引用块内
   * @param videoSrc 动态照片的动态视频地址（解析层折叠后挂在 IMAGE 节点的 `videoSrc` 上），
   *                 非动态照片传空串。**直接取节点字段、不查 `MovingPhotoRegistry`**：
   *                 注册表可能因容量淘汰而查不到，那会让正文里的动态照片退化成"点了没反应"。
   */
  @Builder
  RenderImageContent(src: string, inQuote: boolean, videoSrc: string) {
    if (shouldUsePassive(this.imageLoadStrategy)) {
      /* 被动式：紧凑占位图。 */
      Row() {
        Stack() {
          Image($r('app.media.icon_image'))
            .width(18).height(18)
            .fillColor(AppColors.textTertiary)
            .opacity(0.45)
            /* 与实图分支同一项：被动式下**同样**不出现"有的图能识别、有的不能"的差异。
               占位本身只有 28×28（低于分析所需的最小 100×100），不会触发识别；
               用户点开后进入的是实图分支。开关与分析器拆除状态同源（见 `analyzerEnabled`）。 */
            .enableAnalyzer(this.analyzerEnabled)
        }
        .width(28).height(28)
        .borderRadius(6)
        .backgroundColor(AppColors.bgSecondary)

        Text(videoSrc.length > 0 ? '点击查看动态照片' : '点击查看图片').fontSize(13).fontColor(AppColors.textTertiary).margin({ left: 8 })
      }
      .padding({ left: 10, right: 10 })
      .height(40)
      .borderRadius(8)
      .backgroundColor(AppColors.bgSecondary)
      .margin({ top: 6, bottom: 4 })
      .onClick(() => {
        this.handleImageTap(src)
      })
    } else {
      /* 主动式：原有加载行为。 */
      Stack() {
        if (!this.loadedImages.has(src)) {
          Column() {
            LoadingProgress()
              .width(24).height(24)
              .color(AppColors.textTertiary)
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        }

        /* 静态封面常驻：播放态切换绝不能走 if/else 换枝——换枝会销毁并重建整个 Image
           节点，新节点必须重新解码，解码完成前那一两帧是空白，正是"点角标播放 / 播完
           收起"时看到的闪烁。改为把播放器**叠**在封面上：两者几何完全重合（同为 Contain），
           播放时封面被完全盖住；播放器出帧前的空档露出来的正是下面这张已解码好的封面。
           同一契约也用在 `MovingPhotoPlayer` 内部（封面 Image 与 MovingPhotoView）。 */
        if (this.releasedImages.has(src) || this.getImageAspectRatio(src) > 0) {
          /* 第二个参数是**分析选项**（不是 reloadKey）：本工程只做文字识别，见
             `common/media/ImageAnalyzerOptions.ets`。`Image` 没有设置类型的属性，构造是唯一通路。 */
          Image(src, createTextOnlyAnalyzerOptions())
            .width('100%').height('100%')
            /* 动态照片恒用 Contain：须与播放用的 MovingPhotoView（固定 Contain）同几何，
               否则引用块里 Cover 的封面与 Contain 的播放画面会大小不一。 */
            .objectFit(inQuote && videoSrc.length === 0 ? ImageFit.Cover : ImageFit.Contain)
            .borderRadius(inQuote ? 6 : 8)
            /* 长按不注册操作：Image 自 API 10 起 draggable 默认 true，长按会被系统当成拖拽图片。
               对下方的识图而言这一行是**消歧**而非前提：SDK 只声明 `draggable(true)` 会让绑定到
               组件上的长按手势失效，分析器的长按由系统内部处理、不属于拖拽类事件，官方**未声明**
               两者交互；停用拖拽后与识别争抢长按的角色（拖拽）已被移除，行为完全确定。 */
            .draggable(false)
            /* 正文图开启系统 AI 图像分析（API 11+）：长按**文字区**识别文字、可框选与复制。
               分析类型在构造处收窄为「只做文字识别」（`createTextOnlyAnalyzerOptions`），
               **不含**系统默认的主体分割（长按抠图），完整契约与真机验收项见
               `docs/research/IMAGE_TEXT_RECOGNITION_GUIDE.md`。此处只记四条与本节点相关的：
               ① 识别基于**完整原图**，本处的 objectFit 与父层 aspectRatio 不影响识别区域；
               ② 与 onClick（打开查看器）不冲突：长按归分析器、单击归点击回调；
               ③ **GIF 不支持分析**（SDK：svg/gif 属动图，不参与），故动图长按无反应属系统限制；
               ④ 开关绑状态而非字面量 true：选取态的取消就是把分析器拆掉一次（见 `analyzerEnabled`）。
               非国内设备 / 老设备 / 模拟器上系统静默失效，不报错也不影响其余交互（不做降级）。 */
            .enableAnalyzer(this.analyzerEnabled)
            /* 长按判定只用原始触摸计时，不注册手势：手势会与系统识图的长按竞争（见 `onImageTouch`）。 */
            .onTouch((event: TouchEvent): void => {
              this.onImageTouch(event, src)
            })
            .onError(() => {
              this.markImageFailed(src)
            })
            .onComplete((event) => {
              if (event) {
                this.onImageLoaded(src, event.width, event.height)
              } else {
                this.onImageLoaded(src)
              }
            })
            .onClick(() => {
              this.handleImageTap(src)
            })
        }

        if (videoSrc.length > 0 && this.playingMovingPhotoSrc === src) {
          /* 就地播放：点击图片左上角图标后展开播放器，播放一遍后自动收起回静态封面。
             叠在封面之上（不是替换）：封面节点始终不动，播放结束只卸载本层。 */
          MovingPhotoPlayer({
            coverUrl: src,
            videoUrl: videoSrc,
            /* 与正文静态图标同位置同尺寸：接管前后图标不跳动。 */
            iconTop: 6,
            iconLeft: 6,
            iconSize: 40,
            autoPlayOnce: true,
            onPlaybackFinish: (): void => {
              this.playingMovingPhotoSrc = ''
            },
            onPrepareFailed: (coverUrl: string): void => {
              /* 准备失败（下载失败/loadMovingPhoto 拒绝）：收起播放器回到静态角标，
                 否则会停在一块"没有播放入口"的静态封面上（角标已隐藏、播放器图标也不显示）。 */
              if (this.playingMovingPhotoSrc === coverUrl) {
                this.playingMovingPhotoSrc = ''
              }
            },
            onBodyClick: (): void => {
              /* 播放态点图片与静态封面行为一致：先收起就地播放器，再走同一条点击分流
                 （图上还留着选区时，第一次点击只取消选取态）。 */
              this.playingMovingPhotoSrc = ''
              this.handleImageTap(src)
            }
          })
            .width('100%')
            .height('100%')
        }

        if (videoSrc.length > 0 && this.playingMovingPhotoSrc !== src) {
          /* 图片左上角 Live Photo 图标按钮：圆形实底 + 一圈细描边（按钮底板形态，
             与视频右上角静音按钮同款），点击就地播放一次。 */
          Stack() {
            Image($r('app.media.icon_live_photo'))
              .width(25)
              .height(25)
              .fillColor(AppColors.white)
              .draggable(false)
          }
          .width(40)
          .height(40)
          .borderRadius(20)
          .backgroundColor(AppColors.movingPhotoBadgeBg)
          /* 描边给底板上边：底板是半透明黑，压在暗色/杂乱画面上时边界糊掉，
             一圈细白线负责在任何底图上都框出按钮轮廓。 */
          .border({ width: 1, color: AppColors.movingPhotoBadgeBorder })
          /* 绝对定位：保证落在图片左上角（不受父 Stack 对齐规则影响）。 */
          .position({ x: 6, y: 6 })
          .accessibilityText('播放动态照片')
          .onClick(() => {
            this.playingMovingPhotoSrc = src
          })
        }
      }
      .width('100%')
      .aspectRatio(this.getImageAspectRatio(src))
      .constraintSize({
        maxWidth: '100%',
        maxHeight: inQuote ? 200 : 10000,
        minHeight: 60,
      })
      .backgroundColor(this.loadedImages.has(src) ? Color.Transparent : AppColors.bgSecondary)
      .borderRadius(inQuote ? 6 : 8)
      .margin({ top: 6, bottom: 4 })
    }
  }

  /**
   * 渲染引用块及其来源头。
   *
   * @param node 引用节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderQuote(node: BBNode, ctx: RenderContext) {
    Column() {
      if (splitQuoteChildren(node.children).hasHeader) {
        this.RenderQuoteHeader(node.children[0], ctx)
        if (this.isQuoteBlacklisted(node)) {
          Text('该用户已被屏蔽')
            .fontSize(inlineFontSize(this.makeQuoteCtx(ctx), this.contentFontSize))
            .fontColor(AppColors.textTertiary)
            .lineHeight(inlineLineHeight(this.makeQuoteCtx(ctx), this.contentFontSize))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 8, bottom: 8 })
        } else {
          this.RenderChildren(splitQuoteChildren(node.children).body, this.makeQuoteCtx(ctx))
        }
      } else {
        this.RenderChildren(node.children, this.makeQuoteCtx(ctx))
      }
    }
    .width('100%')
    .padding({ left: 12, top: 6, bottom: 6 })
    .margin({ top: 6, bottom: 4 })
    .border({
      width: { left: 2 },
      color: { left: QUOTE_BORDER_COLORS[Math.min(ctx.quoteDepth, QUOTE_BORDER_COLORS.length - 1)] },
      style: { left: BorderStyle.Solid }
    })
    .borderRadius({ topLeft: 4, bottomLeft: 4 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 渲染引用来源头。
   *
   * @param node 来源头节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderQuoteHeader(node: BBNode, ctx: RenderContext) {
    Row() {
      Text() {
        ForEach(flattenInlineNodes(node.children, ctx.inlineStyle), (run: InlineRun) => {
          this.RenderInlineRun(run, this.makeQuoteCtx(ctx))
        }, (run: InlineRun) => run.key)
      }
      .fontSize(14)
      .fontColor(AppColors.textSecondary)
      .fontStyle(FontStyle.Italic)
      .lineHeight(20)
    }
    .width('100%')
    .padding({ bottom: 2 })
  }

  /**
   * 创建引用正文的渲染上下文。
   *
   * @param parent 父级上下文
   * @returns 引用上下文
   */
  private makeQuoteCtx(parent: RenderContext): RenderContext {
    const c = new RenderContext()
    c.inQuote = true
    c.quoteDepth = parent.quoteDepth + 1
    c.listDepth = parent.listDepth
    c.inlineStyle = parent.inlineStyle
    c.textAlign = parent.textAlign
    return c
  }

  /**
   * 为白名单 `[style ...]` 块创建继承文字样式的上下文。
   *
   * @param node STYLE_DIV 节点
   * @param parent 父级渲染上下文
   * @returns 样式块子节点上下文
   */
  private makeStyleCtx(node: BBNode, parent: RenderContext): RenderContext {
    const result = new RenderContext()
    result.inQuote = parent.inQuote
    result.quoteDepth = parent.quoteDepth
    result.listDepth = parent.listDepth
    const inheritedStyle: InlineTextStyle = applyInlineFormatTags(node.inheritedFormatTags, parent.inlineStyle)
    result.inlineStyle = applyTextStyleDeclaration(node.text, inheritedStyle)
    result.textAlign = this.resolveTextAlign(extractTextStyleAlign(node.text), parent.textAlign)
    return result
  }

  /**
   * 把 BBCode 对齐值转换为 ArkUI 文字对齐方式。
   *
   * @param value left、center、right 或空字符串
   * @param inherited 未显式声明时继承的对齐方式
   * @returns ArkUI 文字对齐方式
   */
  private resolveTextAlign(value: string, inherited: TextAlign): TextAlign {
    if (value === 'center') return TextAlign.Center
    if (value === 'right') return TextAlign.End
    if (value === 'left') return TextAlign.Start
    return inherited
  }

  /**
   * 把文字对齐方式转换为 Column 子项的水平对齐方式。
   *
   * @param textAlign ArkUI 文字对齐方式
   * @returns Column 水平对齐方式
   */
  private horizontalAlignForText(textAlign: TextAlign): HorizontalAlign {
    if (textAlign === TextAlign.Center) return HorizontalAlign.Center
    if (textAlign === TextAlign.End) return HorizontalAlign.End
    return HorizontalAlign.Start
  }

  /**
   * 判断归一化表格是否需要横向滚动。
   *
   * @param layout 表格逻辑网格
   * @returns 逻辑列数不少于 4 时返回 true
   */
  private isWideTable(layout: TableLayout): boolean {
    return layout.columnCount >= 4
  }

  /**
   * 计算宽表模式下单元格的固定宽度。
   *
   * 优先使用解析阶段获得的 colWidth，否则按默认列宽 120vp × colSpan。
   * 固定列宽保证所有行同列宽度一致，避免内容跨分隔线错位。
   *
   * @param cell 已归一化的渲染片段
   * @returns 单元格宽度（vp）
   */
  private tableCellFixedWidth(cell: TableLayoutCell): number {
    const colWidth: number = cell.node?.colWidth ?? 0
    if (colWidth > 0) return colWidth
    return 120 * cell.columnSpan
  }

  /**
   * 计算归一化表格片段的边框宽度。
   *
   * 跨行连接片段隐藏内部横边框，使多个自适应高度的行在视觉上形成一个合并单元格。
   *
   * @param cell 已归一化的渲染片段
   * @returns ArkUI 四边边框宽度
   */
  private tableCellBorderWidth(cell: TableLayoutCell): EdgeWidths {
    return {
      top: cell.connectsAbove ? 0 : 0.5,
      right: 0.5,
      bottom: cell.connectsBelow ? 0 : 0.5,
      left: 0.5,
    }
  }

  /**
   * 计算表格片段内容的垂直对齐方式。
   *
   * rowspan 连接片段在承载内容的中间逻辑行内继续垂直居中；普通单元格保持顶部对齐。
   *
   * @param cell 已归一化的渲染片段
   * @returns ArkUI 主轴对齐方式
   */
  private tableCellVerticalAlign(cell: TableLayoutCell): FlexAlign {
    return cell.connectsAbove || cell.connectsBelow ? FlexAlign.Center : FlexAlign.Start
  }

  /**
   * 为显式 `[align]` 块创建可向后代传递的对齐上下文。
   *
   * @param node ALIGN 节点
   * @param parent 父级渲染上下文
   * @returns 对齐块子节点上下文
   */
  private makeAlignCtx(node: BBNode, parent: RenderContext): RenderContext {
    const result = new RenderContext()
    result.inQuote = parent.inQuote
    result.quoteDepth = parent.quoteDepth
    result.listDepth = parent.listDepth
    result.inlineStyle = applyInlineFormatTags(node.inheritedFormatTags, parent.inlineStyle)
    result.textAlign = this.resolveTextAlign(node.align, parent.textAlign)
    return result
  }

  /**
   * 渲染回复来源引用。
   *
   * @param node 回复来源节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderReplyRef(node: BBNode, ctx: RenderContext) {
    Column() {
      this.RenderChildren(node.children, this.makeQuoteCtx(ctx))
    }
    .width('100%')
    .padding({ left: 12, top: 6, bottom: 6 })
    .margin({ top: 6, bottom: 4 })
    .border({
      width: { left: 2 },
      color: { left: AppColors.quoteBorders[1] },
      style: { left: BorderStyle.Solid }
    })
    .borderRadius({ topLeft: 4, bottomLeft: 4 })
    .alignItems(HorizontalAlign.Start)
    .constraintSize({ maxHeight: 80 })
    .opacity(0.85)
  }

  /**
   * 渲染可展开或收起的折叠块。
   *
   * @param node 折叠节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderCollapse(node: BBNode, ctx: RenderContext) {
    Column() {
      Row() {
        Text(this.collapseKeys.has(node.title) ? '▾ ' : '▸ ')
          .fontSize(14)
          .fontColor(AppColors.primary)
          .fontWeight(FontWeight.Medium)
        Text(node.title)
          .fontSize(14)
          .fontColor(AppColors.textSecondary)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        if (!this.collapseKeys.has(node.title)) {
          Text('点击展开')
            .fontSize(11)
            .fontColor(AppColors.textTertiary)
            .margin({ right: 4 })
        }
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .backgroundColor(AppColors.bgSecondary)
      .borderRadius(8)
      .onClick(() => {
        if (this.collapseKeys.has(node.title)) {
          this.collapseKeys.delete(node.title)
        } else {
          this.collapseKeys.add(node.title)
        }
      })

      if (this.collapseKeys.has(node.title)) {
        Column() {
          this.RenderChildren(node.children, ctx)
        }
        .width('100%')
        .padding({ left: 12, top: 8, bottom: 8 })
        .alignItems(HorizontalAlign.Start)
        .border({
          width: { left: 2 },
          color: { left: AppColors.quoteBorders[0] },
          style: { left: BorderStyle.Solid }
        })
        .borderRadius({ topLeft: 4, bottomLeft: 4 })
        .margin({ top: 4 })
      }
    }
    .width('100%')
    .margin({ top: 4, bottom: 2 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 渲染等宽字体代码块。
   *
   * @param node 代码节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderCode(node: BBNode, ctx: RenderContext) {
    Scroll() {
      Text(node.text)
        .fontSize(codeFontSize(ctx, this.contentFontSize))
        .fontColor(AppColors.textPrimary)
        .fontFamily('monospace')
        .lineHeight(codeLineHeight(ctx, this.contentFontSize))
    }
    .width('100%')
    .scrollable(ScrollDirection.Horizontal)
    .padding(10)
    .margin({ top: 6, bottom: 4 })
    .borderRadius(8)
    .backgroundColor(AppColors.bgSecondary)
    .align(Alignment.TopStart)
    /* 正文内的横向滚动同样是"非识图交互"：拖动代码块即收掉选区（无会话时是一次空数组判断）。 */
    .onDidScroll((): void => {
      dismissAnalyzerSessions()
    })
  }

  /**
   * 渲染列表及其项目。
   *
   * @param node 列表节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderList(node: BBNode, ctx: RenderContext) {
    Column() {
      ForEach(node.children, (child: BBNode) => {
        if (child.type === BBNodeType.LIST_ITEM) {
          Row() {
            Text(this.listBullet(ctx.listDepth))
              .fontSize(inlineFontSize(ctx, this.contentFontSize))
              .fontColor(ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary)
              .lineHeight(inlineLineHeight(ctx, this.contentFontSize))
              .width(16)
              .textAlign(TextAlign.Start)
            if (child.children.length > 0) {
              Column() {
                this.RenderChildren(child.children, this.makeListItemCtx(ctx))
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            } else {
              Text(child.text)
                .fontSize(inlineFontSize(ctx, this.contentFontSize))
                .fontColor(ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary)
                .layoutWeight(1)
                .lineHeight(inlineLineHeight(ctx, this.contentFontSize))
            }
          }
          .width('100%')
          .padding({ top: ctx.listDepth === 0 ? 2 : 1, bottom: ctx.listDepth === 0 ? 2 : 1 })
          .alignItems(VerticalAlign.Top)
        }
      }, (child: BBNode) => child.id.toString())
    }
    .width('100%')
    .padding({ left: ctx.listDepth === 0 ? 12 : 16 })
    .margin({ top: ctx.listDepth === 0 ? 4 : 0, bottom: ctx.listDepth === 0 ? 4 : 0 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 渲染警告提示块。
   *
   * @param node 警告节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderWarn(node: BBNode, ctx: RenderContext) {
    Column() {
      if (node.children.length > 0) {
        this.RenderChildren(node.children, ctx)
      } else {
        Text(node.text)
          .fontSize(inlineFontSize(ctx, this.contentFontSize))
          .fontColor(AppColors.warnText)
          .lineHeight(inlineLineHeight(ctx, this.contentFontSize))
      }
    }
    .width('100%')
    .padding(12)
    .margin({ top: 6, bottom: 4 })
    .borderRadius(8)
    .backgroundColor(AppColors.warnBg)
    .border({ width: 1, color: AppColors.warnBorder })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 渲染相册块。
   *
   * @param node 相册节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderAlbum(node: BBNode, ctx: RenderContext) {
    Column() {
      if (node.title.length > 0) {
        Text(node.title)
          .fontSize(14)
          .fontColor(AppColors.textSecondary)
          .fontWeight(FontWeight.Bold)
          .padding({ top: 4, bottom: 4 })
      }
      this.RenderChildren(node.children, ctx)
    }
    .width('100%')
    .padding(10)
    .margin({ top: 6, bottom: 4 })
    .borderRadius(8)
    .backgroundColor(AppColors.bgSecondary)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 渲染左侧或右侧对齐的浮动块。
   *
   * @param node 浮动节点
   * @param flexAlign 水平对齐方式
   * @param ctx 渲染上下文
   */
  @Builder
  RenderFloat(node: BBNode, flexAlign: FlexAlign, ctx: RenderContext) {
    Row() {
      Column() {
        this.RenderChildren(node.children, ctx)
      }
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .justifyContent(flexAlign)
    .margin({ top: 4, bottom: 2 })
  }

  /**
   * 渲染显式文字对齐块。
   *
   * @param node 对齐节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderAlign(node: BBNode, ctx: RenderContext) {
    Column() {
      this.RenderChildren(node.children, this.makeAlignCtx(node, ctx))
    }
    .width('100%')
    .alignItems(this.horizontalAlignForText(this.resolveTextAlign(node.align, ctx.textAlign)))
    .margin({ top: 4, bottom: 2 })
  }

  /**
   * 渲染表格块。
   *
   * 按列数区分两种渲染模式，确保列对齐正确：
   * - 宽表（最大列数 ≥ 4）：固定列宽 + 横向 Scroll，避免列宽被压缩；
   *   所有行同列使用相同固定宽度，列分隔线对齐一致。
   * - 窄表（列数 < 4）：layoutWeight 平均分配容器宽度，与原版行为一致。
   *
   * @param node 表格节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderTable(node: BBNode, ctx: RenderContext) {
    this.RenderTableLayout(buildTableLayout(node), ctx)
  }

  /**
   * 渲染已经过 rowspan/colspan 归一化的表格逻辑网格。
   *
   * @param layout 表格逻辑网格
   * @param ctx 渲染上下文
   */
  @Builder
  RenderTableLayout(layout: TableLayout, ctx: RenderContext) {
    if (this.isWideTable(layout)) {
      Scroll() {
        Column() {
          ForEach(layout.rows, (row: TableLayoutRow) => {
            Flex({ direction: FlexDirection.Row, alignItems: ItemAlign.Stretch }) {
              ForEach(row.cells, (cell: TableLayoutCell) => {
                Column() {
                  if (cell.rendersContent && cell.node !== null) {
                    this.RenderChildren(cell.node.children, ctx)
                  }
                }
                .padding(6)
                .width(this.tableCellFixedWidth(cell))
                .border({ width: this.tableCellBorderWidth(cell), color: AppColors.separator })
                .alignItems(HorizontalAlign.Start)
                .justifyContent(this.tableCellVerticalAlign(cell))
              }, (cell: TableLayoutCell) => cell.key)
            }
          }, (row: TableLayoutRow) => row.key)
        }
        .border({ width: 0.5, color: AppColors.separator })
        .borderRadius(4)
        .alignItems(HorizontalAlign.Start)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Auto)
      .width('100%')
      .margin({ top: 6, bottom: 4 })
      /* 宽表的横向滚动同代码块：拖动即收掉识图选区（无会话时是一次空数组判断）。 */
      .onDidScroll((): void => {
        dismissAnalyzerSessions()
      })
    } else {
      Column() {
        ForEach(layout.rows, (row: TableLayoutRow) => {
          Flex({ direction: FlexDirection.Row, alignItems: ItemAlign.Stretch }) {
            ForEach(row.cells, (cell: TableLayoutCell) => {
              Column() {
                if (cell.rendersContent && cell.node !== null) {
                  this.RenderChildren(cell.node.children, ctx)
                }
              }
              .padding(6)
              .layoutWeight(cell.columnSpan)
              .border({ width: this.tableCellBorderWidth(cell), color: AppColors.separator })
              .alignItems(HorizontalAlign.Start)
              .justifyContent(this.tableCellVerticalAlign(cell))
            }, (cell: TableLayoutCell) => cell.key)
          }
          .width('100%')
        }, (row: TableLayoutRow) => row.key)
      }
      .width('100%')
      .margin({ top: 6, bottom: 4 })
      .border({ width: 0.5, color: AppColors.separator })
      .borderRadius(4)
      .alignItems(HorizontalAlign.Start)
    }
  }

  /**
   * 渲染经过白名单过滤的样式块。
   *
   * @param node 样式节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderStyleDiv(node: BBNode, ctx: RenderContext) {
    Column() {
      this.RenderChildren(node.children, this.makeStyleCtx(node, ctx))
    }
    .width('100%')
    .margin({ top: 4, bottom: 2 })
    .alignItems(this.horizontalAlignForText(
      this.resolveTextAlign(extractTextStyleAlign(node.text), ctx.textAlign)))
  }
}
