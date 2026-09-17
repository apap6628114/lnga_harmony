/**
 * 动态照片沙箱缓存：路径、下载与占用治理（单源）。
 *
 * 动态照片播放需要把「封面图 + 视频」两份资源落到应用沙箱后交给
 * `MediaAssetManager.loadMovingPhoto`，因此这一份缓存被两处共用：
 * - `MovingPhotoPlayer`：播放前取得文件；
 * - `ImageViewer`：保存动态照片时复用同一份缓存（避免把视频重下一遍）。
 *
 * 目录位于持久目录 `filesDir` 下（官方指南的 `loadMovingPhoto` 示例同样使用 `filesDir`），
 * 不在系统 `cacheDir` 范围内、系统不会回收，因此由 `SettingsPanel.clearCache` 显式清理。
 *
 * ## 占用与淘汰
 * {@link ensureMovingPhotoFiles} 返回的 {@link MovingPhotoPair} 会**占用**封面与视频两个文件
 * （引用计数 +1），调用方必须配对调用 {@link releaseMovingPhotoFiles}。淘汰时跳过
 * 「有占用」与「下载中」的文件：删掉正在播放的文件会让播放失败，删掉正在写入的文件
 * 会让 `renameSync` 失败。**清理整目录的「清除缓存」不受此保护**（见该函数注释）。
 */

import { http } from '@kit.NetworkKit'
import { fileIo } from '@kit.CoreFileKit'
import { Logger, DOMAIN_UI, formatError } from '../utils/Logger'

const logger = new Logger(DOMAIN_UI, 'MovingPhotoCache')

/** 缓存目录名（位于应用 `filesDir` 下）。 */
export const MOVING_PHOTO_CACHE_DIR: string = 'mphoto'

/** 缓存文件数兜底上限：一组动态照片占 2 个文件（封面 + 视频），80 个文件 ≈ 40 组。 */
const MAX_CACHE_FILES: number = 80

/**
 * 缓存总体积上限（字节）。
 *
 * 体积由视频主导：只限文件数时，120 个文件可能是 GB 级（10s 视频几 MB 到十几 MB），
 * 而该目录位于持久区、系统不会像 `cacheDir` 那样回收。256MB ≈ 十几到几十组动态照片。
 */
const MAX_CACHE_BYTES: number = 256 * 1024 * 1024

/**
 * 单次下载的响应体积上限（`HttpRequestOptions.maxLimit`，官方上限 100MB）。
 *
 * 不设时依赖官方默认值，而该默认值在官方文档里自相矛盾（`request()` 的说明写
 * 「API 23 起上限 50MB」，`maxLimit` 字段又写「默认 5MB、最大 100MB」）；
 * 显式声明把边界变成自己的取值，超限的下载会失败而不是拿到半个文件。
 */
const MAX_DOWNLOAD_BYTES: number = 64 * 1024 * 1024

/**
 * 计算动态照片缓存目录的绝对路径。
 *
 * @param filesDir 应用持久目录（`Context.filesDir`）
 * @returns 缓存目录绝对路径
 */
export function movingPhotoCacheDir(filesDir: string): string {
  return `${filesDir}/${MOVING_PHOTO_CACHE_DIR}`
}

/**
 * 计算 URL 的稳定短哈希，用于沙箱缓存文件名。
 *
 * FNV-1a 32 位 + URL 长度前缀：只用哈希不用原 URL 作文件名（NGA 附件名可能带
 * 查询串与特殊字符，直接落盘有非法字符与超长风险），长度前缀进一步降低不同 URL
 * 命中同一缓存文件的概率（纯 32 位截断哈希存在静默串图风险）。
 *
 * @param url 资源地址
 * @returns 36 进制哈希字符串
 */
function hashUrl(url: string): string {
  let hash: number = 0x811c9dc5
  for (let i: number = 0; i < url.length; i++) {
    hash = hash ^ url.charCodeAt(i)
    hash = (hash * 0x01000193) | 0
  }
  if (hash < 0) {
    hash = -hash
  }
  return `${url.length.toString(36)}${hash.toString(36)}`
}

/**
 * 取 URL 的扩展名（小写、不含点）。
 *
 * @param url 资源地址
 * @param fallback 无法识别时的回退扩展名
 * @returns 扩展名
 */
function extensionOf(url: string, fallback: string): string {
  const match: RegExpMatchArray | null = url.match(/\.(\w{2,5})(?:[?#]|$)/)
  if (match === null) {
    return fallback
  }
  const ext: string = match[1].toLowerCase()
  if (ext === 'jpeg') {
    return 'jpg'
  }
  return ext
}

/**
 * 计算某个资源地址在缓存目录中的绝对路径。
 *
 * @param dir 缓存目录绝对路径
 * @param url 资源地址
 * @param fallbackExt 无法识别扩展名时的回退值
 * @returns 缓存文件绝对路径
 */
function cachePathOf(dir: string, url: string, fallbackExt: string): string {
  return `${dir}/${hashUrl(url)}.${extensionOf(url, fallbackExt)}`
}

/** 缓存淘汰项（文件路径 + 修改时间 + 体积）。 */
class CacheEntry {
  /** 文件绝对路径。 */
  path: string = ''
  /** 修改时间（秒，`fileIo.Stat.mtime`）。 */
  mtime: number = 0
  /** 文件体积（字节）。 */
  size: number = 0

  /**
   * @param path 文件绝对路径
   * @param mtime 修改时间（秒）
   * @param size 文件体积（字节）
   */
  constructor(path: string, mtime: number, size: number) {
    this.path = path
    this.mtime = mtime
    this.size = size
  }
}

/**
 * 进行中的下载表（目标文件路径 → 下载 Promise）。
 *
 * 同一资源可能被多个组件同时需要（查看器相邻两张都是动态照片时 `@Watch` 会触发两次；
 * 正文就地播放下载中又打开查看器），若各自以目标文件名直接写，后到者会读到**尚未写完**
 * 的文件并把坏文件永久留在缓存里，失败分支还会删掉别人正在用的文件。
 */
const inFlightDownloads: Map<string, Promise<boolean>> = new Map<string, Promise<boolean>>()

/** 在用文件引用计数（缓存文件路径 → 引用数），由 `ensureMovingPhotoFiles` 维护。 */
const activeFiles: Map<string, number> = new Map<string, number>()

/**
 * 动态照片的沙箱文件对（封面 + 视频）。
 *
 * 由 {@link ensureMovingPhotoFiles} 返回，持有期间会阻止缓存淘汰删除这两个文件。
 */
export class MovingPhotoPair {
  /** 封面文件绝对路径。 */
  coverPath: string = ''
  /** 视频文件绝对路径。 */
  videoPath: string = ''

  /**
   * @param coverPath 封面文件绝对路径
   * @param videoPath 视频文件绝对路径
   */
  constructor(coverPath: string, videoPath: string) {
    this.coverPath = coverPath
    this.videoPath = videoPath
  }
}

/**
 * 占用一个缓存文件（引用计数 +1）。
 *
 * @param path 缓存文件绝对路径
 */
function retainFile(path: string): void {
  const count: number | undefined = activeFiles.get(path)
  activeFiles.set(path, count === undefined ? 1 : count + 1)
}

/**
 * 释放一个缓存文件（引用计数 -1，归零时移出占用表）。
 *
 * @param path 缓存文件绝对路径
 */
function releaseFile(path: string): void {
  const count: number | undefined = activeFiles.get(path)
  if (count === undefined || count <= 1) {
    activeFiles.delete(path)
    return
  }
  activeFiles.set(path, count - 1)
}

/**
 * 确保缓存目录存在并返回其绝对路径。
 *
 * @param filesDir 应用持久目录
 * @returns 缓存目录绝对路径
 */
function ensureCacheDir(filesDir: string): string {
  const dir: string = movingPhotoCacheDir(filesDir)
  if (!fileIo.accessSync(dir)) {
    fileIo.mkdirSync(dir, true)
  }
  return dir
}

/**
 * 判断缓存文件是否可用（存在且非空）。
 *
 * 只判断存在会踩到"半成品文件"：并发写入期间或写入中断后，文件存在但内容不完整。
 *
 * @param filePath 沙箱文件路径
 * @returns 是否可直接复用
 */
function cachedFileUsable(filePath: string): boolean {
  try {
    if (!fileIo.accessSync(filePath)) {
      return false
    }
    return fileIo.statSync(filePath).size > 0
  } catch (err) {
    return false
  }
}

/**
 * 下载到临时文件后原子替换目标文件。
 *
 * 先写 `xxx.part` 再 rename：写入过程对其它组件不可见，杜绝"读到半个文件"；
 * 失败时只清理自己的临时文件，绝不删除目标文件（那可能是别的组件正在用的）。
 *
 * **必须校验响应**：`http.request` 对 4xx/5xx 同样是成功 resolve（错误页在 `result` 里），
 * 不判状态码就会把错误页当媒体文件落盘，而缓存命中只校验 `size > 0`——坏文件从此永久命中，
 * 该动态照片再也播不出来（除非清缓存或被淘汰）。
 *
 * @param url 资源地址
 * @param filePath 沙箱目标路径
 * @returns 是否下载成功
 */
async function downloadToFile(url: string, filePath: string): Promise<boolean> {
  const tempPath: string = `${filePath}.part`
  const httpRequest: http.HttpRequest = http.createHttp()
  let file: fileIo.File | undefined = undefined
  try {
    const response: http.HttpResponse = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      maxLimit: MAX_DOWNLOAD_BYTES
    })
    if (response.responseCode !== http.ResponseCode.OK) {
      logger.warn('[MovingPhotoCache] download http %{public}d: %{public}s', response.responseCode, url)
      return false
    }
    const data: ArrayBuffer = response.result as ArrayBuffer
    if (data.byteLength === 0) {
      logger.warn('[MovingPhotoCache] download empty body: %{public}s', url)
      return false
    }
    file = await fileIo.open(tempPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC)
    await fileIo.write(file.fd, data)
    fileIo.closeSync(file)
    file = undefined
    if (fileIo.accessSync(filePath)) {
      fileIo.unlinkSync(filePath)
    }
    fileIo.renameSync(tempPath, filePath)
    return true
  } catch (err) {
    logger.warn('[MovingPhotoCache] download failed: %{public}s', formatError(err))
    return false
  } finally {
    if (file !== undefined) {
      try {
        fileIo.closeSync(file)
      } catch (closeErr) {
        logger.verbose('[MovingPhotoCache] close failed: %{public}s', formatError(closeErr))
      }
    }
    try {
      if (fileIo.accessSync(tempPath)) {
        fileIo.unlinkSync(tempPath)
      }
    } catch (cleanupErr) {
      logger.verbose('[MovingPhotoCache] cleanup failed: %{public}s', formatError(cleanupErr))
    }
    httpRequest.destroy()
  }
}

/**
 * 确保沙箱内已有可用的目标文件（无则下载，同一文件并发请求会复用同一次下载）。
 *
 * @param url 资源地址
 * @param filePath 沙箱目标路径
 * @returns 文件是否可用
 */
async function ensureFile(url: string, filePath: string): Promise<boolean> {
  if (cachedFileUsable(filePath)) {
    return true
  }
  const pending: Promise<boolean> | undefined = inFlightDownloads.get(filePath)
  if (pending !== undefined) {
    return pending
  }
  const task: Promise<boolean> = downloadToFile(url, filePath)
  inFlightDownloads.set(filePath, task)
  try {
    return await task
  } finally {
    inFlightDownloads.delete(filePath)
  }
}

/**
 * 缓存淘汰：超预算时按修改时间从旧到新删除，直到体积与文件数都回落到上限的一半。
 *
 * 体积为主、文件数为兜底：只限文件数挡不住"少数几个大视频"，只限体积挡不住
 * "大量小封面撑爆目录条目"。留一半余量是为了摊销成本——否则每下载一组就要淘汰一次。
 * 跳过「有占用」（正在播放/正在保存）与「下载中」的文件。
 *
 * @param dir 缓存目录绝对路径
 */
function pruneCache(dir: string): void {
  try {
    const names: string[] = fileIo.listFileSync(dir)
    const entries: CacheEntry[] = []
    let totalBytes: number = 0
    for (let i: number = 0; i < names.length; i++) {
      try {
        const stat: fileIo.Stat = fileIo.statSync(`${dir}/${names[i]}`)
        entries.push(new CacheEntry(`${dir}/${names[i]}`, stat.mtime, stat.size))
        totalBytes += stat.size
      } catch (statErr) {
        /* 单个文件 stat 失败（可能正被删除）不影响其它条目。 */
      }
    }
    if (entries.length <= MAX_CACHE_FILES && totalBytes <= MAX_CACHE_BYTES) {
      return
    }
    entries.sort((a: CacheEntry, b: CacheEntry): number => a.mtime - b.mtime)
    let remainingBytes: number = totalBytes
    let remainingCount: number = entries.length
    const targetCount: number = Math.floor(MAX_CACHE_FILES / 2)
    const targetBytes: number = Math.floor(MAX_CACHE_BYTES / 2)
    for (let i: number = 0; i < entries.length; i++) {
      if (remainingCount <= targetCount && remainingBytes <= targetBytes) {
        break
      }
      const entry: CacheEntry = entries[i]
      if (inFlightDownloads.has(entry.path) || activeFiles.has(entry.path)) {
        continue
      }
      try {
        fileIo.unlinkSync(entry.path)
        remainingBytes -= entry.size
        remainingCount--
      } catch (unlinkErr) {
        /* 已被其它路径删除则忽略。 */
      }
    }
  } catch (err) {
    logger.verbose('[MovingPhotoCache] prune failed: %{public}s', formatError(err))
  }
}

/**
 * 取得一组动态照片的沙箱文件（封面 + 视频），必要时下载，并**占用**它们。
 *
 * 调用方必须配对调用 {@link releaseMovingPhotoFiles}：占用只影响淘汰，不影响读取，
 * 但忘记释放会让这两个文件永久免于淘汰。
 *
 * @param ctx 应用上下文（提供 `filesDir`）
 * @param coverUrl 封面图地址
 * @param videoUrl 动态视频地址
 * @returns 文件对；任一资源不可用时返回 null
 */
export async function ensureMovingPhotoFiles(ctx: Context, coverUrl: string,
  videoUrl: string): Promise<MovingPhotoPair | null> {
  if (coverUrl.length === 0 || videoUrl.length === 0) {
    return null
  }
  try {
    const dir: string = ensureCacheDir(ctx.filesDir)
    pruneCache(dir)
    const coverPath: string = cachePathOf(dir, coverUrl, 'jpg')
    const videoPath: string = cachePathOf(dir, videoUrl, 'mp4')
    const coverReady: boolean = await ensureFile(coverUrl, coverPath)
    const videoReady: boolean = await ensureFile(videoUrl, videoPath)
    if (!coverReady || !videoReady) {
      return null
    }
    const pair: MovingPhotoPair = new MovingPhotoPair(coverPath, videoPath)
    retainFile(coverPath)
    retainFile(videoPath)
    return pair
  } catch (err) {
    logger.warn('[MovingPhotoCache] ensure files failed: %{public}s', formatError(err))
    return null
  }
}

/**
 * 释放 {@link ensureMovingPhotoFiles} 占用的一对文件。
 *
 * @param pair 待释放的文件对
 */
export function releaseMovingPhotoFiles(pair: MovingPhotoPair): void {
  releaseFile(pair.coverPath)
  releaseFile(pair.videoPath)
}
