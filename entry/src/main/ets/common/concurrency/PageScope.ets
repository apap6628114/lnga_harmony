/**
 * 页面/组件存活令牌 — aboutToAppear/aboutToDisappear 驱动。
 *
 * 同时承载两层语义（与异步回调可信环境检查的"页面存活 + 请求新鲜度"两维对应）：
 * - 存活标志：页面销毁后 {@link isAlive} 为 false，定时器/监听回调应停止一切操作；
 * - 代际计数：每次 {@link begin} 都推进代际，新请求自动使旧请求的已捕获令牌失效。
 *
 * 用法（struct 中作普通 private 字段，勿挂 @State，参照 `private scroller` 惯例）：
 * - aboutToAppear → `this.scope.begin()`（返回本次会话代际）
 * - aboutToDisappear → `this.scope.end()`
 * - 异步回调恢复 → `if (!this.scope.isActive(captured)) return`
 * - 无代际语义的定时器回调 → `if (!this.scope.isAlive()) return`
 */
export class PageScope {
  /** 页面/组件是否仍存活。 */
  private alive: boolean = false
  /** 会话代际值，每次 begin 自增。 */
  private generation: number = 0

  /**
   * 页面出现时调用：置存活并推进代际，使旧会话令牌失效。
   *
   * @returns 本次出现会话的代际值，供异步回调捕获
   */
  begin(): number {
    this.alive = true
    this.generation++
    return this.generation
  }

  /**
   * 页面消失时调用：置死并使所有已捕获代际失效。
   * 此后任何异步回调（含已排队的定时器）都不应再更新页面状态。
   */
  end(): void {
    this.alive = false
    this.generation++
  }

  /**
   * 仅存活检查。适用于无代际语义的定时器/事件回调（未捕获令牌、仅需确认页面还在）。
   *
   * @returns 页面/组件是否仍存活
   */
  isAlive(): boolean {
    return this.alive
  }

  /**
   * 校验捕获代际是否仍可安全更新页面状态。
   * 页面存活 且 期间未被新会话/页面销毁推进代际。
   *
   * @param captured - begin() 捕获的会话代际
   * @returns true 表示回调仍有效
   */
  isActive(captured: number): boolean {
    return this.alive && captured === this.generation
  }
}
