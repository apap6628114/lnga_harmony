/**
 * Toast 消息提示状态管理
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
  private timer: number = -1

  /** 纯文本 Toast 的展示时长。 */
  private readonly plainDurationMs: number = 2500
  /** 带动作按钮 Toast 的展示时长（回复成功场景给用户留出点击窗口）。 */
  private readonly actionDurationMs: number = 4000

  show(msg: string): void {
    this.showImpl(msg, '', null, this.plainDurationMs)
  }

  /**
   * 展示带动作按钮的 Toast。
   *
   * @param msg - 主文案
   * @param actionText - 按钮文案（如「前往查看」）
   * @param onAction - 点击回调；回调在 Toast 隐藏后仍持有引用，闭包内不得依赖组件实例
   */
  showAction(msg: string, actionText: string, onAction: () => void): void {
    this.showImpl(msg, actionText, onAction, this.actionDurationMs)
  }

  /**
   * 立即隐藏并清空动作回调（动作按钮点击后调用，防重复触发）。
   */
  hideAction(): void {
    clearTimeout(this.timer)
    this.state.visible = false
    this.state.message = ''
    this.state.actionText = ''
    this.state.onAction = null
  }

  private showImpl(msg: string, actionText: string, onAction: (() => void) | null, durationMs: number): void {
    clearTimeout(this.timer)
    this.state.message = msg
    this.state.actionText = actionText
    this.state.onAction = onAction
    this.state.visible = true
    this.timer = setTimeout(() => {
      this.state.visible = false
      this.state.message = ''
      this.state.actionText = ''
      this.state.onAction = null
    }, durationMs)
  }
}
