import { audio } from '@kit.AudioKit'
import { textToSpeech } from '@kit.CoreSpeechKit'
import { DOMAIN_MEDIA, formatError, Logger } from '../utils/Logger'

const logger: Logger = new Logger(DOMAIN_MEDIA, 'TtsPcmRenderer')
const MAX_BUFFERED_PCM_BYTES: number = 64 * 1024 * 1024

/**
 * PCM 数据加入完整朗读缓冲区的结果。
 */
export enum TtsPcmEnqueueResult {
  /** 数据已经加入当前任务。 */
  ACCEPTED = 0,
  /** 数据不属于当前播放任务。 */
  INACTIVE = 1,
  /** 数据会使完整朗读缓冲区超过内存上限。 */
  LIMIT_EXCEEDED = 2
}

/**
 * 计算 PCM 音频的实际声道数。
 *
 * @param channelCount TTS 返回的声道数。
 * @returns PCM 数据的实际声道数。
 */
function resolveChannelCount(channelCount: number): number {
  return channelCount === 2 ? 2 : 1
}

/**
 * 根据 PCM 格式和数据量计算音频时长。
 *
 * @param response TTS 音频参数。
 * @param bufferedBytes PCM 数据总字节数。
 * @returns 音频时长，单位为毫秒。
 */
function resolveDurationMs(
  response: textToSpeech.StartResponse,
  bufferedBytes: number
): number {
  const bytesPerSample: number = response.sampleBit / 8
  const bytesPerSecond: number =
    response.sampleRate * resolveChannelCount(response.audioChannel) * bytesPerSample
  if (bytesPerSecond <= 0) {
    return 0
  }
  return Math.floor(bufferedBytes * 1000 / bytesPerSecond)
}

/**
 * 将 TTS 返回的采样率转换为 AudioRenderer 支持的枚举值。
 *
 * @param samplingRate TTS 返回的采样率。
 * @returns 对应的音频采样率，不支持时返回 null。
 */
function resolveSamplingRate(samplingRate: number): audio.AudioSamplingRate | null {
  switch (samplingRate) {
    case 8000:
      return audio.AudioSamplingRate.SAMPLE_RATE_8000
    case 11025:
      return audio.AudioSamplingRate.SAMPLE_RATE_11025
    case 12000:
      return audio.AudioSamplingRate.SAMPLE_RATE_12000
    case 16000:
      return audio.AudioSamplingRate.SAMPLE_RATE_16000
    case 22050:
      return audio.AudioSamplingRate.SAMPLE_RATE_22050
    case 24000:
      return audio.AudioSamplingRate.SAMPLE_RATE_24000
    case 32000:
      return audio.AudioSamplingRate.SAMPLE_RATE_32000
    case 44100:
      return audio.AudioSamplingRate.SAMPLE_RATE_44100
    case 48000:
      return audio.AudioSamplingRate.SAMPLE_RATE_48000
    case 64000:
      return audio.AudioSamplingRate.SAMPLE_RATE_64000
    case 88200:
      return audio.AudioSamplingRate.SAMPLE_RATE_88200
    case 96000:
      return audio.AudioSamplingRate.SAMPLE_RATE_96000
    case 176400:
      return audio.AudioSamplingRate.SAMPLE_RATE_176400
    case 192000:
      return audio.AudioSamplingRate.SAMPLE_RATE_192000
    default:
      return null
  }
}

/**
 * 将 TTS 返回的采样位深转换为 AudioRenderer 支持的枚举值。
 *
 * @param sampleBit TTS 返回的采样位深。
 * @returns 对应的采样格式，不支持时返回 null。
 */
function resolveSampleFormat(sampleBit: number): audio.AudioSampleFormat | null {
  switch (sampleBit) {
    case 8:
      return audio.AudioSampleFormat.SAMPLE_FORMAT_U8
    case 16:
      return audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE
    case 24:
      return audio.AudioSampleFormat.SAMPLE_FORMAT_S24LE
    case 32:
      return audio.AudioSampleFormat.SAMPLE_FORMAT_S32LE
    default:
      return null
  }
}

/**
 * 将 TTS 返回的声道数转换为 AudioRenderer 支持的枚举值。
 * CoreSpeechKit 在 PCM 输出模式下会用数值 3 表示语音助手声音通道，
 * 实际合成数据仍为单声道 PCM。
 *
 * @param channelCount TTS 返回的声道数。
 * @returns 对应的音频声道，不支持时返回 null。
 */
function resolveAudioChannel(channelCount: number): audio.AudioChannel | null {
  switch (channelCount) {
    case 1:
      return audio.AudioChannel.CHANNEL_1
    case 2:
      return audio.AudioChannel.CHANNEL_2
    case 3:
      return audio.AudioChannel.CHANNEL_1
    default:
      return null
  }
}

/**
 * 使用 AudioRenderer 播放 TTS 合成的 PCM 数据。
 */
export class TtsPcmRenderer {
  /** 当前 PCM 数据所属的播放代次。 */
  private generation: number = -1
  /** TTS 返回的 PCM 格式。 */
  private startResponse: textToSpeech.StartResponse | null = null
  /** 合成阶段收到的 PCM 数据块。 */
  private buffers: ArrayBuffer[] = []
  /** 当前任务已缓冲的 PCM 字节数。 */
  private bufferedBytes: number = 0
  /** 当前正在播放的音频渲染器。 */
  private renderer: audio.AudioRenderer | null = null
  /** 当前渲染器是否正处于业务暂停状态。 */
  private playbackPaused: boolean = false
  /** 暂停期间阻止继续写入 PCM 数据的等待任务。 */
  private resumeSignal: Promise<void> | null = null
  /** 恢复播放时唤醒 PCM 写入任务的回调。 */
  private resumeResolver: (() => void) | null = null

  /**
   * 开始接收一次完整朗读任务的 PCM 数据。
   *
   * @param generation 当前播放代次。
   */
  begin(generation: number): void {
    this.stop()
    this.generation = generation
    this.bufferedBytes = 0
    this.playbackPaused = false
  }

  /**
   * 记录并校验 TTS 返回的 PCM 参数。
   *
   * @param response TTS 音频参数。
   * @param generation 当前播放代次。
   * @returns 参数是否属于当前任务且与已有 PCM 格式兼容。
   */
  prepare(response: textToSpeech.StartResponse, generation: number): boolean {
    if (generation !== this.generation) {
      return false
    }
    const currentResponse: textToSpeech.StartResponse | null = this.startResponse
    if (currentResponse === null) {
      this.startResponse = response
      return true
    }
    return currentResponse.sampleRate === response.sampleRate &&
      currentResponse.sampleBit === response.sampleBit &&
      currentResponse.audioChannel === response.audioChannel
  }

  /**
   * 保存一段 PCM 数据，等待整次任务合成完成后播放。
   *
   * @param buffer PCM 数据。
   * @param generation 当前播放代次。
   * @returns PCM 数据加入缓冲区的结果。
   */
  enqueue(buffer: ArrayBuffer, generation: number): TtsPcmEnqueueResult {
    if (generation !== this.generation) {
      return TtsPcmEnqueueResult.INACTIVE
    }
    if (buffer.byteLength > 0) {
      if (this.bufferedBytes + buffer.byteLength > MAX_BUFFERED_PCM_BYTES) {
        return TtsPcmEnqueueResult.LIMIT_EXCEEDED
      }
      this.buffers.push(buffer.slice(0))
      this.bufferedBytes += buffer.byteLength
    }
    return TtsPcmEnqueueResult.ACCEPTED
  }

  /**
   * 播放已经完整合成的 PCM 数据并释放渲染器。
   *
   * @param generation 当前播放代次。
   * @param onStarted 音频渲染器启动后的异步回调。
   * @returns 当前任务是否完整播放。
   */
  async complete(
    generation: number,
    onStarted: (durationMs: number) => Promise<void>
  ): Promise<boolean> {
    const response: textToSpeech.StartResponse | null = this.startResponse
    if (generation !== this.generation || response === null) {
      return false
    }
    const buffers: ArrayBuffer[] = this.buffers
    const bufferedBytes: number = this.bufferedBytes
    const durationMs: number = resolveDurationMs(response, bufferedBytes)
    this.buffers = []
    this.bufferedBytes = 0
    if (buffers.length === 0) {
      throw new Error('TTS did not return PCM data')
    }
    let renderer: audio.AudioRenderer | null = null
    try {
      renderer = await this.createRenderer(response)
      if (generation !== this.generation) {
        await this.releaseRenderer(renderer)
        renderer = null
        return false
      }
      await renderer.start()
      if (generation !== this.generation) {
        await this.releaseRenderer(renderer)
        renderer = null
        return false
      }
      this.renderer = renderer
      this.playbackPaused = false
      logger.info(
        'TTS PCM renderer started: %{public}dHz/%{public}dbit, channel code %{public}d, bytes: %{public}d',
        response.sampleRate,
        response.sampleBit,
        response.audioChannel,
        bufferedBytes
      )
      await onStarted(durationMs)
      if (generation !== this.generation) {
        return false
      }
      for (let index: number = 0; index < buffers.length; index++) {
        if (generation !== this.generation) {
          return false
        }
        await this.writeFully(renderer, buffers[index], generation)
        buffers[index] = new ArrayBuffer(0)
      }
      if (generation !== this.generation) {
        return false
      }
      await this.drainWhenResumed(renderer, generation)
      return generation === this.generation
    } finally {
      if (renderer !== null && this.renderer === renderer) {
        this.renderer = null
        await this.releaseRenderer(renderer)
      }
      if (generation === this.generation) {
        this.generation = -1
        this.startResponse = null
        this.buffers = []
        this.bufferedBytes = 0
        this.playbackPaused = false
        this.releaseResumeSignal()
      }
    }
  }

  /**
   * 暂停当前 PCM 播放。
   *
   * @returns 是否已经处于暂停状态。
   */
  async pause(): Promise<boolean> {
    const renderer: audio.AudioRenderer | null = this.renderer
    const generation: number = this.generation
    if (renderer === null || generation < 0) {
      return false
    }
    if (this.playbackPaused) {
      return true
    }
    this.playbackPaused = true
    this.ensureResumeSignal()
    try {
      await renderer.pause()
      return generation === this.generation && this.renderer === renderer
    } catch (error) {
      if (generation === this.generation && this.renderer === renderer) {
        this.playbackPaused = false
        this.releaseResumeSignal()
      }
      throw new Error(formatError(error))
    }
  }

  /**
   * 恢复当前 PCM 播放。
   *
   * @returns 是否已经恢复播放。
   */
  async resume(): Promise<boolean> {
    const renderer: audio.AudioRenderer | null = this.renderer
    const generation: number = this.generation
    if (renderer === null || generation < 0 || !this.playbackPaused) {
      return false
    }
    await renderer.start()
    if (generation !== this.generation || this.renderer !== renderer) {
      return false
    }
    this.playbackPaused = false
    this.releaseResumeSignal()
    return true
  }

  /**
   * 立即终止当前 PCM 播放并异步释放 AudioRenderer。
   */
  stop(): void {
    const renderer: audio.AudioRenderer | null = this.renderer
    this.generation = -1
    this.startResponse = null
    this.buffers = []
    this.bufferedBytes = 0
    this.renderer = null
    this.playbackPaused = false
    this.releaseResumeSignal()
    if (renderer !== null) {
      this.releaseRenderer(renderer).catch((error: Object): void => {
        logger.warn('Release stopped TTS AudioRenderer failed: %{public}s', formatError(error))
      })
    }
  }

  /**
   * 创建符合 TTS PCM 参数的 AudioRenderer。
   *
   * @param response TTS 音频参数。
   * @returns 创建完成的音频渲染器。
   */
  private async createRenderer(response: textToSpeech.StartResponse): Promise<audio.AudioRenderer> {
    const samplingRate: audio.AudioSamplingRate | null = resolveSamplingRate(response.sampleRate)
    const sampleFormat: audio.AudioSampleFormat | null = resolveSampleFormat(response.sampleBit)
    const channels: audio.AudioChannel | null = resolveAudioChannel(response.audioChannel)
    if (samplingRate === null || sampleFormat === null || channels === null) {
      throw new Error(
        'Unsupported TTS PCM format: ' + response.sampleRate.toString() + 'Hz/' +
        response.sampleBit.toString() + 'bit/' + response.audioChannel.toString() + 'ch'
      )
    }
    const options: audio.AudioRendererOptions = {
      streamInfo: {
        samplingRate: samplingRate,
        channels: channels,
        sampleFormat: sampleFormat,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      },
      rendererInfo: {
        usage: audio.StreamUsage.STREAM_USAGE_AUDIOBOOK,
        rendererFlags: 0
      }
    }
    return audio.createAudioRenderer(options)
  }

  /**
   * 确保整段 PCM 数据全部写入 AudioRenderer。
   *
   * @param renderer 音频渲染器。
   * @param buffer PCM 数据。
   * @param generation 当前播放代次。
   */
  private async writeFully(
    renderer: audio.AudioRenderer,
    buffer: ArrayBuffer,
    generation: number
  ): Promise<void> {
    let offset: number = 0
    while (offset < buffer.byteLength && generation === this.generation) {
      if (!await this.waitUntilResumed(generation)) {
        return
      }
      const remaining: ArrayBuffer = offset === 0 ? buffer : buffer.slice(offset)
      let written: number = 0
      try {
        written = await renderer.write(remaining)
      } catch (error) {
        if (this.playbackPaused && generation === this.generation) {
          continue
        }
        throw new Error(formatError(error))
      }
      if (written <= 0) {
        if (this.playbackPaused && generation === this.generation) {
          continue
        }
        throw new Error('AudioRenderer did not consume PCM data')
      }
      offset += written
    }
  }

  /**
   * 在业务暂停期间等待恢复命令。
   *
   * @param generation 当前播放代次。
   * @returns 当前任务是否仍可继续写入。
   */
  private async waitUntilResumed(generation: number): Promise<boolean> {
    while (this.playbackPaused && generation === this.generation) {
      const signal: Promise<void> = this.ensureResumeSignal()
      await signal
    }
    return generation === this.generation
  }

  /**
   * 在播放状态下等待渲染器排空，暂停造成的状态切换不会被视为播放错误。
   *
   * @param renderer 当前音频渲染器。
   * @param generation 当前播放代次。
   */
  private async drainWhenResumed(
    renderer: audio.AudioRenderer,
    generation: number
  ): Promise<void> {
    while (generation === this.generation) {
      if (!await this.waitUntilResumed(generation)) {
        return
      }
      try {
        await renderer.drain()
        return
      } catch (error) {
        if (!this.playbackPaused || generation !== this.generation) {
          throw new Error(formatError(error))
        }
      }
    }
  }

  /**
   * 创建或获取当前暂停周期的恢复信号。
   *
   * @returns 当前暂停周期的恢复信号。
   */
  private ensureResumeSignal(): Promise<void> {
    const currentSignal: Promise<void> | null = this.resumeSignal
    if (currentSignal !== null) {
      return currentSignal
    }
    const signal: Promise<void> = new Promise<void>((resolve: () => void): void => {
      this.resumeResolver = resolve
    })
    this.resumeSignal = signal
    return signal
  }

  /**
   * 释放当前暂停周期的恢复信号。
   */
  private releaseResumeSignal(): void {
    const resolver: (() => void) | null = this.resumeResolver
    this.resumeResolver = null
    this.resumeSignal = null
    if (resolver !== null) {
      resolver()
    }
  }

  /**
   * 停止并释放 AudioRenderer。
   *
   * @param renderer 音频渲染器。
   */
  private async releaseRenderer(renderer: audio.AudioRenderer): Promise<void> {
    try {
      await renderer.stop()
    } catch (error) {
      logger.warn('Stop TTS AudioRenderer failed: %{public}s', formatError(error))
    }
    try {
      await renderer.release()
    } catch (error) {
      logger.warn('Release TTS AudioRenderer failed: %{public}s', formatError(error))
    }
  }
}
