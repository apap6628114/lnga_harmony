/**
 * 应用内调度器 — 类型与数据模型。
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §7（任务模型 / 调度器契约）与
 * `docs/research/SCHEDULER_RESEARCH.md` §3（触发源枚举、公共契约）。
 *
 * 本文件只有数据结构，不含任何调度逻辑，也不依赖 AppStore / 网络 / 持久化，
 * 便于单测与后续 `BuiltinTasks` 复用。
 *
 * 纪律：本文件禁止 import 任何 store / service（调度器必须能独立编译与测试）。
 */

/**
 * 触发源：与生命周期 / 系统事件 / 用户操作一一对应。
 *
 * 调度器只按此枚举做匹配，不解释具体来源；`AppStore` / `EntryAbility` 负责把
 * Ability 回调、网络事件、登录事件翻译成 `AppScheduler.notify(trigger)`。
 */
export enum SchedulerTrigger {
  /** 冷启动完成（AppStore.init / 持久化加载之后调用 `setStartupComplete`）。 */
  STARTUP = 'startup',
  /** 回到前台（含冷启动后的第一次前台，由调用方决定是否与 STARTUP 同帧）。 */
  FOREGROUND = 'foreground',
  /** 进入后台：只允许收尾型任务（不做网络请求）。 */
  BACKGROUND = 'background',
  /** 网络恢复可用（调用方需自行去抖后通知）。 */
  NETWORK_AVAILABLE = 'network',
  /** 登录成功（新会话）。 */
  LOGIN = 'login',
  /** 退出登录 / 切换账号（旧会话作废）。 */
  LOGOUT = 'logout',
  /** 周期心跳（仅前台由调度器派发，见 AppScheduler 心跳）。 */
  TICK = 'tick',
  /** 用户主动（按钮 / 下拉刷新）；此类触发不会被 `startDelayMs` 延迟。 */
  USER = 'user'
}

/**
 * 单次任务执行结果。
 *
 * 约定：`SKIPPED` 表示条件不满足（未登录 / 后台 / 降级等），不是错误，
 * 不进入失败退避；`FAILED` 才参与 `retryDelaysMs` 退避。
 */
export enum TaskOutcome {
  /** 成功执行。 */
  OK = 0,
  /** 跳过（门禁不满足 / 节流窗口内 / 已有在途执行）。 */
  SKIPPED = 1,
  /** 失败（可重试）。 */
  FAILED = 2
}

/**
 * 调度上下文：注入给任务体，任务可据此做统一的日志与提前退出判断。
 *
 * 每次执行新建一个实例，任务体不得缓存或修改它以外的状态。
 */
export class SchedulerContext {
  /** 执行瞬间是否处于前台。 */
  foreground: boolean = false
  /** 本次执行对应的触发源。 */
  trigger: SchedulerTrigger = SchedulerTrigger.TICK
  /** 执行瞬间的时间戳（毫秒，来自调度器注入的时钟，便于测试）。 */
  now: number = 0
}

/**
 * 任务定义（注册时一次性描述，运行期不改）。
 *
 * 标题字段全部由注册方设置；调度器只读取，不修改任务定义。
 *
 * ## 为什么既有英文 `id` 又有中文 `label`
 *
 * `id` 是日志与排障的稳定主键（`session.verify`），**不直接展示给用户**；
 * 数据管理页「后台任务调度」一律展示 `label`（缺失时 UI 回退 `id`），
 * 避免用户看到一串看不懂的英文点分名。
 */
export class ScheduledTask {
  /** 唯一 ID（日志 / 状态查询主键；重复注册会被拒绝）。 */
  id: string = ''
  /** 用户可读的中文显示名（数据管理页展示；为空时 UI 回退英文 id）。 */
  label: string = ''
  /** 用户可读的一句话中文说明（展示在中文名下方；可为空）。 */
  detail: string = ''
  /** 触发源集合：命中任一即参与本次派发。 */
  triggers: SchedulerTrigger[] = []
  /** 最小成功执行间隔（毫秒）；0 表示不节流。 */
  minIntervalMs: number = 0
  /** 失败后的退避序列（毫秒）；空数组表示失败后不额外退避。 */
  retryDelaysMs: number[] = []
  /** 仅前台执行：后台触发时直接 SKIPPED。默认 true（防后台耗电）。 */
  foregroundOnly: boolean = true
  /** 需要已登录：未认证时直接 SKIPPED。 */
  requiresAuth: boolean = false
  /** 首次命中触发后的延迟（毫秒）；0 表示立即执行。用户主动触发不延迟。 */
  startDelayMs: number = 0
  /**
   * 任务体。
   *
   * 约定：任务体自行吞掉可恢复异常并返回 SKIPPED / FAILED；调度器仍会 try/catch
   * 兜底（抛错记为 FAILED 并截断错误信息，不影响同批其它任务）。
   */
  run: (ctx: SchedulerContext) => Promise<TaskOutcome> =
    async (): Promise<TaskOutcome> => TaskOutcome.OK
}

/**
 * 任务运行状态（`snapshot()` 返回的只读快照模型）。
 *
 * 字段语义：
 * - `lastRunAt`：最近一次**实际执行完成**的时间（OK / FAILED / 任务体自报 SKIPPED 都会更新；
 *   门禁或节流导致的跳过不更新，保证"上次成功时间"不被跳过污染）；
 * - `lastOutcome`：最近一次执行或跳过判定的结果（门禁跳过记 SKIPPED，便于诊断）；
 * - `failureCount`：连续失败次数（成功清零，跳过不清零）；
 * - `nextAllowedAt`：失败退避窗口的解除时间戳（0 = 无退避）；
 * - `coalesced`：因单飞/延迟等待被合并掉的触发次数；
 * - `running`：当前是否有在途执行；
 * - `lastError`：最近一次失败的异常摘要（最多 200 字符）。
 */
export class TaskStatus {
  /** 任务 ID（排障主键，不直接展示给用户）。 */
  id: string = ''
  /** 任务中文显示名（注册时取自 `ScheduledTask.label`；空串由 UI 回退 id）。 */
  label: string = ''
  /** 任务中文说明（注册时取自 `ScheduledTask.detail`；可为空串）。 */
  detail: string = ''
  /** 最近一次实际执行完成时间（毫秒；0 = 尚未执行过）。 */
  lastRunAt: number = 0
  /** 最近一次结果（含门禁跳过）。 */
  lastOutcome: TaskOutcome = TaskOutcome.SKIPPED
  /** 连续失败次数。 */
  failureCount: number = 0
  /** 退避窗口解除时间（毫秒；0 = 无退避）。 */
  nextAllowedAt: number = 0
  /** 被合并（单飞 / 延迟等待）的触发次数。 */
  coalesced: number = 0
  /** 当前是否在执行。 */
  running: boolean = false
  /** 最近一次失败的错误摘要（截断 200 字符）。 */
  lastError: string = ''
}
