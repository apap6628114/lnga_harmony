/**
 * 「智能去水」的网络传输长时任务。
 *
 * 去水要按帖子总页数逐页抓取，上千页的帖子会连续跑几十分钟。应用退到后台后，
 * 普通前后台任务会被系统冻结/限流，抓取循环会停在半路（表现为进度长时间不动，
 * 回到前台才继续）。因此任务期间申请一个 **dataTransfer 型长时任务**，让系统
 * 允许应用在后台继续网络传输，并给用户一条常驻通知说明「有任务在跑」。
 *
 * 与 `TtsBackgroundTaskController` 的关系：结构同源（串行化状态变更、按
 * `lifecycleGeneration` 防异步清理误伤新上下文），但**不复用同一个实例**——
 * 长时任务的 `taskId` 与类型是分开申请的（音频播放 / 数据传输），共用一个
 * 控制器会让「停止音频任务」顺带掐掉正在跑的去水任务。
 *
 * 需要 `module.json5` 中声明 `ohos.permission.KEEP_BACKGROUND_RUNNING` 与
 * `backgroundModes: ["dataTransfer"]`；设备不支持该能力时静默降级为
 * 「仅前台执行」，任务本身不受影响（只是退到后台会暂停）。
 */

import { common, wantAgent, WantAgent } from '@kit.AbilityKit'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { DOMAIN_MANAGER, formatError, Logger } from '../utils/Logger'

/** 长时任务通知的请求码（与 TTS 的 23001 区分开）。 */
const WATER_FILTER_TASK_REQUEST_CODE: number = 23002

/** 长时任务类型：数据传输（与 module.json5 的 backgroundModes 一致）。 */
const WATER_FILTER_BACKGROUND_MODES: string[] = ['dataTransfer']

const logger: Logger = new Logger(DOMAIN_MANAGER, 'WaterFilterBgTask')

/**
 * 长时任务系统事件回调。
 */
export interface WaterFilterBackgroundCallbacks {
  /** 长时任务被用户或系统取消：此时必须终止在途的去水任务，不能继续占用后台资源。 */
  onCancelled: () => void
  /** 长时任务因系统策略被暂停（true）或恢复活动（false）。 */
  onSuspended: (suspended: boolean) => void
}

/**
 * 管理「智能去水」的网络传输长时任务。
 */
export class WaterFilterBackgroundTask {
  private readonly callbacks: WaterFilterBackgroundCallbacks
  /** 当前 UIAbility 上下文。 */
  private context: common.UIAbilityContext | null = null
  /** 系统长时任务是否处于活动状态。 */
  private active: boolean = false
  /** 系统长时任务是否被系统暂停。 */
  private suspended: boolean = false
  /** 最新意图是否需要长时任务。 */
  private desired: boolean = false
  /** 当前长时任务标识。 */
  private taskId: number = -1
  /** 是否已注册系统事件监听。 */
  private listenerRegistered: boolean = false
  /** 是否正在主动停止长时任务。 */
  private stopping: boolean = false
  /** 串行化长时任务状态变更的操作链。 */
  private operation: Promise<void> = Promise.resolve()
  /** Ability 生命周期代次，用于避免异步清理误伤新上下文。 */
  private lifecycleGeneration: number = 0

  /** 系统取消长时任务：通知任务侧终止抓取。 */
  private readonly cancelCallback = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    if (this.stopping || !this.active || (this.taskId >= 0 && this.taskId !== info.id)) {
      return
    }
    logger.warn('water filter background task cancelled, reason: %{public}d', info.reason)
    this.active = false
    this.suspended = false
    this.desired = false
    this.taskId = -1
    this.callbacks.onCancelled()
  }

  /** 系统暂停/恢复长时任务。 */
  private readonly suspendCallback =
    (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
      if (!this.active || (this.taskId >= 0 && this.taskId !== info.continuousTaskId)) {
        return
      }
      this.suspended = info.suspendState
      logger.warn('water filter background task suspend changed: suspended=%{public}s, reason=%{public}d',
        info.suspendState.toString(), info.suspendReason)
      this.callbacks.onSuspended(info.suspendState)
    }

  /** 系统重新激活长时任务。 */
  private readonly activeCallback =
    (info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
      if (!this.active || (this.taskId >= 0 && this.taskId !== info.id)) {
        return
      }
      this.suspended = false
      logger.info('water filter background task activated, id: %{public}d', info.id)
      this.callbacks.onSuspended(false)
    }

  /**
   * 创建后台任务控制器。
   *
   * @param callbacks - 长时任务系统事件回调
   */
  constructor(callbacks: WaterFilterBackgroundCallbacks) {
    this.callbacks = callbacks
  }

  /**
   * 注入 UIAbility 上下文并注册系统事件监听。
   *
   * @param context - UIAbility 上下文
   */
  initialize(context: common.UIAbilityContext): void {
    this.lifecycleGeneration++
    this.context = context
    if (this.listenerRegistered) {
      return
    }
    if (!canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      logger.warn('water filter background task is not supported on this device')
      return
    }
    this.listenerRegistered = true
    try {
      backgroundTaskManager.on('continuousTaskCancel', this.cancelCallback)
      backgroundTaskManager.on('continuousTaskSuspend', this.suspendCallback)
      backgroundTaskManager.on('continuousTaskActive', this.activeCallback)
    } catch (error) {
      logger.error('register water filter background listener failed: %{public}s', formatError(error))
      this.unregisterListener()
    }
  }

  /**
   * 申请（或保持）长时任务。
   *
   * @returns 是否成功持有长时任务；false 表示只在前台运行
   */
  async start(): Promise<boolean> {
    this.desired = true
    await this.enqueueSynchronization()
    return this.active && !this.suspended
  }

  /**
   * 释放长时任务。
   */
  stop(): void {
    this.desired = false
    this.enqueueSynchronization()
  }

  /**
   * 停止长时任务、注销监听并释放上下文（Ability 销毁时调用）。
   */
  shutdown(): void {
    const lifecycleGeneration: number = ++this.lifecycleGeneration
    this.desired = false
    this.operation = this.operation.then(async (): Promise<void> => {
      await this.synchronize()
      if (lifecycleGeneration !== this.lifecycleGeneration) {
        return
      }
      this.unregisterListener()
      this.context = null
      this.active = false
      this.suspended = false
      this.taskId = -1
    })
  }

  private enqueueSynchronization(): Promise<void> {
    this.operation = this.operation.then(async (): Promise<void> => {
      await this.synchronize()
    })
    return this.operation
  }

  private async synchronize(): Promise<void> {
    try {
      if (this.desired && !this.active) {
        await this.activate()
      } else if (!this.desired && this.active) {
        await this.deactivate()
      }
    } catch (error) {
      logger.error('synchronize water filter background task failed: %{public}s', formatError(error))
    }
  }

  /** 创建通知跳转代理并申请数据传输长时任务。 */
  private async activate(): Promise<void> {
    const context: common.UIAbilityContext | null = this.context
    if (context === null) {
      logger.warn('start water filter background task skipped: context unavailable')
      return
    }
    if (!canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      return
    }
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: WATER_FILTER_TASK_REQUEST_CODE,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    }
    try {
      const agent: WantAgent = await wantAgent.getWantAgent(wantAgentInfo)
      const notification: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(
          context, WATER_FILTER_BACKGROUND_MODES, agent)
      this.active = true
      this.suspended = false
      this.taskId = notification.continuousTaskId ?? -1
      logger.info('water filter background task started, id: %{public}d', this.taskId)
      if (!this.desired) {
        await this.deactivate()
      }
    } catch (error) {
      // 降级：没有长时任务时任务仍可前台完成，只是退到后台会暂停
      logger.error('start water filter background task failed: %{public}s', formatError(error))
    }
  }

  /** 取消当前数据传输长时任务。 */
  private async deactivate(): Promise<void> {
    const context: common.UIAbilityContext | null = this.context
    if (context === null ||
      !canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      this.active = false
      this.suspended = false
      this.taskId = -1
      return
    }
    const taskId: number = this.taskId
    this.stopping = true
    try {
      if (taskId >= 0) {
        await backgroundTaskManager.stopBackgroundRunning(context, taskId)
      } else {
        await backgroundTaskManager.stopBackgroundRunning(context)
      }
      this.active = false
      this.suspended = false
      this.taskId = -1
      logger.info('water filter background task stopped')
    } catch (error) {
      logger.error('stop water filter background task failed: %{public}s', formatError(error))
    } finally {
      this.stopping = false
    }
  }

  private unregisterListener(): void {
    if (!this.listenerRegistered) {
      return
    }
    try {
      backgroundTaskManager.off('continuousTaskCancel', this.cancelCallback)
    } catch (error) {
      logger.warn('unregister water filter cancel listener failed: %{public}s', formatError(error))
    }
    try {
      backgroundTaskManager.off('continuousTaskSuspend', this.suspendCallback)
    } catch (error) {
      logger.warn('unregister water filter suspend listener failed: %{public}s', formatError(error))
    }
    try {
      backgroundTaskManager.off('continuousTaskActive', this.activeCallback)
    } catch (error) {
      logger.warn('unregister water filter active listener failed: %{public}s', formatError(error))
    }
    this.listenerRegistered = false
  }
}
