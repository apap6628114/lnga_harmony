/**
 * 楼层定位进度状态发布器（与 TtsProgress 同模式）。
 *
 * pid→页码二分查找由入口层（回帖列表/链接）发起，入口页面可能随时切换，
 * 因此进度状态放在全局单例中发布，由页面根部挂载的指示组件轮询读取，
 * 与 TtsProgressIndicator 保持一致的驱动方式，不依赖具体入口页面。
 *
 * 接管语义：多个入口（TopicListPanel 实例、LinkUtils）共享同一全局单例，
 * 通过 begin() 分配全局代际解决归属——只有当前代际的 show/hide 才生效，
 * 过期查找的进度回调与 hide 均不会污染或误伤最新一次的显示。
 *
 * 步数语义：locatePidPage 的 onProgress(done, total) 直接透传——
 * 末页请求完成后 total 即确定（1 + ⌈log₂总页数⌉），total≤1 表示步数未知。
 */

/**
 * 全局楼层定位进度状态，由入口层发布、指示组件轮询读取。
 */
export class PidLocateProgressState {
  /** 是否正在定位楼层。 */
  visible: boolean = false
  /** 已完成请求步数。 */
  step: number = 0
  /** 总步数；小于等于 1 表示未知（仅展示纯文案）。 */
  total: number = 0
}

/**
 * 管理全局楼层定位进度的发布。
 */
export class PidLocateProgressManager {
  readonly state: PidLocateProgressState = new PidLocateProgressState()
  /** 全局接管代际：每次 begin() 递增，过期查找的 show/hide 均被忽略。 */
  private currentGeneration: number = 0

  /**
   * 发起一次定位查找并接管全局指示器。
   *
   * 之后的 show/hide 均须携带本方法返回的代际；任何新的 begin() 都会使
   * 旧代际失效，从而保证连点/跨入口时指示器只反映最新一次查找。
   *
   * @returns 本次查找的全局代际
   */
  begin(): number {
    this.currentGeneration++
    this.state.step = 0
    this.state.total = 0
    this.state.visible = true
    return this.currentGeneration
  }

  /**
   * 发布定位进度；仅当前代际生效，过期查找的回调被忽略。
   *
   * @param generation - begin() 返回的代际
   * @param step - 已完成请求步数
   * @param total - 总步数；小于等于 1 时 UI 仅展示「正在定位楼层…」
   */
  show(generation: number, step: number, total: number): void {
    if (generation !== this.currentGeneration) {
      return
    }
    this.state.step = step
    this.state.total = total
    this.state.visible = true
  }

  /**
   * 隐藏定位进度指示；仅当前代际生效，过期查找的 hide 不误伤新接管者。
   *
   * @param generation - begin() 返回的代际
   */
  hide(generation: number): void {
    if (generation !== this.currentGeneration) {
      return
    }
    this.state.visible = false
    this.state.step = 0
    this.state.total = 0
  }
}

/** 全局楼层定位进度发布器单例。 */
export const pidLocateProgress: PidLocateProgressManager = new PidLocateProgressManager()
