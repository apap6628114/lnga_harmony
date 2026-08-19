/**
 * 保存帖子进度状态发布器。
 *
 * 保存多页帖子时，逐页拉取由 SavedThreadService 驱动，进度经本管理器发布，
 * 指示组件通过轮询读取状态（与 TtsProgress 相同的解耦方式）。
 */

/**
 * 全局保存帖子进度状态，由 SavedThreadService 发布、进度指示组件轮询读取。
 */
export class SavedThreadProgressState {
  /** 是否正在保存帖子。 */
  visible: boolean = false
  /** 0~100 的进度百分比。 */
  percent: number = -1
  /** 当前进度文案（如「第 3/50 页」）。 */
  label: string = ''
}

/**
 * 管理全局保存帖子进度的发布。
 */
export class SavedThreadProgressManager {
  readonly state: SavedThreadProgressState = new SavedThreadProgressState()

  /**
   * 发布保存进度。
   *
   * @param percent 0~100 的估算进度
   * @param label 当前进度文案
   */
  show(percent: number, label: string): void {
    this.state.percent = Math.max(0, Math.min(100, Math.round(percent)))
    this.state.label = label
    this.state.visible = true
  }

  /**
   * 隐藏保存进度指示。
   */
  hide(): void {
    this.state.visible = false
    this.state.percent = -1
    this.state.label = ''
  }
}

/** 全局保存帖子进度发布器单例。 */
export const savedThreadProgress: SavedThreadProgressManager = new SavedThreadProgressManager()
