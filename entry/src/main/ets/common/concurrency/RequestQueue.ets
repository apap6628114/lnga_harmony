/**
 * 固定并发上限的请求调度队列。
 *
 * 封装「活跃计数 + 等待队列」调度模板：调用方通过 {@link schedule} 入队任务，
 * 当活跃数低于上限时立即执行，否则排队等待；任务结束后调用 {@link done}
 * 释放槽位并唤醒队首等待者。
 *
 * 与 {@link Throttler}（令牌桶，按 domain 分桶 + 最小时间间隔限流）职责不同：
 * RequestQueue 用于固定并发探测（如视频尺寸预取），无 domain 维度、无时间间隔约束。
 *
 * 注意：本队列**只做固定并发调度，不做请求去重**。对同一目标重复 schedule 会得到
 * 多个独立执行；若需要去重（如同一 URL 的尺寸探测只发一次），必须由调用方自行用
 * pending Map 在入队前拦截（参见 VideoSizeUtil）。
 */
export class RequestQueue {
  /** 并发上限 */
  private maxConcurrent: number;
  /** 当前活跃任务数 */
  private activeCount: number = 0;
  /** 等待执行的任务队列 */
  private requestQueue: Array<() => void> = new Array<() => void>();

  /**
   * 构造并发队列。
   *
   * @param maxConcurrent - 允许的最大并发任务数
   */
  constructor(maxConcurrent: number) {
    this.maxConcurrent = maxConcurrent;
  }

  /**
   * 入队一个任务。若当前活跃数低于上限则立即执行，否则排队等待。
   *
   * @param run - 实际要执行的任务（箭头函数）
   */
  schedule(run: () => void): void {
    if (this.activeCount < this.maxConcurrent) {
      this.activeCount++;
      run();
    } else {
      this.requestQueue.push(run);
    }
  }

  /**
   * 标记一个任务完成：活跃数减一，并尽可能唤醒队首等待者。
   *
   * 必须在 {@link schedule} 投递的任务结束时（无论成功/失败）调用一次，
   * 以保证后续排队任务得以执行。
   */
  done(): void {
    this.activeCount--;
    while (this.requestQueue.length > 0 && this.activeCount < this.maxConcurrent) {
      const next: (() => void) | undefined = this.requestQueue.shift();
      if (next) {
        this.activeCount++;
        next();
      }
    }
  }
}
