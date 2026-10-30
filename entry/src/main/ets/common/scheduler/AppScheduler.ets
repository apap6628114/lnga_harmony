/**
 * 应用内调度器（AppScheduler）— 纯逻辑编排层。
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §7.3 与
 * `docs/research/SCHEDULER_RESEARCH.md` §3。核心职责是把"何时跑"从各 Store 内部
 * 定时器 / Ability 生命周期里收敛到一处：
 *
 * 1. 任务注册：`register(task)` 一次性登记（重复 id 拒绝）；
 * 2. 事件入口：`notify(trigger)` 匹配任务并按注册顺序**串行**执行（同一次派发内
 *    await 每个任务，避免回前台请求风暴叠加——这是调度调研发现的核心问题）；
 * 3. 用户入口：`requestRun(id, force)` 立即执行（绕过节流 / 退避 / 延迟）；
 * 4. 心跳：`start()` 后每 60s 派发一次 `TICK`，**仅前台**（后台保留心跳但不派发）；
 * 5. 状态：`snapshot()` 返回全部任务状态快照（数据管理页 / 诊断日志）。
 *
 * 统一契约（与现有实现语义对齐，见调研文档 §3.2）：
 * - 单飞：同一任务在途时再次触发直接忽略并累加 `coalesced`；
 * - 节流：`now - lastRunAt < minIntervalMs` 跳过，且跳过不更新 `lastRunAt`；
 * - 退避：失败后 `nextAllowedAt = now + retryDelaysMs[失败序号]`，成功清零；
 * - 门禁：`foregroundOnly && !foreground`、`requiresAuth && !authenticated`、
 *   STARTUP 早于 `setStartupComplete` 均跳过；
 * - 异常隔离：任务体抛错只影响自己（记 FAILED + 截断错误），不影响同批其它任务；
 * - 后台守则：`foregroundOnly` 默认 true，后台不跑网络任务（调研结论 R-1）。
 *
 * 设计约束：
 * - **不 import AppStore / service / 网络**，全部依赖通过 probe 注入，避免循环依赖；
 * - 时钟、前台探针、认证探针、定时器均可注入（`bindClock` / `bindForegroundProbe` /
 *   `bindAuthProbe` / `bindTimers`），保证单测确定性、不依赖真实时间。
 *
 * 生命周期语义：
 * - `start()` 幂等；`notify()` 在 `start()` 之前或 `stop()` 之后**不执行任务**；
 * - `stop()` 只停心跳与派发，不清任务表；再次 `start()` 可恢复；
 * - `requestRun()` 不受 `start/stop` 限制（用户显式动作），仅受 `shutdown()` 约束；
 * - `shutdown()` 清理全部定时器（心跳 + `startDelayMs` 待执行项），之后不再接受任何执行。
 */

import { Logger, DOMAIN_APP, formatError } from '../utils/Logger'
import {
  ScheduledTask,
  SchedulerContext,
  SchedulerTrigger,
  TaskOutcome,
  TaskStatus
} from './SchedulerTypes'

/** 心跳间隔（毫秒）：前台每 60s 派发一次 TICK。 */
export const HEARTBEAT_INTERVAL_MS: number = 60 * 1000

/** `lastError` 最大长度（字符）：异常信息只保留摘要，避免状态快照膨胀。 */
export const MAX_ERROR_LENGTH: number = 200

/** 定时器句柄（与全局 setTimeout 返回值一致，便于测试注入）。 */
export type SchedulerTimerId = number

/** 定时器调度函数（默认实现走全局 setTimeout）。 */
export type SchedulerSetTimer = (callback: () => void, delayMs: number) => SchedulerTimerId

/** 定时器取消函数（默认实现走全局 clearTimeout）。 */
export type SchedulerClearTimer = (timerId: SchedulerTimerId) => void

const logger: Logger = new Logger(DOMAIN_APP, 'AppScheduler')

/**
 * 任务注册项：任务定义 + 可变运行状态。
 *
 * 调度器内部模型，不对外暴露；外部只看到 `TaskStatus` 快照。
 */
class TaskEntry {
  /** 任务定义（注册后不再修改）。 */
  readonly task: ScheduledTask
  /** 运行状态（唯一可变真源）。 */
  readonly status: TaskStatus = new TaskStatus()
  /** 是否已实际执行过（用于首次执行的节流判定，避免时钟 0 与初始值冲突）。 */
  hasRun: boolean = false
  /** `startDelayMs` 是否已用掉（只对首次命中生效）。 */
  startDelayUsed: boolean = false
  /** `startDelayMs` 待执行的定时器句柄（-1 = 无）。 */
  startDelayTimer: number = -1
  /** 触发延迟执行的那次触发源（延迟到期后作为 ctx.trigger）。 */
  pendingDelayTrigger: SchedulerTrigger = SchedulerTrigger.TICK

  /**
   * 构造注册项。
   *
   * @param task - 任务定义
   */
  constructor(task: ScheduledTask) {
    this.task = task
    this.status.id = task.id
  }
}

/**
 * 应用内调度器。
 *
 * 单实例由 `AppStore` 持有并注入依赖；本类不持有任何全局状态，可直接 `new` 用于测试。
 */
export class AppScheduler {
  /** 注册表（注册顺序即同一次派发内的执行顺序）。 */
  private entries: TaskEntry[] = []
  /** 时钟注入（默认 Date.now）。 */
  private clock: () => number = (): number => Date.now()
  /** 前台探针（默认 false：未接线时一律视为后台，避免误跑前台任务）。 */
  private foregroundProbe: () => boolean = (): boolean => false
  /** 认证探针（默认 false：未接线时 requiresAuth 任务一律跳过）。 */
  private authProbe: () => boolean = (): boolean => false
  /** 定时器注入（默认全局 setTimeout）。 */
  private setTimer: SchedulerSetTimer =
    (callback: () => void, delayMs: number): number => setTimeout(callback, delayMs)
  /** 定时器取消注入（默认全局 clearTimeout）。 */
  private clearTimer: SchedulerClearTimer = (timerId: number): void => { clearTimeout(timerId) }
  /** 心跳间隔（毫秒；测试可注入更短值）。 */
  private heartbeatIntervalMs: number = HEARTBEAT_INTERVAL_MS
  /** 心跳定时器句柄（-1 = 未运行）。 */
  private heartbeatTimer: number = -1
  /** 是否已启动（`start` 之后、`stop` 之前为 true）。 */
  private started: boolean = false
  /** 是否已销毁（`shutdown` 之后不再接受任何执行）。 */
  private disposed: boolean = false
  /** STARTUP 门禁：`setStartupComplete` 之前 STARTUP 触发一律跳过。 */
  private startupComplete: boolean = false
  /** 在途派发计数（`whenIdle` 等待用）。 */
  private pendingDispatchCount: number = 0
  /** 等待"全部派发结束"的唤醒回调。 */
  private idleWaiters: (() => void)[] = []

  /**
   * 注册一个任务。
   *
   * 重复 id 拒绝并告警（不抛错：注册失败不应中断启动流程）；空 id 同样拒绝。
   *
   * @param task - 任务定义
   */
  register(task: ScheduledTask): void {
    if (this.disposed) {
      logger.warn('register ignored: scheduler disposed')
      return
    }
    if (task.id.length === 0) {
      logger.warn('register rejected: empty task id')
      return
    }
    if (this.entryById(task.id) !== undefined) {
      logger.warn('register rejected: duplicate task id %{public}s', task.id)
      return
    }
    const entry: TaskEntry = new TaskEntry(task)
    this.entries.push(entry)
    logger.verbose('registered task %{public}s (triggers=%{public}d, minInterval=%{public}dms)',
      task.id, task.triggers.length, task.minIntervalMs)
  }

  /**
   * 启动调度器：开启 60s 心跳（仅前台派发 TICK）。
   *
   * 幂等；`shutdown()` 之后调用无效。
   */
  start(): void {
    if (this.disposed) {
      logger.warn('start ignored: scheduler disposed')
      return
    }
    if (this.started) {
      return
    }
    this.started = true
    this.scheduleHeartbeat()
    logger.info('started (heartbeat=%{public}dms, tasks=%{public}d)', this.heartbeatIntervalMs, this.entries.length)
  }

  /**
   * 停止调度器：停心跳并阻止后续 `notify` 执行任务（不清任务表）。
   *
   * 幂等；`start()` 可再次恢复。
   */
  stop(): void {
    if (!this.started) {
      return
    }
    this.started = false
    this.clearHeartbeat()
    logger.info('stopped')
  }

  /**
   * 销毁调度器：清理全部定时器（心跳 + `startDelayMs` 待执行项）。
   *
   * 之后 `register` / `start` / `notify` / `requestRun` 均不再执行任务；幂等。
   */
  shutdown(): void {
    if (this.disposed) {
      return
    }
    this.disposed = true
    this.started = false
    this.clearHeartbeat()
    for (let i = 0; i < this.entries.length; i++) {
      const entry: TaskEntry = this.entries[i]
      if (entry.startDelayTimer >= 0) {
        this.clearTimer(entry.startDelayTimer)
        entry.startDelayTimer = -1
      }
    }
    logger.info('shutdown')
  }

  /**
   * 事件入口：异步派发匹配该触发源的任务（不阻塞调用方）。
   *
   * 同一次派发内按注册顺序串行 `await` 每个任务，避免并发请求叠加；
   * 未 `start()` 或已 `stop()` / `shutdown()` 时直接忽略。
   *
   * @param trigger - 触发源
   */
  notify(trigger: SchedulerTrigger): void {
    if (!this.started || this.disposed) {
      return
    }
    const dispatch: Promise<void> = this.dispatch(trigger)
    this.trackDispatch(dispatch)
  }

  /**
   * 用户主动执行指定任务（按钮 / 下拉刷新 / 立即重试）。
   *
   * `force` 为 true 时绕过节流、退避窗口与 `startDelayMs`（门禁仍生效）；
   * 任务在途时按单飞语义跳过并累加 `coalesced`；未知 id 返回 SKIPPED。
   *
   * @param id - 任务 ID
   * @param force - 是否强制（忽略节流 / 退避 / 延迟）
   * @returns 本次执行结果
   */
  async requestRun(id: string, force: boolean): Promise<TaskOutcome> {
    if (this.disposed) {
      return TaskOutcome.SKIPPED
    }
    const entry: TaskEntry | undefined = this.entryById(id)
    if (entry === undefined) {
      logger.warn('requestRun ignored: unknown task %{public}s', id)
      return TaskOutcome.SKIPPED
    }
    return await this.executeEntry(entry, SchedulerTrigger.USER, force)
  }

  /**
   * 全部任务状态快照（注册顺序；返回的是副本，外部修改不影响内部状态）。
   *
   * @returns 任务状态数组
   */
  snapshot(): TaskStatus[] {
    const result: TaskStatus[] = []
    for (let i = 0; i < this.entries.length; i++) {
      result.push(this.copyStatus(this.entries[i].status))
    }
    return result
  }

  /**
   * 注入时钟（测试用；生产默认 Date.now）。
   *
   * @param clock - 返回当前毫秒时间戳的函数
   */
  bindClock(clock: () => number): void {
    this.clock = clock
  }

  /**
   * 注入前台探针（生产接 `appStore.foregroundActive`；未注入时视为后台）。
   *
   * @param probe - 返回当前是否前台的函数
   */
  bindForegroundProbe(probe: () => boolean): void {
    this.foregroundProbe = probe
  }

  /**
   * 注入认证探针（生产接 `appStore.auth.isAuthenticated`；未注入时视为未登录）。
   *
   * @param probe - 返回当前是否已登录的函数
   */
  bindAuthProbe(probe: () => boolean): void {
    this.authProbe = probe
  }

  /**
   * 标记 STARTUP 门禁已解除（AppStore.init / 持久化加载完成后调用）。
   *
   * 解除前 `notify(STARTUP)` 对全部任务返回 SKIPPED；解除后需由调用方再次 `notify`。
   */
  setStartupComplete(): void {
    this.startupComplete = true
  }

  /**
   * 注入定时器实现（测试用；生产默认全局 setTimeout / clearTimeout）。
   *
   * 必须在 `start()` 之前注入，否则已排的心跳仍用旧实现。
   *
   * @param setTimer - 定时器调度函数
   * @param clearTimer - 定时器取消函数
   */
  bindTimers(setTimer: SchedulerSetTimer, clearTimer: SchedulerClearTimer): void {
    this.setTimer = setTimer
    this.clearTimer = clearTimer
  }

  /**
   * 注入心跳间隔（测试用；生产默认 60s，见 `HEARTBEAT_INTERVAL_MS`）。
   *
   * @param intervalMs - 心跳间隔毫秒数（必须为正数）
   */
  bindHeartbeatIntervalMs(intervalMs: number): void {
    if (!isFinite(intervalMs) || intervalMs <= 0) {
      return
    }
    this.heartbeatIntervalMs = Math.floor(intervalMs)
    if (this.started) {
      this.clearHeartbeat()
      this.scheduleHeartbeat()
    }
  }

  /**
   * 等待当前全部在途派发结束（测试 / 收尾用）。
   *
   * `notify` 本身不阻塞调用方；需要确认"这一轮触发的任务都跑完了"时 await 本方法。
   *
   * @returns 无在途派发时 resolve
   */
  whenIdle(): Promise<void> {
    if (this.pendingDispatchCount <= 0) {
      return Promise.resolve()
    }
    return new Promise<void>((resolve: () => void): void => {
      this.idleWaiters.push(resolve)
    })
  }

  /**
   * 匹配触发源并串行执行。
   *
   * @param trigger - 触发源
   * @returns 派发完成时 resolve
   */
  private async dispatch(trigger: SchedulerTrigger): Promise<void> {
    const count: number = this.entries.length
    for (let i = 0; i < count; i++) {
      if (!this.started || this.disposed) {
        return
      }
      const entry: TaskEntry = this.entries[i]
      if (!this.matches(entry.task, trigger)) {
        continue
      }
      await this.executeEntry(entry, trigger, false)
    }
  }

  /**
   * 执行单个任务（门禁 → 节流 → 退避 → 延迟 → 任务体 → 状态落地）。
   *
   * @param entry - 任务注册项
   * @param trigger - 触发源
   * @param force - 是否强制（绕过节流 / 退避 / 延迟）
   * @returns 本次结果
   */
  private async executeEntry(entry: TaskEntry, trigger: SchedulerTrigger, force: boolean): Promise<TaskOutcome> {
    if (this.disposed) {
      return TaskOutcome.SKIPPED
    }
    const task: ScheduledTask = entry.task
    const status: TaskStatus = entry.status

    if (trigger === SchedulerTrigger.STARTUP && !this.startupComplete) {
      status.lastOutcome = TaskOutcome.SKIPPED
      return TaskOutcome.SKIPPED
    }
    if (status.running) {
      status.coalesced += 1
      return TaskOutcome.SKIPPED
    }
    if (entry.startDelayTimer >= 0) {
      if (!force) {
        status.coalesced += 1
        return TaskOutcome.SKIPPED
      }
      this.clearTimer(entry.startDelayTimer)
      entry.startDelayTimer = -1
    }
    if (task.foregroundOnly && !this.foregroundProbe()) {
      status.lastOutcome = TaskOutcome.SKIPPED
      return TaskOutcome.SKIPPED
    }
    if (task.requiresAuth && !this.authProbe()) {
      status.lastOutcome = TaskOutcome.SKIPPED
      return TaskOutcome.SKIPPED
    }
    const now: number = this.clock()
    if (!force && now < status.nextAllowedAt) {
      status.lastOutcome = TaskOutcome.SKIPPED
      return TaskOutcome.SKIPPED
    }
    if (!force && status.failureCount === 0 && task.minIntervalMs > 0 && entry.hasRun &&
      now - status.lastRunAt < task.minIntervalMs) {
      status.lastOutcome = TaskOutcome.SKIPPED
      return TaskOutcome.SKIPPED
    }
    if (!force && trigger !== SchedulerTrigger.USER && !entry.startDelayUsed && task.startDelayMs > 0) {
      entry.startDelayUsed = true
      entry.pendingDelayTrigger = trigger
      entry.startDelayTimer = this.setTimer((): void => {
        this.onStartDelayElapsed(entry)
      }, task.startDelayMs)
      return TaskOutcome.SKIPPED
    }
    entry.startDelayUsed = true
    status.running = true
    const context: SchedulerContext = new SchedulerContext()
    context.foreground = this.foregroundProbe()
    context.trigger = trigger
    context.now = now
    let outcome: TaskOutcome = TaskOutcome.FAILED
    try {
      outcome = await task.run(context)
    } catch (e) {
      outcome = TaskOutcome.FAILED
      status.lastError = this.truncateError(formatError(e))
    }
    status.running = false
    const finishedAt: number = this.clock()
    entry.hasRun = true
    status.lastRunAt = finishedAt
    status.lastOutcome = outcome
    if (outcome === TaskOutcome.FAILED) {
      status.failureCount += 1
      const delays: number[] = task.retryDelaysMs
      if (delays.length > 0) {
        const index: number = Math.min(status.failureCount - 1, delays.length - 1)
        status.nextAllowedAt = finishedAt + delays[index]
      } else {
        status.nextAllowedAt = 0
      }
      logger.warn('task failed: id=%{public}s trigger=%{public}s failures=%{public}d error=%{public}s',
        task.id, trigger, status.failureCount, status.lastError)
    } else if (outcome === TaskOutcome.OK) {
      status.failureCount = 0
      status.nextAllowedAt = 0
      status.lastError = ''
      logger.verbose('task ok: id=%{public}s trigger=%{public}s cost=%{public}dms coalesced=%{public}d',
        task.id, trigger, finishedAt - now, status.coalesced)
    } else {
      logger.verbose('task skipped by body: id=%{public}s trigger=%{public}s', task.id, trigger)
    }
    return outcome
  }

  /**
   * `startDelayMs` 到期回调：补一次实际执行（状态/门禁在 executeEntry 内重新判定）。
   *
   * @param entry - 任务注册项
   */
  private onStartDelayElapsed(entry: TaskEntry): void {
    entry.startDelayTimer = -1
    if (!this.started || this.disposed) {
      return
    }
    const trigger: SchedulerTrigger = entry.pendingDelayTrigger
    const execution: Promise<void> = this.executeEntry(entry, trigger, false).then((): void => {})
    this.trackDispatch(execution)
  }

  /**
   * 调度下一次心跳。
   */
  private scheduleHeartbeat(): void {
    if (!this.started || this.heartbeatTimer >= 0) {
      return
    }
    this.heartbeatTimer = this.setTimer((): void => {
      this.onHeartbeat()
    }, this.heartbeatIntervalMs)
  }

  /**
   * 心跳回调：仅前台派发 TICK，随后无条件续排（后台保留心跳但不派发）。
   */
  private onHeartbeat(): void {
    this.heartbeatTimer = -1
    if (!this.started || this.disposed) {
      return
    }
    if (this.foregroundProbe()) {
      this.notify(SchedulerTrigger.TICK)
    }
    this.scheduleHeartbeat()
  }

  /**
   * 清理心跳定时器。
   */
  private clearHeartbeat(): void {
    if (this.heartbeatTimer >= 0) {
      this.clearTimer(this.heartbeatTimer)
      this.heartbeatTimer = -1
    }
  }

  /**
   * 跟踪一个在途派发（供 `whenIdle` 等待）。
   *
   * @param dispatch - 派发 Promise
   */
  private trackDispatch(dispatch: Promise<void>): void {
    this.pendingDispatchCount += 1
    const finish: () => void = (): void => {
      this.pendingDispatchCount -= 1
      if (this.pendingDispatchCount <= 0) {
        this.pendingDispatchCount = 0
        const waiters: (() => void)[] = this.idleWaiters
        this.idleWaiters = []
        for (let i = 0; i < waiters.length; i++) {
          waiters[i]()
        }
      }
    }
    dispatch.then((): void => {
      finish()
    }).catch((): void => {
      finish()
    })
  }

  /**
   * 任务是否声明了该触发源。
   *
   * @param task - 任务定义
   * @param trigger - 触发源
   * @returns 是否匹配
   */
  private matches(task: ScheduledTask, trigger: SchedulerTrigger): boolean {
    return task.triggers.indexOf(trigger) >= 0
  }

  /**
   * 按 ID 查找注册项。
   *
   * @param id - 任务 ID
   * @returns 注册项；不存在时为 undefined
   */
  private entryById(id: string): TaskEntry | undefined {
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].task.id === id) {
        return this.entries[i]
      }
    }
    return undefined
  }

  /**
   * 复制状态（避免 `snapshot()` 暴露内部可变对象）。
   *
   * @param source - 内部状态
   * @returns 新状态实例
   */
  private copyStatus(source: TaskStatus): TaskStatus {
    const target: TaskStatus = new TaskStatus()
    target.id = source.id
    target.lastRunAt = source.lastRunAt
    target.lastOutcome = source.lastOutcome
    target.failureCount = source.failureCount
    target.nextAllowedAt = source.nextAllowedAt
    target.coalesced = source.coalesced
    target.running = source.running
    target.lastError = source.lastError
    return target
  }

  /**
   * 截断错误信息（最多 `MAX_ERROR_LENGTH` 字符）。
   *
   * @param message - 原始错误描述
   * @returns 截断后的描述
   */
  private truncateError(message: string): string {
    if (message.length <= MAX_ERROR_LENGTH) {
      return message
    }
    return message.substring(0, MAX_ERROR_LENGTH)
  }
}
