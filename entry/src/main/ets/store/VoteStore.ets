import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { BaseStore } from './BaseStore'

const TAG = 'VoteStore'

class VoteRecord {
  upPids: string[] = []
  downPids: string[] = []
  ts: number = 0
}

const VOTE_MAX_ENTRIES: number = 200

/**
 * 帖子投票记录持久化管理
 */
export class VoteStore extends BaseStore<Object> {
  override state: Object = new Object()
  private voteCache: Record<string, VoteRecord> = {}
  private voteLoadedUid: string = ''

  init(store: PreferencesStore, queue: SerialQueue): void {
    this.setDeps(store, queue)
  }

  /** 重置缓存（登出时调用） */
  reset(): void {
    this.voteCache = {}
    this.voteLoadedUid = ''
    super.reset()
  }

  private voteKey(uid: string): string {
    return `votes_${uid}`
  }

  async loadVoteRecord(uid: string, tid: string): Promise<Set<string>[]> {
    if (uid.length === 0) {
      return [new Set<string>(), new Set<string>()]
    }
    if (this.voteLoadedUid !== uid) {
      const gen: number = this.generationGuard.current()
      const saved = await this.store.getJSON<Record<string, VoteRecord>>(this.voteKey(uid))
      // 加载期间已登出（reset 推进代际）或已有其他账号的数据回写：放弃本次，避免跨账号污染
      if (!this.generationGuard.isCurrent(gen) ||
        (this.voteLoadedUid !== '' && this.voteLoadedUid !== uid)) {
        return [new Set<string>(), new Set<string>()]
      }
      this.voteCache = saved ?? {}
      this.voteLoadedUid = uid
    }
    const upSet = new Set<string>()
    const downSet = new Set<string>()
    const record = this.voteCache[tid]
    if (record) {
      for (let i = 0; i < record.upPids.length; i++) {
        upSet.add(record.upPids[i])
      }
      for (let i = 0; i < record.downPids.length; i++) {
        downSet.add(record.downPids[i])
      }
    }
    return [upSet, downSet]
  }

  async saveVoteRecord(uid: string, tid: string, upPids: Set<string>, downPids: Set<string>): Promise<void> {
    if (uid.length === 0 || tid.length === 0) return
    if (this.voteLoadedUid !== uid) {
      const gen: number = this.generationGuard.current()
      const saved = await this.store.getJSON<Record<string, VoteRecord>>(this.voteKey(uid))
      // 加载期间已登出（reset 推进代际）或已有其他账号的数据回写：放弃本次，避免跨账号污染
      if (!this.generationGuard.isCurrent(gen) ||
        (this.voteLoadedUid !== '' && this.voteLoadedUid !== uid)) {
        return
      }
      this.voteCache = saved ?? {}
      this.voteLoadedUid = uid
    }
    const record = new VoteRecord()
    const upArr: string[] = []
    upPids.forEach((pid: string) => { upArr.push(pid) })
    const downArr: string[] = []
    downPids.forEach((pid: string) => { downArr.push(pid) })
    record.upPids = upArr
    record.downPids = downArr
    record.ts = Date.now()
    this.voteCache[tid] = record
    this.evictVotesIfNeeded()
    this.writeQueue.enqueue(async (): Promise<void> => {
      if (!this.uidGuard()) return
      await this.store.putJSON(this.voteKey(uid), this.voteCache, false)
      this.store.scheduleFlush()
    })
  }

  async removeVoteRecord(uid: string, tid: string): Promise<void> {
    if (uid.length === 0) return
    if (this.voteLoadedUid !== uid) {
      const gen: number = this.generationGuard.current()
      const saved = await this.store.getJSON<Record<string, VoteRecord>>(this.voteKey(uid))
      // 加载期间已登出（reset 推进代际）或已有其他账号的数据回写：放弃本次，避免跨账号污染
      if (!this.generationGuard.isCurrent(gen) ||
        (this.voteLoadedUid !== '' && this.voteLoadedUid !== uid)) {
        return
      }
      this.voteCache = saved ?? {}
      this.voteLoadedUid = uid
    }
    const newCache: Record<string, VoteRecord> = {}
    const cacheKeys = Object.keys(this.voteCache)
    for (let i = 0; i < cacheKeys.length; i++) {
      if (cacheKeys[i] !== tid) {
        newCache[cacheKeys[i]] = this.voteCache[cacheKeys[i]]
      }
    }
    this.voteCache = newCache
    this.writeQueue.enqueue(async (): Promise<void> => {
      if (!this.uidGuard()) return
      await this.store.putJSON(this.voteKey(uid), this.voteCache, false)
      this.store.scheduleFlush()
    })
  }

  async clearVoteRecords(uid: string): Promise<void> {
    this.voteCache = {}
    this.voteLoadedUid = uid
    this.writeQueue.enqueue(async (): Promise<void> => {
      if (!this.uidGuard()) return
      await this.store.putJSON(this.voteKey(uid), this.voteCache, false)
      this.store.scheduleFlush()
    })
  }

  private evictVotesIfNeeded(): void {
    const keys = Object.keys(this.voteCache)
    if (keys.length <= VOTE_MAX_ENTRIES) return
    const entries: string[][] = []
    for (let i = 0; i < keys.length; i++) {
      const record = this.voteCache[keys[i]]
      if (record) {
        entries.push([keys[i], String(record.ts)])
      }
    }
    entries.sort((a: string[], b: string[]): number => {
      return Number(a[1]) - Number(b[1])
    })
    const removeCount = entries.length - VOTE_MAX_ENTRIES
    const evictSet = new Set<string>()
    for (let i = 0; i < removeCount; i++) {
      evictSet.add(entries[i][0])
    }
    const newCache: Record<string, VoteRecord> = {}
    for (let i = 0; i < keys.length; i++) {
      if (!evictSet.has(keys[i])) {
        newCache[keys[i]] = this.voteCache[keys[i]]
      }
    }
    this.voteCache = newCache
  }
}
