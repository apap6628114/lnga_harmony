/**
 * 通用代际令牌 — 使过时的异步回调失效。
 *
 * 用于"异步请求发起后环境可能已变化"的场景：请求发起前调用 {@link bump}
 * 捕获当前代际，回调恢复后用 {@link isCurrent} 比对——代际已推进说明
 * 期间发生了使旧请求失效的事件（重置、新请求取代等），应放弃执行。
 *
 * 约定：
 * - 统一采用 bump 语义（永不归零），避免"捕获 0 后重置归 0 → 0 === 0 误判有效"的边界缺陷；
 * - 三段式用法：`const token = guard.bump()` → `await ...` → `if (!guard.isCurrent(token)) return`。
 */
export class GenerationGuard {
  /** 当前代际值，每次 bump 自增。 */
  private generation: number = 0

  /**
   * 推进代际并返回新值。发起新异步会话（或执行重置）前调用，
   * 使此前捕获的所有代际令牌全部失效。
   *
   * @returns 新的代际值
   */
  bump(): number {
    this.generation++
    return this.generation
  }

  /**
   * 获取当前代际值。用于发起请求前的只读快照（如预取前一并携带代际）。
   *
   * @returns 当前代际值
   */
  current(): number {
    return this.generation
  }

  /**
   * 判断捕获的代际是否仍为当前代际。
   *
   * @param captured - 请求发起时捕获的代际值
   * @returns true 表示期间未发生代际推进，回调仍可安全执行
   */
  isCurrent(captured: number): boolean {
    return captured === this.generation
  }
}
