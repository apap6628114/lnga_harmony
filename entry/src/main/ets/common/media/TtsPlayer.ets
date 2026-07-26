import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { textToSpeech } from '@kit.CoreSpeechKit'
import { appStore } from '../../store/AppStore'
import {
  TtsAvSessionController,
  TtsMediaMetadata
} from './TtsAvSessionController'
import { TtsBackgroundTaskController } from './TtsBackgroundTaskController'
import { TtsPcmEnqueueResult, TtsPcmRenderer } from './TtsPcmRenderer'
import { DOMAIN_MEDIA, formatError, Logger } from '../utils/Logger'

const MAX_CHUNK_LEN: number = 10000
const logger: Logger = new Logger(DOMAIN_MEDIA, 'TtsPlayer')

/**
 * 判断指定 UTF-16 编码单元是否为高位代理项。
 *
 * @param code UTF-16 编码单元。
 * @returns 是否为高位代理项。
 */
function isHighSurrogate(code: number): boolean {
  return code >= 0xD800 && code <= 0xDBFF
}

/**
 * 判断指定 UTF-16 编码单元是否为低位代理项。
 *
 * @param code UTF-16 编码单元。
 * @returns 是否为低位代理项。
 */
function isLowSurrogate(code: number): boolean {
  return code >= 0xDC00 && code <= 0xDFFF
}

/**
 * 避免在 Unicode 代理项中间切分文本。
 *
 * @param text 原始文本。
 * @param cutPosition 初始切分位置。
 * @returns 安全的切分位置。
 */
function adjustSurrogateBoundary(text: string, cutPosition: number): number {
  if (cutPosition <= 0 || cutPosition >= text.length) {
    return cutPosition
  }
  const previousCode: number = text.charCodeAt(cutPosition - 1)
  const nextCode: number = text.charCodeAt(cutPosition)
  if (isHighSurrogate(previousCode) && isLowSurrogate(nextCode)) {
    return cutPosition - 1
  }
  return cutPosition
}

/**
 * 判断字符是否适合作为 TTS 文本段落的结束位置。
 *
 * @param character 待判断字符。
 * @returns 是否为自然断句字符。
 */
function isSentenceBoundary(character: string): boolean {
  return character === '\n' || character === '。' || character === '！' ||
    character === '？' || character === '；' || character === '，' ||
    character === '.' || character === '!' || character === '?' ||
    character === ';' || character === ','
}

/**
 * 按 TTS 单次请求上限和自然断句位置拆分文本。
 *
 * @param text 待朗读文本。
 * @returns 拆分后的文本段落。
 */
function splitText(text: string): string[] {
  if (text.length <= MAX_CHUNK_LEN) {
    return [text]
  }
  const chunks: string[] = []
  let start: number = 0
  while (start < text.length) {
    if (start + MAX_CHUNK_LEN >= text.length) {
      chunks.push(text.substring(start))
      break
    }
    let cutPosition: number = start + MAX_CHUNK_LEN
    for (let index: number = cutPosition - 1; index > start; index--) {
      if (isSentenceBoundary(text.charAt(index))) {
        cutPosition = index + 1
        break
      }
    }
    cutPosition = adjustSurrogateBoundary(text, cutPosition)
    chunks.push(text.substring(start, cutPosition))
    start = cutPosition
  }
  return chunks
}

/**
 * 协调 TTS 引擎、PCM 渲染器和后台长时任务的完整生命周期。
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
  /** 已显示开始朗读提示的任务代次。 */
  private startToastGeneration: number = -1
  /** TTS PCM 数据缓冲与播放组件。 */
  private readonly pcmRenderer: TtsPcmRenderer = new TtsPcmRenderer()
  /** 系统媒体播控会话控制器。 */
  private readonly avSessionController: TtsAvSessionController
  /** 音频播放长时任务控制器。 */
  private readonly backgroundTaskController: TtsBackgroundTaskController
  /** 串行化播放、暂停操作的任务链。 */
  private playbackControlOperation: Promise<void> = Promise.resolve()
  /** 用户或系统当前是否期望朗读保持暂停。 */
  private playbackPauseRequested: boolean = false
  /** 当前任务是否已经创建并启动 PCM 渲染器。 */
  private pcmPlaybackStarted: boolean = false

  /**
   * 创建 TTS 播放协调器。
   */
  constructor() {
    this.avSessionController = new TtsAvSessionController({
      onPlay: (): void => {
        this.resume()
      },
      onPause: (): void => {
        this.pause()
      },
      onStop: (): void => {
        this.stop()
      }
    })
    this.backgroundTaskController = new TtsBackgroundTaskController((): void => {
      this.handleBackgroundTaskCancelled()
    })
  }

  /**
   * 初始化播放器所需的 UIAbility 上下文。
   *
   * @param context UIAbility 上下文。
   */
  initialize(context: common.UIAbilityContext): void {
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
    this.playbackPauseRequested = false
    this.pcmPlaybackStarted = false
    if (allowBackground) {
      this.avSessionController.start(this.resolveMediaMetadata(pid, metadata))
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
      if (error.code === 1002300003 || error.code === 1002300005) {
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
   * 在后台长时任务就绪后开始完整文本合成。
   *
   * @param generation 当前朗读任务代次。
   */
  private async beginSynthesis(generation: number): Promise<void> {
    let backgroundTaskStarted: boolean = true
    if (this.backgroundPlaybackEnabled) {
      backgroundTaskStarted = await this.backgroundTaskController.start()
    }
    if (!this.isActivePlayback(generation)) {
      return
    }
    if (!backgroundTaskStarted && this.backgroundWarningGeneration !== generation) {
      this.backgroundWarningGeneration = generation
      appStore.showToast('后台朗读启动失败，熄屏后可能中断')
    }
    this.pcmRenderer.begin(generation)
    this.synthesizeNextChunk(generation)
  }

  /**
   * 调用 TTS 引擎合成下一段文本，全部合成后开始 PCM 播放。
   *
   * @param generation 当前朗读任务代次。
   */
  private synthesizeNextChunk(generation: number): void {
    if (!this.isActivePlayback(generation)) {
      return
    }
    if (this.chunkIndex >= this.pendingChunks.length) {
      this.playBufferedAudio(generation)
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
    if (!this.pcmRenderer.prepare(response, generation)) {
      this.handlePcmRendererError(generation, new Error('TTS PCM format changed during synthesis'))
      return
    }
    if (this.startToastGeneration !== generation) {
      this.startToastGeneration = generation
      appStore.showToast('正在朗读')
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
    const enqueueResult: TtsPcmEnqueueResult =
      this.pcmRenderer.enqueue(pcmData, generation)
    if (enqueueResult === TtsPcmEnqueueResult.LIMIT_EXCEEDED) {
      this.handlePcmRendererError(
        generation,
        new Error('TTS PCM buffer exceeded the 64 MiB safety limit'),
        '朗读内容过长，已停止以避免占用过多内存'
      )
    } else if (enqueueResult === TtsPcmEnqueueResult.INACTIVE) {
      this.handlePcmRendererError(
        generation,
        new Error('TTS PCM data arrived outside the active playback')
      )
    }
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
    if (errorCode === 1002300007) {
      this.releaseEngine()
    }
    logger.error('TTS synthesis failed: %{public}d %{public}s', errorCode, errorMessage)
    appStore.showToast('朗读出错')
  }

  /**
   * 播放当前任务已经完整合成的 PCM 数据。
   *
   * @param generation 当前朗读任务代次。
   */
  private playBufferedAudio(generation: number): void {
    this.pcmRenderer.complete(generation, async (durationMs: number): Promise<void> => {
      await this.handlePcmPlaybackStarted(generation, durationMs)
    }).then((completed: boolean): void => {
      if (completed && this.isActivePlayback(generation)) {
        this.finishPlayback(true)
      }
    }).catch((error: Object): void => {
      this.handlePcmRendererError(generation, error)
    })
  }

  /**
   * 同步 PCM 渲染器启动后的期望播放状态。
   *
   * @param generation 当前朗读任务代次。
   * @param durationMs 当前媒体总时长，单位为毫秒。
   */
  private async handlePcmPlaybackStarted(
    generation: number,
    durationMs: number
  ): Promise<void> {
    if (!this.isActivePlayback(generation)) {
      return
    }
    this.pcmPlaybackStarted = true
    await this.enqueuePlaybackControl(async (): Promise<void> => {
      if (!this.isActivePlayback(generation)) {
        return
      }
      if (this.playbackPauseRequested) {
        let paused: boolean = false
        try {
          paused = await this.pcmRenderer.pause()
        } catch (error) {
          logger.warn('Apply pending TTS pause failed: %{public}s', formatError(error))
        }
        if (!this.isActivePlayback(generation)) {
          return
        }
        if (!paused) {
          this.stopInternal()
          appStore.showToast('暂停失败，朗读已停止')
          return
        }
        if (this.backgroundPlaybackEnabled) {
          this.avSessionController.setPaused(durationMs)
          this.backgroundTaskController.stop()
        }
        return
      }
      if (this.backgroundPlaybackEnabled) {
        this.avSessionController.setPlaying(durationMs)
      }
    })
  }

  /**
   * 处理应用 PCM 播放链路中的不可恢复错误。
   *
   * @param generation 出错的朗读任务代次。
   * @param error 错误对象。
   * @param toastMessage 面向用户展示的错误信息。
   */
  private handlePcmRendererError(
    generation: number,
    error: Object,
    toastMessage: string = '朗读出错'
  ): void {
    if (!this.isActivePlayback(generation)) {
      return
    }
    logger.error('TTS PCM playback failed: %{public}s', formatError(error))
    const engine: textToSpeech.TextToSpeechEngine | null = this.engine
    this.finishPlayback()
    try {
      if (engine !== null && engine.isBusy()) {
        engine.stop()
      }
    } catch (stopError) {
      logger.warn('Stop TTS after PCM playback error failed: %{public}s', formatError(stopError))
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
        logger.warn('Control TTS PCM playback failed: %{public}s', formatError(error))
      })
    return this.playbackControlOperation
  }

  /**
   * 暂停当前代次的 PCM 播放并释放长时任务。
   *
   * @param generation 当前朗读任务代次。
   */
  private async pauseInternal(generation: number): Promise<void> {
    if (!this.isActivePlayback(generation)) {
      return
    }
    this.playbackPauseRequested = true
    let paused: boolean = false
    try {
      paused = await this.pcmRenderer.pause()
    } catch (error) {
      if (this.isActivePlayback(generation)) {
        this.playbackPauseRequested = false
      }
      throw new Error(formatError(error))
    }
    if (!this.isActivePlayback(generation)) {
      return
    }
    if (this.pcmPlaybackStarted && !paused) {
      this.playbackPauseRequested = false
      return
    }
    if (this.backgroundPlaybackEnabled) {
      this.avSessionController.setPaused()
      this.backgroundTaskController.stop()
    }
  }

  /**
   * 重新申请长时任务并恢复当前代次的 PCM 播放。
   *
   * @param generation 当前朗读任务代次。
   */
  private async resumeInternal(generation: number): Promise<void> {
    if (!this.isActivePlayback(generation) || !this.playbackPauseRequested) {
      return
    }
    this.playbackPauseRequested = false
    if (this.backgroundPlaybackEnabled) {
      const backgroundTaskStarted: boolean = await this.backgroundTaskController.start()
      if (!this.isActivePlayback(generation)) {
        return
      }
      if (!backgroundTaskStarted && this.backgroundWarningGeneration !== generation) {
        this.backgroundWarningGeneration = generation
        appStore.showToast('后台朗读启动失败，熄屏后可能中断')
      }
    }
    if (!this.pcmPlaybackStarted) {
      if (this.backgroundPlaybackEnabled) {
        this.avSessionController.setPreparing()
      }
      return
    }
    let resumed: boolean = false
    try {
      resumed = await this.pcmRenderer.resume()
    } catch (error) {
      this.rollbackFailedResume(generation)
      throw new Error(formatError(error))
    }
    if (resumed && this.isActivePlayback(generation) && this.backgroundPlaybackEnabled) {
      this.avSessionController.setResumed()
    } else if (!resumed) {
      this.rollbackFailedResume(generation)
    }
  }

  /**
   * 恢复 PCM 播放失败时还原暂停状态和后台资源。
   *
   * @param generation 当前朗读任务代次。
   */
  private rollbackFailedResume(generation: number): void {
    if (!this.isActivePlayback(generation)) {
      return
    }
    this.playbackPauseRequested = true
    if (this.backgroundPlaybackEnabled) {
      this.avSessionController.setPaused()
      this.backgroundTaskController.stop()
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
   *
   * @param completed 是否为自然播放完成。
   */
  private finishPlayback(completed: boolean = false): void {
    const avSessionActive: boolean = this.backgroundPlaybackEnabled
    this.pcmRenderer.stop()
    this.speakingPid = -1
    this.pendingChunks = []
    this.chunkIndex = 0
    this.clearActiveRequest()
    this.backgroundPlaybackEnabled = false
    this.backgroundWarningGeneration = -1
    this.startToastGeneration = -1
    this.playbackPauseRequested = false
    this.pcmPlaybackStarted = false
    this.backgroundTaskController.stop()
    if (avSessionActive) {
      this.avSessionController.stop(completed)
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
   * 响应系统取消长时任务事件。
   */
  private handleBackgroundTaskCancelled(): void {
    if (!this.backgroundPlaybackEnabled) {
      return
    }
    this.stopInternal()
    appStore.showToast('后台朗读已停止')
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
