/**
 * 草稿媒体本地副本存储。
 *
 * ## 为什么必须有副本
 * Picker 返回的 URI 是**临时授权**的，跨进程（甚至跨会话）就不可读；动态照片的导出产物
 * 更是落在 `cacheDir/mphoto_upload/<ts>/` 里、上传结束即被 `releaseExportedMovingPhoto`
 * 整目录删除。草稿里的图片要在**杀进程之后**仍能被重新上传（懒重传，见
 * `DRAFT_MEDIA_PLAN.md` 阶段 3），就必须有一份落在**持久区**的副本。
 *
 * ## 落盘形态
 * `filesDir/draft_media/<草稿键>/<序号>_<原始文件名>`——按草稿键分目录，草稿被放弃/
 * 超期/清缓存时整目录删除，不会给别的草稿留垃圾。
 *
 * 为何是 `filesDir` 而不是 `cacheDir`：后者会被系统回收，草稿却要跨会话甚至跨天存活。
 * 代价是这个目录**系统不会自动清**，因此由本模块的孤儿/容量淘汰与 `SettingsPanel.clearCache`
 * 显式清理共同兜底（与 `MovingPhotoCache` 同一取舍）。
 *
 * ## 淘汰口径：副本寿命**绑定草稿**，不独立按天淘汰
 * 草稿正文里的 `[img]` 标签是持久化的，副本一删，用户下次（可能离线）发送时懒重传就会撞上
 * "本地副本已不存在"的硬失败。因此本模块**没有**独立的"按 7 天淘汰媒体"：
 *
 * - **孤儿**（`DraftMediaClaim.isClaimed` 为假：磁盘上没有该键的草稿 JSON）→ **即时删除**，
 *   不看时间。A7 之前的实现要求孤儿还要满 7 天才删，于是刚产生的孤儿必然留着，
 *   而孤儿又不计入 `totalBytes` —— 128MB 上限形同虚设，磁盘占用无上界。
 * - **有主**（草稿 JSON 在 / 编辑器会话活跃）→ **一律豁免**，容量淘汰也不动它。
 * - 容量超限时**只在孤儿里挑**（按目录时间从旧到新整目录删，直到回落到上限的一半）；
 *   孤儿清完仍超限就记 warn 并保持现状——删掉有主副本是"用户数据丢失"，比超容量严重得多。
 *   A6 之前的实现把 `liveKeys` 里的目录一起排序、按 mtime 从旧到新删，
 *   于是**最旧的活跃草稿第一个被删**。
 *
 * 兜底：草稿自身满保留期由 `DraftStore.cleanupStale` 删除（`DRAFT_RETENTION_DAYS` 的**唯一**
 * 语义就是「草稿 JSON 的保留期」，定义在 `DraftStore` 里），随后它的媒体目录自动成为孤儿
 * 并在同一次清理里被回收。
 *
 * ## 为什么是"传 bytes"而不是"传来源路径让本模块自己拷"
 * 本地 SDK（API 26）`@ohos.file.fs` 的两个复制接口契约**不同**：
 * - `copy(srcUri, destUri, options?)`（@since 11）——两个参数**都是 URI**
 *   （`destUri` 的注释是 "URI of the destination file or directory"），裸沙箱路径不是合法入参；
 * - `copyFile(src, dest, mode?)` / `copyFileSync`——参数是 Path 或 FD，**不吃 URI**。
 *
 * 而草稿媒体的两个来源恰好一个 URI、一个路径：静态图来自 Picker 的 `file://media/...`，
 * 动态照片两半来自 `cacheDir` 的沙箱路径。要让某一个 API 同时吃下两者，就得引入
 * `fileUri.getUriFromPath` 一类的转换，把"复制"这件小事绑到 URI 语义上。
 *
 * 更省事也更可靠的路子是**绕开路径语义**：调用方本来就已经把字节读进内存了
 * （静态图在 `uploadStillImage` 读 Picker URI、动态照片在 `readExportedFile` 读导出产物），
 * 直接把 `ArrayBuffer` 交给本模块写盘即可——与 `SavedThreadStore` 的写文件路径同款。
 */

import { fileIo } from '@kit.CoreFileKit'
import { Context } from '@kit.AbilityKit'
import { Logger, DOMAIN_STORE, formatError } from '../utils/Logger'
import { removeDirRecursively } from '../utils/FileUtils'
import { isValidDraftKey } from '../managers/DraftStore'

const logger = new Logger(DOMAIN_STORE, 'DraftMediaStore')

/** 媒体副本根目录名（位于应用 `filesDir` 下）。 */
export const DRAFT_MEDIA_DIR_NAME: string = 'draft_media'

/**
 * 媒体副本总体积上限（字节）。
 *
 * 动态照片的视频单条可达数十 MB（`MovingPhotoCache` 用的是 256MB / 80 文件，那是"播放缓存"；
 * 草稿副本是"用户还没发出去的东西"，不需要那么多），取 128MB ≈ 数十张普通图或几组动态照片。
 *
 * 注意这是**有主副本豁免**下的软上限：孤儿清完仍超限时只会记 warn，不会删有主副本。
 */
export const DRAFT_MEDIA_MAX_BYTES: number = 128 * 1024 * 1024

/**
 * 把原始文件名清洗成可安全落盘的一段。
 *
 * 只保留字母/数字/`._-`，其余（含路径分隔符、中文、空格）替换为 `_`，并截断到 48 字符：
 * 文件名只用于**本地区分**，上传用的原始名另存在 `DraftMedia.fileName` 里，因此可以放心清洗。
 *
 * @param fileName - 原始文件名（或含路径的名字）
 * @returns 清洗后的文件名片段
 */
function sanitizeFileName(fileName: string): string {
  let base: string = fileName
  const slashIndex: number = base.lastIndexOf('/')
  if (slashIndex >= 0) {
    base = base.substring(slashIndex + 1)
  }
  const backslashIndex: number = base.lastIndexOf('\\')
  if (backslashIndex >= 0) {
    base = base.substring(backslashIndex + 1)
  }
  let out: string = ''
  for (let i: number = 0; i < base.length && out.length < 48; i++) {
    const c: string = base.charAt(i)
    const isAlnum: boolean = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    if (isAlnum || c === '.' || c === '_' || c === '-') {
      out += c
    } else {
      out += '_'
    }
  }
  return out.length > 0 ? out : 'media.bin'
}

/** 一个媒体目录的占用信息（容量淘汰用）。 */
class MediaDirEntry {
  /** 草稿键。 */
  key: string = ''
  /** 目录绝对路径。 */
  path: string = ''
  /** 目录内最新的修改时间（秒）。 */
  mtime: number = 0
  /** 目录占用字节数。 */
  size: number = 0

  /**
   * @param key 草稿键
   * @param path 目录绝对路径
   * @param mtime 最新修改时间（秒）
   * @param size 占用字节数
   */
  constructor(key: string, path: string, mtime: number, size: number) {
    this.key = key
    this.path = path
    this.mtime = mtime
    this.size = size
  }
}

/**
 * 一次媒体清理的结果。
 *
 * 分成「孤儿回收」与「容量淘汰」两个计数，是为了让线上日志能直接回答
 * 「这 128MB 是被谁占的、为什么没降下来」。
 */
export class DraftMediaCleanupResult {
  /** 本次删除的键（孤儿 + 容量淘汰）。 */
  removed: string[] = []

  /** 因"有草稿认领 / 会话活跃"而被容量淘汰跳过的目录数。 */
  protectedCount: number = 0

  /** 清理后仍超出容量上限（保留现状，仅记 warn）。 */
  overLimit: boolean = false
}

/**
 * 「这个键的媒体目录是否还有草稿认领」的判定入口。
 *
 * 由调用方（`AppStore.initDraftCleanup`，它同时持有 `draftStore`）构造。
 * 用注入的判定函数而不是把 `draftStore` 直接 import 进来，是为了让删除决策**依赖调用时的
 * 实时状态**（草稿文件现在还在不在），而不是启动时算出来的快照——
 * 清理跑在启动后 800ms，期间用户完全可能刚存下一份新草稿（A7 的误删防线之一）。
 */
export class DraftMediaClaim {
  /** 仍存在草稿 JSON 的键集合（启动时的快照，仅用于日志统计）。 */
  liveKeys: string[] = []

  /** 正在编辑的会话键（快照；`draftStore.activeKeyList()`）。 */
  activeKeys: string[] = []

  /**
   * 判定函数：该键当前是否有草稿认领。
   *
   * @param key - 草稿键
   * @returns true 表示磁盘上还有该键的草稿 JSON
   */
  isClaimed: (key: string) => boolean = (_key: string): boolean => false

  /**
   * 判断键是否在快照里（活跃会话键的兜底判定）。
   *
   * @param key - 草稿键
   * @returns 是否在 `liveKeys` 或 `activeKeys` 里
   */
  isListed(key: string): boolean {
    return containsString(this.liveKeys, key) || containsString(this.activeKeys, key)
  }

  /**
   * 综合判定：有主（豁免删除）。
   *
   * 三个判据取或：① 实时存在草稿文件；② 启动快照里有；③ 编辑器会话活跃。
   * ① 是主判据；②③ 覆盖"文件刚被删但会话还在编辑"这类中间态——
   * 那种情况下副本仍然是即将提交的内容的唯一来源，删了就是硬失败。
   *
   * @param key - 草稿键
   * @returns 是否豁免删除
   */
  isProtected(key: string): boolean {
    return this.isClaimed(key) || this.isListed(key)
  }
}

/** 草稿媒体副本存储（进程级单例，随 `AppStore.init` 初始化）。 */
export class DraftMediaStore {
  /** 应用上下文；未初始化时为空。 */
  private context: Context | null = null

  /** 根目录绝对路径。 */
  private dirPath: string = ''

  /** 同一次进程内追加副本的序号（保证同一毫秒内多次复制不重名）。 */
  private sequence: number = 0

  /**
   * 初始化：记录上下文并建立根目录。
   *
   * @param context 应用上下文（提供 `filesDir`）
   */
  async init(context: Context): Promise<void> {
    this.context = context
    this.dirPath = context.filesDir + '/' + DRAFT_MEDIA_DIR_NAME
    this.ensureRootDir()
  }

  /** 返回根目录绝对路径（清理接线用；未初始化时为空串）。 */
  get directory(): string {
    return this.dirPath
  }

  /** 建立根目录（幂等；失败只记日志）。 */
  private ensureRootDir(): void {
    if (this.context === null) {
      return
    }
    try {
      if (!fileIo.accessSync(this.dirPath)) {
        fileIo.mkdirSync(this.dirPath, true)
      }
    } catch (e) {
      logger.error('mkdir root failed: %{public}s', formatError(e))
    }
  }

  /**
   * 「清除缓存」整目录删除之后重建根目录。
   *
   * 不重建的话，本次进程内下一次 `saveCopy` 会走 `ensureKeyDir` 自己把根目录建回来
   * （`mkdirSync(dir, true)` 会补建父目录），看起来没坏；但 `directory` 这个 getter
   * 在根目录已消失时对外仍然报着一个不存在的路径，`cleanupStale` 的 `listFileSync` 也会
   * 直接抛（被 catch 吞成一行 verbose 日志）。重建一次的成本是两次 `accessSync`。
   */
  reloadAfterClear(): void {
    this.sequence = 0
    this.ensureRootDir()
  }

  /**
   * 确保某个草稿键的媒体目录存在。
   *
   * @param key - 草稿键
   * @returns 目录绝对路径；未初始化或键非法时为空串
   */
  private ensureKeyDir(key: string): string {
    if (this.context === null || !isValidDraftKey(key)) {
      return ''
    }
    const dir: string = this.dirPath + '/' + key
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true)
      }
      return dir
    } catch (e) {
      logger.error('mkdir key dir failed key=%{public}s: %{public}s', key, formatError(e))
      return ''
    }
  }

  /**
   * 把一份**已在内存中的字节**写成草稿媒体副本。
   *
   * 调用方负责把源读进内存：静态图来自 `uploadStillImage` 已读到的 buffer，
   * 动态照片两半来自 `readExportedFile`——两条链路都不必把 URI 语义带进来（见文件头）。
   *
   * @param key - 草稿键
   * @param data - 副本字节（0 字节视为失败）
   * @param fileName 原始文件名（用于生成可辨识的副本名）
   * @returns 副本绝对路径；失败时为空串（调用方据此放弃副本，不影响本次上传）
   */
  async saveCopy(key: string, data: ArrayBuffer, fileName: string): Promise<string> {
    if (data.byteLength === 0) {
      logger.warn('saveCopy skipped: empty data (key=%{public}s)', key)
      return ''
    }
    const dir: string = this.ensureKeyDir(key)
    if (dir.length === 0) {
      logger.warn('saveCopy skipped: store not ready (key=%{public}s)', key)
      return ''
    }
    this.sequence++
    const dest: string = dir + '/' + String(Date.now()) + '_' + String(this.sequence) + '_' +
      sanitizeFileName(fileName)
    if (writeBuffer(dest, data)) {
      return dest
    }
    return ''
  }

  /**
   * 删除某个草稿键的全部媒体副本。
   *
   * @param key - 草稿键
   */
  removeDraftMedia(key: string): void {
    if (this.context === null || !isValidDraftKey(key)) {
      return
    }
    removeDirRecursively(this.dirPath + '/' + key)
  }

  /**
   * 统计某个草稿键的媒体副本占用。
   *
   * @param key - 草稿键
   * @returns 字节数
   */
  draftMediaBytes(key: string): number {
    if (this.context === null || !isValidDraftKey(key)) {
      return 0
    }
    return dirBytes(this.dirPath + '/' + key)
  }

  /**
   * 统计**全部**媒体副本占用（设置页的草稿占用徽标用）。
   *
   * @returns 字节数（根目录不可用时为 0）
   */
  totalBytes(): number {
    if (this.context === null) {
      return 0
    }
    return dirBytes(this.dirPath)
  }

  /**
   * 媒体副本清理：**即时回收孤儿** + **只淘汰孤儿**的容量控制。
   *
   * 完整口径见文件头「淘汰口径」。这里只强调两条实现约束：
   * 1. 删除前对每个键**重新确认**草稿归属（`claim.isProtected`）——启动快照里没有的键，
   *    此刻可能已经有一份新草稿了；
   * 2. 容量淘汰只在孤儿里挑，有主的一律跳过；孤儿清完仍超限 → 记 warn 并保持。
   *
   * @param claim - 草稿归属判定（含实时确认函数）
   * @param maxBytes - 总体积上限（<=0 表示不按容量清理）
   * @returns 清理结果（删除的键 + 被豁免数 + 是否仍超限）
   */
  cleanupStale(claim: DraftMediaClaim, maxBytes: number): DraftMediaCleanupResult {
    const result: DraftMediaCleanupResult = new DraftMediaCleanupResult()
    if (this.context === null) {
      return result
    }
    const claimedEntries: MediaDirEntry[] = []
    let totalBytes: number = 0
    try {
      const names: string[] = fileIo.listFileSync(this.dirPath)
      for (let i: number = 0; i < names.length; i++) {
        const key: string = names[i]
        if (!isValidDraftKey(key)) {
          // 非键名的目录项（外部残留）：根目录只由本模块写，出现即异常，记 warn 不删
          logger.warn('unexpected entry in draft_media root: %{public}s', key)
          continue
        }
        const entry: MediaDirEntry = this.inspectDir(key)
        if (!claim.isProtected(key)) {
          // 孤儿：没有草稿认领，副本永远不可能被用到（正文里的标签早已随草稿一起消失）
          this.removeDraftMedia(key)
          result.removed.push(key)
          logger.info('reclaimed orphan media dir key=%{public}s bytes=%{public}d', key, entry.size)
          continue
        }
        totalBytes += entry.size
        claimedEntries.push(entry)
      }
    } catch (e) {
      logger.verbose('cleanupStale list failed: %{public}s', formatError(e))
      return result
    }

    if (maxBytes <= 0 || totalBytes <= maxBytes) {
      return result
    }

    // 超容量：候选只剩**有主**目录，它们一律豁免。这里记下数量与最旧的一条，
    // 让线上日志能直接回答「128MB 是被几个活跃草稿占着的、最旧的那个多久了」。
    result.protectedCount = claimedEntries.length
    if (claimedEntries.length === 0) {
      // 理论上不可达（没有有主目录就不可能有 totalBytes），留着是为了避免日志说反话
      return result
    }
    claimedEntries.sort((a: MediaDirEntry, b: MediaDirEntry): number => a.mtime - b.mtime)
    const oldest: MediaDirEntry = claimedEntries[0]
    logger.warn('draft media over limit bytes=%{public}d limit=%{public}d protected=%{public}d ' +
      'oldestKey=%{public}s oldestAgeSec=%{public}d; orphans already reclaimed, keep as is',
      totalBytes, maxBytes, result.protectedCount, oldest.key,
      Math.floor(Date.now() / 1000 - oldest.mtime))
    result.overLimit = true
    return result
  }

  /**
   * 读取一个键目录的占用信息。
   *
   * @param key - 草稿键
   * @returns 目录条目（目录不可用时 size/mtime 为 0）
   */
  private inspectDir(key: string): MediaDirEntry {
    const path: string = this.dirPath + '/' + key
    let size: number = 0
    let newest: number = 0
    try {
      const names: string[] = fileIo.listFileSync(path)
      for (let i: number = 0; i < names.length; i++) {
        try {
          const stat: fileIo.Stat = fileIo.statSync(path + '/' + names[i])
          size += stat.size
          if (stat.mtime > newest) {
            newest = stat.mtime
          }
        } catch (e) {
          /* 单个文件 stat 失败不影响统计 */
        }
      }
    } catch (e) {
      logger.verbose('inspectDir failed key=%{public}s: %{public}s', key, formatError(e))
    }
    return new MediaDirEntry(key, path, newest, size)
  }
}

/**
 * 判断键是否在数组中。
 *
 * 不用 `Array.prototype.includes`：ArkTS 子集对标准库方法有裁剪，显式循环与工程其它
 * 模块（如 `SavedThreadStore` 的查找）风格一致。
 *
 * @param keys - 键数组
 * @param key - 待查键
 * @returns 是否存在
 */
function containsString(keys: string[], key: string): boolean {
  for (let i: number = 0; i < keys.length; i++) {
    if (keys[i] === key) {
      return true
    }
  }
  return false
}

/**
 * 递归统计目录占用。
 *
 * @param dirPath - 目录绝对路径
 * @returns 字节数
 */
function dirBytes(dirPath: string): number {
  let total: number = 0
  try {
    if (!fileIo.accessSync(dirPath)) {
      return total
    }
    const names: string[] = fileIo.listFileSync(dirPath)
    for (let i: number = 0; i < names.length; i++) {
      const child: string = dirPath + '/' + names[i]
      try {
        if (fileIo.lstatSync(child).isDirectory()) {
          total += dirBytes(child)
        } else {
          total += fileIo.statSync(child).size
        }
      } catch (e) {
        /* 子项不可读时跳过 */
      }
    }
  } catch (e) {
    logger.verbose('dirBytes failed: %{public}s', formatError(e))
  }
  return total
}

/**
 * 把一段字节写成一个文件。
 *
 * 写失败必须清理目标文件：留下半成品会让懒重传读到"存在但内容不完整"的副本
 * （`readDraftMediaFile` 只判存在与非空，判不出截断）。
 *
 * @param dest - 目标沙箱绝对路径
 * @param data - 待写字节
 * @returns 是否写入成功且文件可用
 */
function writeBuffer(dest: string, data: ArrayBuffer): boolean {
  try {
    const file: fileIo.File = fileIo.openSync(dest,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC)
    try {
      fileIo.writeSync(file.fd, data)
    } finally {
      fileIo.closeSync(file)
    }
  } catch (e) {
    logger.warn('write copy failed: %{public}s', formatError(e))
    cleanup(dest)
    return false
  }
  return isUsable(dest)
}

/**
 * 判断文件是否存在且非空。
 *
 * 只判断存在会踩到"半成品文件"：写入中断后文件存在但内容不完整。
 *
 * @param filePath - 沙箱绝对路径
 * @returns 是否可用
 */
function isUsable(filePath: string): boolean {
  try {
    return fileIo.accessSync(filePath) && fileIo.statSync(filePath).size > 0
  } catch (e) {
    return false
  }
}

/**
 * 删除一个残留文件（不存在则忽略）。
 *
 * @param filePath - 沙箱绝对路径
 */
function cleanup(filePath: string): void {
  try {
    if (fileIo.accessSync(filePath)) {
      fileIo.unlinkSync(filePath)
    }
  } catch (e) {
    logger.verbose('cleanup failed: %{public}s', formatError(e))
  }
}

/**
 * 一次副本读取的结果。
 *
 * 「可读」与「内容」打包返回，避免调用方先判存在再读一次（两步之间有竞态，
 * 且判存在必须同时判非空——只判断存在会踩到复制中断留下的半成品文件）。
 */
export class DraftMediaFile {
  /** 文件内容；不可读时为 0 字节缓冲。 */
  data: ArrayBuffer = new ArrayBuffer(0)

  /** 是否读到可用内容（存在且非空）。 */
  usable: boolean = false
}

/**
 * 读取一份草稿媒体副本。
 *
 * 由懒重传（`DraftMediaUploader`）调用：副本不可用时必须让重传**明确失败**，
 * 而不是发出一条"正文有 `[img]`、服务端没收到附件"的回复。
 *
 * @param filePath - 副本绝对路径
 * @returns 读取结果
 */
export function readDraftMediaFile(filePath: string): DraftMediaFile {
  const result: DraftMediaFile = new DraftMediaFile()
  if (filePath.length === 0) {
    return result
  }
  try {
    if (!fileIo.accessSync(filePath)) {
      return result
    }
    const stat: fileIo.Stat = fileIo.statSync(filePath)
    if (stat.size <= 0) {
      return result
    }
    const buffer: ArrayBuffer = new ArrayBuffer(stat.size)
    const file: fileIo.File = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY)
    try {
      fileIo.readSync(file.fd, buffer)
    } finally {
      fileIo.closeSync(file)
    }
    result.data = buffer
    result.usable = true
  } catch (e) {
    logger.warn('readDraftMediaFile failed: %{public}s', formatError(e))
  }
  return result
}

/** 草稿媒体副本存储单例。 */
export const draftMediaStore = new DraftMediaStore()
