/**
 * 「智能去水」进度状态发布器。
 *
 * 去水是**全帖跨页任务**（用户要求帖子有多少页就抓多少页），上百页以上的帖子
 * 会跑几十分钟，且用户完全可以离开帖子页去别处。因此进度**不做页内浮层**，
 * 而是与 `savedThreadProgress`（离线保存）同样的解耦方式：服务发布 → 全局
 * 指示组件（挂在 `MainPage`）轮询读取。
 *
 * 与保存进度分开维护而非复用同一个发布器：两条任务可能同时在不同设置下运行，
 * 各自需要独立的取消入口与阶段文案；共用一份状态会让「取消」按错对象。
 */

/**
 * 去水任务的阶段。
 */
export enum WaterFilterPhase {
  /** 逐页抓取并判定。 */
  FETCHING = 'fetching',
  /** 整理楼层并写入本地存档。 */
  PACKING = 'packing'
}

/**
 * 全局去水进度状态，由去水服务发布、进度指示组件轮询读取。
 */
export class WaterFilterProgressState {
  /** 是否正在执行去水任务。 */
  visible: boolean = false
  /** 0~100 的进度百分比；-1 表示未知（不定进度）。 */
  percent: number = -1
  /** 当前阶段。 */
  phase: string = WaterFilterPhase.FETCHING
  /** 当前进度文案（如「第 312/823 页 · 已去 1892 层」）。 */
  label: string = ''
  /** 剩余时间估算文案（无估算时为空串）。 */
  hint: string = ''
}

/**
 * 管理全局去水进度的发布。
 */
export class WaterFilterProgressManager {
  readonly state: WaterFilterProgressState = new WaterFilterProgressState()

  /**
   * 发布去水进度。
   *
   * @param percent - 0~100 的估算进度（-1 表示未知）
   * @param label - 当前进度文案
   * @param hint - 剩余时间估算（可为空串）
   * @param phase - 当前阶段
   */
  show(percent: number, label: string, hint: string = '',
    phase: string = WaterFilterPhase.FETCHING): void {
    this.state.percent = percent < 0 ? -1 : Math.max(0, Math.min(100, Math.round(percent)))
    this.state.label = label
    this.state.hint = hint
    this.state.phase = phase
    this.state.visible = true
  }

  /**
   * 隐藏去水进度指示。
   */
  hide(): void {
    this.state.visible = false
    this.state.percent = -1
    this.state.label = ''
    this.state.hint = ''
  }
}

/** 全局去水进度发布器单例。 */
export const waterFilterProgress: WaterFilterProgressManager = new WaterFilterProgressManager()
