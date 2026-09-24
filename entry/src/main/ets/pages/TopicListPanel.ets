/**
 * 主题列表面板 - 统一版, 所有断点共用
 * 第二列(板块堆栈) 或 第三列(活动栈) 均可使用
 * 点击主题通过 routerStore 导航
 */

import { SegmentButton, SegmentButtonOptions, SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI'
import { appStore } from '../store/AppStore'
import { routerStore, Screen, ThreadSource } from '../store/RouterStore'
import { floatingLayerStore, FloatingPage } from '../store/FloatingLayerStore'
import { withTimeout } from '../common/utils/TimeoutUtils'
import { getTopicList, createTopicListParams, setSubforumFilter } from '../service/api/ForumApi'
import { locatePidPage } from '../service/api/ThreadApi'
import type { TopicListParams } from '../service/api/ForumApi'
import type { TopicListResult } from '../model/NgaApiResults'
import {
  resolvePreviewRowLayout,
  FALLBACK_PREVIEW_AREA_WIDTH,
  PREVIEW_IMAGE_GAP,
  PreviewTileLayout
} from '../common/utils/TopicPreviewUtils'
import type { PreviewImage, PreviewRowLayout } from '../common/utils/TopicPreviewUtils'
import { newTopicManager } from '../common/managers/NewTopicManager'
import type { PostReplyResult } from '../model/ThreadResult'
import type { SubBoard } from '../model/Forum'
import { FavBoard } from '../model/SocialEntries'
import { AppColors, FONT_COLORS, SORT_MODES, HOT_RANGES, SortMode, BreakpointType, SheetWidthConstants, ImageLoadStrategy } from '../common/constants/Constants'
import { formatTime } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { PanelNavBar, NavBarMenuItem } from '../common/components/PanelNavBar'
import { HdsMaterialHost } from '../common/components/HdsMaterialHost'
import { ThreadDataSource } from '../common/datasource/LazyDataSource'
import { LoadingStateView, ErrorStateView, EmptyStateView } from '../common/components/PageStateView'
import { AnonymousName } from '../common/components/AnonymousName'
import { BoardIcon } from '../common/components/BoardIcon'
import { TopicPaginationManager } from '../common/managers/TopicPaginationManager'
import { Logger, DOMAIN_UI } from '../common/utils/Logger'
import {
  ReadingFontRole,
  ReadingLineHeightRole,
  ReadingTypography
} from '../common/typography/ReadingTypography'
import { AuthScope } from '../store/AuthScope'
import { PageScope } from '../common/concurrency/PageScope'
import { UIMaterialManager } from '../common/managers/UIMaterialManager'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'
import { pidLocateProgress } from '../common/media/PidLocateProgress'
import { HoldingHandMonitor, HoldingHandStatus } from '../common/managers/HoldingHandMonitor'
import {
  HOT_RANGE_DAY,
  getHotDays,
  currentModeKey,
  canManageCurrentBoard
} from '../common/utils/TopicListUtils'
import { shouldUsePassive } from '../common/utils/NetworkUtil'

const logger = new Logger(DOMAIN_UI, 'TopicListPanel')

/**
 * 热门时间窗菜单锚点的尺寸（宽 × 高，vp）。
 *
 * 锚点必须是**有确定尺寸的真实节点**：折叠屏多列路由（md/lg）下内容区起点不是 `x = 0`，
 * 菜单锚点的几何很容易被算到**窗口左侧**——挂在整条排序条这种宽锚点上必然复发，与 `sm` 无关
 * （三轮踩坑的结论见 `PanelNavBar` 文件头、`docs/UI_COMPONENT_MIGRATION.md` §7.4 约束 7）。
 *
 * 宽度取与标题栏操作按钮同一档（36）：本项目已验证该量级的锚点几何在多列下被正确计算。
 * 高度取 28——官方声明 `SegmentButton` 的**最小高度就是 28vp**，锚点因此不会把排序条那一行撑高
 * （`Stack` 的高度由更高的 `SegmentButton` 决定）；排序条实际更高时锚点在其内容区内**垂直居中**，
 * 菜单落点随之略向上收，仍紧贴排序条下方。
 */
const HOT_RANGE_ANCHOR_WIDTH: number = 36
const HOT_RANGE_ANCHOR_HEIGHT: number = 28

/**
 * 子版块筛选面板中「已屏蔽」行图标的弱化不透明度。
 *
 * 图标弱化只负责"降噪"，**不再承担状态语义**：面板背板是半透明系统材质，背后帖子列表的
 * 图标与文字会透上来，靠整体压暗的位图图标无法稳定传达"已屏蔽"，语义交给行内的状态徽标。
 * 因此这里从原来的 0.45 提到 0.6——屏蔽态图标仍可辨认，同时不与未屏蔽行抢注意力。
 */
const SUB_BOARD_BLOCKED_ICON_OPACITY: number = 0.6

/**
 * 预览图圆角（与 `PostAttachments` 附件缩略图保持一致）。
 *
 * 预览区**尺寸不固定**：区域最大宽高由"当前图片区宽度 × 张数"与 240vp 上限算出，区域内每张图
 * 再按自身真实比例做最优适配（见 `TopicPreviewUtils.resolvePreviewArea` /
 * `resolvePreviewRowLayout` 与 docs/TOPIC_PREVIEW_DESIGN.md §6.2）。
 * 原先的 `PREVIEW_IMAGE_HEIGHT = 120` 固定值已移除——实测 582 个真实列表附件下，
 * 固定 120vp 高度平均只能显示 39.7% 的画面（竖图仅 21~27%），是"图片比例多样 ×
 * 设备形态多样"下最大的观感损失点。
 */
const PREVIEW_IMAGE_RADIUS: number = 8

/**
 * 列表单元**内部**左右 padding（vp）：文字/图片与列表左右边界的距离。
 *
 * 横向留白**只由这一层承担**：列表自身没有左右 padding（见 `build()` 里的 `List`），
 * 条目边界由贯穿整列的分隔横线表达。预览图区宽度也据此扣（见
 * `TopicCardComponent.previewAreaWidth`）。
 */
const ITEM_HORIZONTAL_PADDING: number = 16

/**
 * 多图横排最多显示的缩略图张数。
 *
 * 取 3：一行 3 张时每张约 100~180vp（视列宽），已能辨认内容；再多会让单张过窄、
 * 退化成"色块"。第 4 张起不渲染（不叠数量角标，点开查看器可看全部）。
 * 实测列表附件里带图条目以 1~3 张为主，3 张覆盖绝大多数场景。
 */
const PREVIEW_IMAGE_MAX_INLINE: number = 3

/**
 * 列表单元内各区块之间的**统一纵向间距**（vp）。
 *
 * 标题行 / 摘要 / 预览图 / 底栏 之间全部用这一个值，不再各写各的（此前底栏是 12、
 * 图片区是 10 且靠"上一个区块自己带 margin"实现，导致有无摘要时图片与标题的间距不一致）。
 * 统一后"标题→图片""摘要→图片""图片→底栏"的间距在视觉上完全相同。
 *
 * 取 10：与内边距 16 成比例（区块内松、区块间紧），且不改动原有观感基准。
 */
const ITEM_BLOCK_GAP: number = 10

/** 预加载页面临时结果 — startPrefetch 内部收集用 */
class PrefetchPageResult {
  page: number = 0
  threads: object[] = []
  totalPages: number = 0
}

/**
 * 排序模式的分页状态快照（每种排序模式独立数据源的会话级缓存）。
 * 切换排序/时间窗时保存，切回时恢复，避免整页重拉。
 */
class TopicModeState {
  /** 已加载的主题列表快照。 */
  threads: object[] = []
  /** 当前页码（1 基）。 */
  currentPage: number = 1
  /** 服务端返回的总页数。 */
  totalPages: number = 0
  /** 是否还有更多页可加载。 */
  hasMore: boolean = true
  /** 热门模式聚合缓存（对应具体时间窗）。 */
  hotCache: object[] = []
}

@Component
export struct TopicListPanel {
  @Prop @Watch('onBoardChanged') boardFid: number = 0
  @Prop boardName: string = ''
  @Prop boardStid: string = ''
  @Prop isFavorites: boolean = false
  @Prop authorid: string = ''
  @Prop favor: string = ''
  @Prop searchKey: string = ''
  @Prop author: string = ''
  @Prop searchpost: string = ''
  @Prop showBack: boolean = true
  @State holdingStatus: HoldingHandStatus = appStore.settings.holdingHand as HoldingHandStatus
  @State holdingDetected: boolean = false
  @State isLoading: boolean = true
  @State isLoadingMore: boolean = false
  @State hasError: boolean = false
  @State errorMsg: string = ''
  @State mgr: TopicPaginationManager = new TopicPaginationManager()
  private threadsDataSource: ThreadDataSource = new ThreadDataSource()

  /**
   * pid→页码预查找的代际计数：每次发起查找自增，完成后校验未变化才跳转；
   * 面板离开（aboutToDisappear）时也自增，使在途查找失效，防止过期跳转。
   */
  private pidLookupGeneration: number = 0

  /**
   * 最近一次发起的全局定位进度代际（pidLocateProgress.begin() 返回值），
   * 用于面板离开/切版块时按归属隐藏指示器；-1 表示本面板未发起过。
   */
  private pidLocateGeneration: number = -1

  @State sortMode: string = 'latest'
  /** 热门模式的时间窗档位（day/week/month，对齐官方 TopArticleListScope）。 */
  @State hotRange: string = HOT_RANGE_DAY
  /** 各排序模式的分页状态缓存，键为模式键（hot 时含时间窗）。 */
  private modeStates: Map<string, TopicModeState> = new Map()
  /** 排序条分段按钮选项（原生 SegmentButton，胶囊单选），文案由 SORT_MODES 生成避免双份维护。 */
  @State sortOptions: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: SORT_MODES.map((mode: SortMode): SegmentButtonTextItem => {
      const item: SegmentButtonTextItem = { text: mode.key === 'hot' ? `${mode.label} ▾` : mode.label }
      return item
    }) as SegmentButtonItemTuple,
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
  /** 排序条分段按钮选中项（SegmentButton 双向绑定，单选取 [index]）。 */
  @State sortSelected: number[] = [0]
  /** 是否显示热门时间窗气泡菜单。 */
  @State showHotRangeMenu: boolean = false
  /** 排序条在窗口中的底部纵坐标（onAreaChange 实时采集，供状态视图撑满排序条下方的列表可视区）。 */
  private sortBarBottomY: number = 0
  @State showSort: boolean = true
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  /** 当前窗口宽度（vp）：半模态面板宽度按窗口收敛的依据（见 `SheetWidthConstants`）。 */
  @StorageProp('windowWidthVp') windowWidthVp: number = 0
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @StorageProp('unreadNotiCount') unreadNotiCount: number = 0
  /** 未读私信通知数量（与通知/动态未读数合并展示在标题栏铃铛角标）。 */
  @StorageProp('unreadMessageCount') unreadMessageCount: number = 0
  /** 未读关注动态数量（与通知未读数合并展示在标题栏铃铛角标）。 */
  @StorageProp('unreadActivityCount') unreadActivityCount: number = 0
  @StorageProp('navBarHeight') navBarHeight: number = 0
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 列表当前视口高度。 */
  @State listViewportHeight: number = 1
  /**
   * 列表实测宽度（vp），由列表自身的 `onAreaChange` 采集后下传给列表条目。
   *
   * 预览图区宽度不能由断点硬编码推出：`sm` 是整窗、`md` 是"窗口 − 侧边栏 180"、
   * `lg` 双列时是"窗口 − 侧边栏 − 活动列"的 40%，任何写死的宽度都会在其中一种形态下失配。
   * 首帧为 0，由 {@link TopicCardComponent} 回落 `FALLBACK_PREVIEW_AREA_WIDTH`。
   */
  @State listWidth: number = 0
  @State loadingContentOpacity: number = 0
  private loadingDelayTimer: number = -1
  /** 是否显示子版块显示面板。 */
  @State showSubBoardFilterPanel: boolean = false
  /** 当前父版块返回的子版块。 */
  @State subBoards: SubBoard[] = []
  /** 当前正在提交的子版块筛选标识。 */
  @State updatingSubBoardFilterId: string = ''
  /** 收藏板块版本号，用于响应现有收藏功能的变更。 */
  @StorageProp('favVersion') favVersion: number = 0
  /** 主题收藏关系版本号。 */
  @StorageProp('favoriteTopicVersion') @Watch('onFavoriteTopicVersionChange')
  favoriteTopicVersion: number = 0
  /** 当前收藏夹已经处理的服务端 mutation 版本。 */
  private handledFavoriteMutationVersion: number = 0

  private scroller: Scroller = new Scroller()

  /** 面板存活令牌（异步回顶回调的守卫：面板销毁后不得再操作 scroller，见 PageScope 用法）。 */
  private scope: PageScope = new PageScope()

  /**
   * 数据源重建后把列表显式滚回起点（刷新 / 换版块 / 切换排序模式 / 提交后重载）。
   *
   * **不能依赖「清空数据源 → 系统把偏移夹回起点」这条隐含路径**（`TITLE_LIST_DESIGN` 坑点 7 要求显式回顶）：
   * 加载占位项高度 `getStateViewHeight()` 是按 `sortBarBottomY` 动态算出的，而 `sortBarBottomY` 的采样
   * 时机不可控——`onAreaChange` 只响应**布局变化**引起的区域变化（SDK `common.d.ts`：translate/offset
   * 等绘制类变化不触发），它在滚动中何时被触发、采样到的是哪一时刻的窗口坐标，官方均未定义。
   * 设 C = contentStartOffset、itemH = 排序条 ListItem 高，清空数据后的滚动上界
   * `U = C + itemH − sortBarBottomY`，于是判据是 `不回顶 ⟺ yOffset ≤ itemH − sortBarBottomY`：
   * 「是否回顶」取决于**最后一次采样时刻与按键时刻之间的位移**这个窄窗口（而非刷新本身），
   * 且排序条滚出屏幕后 `sortBarBottomY <= 0` 走首帧兜底、内容不足一屏才会被夹回起点。
   *
   * 回顶原语用 `scrollToIndex(0, false, ScrollAlign.START)`（项目先例见 `ThreadPanel`）：官方对
   * `scrollToIndex` 明确写了「`ScrollAlign.START` 时指定 item 首部与容器 `contentStartOffset` 处对齐」，
   * 而对 `scrollEdge` 只写了「滚动到容器边缘」、**未定义**它与 `contentStartOffset` 的关系——那是
   * 「内容起点」与「首项贴屏幕上边界」（该位置 progress 已饱和为 1）两种不同落点，不能靠猜。
   *
   * 延迟一帧执行并做二次校准：命令发出时列表可能尚未完成重建（未挂载时定位类命令静默无效，
   * 见 `THREAD_DESIGN`），且这次程序化滚动是否触发 `onDidScroll` 也没有文档保证；回顶后按
   * `currentOffset()` 回算一次进度，既覆盖「命令未生效」的情形（此时校准值就是原位置的真值），
   * 也避免进度与位置长期不一致。
   */
  private scrollListToTop(): void {
    setTimeout((): void => {
      if (!this.scope.isAlive()) {
        return
      }
      this.scroller.scrollToIndex(0, false, ScrollAlign.START)
      setTimeout((): void => {
        if (this.scope.isAlive()) {
          this.syncTitleScrollEffect()
        }
      }, 0)
    }, 0)
  }

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

  private twentyFourCache: object[] = []

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

  aboutToAppear(): void {
    this.scope.begin()
    this.showSort = !this.authorid && !this.favor
    if (this.favor.length > 0) {
      this.handledFavoriteMutationVersion = appStore.favoriteStore.getFolderMutationVersion(this.favor)
      appStore.favoriteStore.ensureFolders()
    }
    this.loadTopics(1)
    appStore.refreshUnreadCount()
    appStore.settingsStore.ensureFavorites()
    this.startHoldingHandMonitoring()
  }

  aboutToDisappear(): void {
    // 先失效在途的异步回顶回调，再停其他监听
    this.scope.end()
    this.stopHoldingHandMonitoring()
    // 推进分页代际，使未完成的分页/预取异步回调失效，避免回写已销毁页面
    this.mgr.reset()
    // 使在途的 pid→页码预查找失效，避免面板离开后过期跳转
    this.pidLookupGeneration++
    // 按归属隐藏全局定位指示（若已被其他入口接管则自动无效）
    pidLocateProgress.hide(this.pidLocateGeneration)
    this.pidLocateGeneration = -1
    // 排序模式缓存随面板生命周期释放（板块数据可能已变化）
    this.modeStates.clear()
  }

  private onBoardChanged(): void {
    this.mgr.reset()
    this.threadsDataSource.clear()
    this.hasError = false
    // 切换版块使在途的 pid 预查找失效并收起全局定位指示
    this.pidLookupGeneration++
    pidLocateProgress.hide(this.pidLocateGeneration)
    this.pidLocateGeneration = -1
    this.sortMode = 'latest'
    this.hotRange = HOT_RANGE_DAY
    this.sortSelected = [0]
    this.showHotRangeMenu = false
    this.modeStates.clear()
    this.showSubBoardFilterPanel = false
    this.subBoards = []
    this.updatingSubBoardFilterId = ''
    this.showSort = !this.authorid && !this.favor
    this.loadTopics(1)
  }

  /**
   * 响应其他页面完成的服务端主题收藏关系变更。
   *
   * 属**被动刷新**（用户没按刷新，可能是别的入口改了收藏关系）：不显式回顶，避免把正在阅读的
   * 长列表拽回顶部（`scrollToTop = false`）。
   */
  private onFavoriteTopicVersionChange(): void {
    if (this.favor.length === 0) {
      return
    }
    const mutationVersion: number = appStore.favoriteStore.getFolderMutationVersion(this.favor)
    if (mutationVersion <= this.handledFavoriteMutationVersion) {
      return
    }
    this.handledFavoriteMutationVersion = mutationVersion
    this.loadTopics(1, false)
  }

  /**
   * 从当前收藏列表及其 LazyForEach 数据源中立即移除主题。
   *
   * @param topicId - NGA 主题 ID
   */
  private removeTopicFromCurrentList(topicId: string): void {
    this.mgr.clearPrefetchedPages()
    const filtered: object[] = this.mgr.threads.filter((topic: object): boolean =>
      String((topic as Record<string, Object>)['tid'] ?? '') !== topicId)
    if (filtered.length === this.mgr.threads.length) {
      return
    }
    this.mgr.threads = filtered
    this.threadsDataSource.replaceAll(filtered)
    // 同步模式缓存，避免切走再切回时已删除主题“复活”
    this.saveCurrentModeState()
  }

  /**
   * 判断当前页面是否对应一个可管理的普通版块。
   *
   * 纯逻辑已下沉至 {@link canManageCurrentBoard}，本方法仅转发组件 props。
   *
   * @returns 是否允许管理当前版块
   */
  private canManageCurrentBoard(): boolean {
    return canManageCurrentBoard(this.boardFid, this.isFavorites, this.favor,
      this.authorid, this.searchKey, this.author, this.searchpost)
  }

  /**
   * 回帖列表条目点击：先完成 pid→页码数据查找，再打开帖子。
   *
   * 仅在 searchpost 列表携带真实楼层 pid 时走此路径（普通列表 pid 已归一为空，
   * 见 TopicCardComponent.onClick）。查找失败（楼层已删除/请求异常）时退化为
   * 不带定位意图地打开第 1 页。带代际防重入：连点多个帖子时只执行最新一次，
   * 面板离开后在途查找作废，避免过期跳转。
   *
   * @param tid - 主题 ID
   * @param pid - 目标楼层 pid（已归一，非 '0'）
   */
  private async openThreadAfterPidLookup(tid: string, pid: string): Promise<void> {
    const generation: number = ++this.pidLookupGeneration
    // 接管全局定位指示器：总步数由 locatePidPage 在末页请求后确定（1 + ⌈log₂总页数⌉）
    const progressGeneration: number = pidLocateProgress.begin()
    this.pidLocateGeneration = progressGeneration
    const page: number = await locatePidPage(appStore.auth.token, tid, parseInt(pid, 10),
      (done: number, total: number): void => {
        // 过期查找的进度回调不得污染最新一次显示（本地代际 + 全局代际双校验）
        if (generation !== this.pidLookupGeneration) {
          return
        }
        pidLocateProgress.show(progressGeneration, done, total)
      })
    if (generation !== this.pidLookupGeneration) {
      // 已有更新的点击或面板已离开：丢弃过期结果（指示器由最新一次调用接管）
      return
    }
    pidLocateProgress.hide(progressGeneration)
    this.pidLocateGeneration = -1
    if (page > 0) {
      routerStore.navigateActivity(Screen.thread(tid, page, pid, ThreadSource.TOPIC_LIST))
    } else {
      // 定位失败（楼层已删除/请求异常）：打开帖子首页并告知
      appStore.showToast('未能定位到该楼层，已打开帖子首页')
      routerStore.navigateActivity(Screen.thread(tid, 1, '', ThreadSource.TOPIC_LIST))
    }
  }

  /**
   * 打开发新主题编辑器。
   *
   * 仅真实版块（canManageCurrentBoard）提供入口；未登录时提示登录。
   */
  private openNewTopic(): void {
    if (!appStore.auth.isAuthenticated) {
      appStore.showToast('请先登录后发帖')
      return
    }
    const parsedStid: number = Number(this.boardStid)
    const stid: number = Number.isFinite(parsedStid) && parsedStid !== 0 ? parsedStid : 0
    newTopicManager.start(this.boardFid, stid, this.boardName)
    floatingLayerStore.newTopicOnSend = (subject: string, content: string, isAnony: boolean): Promise<void> => {
      return this.handleNewTopicSend(subject, content, isAnony)
    }
    floatingLayerStore.push(FloatingPage.NEW_TOPIC_DIALOG)
  }

  /**
   * 发布新主题。
   *
   * 成功后刷新版面列表并跳转到新主题详情；失败时抛出错误，
   * 使编辑器保留内容与草稿（错误提示在此完成 Toast）。
   */
  private async handleNewTopicSend(subject: string, content: string, isAnony: boolean): Promise<void> {
    let result: PostReplyResult
    try {
      result = await newTopicManager.send(subject, content, isAnony)
    } catch (e) {
      appStore.showToast((e as Error).message || '发帖失败')
      throw new Error((e as Error).message || '发帖失败')
    }
    if (!result.ok) {
      appStore.showToast(result.error || '发帖失败')
      throw new Error(result.error || '发帖失败')
    }
    appStore.showToast('发帖成功')
    this.loadTopics(1)
    if (result.tid > 0) {
      // 发帖成功跳转到新帖（无 pid 定位意图），来源归主题列表面板
      routerStore.navigateActivity(Screen.thread(String(result.tid), 1, '', ThreadSource.TOPIC_LIST))
    }
  }

  /**
   * 判断当前版块是否已存在于本地收藏板块列表。
   *
   * @returns 是否已收藏
   */
  private isCurrentBoardFavorite(): boolean {
    if (!this.canManageCurrentBoard()) return false
    const favorites: FavBoard[] = appStore.settings.favorites
    for (let i = 0; i < favorites.length; i++) {
      if (favorites[i].fid === this.boardFid) return true
    }
    return false
  }

  /**
   * 接入现有收藏板块功能，切换当前版块的收藏状态。
   */
  private toggleCurrentBoardFavorite(): void {
    if (!this.canManageCurrentBoard()) {
      appStore.showToast('当前页面不是可收藏的板块')
      return
    }
    if (this.isCurrentBoardFavorite()) {
      appStore.settingsStore.removeFavorite(this.boardFid)
      appStore.showToast('已取消收藏板块')
      return
    }

    const parsedStid: number = Number(this.boardStid)
    const favorite: FavBoard = new FavBoard()
    favorite.fid = this.boardFid
    favorite.stid = Number.isFinite(parsedStid) && parsedStid !== 0 ? parsedStid : this.boardFid
    favorite.name = this.boardName
    appStore.settingsStore.addFavorite(favorite)
    appStore.showToast('已收藏板块')
  }

  /**
   * 打开子版块显示面板。
   */
  private openSubBoardFilterPanel(): void {
    this.showHotRangeMenu = false
    if (!this.canManageCurrentBoard()) {
      appStore.showToast('当前页面不支持子版块显示')
      return
    }
    if (this.subBoards.length === 0) {
      appStore.showToast('当前板块没有可管理的子版块')
      return
    }
    this.showSubBoardFilterPanel = true
  }

  /**
   * 在本地替换指定子版块的显示状态。
   *
   * @param filterId - 子版块筛选标识
   * @param selected - 新显示状态
   */
  private replaceSubBoardSelection(filterId: string, selected: boolean): void {
    const next: SubBoard[] = []
    for (let i = 0; i < this.subBoards.length; i++) {
      const item: SubBoard = this.subBoards[i]
      next.push({
        fid: item.fid,
        stid: item.stid,
        name: item.name,
        boardHead: item.boardHead,
        tidStr: item.tidStr,
        type: item.type,
        checked: item.filterId === filterId ? selected : item.checked,
        description: item.description,
        parentFidStr: item.parentFidStr,
        filterId: item.filterId,
        attributes: item.attributes,
        filterable: item.filterable,
      })
    }
    this.subBoards = next
  }

  /**
   * 修改子版块的 NGA 账号级显示状态并刷新父版块。
   *
   * @param subBoard - 待修改子版块
   * @param show - 是否在父版块中显示
   */
  private async handleSubBoardFilterChange(subBoard: SubBoard, show: boolean): Promise<void> {
    if (!subBoard.filterable || subBoard.filterId.length === 0
      || this.updatingSubBoardFilterId.length > 0) {
      return
    }

    const previous: boolean = subBoard.checked
    this.updatingSubBoardFilterId = subBoard.filterId
    this.replaceSubBoardSelection(subBoard.filterId, show)
    try {
      const result = await setSubforumFilter(
        appStore.auth.token, this.boardFid, subBoard, show)
      if (!result.ok) {
        this.replaceSubBoardSelection(subBoard.filterId, previous)
        appStore.showToast(result.error || '修改子版块显示设置失败')
        return
      }
      appStore.showToast(show ? `已显示“${subBoard.name}”` : `已屏蔽“${subBoard.name}”`)
      // 子版块显示设置改变了服务端列表，其余排序模式缓存随之过期，统一失效重建
      this.modeStates.clear()
      await this.loadTopics(1)
    } catch (e) {
      this.replaceSubBoardSelection(subBoard.filterId, previous)
      appStore.showToast((e as Error).message || '修改子版块显示设置失败')
    } finally {
      this.updatingSubBoardFilterId = ''
    }
  }

  private buildTopicParams(page: number): TopicListParams {
    const params: TopicListParams = createTopicListParams()
    params.page = String(page)
    if (this.isFavorites || this.favor) {
      params.favor = this.favor || '1'
    } else {
      if (this.boardFid) params.fid = String(this.boardFid)
      if (this.boardStid) params.stid = this.boardStid
    }
    if (this.authorid) params.authorid = this.authorid
    if (this.searchKey) params.key = this.searchKey
    if (this.author) params.author = this.author
    if (this.searchpost) params.searchpost = this.searchpost
    if (this.showSort) {
      if (this.sortMode === 'topped') {
        // 置顶模式走官方 subject/topped（topped=fid，与官方 r0 一致）；
        // boardFid=0（合集场景）时发空串，与官方合集页行为一致，避免 topped=0 误请求
        params.topped = this.boardFid !== 0 ? String(this.boardFid) : ''
      } else if (this.sortMode === 'hot') {
        // 热门模式走官方 subject/hot（days 按时间窗档位映射）
        params.hotDays = this.getHotDays()
      } else if (this.sortMode === 'latest') {
        // 最新（新回复）显式发 order_by=lastpostdesc，对齐官方 W() 的恒发行为
        params.orderBy = 'lastpostdesc'
      } else if (this.sortMode === 'postdate') {
        params.orderBy = 'postdatedesc'
      } else if (this.sortMode === 'recommend') {
        params.recommend = '1'
      }
    }
    return params
  }

  /**
   * 将收藏夹列表响应中的主题登记到运行期成员关系缓存。
   *
   * @param topics - 当前收藏夹响应中的主题列表
   * @param folderId - 该响应所属的收藏夹 ID
   */
  private recordFavoriteTopics(topics: object[], folderId: string = this.favor): void {
    if (folderId.length === 0) {
      return
    }
    const topicIds: string[] = []
    for (let i = 0; i < topics.length; i++) {
      const topic: Record<string, Object> = topics[i] as Record<string, Object>
      const topicId: string = String(topic['tid'] ?? '')
      if (topicId.length > 0) {
        topicIds.push(topicId)
      }
    }
    appStore.favoriteStore.recordTopicMemberships(topicIds, folderId, true)
  }


  private async loadTwentyFourTopics(): Promise<void> {
    this.hasError = false
    this.mgr.clearPrefetchedPages()
    const gen: number = this.mgr.getGeneration()

    try {
      // 官方 subject/hot：一次请求返回该 days 时间窗的完整热度榜
      // （服务端热度排序，忽略 _page；days=1 约 32 条 / 7 约 230 条 / 30 约 930 条），
      // 整表缓存后本地切片翻页，不再需要并发拉页/时间窗过滤/回复数排序/截断。
      const params: TopicListParams = this.buildTopicParams(1)
      const result: TopicListResult = await withTimeout<TopicListResult>(
        getTopicList(appStore.auth.token, params, appStore.settingsStore.getBlacklistIds(),
          appStore.settingsStore.getEnabledKeywords()), 15000)
      if (gen !== this.mgr.getGeneration()) return

      if (!result.ok || !result.data) {
        this.hasError = true
        this.errorMsg = result.error || '加载失败'
        return
      }

      const all: object[] = result.data.threadPageList
      this.twentyFourCache = all
      if (this.canManageCurrentBoard()) {
        // 热门接口不返回 subForum，热门模式下子版块筛选面板不适用
        this.subBoards = []
      }

      const firstPageLen: number = all.length > 20 ? 20 : all.length
      const firstPage: object[] = []
      for (let i = 0; i < firstPageLen; i++) {
        firstPage.push(all[i])
      }
      this.mgr.replaceWith(firstPage, 1, all.length > 0 ? Math.ceil(all.length / 20) : 0)
      this.threadsDataSource.replaceAll(firstPage)
      this.saveCurrentModeState()
    } catch (e) {
      if (gen === this.mgr.getGeneration()) {
        this.hasError = true
        this.errorMsg = (e as Error).message || '加载失败'
      }
    } finally {
      // 代际校验：模式切换后的过期会话不得复位新会话的加载态
      if (gen === this.mgr.getGeneration()) {
        clearTimeout(this.loadingDelayTimer)
        this.loadingDelayTimer = -1
        this.loadingContentOpacity = 0
        this.isLoading = false
        this.isLoadingMore = false
      }
    }
  }

  private loadMoreTwentyFourTopics(page: number): void {
    this.isLoadingMore = true

    const end: number = page * 20
    const count: number = end > this.twentyFourCache.length ? this.twentyFourCache.length : end

    const existingTids: Set<number> = new Set()
    for (let i = 0; i < this.mgr.threads.length; i++) {
      const tid: number = Number((this.mgr.threads[i] as Record<string, Object>)['tid'] ?? 0)
      if (tid) existingTids.add(tid)
    }

    const newItems: object[] = []
    for (let i = 0; i < count; i++) {
      const t: object = this.twentyFourCache[i]
      const tid: number = Number((t as Record<string, Object>)['tid'] ?? 0)
      if (!existingTids.has(tid)) {
        newItems.push(t)
        existingTids.add(tid)
      }
    }

    if (newItems.length > 0) {
      const arr: object[] = []
      for (let i = 0; i < this.mgr.threads.length; i++) arr.push(this.mgr.threads[i])
      for (let i = 0; i < newItems.length; i++) arr.push(newItems[i])
      this.mgr.threads = arr
      this.threadsDataSource.appendAll(newItems)
    }

    this.mgr.currentPage = page
    this.isLoadingMore = false
  }

  /**
   * 加载主题列表页。
   *
   * @param page - 目标页码（1 基）；`page === 1` 表示整表重建
   * @param scrollToTop - 整表重建后是否显式回顶。**被动刷新必须传 false**：本方法也由
   *   `onFavoriteTopicVersionChange`（其他入口改动了服务端收藏关系）触发，此时用户并未要求刷新，
   *   把长列表拽回顶部会直接打断阅读（见 scrollListToTop 的契约）
   */
  private async loadTopics(page: number, scrollToTop: boolean = true): Promise<void> {
    const gen: number = this.mgr.nextGeneration()
    const authScope: AuthScope = AuthScope.capture(appStore.auth, 0)
    const favoriteFolderId: string = this.favor
    if (page === 1) {
      this.titleScrollEffectProgress = 0
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
      this.hasError = false
      this.mgr.clearPrefetchedPages()
      // 清空残留数据：避免加载中切走时把上一模式的 threads 以当前模式 key 存入缓存，
      // 也防止过期会话期间残留列表被渲染/翻页混排
      this.mgr.threads = []
      this.threadsDataSource.clear()
      if (scrollToTop) {
        // 数据源重建后显式回顶：隐含夹紧的位置相关行为不可靠（见 scrollListToTop）
        this.scrollListToTop()
      }
      if (this.sortMode === 'hot') {
        await this.loadTwentyFourTopics()
        return
      }
    } else {
      this.isLoadingMore = true
      if (this.sortMode === 'hot') {
        this.loadMoreTwentyFourTopics(page)
        return
      }
    }

    try {
      const params: TopicListParams = this.buildTopicParams(page)
      const result: TopicListResult = await withTimeout<TopicListResult>(
        getTopicList(appStore.auth.token, params, appStore.settingsStore.getBlacklistIds(),
          appStore.settingsStore.getEnabledKeywords()), 15000)
      if (gen !== this.mgr.getGeneration() || this.favor !== favoriteFolderId ||
        !authScope.isCurrent(appStore.auth, 0)) return
      if (result.ok && result.data) {
        const list: object[] = result.data.threadPageList
        this.recordFavoriteTopics(list, favoriteFolderId)
        if (page === 1) {
          this.subBoards = this.canManageCurrentBoard() ? result.data.subBoardList : []
          this.mgr.replaceWith(list, page, result.data.pagination.totalPages)
          this.threadsDataSource.replaceAll(list)
          this.saveCurrentModeState()
        } else {
          const added: object[] = this.mgr.appendWith(list, page, result.data.pagination.totalPages)
          if (added.length > 0) {
            this.threadsDataSource.appendAll(added)
          }
        }
        this.triggerPrefetch()
      } else if (page === 1) {
        this.hasError = true
        this.errorMsg = result.error || '加载失败'
      }
    } catch (e) {
      // 代际校验：过期会话的失败不得污染新模式/新板块的 UI 状态
      if (page === 1 && gen === this.mgr.getGeneration()) {
        this.hasError = true
        this.errorMsg = (e as Error).message || '加载失败'
      }
    }
    if (gen === this.mgr.getGeneration()) {
      clearTimeout(this.loadingDelayTimer)
      this.loadingDelayTimer = -1
      this.loadingContentOpacity = 0
      this.isLoading = false
      this.isLoadingMore = false
    }
  }

  /**
   * 当前排序模式的状态缓存键（热门模式按时间窗细分，独立数据源隔离）。
   *
   * 纯逻辑已下沉至 {@link currentModeKey}，本方法仅转发组件状态。
   *
   * @returns 模式键
   */
  private currentModeKey(): string {
    return currentModeKey(this.sortMode, this.hotRange)
  }

  /**
   * 将当前排序模式的分页状态快照存入缓存（切换走之前调用）。
   * 首屏数据提交后也会调用，保证刷新后缓存同步。
   */
  private saveCurrentModeState(): void {
    const key: string = this.currentModeKey()
    const state: TopicModeState = new TopicModeState()
    state.threads = this.mgr.threads.slice()
    state.currentPage = this.mgr.currentPage
    state.totalPages = this.mgr.totalPages
    state.hasMore = this.mgr.hasMore
    if (this.sortMode === 'hot') {
      state.hotCache = this.twentyFourCache.slice()
    }
    this.modeStates.set(key, state)
  }

  /**
   * 从缓存恢复排序模式的分页状态（切回时秒开，不重新请求）。
   *
   * @param state - 目标模式的快照
   */
  private restoreModeState(state: TopicModeState): void {
    this.mgr.threads = state.threads
    this.mgr.currentPage = state.currentPage
    this.mgr.totalPages = state.totalPages
    this.mgr.hasMore = state.hasMore
    this.mgr.clearPrefetchedPages()
    if (this.sortMode === 'hot') {
      this.twentyFourCache = state.hotCache.slice()
      // 热门接口不返回 subForum，恢复热门模式时清空上一模式的子版块面板数据
      this.subBoards = []
    } else {
      this.twentyFourCache = []
    }
    this.threadsDataSource.replaceAll(state.threads)
    // 切换排序/时间窗同样属「切换数据源」：进度先归零（坑点 5，避免旧进度残留在新内容上），
    // 再按坑点 7 显式回顶，回顶后由 scrollListToTop 的二次校准按真实偏移收敛
    this.titleScrollEffectProgress = 0
    this.scrollListToTop()
    this.hasError = false
    this.isLoading = false
    this.isLoadingMore = false
    clearTimeout(this.loadingDelayTimer)
    this.loadingDelayTimer = -1
    this.loadingContentOpacity = 0
    // 恢复后重新建立预取链（restore 前 clearPrefetchedPages 已清空缓存）。
    // 热门模式除外：subject/hot 恒返回全量热度榜（服务端忽略 _page），预取
    // page 2 会重复拉取全量且响应 totalPages=1 覆盖本地切片页数、切断翻页；
    // 热门模式翻页本就走 twentyFourCache 内存切片，不依赖预取链。
    if (this.sortMode !== 'hot') {
      this.triggerPrefetch()
    }
  }

  /**
   * 切换排序模式：保存当前模式状态，恢复目标模式缓存或首次加载。
   *
   * @param mode - 目标排序模式键
   */
  private switchSortMode(mode: string): void {
    if (mode === this.sortMode) {
      return
    }
    this.saveCurrentModeState()
    this.sortMode = mode
    this.switchToMode()
  }

  /**
   * 切换热门时间窗（24小时/7天/30天），不同窗口使用独立缓存。
   *
   * @param range - 目标时间窗键
   */
  private switchHotRange(range: string): void {
    if (range === this.hotRange) {
      return
    }
    this.saveCurrentModeState()
    this.hotRange = range
    this.switchToMode()
  }

  /**
   * 排序条分段按钮点击：热门未选中时进入热门模式，已选中时弹出时间窗气泡。
   *
   * @param index - 被点击的选项下标
   */
  private handleSortClicked(index: number): void {
    if (index < 0 || index >= SORT_MODES.length) {
      return
    }
    const mode: string = SORT_MODES[index].key
    if (mode === 'hot') {
      if (this.sortMode === 'hot') {
        this.showHotRangeMenu = true
        return
      }
      this.sortSelected = [index]
      this.switchSortMode('hot')
      return
    }
    this.sortSelected = [index]
    this.switchSortMode(mode)
  }

  /**
   * 时间窗气泡选项点击：关闭气泡并切换热门时间窗（同窗仅关闭）。
   *
   * @param range - 目标时间窗键
   */
  private handleHotRangeSelect(range: string): void {
    this.showHotRangeMenu = false
    this.switchHotRange(range)
  }

  /**
   * 切换到当前 sortMode/hotRange 指向的模式：有非空缓存则恢复，否则首次加载。
   */
  private switchToMode(): void {
    // 废弃在途请求（预取/翻页），防止旧模式响应回写当前模式
    this.mgr.nextGeneration()
    const cached: TopicModeState | undefined = this.modeStates.get(this.currentModeKey())
    if (cached !== undefined && cached.threads.length > 0) {
      this.restoreModeState(cached)
    } else {
      this.loadTopics(1)
    }
  }

  /**
   * 热门模式的官方 subject/hot days 参数（按时间窗档位）。
   *
   * 纯逻辑已下沉至 {@link getHotDays}，本方法仅转发时间窗状态。
   *
   * @returns days 参数值（'1' | '7' | '30'）
   */
  private getHotDays(): string {
    return getHotDays(this.hotRange)
  }

  /**
   * 计算列表状态视图（加载/错误/空态）的撑满高度。
   *
   * 减去排序条占据的顶部区域，使状态内容居中于列表可视区；
   * 排序条坐标尚未实测（首帧）时用标题区高度 + 排序条占位估算兜底，避免高度跳变。
   *
   * @returns 状态视图高度
   */
  private getStateViewHeight(): number {
    let topOffset: number = 0
    if (this.showSort) {
      topOffset = this.sortBarBottomY > 0
        ? this.sortBarBottomY
        : TitleScrollEffect.getContentStartOffset(this.statusBarHeight) + 50
    }
    return Math.max(this.listViewportHeight - topOffset, 400)
  }

  /**
   * 尝试加载下一页（从 onScrollIndex 触发，靠近底部时调用）
   * 避免触及列表边界触发系统回弹动画
   */
  private tryLoadNext(): void {
    if (this.isLoadingMore || this.mgr.currentPage >= this.mgr.totalPages) return
    const nextPage: number = this.mgr.currentPage + 1
    if (this.mgr.hasPrefetchedPage(nextPage)) {
      const added: object[] = this.mgr.commitPrefetchedPage(nextPage)
      if (added.length > 0) {
        this.threadsDataSource.appendAll(added)
      } else if (this.mgr.currentPage < this.mgr.totalPages) {
        this.tryLoadNext()
        return
      }
      this.triggerPrefetch()
    } else {
      this.loadTopics(nextPage)
    }
  }

  private lastPrefetchTime: number = 0
  private readonly PREFETCH_COOLDOWN_MS: number = 400

  private triggerPrefetch(): void {
    const lookahead: number = appStore.settings.prefetchPageCount
    if (lookahead <= 0) return
    const now: number = Date.now()
    if (now - this.lastPrefetchTime < this.PREFETCH_COOLDOWN_MS) return
    if (this.mgr.prefetchInProgress) return
    const pagesToFetch: number[] = []
    const maxPage: number = Math.min(this.mgr.currentPage + lookahead, this.mgr.totalPages)
    for (let p: number = this.mgr.currentPage + 1; p <= maxPage; p++) {
      if (!this.mgr.hasPrefetchedPage(p)) {
        pagesToFetch.push(p)
      }
    }
    if (pagesToFetch.length === 0) return
    this.lastPrefetchTime = now
    this.startPrefetch(pagesToFetch)
  }

  private async startPrefetch(pages: number[]): Promise<void> {
    this.mgr.prefetchInProgress = true
    const gen: number = this.mgr.getGeneration()
    const favoriteFolderId: string = this.favor
    const authScope: AuthScope = AuthScope.capture(appStore.auth, 0)
    try {
      const fetchResults: PrefetchPageResult[] = []
      const promises: Promise<void>[] = []
      for (let i = 0; i < pages.length; i++) {
        const page: number = pages[i]
        promises.push(
          (async (): Promise<void> => {
            try {
              const params: TopicListParams = this.buildTopicParams(page)
              const result: TopicListResult = await withTimeout<TopicListResult>(
                getTopicList(appStore.auth.token, params, appStore.settingsStore.getBlacklistIds(), appStore.settingsStore.getEnabledKeywords()), 10000
              )
              if (result.ok && result.data) {
                const pr: PrefetchPageResult = new PrefetchPageResult()
                pr.page = page
                pr.threads = result.data.threadPageList
                pr.totalPages = result.data.pagination.totalPages
                fetchResults.push(pr)
              }
            } catch (e) {
              // silently skip this page
            }
          })()
        )
      }
      await Promise.all(promises)
      if (gen !== this.mgr.getGeneration() || this.favor !== favoriteFolderId ||
        !authScope.isCurrent(appStore.auth, 0)) return
      for (let i = 0; i < fetchResults.length; i++) {
        const r: PrefetchPageResult = fetchResults[i]
        this.recordFavoriteTopics(r.threads, favoriteFolderId)
        this.mgr.setPrefetchedPage(r.page, r.threads, r.totalPages)
      }
    } catch (e) {
      // silently fall back
    } finally {
      // 代际校验：旧模式的过期预取会话不得误复位新模式的 prefetchInProgress
      if (gen === this.mgr.getGeneration()) {
        this.mgr.prefetchInProgress = false
      }
    }
  }

  private async handleRemoveFav(tid: number): Promise<void> {
    const generation: number = this.mgr.getGeneration()
    const favorSnapshot: string = this.favor
    const authScope: AuthScope = AuthScope.capture(appStore.auth, 0)
    try {
      const folderId: string = favorSnapshot || '1'
      appStore.favoriteStore.recordTopicMembership(String(tid), folderId, true)
      const result = await appStore.favoriteStore.setTopicFavorite(String(tid), folderId, false)
      if (generation !== this.mgr.getGeneration() || this.favor !== favorSnapshot ||
        !authScope.isCurrent(appStore.auth, 0)) {
        return
      }
      if (result.ok) {
        this.removeTopicFromCurrentList(String(tid))
        appStore.showToast('已取消收藏')
      } else {
        appStore.showToast(result.error || '取消收藏失败')
      }
    } catch (e) {
      if (generation === this.mgr.getGeneration() && this.favor === favorSnapshot &&
        authScope.isCurrent(appStore.auth, 0)) {
        appStore.showToast('取消收藏失败')
      }
    }
  }

  build() {
    Stack() {
      Column() {
        /* 条目之间**不留间距**（`ListOptions.space` 不传即 0）：一条帖子由贯穿整列的分隔横线
           切分（见列表尾部的 `divider`），横线上下紧贴相邻条目。 */
        List({ scroller: this.scroller }) {
          if (this.showSort) {
            ListItem() {
              // 排序条与时间窗菜单锚点**同层叠放**：菜单不能挂在排序条这一行上——整行是宽锚点，
              // 折叠屏多列路由下会被算到窗口左侧（见文件头 HOT_RANGE_ANCHOR_WIDTH 的说明）。
              // 锚点也不再能挂在 `SegmentButton` 上：本地 SDK 声明它**不支持通用属性**，
              // 且各分段均分其宽度——「热门」是最后一段，所以锚点取排序条内容区的**右端**，
              // 横向与那颗真实分段对齐、纵向与排序条同心（`Alignment.End` ＝ 右中对齐）。
              Stack({ alignContent: Alignment.End }) {
                SegmentButton({
                  options: this.sortOptions,
                  selectedIndexes: $sortSelected,
                  onItemClicked: (index: number): void => {
                    this.handleSortClicked(index)
                  }
                })

                // 热门时间窗菜单锚点：透明占位节点，只为承载锚点几何，不参与视觉与交互。
                // - `HitTestMode.None` 必须写：锚点盖在「热门」分段上，`Default` 会吞掉该分段的点击
                //   （该模式自身不响应命中测试，且不阻塞兄弟节点）。
                // - 菜单本体仍由系统沉浸材质承担（见 hotRangeMenuOptions）。
                Row()
                  .width(HOT_RANGE_ANCHOR_WIDTH)
                  .height(HOT_RANGE_ANCHOR_HEIGHT)
                  .hitTestBehavior(HitTestMode.None)
                  .bindMenu(this.showHotRangeMenu, this.HotRangeMenu(), this.hotRangeMenuOptions())
              }
              .width('100%')
              /* 沿用原有 4% 比例留白：条目自带 16vp 内边距，排序条按列表宽度的比例留白，
                 与整列的观感基准一致（不随列宽变化而显得贴边或过缩）。 */
              .padding({ left: '4%', right: '4%' })
              .margin({ top: 8, bottom: 6 })
              .onAreaChange((_oldValue: Area, newValue: Area): void => {
                // 采集排序条底部纵坐标：供状态视图撑满排序条下方的列表可视区
                if (typeof newValue.globalPosition.y === 'number' && typeof newValue.height === 'number') {
                  this.sortBarBottomY = newValue.globalPosition.y + newValue.height
                }
              })
            }
          }
          if (this.isLoading) {
            ListItem() {
              Column() {
                LoadingStateView()
              }
              .opacity(this.loadingContentOpacity)
              .width('100%').height(this.getStateViewHeight())
              .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
              .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
            }
          } else if (this.hasError) {
            ListItem() {
              Column() {
                ErrorStateView({ msg: this.errorMsg || '加载失败', onRetry: () => this.loadTopics(1) })
              }
              .width('100%').height(this.getStateViewHeight())
              .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
              .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
            }
          } else if (this.mgr.threads.length === 0) {
            ListItem() {
              Column() {
                EmptyStateView({ msg: this.searchpost ? '暂无回帖' : '暂无帖子', icon: $r('app.media.icon_chat_bubble') })
              }
              .width('100%').height(this.getStateViewHeight())
              .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
              .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
            }
          } else {
            LazyForEach(this.threadsDataSource, (thread: object) => {
              ListItem() {
                TopicCardComponent({
                  thread: thread as Record<string, Object>,
                  isFavorites: this.isFavorites || this.favor.length > 0,
                  listWidth: this.listWidth,
                  onRemoveFav: (tid: number): void => { this.handleRemoveFav(tid) },
                  onCardClick: (tid: string, pid: string): void => {
                    if (tid) {
                      if (this.favor.length > 0) {
                        appStore.favoriteStore.recordTopicMembership(tid, this.favor, true)
                      }
                      if (pid.length > 0) {
                        // 回帖列表进入：先完成 pid→页码数据查找，再以正确页码打开帖子
                        this.openThreadAfterPidLookup(tid, pid)
                      } else {
                        routerStore.navigateActivity(Screen.thread(tid, 1, '', ThreadSource.TOPIC_LIST))
                      }
                    }
                  }
                })
              }
              /* 一条帖子 = 列表里的一个普通条目：条目边界交给列表自身的分隔横线
                 （见列表尾部的 `divider({ strokeWidth: 0.5, color: AppColors.separator })`），
                 条目本体不设圆角、不设描边、不设底色——与页面同底色。 */
            }, (thread: object) => {
              const t = thread as Record<string, Object>
              return String(t['tid'] ?? '')
            })
            ListItem() {
              Row() {
                if (this.isLoadingMore) {
                  LoadingProgress().width(16).height(16).color(AppColors.textTertiary)
                  Text('加载更多...').fontSize(13).fontColor(AppColors.textTertiary).margin({ left: 8 })
                } else if (this.mgr.currentPage >= this.mgr.totalPages) {
                  Text('— 已到底 —').fontSize(12).fontColor(AppColors.textTertiary)
                }
              }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 16, bottom: 16 })
            }
          }
        }
        .width('100%').layoutWeight(1)
        .scrollBar(BarState.Off)
        /* 条目边界：一条贯穿整列的 0.5px 分隔横线（与排序条上方的写法一致）。
           条目之间没有间距（见上面的 `List`），所以横线正好落在两个条目之间，
           "上下横线 0 间隔"——线即是唯一的边界信号，条目本体不带圆角/描边/底色。 */
        .divider({ strokeWidth: 0.5, color: AppColors.separator })
        .lanes(new BreakpointType(1, 1, 1).getValue(this.currentBreakpoint), 12)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(3)
        .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
        .linearGradientBlur(
          TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),
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
          // 列表实测宽度下传条目：预览图高度按"图片区宽度 × 图片比例"算，
          // 而这个宽度只有列表自己知道（sm 整窗 / md 减侧边栏 / lg 双列再乘 40%）
          if (typeof newValue.width === 'number' && newValue.width > 0 &&
            newValue.width !== this.listWidth) {
            this.listWidth = newValue.width
          }
        })
        .onDidScroll((): void => {
          this.syncTitleScrollEffect()
          // 列表滚动时收起时间窗气泡（其锚定的排序条已随内容移动）
          this.showHotRangeMenu = false
        })
        .onAppear((): void => {
          this.syncTitleScrollEffect()
        })
        .onScrollIndex((start: number, end: number): void => {
          const total: number = this.threadsDataSource.totalCount()
          if (end >= total - 3 && total > 0) {
            this.tryLoadNext()
          }
        })
      }
      .width('100%').height('100%')

      PanelNavBar({
        title: this.boardName,
        scrollEffectProgress: this.titleScrollEffectProgress,
        showBack: this.showBack,
        rightIcon: this.canManageCurrentBoard() ? $r('app.media.icon_bell') : '',
        rightIconBadge: this.canManageCurrentBoard()
          ? this.unreadNotiCount + this.unreadMessageCount + this.unreadActivityCount : 0,
        onRightClick: (): void => {
          routerStore.navigateActivity(Screen.notifications())
        },
        secondaryRightIcon: this.canManageCurrentBoard() ? $r('app.media.icon_more') : '',
        // 菜单挂在**第二颗**按钮（更多）上，并由 PanelNavBar 内部渲染：折叠屏多列路由下，只有以
        // 那颗真实按钮为锚点，菜单才不会被算到窗口左侧。两参 bindMenu 下开合由系统持有，本组件
        // 不再持有显隐状态，第二颗按钮因此也不需要 onClick。
        hasMenu: this.canManageCurrentBoard(),
        menuOnSecondary: true,
        menuItemsProvider: (): NavBarMenuItem[] => this.moreMenuItems()
      })
        .width('100%').position({ x: 0, y: 0 })

      this.FloatingActions()
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg).alignContent(Alignment.BottomEnd)
    // 子版块筛选面板：半模态转场承载，面板本体材质见 subBoardFilterSheetOptions
    .bindSheet(this.showSubBoardFilterPanel && this.canManageCurrentBoard(),
      this.SubBoardFilterSheetContent(), this.subBoardFilterSheetOptions())
  }

  /**
   * FloatingActions（原 build() 内联块，结构搬移；材质改为 HDS 材质宿主）。
   *
   * 两个按钮的背板从自绘磨砂玻璃（`UIMaterialManager.fabMaterial`）换成 **HDS 材质宿主**
   * （`HdsMaterialHost` → `HdsTabs` 的悬浮页签栏材质）：API 26 Release 收紧了 `systemMaterial`
   * 的生效范围，页面内容区的普通组件拿不到系统沉浸材质，HDS 材质是内容区唯一能拿到**真材质**
   * 的通道（详见 `HdsMaterialHost` 文件头）。宿主尺寸默认与材质块逐像素重合，所以
   * `Row({ space: 12 })` 与下面这行 `padding` 的落点保持不变。
   */
  @Builder
  FloatingActions() {
    Row({ space: 12 }) {
      if (this.canManageCurrentBoard()) {
        HdsMaterialHost({ barWidth: 44, barHeight: 44, onTap: () => this.openNewTopic() }) {
          Stack() {
            Image($r('app.media.icon_compose'))
              .width(22).height(22)
              .fillColor(UIMaterialManager.adaptiveForeground)
              // Image 的 draggable 自 API 10 起默认为 true：长按会被系统当成"拖拽图片"（见 §12.9）
              .draggable(false)
          }
          .width('100%').height('100%').alignContent(Alignment.Center)
        }
      }
      HdsMaterialHost({ barWidth: 44, barHeight: 44, onTap: () => this.loadTopics(1) }) {
        Stack() {
          Image($r('app.media.icon_refresh'))
            .width(22).height(22)
            .fillColor(UIMaterialManager.adaptiveForeground)
            // Image 的 draggable 自 API 10 起默认为 true：长按会被系统当成"拖拽图片"（见 §12.9）
            .draggable(false)
        }
        .width('100%').height('100%').alignContent(Alignment.Center)
      }
    }.width('100%').justifyContent(this.holdingStatus === HoldingHandStatus.LEFT_HAND_HELD ? FlexAlign.Start : FlexAlign.End)
    .padding({ left: this.holdingStatus === HoldingHandStatus.LEFT_HAND_HELD ? 16 : 0, right: this.holdingStatus === HoldingHandStatus.LEFT_HAND_HELD ? 0 : 16, bottom: 16 + this.navBarHeight })
  }

  /**
   * 版块更多菜单项（菜单本体在 `PanelNavBar` **内部**渲染，锚点是那颗"更多"按钮）。
   *
   * 材质由 `MenuOptions.systemMaterial` 的系统沉浸材质承担（菜单控制属页面内全区域生效的
   * 弹窗类接口）。回调写成**箭头函数**以捕获本组件的 `this`（见 `NavBarMenuItem` 说明）。
   *
   * @returns 菜单项
   */
  private moreMenuItems(): NavBarMenuItem[] {
    const items: NavBarMenuItem[] = []
    items.push({
      label: '搜索本版',
      action: (): void => {
        routerStore.navigateSearch(this.boardFid, this.boardName, this.boardStid)
      }
    })
    items.push({
      label: '子版块显示',
      action: (): void => {
        this.openSubBoardFilterPanel()
      }
    })
    items.push({
      label: this.isCurrentBoardFavorite() ? '取消收藏板块' : '收藏板块',
      action: (): void => {
        this.toggleCurrentBoardFavorite()
      }
    })
    return items
  }

  /**
   * 热门时间窗菜单（官方 `bindMenu` 承载，选项见 {@link hotRangeMenuOptions}）。
   *
   * 材质由 `MenuOptions.systemMaterial` 承担（菜单控制属页面内全区域生效的弹窗类接口）。
   * 当前时间窗的选中态改用系统菜单的 `selected` + `selectIcon`，不再自绘主题色文字与打勾图标。
   */
  @Builder
  HotRangeMenu() {
    Menu() {
      ForEach(HOT_RANGES, (range: SortMode) => {
        MenuItem({ content: range.label })
          .selected(this.hotRange === range.key)
          .selectIcon(true)
          .onClick(() => {
            // 内部已置 showHotRangeMenu = false 并切换时间窗
            this.handleHotRangeSelect(range.key)
          })
      }, (range: SortMode) => {
        return range.key
      })
    }
  }

  /**
   * 热门时间窗菜单选项。
   *
   * 锚点＝排序条右端那颗固定尺寸的透明占位节点（见 `build()` 里的排序条 `Stack`），
   * `Placement.BottomRight` 让菜单落在排序条下方、右边缘与排序条内容右边缘对齐——与迁移前
   * `.position({ top: sortBarBottomY + 6, right: '4%' })` 的落点一致（锚点底边已对齐排序条内容底边，
   * 纵向差额由系统 `targetSpace` 补）；`sortBarBottomY` 的采集因此只剩「状态视图撑满排序条下方的
   * 列表可视区」一个用途。
   *
   * **锚点不能再挂回排序条那一行**：整行是宽锚点，折叠屏多列路由下菜单会被算到窗口左侧
   * （`PanelNavBar` 三轮踩坑的同一结论，见 `docs/UI_COMPONENT_MIGRATION.md` §7.4 约束 7）。
   *
   * @returns 菜单选项
   */
  private hotRangeMenuOptions(): MenuOptions {
    const options: MenuOptions = {
      placement: Placement.BottomRight,
      enableArrow: false,
      // 背板交给系统材质：不设 backgroundColor / backgroundBlurStyle（不做设备降级，
      // 见 UIMaterialManager 的约定说明）
      systemMaterial: UIMaterialManager.menuMaterial,
      // 系统关闭菜单（点击区域外 / 列表滚动等）后回写显隐状态。这一处比标题栏菜单更要紧：
      // 排序条点击是"赋 true"而不是取反，状态一旦卡在 true，再点「热门」赋同一个值不触发刷新，
      // 菜单会**再也弹不出来**（迁移前由手搓遮罩的 onClick 承担，迁到 bindMenu 时漏了）。
      onDisappear: (): void => {
        this.showHotRangeMenu = false
      }
    }
    return options
  }

  /**
   * 子版块筛选半模态内容的居中外层（官方 `bindSheet` 承载，选项见 {@link subBoardFilterSheetOptions}）。
   *
   * 与 `FloatingLayerComponent.ReplyEditorSheet` 同构：外层负责居中与左右留白
   * （`sm` 10vp / 其余 24vp），内层 `SubBoardFilterPanel` 自带 600vp 宽度上限——
   * 面板在非 sm 断点被限宽（基准 648vp，按窗口收敛）后，内容恒按「600 + 左右各 24」摆放。
   */
  @Builder
  SubBoardFilterSheetContent() {
    Column() {
      this.SubBoardFilterPanel()
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({
      left: this.currentBreakpoint === 'sm' ? 10 : 24,
      right: this.currentBreakpoint === 'sm' ? 10 : 24
    })
  }

  /**
   * 子版块筛选面板内容本体。
   *
   * 面板**本体**的材质由 `SheetOptions.systemMaterial` 的系统沉浸材质承担——**半模态转场**属
   * Release 允许「页面内全部区域」生效的弹窗类接口。全屏遮罩、圆角与「点击空白关闭」分别改由
   * `maskColor`、`radius` 与下拉/侧滑手势承担，内容里不再自绘遮罩与玻璃面板。
   *
   * 面板内部的 `Toggle` 继续走 `controlMaterial`：Toggle 属官方「按钮与选择类」清单，生效范围
   * 与所在位置无关，**浮层内部依然生效**——这是它与普通容器（Column/Row/Text）最大的区别。
   *
   * **前景色一律取 `UIMaterialManager.adaptive*`（系统 `sys.color.font_*` / `icon_*`），不再用
   * `AppColors.text*`**——与 `ReplyDialog` / `NewTopicDialog` 同一套内容层取色契约（§12.3）。
   * 原因是结构性的，不是审美偏好：
   *
   * 1. 四条系统材质背板**一律不赋色**（§12.7），面板的实际底色是系统按深浅色模式自适应的中性色，
   *    **不等于**应用的实底 `bg`（暖白 `#FEFAF6` / 暗色 `#121214`）；而 `AppColors.text*` 是
   *    为那个暖白底调制的暖棕阶（`#3E2A1D` / `#9C8B7A` / `#C4B5A0`），落在系统材质上属于
   *    **跨调色板取色**——色相不匹配，明度余量也不是按材质底算的。
   * 2. 材质是**半透明**的，背后帖子列表的文字与图标会透上来。`textSecondary` / `textTertiary`
   *    在实底上"刚好够用"的对比余量会被这些透出的高频细节吃光（亮色下 `textTertiary`
   *    `#C4B5A0` 几乎不可辨，而它此刻正承担「已屏蔽」与「版块说明」两种信息）。
   * 3. 分隔线同理改用 `sys.color.comp_divider`（§6.3 表 1 的特殊系统资源，亮 `#33000000` /
   *    暗 `#33FFFFFF`）：它是随材质深浅色自适应的那一档，`AppColors.separator` 的暖米细线在
   *    系统材质上近乎不可见。
   *
   * 层级与状态也不再靠"颜色差"表达（§12.8）：行内用「主 / 次两档系统前景 + 字重」区分生效与屏蔽，
   * 「已屏蔽」升级为**中性半透明底的状态徽标**，「关闭」升级为**有边界的胶囊按钮**
   * （`dialogActionMaterial`，与 `ReplyDialog` 头部的模式切换胶囊是同一套内容层配方）。
   *
   * 根节点自带 600vp 宽度上限（`SheetWidthConstants.CONTENT_MAX_WIDTH`），居中与左右留白
   * 由 `SubBoardFilterSheetContent` 的外层容器承担。
   */
  @Builder
  SubBoardFilterPanel() {
    Column() {
      Row() {
        Column() {
          Text('子版块显示')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(UIMaterialManager.adaptiveForeground)
            .width('100%')
          Text() {
            Span('关闭即屏蔽，开关会同步到 ')
            Span('NGA 账号').fontWeight(FontWeight.Medium)
            Span('，并刷新当前父版块的帖子列表')
          }
          .fontSize(12)
          .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
          .lineHeight(16)
          .width('100%')
          .margin({ top: 3 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 「关闭」是面板内唯一的中性次要操作：从纯文字升级为有边界的胶囊，
        // 用 `dialogActionMaterial`（半透明填充 + 极淡描边、不做模糊）表达"可点区域"——
        // 与 ReplyDialog 头部的模式切换胶囊同一套内容层配方（§12.7）。纯文字入口在半透明
        // 材质上没有结构，用户要靠猜；描边胶囊在任何底色上都稳定。
        // 文字保留主题色（品牌强调，ReplyDialog 的主操作同样取 AppColors.primary）。
        Text('关闭')
          .fontSize(14)
          .fontColor(AppColors.primary)
          .height(32)
          .padding({ left: 14, right: 14 })
          .textAlign(TextAlign.Center)
          .borderRadius(16)
          .attributeModifier(UIMaterialManager.dialogActionMaterial)
          .onClick(() => {
            if (this.updatingSubBoardFilterId.length === 0) {
              this.showSubBoardFilterPanel = false
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      Divider().width('100%').color($r('sys.color.comp_divider'))

      List() {
        ForEach(this.subBoards, (subBoard: SubBoard) => {
          ListItem() {
            Row() {
              BoardIcon({ url: subBoard.boardHead, iconSize: 36, iconRadius: 8 })
                .opacity(subBoard.checked ? 1 : SUB_BOARD_BLOCKED_ICON_OPACITY)

              Column() {
                // 生效 / 屏蔽用「主 / 次两档系统前景 + 字重」区分，而不是三档应用色：
                // 系统色阶随材质深浅色自适应，且带正确的 alpha 档位，在半透明背板上仍有对比余量。
                Text(unescapeHtml(subBoard.name))
                  .fontSize(15)
                  .fontWeight(subBoard.checked ? FontWeight.Medium : FontWeight.Regular)
                  .fontColor(subBoard.checked
                    ? UIMaterialManager.adaptiveForeground
                    : UIMaterialManager.adaptiveSecondaryForeground)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                if (subBoard.checked && subBoard.description.length > 0) {
                  Text(unescapeHtml(subBoard.description))
                    .fontSize(12)
                    .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .margin({ top: 2 })
                }
                if (!subBoard.checked) {
                  // 「已屏蔽」是状态徽标，不再用"更淡的一档文字色"表达：颜色差会随透出的背景
                  // 漂移、且与上方的版块说明撞在同一档色上（§12.8）。改为中性半透明底 + 圆角胶囊，
                  // 底色取 `sys.color.comp_background_secondary`（§6.3 表 1，亮 10% 黑 / 暗 10% 白），
                  // 在任何材质底色上都是一块稳定的淡底，语义不再依赖颜色的深浅。
                  Text('已屏蔽')
                    .fontSize(11)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
                    .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                    .borderRadius(7)
                    .backgroundColor($r('sys.color.comp_background_secondary'))
                    .margin({ top: 3 })
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .margin({ left: 10, right: 10 })

              if (this.updatingSubBoardFilterId === subBoard.filterId) {
                LoadingProgress().width(22).height(22).color(AppColors.primary)
              } else {
                Toggle({
                  type: ToggleType.Switch,
                  isOn: subBoard.filterable ? subBoard.checked : true
                })
                  .enabled(subBoard.filterable && subBoard.filterId.length > 0
                    && this.updatingSubBoardFilterId.length === 0)
                  .onChange((show: boolean): void => {
                    this.handleSubBoardFilterChange(subBoard, show)
                  })
                  .systemMaterial(UIMaterialManager.controlMaterial)
              }
            }
            .width('100%')
            .height(58)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .alignItems(VerticalAlign.Center)
          }
        }, (subBoard: SubBoard) => {
          const stableId: string = subBoard.filterId.length > 0
            ? subBoard.filterId : `${subBoard.fid}:${subBoard.stid}:${subBoard.name}`
          return `${stableId}:${subBoard.checked ? 'shown' : 'blocked'}`
        })
      }
      .width('100%')
      .layoutWeight(1)
      .divider({ strokeWidth: 0.5, color: $r('sys.color.comp_divider'), startMargin: 60 })
      .scrollBar(BarState.Auto)
    }
    .width('100%').height('100%')
    .constraintSize({ maxWidth: SheetWidthConstants.CONTENT_MAX_WIDTH })
  }

  /**
   * 子版块筛选半模态选项。
   *
   * `dragBar` / `showClose` 关闭系统附属元素：内容区自带标题行与「关闭」入口，再叠一套系统元素
   * 会重复。`backgroundColor` 必须显式置 `Color.Transparent`——`BindOptions.backgroundColor`
   * 默认是 `Color.White`，不清掉的话这层白色内容会盖住背板材质（不做设备降级，见
   * `UIMaterialManager` 的约定说明）。`shouldDismiss` 保留迁移前「提交中点击遮罩不关闭」的守卫。
   *
   * @returns 半模态选项
   */
  private subBoardFilterSheetOptions(): SheetOptions {
    const options: SheetOptions = {
      height: '70%',
      dragBar: false,
      showClose: false,
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.sheetMaterial,
      maskColor: UIMaterialManager.scrim,
      preferType: this.currentBreakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
      // radius 的类型是 LengthMetrics | BorderRadiuses | LocalizedBorderRadiuses，**不接受裸 number**；
      // 四个圆角取同值（官方说明：圆角相等时面板视觉体验最佳），底部样式不显示底部两角，无副作用
      radius: { topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 16 },
      onDisappear: () => {
        // 系统关闭（下拉 / 侧滑 / 蒙层）后回写可见性，保证状态与面板一致
        this.showSubBoardFilterPanel = false
      },
      shouldDismiss: (sheetDismiss: SheetDismiss) => {
        if (this.updatingSubBoardFilterId.length === 0) {
          sheetDismiss.dismiss()
        } else {
          // 提交中要挡住关闭（与迁移前"点击遮罩不关闭"的守卫一致），但必须给一次反馈：
          // shouldDismiss 覆盖下拉 / 侧滑 / 返回键全部交互式关闭来源，静默 return 会让用户
          // 觉得"手势失灵"
          appStore.showToast('正在同步，请稍候')
        }
      }
    }
    // 宽度基准与编辑类半模态一致（`FloatingLayerComponent.editorSheetOptions`）：
    // 非 sm 限宽（基准 648vp）并按窗口收敛，否则折叠屏展开 / 平板上居中面板会横贯整个窗口宽度。
    // 窗口宽度未知时不设 width，交给系统默认宽度，避免用猜测值覆盖
    if (this.currentBreakpoint !== 'sm' && this.windowWidthVp > 0) {
      options.width = SheetWidthConstants.resolve(this.windowWidthVp)
    }
    return options
  }
}

@Component
struct TopicCardComponent {
  @Prop thread: Record<string, Object> = {}
  @Prop isFavorites: boolean = false
  @StorageProp('topicFontSize') topicFontSize: number = 15
  /** 黑名单变更版本号。 */
  @StorageProp('blacklistVersion') blacklistVersion: number = 0
  onRemoveFav: (tid: number) => void = (_tid: number) => {}
  onCardClick: (tid: string, pid: string) => void = (_tid: string, _pid: string) => {}
  /** 「显示帖子预览图」开关（默认开启；设置页改动即时生效，见 docs/TOPIC_PREVIEW_DESIGN.md §8）。 */
  @StorageProp('showTopicPreview') showTopicPreview: boolean = true
  /** 图片加载模式：决定预览图主动加载还是被动占位。 */
  @StorageProp('imageLoadStrategy') imageLoadStrategy: string = ImageLoadStrategy.ALWAYS
  /** 网络变更版本号：WiFi↔蜂窝切换 / 模式变更后重判被动态。 */
  @StorageProp('networkChangeVersion') networkChangeVersion: number = 0
  /**
   * 列表实测宽度（vp，由 `TopicListPanel` 采集后下传）。
   *
   * 预览图区宽度 = 本值 − 条目左右内边距（`ITEM_HORIZONTAL_PADDING`）；首帧为 0 时回落
   * `FALLBACK_PREVIEW_AREA_WIDTH`，列表布局完成后即被真实值替换。
   */
  @Prop listWidth: number = 0
  /**
   * 预览图是否已加载失败（失败即整块隐藏，不再尝试其它质量档）。
   *
   * **列表预览统一使用原图**（与 `ImageViewer` / `ThreadPanel` 的图片链路一致，见设计文档
   * §5.3 / K22）。组件内状态：LazyForEach 按 tid 复用，条目不变时状态保留；条目被回收重建时重置为 false。
   */
  @State private previewFailed: boolean = false
  /**
   * 图片显示布局的零尺寸兜底（仅 {@link tileAt} 下标越界时使用）。
   *
   * 单独持有一个实例而不是每次 `new`：`@Builder` 内部不能声明局部变量（ArkUI build 约束），
   * 越界分支若现场分配会在每帧布局里产生垃圾对象。
   */
  private emptyTile: PreviewTileLayout = new PreviewTileLayout()

  /**
   * 条目内**图片区总宽**（vp）：列表实测宽度 − 条目左右内边距 × 2。
   *
   * 区域宽度的唯一来源。**不能由断点硬编码推出**：`sm` 是整窗、`md` 是"窗口 − 侧边栏 180"、
   * `lg` 双列时还要再乘 40%，任何写死的宽度都会在其中一种形态下失配（K24）；首帧列表宽度
   * 尚未测得（`listWidth === 0`）时回落 `FALLBACK_PREVIEW_AREA_WIDTH`。
   *
   * @returns 图片区总宽（vp）
   */
  private previewAreaWidth(): number {
    return this.listWidth > 0
      ? this.listWidth - ITEM_HORIZONTAL_PADDING * 2
      : FALLBACK_PREVIEW_AREA_WIDTH
  }

  /**
   * 预览图**整行**布局（行高 + 每张图的显示尺寸），由纯函数算出，UI 侧不做算术。
   *
   * 区域（最大宽高）与逐张适配都在 `resolvePreviewRowLayout` 内部完成：它先按张数把图片区
   * 总宽折算成**单张可用区域**（多图扣掉图间距后均分、高度上限 240vp），再让每张图按自己的
   * 真实比例在区域内做最优适配（完整显示优先）。单图与多图因此走的是同一条算法，
   * 差别只在"区域是整宽还是单张分区宽"。
   *
   * @returns 整行布局
   */
  private previewRowLayout(): PreviewRowLayout {
    return resolvePreviewRowLayout(this.inlinePreviewImages(), this.previewAreaWidth())
  }

  /**
   * 整行高度（vp）：单图 = 该图显示高度；多图 = 各张显示高度的最大值。
   *
   * 被动占位块与实图**共用本值**，被动↔主动切换、WiFi↔蜂窝重判都不产生列表高度跳动（K6）。
   *
   * @returns 行高（vp）
   */
  private previewRowHeight(): number {
    return this.previewRowLayout().height
  }

  /**
   * 第 `index` 张图的显示布局（宽度 / 高度 / 是否完整显示）。
   *
   * @param index - 图片在 {@link inlinePreviewImages} 中的下标
   * @returns 单张布局；下标越界时返回零尺寸兜底（正常路径不会发生：tiles 与图片同源同长）
   */
  private tileAt(index: number): PreviewTileLayout {
    const tiles: PreviewTileLayout[] = this.previewRowLayout().tiles
    return index >= 0 && index < tiles.length ? tiles[index] : this.emptyTile
  }

  /**
   * 判断当前主题作者是否已被屏蔽。
   *
   * @returns 作者是否在实时黑名单中
   */
  private isAuthorBlacklisted(): boolean {
    return this.blacklistVersion >= 0 &&
      appStore.settingsStore.isBlacklisted(String(this.thread['authorId'] ?? ''))
  }

  /**
   * 判断当前摘要对应的回复作者是否已被屏蔽。
   *
   * @returns 摘要作者是否在实时黑名单中
   */
  private isPreviewAuthorBlacklisted(): boolean {
    const authorId: string = String(this.thread['previewAuthorId'] ?? '')
    return this.blacklistVersion >= 0 &&
      authorId.length > 0 &&
      appStore.settingsStore.isBlacklisted(authorId)
  }

  /**
   * 预览图列表（URL 与解析期算定的真实尺寸成对给出）。
   *
   * `@Prop thread` 为 Record，取数组必须判型（缺失/形状不符时返回空数组）。
   * 元素形状由解析层保证（`TopicPreviewUtils.parsePreviewAttachments`）——尺寸与 URL 同行产出，
   * 卡片因此不需要任何"未下载先探测"的请求：每张图的比例在解析期就已确定。
   *
   * @returns 预览图列表（保序）
   */
  private previewImages(): PreviewImage[] {
    const value: Object | undefined = this.thread['previewImages']
    if (value === undefined || value === null || !Array.isArray(value)) {
      return []
    }
    return value as PreviewImage[]
  }

  /**
   * 条目内**横排渲染**的预览图（最多 `PREVIEW_IMAGE_MAX_INLINE` 张）。
   *
   * 多图时只渲染前几张，其余不渲染也不叠数量角标（点开查看器可看全部）。限制数量既是为
   * 单张宽度留余量，也避免列表里同时发起过多图片请求（实测最多的条目带 7 张图）。
   *
   * 布局与渲染共用本方法：区域按**渲染出来的张数**均分，不按 `previewImages` 总数——
   * 否则 7 张的条目会按 7 份均分宽度、却只画 3 张，每张白白窄掉一半。
   *
   * @returns 前 N 张（保序）
   */
  private inlinePreviewImages(): PreviewImage[] {
    const images: PreviewImage[] = this.previewImages()
    return images.length > PREVIEW_IMAGE_MAX_INLINE
      ? images.slice(0, PREVIEW_IMAGE_MAX_INLINE)
      : images
  }

  /**
   * 是否渲染预览图区。
   *
   * 三级判定（任一不满足即整块不渲染、不占高度）：
   *  1. 设置开关开启（showTopicPreview）；
   *  2. 条目有可用预览图（previewImages 非空）；
   *  3. 尚未加载失败（`previewFailed === false`）。
   *
   * 「是否真的发起图片请求」由 `shouldUsePassive` 另行决定——本方法只回答"这块 UI 存不存在"。
   *
   * @returns 是否渲染预览图区
   */
  private shouldRenderPreview(): boolean {
    return this.showTopicPreview && this.previewImages().length > 0 && !this.previewFailed
  }

  /**
   * 原图加载失败 → 隐藏整块。
   *
   * **只有这一级**：列表统一用原图，没有更低质量的回退档（见设计文档 §5.3 / K22）。
   * 置位幂等：同一次加载即使 `onError` 与 `onComplete` 都触发也只隐藏一次。
   */
  private onPreviewFailed(): void {
    this.previewFailed = true
  }

  /**
   * 判断解码结果是否为 NGA 的"失效图"占位。
   *
   * CDN 对不存在的附件路径返回 `404 + content-type: image/gif` + 43 字节 `GIF89a` **1×1** 图，
   * ArkUI `Image` 把这次响应当作**加载成功**（`onError` 不触发、`onComplete` 回填 1×1，见
   * docs/research/IMAGE_PIPELINE_AUDIT.md §5.2）：只靠 `onError` 判失败，失效图会被
   * `ImageFit.Cover` 拉成一张纯色空白大图。
   *
   * **精确匹配 1×1**（不用 `≤1`）：`width/height` 为 0 表示尚未解码出尺寸，
   * 此时不能判失败，否则会平白多一次原图回退、最坏把合法图隐藏。
   *
   * @param width - 解码后图片宽度（px）
   * @param height - 解码后图片高度（px）
   * @returns 是否为失效占位图
   */
  private isBrokenPreview(width: number, height: number): boolean {
    return width === 1 && height === 1
  }

  /**
   * 预览图区（摘要下方、底栏上方）。
   *
   * 两个互斥分支：
   *  1. **被动加载**（`shouldUsePassive`：手动模式，或"仅 WiFi"模式下的蜂窝网络）→ 占位块。
   *     用 `if / else` 分支隔离：不创建 `Image` 节点就不会发起请求（不能用 `visibility`
   *     隐藏，那仍可能触发加载，见设计文档 §6.3 / K8）。
   *  2. 实图 → **直接使用原图 URL**（与 `ImageViewer` / `ThreadPanel` 的图片链路一致，
   *     见设计文档 §5.3 / K22）；加载失败即隐藏整块。
   *
   * **区域与逐张适配都由纯函数给出**（见设计文档 §6.2 / §6.8），本 Builder 只摆放：
   * - 区域：`resolvePreviewArea(图片区总宽, 张数)` → 单张可用宽（多图扣间距后均分）× 240vp 上限；
   * - 每张图**各自**按自身真实比例在该区域内做最优适配（完整显示优先、至少一边贴满），
   *   宽度与高度都**不超过区域**——`Cover` 只在"超宽全景图被最小高度抬起后按比例会超出区域宽"
   *   时才出现，此时裁掉的是两端而不是主体；
   * - 整行高度 = 各张显示高度的最大值（多图不逐张撑高行高，行内其余图垂直居中）；
   * - 被动占位块与实图**同高**（同一个 `previewRowHeight()`），切换与加载过程中不产生跳动。
   *
   * **每张图用自己的布局**（`tileAt(index)`）：改造前整行共用首图的布局，首图是横图时第二张
   * 竖图也会被套上横图容器，完整显示/裁切两种语义被强行统一到首图上。
   *
   * **不渲染任何角标**（用户明确要求移除）：多图「N 图」数量角标（多图横排本身"看得见"张数，
   * 再叠一个数字属于重复表达，且会压住最后一张图的角落）与单图极端比例的「长图」提示角标
   * **都已删除**。预览区因此只有图片本身（或被动态占位块），右下角不再有任何文字徽标；
   * 外层容器也不再是"用来叠角标"的 `Stack`，只承担公共宽度与区块间距（`Column`）。
   *
   * 宽度与高度**双向显式**写死（容器与 `Image` 各自 `.width/.height`）：SDK 声明
   * 「`Image` 未设宽高时获取失败或尺寸为 0 会被自动重设为 0，且不遵循父布局约束」
   * （`component/image.d.ts`），靠自适应会在失效图（NGA 的 404 → 43 字节 1×1 GIF）上塌陷。
   */
  @Builder
  previewArea() {
    if (this.shouldRenderPreview()) {
      Column() {
        if (shouldUsePassive(this.imageLoadStrategy)) {
          Row() {
            Image($r('app.media.icon_image')).width(22).height(22)
              .fillColor(AppColors.textTertiary).opacity(0.45)
          }
          .width('100%').height(this.previewRowHeight())
          .justifyContent(FlexAlign.Center)
          .borderRadius(PREVIEW_IMAGE_RADIUS).backgroundColor(AppColors.bgSecondary)
        } else {
          Row({ space: PREVIEW_IMAGE_GAP }) {
            ForEach(this.inlinePreviewImages(), (image: PreviewImage, index: number) => {
              Image(image.url)
                /* 尺寸按**这张图自己**的布局：完整显示时宽度 = 高度 × 比例（贴合图片、两侧不留白），
                   需要裁切时取满分区宽度。恒用 `width('100%')` 会让窄图两侧各留一条空白。 */
                .width(this.tileAt(index).width)
                .height(this.tileAt(index).height)
                .objectFit(this.tileAt(index).useContain ? ImageFit.Contain : ImageFit.Cover)
                .borderRadius(PREVIEW_IMAGE_RADIUS)
                /* 内容到位时的柔和淡入（`@since 21`）。声明只排除"动态图资源"，对网络图 src 是否
                   生效未定义——**待真机复核**：若实测无效（表现为图片硬切出现），删掉本行即可，
                   其余布局不依赖它。 */
                .contentTransition(ContentTransitionEffect.OPACITY)
                /* 404 会被 Image 当作加载成功、onError 不触发，故同时用 onComplete 的尺寸补判 */
                .onComplete((event) => {
                  if (event && this.isBrokenPreview(event.width, event.height)) {
                    this.onPreviewFailed()
                  }
                })
                .onError(() => { this.onPreviewFailed() })
            }, (image: PreviewImage) => image.url)
          }
          .width('100%')
          /* 行高 = 各张显示高度的最大值：每张图按自身布局取高，Row 按最高者定高，
             其余图在其中垂直居中（默认 `VerticalAlign.Center`）——一行整齐，又不牺牲任何一张的完整性 */
          .height(this.previewRowHeight())
          /* 左对齐：窄图收窄后必须贴左，否则 Row 的默认排布会把它们挤到中间 */
          .justifyContent(FlexAlign.Start)
        }
      }
      .width('100%')
      /* 每个区块自带 `margin top`，值统一为 ITEM_BLOCK_GAP：
         标题→摘要、摘要→图片、图片→底栏三处因此完全一致（无摘要时"标题→图片"也是同一值）。
         此前只有图片区没有自己的 margin，它的间距依赖"上一个区块是否带 margin"，
         于是有无摘要会出现两种间距。 */
      .margin({ top: ITEM_BLOCK_GAP })
    }
  }

  /**
   * 列表单元主体（§6.1 的顺序：**标题 → 摘要 → 图片 → 底栏**）。
   *
   * 预览图放在摘要之后、底栏之前：标题与摘要构成"这条帖子讲什么"的信息块，图片作为其佐证，
   * 底栏（作者 / 时间 / 回复数）收尾。标题行因此**不需要**条件性 `margin top`——预览区在它
   * 下方，无图条目天然保持紧凑。
   */
  build() {
    Column() {
      Row() {
        if (this.isAuthorBlacklisted()) {
          Text('该用户已被屏蔽')
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_TITLE, this.topicFontSize))
            .fontColor(AppColors.textTertiary)
            .layoutWeight(1)
        } else {
          Text(getTypeTags(Number(this.thread['type'] ?? 0)))
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_TITLE, this.topicFontSize))
            .fontColor(AppColors.textTertiary)
          Text(unescapeHtml(String(this.thread['subject'] ?? '')))
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_TITLE, this.topicFontSize))
            .fontColor(getSubjectFontColor(String(this.thread['titleFont'] ?? '')))
            .fontWeight(isSubjectBold(String(this.thread['titleFont'] ?? '')) ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(isSubjectItalic(String(this.thread['titleFont'] ?? '')) ? FontStyle.Italic : FontStyle.Normal)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        }
        if (this.isFavorites) {
          Image($r('app.media.icon_close')).width(16).height(16).fillColor(AppColors.textTertiary)
            .padding({ left: 8, right: 4 })
            .onClick(() => { this.onRemoveFav(Number(this.thread['tid'] ?? 0)) })
        }
      }
      .width('100%').alignItems(VerticalAlign.Top)

      if (this.thread['previewSnippet']) {
        if (this.isPreviewAuthorBlacklisted()) {
          Text('该用户已被屏蔽')
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_SUMMARY, this.topicFontSize))
            .fontColor(AppColors.textTertiary)
            .margin({ top: ITEM_BLOCK_GAP })
            .width('100%')
        } else {
          Text(unescapeHtml(String(this.thread['previewSnippet'] ?? '')))
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_SUMMARY, this.topicFontSize))
            .fontColor(AppColors.textSecondary)
            .maxLines(2)
            .lineHeight(ReadingTypography.lineHeight(
              ReadingLineHeightRole.TOPIC_SUMMARY,
              ReadingTypography.fontSize(ReadingFontRole.TOPIC_SUMMARY, this.topicFontSize)
            ))
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: ITEM_BLOCK_GAP }).width('100%')
        }
      }

      this.previewArea()

      Row() {
        Row() {
          AnonymousName({ author: String(this.thread['author'] ?? ''), isAnonymous: this.thread['isAnonymity'] as boolean, fontSize: 12 })
          if (appStore.settingsStore.getNote(String(this.thread['authorId'] ?? '')).length > 0) {
            Text('(' + appStore.settingsStore.getNote(String(this.thread['authorId'] ?? '')) + ')')
              .fontSize(11).fontColor(AppColors.warning).margin({ left: 3 })
          }
          Text(` · ${formatTime(Number(this.thread['postDate'] ?? 0))}`)
            .fontSize(12).fontColor(AppColors.textTertiary)
          if (this.thread['board']) {
            Text(` · ${unescapeHtml(String(this.thread['board']))}`)
              .fontSize(12).fontColor(AppColors.textTertiary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.layoutWeight(1)
        Row() { Image($r('app.media.icon_chat_bubble')).width(12).height(12).fillColor(AppColors.textTertiary); Text(` ${this.thread['replies'] ?? 0}`).fontSize(12).fontColor(AppColors.textTertiary) }
      }.width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ top: ITEM_BLOCK_GAP })
    }
    .width('100%')
    /* 条目内边距：横向留白只由这一层承担（见 `ITEM_HORIZONTAL_PADDING` 常量注释） */
    .padding({
      left: ITEM_HORIZONTAL_PADDING,
      right: ITEM_HORIZONTAL_PADDING,
      top: 16,
      bottom: 16
    })
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      // 普通列表 pid 为 0（NGA 的"主楼/无楼层"哨兵值），在入口判断前就归一为空串，
      // 避免误入 pid→页码预查找；searchpost 回帖列表携带真实楼层 pid
      const rawPid: number = Number(this.thread['pid'] ?? 0)
      this.onCardClick(String(this.thread['tid'] ?? ''), rawPid > 0 ? String(rawPid) : '')
    })
  }
}

function getSubjectFontColor(titleFont: string): ResourceColor {
  const num = Number(titleFont) || 0
  const color = num & 0x1f
  if (FONT_COLORS[color]) return FONT_COLORS[color]
  return AppColors.textPrimary
}

function isSubjectBold(titleFont: string): boolean {
  return (Number(titleFont) & 32) !== 0
}

function isSubjectItalic(titleFont: string): boolean {
  return (Number(titleFont) & 64) !== 0
}

function getTypeTags(type: number): string {
  if (type & 1024) return '[锁定]'
  return ''
}
