/**
 * 内置调度任务注册表。
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §7.4。把原本散落在 `EntryAbility`、
 * `AppStore` 私有定时器与各 `PollingController` 里的"时机任务"收编为静态任务表：
 * 触发源、最小间隔、前台/认证门禁、执行体全部集中声明，`AppStore` 只提供回调。
 *
 * ## 为什么宿主要注入而不是直接 import
 *
 * `AppStore` 会 import 本模块注册任务；若本模块反过来 import `AppStore` 就形成循环依赖
 * （ArkTS 模块初始化顺序问题）。因此所有业务动作通过 {@link BuiltinTaskHost} 注入，
 * 本文件只依赖 `AppScheduler` 的纯逻辑接口，可独立单测。
 *
 * ## 不注册的任务（保留既有实现）
 *
 * - `credential.recheck`：凭证降级复验保留 `AppStore.scheduleCredentialRecheck` 的有界退避
 *   定时器（与 SessionGuard 深度耦合，迁移收益低、回归风险高）；
 * - `toolcache.flush` / `persistence.flush`：保留 `EntryAbility.onBackground → flushAll`
 *   （后台时机必须同步发起，调度器的异步派发可能晚于进程被回收）。
 */

import { AppScheduler } from './AppScheduler'
import { ScheduledTask, SchedulerContext, SchedulerTrigger, TaskOutcome } from './SchedulerTypes'

/** 通知轮询间隔（毫秒）。 */
const NOTIFICATION_POLL_INTERVAL_MS: number = 300 * 1000

/** 关注动态轮询间隔（毫秒）。 */
const ACTIVITY_POLL_INTERVAL_MS: number = 300 * 1000

/** 跟踪帖子检查间隔（毫秒）。 */
const TRACKED_CHECK_INTERVAL_MS: number = 10 * 60 * 1000

/** 前台会话校验间隔（毫秒）。 */
const SESSION_VERIFY_INTERVAL_MS: number = 10 * 60 * 1000

/** 旧数据清理检查间隔（毫秒）：每日一次即可。 */
const LEGACY_CLEANUP_INTERVAL_MS: number = 24 * 60 * 60 * 1000

/** 草稿清理启动延迟（毫秒）。 */
const DRAFT_CLEANUP_DELAY_MS: number = 800

/**
 * 任务宿主 — 由 `AppStore` 注入全部业务动作。
 *
 * 所有回调都必须自行容错（框架会兜底 catch 并记 FAILED，但不希望正常失败路径污染状态）。
 */
export class BuiltinTaskHost {
  /** 前台会话校验（内部由 SessionGuard 再做 10 分钟节流）。 */
  verifySession: () => Promise<void> = async (): Promise<void> => {}
  /** 自动签到（内部按日期去重）。 */
  autoCheckin: () => Promise<void> = async (): Promise<void> => {}
  /** 通知刷新一次（内部有 30s 普通刷新节流与并发复用）。 */
  pollNotifications: () => Promise<void> = async (): Promise<void> => {}
  /** 关注动态刷新一次。 */
  pollActivities: () => Promise<void> = async (): Promise<void> => {}
  /** 跟踪帖子检查一轮。 */
  checkTracked: () => Promise<void> = async (): Promise<void> => {}
  /** 草稿清理（内部有重入守卫，幂等）。 */
  cleanupDrafts: () => void = (): void => {}
  /** 旧格式数据清理（未到期时内部直接返回）。 */
  cleanupLegacy: () => Promise<void> = async (): Promise<void> => {}
}

/**
 * 注册内置任务。
 *
 * 幂等性由 `AppScheduler.register` 保证（重复 id 拒绝并告警），`AppStore.init` 重入时
 * 重复调用不会产生重复任务。
 *
 * @param scheduler - 调度器实例
 * @param host - 任务宿主（业务动作）
 */
export function registerBuiltinTasks(scheduler: AppScheduler, host: BuiltinTaskHost): void {
  // ---- 会话校验：回前台 + 心跳驱动；10 分钟节流（与 SessionGuard 内部节流同档）----
  // 数据管理页展示名：登录状态检查。
  const verifyTask: ScheduledTask = new ScheduledTask()
  verifyTask.id = 'session.verify'
  verifyTask.label = '登录状态检查'
  verifyTask.detail = '回到前台或定时确认登录是否仍然有效'
  verifyTask.triggers = [
    SchedulerTrigger.FOREGROUND,
    SchedulerTrigger.TICK,
    SchedulerTrigger.LOGIN
  ]
  verifyTask.minIntervalMs = SESSION_VERIFY_INTERVAL_MS
  verifyTask.foregroundOnly = true
  verifyTask.requiresAuth = true
  verifyTask.run = async (ctx: SchedulerContext): Promise<TaskOutcome> => {
    await host.verifySession()
    return TaskOutcome.OK
  }
  scheduler.register(verifyTask)

  // ---- 自动签到：启动 / 回前台各检查一次（内部按日去重）----
  // 数据管理页展示名：自动签到。
  const checkinTask: ScheduledTask = new ScheduledTask()
  checkinTask.id = 'checkin.auto'
  checkinTask.label = '自动签到'
  checkinTask.detail = '启动或回到前台时自动完成每日签到'
  checkinTask.triggers = [SchedulerTrigger.STARTUP, SchedulerTrigger.FOREGROUND]
  checkinTask.minIntervalMs = 0
  checkinTask.foregroundOnly = true
  checkinTask.requiresAuth = true
  checkinTask.run = async (ctx: SchedulerContext): Promise<TaskOutcome> => {
    await host.autoCheckin()
    return TaskOutcome.OK
  }
  scheduler.register(checkinTask)

  // ---- 通知轮询 ----
  // 数据管理页展示名：新通知检查。
  const pollNotifications: ScheduledTask = new ScheduledTask()
  pollNotifications.id = 'notifications.poll'
  pollNotifications.label = '新通知检查'
  pollNotifications.detail = '每 5 分钟检查一次是否有新通知'
  pollNotifications.triggers = [
    SchedulerTrigger.STARTUP,
    SchedulerTrigger.FOREGROUND,
    SchedulerTrigger.TICK
  ]
  pollNotifications.minIntervalMs = NOTIFICATION_POLL_INTERVAL_MS
  pollNotifications.foregroundOnly = true
  pollNotifications.requiresAuth = true
  pollNotifications.run = async (ctx: SchedulerContext): Promise<TaskOutcome> => {
    await host.pollNotifications()
    return TaskOutcome.OK
  }
  scheduler.register(pollNotifications)

  // ---- 关注动态轮询 ----
  // 数据管理页展示名：关注动态检查。
  const pollActivities: ScheduledTask = new ScheduledTask()
  pollActivities.id = 'activities.poll'
  pollActivities.label = '关注动态检查'
  pollActivities.detail = '每 5 分钟检查一次关注的人是否有新动态'
  pollActivities.triggers = [
    SchedulerTrigger.STARTUP,
    SchedulerTrigger.FOREGROUND,
    SchedulerTrigger.TICK
  ]
  pollActivities.minIntervalMs = ACTIVITY_POLL_INTERVAL_MS
  pollActivities.foregroundOnly = true
  pollActivities.requiresAuth = true
  pollActivities.run = async (ctx: SchedulerContext): Promise<TaskOutcome> => {
    await host.pollActivities()
    return TaskOutcome.OK
  }
  scheduler.register(pollActivities)

  // ---- 跟踪帖子检查 ----
  // 数据管理页展示名：跟踪帖子检查。
  const checkTracked: ScheduledTask = new ScheduledTask()
  checkTracked.id = 'tracked.check'
  checkTracked.label = '跟踪帖子检查'
  checkTracked.detail = '每 10 分钟检查一次跟踪的帖子是否有更新'
  checkTracked.triggers = [
    SchedulerTrigger.STARTUP,
    SchedulerTrigger.FOREGROUND,
    SchedulerTrigger.TICK
  ]
  checkTracked.minIntervalMs = TRACKED_CHECK_INTERVAL_MS
  checkTracked.foregroundOnly = true
  checkTracked.requiresAuth = true
  checkTracked.run = async (ctx: SchedulerContext): Promise<TaskOutcome> => {
    await host.checkTracked()
    return TaskOutcome.OK
  }
  scheduler.register(checkTracked)

  // ---- 草稿清理：启动后延迟 800ms（让出启动前几帧）----
  // 数据管理页展示名：草稿清理。
  const cleanupDrafts: ScheduledTask = new ScheduledTask()
  cleanupDrafts.id = 'draft.cleanup'
  cleanupDrafts.label = '草稿清理'
  cleanupDrafts.detail = '启动后清理超过保留期的草稿和超量的草稿图片/视频副本'
  cleanupDrafts.triggers = [SchedulerTrigger.STARTUP]
  cleanupDrafts.minIntervalMs = 0
  cleanupDrafts.startDelayMs = DRAFT_CLEANUP_DELAY_MS
  cleanupDrafts.foregroundOnly = false
  cleanupDrafts.requiresAuth = false
  cleanupDrafts.run = async (ctx: SchedulerContext): Promise<TaskOutcome> => {
    host.cleanupDrafts()
    return TaskOutcome.OK
  }
  scheduler.register(cleanupDrafts)

  // ---- 旧格式数据清理：启动检查 + 每日一次（未到期内部直接返回）----
  // 数据管理页展示名：旧数据清理。
  const cleanupLegacy: ScheduledTask = new ScheduledTask()
  cleanupLegacy.id = 'migration.legacyCleanup'
  cleanupLegacy.label = '旧数据清理'
  cleanupLegacy.detail = '每天检查并清理旧版本遗留的数据'
  cleanupLegacy.triggers = [SchedulerTrigger.STARTUP, SchedulerTrigger.TICK]
  cleanupLegacy.minIntervalMs = LEGACY_CLEANUP_INTERVAL_MS
  cleanupLegacy.foregroundOnly = false
  cleanupLegacy.requiresAuth = false
  cleanupLegacy.run = async (ctx: SchedulerContext): Promise<TaskOutcome> => {
    await host.cleanupLegacy()
    return TaskOutcome.OK
  }
  scheduler.register(cleanupLegacy)
}
