import { common, wantAgent, WantAgent } from '@kit.AbilityKit'
import { avSession } from '@kit.AVSessionKit'
import { DOMAIN_MEDIA, formatError, Logger } from '../utils/Logger'

const AV_SESSION_REQUEST_CODE: number = 23002
const AV_SESSION_TAG: string = 'NgaPostTts'
const POSITION_SYNC_INTERVAL_MS: number = 1000
const MAX_STATE_SYNC_ATTEMPTS: number = 3
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
  /** 请求定位到指定播放位置。 */
  onSeek: (positionMs: number) => void
  /** 请求向前跳过系统媒体卡片指定的间隔。 */
  onFastForward: (intervalSeconds?: number) => void
  /** 请求向后跳过系统媒体卡片指定的间隔。 */
  onRewind: (intervalSeconds?: number) => void
}

/**
 * 一次不可变的系统媒体会话播放状态。
 */
interface TtsAvSessionPlaybackSnapshot {
  /** 系统媒体播放状态。 */
  state: avSession.PlaybackState
  /** 生成快照时的精确播放位置，单位为毫秒。 */
  positionMs: number
  /** 当前媒体总时长，单位为毫秒。 */
  durationMs: number
  /** 生成快照的系统时间，单位为毫秒。 */
  updateTimeMs: number
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
  /** 当前系统媒体会话是否已经激活。 */
  private sessionActivated: boolean = false
  /** 当前媒体元数据。 */
  private metadata: TtsMediaMetadata | null = null
  /** 当前媒体总时长，单位为毫秒。 */
  private durationMs: number = 0
  /** 当前媒体已播放时长，单位为毫秒。 */
  private elapsedTimeMs: number = 0
  /** 最近一次进入播放状态的时间。 */
  private playbackStartedAtMs: number = 0
  /** 最近一次向系统同步精确播放位置的时间。 */
  private lastPositionSyncAtMs: number = 0
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
  /** 最新待同步播放状态的版本。 */
  private stateUpdateRevision: number = 0
  /** 是否已经安排最新播放状态同步任务。 */
  private stateSynchronizationScheduled: boolean = false
  /** 当前媒体元数据是否需要重新同步。 */
  private metadataDirty: boolean = false

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

  /** 响应系统进度定位命令。 */
  private readonly seekCallback = (positionMs: number): void => {
    this.callbacks.onSeek(positionMs)
  }

  /** 响应系统快进命令。 */
  private readonly fastForwardCallback = (intervalSeconds?: number): void => {
    this.callbacks.onFastForward(intervalSeconds)
  }

  /** 响应系统快退命令。 */
  private readonly rewindCallback = (intervalSeconds?: number): void => {
    this.callbacks.onRewind(intervalSeconds)
  }

  /** 将系统上一条命令兼容映射为向后跳过默认间隔。 */
  private readonly playPreviousCallback = (): void => {
    this.callbacks.onRewind()
  }

  /** 将系统下一条命令兼容映射为向前跳过默认间隔。 */
  private readonly playNextCallback = (): void => {
    this.callbacks.onFastForward()
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
   *
   * @returns 当前媒体会话是否成功创建并激活。
   */
  start(metadata: TtsMediaMetadata): Promise<boolean> {
    const generation: number = ++this.generation
    this.metadata = metadata
    this.durationMs = 0
    this.elapsedTimeMs = 0
    this.playbackStartedAtMs = 0
    this.lastPositionSyncAtMs = 0
    this.playbackState = avSession.PlaybackState.PLAYBACK_STATE_PREPARE
    this.activeRequested = true
    this.stateUpdateRevision++
    this.metadataDirty = true
    const activationOperation: Promise<void> = this.enqueue(async (): Promise<void> => {
      await this.activate(generation)
    })
    return activationOperation.then((): boolean => {
      return this.isCurrentActiveGeneration(generation) &&
        this.session !== null &&
        this.sessionActivated
    })
  }

  /**
   * 将当前朗读同步为播放状态。
   *
   * @param durationMs 当前媒体总时长，单位为毫秒。
   * @param positionMs 当前播放位置，单位为毫秒。
   */
  setPlaying(durationMs: number, positionMs: number = this.elapsedTimeMs): void {
    if (!this.activeRequested) {
      return
    }
    this.durationMs = Math.max(0, durationMs)
    this.elapsedTimeMs = this.clampPosition(positionMs)
    this.playbackStartedAtMs = Date.now()
    this.playbackState = avSession.PlaybackState.PLAYBACK_STATE_PLAY
    this.enqueueStateUpdate(this.generation, true)
  }

  /**
   * 将当前朗读同步为暂停状态。
   *
   * @param durationMs 已知的媒体总时长，单位为毫秒。
   * @param positionMs 当前播放位置，单位为毫秒。
   */
  setPaused(durationMs?: number, positionMs?: number): void {
    if (!this.activeRequested) {
      return
    }
    const updateMetadata: boolean = durationMs !== undefined
    if (durationMs !== undefined) {
      this.durationMs = Math.max(0, durationMs)
    }
    this.elapsedTimeMs = positionMs === undefined
      ? this.resolveElapsedTime()
      : this.clampPosition(positionMs)
    this.playbackStartedAtMs = 0
    this.playbackState = avSession.PlaybackState.PLAYBACK_STATE_PAUSE
    this.enqueueStateUpdate(this.generation, updateMetadata)
  }

  /**
   * 将自然完成的朗读同步为可定位、可重播的卡片暂停状态。
   *
   * 系统媒体卡片会将 PLAYBACK_STATE_COMPLETED 继续渲染为暂停按钮，
   * 因此使用官方示例采用的暂停状态表达“等待用户再次播放”。
   *
   * @param durationMs 当前媒体总时长，单位为毫秒。
   * @param positionMs 当前播放位置，单位为毫秒。
   */
  setReplayReady(
    durationMs: number,
    positionMs: number = durationMs
  ): void {
    if (!this.activeRequested) {
      return
    }
    const normalizedDurationMs: number = Math.max(0, durationMs)
    const updateMetadata: boolean = normalizedDurationMs !== this.durationMs
    this.durationMs = normalizedDurationMs
    this.elapsedTimeMs = this.clampPosition(positionMs)
    this.playbackStartedAtMs = 0
    this.playbackState = avSession.PlaybackState.PLAYBACK_STATE_PAUSE
    this.enqueueStateUpdate(this.generation, updateMetadata)
  }

  /**
   * 将尚未开始输出声音的朗读重新同步为准备状态。
   *
   * @param durationMs 已知的媒体总时长，单位为毫秒。
   */
  setPreparing(durationMs?: number): void {
    if (!this.activeRequested) {
      return
    }
    const updateMetadata: boolean = durationMs !== undefined
    if (durationMs !== undefined) {
      this.durationMs = Math.max(0, durationMs)
    }
    this.elapsedTimeMs = this.clampPosition(this.elapsedTimeMs)
    this.playbackStartedAtMs = 0
    this.playbackState = avSession.PlaybackState.PLAYBACK_STATE_PREPARE
    this.enqueueStateUpdate(this.generation, updateMetadata)
  }

  /**
   * 使用 AVPlayer 的真实位置刷新系统媒体卡片。
   *
   * @param positionMs 当前播放位置，单位为毫秒。
   * @param durationMs 当前媒体时长，单位为毫秒。
   * @param force 是否忽略节流并立即同步。
   */
  setPosition(
    positionMs: number,
    durationMs?: number,
    force: boolean = false
  ): void {
    if (!this.activeRequested) {
      return
    }
    const updateMetadata: boolean =
      durationMs !== undefined && Math.max(0, durationMs) !== this.durationMs
    if (durationMs !== undefined) {
      this.durationMs = Math.max(0, durationMs)
    }
    this.elapsedTimeMs = this.clampPosition(positionMs)
    if (this.playbackState === avSession.PlaybackState.PLAYBACK_STATE_PLAY) {
      this.playbackStartedAtMs = Date.now()
    }
    const now: number = Date.now()
    if (!force && now - this.lastPositionSyncAtMs < POSITION_SYNC_INTERVAL_MS) {
      return
    }
    this.lastPositionSyncAtMs = now
    this.enqueueStateUpdate(this.generation, updateMetadata)
  }

  /**
   * 停止当前系统媒体会话。
   */
  stop(): void {
    const generation: number = ++this.generation
    this.elapsedTimeMs = this.resolveElapsedTime()
    this.playbackStartedAtMs = 0
    this.playbackState = avSession.PlaybackState.PLAYBACK_STATE_STOP
    this.activeRequested = false
    this.stateUpdateRevision++
    this.metadataDirty = false
    const snapshot: TtsAvSessionPlaybackSnapshot =
      this.capturePlaybackSnapshot()
    this.enqueue(async (): Promise<void> => {
      await this.closeSession(generation, snapshot)
    })
  }

  /**
   * 销毁系统媒体会话并释放 Ability 级资源。
   */
  shutdown(): void {
    const generation: number = ++this.generation
    const lifecycleGeneration: number = ++this.lifecycleGeneration
    this.activeRequested = false
    this.stateUpdateRevision++
    this.metadataDirty = false
    this.playbackStartedAtMs = 0
    this.playbackState = avSession.PlaybackState.PLAYBACK_STATE_RELEASED
    const snapshot: TtsAvSessionPlaybackSnapshot =
      this.capturePlaybackSnapshot()
    this.enqueue(async (): Promise<void> => {
      await this.closeSession(
        generation,
        snapshot,
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
   * @returns 当前媒体会话操作链。
   */
  private enqueue(task: () => Promise<void>): Promise<void> {
    this.operation = this.operation.then(task).catch((error: Object): void => {
      logger.error('Synchronize TTS AVSession failed: %{public}s', formatError(error))
    })
    return this.operation
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
      if (!this.sessionActivated) {
        await session.activate()
        this.sessionActivated = true
      }
    } catch (error) {
      logger.error('Activate TTS AVSession failed: %{public}s', formatError(error))
      if (this.isCurrentActiveGeneration(generation) && this.session === session) {
        this.session = null
        this.sessionActivated = false
        await this.releaseSessionInstance(session)
      }
      return
    }
    if (!this.isCurrentActiveGeneration(generation)) {
      return
    }
    const snapshot: TtsAvSessionPlaybackSnapshot =
      this.capturePlaybackSnapshot()
    const metadataRevision: number = this.stateUpdateRevision
    try {
      await session.setAVMetadata(this.buildMetadata(metadata, snapshot.durationMs))
      if (this.isCurrentActiveGeneration(generation) &&
        metadataRevision === this.stateUpdateRevision) {
        this.metadataDirty = false
      }
    } catch (error) {
      this.metadataDirty = true
      logger.warn('Set initial TTS AVSession metadata failed: %{public}s', formatError(error))
    }
    if (!this.isCurrentActiveGeneration(generation)) {
      return
    }
    try {
      await session.setAVPlaybackState(this.buildPlaybackState(snapshot))
    } catch (error) {
      logger.warn('Set initial TTS AVSession state failed: %{public}s', formatError(error))
    }
    logger.info('TTS AVSession activated')
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
      session.on('seek', this.seekCallback)
      session.on('fastForward', this.fastForwardCallback)
      session.on('rewind', this.rewindCallback)
      session.on('playPrevious', this.playPreviousCallback)
      session.on('playNext', this.playNextCallback)
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
      logger.warn('Set TTS AVSession launch ability failed: %{public}s', formatError(error))
    }
  }

  /**
   * 将当前媒体信息转换为 AVSession 元数据。
   *
   * @param metadata 当前媒体信息。
   * @param durationMs 当前媒体总时长，单位为毫秒。
   * @returns 系统媒体会话元数据。
   */
  private buildMetadata(
    metadata: TtsMediaMetadata,
    durationMs: number
  ): avSession.AVMetadata {
    return {
      assetId: metadata.assetId,
      title: metadata.title,
      artist: metadata.artist,
      album: metadata.album,
      duration: durationMs,
      skipIntervals: avSession.SkipIntervals.SECONDS_15
    }
  }

  /**
   * 将播放快照转换为系统媒体会话播放状态。
   *
   * @param snapshot 待发布的不可变播放快照。
   * @returns 系统媒体会话播放状态。
   */
  private buildPlaybackState(
    snapshot: TtsAvSessionPlaybackSnapshot
  ): avSession.AVPlaybackState {
    return {
      state: snapshot.state,
      speed: 1,
      position: {
        elapsedTime: snapshot.positionMs,
        updateTime: snapshot.updateTimeMs
      },
      bufferedTime: snapshot.durationMs,
      duration: snapshot.durationMs
    }
  }

  /**
   * 捕获当前播放状态，避免异步队列执行时读取到后续状态。
   *
   * @returns 当前不可变播放快照。
   */
  private capturePlaybackSnapshot(): TtsAvSessionPlaybackSnapshot {
    return {
      state: this.playbackState,
      positionMs: this.resolveElapsedTime(),
      durationMs: this.durationMs,
      updateTimeMs: Date.now()
    }
  }

  /**
   * 排队同步当前媒体会话状态。
   *
   * @param generation 当前会话操作代次。
   * @param updateMetadata 是否同时更新包含总时长的媒体元数据。
   */
  private enqueueStateUpdate(generation: number, updateMetadata: boolean): void {
    if (!this.isCurrentActiveGeneration(generation)) {
      return
    }
    this.stateUpdateRevision++
    this.metadataDirty = this.metadataDirty || updateMetadata
    this.scheduleStateSynchronization()
  }

  /**
   * 确保系统操作队列中最多存在一个最新状态同步任务。
   */
  private scheduleStateSynchronization(): void {
    if (this.stateSynchronizationScheduled || !this.activeRequested) {
      return
    }
    this.stateSynchronizationScheduled = true
    this.enqueue(async (): Promise<void> => {
      await this.synchronizeLatestState()
    })
  }

  /**
   * 丢弃过期快照并将 AVSession 收敛到最新业务状态。
   */
  private async synchronizeLatestState(): Promise<void> {
    let synchronizedRevision: number = -1
    try {
      let attempt: number = 0
      while (this.activeRequested) {
        const generation: number = this.generation
        const revision: number = this.stateUpdateRevision
        synchronizedRevision = revision
        const session: avSession.AVSession | null = this.session
        if (!this.isCurrentActiveGeneration(generation) || session === null) {
          return
        }
        const snapshot: TtsAvSessionPlaybackSnapshot =
          this.capturePlaybackSnapshot()
        const currentMetadata: TtsMediaMetadata | null = this.metadata
        const shouldUpdateMetadata: boolean =
          this.metadataDirty && currentMetadata !== null
        let metadataSynchronized: boolean = !shouldUpdateMetadata
        if (shouldUpdateMetadata && currentMetadata !== null) {
          try {
            await session.setAVMetadata(
              this.buildMetadata(currentMetadata, snapshot.durationMs)
            )
            metadataSynchronized = true
          } catch (error) {
            logger.warn('Set TTS AVSession metadata failed: %{public}s', formatError(error))
          }
        }
        if (!this.isCurrentActiveGeneration(generation)) {
          return
        }
        let playbackStateSynchronized: boolean = false
        try {
          await session.setAVPlaybackState(this.buildPlaybackState(snapshot))
          playbackStateSynchronized = true
        } catch (error) {
          logger.warn('Set TTS AVSession playback state failed: %{public}s', formatError(error))
        }
        if (!this.isCurrentActiveGeneration(generation)) {
          return
        }
        if (revision !== this.stateUpdateRevision) {
          attempt = 0
          continue
        }
        if (metadataSynchronized) {
          this.metadataDirty = false
        }
        if (metadataSynchronized && playbackStateSynchronized) {
          return
        }
        attempt++
        if (attempt >= MAX_STATE_SYNC_ATTEMPTS) {
          logger.warn(
            'TTS AVSession state did not converge after %{public}d attempts',
            MAX_STATE_SYNC_ATTEMPTS
          )
          return
        }
      }
    } finally {
      this.stateSynchronizationScheduled = false
      if (this.activeRequested &&
        synchronizedRevision !== this.stateUpdateRevision) {
        this.scheduleStateSynchronization()
      }
    }
  }

  /**
   * 更新终止状态并销毁当前系统媒体会话。
   *
   * @param generation 当前会话操作代次。
   * @param snapshot 会话关闭前同步的终止状态快照。
   * @param force 是否忽略播放代次并强制释放旧 Ability 的会话。
   */
  private async closeSession(
    generation: number,
    snapshot: TtsAvSessionPlaybackSnapshot,
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
    this.sessionActivated = false
    try {
      await session.setAVPlaybackState(this.buildPlaybackState(snapshot))
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
      session.off('seek', this.seekCallback)
      session.off('fastForward', this.fastForwardCallback)
      session.off('rewind', this.rewindCallback)
      session.off('playPrevious', this.playPreviousCallback)
      session.off('playNext', this.playNextCallback)
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
   * 将播放位置约束在当前媒体有效范围内。
   *
   * @param positionMs 待约束的位置。
   * @returns 有效播放位置，单位为毫秒。
   */
  private clampPosition(positionMs: number): number {
    const normalizedPosition: number = Math.max(0, Math.round(positionMs))
    if (this.durationMs <= 0) {
      return normalizedPosition
    }
    return Math.min(normalizedPosition, this.durationMs)
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
    this.metadataDirty = false
    this.durationMs = 0
    this.elapsedTimeMs = 0
    this.playbackStartedAtMs = 0
    this.lastPositionSyncAtMs = 0
  }
}
