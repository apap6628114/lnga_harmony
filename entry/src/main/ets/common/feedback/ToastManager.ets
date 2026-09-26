/**
 * Toast 消息提示状态管理（系统弹窗层承载）
 *
 * ## 架构（层级问题见 {@link ToastOverlay} 文件头）
 *
 * - 内容节点：`PromptAction.openCustomDialog` + `ComponentContent`，落在浮层树的 **Dialog 层**，
 *   与 `bindSheet`（回复编辑器）的 `SheetMode.OVERLAY` **同层**（SDK 对该 mode 的注释原文：
 *   "displayed at the same level as dialog boxes"），不再被压在页面树之下。
 *   注意 `LevelOrder.clamp(100000)` 只对**参与 levelOrder 排序的弹窗**有意义——
 *   `bindSheet` / `bindContentCover` 没有该字段，同层内先后顺序官方未明确，属待实测项
 *   （见 `docs/UI_COMPONENT_MIGRATION.md` §7.9）。
 * - 非模态：`isModal: false`（官方默认 `true`，不关会带可见蒙层）。
 *   **注意事件透传不由它决定**：官方 `maskRect` 的语义是"遮蔽层区域内的事件不透传、区域外透传"，
 *   而其默认值是整屏——不显式收紧 `maskRect`，Toast 显示期间全屏点击都会被吞掉（已实测）。
 *   详见 `openImpl` 里的参数注释。
 *
 * ## 节点生命周期（严格遵守官方释放时机，勿自行发明）
 *
 * - **每次展示新建**一个 `ComponentContent`，并且**永不复用**：官方没有给"关闭后再 open 同一
 *   节点"任何保证（FAQ 明确 dialog 关闭**不**触发内部组件树的 `aboutToDisappear`，即组件树不重建），
 *   复用会让内容刷新语义不可靠。这条是硬约束，改动前请先读 `onOpenFailed` 的说明。
 * - **释放时机**：官方指南给的写法是
 *   `closeCustomDialog(content).then(() => { content.dispose() })` —— 在关闭完成回调里释放，
 *   既不提前（避开关闭动画），也不靠定时器猜。本文件照此实现（见 {@link releaseAfterClose}）。
 *
 * ## 与旧实现的差别
 *
 * 旧实现把内容挂在 MainPage 根 Stack（页面树）并靠 150ms 定时轮询 `@Observed` 状态驱动，
 * 既有层级遮挡问题，也有最多 150ms 的显示延迟。现在由系统在展示时回调构建函数，
 * 无轮询、无延迟。
 *
 * ## 未注入 UIContext 时
 *
 * `ComponentContent` 必须由 UI 上下文创建。页面加载完成前（`EntryAbility` 尚未回调
 * `attachUIContext`）产生的提示会暂存最后一条，注入后补播——与旧实现"后来的覆盖先前的"
 * 语义一致（旧实现在 page 未就绪时的表现同样只剩最后一条，因为状态是单例）。
 */

// DialogAlignment 是 ArkUI 全局声明（component/alert_dialog.d.ts 的 `declare enum`），
// 无需 import，也不能从 @kit.ArkUI 导入（该 Kit 未导出它）。
import { ComponentContent } from '@kit.ArkUI'
import { LevelOrder } from '@ohos.promptAction'
import { UIContext } from '@ohos.arkui.UIContext'
import { toastOverlayHooks, ToastOverlayParam, toastOverlayWrappedBuilder } from './ToastOverlay'
import { KEY_NAV_BAR_HEIGHT } from '../constants/AppStorageKeys'
import { TOAST_BOTTOM_MARGIN } from '../constants/Constants'
import { DOMAIN_UI, formatError, Logger } from '../utils/Logger'

const logger = new Logger(DOMAIN_UI, 'ToastManager')

/**
 * Toast 展示状态快照。
 *
 * 迁移到系统浮层后已无组件直接订阅它（旧 `ToastComponent` 的轮询消费者已删除），
 * 保留是为了给需要查询当前提示内容的调用方留一个只读入口。
 */
@Observed
export class ToastState {
  message: string = ''
  visible: boolean = false
  /** 动作按钮文案；为空表示纯文本 Toast。 */
  actionText: string = ''
  /** 动作按钮点击回调；点击后立即隐藏并清空，防止重复触发。 */
  onAction: (() => void) | null = null
}

export class ToastManager {
  state: ToastState = new ToastState()

  /** 纯文本 Toast 的展示时长。 */
  private readonly plainDurationMs: number = 2500
  /** 带动作按钮 Toast 的展示时长（回复成功场景给用户留出点击窗口）。 */
  private readonly actionDurationMs: number = 4000
  /** 打开失败（系统侧弹窗尚未释放）后的重试间隔。 */
  private readonly openRetryDelayMs: number = 120
  /**
   * 「打开被系统拒绝」时节点的延迟释放时长。
   *
   * 未成功打开 = 系统从未接管该节点，没有关闭动画需要等；延迟只为兜住"reject 与内部清理
   * 之间存在极短的在途状态"这一可能，与已打开节点的释放路径（`closeCustomDialog().then()`）无关。
   */
  private readonly unopenedDisposeDelayMs: number = 300

  /** 由 `EntryAbility` 注入；为 null 表示页面尚未加载完成。 */
  private uiContext: UIContext | null = null
  /** 页面未就绪时暂存的最后一条提示，注入 UI 上下文后补播。 */
  private pendingToast: ToastOverlayParam | null = null

  /** 当前正在展示的节点；为 null 表示没有活着的节点。 */
  private content: ComponentContent<ToastOverlayParam> | null = null
  private isOpen: boolean = false
  /**
   * 展示序号：每次 `show` 递增。
   *
   * 用于让**异步回调认领自己那一次展示**——打开失败后的重试定时器、以及"打开在途时被顶掉"
   * 的清理，都必须校验序号，否则会把后续新提示的节点或文案误当成自己的（复活旧文案 /
   * 误释放新节点）。
   */
  private showToken: number = 0
  private timer: number = -1
  /** 打开失败后的重试定时器句柄；关闭时一并取消，避免跨生命周期的悬挂回调。 */
  private retryTimer: number = -1

  // ---------- 生命周期 ----------

  /**
   * 注入 UI 上下文（`EntryAbility` 在 `loadContent` 回调中调用）。
   *
   * 幂等：重复注入只更新引用；若有暂存提示则立即补播。
   */
  attachUIContext(uiContext: UIContext): void {
    this.uiContext = uiContext
    const pending: ToastOverlayParam | null = this.pendingToast
    if (pending !== null) {
      this.pendingToast = null
      // 重放走 showImpl 而非直接 open：底部边距等取值在展示时重新计算，
      // 且打开失败仍能进入既有的重试路径。
      const pendingAction: (() => void) | null = this.state.onAction
      this.showImpl(pending.message, pending.actionText, pendingAction, pending.durationMs)
    }
  }

  // ---------- 展示 ----------

  show(msg: string): void {
    this.showImpl(msg, '', null, this.plainDurationMs)
  }

  /**
   * 展示带动作按钮的 Toast。
   *
   * @param msg - 主文案
   * @param actionText - 按钮文案（如「前往查看」）
   * @param onAction - 点击回调；回调可能晚于 Toast 消失触发，闭包内不得依赖已销毁的组件实例
   */
  showAction(msg: string, actionText: string, onAction: () => void): void {
    this.showImpl(msg, actionText, onAction, this.actionDurationMs)
  }

  /**
   * 立即隐藏并清空动作回调（动作按钮点击后调用，防重复触发）。
   *
   * 顺带停掉展示计时器：否则点击后计时器仍会到期并走一遍无意义的关闭流程。
   */
  hideAction(): void {
    this.closeToast()
    this.state.onAction = null
  }

  // ---------- 内部实现 ----------

  private showImpl(msg: string, actionText: string, onAction: (() => void) | null, durationMs: number): void {
    // 先认领序号：本次展示的所有异步回调都以它为准
    this.showToken += 1
    const token: number = this.showToken

    this.state.message = msg
    this.state.actionText = actionText
    this.state.onAction = onAction

    const param: ToastOverlayParam =
      new ToastOverlayParam(msg, actionText, durationMs, this.resolveBottomMargin())

    if (this.uiContext === null) {
      // 页面加载完成前：暂存最后一条，注入后补播
      this.pendingToast = param
      logger.warn('UI context 未就绪，暂存 Toast：%{public}s', msg)
      return
    }

    this.openImpl(param, false, token)
  }

  /**
   * 计算 Toast 距屏幕底部的最终边距。
   *
   * **必须在 manager（普通上下文）里读 AppStorage，不能放到浮层组件内**：浮层构建在
   * `ComponentContent`（BuilderNode 体系）里，实测 `@StorageProp` 在其中不生效
   * （`navBarHeight` 恒为 0），会让 Toast 比旧实现整体下沉一个导航条高度。
   *
   * 键名写死字面量是遵循本工程约定（`@StorageProp` 装饰器参数须为编译期字面量，
   * `AppStorageKeys` 的常量与该字面量是手工对齐关系），写入方是 `EntryAbility.updateSafeArea`。
   */
  private resolveBottomMargin(): number {
    const navBarHeight: number = AppStorage.get<number>(KEY_NAV_BAR_HEIGHT) ?? 0
    return TOAST_BOTTOM_MARGIN + navBarHeight
  }

  /** 打开节点并登记本次展示的行为钩子与计时器；首次失败时重建重试一次。 */
  private openImpl(param: ToastOverlayParam, isRetry: boolean, token: number): void {
    // 行为钩子按"每次展示"覆盖：重试会重建节点，回调闭包必须是最新的。
    // 挂到模块级钩子而不是 ComponentContent 参数，是因为 ArkTS 的 @Prop 不承接函数成员
    //（官方《@Prop装饰器》支持类型表不含 Function）。
    toastOverlayHooks.onAction = this.state.onAction
    toastOverlayHooks.onTimeout = (): void => { this.onTimeout() }

    // 上一轮的节点若仍标记为打开（例如系统自行关闭过），先关闭；
    // 它会在 closeCustomDialog 的回调里释放，不能在这里直接 dispose。
    if (this.isOpen) {
      this.closeToast()
    }

    const uiContext: UIContext = this.uiContext as UIContext
    const content: ComponentContent<ToastOverlayParam> =
      new ComponentContent(uiContext, toastOverlayWrappedBuilder, param)
    this.content = content
    this.isOpen = true
    this.state.visible = true
    this.restartTimer(param.durationMs)

    try {
      // 未注册 `onWillDismiss`：本弹窗对返回键/侧滑/ESC 的响应官方未明确（非模态场景无说明），
      // 若系统据此自行关闭，manager 侧不会收到回调 —— 下次 show 会走「先关闭再重建」，
      // 那条路径已能容忍"节点其实已不存在"（closeCustomDialog 的 catch 分支照常释放）。
      // 测出返回键确实会关掉 Toast 后，可改为注册 onWillDismiss 自行决定是否关闭。
      uiContext.getPromptAction().openCustomDialog(content, {
        isModal: false,
        autoCancel: false,
        // 不抢焦点：Toast 是纯反馈，不应扰动下层的输入焦点与软键盘（API 19+，默认 true）。
        focusable: false,
        // 位置交给系统：底部对齐 + 向上偏移。**不要改用"全屏 Stack + margin"自算位置**——
        // dialog 对内容节点的约束与页面树不同，margin 不生效，Toast 会紧贴屏幕底边。
        alignment: DialogAlignment.Bottom,
        offset: { dx: 0, dy: -param.bottomOffset },
        // ★ 事件透传的真正开关。官方对 `maskRect` 的定义是"**遮蔽层区域内的事件不透传，
        //   在遮蔽层区域外的事件透传**"，而它的默认值是 `{x:0, y:0, width:'100%', height:'100%'}`
        //   ——即整屏都吃事件。`isModal: false` 只保证"无蒙层、可与周围控件交互"，
        //   **并不能**把默认的全屏遮蔽层变成透传；不显式收紧 `maskRect`，Toast 显示期间
        //   全屏点击都会被吞掉（实测现象："触控被吃了"）。
        //   这里收到 0 尺寸：整屏事件透传，命中行为回到"只由气泡自身的 hitTestBehavior 决定"
        //   （带动作按钮 Block 独占、纯文本 Transparent 穿透），与旧实现语义一致。
        maskRect: { x: 0, y: 0, width: 0, height: 0 },
        // 未注册 `onWillDismiss`：本弹窗对返回键/侧滑/ESC 的响应官方未明确（非模态场景无说明），
        // 若系统据此自行关闭，manager 侧不会收到回调 —— 下次 show 会走「先关闭再重建」，
        // 那条路径已能容忍"节点其实已不存在"（closeCustomDialog 的 catch 分支照常释放）。
        // 取「参与 levelOrder 排序的弹窗」这一集合内的最大 order（官方范围 [-100000, 100000]，
        // 默认 clamp(0)）。**注意边界**：`bindSheet` / `bindContentCover` 没有 levelOrder 字段
        // （SheetOptions / ContentCoverOptions / BindOptions 均无），所以本参数对它们无约束力——
        // 它们的层级由 `SheetOptions.mode`（默认 SheetMode.OVERLAY，官方注释：
        // "displayed at the same level as dialog boxes"）决定。
        levelOrder: LevelOrder.clamp(100000)
      }).catch((err: Object): void => {
        this.onOpenFailed(param, isRetry, token, err)
      })
    } catch (e) {
      // 同步抛出：回滚状态并释放节点，异常不再冒泡打断业务调用方
      this.content = null
      this.isOpen = false
      this.releaseUnopenedContent(content)
      this.resetState()
      logger.warn('创建/打开 Toast 浮层异常: %{public}s', formatError(e))
    }
  }

  /**
   * 打开失败处理。
   *
   * 已知失败场景：系统侧弹窗状态尚未完全释放时又调用了 open（错误码 103302
   * "Dialog content already exist"；103301 为内容错误）。可恢复——重建一个全新节点再打开即可，
   * 且重试对用户不可见（仍在展示时长内）。
   *
   * **不要改成复用 `ComponentContent`**（例如用 `update()` 换文案后重新 open）：官方没有给
   * "关闭后再 open 同一节点"任何保证，且 FAQ 明确 dialog 关闭不触发内部组件树的
   * `aboutToDisappear`（组件树不重建），复用会让内容与生命周期语义都不可靠。
   */
  private onOpenFailed(param: ToastOverlayParam, isRetry: boolean, token: number, err: Object): void {
    const failed: ComponentContent<ToastOverlayParam> | null = this.content
    if (failed === null) {
      // 已被后续展示接管（或已释放）：交给那条路径处理
      return
    }
    this.content = null
    this.isOpen = false
    this.releaseUnopenedContent(failed)
    logger.warn('打开 Toast 浮层失败%s: %{public}s', isRetry ? '（不再重试）' : '', formatError(err))

    if (isRetry) {
      // 重试用尽：本次展示彻底失败，状态不能留在"正在显示"上
      this.resetState()
      return
    }

    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1
      // 序号不符说明期间已有新提示——放弃重试，绝不复活旧文案
      if (token !== this.showToken) {
        return
      }
      // 已有节点在展示：同样放弃
      if (this.isOpen || this.content !== null) {
        return
      }
      this.openImpl(param, true, token)
    }, this.openRetryDelayMs)
  }

  /** 超时（由浮层回调）：关闭节点，节点在关闭完成回调里释放。 */
  private onTimeout(): void {
    this.closeToast()
  }

  /** 关闭节点（幂等）。节点释放交给 `closeCustomDialog` 的完成回调，不在这里 dispose。 */
  private closeToast(): void {
    this.resetState()
    if (!this.isOpen) {
      return
    }
    this.isOpen = false
    const content: ComponentContent<ToastOverlayParam> | null = this.content
    this.content = null
    if (content === null) {
      return
    }
    const uiContext: UIContext | null = this.uiContext
    if (uiContext === null) {
      // 理论不可达（没有 UIContext 就不会有已打开节点）；兜底直接释放，避免泄漏
      this.releaseUnopenedContent(content)
      return
    }
    uiContext.getPromptAction().closeCustomDialog(content)
      .then((): void => {
        this.releaseAfterClose(content)
      })
      .catch((err: Object): void => {
        // 系统可能已自行关闭（如页面隐藏）：此时找不到节点属正常，但仍需释放
        logger.warn('关闭 Toast 浮层失败: %{public}s', formatError(err))
        this.releaseAfterClose(content)
      })
  }

  /** 清状态与展示计时器，不动节点（节点关闭走 {@link closeToast}）。 */
  private resetState(): void {
    clearTimeout(this.timer)
    clearTimeout(this.retryTimer)
    this.retryTimer = -1
    this.state.visible = false
    this.state.message = ''
    this.state.actionText = ''
    this.state.onAction = null
  }

  /** 释放一个**已关闭**的节点：官方释放时机（`closeCustomDialog().then()`）。 */
  private releaseAfterClose(content: ComponentContent<ToastOverlayParam>): void {
    try {
      content.dispose()
    } catch (e) {
      logger.warn('释放 Toast 浮层失败: %{public}s', formatError(e))
    }
  }

  /** 释放一个**从未打开成功**的节点（系统未接管，无需等待关闭动画）。 */
  private releaseUnopenedContent(content: ComponentContent<ToastOverlayParam>): void {
    setTimeout((): void => {
      this.releaseAfterClose(content)
    }, this.unopenedDisposeDelayMs)
  }

  private restartTimer(durationMs: number): void {
    clearTimeout(this.timer)
    this.timer = setTimeout((): void => {
      this.onTimeout()
    }, durationMs)
  }
}
