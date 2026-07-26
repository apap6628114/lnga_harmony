import { common, wantAgent, WantAgent } from '@kit.AbilityKit'
import { avSession } from '@kit.AVSessionKit'
import { DOMAIN_MEDIA, formatError, Logger } from '../utils/Logger'

const AV_SESSION_REQUEST_CODE: number = 23002
const AV_SESSION_TAG: string = 'NgaPostTts'
const logger: Logger = new Logger(DOMAIN_MEDIA, 'TtsAvSession')

/**
 * 系统播控中心展示的 TTS 媒体信息。
 */
export interface TtsMediaMetadata {
  /** 当前朗读内容的唯一标识。 */
  assetId: string
  /** 当前朗读帖子的标题。 */
  title: string
  /** 当前朗读楼层的作者。 */
  artist: string
  /** 当前朗读楼层的说明。 */
  album: string
}

/**
 * 系统播控命令的业务回调。
 */
export interface TtsAvSessionCallbacks {
  /** 请求继续播放当前朗读。 */
  onPlay: () => void
  /** 请求暂停当前朗读。 */
  onPause: () => void
  /** 请求停止当前朗读。 */
  onStop: () => void
}

/**
 * 管理帖子朗读对应的系统 AVSession。
 */
export class TtsAvSessionController {
  /** 系统播控命令的业务回调。 */
  private readonly callbacks: TtsAvSessionCallbacks
  /** 当前 UIAbility 上下文。 */
  private context: common.UIAbilityContext | null = null
  /** 当前系统媒体会话。 */
  private session: avSession.AVSession | null = null
  /** 当前媒体元数据。 */
  private metadata: TtsMediaMetadata | null = null
  /** 当前媒体总时长，单位为毫秒。 */
  private durationMs: number = 0
  /** 当前媒体已播放时长，单位为毫秒。 */
  private elapsedTimeMs: number = 0
  /** 最近一次进入播放状态的时间。 */
  private playbackStartedAtMs: number = 0
  /** 当前期望同步给系统的播放状态。 */
  private playbackState: avSession.PlaybackState =
    avSession.PlaybackState.PLAYBACK_STATE_INITIAL
  /** 当前是否需要保持系统媒体会话活动。 */
  private activeRequested: boolean = false
  /** 会话异步操作代次。 */
  private generation: number = 0
  /** UIAbility 上下文生命周期代次。 */
  private lifecycleGeneration: number = 0
  /** 串行化系统媒体会话操作的任务链。 */
  private operation: Promise<void> = Promise.resolve()

  /** 响应系统播放命令。 */
  private readonly playCallback = (): void => {
    this.callbacks.onPlay()
  }

  /** 响应系统暂停命令。 */
  private readonly pauseCallback = (): void => {
    this.callbacks.onPause()
  }

  /** 响应系统停止命令。 */
  private readonly stopCallback = (): void => {
    this.callbacks.onStop()
  }

  /**
   * 创建系统媒体会话控制器。
   *
   * @param callbacks 系统播控命令的业务回调。
   */
  constructor(callbacks: TtsAvSessionCallbacks) {
    this.callbacks = callbacks
  }

  /**
   * 保存创建系统媒体会话所需的 UIAbility 上下文。
   *
   * @param context UIAbility 上下文。
   */
  initialize(context: common.UIAbilityContext): void {
    this.lifecycleGeneration++
    this.context = context
  }

  /**
   * 为新的帖子朗读创建并激活系统媒体会话。
   *
   * @param metadata 系统播控中心展示的媒体信息。
   */
  start(metadata: TtsMediaMetadata): void {
    const generation: number = ++this.generation
    this.metadata = metadata
    this.durationMs = 0
    this.elapsedTimeMs = 0
    this.playbackStartedAtMs = 0
    this.playbackState = avSession.PlaybackState.PLAYBACK_STATE_PREPARE
    this.activeRequested = true
    this.enqueue(async (): Promise<void> => {
      await this.activate(generation)
    })
  }

  /**
   * 将当前朗读同步为播放状态。
   *
   * @param durationMs 当前媒体总时长，单位为毫秒。
   */
  setPlaying(durationMs: number): void {
    if (!this.activeRequested) {
      return
    }
    this.durationMs = Math.max(0, durationMs)
    this.playbackStartedAtMs = Date.now()
    this.playbackState = avSession.PlaybackState.PLAYBACK_STATE_PLAY
    this.enqueueStateUpdate(this.generation, true)
  }

  /**
   * 将当前朗读同步为暂停状态。
   *
   * @param durationMs 已知的媒体总时长，单位为毫秒。
   */
  setPaused(durationMs?: number): void {
    if (!this.activeRequested) {
      return
    }
    const updateMetadata: boolean = durationMs !== undefined
    if (durationMs !== undefined) {
      this.durationMs = Math.max(0, durationMs)
    }
    this.elapsedTimeMs = this.resolveElapsedTime()
    this.playbackStartedAtMs = 0
    this.playbackState = avSession.PlaybackState.PLAYBACK_STATE_PAUSE
    this.enqueueStateUpdate(this.generation, updateMetadata)
  }

  /**
   * 将尚未开始输出声音的朗读重新同步为准备状态。
   */
  setPreparing(): void {
    if (!this.activeRequested) {
      return
    }
    this.elapsedTimeMs = 0
    this.playbackStartedAtMs = 0
    this.playbackState = avSession.PlaybackState.PLAYBACK_STATE_PREPARE
    this.enqueueStateUpdate(this.generation, false)
  }

  /**
   * 将暂停的朗读重新同步为播放状态。
   */
  setResumed(): void {
    if (!this.activeRequested) {
      return
    }
    this.playbackStartedAtMs = Date.now()
    this.playbackState = avSession.PlaybackState.PLAYBACK_STATE_PLAY
    this.enqueueStateUpdate(this.generation, false)
  }

  /**
   * 停止当前系统媒体会话。
   *
   * @param completed 是否为自然播放完成。
   */
  stop(completed: boolean = false): void {
    const terminalState: avSession.PlaybackState = completed
      ? avSession.PlaybackState.PLAYBACK_STATE_COMPLETED
      : avSession.PlaybackState.PLAYBACK_STATE_STOP
    const generation: number = ++this.generation
    this.elapsedTimeMs = completed ? this.durationMs : this.resolveElapsedTime()
    this.playbackStartedAtMs = 0
    this.playbackState = terminalState
    this.activeRequested = false
    this.enqueue(async (): Promise<void> => {
      await this.closeSession(generation, terminalState)
    })
  }

  /**
   * 销毁系统媒体会话并释放 Ability 级资源。
   */
  shutdown(): void {
    const generation: number = ++this.generation
    const lifecycleGeneration: number = ++this.lifecycleGeneration
    this.activeRequested = false
    this.playbackStartedAtMs = 0
    this.playbackState = avSession.PlaybackState.PLAYBACK_STATE_RELEASED
    this.enqueue(async (): Promise<void> => {
      await this.closeSession(
        generation,
        avSession.PlaybackState.PLAYBACK_STATE_RELEASED,
        true
      )
      if (generation === this.generation &&
        lifecycleGeneration === this.lifecycleGeneration) {
        this.context = null
        this.metadata = null
      }
    })
  }

  /**
   * 将媒体会话操作加入串行队列。
   *
   * @param task 待执行的媒体会话操作。
   */
  private enqueue(task: () => Promise<void>): void {
    this.operation = this.operation.then(task).catch((error: Object): void => {
      logger.error('Synchronize TTS AVSession failed: %{public}s', formatError(error))
    })
  }

  /**
   * 创建并激活当前朗读的系统媒体会话。
   *
   * @param generation 当前会话操作代次。
   */
  private async activate(generation: number): Promise<void> {
    if (!this.isCurrentActiveGeneration(generation)) {
      return
    }
    let session: avSession.AVSession | null = this.session
    if (session === null) {
      session = await this.createSession()
      if (session === null) {
        return
      }
      this.session = session
    }
    if (!this.isCurrentActiveGeneration(generation) || this.session !== session) {
      return
    }
    const metadata: TtsMediaMetadata | null = this.metadata
    if (metadata === null) {
      return
    }
    try {
      await session.setAVMetadata(this.buildMetadata(metadata))
      if (!this.isCurrentActiveGeneration(generation)) {
        return
      }
      await session.setAVPlaybackState(this.buildPlaybackState())
      if (!this.isCurrentActiveGeneration(generation)) {
        return
      }
      await session.activate()
      logger.info('TTS AVSession activated')
    } catch (error) {
      logger.error('Activate TTS AVSession failed: %{public}s', formatError(error))
      if (this.isCurrentActiveGeneration(generation) && this.session === session) {
        this.session = null
        await this.releaseSessionInstance(session)
      }
    }
  }

  /**
   * 创建系统媒体会话并注册基础播控命令。
   *
   * @returns 创建完成的媒体会话，不支持时返回 null。
   */
  private async createSession(): Promise<avSession.AVSession | null> {
    const context: common.UIAbilityContext | null = this.context
    if (context === null) {
      logger.warn('Create TTS AVSession skipped: UIAbility context is unavailable')
      return null
    }
    if (!canIUse('SystemCapability.Multimedia.AVSession.Core')) {
      logger.warn('Create TTS AVSession skipped: capability is unavailable')
      return null
    }
    let session: avSession.AVSession | null = null
    try {
      session = await avSession.createAVSession(context, AV_SESSION_TAG, 'audio')
      session.on('play', this.playCallback)
      session.on('pause', this.pauseCallback)
      session.on('stop', this.stopCallback)
      await this.setLaunchAbility(session, context)
      return session
    } catch (error) {
      logger.error('Create TTS AVSession failed: %{public}s', formatError(error))
      if (session !== null) {
        await this.releaseSessionInstance(session)
      }
      return null
    }
  }

  /**
   * 设置从系统播控中心返回应用的跳转目标。
   *
   * @param session 当前系统媒体会话。
   * @param context 当前 UIAbility 上下文。
   */
  private async setLaunchAbility(
    session: avSession.AVSession,
    context: common.UIAbilityContext
  ): Promise<void> {
    const agentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: AV_SESSION_REQUEST_CODE,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    }
    try {
      const agent: WantAgent = await wantAgent.getWantAgent(agentInfo)
      await session.setLaunchAbility(agent)
    } catch (error) {
      throw new Error(formatError(error))
    }
  }

  /**
   * 将当前媒体信息转换为 AVSession 元数据。
   *
   * @param metadata 当前媒体信息。
   * @returns 系统媒体会话元数据。
   */
  private buildMetadata(metadata: TtsMediaMetadata): avSession.AVMetadata {
    return {
      assetId: metadata.assetId,
      title: metadata.title,
      artist: metadata.artist,
      album: metadata.album,
      duration: this.durationMs
    }
  }

  /**
   * 构建当前系统媒体会话播放状态。
   *
   * @returns 系统媒体会话播放状态。
   */
  private buildPlaybackState(): avSession.AVPlaybackState {
    return {
      state: this.playbackState,
      speed: 1,
      position: {
        elapsedTime: this.resolveElapsedTime(),
        updateTime: Date.now()
      },
      bufferedTime: this.durationMs
    }
  }

  /**
   * 排队同步当前媒体会话状态。
   *
   * @param generation 当前会话操作代次。
   * @param updateMetadata 是否同时更新包含总时长的媒体元数据。
   */
  private enqueueStateUpdate(generation: number, updateMetadata: boolean): void {
    this.enqueue(async (): Promise<void> => {
      const session: avSession.AVSession | null = this.session
      if (!this.isCurrentActiveGeneration(generation) || session === null) {
        return
      }
      const metadata: TtsMediaMetadata | null = this.metadata
      if (updateMetadata && metadata !== null) {
        await session.setAVMetadata(this.buildMetadata(metadata))
      }
      await session.setAVPlaybackState(this.buildPlaybackState())
    })
  }

  /**
   * 更新终止状态并销毁当前系统媒体会话。
   *
   * @param generation 当前会话操作代次。
   * @param terminalState 会话关闭前同步的终止状态。
   * @param force 是否忽略播放代次并强制释放旧 Ability 的会话。
   */
  private async closeSession(
    generation: number,
    terminalState: avSession.PlaybackState,
    force: boolean = false
  ): Promise<void> {
    if (!force && generation !== this.generation) {
      return
    }
    const session: avSession.AVSession | null = this.session
    if (session === null) {
      this.resetClosedSessionState(generation)
      return
    }
    this.session = null
    try {
      await session.setAVPlaybackState({
        state: terminalState,
        speed: 1,
        position: {
          elapsedTime: this.elapsedTimeMs,
          updateTime: Date.now()
        },
        bufferedTime: this.durationMs
      })
    } catch (error) {
      logger.warn('Set terminal TTS AVSession state failed: %{public}s', formatError(error))
    }
    await this.releaseSessionInstance(session)
    if (generation === this.generation) {
      this.resetClosedSessionState(generation)
      logger.info('TTS AVSession released')
    }
  }

  /**
   * 注销当前系统媒体会话的播控命令。
   *
   * @param session 当前系统媒体会话。
   */
  private unregisterCallbacks(session: avSession.AVSession): void {
    try {
      session.off('play', this.playCallback)
      session.off('pause', this.pauseCallback)
      session.off('stop', this.stopCallback)
    } catch (error) {
      logger.warn('Unregister TTS AVSession callbacks failed: %{public}s', formatError(error))
    }
  }

  /**
   * 停用并销毁指定的系统媒体会话实例。
   *
   * @param session 待释放的系统媒体会话。
   */
  private async releaseSessionInstance(session: avSession.AVSession): Promise<void> {
    try {
      await session.deactivate()
    } catch (error) {
      logger.warn('Deactivate TTS AVSession failed: %{public}s', formatError(error))
    }
    this.unregisterCallbacks(session)
    try {
      await session.destroy()
    } catch (error) {
      logger.warn('Destroy TTS AVSession failed: %{public}s', formatError(error))
    }
  }

  /**
   * 计算同步给系统播控中心的当前播放位置。
   *
   * @returns 当前播放位置，单位为毫秒。
   */
  private resolveElapsedTime(): number {
    if (this.playbackStartedAtMs <= 0 ||
      this.playbackState !== avSession.PlaybackState.PLAYBACK_STATE_PLAY) {
      return this.elapsedTimeMs
    }
    const elapsedTime: number = this.elapsedTimeMs + Date.now() - this.playbackStartedAtMs
    return this.durationMs > 0 ? Math.min(elapsedTime, this.durationMs) : elapsedTime
  }

  /**
   * 判断指定代次是否仍是当前需要激活的媒体会话。
   *
   * @param generation 待判断的会话操作代次。
   * @returns 是否仍属于当前活动会话。
   */
  private isCurrentActiveGeneration(generation: number): boolean {
    return generation === this.generation && this.activeRequested
  }

  /**
   * 清理已经关闭的媒体会话状态。
   *
   * @param generation 当前会话操作代次。
   */
  private resetClosedSessionState(generation: number): void {
    if (generation !== this.generation) {
      return
    }
    this.metadata = null
    this.durationMs = 0
    this.elapsedTimeMs = 0
    this.playbackStartedAtMs = 0
  }
}
