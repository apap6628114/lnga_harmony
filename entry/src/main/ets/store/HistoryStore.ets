import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { BaseStore } from './BaseStore'
import type { ThreadResult } from '../model/ThreadResult'
import type { ThreadInfo } from '../model/Thread'
import { PostInfo } from '../model/PostInfo'
import { KEY_BROWSE_HISTORY_VERSION } from '../common/constants/AppStorageKeys'
import { bumpAppStorageVersion } from '../common/utils/AppStorageVersion'

/** 浏览历史条目 */
export class BrowseHistoryEntry {
  tid: string = ''
  subject: string = ''
  author: string = ''
  authorid: string = ''
  replies: number = 0
  postDate: number = 0
  board: string = ''
  ts: number = 0
}

const HISTORY_MAX_COUNT: number = 500

/**
 * 帖子浏览历史管理
 */
export class HistoryStore extends BaseStore<Object> {
  override state: Object = new Object()
  private historyItems: BrowseHistoryEntry[] = []
  private historyLoadedUid: string = ''

  init(store: PreferencesStore, queue: SerialQueue): void {
    this.setDeps(store, queue)
  }

  /** 重置缓存（登出时调用） */
  reset(): void {
    this.historyItems = []
    this.historyLoadedUid = ''
    super.reset()
  }

  private historyKey(uid: string): string {
    return `history_${uid}`
  }

  async getBrowseHistory(uid: string): Promise<BrowseHistoryEntry[]> {
    if (this.historyLoadedUid !== uid) {
      const gen: number = this.generationGuard.current()
      const saved = await this.store.getJSON<BrowseHistoryEntry[]>(this.historyKey(uid))
      // 加载期间已登出（reset 推进代际）或已有其他账号的数据回写：放弃本次，避免跨账号污染
      if (!this.generationGuard.isCurrent(gen) ||
        (this.historyLoadedUid !== '' && this.historyLoadedUid !== uid)) {
        return []
      }
      this.historyItems = saved ?? []
      this.historyLoadedUid = uid
    }
    const result: BrowseHistoryEntry[] = []
    for (let i = 0; i < this.historyItems.length; i++) {
      result.push(this.historyItems[i])
    }
    return result
  }

  async addBrowseHistory(uid: string, entry: BrowseHistoryEntry): Promise<void> {
    if (uid.length === 0) return
    const gen: number = this.generationGuard.current()
    if (this.historyLoadedUid !== uid) {
      await this.getBrowseHistory(uid)
    }
    // 加载期间已登出（reset 推进代际）：中止写入，避免旧会话数据写入新账号
    if (!this.generationGuard.isCurrent(gen)) {
      return
    }
    const filtered: BrowseHistoryEntry[] = []
    for (let i = 0; i < this.historyItems.length; i++) {
      if (this.historyItems[i].tid !== entry.tid) {
        filtered.push(this.historyItems[i])
      }
    }
    entry.ts = Date.now()
    const newList: BrowseHistoryEntry[] = [entry, ...filtered]
    if (newList.length > HISTORY_MAX_COUNT) {
      this.historyItems = newList.slice(0, HISTORY_MAX_COUNT)
    } else {
      this.historyItems = newList
    }
    this.persistBrowseHistory(uid)
  }

  /**
   * 从帖子详情结果构造浏览历史并写入。
   * 转换逻辑（threadInfo 优先、posts[0] 兜底、subject 空则不记录）逐字外迁自
   * ThreadPanel.recordBrowseHistory，行为保持等价。
   *
   * @param uid - 当前用户 uid
   * @param result - getThread 返回的帖子详情结果
   * @param tid - 主题 tid
   */
  async addFromThreadResult(uid: string, result: ThreadResult, tid: string): Promise<void> {
    const entry: BrowseHistoryEntry = new BrowseHistoryEntry()
    entry.tid = tid
    entry.board = result.forumName
    if (result.threadInfo) {
      const info: ThreadInfo = result.threadInfo
      entry.subject = info.subject
      entry.author = info.author
      entry.authorid = String(info.authorid)
      entry.replies = info.replies
    } else if (result.posts.length > 0) {
      const firstPost: PostInfo = result.posts[0]
      entry.subject = firstPost.subject
      entry.author = firstPost.author
      entry.authorid = String(firstPost.authorid)
    }
    if (entry.subject.length === 0) {
      return
    }
    await this.addBrowseHistory(uid, entry)
  }

  async removeBrowseHistory(uid: string, tid: string): Promise<void> {
    const gen: number = this.generationGuard.current()
    if (this.historyLoadedUid !== uid) {
      await this.getBrowseHistory(uid)
    }
    // 加载期间已登出（reset 推进代际）：中止删除，避免误清新账号数据
    if (!this.generationGuard.isCurrent(gen)) {
      return
    }
    const filtered: BrowseHistoryEntry[] = []
    for (let i = 0; i < this.historyItems.length; i++) {
      if (this.historyItems[i].tid !== tid) {
        filtered.push(this.historyItems[i])
      }
    }
    this.historyItems = filtered
    this.persistBrowseHistory(uid)
  }

  async clearBrowseHistory(uid: string): Promise<void> {
    this.historyItems = []
    this.persistBrowseHistory(uid)
  }

  private persistBrowseHistory(uid: string): void {
    this.writeQueue.enqueue(async (): Promise<void> => {
      if (!this.uidGuard()) return
      await this.store.putJSON(this.historyKey(uid), this.historyItems, false)
      bumpAppStorageVersion(KEY_BROWSE_HISTORY_VERSION)
      this.store.scheduleFlush()
    })
  }
}
