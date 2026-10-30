/**
 * 应用内调度器（AppScheduler）单元测试。
 *
 * 覆盖 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §7.3 的调度器契约与
 * `docs/research/SCHEDULER_RESEARCH.md` §3.2 的公共契约：
 * 单飞 / 节流 / 退避 / 前台门禁 / 认证门禁 / STARTUP 门禁 / 异常隔离 /
 * 触发匹配与串行 / startDelayMs / 心跳 / start-stop 语义 / 用户强制 / 状态快照。
 *
 * 测试不依赖真实时间：时钟、前台探针、认证探针、定时器全部注入 fake 实现，
 * 定时任务通过 `FakeTimer.advance` 手动推进。注册入口：
 * `List.test.ets` 中 `import schedulerUnitTest from './SchedulerUnit.test'` 后调用
 * `schedulerUnitTest()`。
 */

import { describe, expect, it } from '@ohos/hypium'
import {
  AppScheduler,
  MAX_ERROR_LENGTH,
  SchedulerClearTimer,
  SchedulerSetTimer
} from '../main/ets/common/scheduler/AppScheduler'
import {
  ScheduledTask,
  SchedulerContext,
  SchedulerTrigger,
  TaskOutcome,
  TaskStatus
} from '../main/ets/common/scheduler/SchedulerTypes'

/** 假定时器中的待执行项。 */
class FakeTimerEntry {
  /** 定时器句柄。 */
  id: number = 0
  /** 到期时刻（毫秒）。 */
  dueAt: number = 0
  /** 到期回调。 */
  callback: () => void = (): void => {}
}

/**
 * 手动推进的假定时器。
 *
 * 只实现调度器用到的 `setTimeout` / `clearTimeout` 语义，`advance` 按到期时间
 * 顺序同步执行回调（回调内新排的定时器也会被同一轮 advance 消化）。
 */
class FakeTimer {
  /** 当前假时间（毫秒）。 */
  now: number = 0
  /** 下一个定时器句柄。 */
  private nextId: number = 1
  /** 待执行项。 */
  private entries: FakeTimerEntry[] = []
  /** 注入调度器的调度函数。 */
  readonly setTimer: SchedulerSetTimer = (callback: () => void, delayMs: number): number => {
    const entry: FakeTimerEntry = new FakeTimerEntry()
    entry.id = this.nextId
    entry.dueAt = this.now + delayMs
    entry.callback = callback
    this.nextId += 1
    this.entries.push(entry)
    return entry.id
  }
  /** 注入调度器的取消函数。 */
  readonly clearTimer: SchedulerClearTimer = (timerId: number): void => {
    const kept: FakeTimerEntry[] = []
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].id !== timerId) {
        kept.push(this.entries[i])
      }
    }
    this.entries = kept
  }

  /**
   * 待执行定时器数量。
   *
   * @returns 待执行项个数
   */
  pendingCount(): number {
    return this.entries.length
  }

  /**
   * 推进假时间并执行期间到期的全部回调。
   *
   * @param ms - 推进的毫秒数
   */
  advance(ms: number): void {
    const target: number = this.now + ms
    let guard: number = 0
    while (guard < 10000) {
      guard += 1
      let next: FakeTimerEntry | null = null
      for (let i = 0; i < this.entries.length; i++) {
        const candidate: FakeTimerEntry = this.entries[i]
        if (candidate.dueAt > target) {
          continue
        }
        if (next === null || candidate.dueAt < next.dueAt ||
          (candidate.dueAt === next.dueAt && candidate.id < next.id)) {
          next = candidate
        }
      }
      if (next === null) {
        break
      }
      this.clearTimer(next.id)
      if (next.dueAt > this.now) {
        this.now = next.dueAt
      }
      next.callback()
    }
    this.now = target
  }
}

/** 前台 / 认证探针的测试状态。 */
class Probes {
  /** 是否前台。 */
  foreground: boolean = true
  /** 是否已登录。 */
  authenticated: boolean = false
}

/** 执行顺序记录（多个任务共享，用于验证串行与注册顺序）。 */
class OrderLog {
  /** 按执行先后记录的标签。 */
  entries: string[] = []
}

/**
 * 任务体执行记录器。
 *
 * 用固定返回值 / 指定序列 / 抛错 / 挂起四种模式覆盖不同任务形态。
 */
class RunRecorder {
  /** 执行次数。 */
  calls: number = 0
  /** 每次执行的触发源。 */
  triggers: SchedulerTrigger[] = []
  /** 当前并发数（用于验证串行）。 */
  concurrency: number = 0
  /** 观测到的最大并发数。 */
  maxConcurrency: number = 0
  /** 默认返回值。 */
  outcome: TaskOutcome = TaskOutcome.OK
  /** 按顺序消费的返回值序列（优先于 outcome）。 */
  outcomes: TaskOutcome[] = []
  /** 非空时任务体抛错（内容为异常消息）。 */
  throwMessage: string = ''
  /** 返回前让出一次微任务（放大并发窗口，验证串行）。 */
  yieldBeforeReturn: boolean = false
  /** 执行顺序标签。 */
  label: string = ''
  /** 共享执行顺序记录。 */
  orderLog: OrderLog | null = null
  /** 挂起执行的 Promise。 */
  private held: Promise<TaskOutcome> | null = null
  /** 挂起释放函数。 */
  private releaseHeld: ((value: TaskOutcome) => void) | null = null

  /**
   * 置为挂起模式：下一次执行会等到 {@link release} 才返回。
   */
  createHold(): void {
    this.held = new Promise<TaskOutcome>((resolve: (value: TaskOutcome) => void): void => {
      this.releaseHeld = resolve
    })
  }

  /**
   * 释放挂起的执行。
   *
   * @param value - 任务体返回值
   */
  release(value: TaskOutcome): void {
    if (this.releaseHeld !== null) {
      const resolve: (value: TaskOutcome) => void = this.releaseHeld
      this.releaseHeld = null
      resolve(value)
    }
  }

  /**
   * 任务体实现。
   *
   * @param ctx - 调度上下文
   * @returns 执行结果
   */
  async execute(ctx: SchedulerContext): Promise<TaskOutcome> {
    this.calls += 1
    this.triggers.push(ctx.trigger)
    if (this.orderLog !== null) {
      this.orderLog.entries.push(this.label)
    }
    this.concurrency += 1
    if (this.concurrency > this.maxConcurrency) {
      this.maxConcurrency = this.concurrency
    }
    try {
      if (this.throwMessage.length > 0) {
        throw new Error(this.throwMessage)
      }
      if (this.yieldBeforeReturn) {
        await Promise.resolve()
      }
      if (this.outcomes.length > 0) {
        const next: TaskOutcome = this.outcomes[0]
        this.outcomes = this.outcomes.slice(1)
        return next
      }
      const pending: Promise<TaskOutcome> | null = this.held
      if (pending !== null) {
        return await pending
      }
      return this.outcome
    } finally {
      this.concurrency -= 1
    }
  }
}

/**
 * 测试装配：把 fake 时钟 / 探针 / 定时器注入调度器。
 *
 * 默认已完成 STARTUP 门禁且未启动（需要心跳的用例自行 `start()`）。
 */
class Harness {
  /** 假定时器（同时充当假时钟）。 */
  readonly timer: FakeTimer = new FakeTimer()
  /** 探针状态。 */
  readonly probes: Probes = new Probes()
  /** 被测调度器。 */
  readonly scheduler: AppScheduler = new AppScheduler()

  /**
   * 装配依赖。
   *
   * @param startupComplete - 是否预先解除 STARTUP 门禁
   */
  constructor(startupComplete: boolean = true) {
    this.scheduler.bindClock((): number => this.timer.now)
    this.scheduler.bindForegroundProbe((): boolean => this.probes.foreground)
    this.scheduler.bindAuthProbe((): boolean => this.probes.authenticated)
    this.scheduler.bindTimers(this.timer.setTimer, this.timer.clearTimer)
    if (startupComplete) {
      this.scheduler.setStartupComplete()
    }
  }

  /**
   * 启动调度器。
   */
  start(): void {
    this.scheduler.start()
  }

  /**
   * 通知触发源并等待本轮派发结束。
   *
   * @param trigger - 触发源
   */
  async notifyAndWait(trigger: SchedulerTrigger): Promise<void> {
    this.scheduler.notify(trigger)
    await this.scheduler.whenIdle()
  }

  /**
   * 推进假时间并等待派发结束。
   *
   * @param ms - 推进的毫秒数
   */
  async advanceAndWait(ms: number): Promise<void> {
    this.timer.advance(ms)
    await this.scheduler.whenIdle()
  }

  /**
   * 读取指定下标任务状态。
   *
   * @param index - 注册顺序下标
   * @returns 状态副本
   */
  statusAt(index: number): TaskStatus {
    return this.scheduler.snapshot()[index]
  }
}

/**
 * 构造任务（任务体委托给记录器）。
 *
 * @param id - 任务 ID
 * @param triggers - 触发源集合
 * @param recorder - 执行记录器
 * @returns 任务定义
 */
function makeTask(id: string, triggers: SchedulerTrigger[], recorder: RunRecorder): ScheduledTask {
  const task: ScheduledTask = new ScheduledTask()
  task.id = id
  task.triggers = triggers
  task.run = async (ctx: SchedulerContext): Promise<TaskOutcome> => {
    return await recorder.execute(ctx)
  }
  return task
}

/**
 * 重复字符构造长字符串（验证错误截断）。
 *
 * @param char - 单字符
 * @param count - 重复次数
 * @returns 构造结果
 */
function repeatChar(char: string, count: number): string {
  let text: string = ''
  for (let i = 0; i < count; i++) {
    text += char
  }
  return text
}

/**
 * 注册调度器单元测试。
 */
export default function schedulerUnitTest(): void {
  describe('appScheduler', (): void => {
    it('coalescesTriggerWhileTaskIsRunning', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      const recorder: RunRecorder = new RunRecorder()
      recorder.createHold()
      harness.scheduler.register(makeTask('poll.a', [SchedulerTrigger.TICK], recorder))
      harness.start()

      harness.scheduler.notify(SchedulerTrigger.TICK)
      harness.scheduler.notify(SchedulerTrigger.TICK)

      expect(recorder.calls).assertEqual(1)
      expect(harness.statusAt(0).coalesced).assertEqual(1)
      expect(harness.statusAt(0).running).assertTrue()

      recorder.release(TaskOutcome.OK)
      await harness.scheduler.whenIdle()

      expect(recorder.calls).assertEqual(1)
      expect(harness.statusAt(0).running).assertFalse()
      expect(harness.statusAt(0).lastOutcome).assertEqual(TaskOutcome.OK)
    })

    it('skipsWithinMinIntervalAndKeepsLastRunAt', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      harness.timer.now = 1000
      const recorder: RunRecorder = new RunRecorder()
      const task: ScheduledTask = makeTask('poll.b', [SchedulerTrigger.TICK], recorder)
      task.minIntervalMs = 5000
      harness.scheduler.register(task)
      harness.start()

      await harness.notifyAndWait(SchedulerTrigger.TICK)
      expect(recorder.calls).assertEqual(1)
      expect(harness.statusAt(0).lastRunAt).assertEqual(1000)

      harness.timer.now = 3000
      await harness.notifyAndWait(SchedulerTrigger.TICK)
      expect(recorder.calls).assertEqual(1)
      expect(harness.statusAt(0).lastOutcome).assertEqual(TaskOutcome.SKIPPED)
      expect(harness.statusAt(0).lastRunAt).assertEqual(1000)

      harness.timer.now = 6000
      await harness.notifyAndWait(SchedulerTrigger.TICK)
      expect(recorder.calls).assertEqual(2)
      expect(harness.statusAt(0).lastRunAt).assertEqual(6000)
    })

    it('backsOffAfterFailureAndResetsOnSuccess', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      harness.timer.now = 1000
      const recorder: RunRecorder = new RunRecorder()
      recorder.outcomes = [TaskOutcome.FAILED, TaskOutcome.OK]
      const task: ScheduledTask = makeTask('auth.verify', [SchedulerTrigger.TICK], recorder)
      task.retryDelaysMs = [100, 300]
      harness.scheduler.register(task)
      harness.start()

      await harness.notifyAndWait(SchedulerTrigger.TICK)
      expect(recorder.calls).assertEqual(1)
      expect(harness.statusAt(0).lastOutcome).assertEqual(TaskOutcome.FAILED)
      expect(harness.statusAt(0).failureCount).assertEqual(1)
      expect(harness.statusAt(0).nextAllowedAt).assertEqual(1100)

      harness.timer.now = 1050
      await harness.notifyAndWait(SchedulerTrigger.TICK)
      expect(recorder.calls).assertEqual(1)
      expect(harness.statusAt(0).lastOutcome).assertEqual(TaskOutcome.SKIPPED)

      harness.timer.now = 1100
      await harness.notifyAndWait(SchedulerTrigger.TICK)
      expect(recorder.calls).assertEqual(2)
      expect(harness.statusAt(0).lastOutcome).assertEqual(TaskOutcome.OK)
      expect(harness.statusAt(0).failureCount).assertEqual(0)
      expect(harness.statusAt(0).nextAllowedAt).assertEqual(0)
    })

    it('capsBackoffAtLastDelayForConsecutiveFailures', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      harness.timer.now = 1000
      const recorder: RunRecorder = new RunRecorder()
      recorder.outcome = TaskOutcome.FAILED
      const task: ScheduledTask = makeTask('tracked.check', [SchedulerTrigger.TICK], recorder)
      task.retryDelaysMs = [100, 300]
      harness.scheduler.register(task)
      harness.start()

      await harness.notifyAndWait(SchedulerTrigger.TICK)
      expect(harness.statusAt(0).failureCount).assertEqual(1)
      expect(harness.statusAt(0).nextAllowedAt).assertEqual(1100)

      harness.timer.now = 1100
      await harness.notifyAndWait(SchedulerTrigger.TICK)
      expect(harness.statusAt(0).failureCount).assertEqual(2)
      expect(harness.statusAt(0).nextAllowedAt).assertEqual(1400)

      harness.timer.now = 1400
      await harness.notifyAndWait(SchedulerTrigger.TICK)
      expect(harness.statusAt(0).failureCount).assertEqual(3)
      expect(harness.statusAt(0).nextAllowedAt).assertEqual(1700)
    })

    it('skipsForegroundOnlyTaskWhenBackgrounded', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      harness.probes.foreground = false
      const recorder: RunRecorder = new RunRecorder()
      harness.scheduler.register(makeTask('notifications.poll', [SchedulerTrigger.TICK], recorder))
      harness.start()

      await harness.notifyAndWait(SchedulerTrigger.TICK)
      expect(recorder.calls).assertEqual(0)
      expect(harness.statusAt(0).lastOutcome).assertEqual(TaskOutcome.SKIPPED)
      expect(harness.statusAt(0).lastRunAt).assertEqual(0)

      harness.probes.foreground = true
      await harness.notifyAndWait(SchedulerTrigger.TICK)
      expect(recorder.calls).assertEqual(1)
    })

    it('skipsAuthRequiredTaskWhenLoggedOut', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      const recorder: RunRecorder = new RunRecorder()
      const task: ScheduledTask = makeTask('checkin.auto', [SchedulerTrigger.FOREGROUND], recorder)
      task.requiresAuth = true
      harness.scheduler.register(task)
      harness.start()

      await harness.notifyAndWait(SchedulerTrigger.FOREGROUND)
      expect(recorder.calls).assertEqual(0)
      expect(harness.statusAt(0).lastOutcome).assertEqual(TaskOutcome.SKIPPED)

      harness.probes.authenticated = true
      await harness.notifyAndWait(SchedulerTrigger.FOREGROUND)
      expect(recorder.calls).assertEqual(1)
    })

    it('skipsStartupTriggerBeforeStartupComplete', 0, async (): Promise<void> => {
      const harness: Harness = new Harness(false)
      const recorder: RunRecorder = new RunRecorder()
      harness.scheduler.register(makeTask('draft.cleanup', [SchedulerTrigger.STARTUP], recorder))
      harness.start()

      await harness.notifyAndWait(SchedulerTrigger.STARTUP)
      expect(recorder.calls).assertEqual(0)
      expect(harness.statusAt(0).lastOutcome).assertEqual(TaskOutcome.SKIPPED)

      harness.scheduler.setStartupComplete()
      await harness.notifyAndWait(SchedulerTrigger.STARTUP)
      expect(recorder.calls).assertEqual(1)
    })

    it('isolatesTaskExceptionAndContinuesSiblings', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      const broken: RunRecorder = new RunRecorder()
      broken.throwMessage = 'boom'
      const healthy: RunRecorder = new RunRecorder()
      harness.scheduler.register(makeTask('task.broken', [SchedulerTrigger.TICK], broken))
      harness.scheduler.register(makeTask('task.healthy', [SchedulerTrigger.TICK], healthy))
      harness.start()

      await harness.notifyAndWait(SchedulerTrigger.TICK)

      expect(broken.calls).assertEqual(1)
      expect(harness.statusAt(0).lastOutcome).assertEqual(TaskOutcome.FAILED)
      expect(harness.statusAt(0).failureCount).assertEqual(1)
      expect(harness.statusAt(0).lastError).assertEqual('boom')
      expect(healthy.calls).assertEqual(1)
      expect(harness.statusAt(1).lastOutcome).assertEqual(TaskOutcome.OK)
    })

    it('truncatesLongErrorToTwoHundredChars', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      const recorder: RunRecorder = new RunRecorder()
      recorder.throwMessage = repeatChar('x', MAX_ERROR_LENGTH + 100)
      harness.scheduler.register(makeTask('task.longError', [SchedulerTrigger.TICK], recorder))
      harness.start()

      await harness.notifyAndWait(SchedulerTrigger.TICK)

      expect(harness.statusAt(0).lastError.length).assertEqual(MAX_ERROR_LENGTH)
      expect(harness.statusAt(0).lastError).assertEqual(repeatChar('x', MAX_ERROR_LENGTH))
    })

    it('runsMatchedTasksSeriallyInRegistrationOrder', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      const orderLog: OrderLog = new OrderLog()
      const first: RunRecorder = new RunRecorder()
      first.label = 'first'
      first.orderLog = orderLog
      first.yieldBeforeReturn = true
      const second: RunRecorder = new RunRecorder()
      second.label = 'second'
      second.orderLog = orderLog
      second.yieldBeforeReturn = true
      harness.scheduler.register(makeTask('task.first', [SchedulerTrigger.TICK], first))
      harness.scheduler.register(makeTask('task.second', [SchedulerTrigger.TICK], second))
      harness.start()

      await harness.notifyAndWait(SchedulerTrigger.TICK)

      expect(orderLog.entries.length).assertEqual(2)
      expect(orderLog.entries[0]).assertEqual('first')
      expect(orderLog.entries[1]).assertEqual('second')
      expect(first.maxConcurrency).assertEqual(1)
      expect(second.maxConcurrency).assertEqual(1)
    })

    it('ignoresUnmatchedTrigger', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      const recorder: RunRecorder = new RunRecorder()
      harness.scheduler.register(makeTask('activity.poll', [SchedulerTrigger.FOREGROUND], recorder))
      harness.start()

      await harness.notifyAndWait(SchedulerTrigger.TICK)
      expect(recorder.calls).assertEqual(0)

      await harness.notifyAndWait(SchedulerTrigger.FOREGROUND)
      expect(recorder.calls).assertEqual(1)
      expect(recorder.triggers[0]).assertEqual(SchedulerTrigger.FOREGROUND)
    })

    it('delaysFirstHitByStartDelayMs', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      const recorder: RunRecorder = new RunRecorder()
      const task: ScheduledTask = makeTask('draft.cleanup.delayed', [SchedulerTrigger.STARTUP], recorder)
      task.startDelayMs = 800
      harness.scheduler.register(task)
      harness.start()

      await harness.notifyAndWait(SchedulerTrigger.STARTUP)
      expect(recorder.calls).assertEqual(0)
      expect(harness.statusAt(0).lastRunAt).assertEqual(0)

      await harness.advanceAndWait(799)
      expect(recorder.calls).assertEqual(0)

      await harness.advanceAndWait(1)
      expect(recorder.calls).assertEqual(1)
      expect(harness.statusAt(0).lastOutcome).assertEqual(TaskOutcome.OK)

      await harness.notifyAndWait(SchedulerTrigger.STARTUP)
      expect(recorder.calls).assertEqual(2)
    })

    it('coalescesTriggerWhileStartDelayPending', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      const recorder: RunRecorder = new RunRecorder()
      const task: ScheduledTask = makeTask('draft.cleanup.pending', [SchedulerTrigger.STARTUP], recorder)
      task.startDelayMs = 800
      harness.scheduler.register(task)
      harness.start()

      await harness.notifyAndWait(SchedulerTrigger.STARTUP)
      await harness.notifyAndWait(SchedulerTrigger.STARTUP)

      expect(recorder.calls).assertEqual(0)
      expect(harness.statusAt(0).coalesced).assertEqual(1)
      const pendingBefore: number = harness.timer.pendingCount()

      await harness.advanceAndWait(800)
      expect(recorder.calls).assertEqual(1)
      expect(harness.timer.pendingCount()).assertEqual(pendingBefore - 1)
    })

    it('requestRunForceCancelsPendingStartDelay', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      const recorder: RunRecorder = new RunRecorder()
      const task: ScheduledTask = makeTask('draft.cleanup.force', [SchedulerTrigger.STARTUP], recorder)
      task.startDelayMs = 800
      harness.scheduler.register(task)
      harness.start()

      await harness.notifyAndWait(SchedulerTrigger.STARTUP)
      const pendingBefore: number = harness.timer.pendingCount()

      const outcome: TaskOutcome = await harness.scheduler.requestRun('draft.cleanup.force', true)

      expect(outcome).assertEqual(TaskOutcome.OK)
      expect(recorder.calls).assertEqual(1)
      expect(harness.timer.pendingCount()).assertEqual(pendingBefore - 1)

      await harness.advanceAndWait(800)
      expect(recorder.calls).assertEqual(1)
      expect(harness.timer.pendingCount()).assertEqual(pendingBefore - 1)
    })

    it('clearsPendingStartDelayOnShutdown', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      const recorder: RunRecorder = new RunRecorder()
      const task: ScheduledTask = makeTask('draft.cleanup.shutdown', [SchedulerTrigger.STARTUP], recorder)
      task.startDelayMs = 800
      harness.scheduler.register(task)
      harness.start()

      await harness.notifyAndWait(SchedulerTrigger.STARTUP)
      const pendingBefore: number = harness.timer.pendingCount()
      expect(pendingBefore).assertEqual(2)

      harness.scheduler.shutdown()
      expect(harness.timer.pendingCount()).assertEqual(0)

      await harness.advanceAndWait(800)
      expect(recorder.calls).assertEqual(0)

      harness.scheduler.notify(SchedulerTrigger.STARTUP)
      await harness.scheduler.whenIdle()
      expect(recorder.calls).assertEqual(0)
    })

    it('dispatchesTickFromHeartbeatOnlyWhenForeground', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      const recorder: RunRecorder = new RunRecorder()
      harness.scheduler.register(makeTask('heartbeat.task', [SchedulerTrigger.TICK], recorder))
      harness.scheduler.bindHeartbeatIntervalMs(1000)
      harness.start()
      expect(harness.timer.pendingCount()).assertEqual(1)

      await harness.advanceAndWait(1000)
      expect(recorder.calls).assertEqual(1)

      await harness.advanceAndWait(1000)
      expect(recorder.calls).assertEqual(2)

      harness.probes.foreground = false
      await harness.advanceAndWait(1000)
      await harness.advanceAndWait(1000)
      expect(recorder.calls).assertEqual(2)
      expect(harness.timer.pendingCount()).assertEqual(1)

      harness.probes.foreground = true
      await harness.advanceAndWait(1000)
      expect(recorder.calls).assertEqual(3)
    })

    it('startIsIdempotentAndStopBlocksNotifications', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      const recorder: RunRecorder = new RunRecorder()
      harness.scheduler.register(makeTask('start.stop', [SchedulerTrigger.TICK], recorder))

      harness.start()
      harness.start()
      expect(harness.timer.pendingCount()).assertEqual(1)

      await harness.notifyAndWait(SchedulerTrigger.TICK)
      expect(recorder.calls).assertEqual(1)

      harness.scheduler.stop()
      expect(harness.timer.pendingCount()).assertEqual(0)

      await harness.notifyAndWait(SchedulerTrigger.TICK)
      expect(recorder.calls).assertEqual(1)

      harness.start()
      await harness.notifyAndWait(SchedulerTrigger.TICK)
      expect(recorder.calls).assertEqual(2)
    })

    it('ignoresNotifyBeforeStart', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      const recorder: RunRecorder = new RunRecorder()
      harness.scheduler.register(makeTask('before.start', [SchedulerTrigger.FOREGROUND], recorder))

      await harness.notifyAndWait(SchedulerTrigger.FOREGROUND)
      expect(recorder.calls).assertEqual(0)

      harness.start()
      await harness.notifyAndWait(SchedulerTrigger.FOREGROUND)
      expect(recorder.calls).assertEqual(1)
    })

    it('requestRunForceBypassesThrottle', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      harness.timer.now = 1000
      const recorder: RunRecorder = new RunRecorder()
      const task: ScheduledTask = makeTask('user.retry', [SchedulerTrigger.TICK], recorder)
      task.minIntervalMs = 5000
      harness.scheduler.register(task)
      harness.start()

      await harness.notifyAndWait(SchedulerTrigger.TICK)
      expect(recorder.calls).assertEqual(1)

      const forced: TaskOutcome = await harness.scheduler.requestRun('user.retry', true)
      expect(forced).assertEqual(TaskOutcome.OK)
      expect(recorder.calls).assertEqual(2)

      const throttled: TaskOutcome = await harness.scheduler.requestRun('user.retry', false)
      expect(throttled).assertEqual(TaskOutcome.SKIPPED)
      expect(recorder.calls).assertEqual(2)
    })

    it('requestRunUnknownIdReturnsSkipped', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      harness.start()

      const outcome: TaskOutcome = await harness.scheduler.requestRun('missing.task', true)

      expect(outcome).assertEqual(TaskOutcome.SKIPPED)
      expect(harness.scheduler.snapshot().length).assertEqual(0)
    })

    it('snapshotReturnsDetachedCopies', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      const recorder: RunRecorder = new RunRecorder()
      harness.scheduler.register(makeTask('snapshot.task', [SchedulerTrigger.TICK], recorder))
      harness.start()

      await harness.notifyAndWait(SchedulerTrigger.TICK)
      const first: TaskStatus[] = harness.scheduler.snapshot()
      expect(first.length).assertEqual(1)
      expect(first[0].lastOutcome).assertEqual(TaskOutcome.OK)

      first[0].failureCount = 99
      first[0].lastOutcome = TaskOutcome.FAILED
      first[0].lastError = 'tampered'

      const second: TaskStatus[] = harness.scheduler.snapshot()
      expect(second[0].failureCount).assertEqual(0)
      expect(second[0].lastOutcome).assertEqual(TaskOutcome.OK)
      expect(second[0].lastError).assertEqual('')
    })

    it('rejectsDuplicateTaskId', 0, async (): Promise<void> => {
      const harness: Harness = new Harness()
      const first: RunRecorder = new RunRecorder()
      const second: RunRecorder = new RunRecorder()
      harness.scheduler.register(makeTask('duplicate.task', [SchedulerTrigger.TICK], first))
      harness.scheduler.register(makeTask('duplicate.task', [SchedulerTrigger.TICK], second))
      harness.start()

      expect(harness.scheduler.snapshot().length).assertEqual(1)

      await harness.notifyAndWait(SchedulerTrigger.TICK)
      expect(first.calls).assertEqual(1)
      expect(second.calls).assertEqual(0)
    })
  })
}
