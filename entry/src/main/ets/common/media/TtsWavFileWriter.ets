import { fileIo } from '@kit.CoreFileKit'
import { textToSpeech } from '@kit.CoreSpeechKit'
import { DOMAIN_MEDIA, formatError, Logger } from '../utils/Logger'

const WAV_HEADER_BYTES: number = 44
const MAX_WAV_PCM_BYTES: number = 256 * 1024 * 1024
const MAX_PENDING_WRITE_BYTES: number = 32 * 1024 * 1024
const logger: Logger = new Logger(DOMAIN_MEDIA, 'TtsWavFileWriter')

/**
 * PCM 数据加入临时 WAV 文件写入队列的结果。
 */
export enum TtsAudioEnqueueResult {
  /** 数据已经加入当前任务的文件写入队列。 */
  ACCEPTED = 0,
  /** 数据不属于当前合成任务。 */
  INACTIVE = 1,
  /** 数据超过临时文件或待写内存的安全上限。 */
  LIMIT_EXCEEDED = 2,
  /** 临时文件此前已经发生写入错误。 */
  WRITE_FAILED = 3
}

/**
 * 已完成写入、可交给媒体播放器读取的 WAV 文件。
 */
export interface TtsWavFileSource {
  /** 只读 WAV 文件句柄。 */
  file: fileIo.File
  /** WAV 文件绝对路径。 */
  path: string
  /** WAV 文件总字节数。 */
  fileSize: number
  /** PCM 音频时长，单位为毫秒。 */
  durationMs: number
}

/**
 * 临时 WAV 文件写入器回调。
 */
export interface TtsWavFileWriterCallbacks {
  /** 异步文件写入失败时通知播放协调层。 */
  onError: (generation: number, error: Object) => void
}

/**
 * 单次 WAV 文件写入会话。
 */
interface TtsWavWriteSession {
  /** 写入会话所属的朗读任务代次。 */
  generation: number
  /** 临时 WAV 文件路径。 */
  path: string
  /** 当前可写文件句柄。 */
  file: fileIo.File
  /** 首个分段返回的 PCM 格式。 */
  format: textToSpeech.StartResponse | null
  /** 已接收的 PCM 数据总字节数。 */
  pcmBytes: number
  /** 已复制但尚未完成写入的 PCM 字节数。 */
  pendingBytes: number
  /** 串行文件写入任务。 */
  writeOperation: Promise<void>
  /** 首个异步写入错误的文本。 */
  writeError: string
  /** 会话是否已经取消。 */
  cancelled: boolean
}

/**
 * 将 ASCII 标识写入 WAV 头部。
 *
 * @param bytes WAV 头部字节数组。
 * @param offset 写入起始位置。
 * @param value ASCII 文本。
 */
function writeAscii(bytes: Uint8Array, offset: number, value: string): void {
  for (let index: number = 0; index < value.length; index++) {
    bytes[offset + index] = value.charCodeAt(index)
  }
}

/**
 * 将 CoreSpeechKit 的特殊声道编码转换为 WAV 声道数。
 *
 * @param audioChannel CoreSpeechKit 返回的声道编码。
 * @returns WAV 声道数。
 */
function resolveChannelCount(audioChannel: number): number {
  if (audioChannel === 2) {
    return 2
  }
  if (audioChannel === 1 || audioChannel === 3) {
    return 1
  }
  return 0
}

/**
 * 校验 PCM 格式是否可封装为标准 WAV 文件。
 *
 * @param response CoreSpeechKit 返回的 PCM 格式。
 * @returns 格式是否受支持。
 */
function isSupportedPcmFormat(response: textToSpeech.StartResponse): boolean {
  const channelCount: number = resolveChannelCount(response.audioChannel)
  const supportedBitDepth: boolean = response.sampleBit === 8 ||
    response.sampleBit === 16 ||
    response.sampleBit === 24 ||
    response.sampleBit === 32
  return response.audioType.trim().toLowerCase() === 'pcm' &&
    response.compressRate >= 0 &&
    response.sampleRate > 0 &&
    channelCount > 0 &&
    supportedBitDepth
}

/**
 * 判断两个 TTS 分段的 PCM 格式是否完全一致。
 *
 * @param left 已记录的 PCM 格式。
 * @param right 新分段的 PCM 格式。
 * @returns 两个格式是否一致。
 */
function isSamePcmFormat(
  left: textToSpeech.StartResponse,
  right: textToSpeech.StartResponse
): boolean {
  return left.sampleRate === right.sampleRate &&
    left.sampleBit === right.sampleBit &&
    left.audioChannel === right.audioChannel &&
    left.audioType.trim().toLowerCase() ===
      right.audioType.trim().toLowerCase() &&
    left.compressRate === right.compressRate
}

/**
 * 创建标准 PCM WAV 文件头。
 *
 * @param response PCM 格式。
 * @param pcmBytes PCM 数据字节数。
 * @returns 44 字节 WAV 文件头。
 */
function createWavHeader(
  response: textToSpeech.StartResponse,
  pcmBytes: number
): ArrayBuffer {
  const channelCount: number = resolveChannelCount(response.audioChannel)
  const bytesPerSample: number = response.sampleBit / 8
  const blockAlign: number = channelCount * bytesPerSample
  const byteRate: number = response.sampleRate * blockAlign
  const buffer: ArrayBuffer = new ArrayBuffer(WAV_HEADER_BYTES)
  const bytes: Uint8Array = new Uint8Array(buffer)
  const view: DataView = new DataView(buffer)
  writeAscii(bytes, 0, 'RIFF')
  view.setUint32(4, 36 + pcmBytes, true)
  writeAscii(bytes, 8, 'WAVE')
  writeAscii(bytes, 12, 'fmt ')
  view.setUint32(16, 16, true)
  view.setUint16(20, 1, true)
  view.setUint16(22, channelCount, true)
  view.setUint32(24, response.sampleRate, true)
  view.setUint32(28, byteRate, true)
  view.setUint16(32, blockAlign, true)
  view.setUint16(34, response.sampleBit, true)
  writeAscii(bytes, 36, 'data')
  view.setUint32(40, pcmBytes, true)
  return buffer
}

/**
 * 根据 PCM 格式和数据量计算音频时长。
 *
 * @param response PCM 格式。
 * @param pcmBytes PCM 数据字节数。
 * @returns 音频时长，单位为毫秒。
 */
function resolveDurationMs(
  response: textToSpeech.StartResponse,
  pcmBytes: number
): number {
  const bytesPerSample: number = response.sampleBit / 8
  const bytesPerSecond: number =
    response.sampleRate * resolveChannelCount(response.audioChannel) * bytesPerSample
  if (bytesPerSecond <= 0) {
    return 0
  }
  return Math.floor(pcmBytes * 1000 / bytesPerSecond)
}

/**
 * 将一段数据完整写入指定文件。
 *
 * @param file 文件句柄。
 * @param buffer 待写数据。
 */
async function writeFully(file: fileIo.File, buffer: ArrayBuffer): Promise<void> {
  let offset: number = 0
  while (offset < buffer.byteLength) {
    const remaining: ArrayBuffer = offset === 0 ? buffer : buffer.slice(offset)
    let written: number = 0
    try {
      written = await fileIo.write(file.fd, remaining)
    } catch (error) {
      throw new Error(formatError(error))
    }
    if (written <= 0) {
      throw new Error('File writer did not consume WAV data')
    }
    offset += written
  }
}

/**
 * 打开临时媒体文件并统一转换文件 API 异常。
 *
 * @param path 文件路径。
 * @param mode 文件打开模式。
 * @returns 已打开文件。
 */
async function openFile(path: string, mode: number): Promise<fileIo.File> {
  try {
    return await fileIo.open(path, mode)
  } catch (error) {
    throw new Error(formatError(error))
  }
}

/**
 * 以临时文件承接完整 TTS PCM 数据，并在合成结束后封装为可定位 WAV 媒体源。
 */
export class TtsWavFileWriter {
  /** 文件写入异常回调。 */
  private readonly callbacks: TtsWavFileWriterCallbacks
  /** 当前缓存目录。 */
  private cacheDir: string = ''
  /** 当前文件写入会话。 */
  private session: TtsWavWriteSession | null = null
  /** 临时文件名递增序号。 */
  private sequence: number = 0
  /** 使过期异步文件创建操作失效的生命周期代次。 */
  private lifecycleGeneration: number = 0
  /** 当前进程是否已经执行过遗留 TTS 缓存清理。 */
  private staleCleanupStarted: boolean = false
  /** 初始化阶段的遗留缓存清理任务。 */
  private initializationOperation: Promise<void> = Promise.resolve()

  /**
   * 创建临时 WAV 文件写入器。
   *
   * @param callbacks 文件写入异常回调。
   */
  constructor(callbacks: TtsWavFileWriterCallbacks) {
    this.callbacks = callbacks
  }

  /**
   * 设置应用缓存目录。
   *
   * @param cacheDir 应用缓存目录。
   */
  initialize(cacheDir: string): void {
    this.cacheDir = cacheDir
    if (cacheDir.length > 0 && !this.staleCleanupStarted) {
      this.staleCleanupStarted = true
      this.initializationOperation =
        this.cleanupStaleFiles(cacheDir).catch((error: Object): void => {
          logger.warn('Clean stale TTS WAV files failed: %{public}s', formatError(error))
        })
    }
  }

  /**
   * 创建单次朗读对应的临时 WAV 文件。
   *
   * @param generation 当前朗读任务代次。
   * @returns 临时文件是否创建成功。
   */
  async begin(generation: number): Promise<boolean> {
    const lifecycleGeneration: number = ++this.lifecycleGeneration
    await this.releaseCurrentSession()
    await this.initializationOperation
    if (lifecycleGeneration !== this.lifecycleGeneration) {
      return false
    }
    if (this.cacheDir.length === 0) {
      throw new Error('TTS cache directory is unavailable')
    }
    this.sequence++
    const separator: string = this.cacheDir.endsWith('/') ? '' : '/'
    const path: string = this.cacheDir + separator + 'tts-' +
      Date.now().toString() + '-' + generation.toString() + '-' +
      this.sequence.toString() + '.wav'
    const mode: number = fileIo.OpenMode.CREATE |
      fileIo.OpenMode.READ_WRITE |
      fileIo.OpenMode.TRUNC
    const file: fileIo.File = await openFile(path, mode)
    if (lifecycleGeneration !== this.lifecycleGeneration) {
      await this.closeAndDelete(file, path)
      return false
    }
    try {
      await writeFully(file, new ArrayBuffer(WAV_HEADER_BYTES))
    } catch (error) {
      await this.closeAndDelete(file, path)
      throw new Error(formatError(error))
    }
    if (lifecycleGeneration !== this.lifecycleGeneration) {
      await this.closeAndDelete(file, path)
      return false
    }
    this.session = {
      generation: generation,
      path: path,
      file: file,
      format: null,
      pcmBytes: 0,
      pendingBytes: 0,
      writeOperation: Promise.resolve(),
      writeError: '',
      cancelled: false
    }
    return true
  }

  /**
   * 记录并校验当前 TTS 分段的 PCM 格式。
   *
   * @param response PCM 格式。
   * @param generation 当前朗读任务代次。
   * @returns 格式是否属于当前任务且受 WAV 封装支持。
   */
  prepare(response: textToSpeech.StartResponse, generation: number): boolean {
    const session: TtsWavWriteSession | null = this.session
    if (session === null || session.generation !== generation || session.cancelled) {
      return false
    }
    if (!isSupportedPcmFormat(response)) {
      return false
    }
    const currentFormat: textToSpeech.StartResponse | null = session.format
    if (currentFormat === null) {
      session.format = response
      return true
    }
    return isSamePcmFormat(currentFormat, response)
  }

  /**
   * 将 PCM 数据复制到当前临时文件的串行写入队列。
   *
   * @param buffer PCM 数据。
   * @param generation 当前朗读任务代次。
   * @returns 数据入队结果。
   */
  enqueue(buffer: ArrayBuffer, generation: number): TtsAudioEnqueueResult {
    const session: TtsWavWriteSession | null = this.session
    if (session === null || session.generation !== generation || session.cancelled) {
      return TtsAudioEnqueueResult.INACTIVE
    }
    if (session.writeError.length > 0) {
      return TtsAudioEnqueueResult.WRITE_FAILED
    }
    if (buffer.byteLength === 0) {
      return TtsAudioEnqueueResult.ACCEPTED
    }
    if (session.pcmBytes + buffer.byteLength > MAX_WAV_PCM_BYTES ||
      session.pendingBytes + buffer.byteLength > MAX_PENDING_WRITE_BYTES) {
      return TtsAudioEnqueueResult.LIMIT_EXCEEDED
    }
    const copiedBuffer: ArrayBuffer = buffer.slice(0)
    session.pcmBytes += copiedBuffer.byteLength
    session.pendingBytes += copiedBuffer.byteLength
    session.writeOperation = session.writeOperation.then(async (): Promise<void> => {
      try {
        if (!session.cancelled && session.writeError.length === 0) {
          await writeFully(session.file, copiedBuffer)
        }
      } finally {
        session.pendingBytes = Math.max(0, session.pendingBytes - copiedBuffer.byteLength)
      }
    }).catch((error: Object): void => {
      if (session.cancelled || session.writeError.length > 0) {
        return
      }
      session.writeError = formatError(error)
      this.callbacks.onError(session.generation, error)
    })
    return TtsAudioEnqueueResult.ACCEPTED
  }

  /**
   * 完成当前 WAV 文件，关闭写句柄并返回只读媒体源。
   *
   * @param generation 当前朗读任务代次。
   * @returns 可供 AVPlayer 使用的 WAV 文件；任务已失效时返回 null。
   */
  async finalize(generation: number): Promise<TtsWavFileSource | null> {
    const session: TtsWavWriteSession | null = this.session
    if (session === null || session.generation !== generation || session.cancelled) {
      return null
    }
    this.session = null
    await session.writeOperation
    const format: textToSpeech.StartResponse | null = session.format
    if (session.writeError.length > 0) {
      await this.closeAndDelete(session.file, session.path)
      throw new Error(session.writeError)
    }
    if (format === null || session.pcmBytes <= 0) {
      await this.closeAndDelete(session.file, session.path)
      throw new Error('TTS did not return PCM data')
    }
    const bytesPerFrame: number =
      resolveChannelCount(format.audioChannel) * format.sampleBit / 8
    if (bytesPerFrame <= 0 || session.pcmBytes % bytesPerFrame !== 0) {
      await this.closeAndDelete(session.file, session.path)
      throw new Error('TTS returned incomplete PCM sample data')
    }
    try {
      fileIo.lseek(session.file.fd, 0, fileIo.WhenceType.SEEK_SET)
      await writeFully(session.file, createWavHeader(format, session.pcmBytes))
      await fileIo.close(session.file)
      const readFile: fileIo.File =
        await openFile(session.path, fileIo.OpenMode.READ_ONLY)
      return {
        file: readFile,
        path: session.path,
        fileSize: WAV_HEADER_BYTES + session.pcmBytes,
        durationMs: resolveDurationMs(format, session.pcmBytes)
      }
    } catch (error) {
      await this.closeAndDelete(session.file, session.path)
      throw new Error(formatError(error))
    }
  }

  /**
   * 取消当前写入会话并删除临时文件。
   */
  async discard(): Promise<void> {
    this.lifecycleGeneration++
    await this.releaseCurrentSession()
  }

  /**
   * 释放当前写入会话，但不改变外层生命周期代次。
   */
  private async releaseCurrentSession(): Promise<void> {
    const session: TtsWavWriteSession | null = this.session
    this.session = null
    if (session === null) {
      return
    }
    session.cancelled = true
    await session.writeOperation
    await this.closeAndDelete(session.file, session.path)
  }

  /**
   * 关闭文件句柄并删除临时文件。
   *
   * @param file 待关闭文件。
   * @param path 待删除路径。
   */
  private async closeAndDelete(file: fileIo.File, path: string): Promise<void> {
    try {
      await fileIo.close(file)
    } catch (error) {
      logger.warn('Close temporary TTS WAV failed: %{public}s', formatError(error))
    }
    try {
      await fileIo.unlink(path)
    } catch (error) {
      logger.warn('Delete temporary TTS WAV failed: %{public}s', formatError(error))
    }
  }

  /**
   * 清理上次进程异常结束后遗留的 TTS 临时文件。
   *
   * @param cacheDir 应用缓存目录。
   */
  private async cleanupStaleFiles(cacheDir: string): Promise<void> {
    let names: string[] = []
    try {
      names = await fileIo.listFile(cacheDir)
    } catch (error) {
      throw new Error(formatError(error))
    }
    const separator: string = cacheDir.endsWith('/') ? '' : '/'
    for (let index: number = 0; index < names.length; index++) {
      const name: string = names[index]
      if (!name.startsWith('tts-') || !name.endsWith('.wav')) {
        continue
      }
      try {
        await fileIo.unlink(cacheDir + separator + name)
      } catch (error) {
        logger.warn('Delete stale TTS WAV failed: %{public}s', formatError(error))
      }
    }
  }
}
