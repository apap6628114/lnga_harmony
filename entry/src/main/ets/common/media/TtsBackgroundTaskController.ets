import { common, wantAgent, WantAgent } from '@kit.AbilityKit'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { DOMAIN_MEDIA, formatError, Logger } from '../utils/Logger'

const BACKGROUND_TASK_REQUEST_CODE: number = 23001
const logger: Logger = new Logger(DOMAIN_MEDIA, 'TtsBackgroundTask')

/**
 * 后台长时任务系统事件回调。
 */
export interface TtsBackgroundTaskCallbacks {
  /** 长时任务被用户或系统取消。 */
  onCancelled: (info: backgroundTaskManager.ContinuousTaskCancelInfo) => void
  /** 长时任务因系统校验或调度策略进入暂停状态。 */
  onSuspended: (info: backgroundTaskManager.ContinuousTaskSuspendInfo) => void
  /** 长时任务从暂停状态恢复活动。 */
  onActivated: (info: backgroundTaskManager.ContinuousTaskActiveInfo) => void
}

/**
 * 管理 TTS 播报所需的音频播放长时任务。
 */
export class TtsBackgroundTaskController {
  /** 长时任务系统事件回调。 */
  private readonly callbacks: TtsBackgroundTaskCallbacks
  /** 当前 UIAbility 上下文。 */
  private context: common.UIAbilityContext | null = null
  /** 系统长时任务是否处于活动状态。 */
  private active: boolean = false
  /** 系统长时任务是否被系统暂停。 */
  private suspended: boolean = false
  /** 最新播放状态是否需要长时任务。 */
  private desired: boolean = false
  /** 当前长时任务标识。 */
  private taskId: number = -1
  /** 是否已经注册系统取消事件。 */
  private listenerRegistered: boolean = false
  /** 是否正在主动停止长时任务。 */
  private stopping: boolean = false
  /** 串行化长时任务状态变更的操作链。 */
  private operation: Promise<void> = Promise.resolve()
  /** Ability 生命周期代次，用于避免异步清理误伤新上下文。 */
  private lifecycleGeneration: number = 0

  /** 系统取消长时任务时同步停止 TTS 播报。 */
  private readonly cancelCallback = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    if (this.stopping || !this.active || (this.taskId >= 0 && this.taskId !== info.id)) {
      return
    }
    logger.warn('TTS background task cancelled, reason: %{public}d', info.reason)
    this.active = false
    this.suspended = false
    this.desired = false
    this.taskId = -1
    this.callbacks.onCancelled(info)
  }

  /** 系统暂停长时任务时同步内部状态。 */
  private readonly suspendCallback =
    (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
      if (!this.active ||
        (this.taskId >= 0 && this.taskId !== info.continuousTaskId)) {
        return
      }
      this.suspended = info.suspendState
      logger.warn(
        'TTS background task suspend state changed: suspended=%{public}s, reason=%{public}d',
        info.suspendState.toString(),
        info.suspendReason
      )
      if (info.suspendState) {
        this.callbacks.onSuspended(info)
      }
    }

  /** 系统重新激活长时任务时同步内部状态。 */
  private readonly activeCallback =
    (info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
      if (!this.active || (this.taskId >= 0 && this.taskId !== info.id)) {
        return
      }
      this.suspended = false
      logger.info('TTS background task activated, id: %{public}d', info.id)
      this.callbacks.onActivated(info)
  }

  /**
   * 创建后台任务控制器。
   *
   * @param callbacks 长时任务系统事件回调。
   */
  constructor(callbacks: TtsBackgroundTaskCallbacks) {
    this.callbacks = callbacks
  }

  /**
   * 保存 UIAbility 上下文并注册后台任务取消监听。
   *
   * @param context UIAbility 上下文。
   */
  initialize(context: common.UIAbilityContext): void {
    this.lifecycleGeneration++
    this.context = context
    if (this.listenerRegistered) {
      return
    }
    if (!canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      logger.warn('TTS background task is not supported on this device')
      return
    }
    this.listenerRegistered = true
    try {
      backgroundTaskManager.on('continuousTaskCancel', this.cancelCallback)
      backgroundTaskManager.on('continuousTaskSuspend', this.suspendCallback)
      backgroundTaskManager.on('continuousTaskActive', this.activeCallback)
    } catch (error) {
      logger.error('Register TTS background task listener failed: %{public}s', formatError(error))
      this.unregisterListener()
    }
  }

  /**
   * 确保音频播放长时任务已启动。
   *
   * @returns 是否成功持有长时任务。
   */
  async start(): Promise<boolean> {
    this.desired = true
    await this.enqueueSynchronization()
    return this.active && !this.suspended
  }

  /**
   * 请求停止音频播放长时任务。
   */
  stop(): void {
    this.desired = false
    this.enqueueSynchronization()
  }

  /**
   * 停止长时任务、注销监听并释放 Ability 上下文。
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

  /**
   * 将长时任务状态同步操作加入串行队列。
   *
   * @returns 当前同步操作。
   */
  private enqueueSynchronization(): Promise<void> {
    this.operation = this.operation.then(async (): Promise<void> => {
      await this.synchronize()
    })
    return this.operation
  }

  /**
   * 根据最新播放意图启动或停止长时任务。
   */
  private async synchronize(): Promise<void> {
    try {
      if (this.desired && !this.active) {
        await this.activate()
      } else if (!this.desired && this.active) {
        await this.deactivate()
      }
    } catch (error) {
      logger.error('Synchronize TTS background task failed: %{public}s', formatError(error))
    }
  }

  /**
   * 创建通知跳转代理并申请音频播放长时任务。
   */
  private async activate(): Promise<void> {
    const context: common.UIAbilityContext | null = this.context
    if (context === null) {
      logger.error('Start TTS background task failed: UIAbility context is unavailable')
      return
    }
    if (!canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      logger.warn('Start TTS background task failed: capability is unavailable')
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
      requestCode: BACKGROUND_TASK_REQUEST_CODE,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    }
    try {
      const agent: WantAgent = await wantAgent.getWantAgent(wantAgentInfo)
      const notification: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(context, ['audioPlayback'], agent)
      this.active = true
      this.suspended = false
      this.taskId = notification.continuousTaskId ?? -1
      logger.info('TTS background task started, id: %{public}d', this.taskId)
      if (!this.desired) {
        await this.deactivate()
      }
    } catch (error) {
      logger.error('Start TTS background task failed: %{public}s', formatError(error))
    }
  }

  /**
   * 取消当前音频播放长时任务。
   */
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
      logger.info('TTS background task stopped')
    } catch (error) {
      logger.error('Stop TTS background task failed: %{public}s', formatError(error))
    } finally {
      this.stopping = false
    }
  }

  /**
   * 注销系统长时任务取消监听。
   */
  private unregisterListener(): void {
    if (!this.listenerRegistered) {
      return
    }
    try {
      backgroundTaskManager.off('continuousTaskCancel', this.cancelCallback)
    } catch (error) {
      logger.warn(
        'Unregister TTS background cancel listener failed: %{public}s',
        formatError(error)
      )
    }
    try {
      backgroundTaskManager.off('continuousTaskSuspend', this.suspendCallback)
    } catch (error) {
      logger.warn(
        'Unregister TTS background suspend listener failed: %{public}s',
        formatError(error)
      )
    }
    try {
      backgroundTaskManager.off('continuousTaskActive', this.activeCallback)
    } catch (error) {
      logger.warn(
        'Unregister TTS background active listener failed: %{public}s',
        formatError(error)
      )
    }
    this.listenerRegistered = false
  }
}
