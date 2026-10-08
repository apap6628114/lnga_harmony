/**
 * 主页面 - 统一三列 Panel 架构
 *
 * 三列均保持在相同树节点位置，通过 .visibility() 控制显隐，避免断点切换时组件重建导致 @State 丢失。
 * SidebarComponent 内部 CommunityPanel 始终以 md+ 模式渲染 (SidebarListContent)，
 * 避免 sm 隐藏时浪费渲染 MobileTwoPanelContent。
 *
 * sm (一列): 侧边栏隐藏, 单列内容 (activity > board > 社区网格)
 * md (两列): 侧边栏 + 单列内容 (activity > board > empty)
 * lg (三列): 侧边栏 + 板块列 + 活动列 (并行显示)
 *
 * ## 列堆栈占比（用户可调）
 *
 * 断点阈值（600 / 840vp）不可调，但每一列分到多少宽度由用户决定：
 * 侧边栏底部的「三竖」按钮激活**占比模式**后，列交接处出现拖动把手、每列顶部显示
 * `百分比 · vp` 读数。几何真源是两个量 —— 侧边栏宽度（vp）与板块列占内容区的比例 ——
 * 具体模型与钳制规则见 `ColumnLayoutMath`。
 *
 * 两个要点：
 * - **占比恒生效，按钮只切换把手/读数的显示**：拖出来的布局关掉模式后不会被打回默认，
 *   否则"持久化保存"没有意义。
 * - **md 与 lg 各自独立**：md 只有「侧边栏 | 内容」一条交接，lg 才有「板块列 | 活动列」，
 *   两套数值分开存（见 `SettingsState.columnSidebarMd` / `columnSidebarLg`）。
 */

import { appStore } from '../store/AppStore'
import { routerStore, RouterStoreClass } from '../store/RouterStore'
import { verifyToken } from '../service/api/AuthApi'

import { floatingLayerStore, FloatingLayerStoreClass, FloatingPage } from '../store/FloatingLayerStore'
import {
  AppColors,
  NAV_BAR_H,
  COLUMN_HANDLE_HIT_W,
  COLUMN_HANDLE_GRIP_W,
  COLUMN_HANDLE_GRIP_H,
  COLUMN_READOUT_BAR_H
} from '../common/constants/Constants'
import { ColumnLayoutMath } from '../common/utils/ColumnLayoutMath'
import type { ColumnMetrics } from '../common/utils/ColumnLayoutMath'
import { ActivityRouter } from './ActivityRouter'
import { BoardRouter } from './BoardRouter'
import { SidebarComponent } from '../common/components/SidebarComponent'
import { CommunityPanel } from './CommunityPanel'
import { FloatingLayerComponent } from '../common/components/FloatingLayerComponent'
import { EmptyHint } from '../common/components/EmptyHint'
import { TtsProgressIndicator } from '../common/components/TtsProgressIndicator'
import { SavedThreadProgressIndicator } from '../common/components/SavedThreadProgressIndicator'
import { PidLocateIndicator } from '../common/components/PidLocateIndicator'
import { Logger, DOMAIN_UI } from '../common/utils/Logger'
import { enableKeepScreenOn, disableKeepScreenOn } from '../common/managers/ScreenOnManager'

const logger = new Logger(DOMAIN_UI, 'MainPage')

/** 把手槽位：侧边栏 | 内容 的交接。 */
const HANDLE_SIDEBAR: number = 0
/** 把手槽位：板块列 | 活动列 的交接。 */
const HANDLE_BOARD: number = 1

/** 读数槽位：侧边栏。 */
const SLOT_SIDEBAR: number = 0
/** 读数槽位：板块列。 */
const SLOT_BOARD: number = 1
/** 读数槽位：活动列。 */
const SLOT_ACTIVITY: number = 2

/** 拖动中的哨兵值：宽度 / 占比都是正数，负数即"未拖动"。 */
const NOT_DRAGGING: number = -1

/**
 * 读数标尺在激活占比模式后的常显时长（ms）。
 *
 * 标尺**不做常驻显示**：它压在标题栏正下方，而这段正是各列内容的第一行 ——
 * 主题列表的排序条（`TopicListPanel` 的第一个 `ListItem`，`SegmentButton` 高 28vp）
 * 恰好从这里开始，常驻会盖住其中约 16vp，出现"看得见一半、点得到全部"的错位。
 * 改为"激活时亮一下 + 拖动全程常显 + 松手后再留一会儿"，既保证被看见，又不常驻遮挡。
 */
const READOUT_BAR_HOLD_MS: number = 5000

/** 把手松手后读数标尺的保留时长（ms）：让用户能核对刚拖到的数值。 */
const READOUT_BAR_RELEASE_HOLD_MS: number = 1600

@Entry
@Component
struct MainPage {
  @StorageProp('currentBreakpoint') @Watch('onBreakpointChanged') currentBreakpoint: string = 'sm'
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @StorageProp('windowWidthVp') windowWidthVp: number = 0
  /** 占比模式开关（侧边栏底部按钮写入，纯内存态）。 */
  @StorageProp('columnRatioMode') @Watch('onColumnRatioModeChanged') columnRatioMode: boolean = false
  /** md 断点侧边栏宽度（vp）。 */
  @StorageProp('columnSidebarWidthMd') @Watch('onColumnLayoutChanged') columnSidebarMd: number = 180
  /** lg 断点侧边栏宽度（vp）。 */
  @StorageProp('columnSidebarWidthLg') @Watch('onColumnLayoutChanged') columnSidebarLg: number = 180
  /** lg 断点板块列占内容区的比例。 */
  @StorageProp('columnBoardRatioLg') @Watch('onColumnLayoutChanged') columnBoardRatioLg: number = 0.4
  @StorageProp('profileVersion') @Watch('onProfileRefresh') profileVersion: number = 0
  @State private router: RouterStoreClass = routerStore
  @State private floating: FloatingLayerStoreClass = floatingLayerStore
  /**
   * 根容器实测宽度（vp）。
   *
   * 列宽的**宽度真源**：`windowWidthVp` 是窗口级的（分屏 / 自由窗口下与页面区域一致），
   * 但首帧可能尚未写入，实测值是更直接的一手数据；两者都拿不到时由
   * `ColumnLayoutMath` 回落兜底常量。
   */
  @State private measuredWidth: number = 0
  /** 拖动中的侧边栏宽度（vp），`NOT_DRAGGING` 表示取持久化值。 */
  @State private dragSidebarVp: number = NOT_DRAGGING
  /** 拖动中的板块列占比，`NOT_DRAGGING` 表示取持久化值。 */
  @State private dragBoardRatio: number = NOT_DRAGGING
  /** 正在拖动的把手槽位（-1=无），用于握柄高亮。 */
  @State private draggingHandle: number = NOT_DRAGGING
  /**
   * 读数标尺是否可见。
   *
   * 只由 {@link showReadoutBar} / {@link scheduleReadoutBarHide} 驱动：激活模式时显示
   * `READOUT_BAR_HOLD_MS`，拖动期间钉住，松手后再保留 `READOUT_BAR_RELEASE_HOLD_MS`。
   */
  @State private readoutBarVisible: boolean = false
  /** 读数标尺自动收起的计时器 id（`NOT_DRAGGING` 表示无待执行计时）。 */
  private readoutBarTimer: number = NOT_DRAGGING
  /** 把手按下瞬间的侧边栏宽度（vp，**已钳制的渲染值**）：拖动全程以它为基准叠加手势偏移量。 */
  private dragBaseSidebarVp: number = 0
  /** 把手按下瞬间的板块列宽度（vp，同样是渲染值）。 */
  private dragBaseBoardVp: number = 0
  /** 把手按下时的断点：抬手按它落盘，避免拖动途中跨断点把值写进另一个槽位。 */
  private dragBreakpoint: string = 'md'

  aboutToAppear(): void {
    // 登录进入主页面后保持屏幕常亮（不息屏），离开主页面时恢复自动息屏
    enableKeepScreenOn()
    this.checkAuth()
  }

  aboutToDisappear(): void {
    disableKeepScreenOn()
    this.clearReadoutBarTimer()
  }

  private onProfileRefresh(): void {
    const cached = appStore.getCachedProfile(appStore.auth.uid)
    if (cached) {
      appStore.auth.nickName = cached.userName
      appStore.auth.avatarUrl = cached.avatarUrl
    }
  }

  /**
   * 持久化值变化后退出「拖动中」覆盖态。
   *
   * 拖动期间列宽读的是本地 @State（避免逐帧写 AppStorage 触发全量刷新），
   * 抬手提交后以持久化值为准。这里不能只在提交处复位：账号切换 / 设置被
   * 外部改写等路径同样要回到持久化真源。
   */
  private onColumnLayoutChanged(): void {
    this.resetHandleDrag()
  }

  /**
   * 占比模式开关变化：起停读数标尺。
   *
   * 标尺的出现/消失自带 `TransitionEffect` 动画（`animation()` 已配参数，属"直接增删组件"式
   * 自播），不需要额外 `animateTo` 包裹。
   */
  private onColumnRatioModeChanged(): void {
    if (this.columnRatioMode) {
      this.showReadoutBar()
      this.scheduleReadoutBarHide(READOUT_BAR_HOLD_MS)
      return
    }
    this.hideReadoutBar()
  }

  /**
   * 断点变化：作废拖动覆盖态。
   *
   * 跨断点时列几何、把手数量与位置都会重算，拖动途中采样的基准（`dragBase*`）随即失效；
   * 若把手被卸载时系统未派发 `onActionCancel`，覆盖值会一直武装 —— 列宽卡在拖动值、
   * 无视后续持久化值，标尺那两格还会永久反色高亮。
   */
  private onBreakpointChanged(): void {
    this.resetHandleDrag()
    if (this.currentBreakpoint === 'sm') {
      this.hideReadoutBar()
    }
  }

  // ============== 读数标尺的显示时机 ==============

  /** 显示读数标尺，并取消待执行的自动收起（由调用方决定何时收起）。 */
  private showReadoutBar(): void {
    this.clearReadoutBarTimer()
    if (!this.readoutBarVisible) {
      this.readoutBarVisible = true
    }
  }

  /** 安排读数标尺在 `delay` 毫秒后收起。 */
  private scheduleReadoutBarHide(delay: number): void {
    this.clearReadoutBarTimer()
    this.readoutBarTimer = setTimeout((): void => {
      this.readoutBarTimer = NOT_DRAGGING
      this.readoutBarVisible = false
    }, delay)
  }

  /** 立即收起读数标尺。 */
  private hideReadoutBar(): void {
    this.clearReadoutBarTimer()
    if (this.readoutBarVisible) {
      this.readoutBarVisible = false
    }
  }

  private clearReadoutBarTimer(): void {
    if (this.readoutBarTimer !== NOT_DRAGGING) {
      clearTimeout(this.readoutBarTimer)
      this.readoutBarTimer = NOT_DRAGGING
    }
  }

  onBackPress(): boolean {
    if (this.floating.size > 0) {
      if (this.floating.top === FloatingPage.REPLY_DIALOG ||
        this.floating.top === FloatingPage.NEW_TOPIC_DIALOG) {
        this.floating.notifyReplyCloseRequested()
      } else {
        this.floating.pop()
      }
      return true
    }
    if (this.router.activityStack.length > 0) {
      this.router.back()
      return true
    }
    if (this.router.boardSlot) {
      if (this.currentBreakpoint === 'sm' || this.router.boardSlot.type === 'search') {
        this.router.back()
        return true
      }
      return true
    }
    return false
  }

  build() {
    // 不设 alignContent：保持默认 Center，与改造前一致（FloatingLayer / 进度指示器都按
    // 满屏容器 + 自身 alignContent 定位，但没必要去动这个既有前提）。
    // 占比模式的浮层一律用 .position() 绝对定位，position 与父容器对齐方式无关。
    Stack() {
      Row() {
        // 宽度与高度都由组件自己按列占比设置：这里只保留父组件才该决定的两件事
        // （可见性、以及不可见的 sm 断点）。同名属性两处都写会变成"谁生效"的隐式约定。
        SidebarComponent({ sidebarWidth: this.sidebarWidth() })
          .visibility(this.currentBreakpoint === 'sm' ? Visibility.None : Visibility.Visible)

        Row() {
          Column() {
            if (this.currentBreakpoint === 'sm') {
              CommunityPanel({ currentBreakpoint: 'sm' })
                .width('100%').height('100%')
                .visibility(!this.router.boardSlot && !this.router.topActivity
                  ? Visibility.Visible : Visibility.None)
            }
            if (this.router.boardSlot) {
              BoardRouter({ boardSlot: this.router.boardSlot })
            }
            if (this.currentBreakpoint !== 'sm' && !this.router.boardSlot && !this.router.topActivity) {
              EmptyHint()
            }
          }
          .height('100%')
          .width(this.boardWidth())
          .backgroundColor(AppColors.bg)
          .visibility(this.getBoardColVisibility())

          Column() {
            ActivityRouter({ activityStack: this.router.activityStack })
          }
          .width(this.activityWidth())
          .height('100%')
          .backgroundColor(AppColors.bg)
          .visibility(this.getActivityColVisibility())
        }
        .layoutWeight(1)
        .height('100%')
        .backgroundColor(AppColors.bg)
      }
      .width('100%')
      .height('100%')
      .onAreaChange((_oldValue: Area, newValue: Area): void => {
        if (typeof newValue.width === 'number' && newValue.width > 0 &&
          newValue.width !== this.measuredWidth) {
          this.measuredWidth = newValue.width
        }
      })

      // 占比模式浮层：读数标尺（短暂显示）+ 拖动把手（全程显示）。只叠在列之上、系统浮层之下。
      if (this.columnRatioMode && this.currentBreakpoint !== 'sm' && this.readoutBarVisible) {
        this.ColumnRatioBar()
      }
      if (this.columnRatioMode && this.currentBreakpoint !== 'sm') {
        this.ColumnHandle(HANDLE_SIDEBAR)
        this.ColumnHandle(HANDLE_BOARD)
      }

      FloatingLayerComponent({ currentBreakpoint: this.currentBreakpoint })
      // 注：Toast 已迁到系统浮层（PromptAction.openCustomDialog），不再挂在页面根 Stack。
      // 原因见 common/feedback/ToastOverlay.ets 文件头：页面树整体位于系统浮层树之下，
      // 只要 bindSheet / bindContentCover 开着，页面内渲染的提示就会被完全遮住。
      TtsProgressIndicator()
      SavedThreadProgressIndicator()
      PidLocateIndicator()
    }
    .width('100%').height('100%')
  }

  // ============== 列堆栈占比：几何 ==============

  /** 布局宽度真源（vp）：优先根容器实测值，其次窗口上报值，最后兜底常量。 */
  private windowWidth(): number {
    const measured: number = this.measuredWidth > 0 ? this.measuredWidth : this.windowWidthVp
    return ColumnLayoutMath.normalizeWindowWidth(measured)
  }

  /** 当前生效的侧边栏宽度（vp）：拖动中取本地值，否则取本断点的持久化值。 */
  private currentSidebarVp(): number {
    if (this.dragSidebarVp !== NOT_DRAGGING) {
      return this.dragSidebarVp
    }
    return this.currentBreakpoint === 'md' ? this.columnSidebarMd : this.columnSidebarLg
  }

  /** 当前生效的板块列占比：拖动中取本地值，否则取持久化值。 */
  private currentBoardRatio(): number {
    return this.dragBoardRatio !== NOT_DRAGGING ? this.dragBoardRatio : this.columnBoardRatioLg
  }

  /**
   * 解析三列几何（宽度 + 占整窗百分比）。
   *
   * 每次调用都重算：入参全是会变的响应式状态，缓存反而要维护失效条件。
   * 计算量是常数级的几次乘除，相对一帧的布局开销可以忽略。
   */
  private columnMetrics(): ColumnMetrics {
    return ColumnLayoutMath.resolve(
      this.windowWidth(),
      this.currentBreakpoint,
      this.currentSidebarVp(),
      this.currentBoardRatio(),
      this.getBoardColVisibility() === Visibility.Visible,
      this.getActivityColVisibility() === Visibility.Visible
    )
  }

  private sidebarWidth(): number {
    return this.columnMetrics().sidebarVp
  }

  private boardWidth(): number {
    return this.columnMetrics().boardVp
  }

  private activityWidth(): number {
    return this.columnMetrics().activityVp
  }

  private getBoardColVisibility(): Visibility {
    if (this.currentBreakpoint === 'lg') {
      return (this.router.boardSlot || !this.router.topActivity) ? Visibility.Visible : Visibility.None
    }
    return this.router.topActivity ? Visibility.None : Visibility.Visible
  }

  private getActivityColVisibility(): Visibility {
    return this.router.topActivity ? Visibility.Visible : Visibility.None
  }

  // ============== 列堆栈占比：读数与把手 ==============

  /** 读数槽位的宽度（vp）—— 同时是"该列是否可见"的判据（隐藏列为 0）。 */
  private slotWidth(slot: number): number {
    const m: ColumnMetrics = this.columnMetrics()
    if (slot === SLOT_SIDEBAR) {
      return m.sidebarVp
    }
    if (slot === SLOT_BOARD) {
      return m.boardVp
    }
    return m.activityVp
  }

  /** 读数文案：`21% · 180vp`。 */
  private slotReadout(slot: number): string {
    const m: ColumnMetrics = this.columnMetrics()
    if (slot === SLOT_SIDEBAR) {
      return ColumnLayoutMath.formatReadout(m.sidebarVp, m.sidebarPercent)
    }
    if (slot === SLOT_BOARD) {
      return ColumnLayoutMath.formatReadout(m.boardVp, m.boardPercent)
    }
    return ColumnLayoutMath.formatReadout(m.activityVp, m.activityPercent)
  }

  /** 把手横坐标（vp，相对窗口）：取所在交接线的中心。 */
  private handleX(slot: number): number {
    const m: ColumnMetrics = this.columnMetrics()
    if (slot === HANDLE_SIDEBAR) {
      return m.sidebarVp
    }
    return m.sidebarVp + m.boardVp
  }

  /**
   * 把手是否应该存在。
   *
   * 侧边栏把手：多列断点下侧边栏与内容列都可见时才有交接线。
   * 板块把手：只有 lg 且板块列 / 活动列**同时可见**时才有这条交接线。
   */
  private handleVisible(slot: number): boolean {
    if (this.currentBreakpoint === 'sm') {
      return false
    }
    const m: ColumnMetrics = this.columnMetrics()
    if (slot === HANDLE_SIDEBAR) {
      return m.sidebarVp > 0 && (m.boardVp > 0 || m.activityVp > 0)
    }
    return m.boardVp > 0 && m.activityVp > 0
  }

  /** 按下把手：记录拖动基准（手势偏移量是相对按下点的累计值），并把标尺钉在屏幕上。 */
  private beginHandleDrag(slot: number): void {
    const m: ColumnMetrics = this.columnMetrics()
    this.draggingHandle = slot
    this.dragBreakpoint = this.currentBreakpoint
    this.dragBaseSidebarVp = m.sidebarVp
    this.dragBaseBoardVp = m.boardVp
    this.showReadoutBar()
  }

  /** 拖动中：只写本地 @State，逐帧改 AppStorage 会让所有订阅者跟着重建。 */
  private updateHandleDrag(slot: number, offsetX: number): void {
    // 把手可能在拖动途中因断点切换 / 活动列消失而被卸载：此时基准已无意义，直接丢弃
    if (!this.handleVisible(slot)) {
      return
    }
    if (slot === HANDLE_SIDEBAR) {
      this.dragSidebarVp = ColumnLayoutMath.clampSidebar(
        this.windowWidth(), this.dragBaseSidebarVp + offsetX)
      return
    }
    // 基准必须用**按下瞬间的渲染宽度**（`dragBaseSidebarVp`，已按窗口钳制），不能用持久化原值：
    // 窗口收窄后原值可能超过当前上限，内容区会被算小、占比被算大，拖动系统性放大且不跟手
    this.dragBoardRatio = ColumnLayoutMath.ratioFromBoardWidth(
      this.windowWidth(), this.dragBaseSidebarVp, this.dragBaseBoardVp + offsetX)
  }

  /**
   * 抬手：把拖动结果提交到设置（触发持久化），并退出拖动覆盖态。
   *
   * **只在渲染几何确实变了时才落盘。** 拖动读的是"渲染后的值"（被窗口收敛过），
   * 而持久化存的是"用户意图"（原值）。若把手已经顶在当前窗口的上限、用户又往同方向推，
   * 渲染结果与按下时完全相同 —— 此时落盘会把「宽窗口下的意图值」永久覆写成收敛值
   * （典型：宽窗口设 320 → 窗口收窄渲染 294 → 轻触把手即把 320 写成 294）。
   */
  private endHandleDrag(slot: number): void {
    const widthVp: number = this.dragSidebarVp
    const ratio: number = this.dragBoardRatio
    const breakpoint: string = this.dragBreakpoint
    this.resetHandleDrag()
    this.scheduleReadoutBarHide(READOUT_BAR_RELEASE_HOLD_MS)
    if (breakpoint === 'sm') {
      return
    }
    if (slot === HANDLE_SIDEBAR) {
      if (widthVp !== NOT_DRAGGING && widthVp !== this.dragBaseSidebarVp) {
        appStore.settingsStore.setColumnSidebarWidth(breakpoint, widthVp)
      }
      return
    }
    if (ratio === NOT_DRAGGING) {
      return
    }
    const content: number = Math.max(0, this.windowWidth() - this.dragBaseSidebarVp)
    if (Math.round(content * ratio) !== this.dragBaseBoardVp) {
      appStore.settingsStore.setColumnBoardRatio(ratio)
    }
  }

  /** 退出拖动覆盖态（不提交）：覆盖值与拖动基准一并作废。 */
  private resetHandleDrag(): void {
    this.draggingHandle = NOT_DRAGGING
    this.dragSidebarVp = NOT_DRAGGING
    this.dragBoardRatio = NOT_DRAGGING
  }

  /**
   * 占比读数标尺：一条横贯窗口的条，分格宽度 = 各列宽度，分格线正对拖动把手。
   *
   * 为什么不是浮在每列顶上的小胶囊：胶囊浮在列表内容里，既容易被当成列表内容的一部分，
   * 又看不清数字归属哪一列（实测关注度不足）。标尺用"分格 = 列"的几何对齐把归属关系直接
   * 画出来，读数本身就成了一条明确的模式提示。
   *
   * 配色用**与主题相反**的反色（亮色主题黑底亮字 / 暗色主题白底暗字，见
   * `AppColors.columnRatioBarBg`）：正面配色会淹没在页面底色里，反色才跳得出来。
   *
   * **必须是短暂显示**：它压在标题栏正下方，而各列内容的第一行正好从这里开始
   * （主题列表的排序条就在这一段），常驻会盖住它。显示时机见 `onColumnRatioModeChanged`
   * 与 `scheduleReadoutBarHide`。
   *
   * 纯展示：`HitTestMode.None` 让点击与滚动穿透到下方列。
   */
  @Builder
  ColumnRatioBar() {
    Row() {
      this.RatioBarCell(SLOT_SIDEBAR)
      this.RatioBarCell(SLOT_BOARD)
      this.RatioBarCell(SLOT_ACTIVITY)
    }
    .width('100%')
    .height(COLUMN_READOUT_BAR_H)
    // 压在标题栏（状态栏 + NAV_BAR_H）正下方，不遮返回键与标题
    .position({ x: 0, y: this.statusBarHeight + NAV_BAR_H })
    .backgroundColor(AppColors.columnRatioBarBg)
    .shadow({ radius: 6, color: AppColors.shadowLight, offsetX: 0, offsetY: 2 })
    .hitTestBehavior(HitTestMode.None)
    // 出现/消失自带动画：`animation()` 已配参数，属"直接增删组件"式自播，无需 animateTo 包裹
    .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
  }

  /**
   * 标尺的单个分格（一列读数）。
   *
   * 拖动中与把手相邻的两格**再反一次色**（亮底暗字），把"正在改哪两列"直接标出来；
   * 这两格的右侧分隔线同时隐藏，视觉上并成一块"正在调整的区域"。
   * `slot` 是按值传入的**编译期字面量**（`SLOT_*`），不参与响应式依赖；宽度 / 文案 / 高亮
   * 一律由 `this` 上的方法读取状态，符合「@Builder 按值传参不建立响应式依赖」的约定
   * （见 entry/src/AGENTS.md）。
   */
  @Builder
  RatioBarCell(slot: number) {
    if (this.slotWidth(slot) > 0) {
      Row() {
        Text(this.slotReadout(slot))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.slotResizing(slot)
            ? AppColors.columnRatioBarActiveText
            : AppColors.columnRatioBarText)
          .maxLines(1)
          // 兜底：极窄列（内容区放不下两条最小列宽时的退化区间）下读数可能放不下，
          // 省略号比静默裁切更容易被读懂
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width(this.slotWidth(slot))
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.slotResizing(slot)
        ? AppColors.columnRatioBarActiveBg
        : Color.Transparent)
      .border({
        width: { right: 0.5 },
        color: this.slotResizing(slot) ? Color.Transparent : AppColors.columnRatioBarDivider
      })
    }
  }

  /**
   * 该分格是否正被拖动改变宽度（用于标尺高亮）：高亮与当前把手相邻的两列。
   */
  private slotResizing(slot: number): boolean {
    if (this.draggingHandle === HANDLE_SIDEBAR) {
      return slot === SLOT_SIDEBAR || slot === this.firstContentSlot()
    }
    if (this.draggingHandle === HANDLE_BOARD) {
      return slot === SLOT_BOARD || slot === SLOT_ACTIVITY
    }
    return false
  }

  /** 第一个可见的内容列槽位（板块列隐藏时是活动列）。 */
  private firstContentSlot(): number {
    return this.slotWidth(SLOT_BOARD) > 0 ? SLOT_BOARD : SLOT_ACTIVITY
  }

  /**
   * 列交接拖动把手。
   *
   * 命中区（`COLUMN_HANDLE_HIT_W` = 20vp ≈ 3.2mm）比可见握柄（4vp）宽得多，但仍小于平台
   * 建议的 40vp：横向精度要求 ±10vp，靠**纵向贯穿全高**补偿（手指落在交接线附近任意高度
   * 都能拖）。这是"好拖"与"少挡内容"之间的折中。
   *
   * 握柄复用标尺的反色 token（亮色主题黑 / 暗色主题白）：把手是标尺的落点，同色系才能被
   * 认成"同一件事的两半"，也保证压在任意列表内容上都够显眼；拖动中换成 primary，给出触点的
   * 即时反馈（标尺那两格另有反色高亮）。**耦合提示**：该 token 语义是"标尺底色"，若将来把
   * 标尺底色改成带 alpha，必须给握柄单开一个不透明资源，否则握柄会跟着变半透明。
   *
   * 命中策略是默认的 `HitTestMode.Default`（**挡住**这条 20vp 竖条下方的列表）：
   * 换取"拖把手绝不会误触发列表滚动或点开帖子"。改成 `Transparent` 能让竖条下方的列表
   * 继续响应纵向滚动，代价是贴着交接线的点击会穿透到帖子条目上 —— 对一个显式的拖动控件
   * 来说，可预期性比那 20vp 的滚动连续性更重要（何况这只在占比模式下短暂存在）。
   *
   * `slot` 同 `RatioBarCell`，是编译期字面量。
   */
  @Builder
  ColumnHandle(slot: number) {
    if (this.handleVisible(slot)) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(COLUMN_HANDLE_GRIP_W)
          .height(COLUMN_HANDLE_GRIP_H)
          .borderRadius(COLUMN_HANDLE_GRIP_W / 2)
          .backgroundColor(this.draggingHandle === slot
            ? AppColors.primary
            : AppColors.columnRatioBarBg)
      }
      .width(COLUMN_HANDLE_HIT_W)
      .height('100%')
      .position({ x: this.handleX(slot) - COLUMN_HANDLE_HIT_W / 2, y: 0 })
      // 与读数标尺同步淡入淡出：否则激活模式时标尺淡入、把手硬闪
      .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
      .gesture(
        PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 2 })
          .onActionStart((): void => { this.beginHandleDrag(slot) })
          .onActionUpdate((event: GestureEvent): void => {
            this.updateHandleDrag(slot, event.offsetX)
          })
          .onActionEnd((): void => { this.endHandleDrag(slot) })
          .onActionCancel((): void => { this.endHandleDrag(slot) })
      )
    }
  }

  // ============== 认证 ==============

  private async checkAuth(): Promise<void> {
    if (!appStore.auth.isAuthenticated) {
      try { this.getUIContext().getRouter().replaceUrl({ url: 'pages/LoginPage' }) } catch (e) { logger.error('route failed: %{public}s', (e as Error).message) }
      return
    }

    const valid = await verifyToken(appStore.auth.token)
    if (!valid) {
      appStore.clearAuth()
      try { this.getUIContext().getRouter().replaceUrl({ url: 'pages/LoginPage' }) } catch (e) { logger.error('route failed: %{public}s', (e as Error).message) }
      return
    }

    const cached = appStore.getCachedProfile(appStore.auth.uid)
    if (cached) {
      appStore.auth.nickName = cached.userName
      appStore.auth.avatarUrl = cached.avatarUrl
    }

    appStore.ensureProfile(appStore.auth.uid)
    appStore.settingsStore.ensureFavorites()
    appStore.autoCheckinIfNeeded()
  }
}
