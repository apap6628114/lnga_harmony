/**
 * 存储后端 — 域的物理读写实现。
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §2.2 / §4。后端只负责"原始字节/字符串"的
 * 读写与目录管理，**不关心**域信封结构、迁移、合并语义（那些在 Hub / MigrationEngine / Transfer 层）。
 *
 * 两个后端：
 * - {@link PreferencesBackend}：Preferences 键值（异步 API，经 `PreferencesStore`）；
 * - {@link JsonFileBackend}：沙箱文件目录（同步 `fileIo`，与既有 DraftStore / SavedThreadStore 一致）。
 */

import { fileIo } from '@kit.CoreFileKit'
import { PreferencesStore } from '../infra/PreferencesStore'
import { Logger, DOMAIN_INFRA, formatError } from '../utils/Logger'
import type { DomainSpec } from './PersistenceTypes'

const logger = new Logger(DOMAIN_INFRA, 'StorageBackends')

/**
 * Preferences 后端 — 一个域对应一个键。
 */
export class PreferencesBackend {
  private readonly store: PreferencesStore

  /**
   * 构造 Preferences 后端。
   *
   * @param store - 已 iniit 的偏好存储（全应用共享同一实例）
   */
  constructor(store: PreferencesStore) {
    this.store = store
  }

  /**
   * 读取域的原始字符串。
   *
   * @param spec - 域元数据（必须为 PREFERENCES 介质）
   * @returns 原始字符串；键不存在或读取失败返回 null
   */
  async readRaw(spec: DomainSpec): Promise<string | null> {
    const key: string = spec.fullKey()
    if (key.length === 0) {
      return null
    }
    if (!(await this.store.hasKey(key))) {
      return null
    }
    const raw: string = await this.store.getString(key, '')
    return raw.length > 0 ? raw : null
  }

  /**
   * 写入域的原始字符串。
   *
   * @param spec - 域元数据
   * @param content - 完整信封 JSON 文本
   * @param flush - 是否立即刷盘
   * @returns 是否写入成功（失败只记日志，不抛错）
   */
  async writeRaw(spec: DomainSpec, content: string, flush: boolean = false): Promise<boolean> {
    const key: string = spec.fullKey()
    if (key.length === 0) {
      return false
    }
    try {
      // 双键 pending 保护（设计文档 §4.5）：先写临时键并刷盘，成功后再覆盖正式键。
      // Preferences 没有 rename 原语；最坏结果是"新数据未生效"，不会截断旧值。
      const pendingKey: string = key + '.pending'
      await this.store.putString(pendingKey, content, true)
      await this.store.putString(key, content, flush)
      await this.store.deleteKey(pendingKey, false)
      if (flush) {
        await this.store.flush()
      }
      /*
       * 读回校验：PreferencesStore 的 putString 内部 catch 掉异常、永不抛错，
       * 若不做读回校验，写失败会被上层当成功（导入/撤销"报成功但没写盘"）。
       * 代价是治理写入多一次读；迁移/导入是低频操作，可接受。
       */
      const readBack: string = await this.store.getString(key, '')
      if (readBack !== content) {
        logger.error('writeRaw verify failed domain=%{public}s', spec.id)
        return false
      }
      return true
    } catch (e) {
      logger.error('writeRaw failed domain=%{public}s: %{public}s', spec.id, formatError(e))
      return false
    }
  }

  /**
   * 删除域数据。
   *
   * @param spec - 域元数据
   * @returns 是否实际删除
   */
  async deleteDomain(spec: DomainSpec): Promise<boolean> {
    return await this.store.deleteKey(spec.fullKey(), true)
  }

  /**
   * 清理半截写入遗留的 pending 键（启动自检调用）。
   *
   * @param specs - 待检查的域
   */
  async cleanupPending(specs: DomainSpec[]): Promise<void> {
    for (let i: number = 0; i < specs.length; i++) {
      const key: string = specs[i].fullKey()
      if (key.length === 0) {
        continue
      }
      try {
        await this.store.deleteKey(key + '.pending', false)
      } catch (e) {
        // 清理是尽力而为，失败不影响启动
      }
    }
  }

  /**
   * 判断域键是否存在。
   *
   * @param spec - 域元数据
   * @returns 是否存在
   */
  async exists(spec: DomainSpec): Promise<boolean> {
    const key: string = spec.fullKey()
    return key.length > 0 ? await this.store.hasKey(key) : false
  }

  /**
   * 返回全部键名（迁移检测枚举旧键用）。
   *
   * @returns 键名数组
   */
  async listKeys(): Promise<string[]> {
    const all: Record<string, Object> = await this.store.getAll()
    return Object.keys(all)
  }
}

/**
 * JSON 文件后端 — 一个域对应 `filesDir/v2/<dir>/` 目录下的一批 JSON 文件。
 *
 * 同步 IO：文件域（草稿/存档）在既有实现中本就是同步读写（KB 级、调用点固定），
 * 保持同步可以避免把 `DraftStore.loadDraft` 等 20+ 调用点改成异步。大目录操作由调用方分批推进。
 */
export class JsonFileBackend {
  private readonly filesDir: string

  /**
   * 构造文件后端。
   *
   * @param filesDir - 应用沙箱持久目录
   */
  constructor(filesDir: string) {
    this.filesDir = filesDir
  }

  /**
   * 确保域目录存在。
   *
   * @param spec - 文件域元数据
   * @returns 目录路径（失败返回空串）
   */
  ensureDir(spec: DomainSpec): string {
    const dir: string = spec.dirPath(this.filesDir)
    if (dir.length === 0) {
      return ''
    }
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true)
      }
      return dir
    } catch (e) {
      logger.error('ensureDir failed domain=%{public}s: %{public}s', spec.id, formatError(e))
      return ''
    }
  }

  /**
   * 把遗留的错误命名空间目录整体改名到正确路径（不存在目标目录时才执行）。
   *
   * 背景：早期实现把文件域目录拼成 `filesDir/v2.<dir>`（点号来自键命名空间），
   * 正确路径是 `filesDir/v2/<dir>`。升级后若旧目录已有数据（用户迁移后新建的草稿/存档），
   * 需要搬移到新路径，否则 Store 读不到。
   *
   * @param legacyDir - 遗留目录绝对路径
   * @param newDir - 目标目录绝对路径
   * @returns 是否执行了搬移
   */
  renameDirIfAbsent(legacyDir: string, newDir: string): boolean {
    try {
      if (!fileIo.accessSync(legacyDir) || fileIo.accessSync(newDir)) {
        return false
      }
      const parentIndex: number = newDir.lastIndexOf('/')
      if (parentIndex > 0) {
        const parent: string = newDir.substring(0, parentIndex)
        if (!fileIo.accessSync(parent)) {
          fileIo.mkdirSync(parent, true)
        }
      }
      fileIo.renameSync(legacyDir, newDir)
      return true
    } catch (e) {
      logger.warn('renameDirIfAbsent failed: %{public}s', formatError(e))
      return false
    }
  }

  /**
   * 列出域目录下的文件名（不含子目录）。
   *
   * @param spec - 文件域元数据
   * @returns 文件名数组；目录不存在返回空数组
   */
  listFiles(spec: DomainSpec): string[] {
    const dir: string = spec.dirPath(this.filesDir)
    if (dir.length === 0) {
      return []
    }
    try {
      if (!fileIo.accessSync(dir)) {
        return []
      }
      return fileIo.listFileSync(dir)
    } catch (e) {
      logger.warn('listFiles failed domain=%{public}s: %{public}s', spec.id, formatError(e))
      return []
    }
  }

  /**
   * 读取域目录下的一个文本文件。
   *
   * @param spec - 文件域元数据
   * @param name - 文件名（必须是 `listFiles` 返回的名字，禁止包含路径分隔符）
   * @returns 文件内容；失败返回 null
   */
  readFile(spec: DomainSpec, name: string): string | null {
    if (!isSafeFileName(name)) {
      return null
    }
    const dir: string = spec.dirPath(this.filesDir)
    try {
      return fileIo.readTextSync(dir + '/' + name)
    } catch (e) {
      logger.warn('readFile failed domain=%{public}s name=%{public}s: %{public}s',
        spec.id, name, formatError(e))
      return null
    }
  }

  /**
   * 原子写入域目录下的一个文本文件（临时文件 + rename）。
   *
   * @param spec - 文件域元数据
   * @param name - 文件名
   * @param content - 文本内容
   * @returns 是否成功
   */
  writeFileAtomic(spec: DomainSpec, name: string, content: string): boolean {
    if (!isSafeFileName(name)) {
      return false
    }
    const dir: string = this.ensureDir(spec)
    if (dir.length === 0) {
      return false
    }
    const path: string = dir + '/' + name
    const tmpPath: string = path + '.tmp'
    let file: fileIo.File | null = null
    try {
      file = fileIo.openSync(tmpPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC)
      fileIo.writeSync(file.fd, content)
      fileIo.closeSync(file)
      file = null
      fileIo.renameSync(tmpPath, path)
      return true
    } catch (e) {
      logger.error('writeFileAtomic failed domain=%{public}s name=%{public}s: %{public}s',
        spec.id, name, formatError(e))
      if (file) {
        try {
          fileIo.closeSync(file)
        } catch (e2) {
        }
      }
      try {
        if (fileIo.accessSync(tmpPath)) {
          fileIo.unlinkSync(tmpPath)
        }
      } catch (e2) {
      }
      return false
    }
  }

  /**
   * 删除域目录下的一个文件。
   *
   * @param spec - 文件域元数据
   * @param name - 文件名
   * @returns 是否实际删除
   */
  deleteFile(spec: DomainSpec, name: string): boolean {
    if (!isSafeFileName(name)) {
      return false
    }
    const dir: string = spec.dirPath(this.filesDir)
    try {
      const path: string = dir + '/' + name
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path)
        return true
      }
    } catch (e) {
      logger.warn('deleteFile failed domain=%{public}s name=%{public}s', spec.id, name)
    }
    return false
  }

  /**
   * 清空域目录（递归删除文件与子目录）。
   *
   * `draft_media` 的布局是 `filesDir/draft_media/<草稿键>/<文件>`——只 `unlink` 文件删不掉
   * 子目录，会导致"清空本地数据"后媒体副本仍残留且占用最多上百 MB。这里统一递归。
   *
   * @param spec - 文件域元数据
   * @returns 删除的文件/目录数
   */
  clearDir(spec: DomainSpec): number {
    const dir: string = spec.dirPath(this.filesDir)
    if (dir.length === 0) {
      return 0;
    }
    return removeDirContentsRecursive(dir);
  }

  /**
   * 递归删除指定绝对目录的内容（不删除目录本身）。
   *
   * @param dirPath - 目录绝对路径
   * @returns 删除的文件数（子目录不计数）
   */
  clearAbsoluteDir(dirPath: string): number {
    return removeDirContentsRecursive(dirPath);
  }

  /**
   * 统计域目录占用字节数。
   *
   * @param spec - 文件域元数据
   * @returns 字节数（失败/不存在返回 0）
   */
  dirSizeBytes(spec: DomainSpec): number {
    const files: string[] = this.listFiles(spec)
    const dir: string = spec.dirPath(this.filesDir)
    let total: number = 0
    for (let i: number = 0; i < files.length; i++) {
      try {
        const stat: fileIo.Stat = fileIo.statSync(dir + '/' + files[i])
        total += stat.size
      } catch (e) {
        // 单个文件统计失败不影响总量
      }
    }
    return total
  }
}

/**
 * 校验文件名是否安全（防路径穿越）。
 *
 * 域目录内的文件名由业务生成（如 `<tid>.json`、`<草稿键>.json`），导入/迁移输入不可信。
 *
 * @param name - 文件名
 * @returns 是否可安全拼接
 */
export function isSafeFileName(name: string): boolean {
  if (name.length === 0 || name.length > 128) {
    return false
  }
  if (name.indexOf('/') >= 0 || name.indexOf('\\') >= 0 || name.indexOf('..') >= 0) {
    return false
  }
  return true
}

/**
 * 递归清空目录内容（保留目录本身）。
 *
 * @param dirPath - 目录绝对路径
 * @returns 删除的文件数（子目录本身不计入）
 */
export function removeDirContentsRecursive(dirPath: string): number {
  let removed: number = 0
  try {
    if (!fileIo.accessSync(dirPath)) {
      return 0
    }
    const names: string[] = fileIo.listFileSync(dirPath)
    for (let i: number = 0; i < names.length; i++) {
      const full: string = dirPath + '/' + names[i]
      try {
        const stat: fileIo.Stat = fileIo.statSync(full)
        if (stat.isDirectory()) {
          removed += removeDirContentsRecursive(full)
          try {
            fileIo.rmdirSync(full)
          } catch (e2) {
            // 非空/被占用：留给下次清理
          }
        } else {
          fileIo.unlinkSync(full)
          removed++
        }
      } catch (e) {
        // 单个条目失败不影响其余
      }
    }
  } catch (e) {
    logger.warn('removeDirContentsRecursive failed: %{public}s', formatError(e))
  }
  return removed
}
