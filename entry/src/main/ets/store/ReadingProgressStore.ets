import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { BaseStore } from './BaseStore'

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
 * 帖子阅读进度管理。
 *
 * 记录每个帖子最近一次阅读到的楼层位置（页码 + 锚点楼层 pid），
 * 下次进入帖子时用于楼层级定位恢复。按账号（uid）隔离存储，持久化到 Preferences。
 */
export class ReadingProgressStore extends BaseStore<Object> {
  override state: Object = new Object()
  private progressMap: Map<string, ReadingProgressEntry> = new Map()
  private progressLoadedUid: string = ''

  init(store: PreferencesStore, queue: SerialQueue): void {
    this.setDeps(store, queue)
  }

  /** 重置缓存（登出/切换账号时调用） */
  reset(): void {
    this.progressMap.clear()
    this.progressLoadedUid = ''
    super.reset()
  }

  private progressKey(uid: string): string {
    return `reading_progress_${uid}`
  }

  /**
   * 懒加载指定账号的进度缓存；账号切换时重新加载。
   *
   * @param uid - 用户 uid
   */
  private async ensureLoaded(uid: string): Promise<void> {
    if (this.progressLoadedUid === uid) return
    const gen: number = this.generationGuard.current()
    const saved = await this.store.getJSON<ReadingProgressEntry[]>(this.progressKey(uid))
    // 加载期间已登出（reset 推进代际）或已有其他账号的数据回写：放弃本次，避免跨账号污染
    if (!this.generationGuard.isCurrent(gen) ||
      (this.progressLoadedUid !== '' && this.progressLoadedUid !== uid)) {
      return
    }
    this.progressMap.clear()
    if (saved) {
      for (let i = 0; i < saved.length; i++) {
        this.progressMap.set(saved[i].tid, saved[i])
      }
    }
    this.progressLoadedUid = uid
  }

  /**
   * 读取指定帖子的阅读进度。
   *
   * @param uid - 用户 uid
   * @param tid - 主题 tid
   * @returns 进度条目；无记录或参数无效时返回 null
   */
  async getProgress(uid: string, tid: string): Promise<ReadingProgressEntry | null> {
    if (uid.length === 0 || tid.length === 0) return null
    await this.ensureLoaded(uid)
    const entry = this.progressMap.get(tid)
    return entry !== undefined ? entry : null
  }

  /**
   * 写入（覆盖）指定帖子的阅读进度。
   *
   * 同帖只保留最新一条；条目数超过上限时按最近阅读时间淘汰最早记录。
   *
   * @param uid - 用户 uid
   * @param entry - 进度条目（tid 必须非空）
   */
  async setProgress(uid: string, entry: ReadingProgressEntry): Promise<void> {
    if (uid.length === 0 || entry.tid.length === 0) return
    const gen: number = this.generationGuard.current()
    await this.ensureLoaded(uid)
    // 加载期间已登出（reset 推进代际）：中止写入，避免旧会话数据写入新账号
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
    this.persistProgress(uid)
  }

  private persistProgress(uid: string): void {
    this.writeQueue.enqueue(async (): Promise<void> => {
      if (!this.uidGuard()) return
      const items: ReadingProgressEntry[] = []
      this.progressMap.forEach((value: ReadingProgressEntry): void => {
        items.push(value)
      })
      await this.store.putJSON(this.progressKey(uid), items, false)
      this.store.scheduleFlush()
    })
  }
}
