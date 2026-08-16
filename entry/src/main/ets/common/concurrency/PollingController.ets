/**
 * 前台轮询调度器 — 统一「立即执行一次 + 定时重复」的轮询骨架。
 *
 * 社交类 Store（NotificationStore / FollowActivityStore）共用同一套调度语义：
 * - start()：幂等启动（已启用时直接返回），立即触发一次 onPoll，再按 interval 定时重复；
 * - stop()：幂等停止，清理定时器；停止后不再触发任何回调；
 * - 调度保证同一时刻至多一个待触发定时器（timer 置 -1 后才允许重新调度），
 *   与既有各 Store 的 scheduleNextPoll 行为完全一致。
 *
 * onPoll 由调用方注入（通常为「执行一次普通刷新」），start/stop 的认证门禁
 * 由调用方在调用前自行完成。
 */

/**
 * 判断社交轮询是否满足前台运行条件。
 *
 * @param foregroundActive - Ability 是否处于前台
 * @param initialized - AppStore 是否初始化完成
 * @param authenticated - 当前账号是否已认证
 * @returns 是否应启用前台轮询
 */
export function shouldEnablePolling(
  foregroundActive: boolean,
  initialized: boolean,
  authenticated: boolean
): boolean {
  return foregroundActive && initialized && authenticated
}

export class PollingController {
  /** 待触发定时器句柄（-1 = 无待触发）。 */
  private timer: number = -1
  /** 是否允许继续调度前台轮询。 */
  private enabled: boolean = false
  /** 轮询间隔（毫秒）。 */
  private readonly intervalMs: number
  /** 每次轮询触发的动作（start 时立即执行一次，之后按间隔重复）。 */
  private readonly onPoll: () => void

  /**
   * 构造轮询调度器。
   *
   * @param intervalMs - 轮询间隔（毫秒）
   * @param onPoll - 轮询动作；start() 会先立即执行一次，再按间隔重复
   */
  constructor(intervalMs: number, onPoll: () => void) {
    this.intervalMs = intervalMs
    this.onPoll = onPoll
  }

  /**
   * 启动前台轮询：立即执行一次 onPoll，并调度后续定时刷新。
   * 幂等：已启用时直接返回，不会重复调度或重复立即刷新。
   * 即使 onPoll 同步抛异常，也会保证下一次调度被安排（异常仍向调用方传播），
   * 避免「enabled 恒 true 但 timer 恒 -1」的不可自愈死状态。
   */
  start(): void {
    if (this.enabled) {
      return
    }
    this.enabled = true
    try {
      this.onPoll()
    } finally {
      this.scheduleNext()
    }
  }

  /**
   * 停止前台轮询：清理定时器并禁止后续调度（幂等）。
   */
  stop(): void {
    this.enabled = false
    if (this.timer >= 0) {
      clearTimeout(this.timer)
      this.timer = -1
    }
  }

  /**
   * 调度下一次轮询；已停止或有待触发定时器时不再重复调度。
   */
  private scheduleNext(): void {
    if (!this.enabled || this.timer >= 0) {
      return
    }
    this.timer = setTimeout((): void => {
      this.timer = -1
      if (!this.enabled) {
        return
      }
      try {
        this.onPoll()
      } finally {
        this.scheduleNext()
      }
    }, this.intervalMs)
  }
}
