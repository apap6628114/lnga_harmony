import { audio } from '@kit.AudioKit'
import { textToSpeech } from '@kit.CoreSpeechKit'
import { DOMAIN_MEDIA, formatError, Logger } from '../utils/Logger'

const logger: Logger = new Logger(DOMAIN_MEDIA, 'TtsPcmRenderer')

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

  /**
   * 开始接收一次完整朗读任务的 PCM 数据。
   *
   * @param generation 当前播放代次。
   */
  begin(generation: number): void {
    this.stop()
    this.generation = generation
    this.bufferedBytes = 0
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
   * @returns 数据是否已加入当前任务。
   */
  enqueue(buffer: ArrayBuffer, generation: number): boolean {
    if (generation !== this.generation) {
      return false
    }
    if (buffer.byteLength > 0) {
      this.buffers.push(buffer.slice(0))
      this.bufferedBytes += buffer.byteLength
    }
    return true
  }

  /**
   * 播放已经完整合成的 PCM 数据并释放渲染器。
   *
   * @param generation 当前播放代次。
   * @returns 当前任务是否完整播放。
   */
  async complete(generation: number): Promise<boolean> {
    const response: textToSpeech.StartResponse | null = this.startResponse
    if (generation !== this.generation || response === null) {
      return false
    }
    const buffers: ArrayBuffer[] = this.buffers
    const bufferedBytes: number = this.bufferedBytes
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
      logger.info(
        'TTS PCM renderer started: %{public}dHz/%{public}dbit, channel code %{public}d, bytes: %{public}d',
        response.sampleRate,
        response.sampleBit,
        response.audioChannel,
        bufferedBytes
      )
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
      await renderer.drain()
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
      }
    }
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
        usage: audio.StreamUsage.STREAM_USAGE_VOICE_ASSISTANT,
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
      const remaining: ArrayBuffer = offset === 0 ? buffer : buffer.slice(offset)
      const written: number = await renderer.write(remaining)
      if (written <= 0) {
        throw new Error('AudioRenderer did not consume PCM data')
      }
      offset += written
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
