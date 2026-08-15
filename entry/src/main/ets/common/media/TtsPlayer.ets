import { common } from '@kit.AbilityKit'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { textToSpeech } from '@kit.CoreSpeechKit'
import { appStore } from '../../store/AppStore'
import {
  TtsAvSessionController,
  TtsMediaMetadata
} from './TtsAvSessionController'
import { TtsBackgroundTaskController } from './TtsBackgroundTaskController'
import {
  TtsAudioInterruptionAction,
  TtsAudioInterruptionEvent,
  TtsAvPlayerRenderer
} from './TtsAvPlayerRenderer'
import { TtsAudioEnqueueResult } from './TtsWavFileWriter'
import { ttsProgress } from './TtsProgress'
import { splitText } from './TtsTextChunker'
import { isVoiceNotDownloadedError, shouldReleaseEngineOnError } from './TtsErrorMessages'
import { DOMAIN_MEDIA, formatError, Logger } from '../utils/Logger'

const SYSTEM_SKIP_INTERVAL_MS: number = 15000
/** 估算每字符 PCM 字节数：16kHz/16bit 单声道约 32000B/s，中文朗读约 5 字符/s（对语速设置不敏感，属估算固有误差）。 */
const ESTIMATED_BYTES_PER_CHAR: number = 6400
/** 每字符 PCM 字节数校准下限（对应语速上限场景）。 */
const MIN_BYTES_PER_CHAR: number = 3200
/** 每字符 PCM 字节数校准上限。 */
const MAX_BYTES_PER_CHAR: number = 12800
const logger: Logger = new Logger(DOMAIN_MEDIA, 'TtsPlayer')

/**
 * 协调层持有的唯一朗读播放阶段。
 */
enum TtsPlaybackPhase {
  /** 当前没有活动朗读。 */
  IDLE = 0,
  /** 正在合成或准备媒体，准备完成后应自动播放。 */
  PREPARING = 1,
  /** 当前期望 AVPlayer 和系统媒体卡片保持播放。 */
  PLAYING = 2,
  /** 当前期望 AVPlayer 和系统媒体卡片保持暂停。 */
  PAUSED = 3,
  /** 当前媒体已自然播放完成，并保留可定位和重播能力。 */
  COMPLETED = 4
}

/**
 * 协调 TTS 引擎、AVPlayer、系统播控和后台长时任务的完整生命周期。
 */
class TtsPlaybackCoordinator {
  /** 当前 TTS 引擎。 */
  private engine: textToSpeech.TextToSpeechEngine | null = null
  /** 当前引擎对应的音色。 */
  private enginePerson: number = -1
  /** 引擎异步创建代次。 */
  private engineInitializationGeneration: number = 0
  /** 待合成的文本段。 */
  private pendingChunks: string[] = []
  /** 下一段待合成文本的索引。 */
  private chunkIndex: number = 0
  /** 待合成文本的总字符数。 */
  private totalChars: number = 0
  /** 已完成合成的累计字符数。 */
  private completedChars: number = 0
  /** 已接收的累计 PCM 字节数。 */
  private receivedPcmBytes: number = 0
  /** 估算的每字符 PCM 字节数，首段合成完成后按实际比例校准。 */
  private bytesPerChar: number = ESTIMATED_BYTES_PER_CHAR
  /** 上一次发布的合成进度百分比，保证进度单调递增。 */
  private lastSynthesisPercent: number = -1
  /** 当前朗读楼层标识。 */
  private speakingPid: number = -1
  /** 当前朗读任务代次。 */
  private playbackGeneration: number = 0
  /** 当前 TTS 合成请求标识。 */
  private activeRequestId: string = ''
  /** 当前 TTS 合成请求所属任务代次。 */
  private activeRequestGeneration: number = -1
  /** 用于生成唯一请求标识的递增序号。 */
  private requestSequence: number = 0
  /** 当前任务是否允许后台播放。 */
  private backgroundPlaybackEnabled: boolean = false
  /** 已显示后台启动警告的任务代次。 */
  private backgroundWarningGeneration: number = -1
  /** TTS 临时 WAV 文件与 AVPlayer 播放组件。 */
  private readonly audioRenderer: TtsAvPlayerRenderer
  /** 系统媒体播控会话控制器。 */
  private readonly avSessionController: TtsAvSessionController
  /** 音频播放长时任务控制器。 */
  private readonly backgroundTaskController: TtsBackgroundTaskController
  /** 串行化播放、暂停操作的任务链。 */
  private playbackControlOperation: Promise<void> = Promise.resolve()
  /** 当前朗读任务的唯一播放阶段。 */
  private playbackPhase: TtsPlaybackPhase = TtsPlaybackPhase.IDLE
  /** 当前任务的 AVPlayer 是否已经具备播放和定位能力。 */
  private rendererReady: boolean = false
  /** 暂时失去音频焦点后是否应在焦点恢复时自动续播。 */
  private interruptionResumePending: boolean = false
  /** 当前朗读任务创建并激活系统媒体会话的异步结果。 */
  private avSessionActivationOperation: Promise<boolean> = Promise.resolve(false)

  /**
   * 创建 TTS 播放协调器。
   */
  constructor() {
    this.audioRenderer = new TtsAvPlayerRenderer({
      onReady: async (generation: number, durationMs: number): Promise<boolean> => {
        return this.handleAudioReady(generation, durationMs)
      },
      onPlaying: (
        generation: number,
        durationMs: number,
        positionMs: number
      ): void => {
        this.handleAudioPlaying(generation, durationMs, positionMs)
      },
      onPositionChanged: (
        generation: number,
        positionMs: number,
        durationMs: number
      ): void => {
        this.handleAudioPositionChanged(generation, positionMs, durationMs)
      },
      onCompleted: (generation: number): void => {
        this.handleAudioCompleted(generation)
      },
      onError: (generation: number, error: Object): void => {
        this.handleAudioRendererError(generation, error)
      },
      onAudioInterruption: (event: TtsAudioInterruptionEvent): void => {
        this.handleAudioInterruption(event)
      },
      onOutputDeviceUnavailable: (generation: number): void => {
        this.handleOutputDeviceUnavailable(generation)
      }
    })
    this.avSessionController = new TtsAvSessionController({
      onPlay: (): void => {
        this.resume()
      },
      onPause: (): void => {
        this.pause()
      },
      onStop: (): void => {
        this.stop()
      },
      onSeek: (positionMs: number): void => {
        this.seek(positionMs)
      },
      onFastForward: (intervalSeconds?: number): void => {
        this.skipBy(this.resolveSkipIntervalMs(intervalSeconds))
      },
      onRewind: (intervalSeconds?: number): void => {
        this.skipBy(-this.resolveSkipIntervalMs(intervalSeconds))
      }
    })
    this.backgroundTaskController = new TtsBackgroundTaskController({
      onCancelled: (
        info: backgroundTaskManager.ContinuousTaskCancelInfo
      ): void => {
        this.handleBackgroundTaskCancelled(info)
      },
      onSuspended: (
        info: backgroundTaskManager.ContinuousTaskSuspendInfo
      ): void => {
        this.handleBackgroundTaskSuspended(info)
      },
      onActivated: (
        info: backgroundTaskManager.ContinuousTaskActiveInfo
      ): void => {
        this.handleBackgroundTaskActivated(info)
      }
    })
  }

  /**
   * 初始化播放器所需的 UIAbility 上下文。
   *
   * @param context UIAbility 上下文。
   */
  initialize(context: common.UIAbilityContext): void {
    this.audioRenderer.initialize(context)
    this.avSessionController.initialize(context)
    this.backgroundTaskController.initialize(context)
  }

  /**
   * 播放文本；再次点击同一楼层时停止播放。
   *
   * @param text 待朗读文本。
   * @param pid 楼层标识。
   * @param allowBackground 是否允许熄屏或切后台继续朗读。
   * @param metadata 系统播控中心展示的媒体信息。
   */
  speak(
    text: string,
    pid: number,
    allowBackground: boolean,
    metadata?: TtsMediaMetadata
  ): void {
    if (this.speakingPid === pid) {
      if (this.playbackPhase === TtsPlaybackPhase.COMPLETED) {
        this.seek(0)
        this.resume()
        return
      }
      this.stopInternal()
      return
    }
    const normalizedText: string = text.trim()
    this.stopInternal()
    if (normalizedText.length === 0) {
      appStore.showToast('没有可朗读的文字')
      return
    }
    if (this.engine !== null && appStore.settings.ttsPerson !== this.enginePerson) {
      this.releaseEngine()
    }
    this.speakingPid = pid
    this.backgroundPlaybackEnabled = allowBackground
    this.pendingChunks = splitText(normalizedText)
    this.chunkIndex = 0
    this.completedChars = 0
    this.receivedPcmBytes = 0
    this.bytesPerChar = ESTIMATED_BYTES_PER_CHAR
    this.lastSynthesisPercent = -1
    this.totalChars = 0
    for (const chunk of this.pendingChunks) {
      this.totalChars += chunk.length
    }
    this.playbackPhase = TtsPlaybackPhase.PREPARING
    this.rendererReady = false
    this.interruptionResumePending = false
    this.publishSynthesisProgress()
    if (allowBackground) {
      this.avSessionActivationOperation =
        this.avSessionController.start(this.resolveMediaMetadata(pid, metadata))
    } else {
      this.avSessionActivationOperation = Promise.resolve(false)
    }
    const generation: number = this.playbackGeneration
    if (this.engine === null) {
      this.initializeEngine(generation)
      return
    }
    this.beginSynthesis(generation)
  }

  /**
   * 查询指定楼层是否正在朗读。
   *
   * @param pid 楼层标识。
   * @returns 是否正在朗读。
   */
  isSpeaking(pid: number): boolean {
    return this.speakingPid === pid
  }

  /**
   * 停止当前朗读。
   */
  stop(): void {
    this.stopInternal()
  }

  /**
   * 暂停当前正在输出的朗读声音。
   */
  pause(): void {
    const generation: number = this.playbackGeneration
    this.enqueuePlaybackControl(async (): Promise<void> => {
      await this.pauseInternal(generation)
    })
  }

  /**
   * 恢复当前暂停的朗读声音。
   */
  resume(): void {
    const generation: number = this.playbackGeneration
    this.enqueuePlaybackControl(async (): Promise<void> => {
      await this.resumeInternal(generation)
    })
  }

  /**
   * 停止朗读并释放所有 Ability 级资源。
   */
  shutdown(): void {
    this.stopInternal()
    this.releaseEngine()
    this.audioRenderer.shutdown()
    this.avSessionController.shutdown()
    this.backgroundTaskController.shutdown()
  }

  /**
   * 创建并初始化文字转语音引擎。
   *
   * @param generation 当前朗读任务代次。
   */
  private initializeEngine(generation: number): void {
    const requestedPerson: number = appStore.settings.ttsPerson
    const initializationGeneration: number = ++this.engineInitializationGeneration
    const extraParams: Record<string, Object> = {
      'style': 'interaction-broadcast',
      'locate': 'CN'
    }
    const initParams: textToSpeech.CreateEngineParams = {
      language: 'zh-CN',
      online: 1,
      person: requestedPerson,
      extraParams: extraParams
    }
    try {
      textToSpeech.createEngine(
        initParams,
        (error: BusinessError, engine: textToSpeech.TextToSpeechEngine): void => {
          this.handleEngineCreated(
            error,
            engine,
            requestedPerson,
            initializationGeneration,
            generation
          )
        }
      )
    } catch (error) {
      if (this.isCurrentInitialization(initializationGeneration, generation)) {
        this.finishPlayback()
        logger.error('Create TTS engine failed: %{public}s', formatError(error))
        appStore.showToast('语音引擎不可用')
      }
    }
  }

  /**
   * 处理 TTS 引擎异步创建结果。
   *
   * @param error 引擎创建错误。
   * @param engine 新创建的 TTS 引擎。
   * @param requestedPerson 请求使用的音色。
   * @param initializationGeneration 引擎创建代次。
   * @param playbackGeneration 朗读任务代次。
   */
  private handleEngineCreated(
    error: BusinessError,
    engine: textToSpeech.TextToSpeechEngine,
    requestedPerson: number,
    initializationGeneration: number,
    playbackGeneration: number
  ): void {
    if (error) {
      if (!this.isCurrentInitialization(initializationGeneration, playbackGeneration)) {
        return
      }
      this.finishPlayback()
      if (isVoiceNotDownloadedError(error.code)) {
        appStore.showToast('音色未下载，请在设置中下载后使用')
      } else {
        appStore.showToast('语音引擎不可用')
      }
      return
    }
    if (!this.isCurrentInitialization(initializationGeneration, playbackGeneration) ||
      requestedPerson !== appStore.settings.ttsPerson) {
      this.shutdownEngineInstance(engine)
      return
    }
    try {
      this.attachEngineListener(engine)
      this.engine = engine
      this.enginePerson = requestedPerson
      this.beginSynthesis(playbackGeneration)
    } catch (listenerError) {
      this.shutdownEngineInstance(engine)
      this.engine = null
      this.enginePerson = -1
      this.finishPlayback()
      logger.error('Initialize TTS engine listener failed: %{public}s', formatError(listenerError))
      appStore.showToast('语音引擎不可用')
    }
  }

  /**
   * 判断异步引擎创建结果是否仍属于当前朗读任务。
   *
   * @param initializationGeneration 引擎创建代次。
   * @param playbackGeneration 朗读任务代次。
   * @returns 是否仍为当前有效初始化。
   */
  private isCurrentInitialization(
    initializationGeneration: number,
    playbackGeneration: number
  ): boolean {
    return initializationGeneration === this.engineInitializationGeneration &&
      playbackGeneration === this.playbackGeneration &&
      this.speakingPid !== -1
  }

  /**
   * 为 TTS 引擎注册当前协调器的事件监听。
   *
   * @param engine TTS 引擎。
   */
  private attachEngineListener(engine: textToSpeech.TextToSpeechEngine): void {
    const owner: TtsPlaybackCoordinator = this
    engine.setListener({
      /**
       * 接收 TTS 合成开始事件并记录 PCM 格式。
       *
       * @param requestId TTS 请求标识。
       * @param response PCM 格式信息。
       */
      onStart(requestId: string, response: textToSpeech.StartResponse): void {
        owner.handleSynthesisStart(requestId, response)
      },
      /**
       * 接收 TTS 合成完成事件。
       *
       * @param requestId TTS 请求标识。
       * @param response 合成完成信息。
       */
      onComplete(requestId: string, response: textToSpeech.CompleteResponse): void {
        owner.handleSynthesisComplete(requestId, response)
      },
      /**
       * 接收 TTS 合成停止事件。
       *
       * @param requestId TTS 请求标识。
       * @param response 合成停止信息。
       */
      onStop(requestId: string, response: textToSpeech.StopResponse): void {
        owner.handleSynthesisStop(requestId, response)
      },
      /**
       * 保存 TTS 合成产生的 PCM 数据。
       *
       * @param requestId TTS 请求标识。
       * @param pcmData PCM 数据。
       * @param response 合成进度信息。
       */
      onData(
        requestId: string,
        pcmData: ArrayBuffer,
        response: textToSpeech.SynthesisResponse
      ): void {
        owner.handleSynthesisData(requestId, pcmData, response)
      },
      /**
       * 接收 TTS 合成错误事件。
       *
       * @param requestId TTS 请求标识。
       * @param errorCode 错误码。
       * @param errorMessage 错误信息。
       */
      onError(requestId: string, errorCode: number, errorMessage: string): void {
        owner.handleSynthesisError(requestId, errorCode, errorMessage)
      }
    })
  }

  /**
   * 准备后台保活和临时 WAV 文件后开始完整文本合成。
   *
   * @param generation 当前朗读任务代次。
   */
  private async beginSynthesis(generation: number): Promise<void> {
    if (!this.isActivePlayback(generation)) {
      return
    }
    await this.ensureBackgroundPlayback(generation)
    if (!this.isActivePlayback(generation) || this.isPlaybackPaused()) {
      return
    }
    let writerStarted: boolean = false
    try {
      writerStarted = await this.audioRenderer.begin(generation)
    } catch (error) {
      this.handleAudioRendererError(
        generation,
        error,
        '无法创建朗读音频缓存'
      )
      return
    }
    if (!this.isActivePlayback(generation) || !writerStarted) {
      return
    }
    this.synthesizeNextChunk(generation)
  }

  /**
   * 调用 TTS 引擎合成下一段文本，全部合成后开始 WAV 播放。
   *
   * @param generation 当前朗读任务代次。
   */
  private synthesizeNextChunk(generation: number): void {
    if (!this.isActivePlayback(generation)) {
      return
    }
    if (this.chunkIndex >= this.pendingChunks.length) {
      this.playSynthesizedAudio(generation)
      return
    }
    const text: string = this.pendingChunks[this.chunkIndex]
    this.chunkIndex++
    this.synthesizeChunk(text, generation)
  }

  /**
   * 调用 TTS 引擎合成单个文本段。
   *
   * @param text 当前文本段。
   * @param generation 当前朗读任务代次。
   */
  private synthesizeChunk(text: string, generation: number): void {
    const engine: textToSpeech.TextToSpeechEngine | null = this.engine
    if (engine === null) {
      this.finishPlayback()
      return
    }
    const extraParams: Record<string, Object> = {
      'queueMode': 1,
      'speed': appStore.settings.ttsSpeed,
      'volume': appStore.settings.ttsVolume,
      'pitch': appStore.settings.ttsPitch,
      'languageContext': 'zh-CN',
      'audioType': 'pcm',
      'playType': 0
    }
    this.requestSequence++
    const requestId: string = Date.now().toString() + '-' + this.requestSequence.toString()
    const speakParams: textToSpeech.SpeakParams = {
      requestId: requestId,
      extraParams: extraParams
    }
    this.activeRequestId = requestId
    this.activeRequestGeneration = generation
    try {
      engine.speak(text, speakParams)
    } catch (error) {
      logger.error('Start TTS synthesis failed: %{public}s', formatError(error))
      this.finishPlayback()
      appStore.showToast('朗读出错')
    }
  }

  /**
   * 处理 TTS 合成开始事件。
   *
   * @param requestId TTS 请求标识。
   * @param response PCM 格式信息。
   */
  private handleSynthesisStart(
    requestId: string,
    response: textToSpeech.StartResponse
  ): void {
    if (!this.isActiveRequest(requestId)) {
      return
    }
    const generation: number = this.playbackGeneration
    if (!this.audioRenderer.prepare(response, generation)) {
      this.handleAudioRendererError(
        generation,
        new Error('TTS PCM format changed or is unsupported')
      )
      return
    }
  }

  /**
   * 处理 TTS 合成完成事件。
   *
   * @param requestId TTS 请求标识。
   * @param response 合成完成信息。
   */
  private handleSynthesisComplete(
    requestId: string,
    response: textToSpeech.CompleteResponse
  ): void {
    if (!this.isActiveRequest(requestId) || response.type !== 0) {
      return
    }
    const generation: number = this.playbackGeneration
    this.clearActiveRequest()
    if (this.chunkIndex > 0) {
      this.completedChars += this.pendingChunks[this.chunkIndex - 1].length
    }
    if (this.completedChars > 0) {
      const calibrated: number = this.receivedPcmBytes / this.completedChars
      this.bytesPerChar = Math.max(
        MIN_BYTES_PER_CHAR,
        Math.min(MAX_BYTES_PER_CHAR, calibrated)
      )
    }
    this.publishSynthesisProgress()
    this.synthesizeNextChunk(generation)
  }

  /**
   * 处理 TTS 合成停止事件。
   *
   * @param requestId TTS 请求标识。
   * @param response 合成停止信息。
   */
  private handleSynthesisStop(
    requestId: string,
    response: textToSpeech.StopResponse
  ): void {
    if (!this.isActiveRequest(requestId)) {
      return
    }
    logger.warn(
      'TTS synthesis stopped: %{public}d %{public}s',
      response.type,
      response.message
    )
    this.finishPlayback()
  }

  /**
   * 保存 TTS 合成产生的 PCM 数据。
   *
   * @param requestId TTS 请求标识。
   * @param pcmData PCM 数据。
   * @param response 合成进度信息。
   */
  private handleSynthesisData(
    requestId: string,
    pcmData: ArrayBuffer,
    response: textToSpeech.SynthesisResponse
  ): void {
    if (!this.isActiveRequest(requestId)) {
      return
    }
    const generation: number = this.playbackGeneration
    if (response.audioType.trim().toLowerCase() !== 'pcm') {
      this.handleAudioRendererError(
        generation,
        new Error('TTS returned non-PCM synthesis data')
      )
      return
    }
    const enqueueResult: TtsAudioEnqueueResult =
      this.audioRenderer.enqueue(pcmData, generation)
    if (enqueueResult === TtsAudioEnqueueResult.LIMIT_EXCEEDED) {
      this.handleAudioRendererError(
        generation,
        new Error('TTS WAV exceeded the storage or write backlog safety limit'),
        '朗读内容过长或缓存空间不足，已停止朗读'
      )
      return
    } else if (enqueueResult === TtsAudioEnqueueResult.WRITE_FAILED) {
      this.handleAudioRendererError(
        generation,
        new Error('TTS WAV writer has already failed'),
        '写入朗读音频缓存失败'
      )
      return
    } else if (enqueueResult === TtsAudioEnqueueResult.INACTIVE) {
      this.handleAudioRendererError(
        generation,
        new Error('TTS PCM data arrived outside the active WAV writer')
      )
      return
    }
    this.receivedPcmBytes += pcmData.byteLength
    this.publishSynthesisProgress()
  }

  /**
   * 处理 TTS 合成错误事件。
   *
   * @param requestId TTS 请求标识。
   * @param errorCode 错误码。
   * @param errorMessage 错误信息。
   */
  private handleSynthesisError(
    requestId: string,
    errorCode: number,
    errorMessage: string
  ): void {
    if (!this.isActiveRequest(requestId)) {
      return
    }
    this.finishPlayback()
    if (shouldReleaseEngineOnError(errorCode)) {
      this.releaseEngine()
    }
    logger.error('TTS synthesis failed: %{public}d %{public}s', errorCode, errorMessage)
    appStore.showToast('朗读出错')
  }

  /**
   * 完成临时 WAV 文件并交给 AVPlayer。
   *
   * @param generation 当前朗读任务代次。
   */
  private playSynthesizedAudio(generation: number): void {
    ttsProgress.hide()
    this.audioRenderer.complete(generation).catch((error: Object): void => {
      this.handleAudioRendererError(generation, error)
    })
  }

  /**
   * 在 AVPlayer 准备完成后同步时长和待执行的暂停状态。
   *
   * @param generation 当前朗读任务代次。
   * @param durationMs 当前媒体总时长，单位为毫秒。
   * @returns 是否应当立即开始播放。
   */
  private async handleAudioReady(
    generation: number,
    durationMs: number
  ): Promise<boolean> {
    if (!this.isActivePlayback(generation)) {
      return false
    }
    this.rendererReady = true
    if (this.playbackPhase === TtsPlaybackPhase.PAUSED) {
      this.synchronizeAvSessionPlaybackState(durationMs, 0)
      return false
    }
    await this.ensureBackgroundPlayback(generation)
    if (!this.isActivePlayback(generation)) {
      return false
    }
    if (this.isPlaybackPaused()) {
      this.backgroundTaskController.stop()
      this.synchronizeAvSessionPlaybackState(durationMs, 0)
      return false
    }
    this.playbackPhase = TtsPlaybackPhase.PLAYING
    this.synchronizeAvSessionPlaybackState(durationMs, 0)
    return true
  }

  /**
   * 在合成和声音输出阶段确保 AVSession 与音频播放长时任务已经就绪。
   *
   * 后台能力失败不会阻止前台朗读，但会提示用户熄屏后可能中断。
   *
   * @param generation 当前朗读任务代次。
   */
  private async ensureBackgroundPlayback(generation: number): Promise<void> {
    if (!this.backgroundPlaybackEnabled || !this.isActivePlayback(generation)) {
      return
    }
    const activationOperation: Promise<boolean> =
      this.avSessionActivationOperation
    const avSessionActivated: boolean = await activationOperation
    if (!this.isActivePlayback(generation)) {
      return
    }
    let backgroundTaskStarted: boolean = false
    if (avSessionActivated) {
      backgroundTaskStarted = await this.backgroundTaskController.start()
    }
    if (!this.isActivePlayback(generation)) {
      return
    }
    if (!avSessionActivated || !backgroundTaskStarted) {
      this.showBackgroundPlaybackWarning(generation)
    }
  }

  /**
   * 每个朗读任务最多提示一次后台播放能力降级。
   *
   * @param generation 当前朗读任务代次。
   */
  private showBackgroundPlaybackWarning(generation: number): void {
    if (this.backgroundWarningGeneration === generation) {
      return
    }
    this.backgroundWarningGeneration = generation
    appStore.showToast('后台朗读启动失败，熄屏后可能中断')
  }

  /**
   * 查询当前朗读是否处于暂停阶段。
   *
   * @returns 是否处于暂停阶段。
   */
  private isPlaybackPaused(): boolean {
    return this.playbackPhase === TtsPlaybackPhase.PAUSED
  }

  /**
   * 发布合成阶段的实时估算进度。
   *
   * 以已接收的 PCM 字节数占总估算字节数（总字符数 × 每字符字节数）的比例估算，
   * 每字符字节数在每段合成完成后按实际比例校准（钳制在估算上下限内）；
   * 已完成段数与估算结果取较大值，并保持单调递增，避免估算波动导致进度回退。
   * 合成阶段最高显示到 99%。
   */
  private publishSynthesisProgress(): void {
    if (this.totalChars <= 0) {
      return
    }
    const chunkPercent: number = this.completedChars / this.totalChars * 100
    const estimatedTotalBytes: number = this.totalChars * this.bytesPerChar
    let percent: number = estimatedTotalBytes > 0
      ? this.receivedPcmBytes / estimatedTotalBytes * 100
      : chunkPercent
    percent = Math.max(percent, chunkPercent)
    percent = Math.min(percent, 99)
    if (percent < this.lastSynthesisPercent) {
      percent = this.lastSynthesisPercent
    }
    this.lastSynthesisPercent = percent
    ttsProgress.showSynthesizing(Math.round(percent))
  }

  /**
   * 在 AVPlayer 真正进入播放状态后同步系统媒体卡片。
   *
   * @param generation 当前朗读任务代次。
   * @param durationMs 当前媒体总时长，单位为毫秒。
   * @param positionMs 当前播放位置，单位为毫秒。
   */
  private handleAudioPlaying(
    generation: number,
    durationMs: number,
    positionMs: number
  ): void {
    if (!this.isActivePlayback(generation)) {
      return
    }
    this.rendererReady = true
    if (this.playbackPhase === TtsPlaybackPhase.PAUSED) {
      this.enqueuePlaybackControl(async (): Promise<void> => {
        await this.pauseInternal(generation)
      })
      return
    }
    this.playbackPhase = TtsPlaybackPhase.PLAYING
    this.synchronizeAvSessionPlaybackState(durationMs, positionMs)
  }

  /**
   * 将自然播放完成同步为可定位、可单击重播的完成状态。
   *
   * @param generation 当前朗读任务代次。
   */
  private handleAudioCompleted(generation: number): void {
    if (!this.isActivePlayback(generation)) {
      return
    }
    this.rendererReady = true
    this.playbackPhase = TtsPlaybackPhase.COMPLETED
    this.interruptionResumePending = false
    this.backgroundTaskController.stop()
    this.synchronizeAvSessionPlaybackState(
      this.audioRenderer.getDuration(),
      this.audioRenderer.getDuration()
    )
    ttsProgress.hide()
  }

  /**
   * 将 AVPlayer 的真实位置同步到系统媒体卡片。
   *
   * @param generation 当前朗读任务代次。
   * @param positionMs 当前播放位置，单位为毫秒。
   * @param durationMs 当前媒体总时长，单位为毫秒。
   */
  private handleAudioPositionChanged(
    generation: number,
    positionMs: number,
    durationMs: number
  ): void {
    if (!this.isActivePlayback(generation) ||
      !this.backgroundPlaybackEnabled ||
      this.playbackPhase === TtsPlaybackPhase.COMPLETED) {
      return
    }
    this.avSessionController.setPosition(positionMs, durationMs)
  }

  /**
   * 处理 WAV 写入或 AVPlayer 播放链路中的不可恢复错误。
   *
   * @param generation 出错的朗读任务代次。
   * @param error 错误对象。
   * @param toastMessage 面向用户展示的错误信息。
   */
  private handleAudioRendererError(
    generation: number,
    error: Object,
    toastMessage: string = '朗读出错'
  ): void {
    if (!this.isActivePlayback(generation)) {
      return
    }
    logger.error('TTS audio playback failed: %{public}s', formatError(error))
    const engine: textToSpeech.TextToSpeechEngine | null = this.engine
    this.finishPlayback()
    try {
      if (engine !== null && engine.isBusy()) {
        engine.stop()
      }
    } catch (stopError) {
      logger.warn('Stop TTS after audio playback error failed: %{public}s', formatError(stopError))
    }
    appStore.showToast(toastMessage)
  }

  /**
   * 判断指定请求是否为当前有效 TTS 合成请求。
   *
   * @param requestId TTS 请求标识。
   * @returns 是否为当前有效请求。
   */
  private isActiveRequest(requestId: string): boolean {
    return requestId === this.activeRequestId &&
      this.activeRequestGeneration === this.playbackGeneration &&
      this.speakingPid !== -1
  }

  /**
   * 判断指定代次是否为当前有效朗读任务。
   *
   * @param generation 朗读任务代次。
   * @returns 是否为当前有效任务。
   */
  private isActivePlayback(generation: number): boolean {
    return generation === this.playbackGeneration && this.speakingPid !== -1
  }

  /**
   * 清除当前 TTS 合成请求标识。
   */
  private clearActiveRequest(): void {
    this.activeRequestId = ''
    this.activeRequestGeneration = -1
  }

  /**
   * 将播放控制操作加入串行队列。
   *
   * @param task 待执行的播放控制操作。
   * @returns 当前播放控制任务链。
   */
  private enqueuePlaybackControl(task: () => Promise<void>): Promise<void> {
    this.playbackControlOperation =
      this.playbackControlOperation.then(task).catch((error: Object): void => {
        logger.warn('Control TTS AVPlayer failed: %{public}s', formatError(error))
      })
    return this.playbackControlOperation
  }

  /**
   * 乐观同步暂停状态并暂停当前代次的 AVPlayer。
   *
   * @param generation 当前朗读任务代次。
   */
  private async pauseInternal(generation: number): Promise<void> {
    if (!this.isActivePlayback(generation)) {
      return
    }
    this.interruptionResumePending = false
    const previousPhase: TtsPlaybackPhase = this.playbackPhase
    this.playbackPhase = TtsPlaybackPhase.PAUSED
    this.synchronizeAvSessionPlaybackState()
    if (!this.rendererReady) {
      this.backgroundTaskController.stop()
      return
    }
    let paused: boolean = false
    try {
      paused = await this.audioRenderer.pause()
    } catch (error) {
      this.rollbackPlaybackPhase(generation, previousPhase)
      throw new Error(formatError(error))
    }
    if (!this.isActivePlayback(generation)) {
      return
    }
    if (!paused) {
      this.rollbackPlaybackPhase(generation, previousPhase)
      return
    }
    this.backgroundTaskController.stop()
  }

  /**
   * 乐观同步播放状态并恢复当前代次的 AVPlayer。
   *
   * @param generation 当前朗读任务代次。
   */
  private async resumeInternal(generation: number): Promise<void> {
    if (!this.isActivePlayback(generation)) {
      return
    }
    this.interruptionResumePending = false
    if (!this.rendererReady) {
      await this.ensureBackgroundPlayback(generation)
      if (!this.isActivePlayback(generation)) {
        return
      }
      if (!this.rendererReady) {
        this.playbackPhase = TtsPlaybackPhase.PREPARING
        this.synchronizeAvSessionPlaybackState()
        this.publishSynthesisProgress()
        return
      }
    }
    const previousPhase: TtsPlaybackPhase = this.playbackPhase
    const failurePhase: TtsPlaybackPhase =
      previousPhase === TtsPlaybackPhase.COMPLETED
        ? TtsPlaybackPhase.COMPLETED
        : TtsPlaybackPhase.PAUSED
    await this.ensureBackgroundPlayback(generation)
    if (!this.isActivePlayback(generation) || !this.rendererReady) {
      return
    }
    this.playbackPhase = TtsPlaybackPhase.PLAYING
    this.synchronizeAvSessionPlaybackState()
    let resumed: boolean = false
    try {
      resumed = await this.audioRenderer.resume()
    } catch (error) {
      this.backgroundTaskController.stop()
      this.rollbackPlaybackPhase(generation, failurePhase)
      throw new Error(formatError(error))
    }
    if (!resumed) {
      this.backgroundTaskController.stop()
      this.rollbackPlaybackPhase(generation, failurePhase)
    }
  }

  /**
   * 播放控制失败时还原指定播放阶段。
   *
   * @param generation 当前朗读任务代次。
   * @param phase 需要恢复的播放阶段。
   */
  private rollbackPlaybackPhase(
    generation: number,
    phase: TtsPlaybackPhase
  ): void {
    if (!this.isActivePlayback(generation)) {
      return
    }
    this.playbackPhase = phase
    this.synchronizeAvSessionPlaybackState()
  }

  /**
   * 将 AVPlayer 的焦点中断串行同步到播放器和系统播控状态。
   *
   * @param event AVPlayer 上报的音频焦点中断。
   */
  private handleAudioInterruption(event: TtsAudioInterruptionEvent): void {
    this.enqueuePlaybackControl(async (): Promise<void> => {
      if (!this.isActivePlayback(event.generation) || !this.rendererReady) {
        return
      }
      if (event.action === TtsAudioInterruptionAction.RESUME) {
        if (!this.interruptionResumePending) {
          return
        }
        this.interruptionResumePending = false
        await this.resumeInternal(event.generation)
        return
      }
      const shouldAutoResume: boolean =
        event.action === TtsAudioInterruptionAction.PAUSE &&
        (this.playbackPhase === TtsPlaybackPhase.PLAYING ||
          this.interruptionResumePending)
      this.playbackPhase = TtsPlaybackPhase.PAUSED
      this.interruptionResumePending = shouldAutoResume
      this.synchronizeAvSessionPlaybackState()
      if (!event.systemApplied) {
        let applied: boolean = false
        try {
          applied = await this.audioRenderer.applySharedInterruption(
            event.action,
            event.generation
          )
        } catch (error) {
          this.handleAudioRendererError(
            event.generation,
            error,
            '音频中断处理失败，朗读已停止'
          )
          return
        }
        if (!applied) {
          if (this.isActivePlayback(event.generation)) {
            this.handleAudioRendererError(
              event.generation,
              new Error('Audio interruption was not applied to the active renderer'),
              '音频中断处理失败，朗读已停止'
            )
          }
          return
        }
      }
      this.backgroundTaskController.stop()
    })
  }

  /**
   * 在当前音频输出设备断开后暂停朗读，避免声音意外切换到扬声器。
   *
   * @param generation 当前朗读任务代次。
   */
  private handleOutputDeviceUnavailable(generation: number): void {
    this.enqueuePlaybackControl(async (): Promise<void> => {
      await this.pauseInternal(generation)
    })
  }

  /**
   * 将协调层的唯一播放阶段同步到系统媒体卡片。
   *
   * @param durationMs 当前媒体总时长，单位为毫秒。
   * @param positionMs 当前播放位置，单位为毫秒。
   */
  private synchronizeAvSessionPlaybackState(
    durationMs: number = this.audioRenderer.getDuration(),
    positionMs: number = this.audioRenderer.getPosition()
  ): void {
    if (!this.backgroundPlaybackEnabled) {
      return
    }
    if (this.playbackPhase === TtsPlaybackPhase.PLAYING) {
      this.avSessionController.setPlaying(durationMs, positionMs)
    } else if (this.playbackPhase === TtsPlaybackPhase.PAUSED) {
      this.avSessionController.setPaused(durationMs, positionMs)
    } else if (this.playbackPhase === TtsPlaybackPhase.PREPARING) {
      this.avSessionController.setPreparing(durationMs)
    } else if (this.playbackPhase === TtsPlaybackPhase.COMPLETED) {
      this.avSessionController.setReplayReady(durationMs, positionMs)
    }
  }

  /**
   * 将系统快进快退命令的秒数转换为毫秒。
   *
   * @param intervalSeconds 系统媒体卡片请求的跳转秒数。
   * @returns 有效跳转间隔，单位为毫秒。
   */
  private resolveSkipIntervalMs(intervalSeconds?: number): number {
    if (intervalSeconds === undefined || intervalSeconds <= 0) {
      return SYSTEM_SKIP_INTERVAL_MS
    }
    return Math.round(intervalSeconds * 1000)
  }

  /**
   * 响应系统媒体卡片的绝对进度定位命令。
   *
   * @param positionMs 目标播放位置，单位为毫秒。
   */
  private seek(positionMs: number): void {
    const generation: number = this.playbackGeneration
    this.enqueuePlaybackControl(async (): Promise<void> => {
      this.seekInternal(generation, positionMs)
    })
  }

  /**
   * 响应系统媒体卡片的固定间隔快进或快退命令。
   *
   * @param deltaMs 相对当前位置的偏移量，单位为毫秒。
   */
  private skipBy(deltaMs: number): void {
    const generation: number = this.playbackGeneration
    this.enqueuePlaybackControl(async (): Promise<void> => {
      const targetMs: number = this.audioRenderer.getPosition() + deltaMs
      this.seekInternal(generation, targetMs)
    })
  }

  /**
   * 在播放控制队列中提交一次 AVPlayer 定位操作。
   *
   * @param generation 当前朗读任务代次。
   * @param positionMs 目标播放位置，单位为毫秒。
   */
  private seekInternal(generation: number, positionMs: number): void {
    if (!this.isActivePlayback(generation) || !this.rendererReady) {
      return
    }
    let submitted: boolean = false
    try {
      submitted = this.audioRenderer.seek(positionMs)
    } catch (error) {
      this.handleAudioRendererError(
        generation,
        error,
        '调整朗读进度失败'
      )
      return
    }
    if (submitted && this.backgroundPlaybackEnabled) {
      this.avSessionController.setPosition(
        this.audioRenderer.getPosition(),
        this.audioRenderer.getDuration(),
        true
      )
    }
  }

  /**
   * 补全系统播控中心展示的媒体元数据。
   *
   * @param pid 当前朗读楼层标识。
   * @param metadata 调用方提供的媒体元数据。
   * @returns 可直接交给 AVSession 的媒体元数据。
   */
  private resolveMediaMetadata(
    pid: number,
    metadata?: TtsMediaMetadata
  ): TtsMediaMetadata {
    if (metadata !== undefined) {
      return metadata
    }
    return {
      assetId: 'tts-' + pid.toString(),
      title: '帖子朗读',
      artist: 'NGA玩家社区',
      album: '文字转语音'
    }
  }

  /**
   * 清理当前朗读状态并释放长时任务。
   */
  private finishPlayback(): void {
    const avSessionActive: boolean = this.backgroundPlaybackEnabled
    this.audioRenderer.stop()
    this.speakingPid = -1
    this.pendingChunks = []
    this.chunkIndex = 0
    this.totalChars = 0
    this.completedChars = 0
    this.receivedPcmBytes = 0
    this.bytesPerChar = ESTIMATED_BYTES_PER_CHAR
    this.lastSynthesisPercent = -1
    this.clearActiveRequest()
    this.backgroundPlaybackEnabled = false
    this.backgroundWarningGeneration = -1
    this.playbackPhase = TtsPlaybackPhase.IDLE
    this.rendererReady = false
    this.interruptionResumePending = false
    this.avSessionActivationOperation = Promise.resolve(false)
    this.backgroundTaskController.stop()
    ttsProgress.hide()
    if (avSessionActive) {
      this.avSessionController.stop()
    }
  }

  /**
   * 主动停止当前朗读并使未完成的异步操作失效。
   */
  private stopInternal(): void {
    this.playbackGeneration++
    this.engineInitializationGeneration++
    const engine: textToSpeech.TextToSpeechEngine | null = this.engine
    this.finishPlayback()
    try {
      if (engine !== null && engine.isBusy()) {
        engine.stop()
      }
    } catch (error) {
      logger.warn('Stop TTS playback failed: %{public}s', formatError(error))
    }
  }

  /**
   * 响应用户或系统取消长时任务事件。
   *
   * @param info 长时任务取消信息。
   */
  private handleBackgroundTaskCancelled(
    info: backgroundTaskManager.ContinuousTaskCancelInfo
  ): void {
    if (!this.backgroundPlaybackEnabled) {
      return
    }
    if (info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL ||
      info.reason ===
        backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL_REMOVE_NOTIFICATION) {
      this.stopInternal()
      appStore.showToast('后台朗读已停止')
      return
    }
    const generation: number = this.playbackGeneration
    this.enqueuePlaybackControl(async (): Promise<void> => {
      await this.pauseInternal(generation)
    })
    appStore.showToast('系统已暂停后台朗读')
  }

  /**
   * 响应系统暂停长时任务事件，停止声音输出并保留恢复位置。
   *
   * @param info 长时任务暂停信息。
   */
  private handleBackgroundTaskSuspended(
    info: backgroundTaskManager.ContinuousTaskSuspendInfo
  ): void {
    if (!this.backgroundPlaybackEnabled || !info.suspendState) {
      return
    }
    const generation: number = this.playbackGeneration
    this.enqueuePlaybackControl(async (): Promise<void> => {
      await this.pauseInternal(generation)
    })
    appStore.showToast('系统已暂停后台朗读')
  }

  /**
   * 记录系统重新激活长时任务的事件。
   *
   * @param info 长时任务激活信息。
   */
  private handleBackgroundTaskActivated(
    info: backgroundTaskManager.ContinuousTaskActiveInfo
  ): void {
    logger.info('TTS background task became active, id: %{public}d', info.id)
  }

  /**
   * 释放当前持有的 TTS 引擎。
   */
  private releaseEngine(): void {
    const engine: textToSpeech.TextToSpeechEngine | null = this.engine
    this.engine = null
    this.enginePerson = -1
    if (engine !== null) {
      this.shutdownEngineInstance(engine)
    }
  }

  /**
   * 安全关闭指定 TTS 引擎实例。
   *
   * @param engine 待关闭的 TTS 引擎。
   */
  private shutdownEngineInstance(engine: textToSpeech.TextToSpeechEngine): void {
    try {
      engine.shutdown()
    } catch (error) {
      logger.warn('Shutdown TTS engine failed: %{public}s', formatError(error))
    }
  }
}

const playbackCoordinator: TtsPlaybackCoordinator = new TtsPlaybackCoordinator()

/**
 * 帖子文字转语音播放器。
 */
export class TtsPlayer {
  /**
   * 初始化播放器所需的 UIAbility 上下文。
   *
   * @param context UIAbility 上下文。
   */
  static initialize(context: common.UIAbilityContext): void {
    playbackCoordinator.initialize(context)
  }

  /**
   * 播放文本；再次点击同一楼层时停止播放。
   *
   * @param text 待朗读文本。
   * @param pid 楼层标识。
   * @param allowBackground 是否允许熄屏或切后台继续朗读。
   * @param metadata 系统播控中心展示的媒体信息。
   */
  static speak(
    text: string,
    pid: number,
    allowBackground: boolean = false,
    metadata?: TtsMediaMetadata
  ): void {
    playbackCoordinator.speak(text, pid, allowBackground, metadata)
  }

  /**
   * 查询指定楼层是否正在朗读。
   *
   * @param pid 楼层标识。
   * @returns 是否正在朗读。
   */
  static isSpeaking(pid: number): boolean {
    return playbackCoordinator.isSpeaking(pid)
  }

  /**
   * 停止当前朗读。
   */
  static stop(): void {
    playbackCoordinator.stop()
  }

  /**
   * 暂停当前朗读。
   */
  static pause(): void {
    playbackCoordinator.pause()
  }

  /**
   * 恢复当前朗读。
   */
  static resume(): void {
    playbackCoordinator.resume()
  }

  /**
   * 停止朗读并释放所有 Ability 级资源。
   */
  static shutdown(): void {
    playbackCoordinator.shutdown()
  }
}
