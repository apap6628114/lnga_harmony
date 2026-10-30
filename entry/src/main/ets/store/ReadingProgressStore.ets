import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { BaseStore } from './BaseStore'
import { DomainIds, PersistenceCatalog } from '../common/persistence/PersistenceCatalog'
import { DomainSpec } from '../common/persistence/PersistenceTypes'

/** 单帖阅读进度条目 */
export class ReadingProgressEntry {
  /** 主题 tid。 */
  tid: string = ''
  /** 锚点楼层所属页码（服务端页，从 1 开始）。 */
  page: number = 1
  /** 视口内锚点楼层 pid；小于 0 表示尚无有效锚点。 */
  pid: number = -1
  /** 最近更新时间戳（LRU 淘汰依据）。 */
  ts: number = 0
}

/** 阅读进度最多保留的帖子数（按最近阅读时间淘汰）。 */
const PROGRESS_MAX_COUNT: number = 200

/**
 * 返回阅读进度域的 Preferences 键（统一命名空间 `v2.reading_progress`，与账号无关）。
 *
 * @returns 键名；域未登记时为空串
 */
function progressDomainKey(): string {
  const spec: DomainSpec | null = PersistenceCatalog.byId(DomainIds.READING_PROGRESS)
  return spec === null ? '' : spec.fullKey()
}

/**
 * 帖子阅读进度管理（设备级数据，不再按账号物理隔离）。
 *
 * 记录每个帖子最近一次阅读到的楼层位置（页码 + 锚点楼层 pid），
 * 下次进入帖子时用于楼层级定位恢复。持久化到统一命名空间的 `v2.reading_progress`。
 *
 * public 方法上的 `uid` 参数仅为兼容既有调用点保留，函数体内不再使用。
 */
export class ReadingProgressStore extends BaseStore<Object> {
  override state: Object = new Object()
  private progressMap: Map<string, ReadingProgressEntry> = new Map()
  /** 是否已从持久化加载过（设备级数据只加载一次）。 */
  private loaded: boolean = false

  init(store: PreferencesStore, queue: SerialQueue): void {
    this.setDeps(store, queue)
  }

  /** 重置缓存（登出/切换账号时调用） */
  reset(): void {
    this.progressMap.clear()
    this.loaded = false
    super.reset()
  }

  /**
   * 懒加载进度缓存（设备级：只加载一次，不再因 uid 变化重载）。
   */
  private async ensureLoaded(): Promise<void> {
    if (this.loaded) return
    const gen: number = this.generationGuard.current()
    const key: string = progressDomainKey()
    const saved: ReadingProgressEntry[] | null =
      key.length === 0 ? null : await this.store.getJSON<ReadingProgressEntry[]>(key)
    // 加载期间已登出（reset 推进代际）：放弃本次，避免把过时数据写回内存
    if (!this.generationGuard.isCurrent(gen)) {
      return
    }
    this.progressMap.clear()
    if (saved) {
      for (let i = 0; i < saved.length; i++) {
        this.progressMap.set(saved[i].tid, saved[i])
      }
    }
    this.loaded = true
  }

  /**
   * 读取指定帖子的阅读进度。
   *
   * @param uid - **仅为兼容既有调用点保留**（设备级数据）
   * @param tid - 主题 tid
   * @returns 进度条目；无记录或参数无效时返回 null
   */
  async getProgress(uid: string, tid: string): Promise<ReadingProgressEntry | null> {
    if (tid.length === 0) return null
    await this.ensureLoaded()
    const entry = this.progressMap.get(tid)
    return entry !== undefined ? entry : null
  }

  /**
   * 写入（覆盖）指定帖子的阅读进度。
   *
   * 同帖只保留最新一条；条目数超过上限时按最近阅读时间淘汰最早记录。
   *
   * @param uid - **仅为兼容既有调用点保留**（设备级数据）
   * @param entry - 进度条目（tid 必须非空）
   */
  async setProgress(uid: string, entry: ReadingProgressEntry): Promise<void> {
    if (entry.tid.length === 0) return
    const gen: number = this.generationGuard.current()
    await this.ensureLoaded()
    // 加载期间已登出（reset 推进代际）：中止写入，避免旧会话数据写入新上下文
    if (!this.generationGuard.isCurrent(gen)) {
      return
    }
    entry.ts = Date.now()
    this.progressMap.set(entry.tid, entry)
    if (this.progressMap.size > PROGRESS_MAX_COUNT) {
      let oldestKey: string = ''
      let oldestTs: number = Number.MAX_SAFE_INTEGER
      this.progressMap.forEach((value: ReadingProgressEntry, key: string): void => {
        if (value.ts < oldestTs) {
          oldestTs = value.ts
          oldestKey = key
        }
      })
      if (oldestKey.length > 0) {
        this.progressMap.delete(oldestKey)
      }
    }
    this.persistProgress()
  }

  private persistProgress(): void {
    const key: string = progressDomainKey()
    if (key.length === 0) {
      return
    }
    this.writeQueue.enqueue(async (): Promise<void> => {
      const items: ReadingProgressEntry[] = []
      this.progressMap.forEach((value: ReadingProgressEntry): void => {
        items.push(value)
      })
      await this.store.putJSON(key, items, false)
      this.store.scheduleFlush()
    })
  }
}
