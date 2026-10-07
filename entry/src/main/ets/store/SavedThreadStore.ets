/**
 * 保存帖子存储 - 文件系统持久化（不按账号区分）。
 *
 * 存档目录为应用沙箱 `filesDir/saved_threads`，每份存档一个 `<archiveId>.json` 文件，
 * 内容为 SavedThread 的 JSON 序列化（含每页同形状原始 JSON）。内存缓存按保存
 * 时间（savedAt）降序维护，与查看页的排序口径一致。导入冲突按覆盖处理
 * （同 archiveId 直接覆盖）。
 *
 * **唯一键是 archiveId 而非 tid**：同一主题允许并存多份存档——原帖全量存档
 * （archiveId === tid）与「智能去水」派生的去水版（archiveId === tid + '-w'）。
 * 两者共用 tid，因此「在线模式打开」仍指向真实主题；用 tid 当键会让后写的
 * 一份直接覆盖另一份。存量存档没有 archiveId 字段，加载时回填为 tid。
 *
 * 写入采用「临时文件 + 重命名」原子替换：写失败不会截断/破坏已存在的旧存档；
 * archiveId 强制校验形状（纯数字，或纯数字 + `-w` 派生后缀），杜绝导入文件
 * 路径穿越越出存档目录。
 */

import { fileIo } from '@kit.CoreFileKit'
import { Context } from '@kit.AbilityKit'
import { bumpAppStorageVersion } from '../common/utils/AppStorageVersion'
import { KEY_SAVED_THREAD_VERSION } from '../common/constants/AppStorageKeys'
import { Logger, DOMAIN_STORE, formatError } from '../common/utils/Logger'
import {
  SavedThread,
  SavedThreadExportFile,
  SAVED_THREAD_SCHEMA_VERSION
} from '../model/SavedThread'

const logger = new Logger(DOMAIN_STORE, 'SavedThreadStore')

/** 存档子目录名（相对 filesDir）。 */
const SAVED_THREAD_DIR_NAME: string = 'saved_threads'

/** 派生存档（去水版）的 archiveId 后缀。 */
export const DERIVED_ARCHIVE_SUFFIX: string = '-w'

/**
 * 把 tid 归一为原帖存档的 archiveId（存量数据与新建存档共用同一口径）。
 *
 * @param tid - NGA 主题 ID
 * @returns 原帖存档的 archiveId
 */
export function baseArchiveIdOf(tid: string): string {
  return tid
}

/**
 * 生成去水版存档的 archiveId（同一主题只保留一份，重跑覆盖）。
 *
 * @param tid - NGA 主题 ID
 * @returns 去水版存档的 archiveId
 */
export function derivedArchiveIdOf(tid: string): string {
  return tid + DERIVED_ARCHIVE_SUFFIX
}

/**
 * 校验 archiveId 是否可安全用于存档文件名。
 *
 * 形状固定为「1~16 位纯数字」+ 可选派生后缀（`-w`）。导入文件为外部可控输入，
 * 必须拒绝含路径分隔符/`..` 等字符的 id，防止路径穿越越出存档目录；**不接受**
 * 任意后缀，避免派生键空间被外部文件随意扩张而绕开归档语义。
 *
 * @param id - 待校验的存档标识
 * @returns 是否合法
 */
function isValidArchiveId(id: string): boolean {
  const digits: string = id.endsWith(DERIVED_ARCHIVE_SUFFIX)
    ? id.substring(0, id.length - DERIVED_ARCHIVE_SUFFIX.length)
    : id
  if (digits.length === 0 || digits.length > 16) {
    return false
  }
  for (let i = 0; i < digits.length; i++) {
    const c: string = digits.charAt(i)
    if (c < '0' || c > '9') {
      return false
    }
  }
  return true
}

/** 导入结果汇总。 */
export class ImportResult {
  /** 成功导入（含覆盖）的帖子数。 */
  imported: number = 0
  /** 因数据无效/写入失败跳过的帖子数。 */
  skipped: number = 0
  /** 首个错误信息（无错误时为空串）。 */
  error: string = ''
}

export class SavedThreadStore {
  private context: Context | null = null
  private dirPath: string = ''
  /** 内存缓存，按 savedAt 降序。 */
  private items: SavedThread[] = []

  async init(context: Context): Promise<void> {
    this.context = context
    this.dirPath = context.filesDir + '/' + SAVED_THREAD_DIR_NAME
    try {
      if (!fileIo.accessSync(this.dirPath)) {
        fileIo.mkdirSync(this.dirPath)
      }
    } catch (e) {
      logger.error('init mkdir failed: %{public}s', formatError(e))
    }
    this.reload()
  }

  private filePathOf(archiveId: string): string {
    return this.dirPath + '/' + archiveId + '.json'
  }

  /**
   * 扫描存档目录重建内存缓存（按 savedAt 降序）。
   */
  reload(): void {
    if (this.context === null) {
      return
    }
    const list: SavedThread[] = []
    try {
      const names: string[] = fileIo.listFileSync(this.dirPath)
      for (let i = 0; i < names.length; i++) {
        const name: string = names[i]
        if (!name.endsWith('.json')) {
          continue
        }
        try {
          const raw: string = fileIo.readTextSync(this.dirPath + '/' + name)
          const parsed: SavedThread = JSON.parse(raw) as SavedThread
          // v2 存档要求具备可解释的同形状原始 JSON；损坏/旧格式文件跳过
          if (!parsed || !parsed.rawPages || parsed.rawPages.length === 0) {
            logger.warn('reload skip file: %{public}s', name)
            continue
          }
          this.normalizeArchive(parsed)
          // 标识非法（含路径穿越形态）的存档整体丢弃，不进入内存列表
          if (isValidArchiveId(parsed.archiveId) && isValidArchiveId(parsed.tid)) {
            list.push(parsed)
          }
        } catch (e) {
          logger.warn('reload skip file: %{public}s', name)
        }
      }
    } catch (e) {
      logger.error('reload failed: %{public}s', formatError(e))
    }
    list.sort((a: SavedThread, b: SavedThread): number => b.savedAt - a.savedAt)
    this.items = list
  }

  /**
   * 规整存档的可解释性字段：savedPages 缺失或与实际页数不一致时以实际页数为准，
   * 避免「列表显示 N 页但打开越界报缺失」的死档；lastLou 缺失（改动前存量存档）
   * 兜底为 0，避免列表显示 "undefined 楼" 技术字符串；archiveId 缺失（本字段引入
   * 前的存量存档）回填为 tid，derivedFrom 兜底为空串。
   *
   * @param thread - 待规整的存档（原地修改）
   */
  private normalizeArchive(thread: SavedThread): void {
    const archiveId: string = thread.archiveId
    if (archiveId === undefined || archiveId === null || archiveId.length === 0) {
      thread.archiveId = baseArchiveIdOf(thread.tid ?? '')
    }
    const derived: string = thread.derivedFrom
    if (derived === undefined || derived === null) {
      thread.derivedFrom = ''
    }
    if (thread.savedPages <= 0 || thread.savedPages !== thread.rawPages.length) {
      thread.savedPages = thread.rawPages.length
    }
    const lou: number = thread.lastLou
    if (lou === undefined || lou === null || lou <= 0) {
      thread.lastLou = 0
    }
  }

  /**
   * 返回全部存档（保存时间降序）的只读快照。
   */
  getAll(): SavedThread[] {
    const copy: SavedThread[] = []
    for (let i = 0; i < this.items.length; i++) {
      copy.push(this.items[i])
    }
    return copy
  }

  /**
   * 按 archiveId 查找存档。
   *
   * @param archiveId - 存档标识（见 SavedThread.archiveId）
   * @returns 存档；不存在时返回 null
   */
  getByArchiveId(archiveId: string): SavedThread | null {
    if (archiveId.length === 0) {
      return null
    }
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].archiveId === archiveId) {
        return this.items[i]
      }
    }
    return null
  }

  /**
   * 按「原帖 tid」查找原帖存档（不含去水版等派生存档）。
   *
   * @param tid - NGA 主题 ID
   * @returns 原帖存档；不存在时返回 null
   */
  getByTid(tid: string): SavedThread | null {
    return this.getByArchiveId(baseArchiveIdOf(tid))
  }

  /**
   * 是否已存在该主题的去水版存档。
   *
   * @param tid - NGA 主题 ID
   * @returns 是否已存在
   */
  hasDerivedArchive(tid: string): boolean {
    return this.getByArchiveId(derivedArchiveIdOf(tid)) !== null
  }

  /**
   * 返回存档数量。
   */
  count(): number {
    return this.items.length
  }

  /**
   * 取存档指定页的同形状原始 JSON。
   *
   * @param archiveId - 存档标识（见 SavedThread.archiveId）
   * @param page - 页码（从 1 开始）
   * @returns 该页原始数据；存档不存在、页号越界或数据缺失时返回 null
   */
  getRawPage(archiveId: string, page: number): Record<string, Object> | null {
    if (page < 1) {
      return null
    }
    for (let i = 0; i < this.items.length; i++) {
      const item: SavedThread = this.items[i]
      if (item.archiveId === archiveId) {
        if (page > item.rawPages.length) {
          return null
        }
        const raw: Object = item.rawPages[page - 1]
        if (raw === null || raw === undefined) {
          return null
        }
        return raw as Record<string, Object>
      }
    }
    return null
  }

  /**
   * 写入（覆盖）一份存档。
   *
   * 原子写：先写 `<archiveId>.json.tmp`，成功后再重命名替换目标文件；写失败时
   * 旧存档保持完整，临时文件被清理。覆盖粒度是 **archiveId**：写去水版
   * （`<tid>-w`）不会动到同主题的原帖存档。
   *
   * @param thread - 待保存的存档快照
   * @param notify - 是否 bump savedThreadVersion（批量导入时由调用方统一触发）
   */
  async save(thread: SavedThread, notify: boolean = true): Promise<void> {
    if (this.context === null) {
      throw new Error('存档未就绪')
    }
    // 先规整（archiveId 缺失时按 tid 回填），再做形状校验
    this.normalizeArchive(thread)
    if (!isValidArchiveId(thread.archiveId)) {
      throw new Error('存档标识无效')
    }
    const path: string = this.filePathOf(thread.archiveId)
    const tmpPath: string = path + '.tmp'
    const content: string = JSON.stringify(thread)
    let file: fileIo.File | null = null
    try {
      file = fileIo.openSync(tmpPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC)
      fileIo.writeSync(file.fd, content)
      fileIo.closeSync(file)
      file = null
      fileIo.renameSync(tmpPath, path)
    } catch (e) {
      logger.error('save failed archiveId=%{public}s: %{public}s', thread.archiveId, formatError(e))
      if (file) {
        try {
          fileIo.closeSync(file)
        } catch (e2) {}
      }
      // 清理残留临时文件，旧存档未被破坏
      try {
        if (fileIo.accessSync(tmpPath)) {
          fileIo.unlinkSync(tmpPath)
        }
      } catch (e2) {}
      throw new Error('写入存档失败')
    } finally {
      if (file) {
        try {
          fileIo.closeSync(file)
        } catch (e) {}
      }
    }
    // 更新内存缓存并保持降序（按 archiveId 去重）
    const filtered: SavedThread[] = []
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].archiveId !== thread.archiveId) {
        filtered.push(this.items[i])
      }
    }
    filtered.push(thread)
    filtered.sort((a: SavedThread, b: SavedThread): number => b.savedAt - a.savedAt)
    this.items = filtered
    if (notify) {
      bumpAppStorageVersion(KEY_SAVED_THREAD_VERSION)
    }
  }

  /**
   * 删除一份存档。
   *
   * @param archiveId - 存档标识（见 SavedThread.archiveId）
   */
  async remove(archiveId: string): Promise<void> {
    if (this.context === null) {
      throw new Error('存档未就绪')
    }
    if (!isValidArchiveId(archiveId)) {
      throw new Error('存档标识无效')
    }
    try {
      const path: string = this.filePathOf(archiveId)
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path)
      }
    } catch (e) {
      logger.error('remove failed archiveId=%{public}s: %{public}s', archiveId, formatError(e))
      throw new Error('删除存档失败')
    }
    const filtered: SavedThread[] = []
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].archiveId !== archiveId) {
        filtered.push(this.items[i])
      }
    }
    this.items = filtered
    bumpAppStorageVersion(KEY_SAVED_THREAD_VERSION)
  }

  /**
   * 清空全部存档。
   */
  async clear(): Promise<void> {
    if (this.context === null) {
      throw new Error('存档未就绪')
    }
    try {
      const names: string[] = fileIo.listFileSync(this.dirPath)
      for (let i = 0; i < names.length; i++) {
        if (names[i].endsWith('.json')) {
          try {
            fileIo.unlinkSync(this.dirPath + '/' + names[i])
          } catch (e) {}
        }
      }
    } catch (e) {
      logger.error('clear failed: %{public}s', formatError(e))
      throw new Error('清空存档失败')
    }
    this.items = []
    bumpAppStorageVersion(KEY_SAVED_THREAD_VERSION)
  }

  /**
   * 序列化一组帖子为导出文件内容（不加密）。
   *
   * @param threads - 待导出的帖子列表
   * @returns 导出文件 JSON 文本
   */
  serializeForExport(threads: SavedThread[]): string {
    const file: SavedThreadExportFile = new SavedThreadExportFile()
    file.exportedAt = Date.now()
    file.threads = threads
    return JSON.stringify(file)
  }

  /**
   * 解析并合并导入内容，冲突按覆盖处理。
   *
   * @param content - 导入文件文本
   * @returns 导入结果汇总；error 非空表示整体解析失败（此时 imported/skipped 均为 0）
   */
  async importContent(content: string): Promise<ImportResult> {
    const result: ImportResult = new ImportResult()
    if (this.context === null) {
      result.error = '存档未就绪'
      return result
    }
    if (!content || content.trim().length === 0) {
      result.error = '文件为空'
      return result
    }
    let parsed: SavedThreadExportFile
    try {
      parsed = JSON.parse(content) as SavedThreadExportFile
    } catch (e) {
      result.error = '文件不是有效的 JSON'
      return result
    }
    if (!parsed || parsed.schemaVersion !== SAVED_THREAD_SCHEMA_VERSION) {
      result.error = '文件格式版本不受支持'
      return result
    }
    if (!parsed.threads || parsed.threads.length === 0) {
      result.error = '文件中没有保存的帖子'
      return result
    }
    let hasAnyInvalid: boolean = false
    for (let i = 0; i < parsed.threads.length; i++) {
      const item: SavedThread = parsed.threads[i]
      if (!item || !item.rawPages || item.rawPages.length === 0) {
        result.skipped++
        hasAnyInvalid = true
        continue
      }
      if (item.savedAt <= 0) {
        item.savedAt = Date.now()
      }
      // 先规整（导出文件可能来自未含 archiveId 的旧版本），再校验键与 tid 形状
      this.normalizeArchive(item)
      if (!isValidArchiveId(item.archiveId) || !isValidArchiveId(item.tid || '')) {
        result.skipped++
        hasAnyInvalid = true
        continue
      }
      try {
        // 批量导入统一在循环结束后 bump 一次版本，避免逐帖触发列表全量刷新
        await this.save(item, false)
        result.imported++
      } catch (e) {
        result.skipped++
        if (result.error.length === 0) {
          result.error = '写入失败：' + formatError(e)
        }
      }
    }
    if (result.imported > 0) {
      bumpAppStorageVersion(KEY_SAVED_THREAD_VERSION)
    }
    if (result.error.length === 0 && hasAnyInvalid) {
      result.error = '部分条目无效已跳过（存档标识非法或缺少内容）'
    }
    return result
  }
}
