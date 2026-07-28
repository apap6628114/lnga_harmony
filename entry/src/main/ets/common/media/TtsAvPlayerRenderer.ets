import { audio } from '@kit.AudioKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { fileIo } from '@kit.CoreFileKit'
import { common } from '@kit.AbilityKit'
import { media } from '@kit.MediaKit'
import {
  TtsAudioEnqueueResult,
  TtsWavFileSource,
  TtsWavFileWriter
} from './TtsWavFileWriter'
import { textToSpeech } from '@kit.CoreSpeechKit'
import { DOMAIN_MEDIA, formatError, Logger } from '../utils/Logger'

const logger: Logger = new Logger(DOMAIN_MEDIA, 'TtsAvPlayerRenderer')
const PLAYER_INITIALIZATION_TIMEOUT_MS: number = 15000

/**
 * AVPlayer 收到的音频焦点中断操作。
 */
export enum TtsAudioInterruptionAction {
  /** 暂时失去音频焦点，焦点恢复后允许自动续播。 */
  PAUSE = 0,
  /** 永久失去音频焦点，当前朗读应暂停并等待用户主动续播。 */
  STOP = 1,
  /** 暂时中断已经结束。 */
  RESUME = 2
}

/**
 * AVPlayer 上报给播放协调层的音频焦点中断。
 */
export interface TtsAudioInterruptionEvent {
  /** 中断所属的朗读任务代次。 */
  generation: number
  /** 系统建议执行的操作。 */
  action: TtsAudioInterruptionAction
  /** 播放器操作是否已经由系统强制执行。 */
  systemApplied: boolean
}

/**
 * TTS AVPlayer 播放层回调。
 */
export interface TtsAvPlayerRendererCallbacks {
  /** WAV 媒体准备完成时返回是否应立即开始播放。 */
  onReady: (generation: number, durationMs: number) => Promise<boolean>
  /** AVPlayer 真正进入播放状态时通知上层。 */
  onPlaying: (generation: number, durationMs: number, positionMs: number) => void
  /** AVPlayer 上报真实播放位置时通知上层。 */
  onPositionChanged: (generation: number, positionMs: number, durationMs: number) => void
  /** WAV 媒体自然播放完成时通知上层。 */
  onCompleted: (generation: number) => void
  /** 播放链路发生不可恢复异常时通知上层。 */
  onError: (generation: number, error: Object) => void
  /** 音频焦点发生变化时通知上层。 */
  onAudioInterruption: (event: TtsAudioInterruptionEvent) => void
  /** 当前音频输出设备不可用时通知上层。 */
  onOutputDeviceUnavailable: (generation: number) => void
}

/**
 * 单个 AVPlayer 实例注册的监听器集合。
 */
interface TtsAvPlayerListeners {
  /** 播放器状态监听器。 */
  stateChange: (state: media.AVPlayerState, reason: media.StateChangeReason) => void
  /** 播放位置监听器。 */
  timeUpdate: (positionMs: number) => void
  /** 定位完成监听器。 */
  seekDone: (positionMs: number) => void
  /** 音频焦点中断监听器。 */
  audioInterrupt: (event: audio.InterruptEvent) => void
  /** 音频输出设备变化监听器。 */
  outputDeviceChange: (event: audio.AudioStreamDeviceChangeInfo) => void
  /** 播放器错误监听器。 */
  error: (error: BusinessError) => void
}

/**
 * 由唯一状态监听器完成的 AVPlayer 初始化等待器。
 */
interface TtsAvPlayerInitializationWaiter {
  /** AVPlayer 初始化结束后返回错误对象或 null 的等待任务。 */
  promise: Promise<Object | null>
  /** 以成功或错误结果结束初始化等待任务。 */
  settle: (error: Object | null) => void
  /** 初始化等待任务是否已经结束。 */
  settled: boolean
  /** 初始化超时定时器标识。 */
  timeoutId: number
}

/**
 * 使用可定位 WAV 文件和 AVPlayer 播放完整 TTS 音频。
 */
export class TtsAvPlayerRenderer {
  /** 播放层业务回调。 */
  private readonly callbacks: TtsAvPlayerRendererCallbacks
  /** PCM 到临时 WAV 文件的写入器。 */
  private readonly wavWriter: TtsWavFileWriter
  /** 当前朗读任务代次。 */
  private generation: number = -1
  /** 当前 AVPlayer。 */
  private player: media.AVPlayer | null = null
  /** 当前 AVPlayer 监听器集合。 */
  private listeners: TtsAvPlayerListeners | null = null
  /** 当前 AVPlayer 使用的 WAV 文件。 */
  private source: TtsWavFileSource | null = null
  /** 当前音频时长，单位为毫秒。 */
  private durationMs: number = 0
  /** 当前播放位置，单位为毫秒。 */
  private positionMs: number = 0
  /** 已经上报自然完成事件的任务代次。 */
  private completedGeneration: number = -1
  /** 已经上报不可恢复错误的任务代次。 */
  private errorGeneration: number = -1
  /** 当前播放周期是否已经向协调层确认 playing 状态。 */
  private playingNotified: boolean = false
  /** 当前尚未完成的 AVPlayer 初始化等待器。 */
  private initializationWaiter: TtsAvPlayerInitializationWaiter | null = null

  /**
   * 创建 TTS AVPlayer 播放层。
   *
   * @param callbacks 播放层业务回调。
   */
  constructor(callbacks: TtsAvPlayerRendererCallbacks) {
    this.callbacks = callbacks
    this.wavWriter = new TtsWavFileWriter({
      onError: (generation: number, error: Object): void => {
        this.reportError(generation, error)
      }
    })
  }

  /**
   * 初始化临时媒体文件所需的 Ability 上下文。
   *
   * @param context UIAbility 上下文。
   */
  initialize(context: common.UIAbilityContext): void {
    this.wavWriter.initialize(context.cacheDir)
  }

  /**
   * 开始接收一次完整朗读任务的 PCM 数据。
   *
   * @param generation 当前朗读任务代次。
   * @returns 临时媒体文件是否创建成功。
   */
  async begin(generation: number): Promise<boolean> {
    this.stop()
    this.generation = generation
    this.completedGeneration = -1
    this.errorGeneration = -1
    this.playingNotified = false
    const started: boolean = await this.wavWriter.begin(generation)
    return started && generation === this.generation
  }

  /**
   * 记录并校验 TTS 返回的 PCM 格式。
   *
   * @param response PCM 格式信息。
   * @param generation 当前朗读任务代次。
   * @returns 格式是否受支持且属于当前任务。
   */
  prepare(response: textToSpeech.StartResponse, generation: number): boolean {
    return generation === this.generation &&
      this.wavWriter.prepare(response, generation)
  }

  /**
   * 将一段 PCM 数据加入临时 WAV 文件写入队列。
   *
   * @param buffer PCM 数据。
   * @param generation 当前朗读任务代次。
   * @returns 数据入队结果。
   */
  enqueue(buffer: ArrayBuffer, generation: number): TtsAudioEnqueueResult {
    if (generation !== this.generation) {
      return TtsAudioEnqueueResult.INACTIVE
    }
    return this.wavWriter.enqueue(buffer, generation)
  }

  /**
   * 完成 WAV 文件并创建可定位的 AVPlayer。
   *
   * @param generation 当前朗读任务代次。
   */
  async complete(generation: number): Promise<void> {
    const source: TtsWavFileSource | null = await this.wavWriter.finalize(generation)
    if (source === null) {
      return
    }
    if (generation !== this.generation) {
      await this.releaseSource(source)
      return
    }
    let player: media.AVPlayer | null = null
    let initializationWaiter: TtsAvPlayerInitializationWaiter | null = null
    try {
      player = await media.createAVPlayer()
      if (generation !== this.generation) {
        await this.releasePlayerAndSource(player, null, source)
        return
      }
      initializationWaiter = this.createInitializationWaiter()
      this.initializationWaiter = initializationWaiter
      const listeners: TtsAvPlayerListeners =
        this.createListeners(player, generation, initializationWaiter)
      this.player = player
      this.listeners = listeners
      this.source = source
      this.registerListeners(player, listeners)
      const descriptor: media.AVFileDescriptor = {
        fd: source.file.fd,
        offset: 0,
        length: source.fileSize
      }
      player.fdSrc = descriptor
      const initializationError: Object | null =
        await initializationWaiter.promise
      if (initializationError !== null) {
        throw new Error(formatError(initializationError))
      }
      if (!this.isCurrentPlayer(player, generation)) {
        return
      }
      player.audioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_AUDIOBOOK,
        rendererFlags: 0
      }
      await player.prepare()
      if (!this.isCurrentPlayer(player, generation)) {
        return
      }
      player.audioInterruptMode = audio.InterruptMode.SHARE_MODE
      this.durationMs = player.duration > 0 ? player.duration : source.durationMs
      this.positionMs = 0
      logger.info(
        'TTS AVPlayer prepared: duration=%{public}dms, bytes=%{public}d',
        this.durationMs,
        source.fileSize
      )
      const shouldPlay: boolean =
        await this.callbacks.onReady(generation, this.durationMs)
      if (shouldPlay && this.isCurrentPlayer(player, generation)) {
        await player.play()
        this.notifyPlaying(player, generation)
      }
    } catch (error) {
      if (initializationWaiter !== null) {
        this.failInitializationWaiter(initializationWaiter, error)
      }
      if (player !== null && this.player === player) {
        this.stop()
      } else if (player === null) {
        await this.releaseSource(source)
      }
      throw new Error(formatError(error))
    }
  }

  /**
   * 暂停当前 AVPlayer。
   *
   * @returns 当前媒体是否已经处于可恢复的暂停状态。
   */
  async pause(): Promise<boolean> {
    const player: media.AVPlayer | null = this.player
    const generation: number = this.generation
    if (player === null || generation < 0) {
      return false
    }
    if (player.state === 'prepared' || player.state === 'paused') {
      this.playingNotified = false
      return true
    }
    if (player.state !== 'playing') {
      return false
    }
    try {
      await player.pause()
    } catch (error) {
      throw new Error(formatError(error))
    }
    this.playingNotified = false
    return this.isCurrentPlayer(player, generation)
  }

  /**
   * 恢复当前 AVPlayer。
   *
   * @returns 当前媒体是否已经开始或请求开始播放。
   */
  async resume(): Promise<boolean> {
    const player: media.AVPlayer | null = this.player
    const generation: number = this.generation
    if (player === null || generation < 0) {
      return false
    }
    if (player.state === 'playing') {
      this.notifyPlaying(player, generation)
      return true
    }
    if (player.state === 'stopped') {
      try {
        await player.prepare()
      } catch (error) {
        throw new Error(formatError(error))
      }
      if (!this.isCurrentPlayer(player, generation)) {
        return false
      }
    }
    const replayingCompletedMedia: boolean =
      player.state === 'completed' || this.completedGeneration === generation
    if (player.state !== 'prepared' &&
      player.state !== 'paused' &&
      player.state !== 'completed') {
      return false
    }
    if (replayingCompletedMedia) {
      this.completedGeneration = -1
      this.playingNotified = false
    }
    try {
      await player.play()
    } catch (error) {
      throw new Error(formatError(error))
    }
    this.notifyPlaying(player, generation)
    return this.isCurrentPlayer(player, generation)
  }

  /**
   * 将当前媒体定位到指定毫秒位置。
   *
   * @param positionMs 目标位置，单位为毫秒。
   * @returns 是否已经提交定位请求。
   */
  seek(positionMs: number): boolean {
    const player: media.AVPlayer | null = this.player
    const generation: number = this.generation
    if (player === null || generation < 0 || this.durationMs <= 0) {
      return false
    }
    if (player.state !== 'prepared' &&
      player.state !== 'playing' &&
      player.state !== 'paused' &&
      player.state !== 'completed') {
      return false
    }
    const targetMs: number =
      Math.max(0, Math.min(Math.round(positionMs), this.durationMs))
    try {
      player.seek(targetMs, media.SeekMode.SEEK_CLOSEST)
    } catch (error) {
      throw new Error(formatError(error))
    }
    this.positionMs = targetMs
    this.callbacks.onPositionChanged(generation, targetMs, this.durationMs)
    return true
  }

  /**
   * 查询当前媒体位置。
   *
   * @returns 当前播放位置，单位为毫秒。
   */
  getPosition(): number {
    return this.positionMs
  }

  /**
   * 查询当前媒体时长。
   *
   * @returns 当前媒体时长，单位为毫秒。
   */
  getDuration(): number {
    return this.durationMs
  }

  /**
   * 执行共享型音频焦点事件中尚未由系统执行的操作。
   *
   * @param action 音频焦点中断操作。
   * @param generation 当前朗读任务代次。
   * @returns 操作是否应用于当前 AVPlayer。
   */
  async applySharedInterruption(
    action: TtsAudioInterruptionAction,
    generation: number
  ): Promise<boolean> {
    const player: media.AVPlayer | null = this.player
    if (player === null || !this.isCurrentPlayer(player, generation)) {
      return false
    }
    if (action === TtsAudioInterruptionAction.PAUSE ||
      action === TtsAudioInterruptionAction.STOP) {
      return this.pause()
    }
    return false
  }

  /**
   * 立即使当前任务失效，并异步释放 AVPlayer、文件句柄和临时文件。
   */
  stop(): void {
    const player: media.AVPlayer | null = this.player
    const listeners: TtsAvPlayerListeners | null = this.listeners
    const source: TtsWavFileSource | null = this.source
    const initializationWaiter: TtsAvPlayerInitializationWaiter | null =
      this.initializationWaiter
    if (initializationWaiter !== null) {
      this.failInitializationWaiter(
        initializationWaiter,
        new Error('AVPlayer initialization was cancelled')
      )
    }
    this.generation = -1
    this.player = null
    this.listeners = null
    this.source = null
    this.durationMs = 0
    this.positionMs = 0
    this.completedGeneration = -1
    this.errorGeneration = -1
    this.playingNotified = false
    this.wavWriter.discard().catch((error: Object): void => {
      logger.warn('Discard temporary TTS WAV failed: %{public}s', formatError(error))
    })
    if (player !== null || source !== null) {
      this.releasePlayerAndSource(player, listeners, source)
        .catch((error: Object): void => {
          logger.warn('Release stopped TTS AVPlayer failed: %{public}s', formatError(error))
        })
    }
  }

  /**
   * 释放 Ability 级播放资源。
   */
  shutdown(): void {
    this.stop()
    this.wavWriter.initialize('')
  }

  /**
   * 创建绑定到指定播放器和任务代次的监听器。
   *
   * @param player AVPlayer 实例。
   * @param generation 当前朗读任务代次。
   * @returns 播放器监听器集合。
   */
  private createListeners(
    player: media.AVPlayer,
    generation: number,
    initializationWaiter: TtsAvPlayerInitializationWaiter
  ): TtsAvPlayerListeners {
    return {
      stateChange: (
        state: media.AVPlayerState,
        reason: media.StateChangeReason
      ): void => {
        this.handleStateChange(
          player,
          generation,
          initializationWaiter,
          state,
          reason
        )
      },
      timeUpdate: (positionMs: number): void => {
        this.handlePositionChanged(player, generation, positionMs)
      },
      seekDone: (positionMs: number): void => {
        this.handlePositionChanged(player, generation, positionMs)
      },
      audioInterrupt: (event: audio.InterruptEvent): void => {
        this.handleAudioInterrupt(player, generation, event)
      },
      outputDeviceChange: (
        event: audio.AudioStreamDeviceChangeInfo
      ): void => {
        this.handleOutputDeviceChange(player, generation, event)
      },
      error: (error: BusinessError): void => {
        this.failInitializationWaiter(initializationWaiter, error)
        this.reportError(generation, error)
      }
    }
  }

  /**
   * 创建由长期状态监听器完成的初始化等待任务。
   *
   * @returns 当前 AVPlayer 的初始化等待器。
   */
  private createInitializationWaiter(): TtsAvPlayerInitializationWaiter {
    const waiter: TtsAvPlayerInitializationWaiter = {
      promise: Promise.resolve(null),
      settle: (_error: Object | null): void => {
      },
      settled: false,
      timeoutId: -1
    }
    waiter.promise = new Promise<Object | null>(
      (
        resolve: (error: Object | null) => void
      ): void => {
        waiter.settle = resolve
      }
    )
    waiter.timeoutId = setTimeout((): void => {
      this.failInitializationWaiter(
        waiter,
        new Error('AVPlayer source initialization timed out')
      )
    }, PLAYER_INITIALIZATION_TIMEOUT_MS)
    return waiter
  }

  /**
   * 完成指定 AVPlayer 初始化等待任务。
   *
   * @param waiter 待完成的初始化等待器。
   */
  private resolveInitializationWaiter(
    waiter: TtsAvPlayerInitializationWaiter
  ): void {
    if (waiter.settled) {
      return
    }
    waiter.settled = true
    if (waiter.timeoutId >= 0) {
      clearTimeout(waiter.timeoutId)
      waiter.timeoutId = -1
    }
    if (this.initializationWaiter === waiter) {
      this.initializationWaiter = null
    }
    waiter.settle(null)
  }

  /**
   * 以错误结果结束指定 AVPlayer 初始化等待任务。
   *
   * @param waiter 待结束的初始化等待器。
   * @param reason 初始化失败或取消原因。
   */
  private failInitializationWaiter(
    waiter: TtsAvPlayerInitializationWaiter,
    reason: Object
  ): void {
    if (waiter.settled) {
      return
    }
    waiter.settled = true
    if (waiter.timeoutId >= 0) {
      clearTimeout(waiter.timeoutId)
      waiter.timeoutId = -1
    }
    if (this.initializationWaiter === waiter) {
      this.initializationWaiter = null
    }
    waiter.settle(reason)
  }

  /**
   * 注册 AVPlayer 生命周期、进度和焦点监听器。
   *
   * @param player AVPlayer 实例。
   * @param listeners 监听器集合。
   */
  private registerListeners(
    player: media.AVPlayer,
    listeners: TtsAvPlayerListeners
  ): void {
    player.on('stateChange', listeners.stateChange)
    player.on('timeUpdate', listeners.timeUpdate)
    player.on('seekDone', listeners.seekDone)
    player.on('audioInterrupt', listeners.audioInterrupt)
    player.on('audioOutputDeviceChangeWithInfo', listeners.outputDeviceChange)
    player.on('error', listeners.error)
  }

  /**
   * 注销 AVPlayer 监听器。
   *
   * @param player AVPlayer 实例。
   * @param listeners 监听器集合。
   */
  private unregisterListeners(
    player: media.AVPlayer,
    listeners: TtsAvPlayerListeners
  ): void {
    try {
      player.off('stateChange', listeners.stateChange)
      player.off('timeUpdate', listeners.timeUpdate)
      player.off('seekDone', listeners.seekDone)
      player.off('audioInterrupt', listeners.audioInterrupt)
      player.off('audioOutputDeviceChangeWithInfo', listeners.outputDeviceChange)
      player.off('error', listeners.error)
    } catch (error) {
      logger.warn('Unregister TTS AVPlayer listeners failed: %{public}s', formatError(error))
    }
  }

  /**
   * 处理 AVPlayer 状态变化。
   *
   * @param player 上报状态的 AVPlayer。
   * @param generation 监听器绑定的任务代次。
   * @param initializationWaiter 当前 AVPlayer 的初始化等待器。
   * @param state 新状态。
   * @param reason 状态变化原因。
   */
  private handleStateChange(
    player: media.AVPlayer,
    generation: number,
    initializationWaiter: TtsAvPlayerInitializationWaiter,
    state: media.AVPlayerState,
    reason: media.StateChangeReason
  ): void {
    if (!this.isCurrentPlayer(player, generation)) {
      return
    }
    logger.info(
      'TTS AVPlayer state changed: %{public}s, reason=%{public}d',
      state,
      reason
    )
    if (state === 'initialized') {
      this.resolveInitializationWaiter(initializationWaiter)
    } else if (state === 'error' || state === 'released') {
      this.failInitializationWaiter(
        initializationWaiter,
        new Error('AVPlayer source initialization failed: ' + state)
      )
    }
    if (state === 'playing') {
      this.notifyPlaying(player, generation)
    } else if (state === 'prepared' ||
      state === 'paused' ||
      state === 'stopped') {
      this.playingNotified = false
    } else if (state === 'completed') {
      this.playingNotified = false
      this.positionMs = this.durationMs
      this.reportCompleted(generation)
    } else if (state === 'error') {
      this.reportError(generation, new Error('AVPlayer entered the error state'))
    }
  }

  /**
   * 幂等确认 AVPlayer 已进入当前播放周期，并同步给协调层。
   *
   * @param player 已开始播放的 AVPlayer。
   * @param generation 当前朗读任务代次。
   */
  private notifyPlaying(
    player: media.AVPlayer,
    generation: number
  ): void {
    if (!this.isCurrentPlayer(player, generation) || this.playingNotified) {
      return
    }
    this.playingNotified = true
    this.positionMs = Math.max(0, player.currentTime)
    this.callbacks.onPlaying(generation, this.durationMs, this.positionMs)
  }

  /**
   * 处理 AVPlayer 的真实播放位置。
   *
   * @param player 上报位置的 AVPlayer。
   * @param generation 监听器绑定的任务代次。
   * @param positionMs 当前播放位置。
   */
  private handlePositionChanged(
    player: media.AVPlayer,
    generation: number,
    positionMs: number
  ): void {
    if (!this.isCurrentPlayer(player, generation)) {
      return
    }
    const normalizedPosition: number =
      Math.max(0, Math.min(positionMs, this.durationMs))
    this.positionMs = normalizedPosition
    this.callbacks.onPositionChanged(
      generation,
      normalizedPosition,
      this.durationMs
    )
  }

  /**
   * 处理 AVPlayer 音频焦点变化。
   *
   * @param player 收到事件的 AVPlayer。
   * @param generation 监听器绑定的任务代次。
   * @param event 音频焦点事件。
   */
  private handleAudioInterrupt(
    player: media.AVPlayer,
    generation: number,
    event: audio.InterruptEvent
  ): void {
    if (!this.isCurrentPlayer(player, generation)) {
      return
    }
    let action: TtsAudioInterruptionAction | null = null
    if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE) {
      action = TtsAudioInterruptionAction.PAUSE
    } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
      action = TtsAudioInterruptionAction.STOP
    } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
      action = TtsAudioInterruptionAction.RESUME
    }
    if (action === null) {
      return
    }
    logger.info(
      'TTS audio interrupt: event=%{public}d, force=%{public}d, hint=%{public}d',
      event.eventType,
      event.forceType,
      event.hintType
    )
    this.callbacks.onAudioInterruption({
      generation: generation,
      action: action,
      systemApplied: event.forceType === audio.InterruptForceType.INTERRUPT_FORCE
    })
  }

  /**
   * 处理耳机、蓝牙等当前音频输出设备不可用事件。
   *
   * @param player 收到事件的 AVPlayer。
   * @param generation 监听器绑定的任务代次。
   * @param event 音频输出设备变化事件。
   */
  private handleOutputDeviceChange(
    player: media.AVPlayer,
    generation: number,
    event: audio.AudioStreamDeviceChangeInfo
  ): void {
    if (!this.isCurrentPlayer(player, generation) ||
      event.changeReason !==
        audio.AudioStreamDeviceChangeReason.REASON_OLD_DEVICE_UNAVAILABLE) {
      return
    }
    logger.info(
      'TTS audio output device became unavailable: reason=%{public}d',
      event.changeReason
    )
    this.callbacks.onOutputDeviceUnavailable(generation)
  }

  /**
   * 上报当前媒体自然播放完成。
   *
   * @param generation 当前朗读任务代次。
   */
  private reportCompleted(generation: number): void {
    if (generation !== this.generation ||
      this.completedGeneration === generation ||
      this.errorGeneration === generation) {
      return
    }
    this.completedGeneration = generation
    this.callbacks.onCompleted(generation)
  }

  /**
   * 上报当前播放链路的首个不可恢复错误。
   *
   * @param generation 当前朗读任务代次。
   * @param error 错误对象。
   */
  private reportError(generation: number, error: Object): void {
    if (generation !== this.generation || this.errorGeneration === generation) {
      return
    }
    this.errorGeneration = generation
    this.callbacks.onError(generation, error)
  }

  /**
   * 判断播放器和任务代次是否仍为当前活动实例。
   *
   * @param player 待判断 AVPlayer。
   * @param generation 待判断任务代次。
   * @returns 是否为当前活动播放器。
   */
  private isCurrentPlayer(
    player: media.AVPlayer,
    generation: number
  ): boolean {
    return this.player === player && this.generation === generation
  }

  /**
   * 释放 AVPlayer 及其临时 WAV 文件。
   *
   * @param player 待释放 AVPlayer。
   * @param listeners 已注册监听器。
   * @param source 待释放媒体文件。
   */
  private async releasePlayerAndSource(
    player: media.AVPlayer | null,
    listeners: TtsAvPlayerListeners | null,
    source: TtsWavFileSource | null
  ): Promise<void> {
    if (player !== null) {
      if (listeners !== null) {
        this.unregisterListeners(player, listeners)
      }
      try {
        if (player.state !== 'released') {
          await player.release()
        }
      } catch (error) {
        logger.warn('Release TTS AVPlayer failed: %{public}s', formatError(error))
      }
    }
    if (source !== null) {
      await this.releaseSource(source)
    }
  }

  /**
   * 关闭 WAV 只读句柄并删除临时文件。
   *
   * @param source 待释放 WAV 文件。
   */
  private async releaseSource(source: TtsWavFileSource): Promise<void> {
    try {
      await fileIo.close(source.file)
    } catch (error) {
      logger.warn('Close TTS WAV source failed: %{public}s', formatError(error))
    }
    try {
      await fileIo.unlink(source.path)
    } catch (error) {
      logger.warn('Delete TTS WAV source failed: %{public}s', formatError(error))
    }
  }
}
