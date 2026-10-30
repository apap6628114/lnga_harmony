import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { BaseStore } from './BaseStore'
import { DomainIds, PersistenceCatalog } from '../common/persistence/PersistenceCatalog'
import { DomainSpec } from '../common/persistence/PersistenceTypes'

const TAG = 'VoteStore'

class VoteRecord {
  upPids: string[] = []
  downPids: string[] = []
  ts: number = 0
}

const VOTE_MAX_ENTRIES: number = 200

/**
 * 返回点赞/踩记录域的 Preferences 键（统一命名空间 `v2.votes`，与账号无关）。
 *
 * @returns 键名；域未登记时为空串
 */
function votesDomainKey(): string {
  const spec: DomainSpec | null = PersistenceCatalog.byId(DomainIds.VOTES)
  return spec === null ? '' : spec.fullKey()
}

/**
 * 返回投票已投记录域的 Preferences 键（统一命名空间 `v2.poll_voted`，与账号无关）。
 *
 * @returns 键名；域未登记时为空串
 */
function pollVotedDomainKey(): string {
  const spec: DomainSpec | null = PersistenceCatalog.byId(DomainIds.POLL_VOTED)
  return spec === null ? '' : spec.fullKey()
}

/**
 * 帖子投票记录持久化管理（设备级数据，不再按账号物理隔离）
 *
 * 两类记录：
 * - 点赞/踩：`v2.votes` → { tid: { upPids, downPids, ts } }
 * - 投票帖已投：`v2.poll_voted` → { tid: 时间戳 }（提交成功后标记，重进页面恢复"已投"状态）
 *
 * public 方法上的 `uid` 参数仅为兼容既有调用点保留，函数体内不再使用。
 */
export class VoteStore extends BaseStore<Object> {
  override state: Object = new Object()
  private voteCache: Record<string, VoteRecord> = {}
  /** 点赞记录是否已从持久化加载（设备级：只加载一次）。 */
  private voteLoaded: boolean = false
  private pollCache: Record<string, number> = {}
  /** 投票已投记录是否已从持久化加载（设备级：只加载一次）。 */
  private pollLoaded: boolean = false

  init(store: PreferencesStore, queue: SerialQueue): void {
    this.setDeps(store, queue)
  }

  /** 重置缓存（登出时调用） */
  reset(): void {
    this.voteCache = {}
    this.voteLoaded = false
    this.pollCache = {}
    this.pollLoaded = false
    super.reset()
  }

  /**
   * 懒加载点赞记录（设备级：只加载一次，不再因 uid 变化重载）。
   *
   * @returns 加载是否可用（代际已失效时返回 false）
   */
  private async ensureVoteLoaded(): Promise<boolean> {
    if (this.voteLoaded) {
      return true
    }
    const gen: number = this.generationGuard.current()
    const key: string = votesDomainKey()
    const saved: Record<string, VoteRecord> | null =
      key.length === 0 ? null : await this.store.getJSON<Record<string, VoteRecord>>(key)
    // 加载期间已登出（reset 推进代际）：放弃本次，避免把过时数据写回内存
    if (!this.generationGuard.isCurrent(gen)) {
      return false
    }
    this.voteCache = saved ?? {}
    this.voteLoaded = true
    return true
  }

  async loadVoteRecord(uid: string, tid: string): Promise<Set<string>[]> {
    if (!(await this.ensureVoteLoaded())) {
      return [new Set<string>(), new Set<string>()]
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
    if (tid.length === 0) return
    if (!(await this.ensureVoteLoaded())) {
      return
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
    this.persistVotes()
  }

  async removeVoteRecord(uid: string, tid: string): Promise<void> {
    if (!(await this.ensureVoteLoaded())) {
      return
    }
    const newCache: Record<string, VoteRecord> = {}
    const cacheKeys = Object.keys(this.voteCache)
    for (let i = 0; i < cacheKeys.length; i++) {
      if (cacheKeys[i] !== tid) {
        newCache[cacheKeys[i]] = this.voteCache[cacheKeys[i]]
      }
    }
    this.voteCache = newCache
    this.persistVotes()
  }

  async clearVoteRecords(uid: string): Promise<void> {
    this.voteCache = {}
    this.voteLoaded = true
    this.persistVotes()
  }

  /** 把点赞记录快照写入设备级域键。 */
  private persistVotes(): void {
    const key: string = votesDomainKey()
    if (key.length === 0) {
      return
    }
    const snapshot: Record<string, VoteRecord> = this.copyVoteCache()
    this.writeQueue.enqueue(async (): Promise<void> => {
      await this.store.putJSON(key, snapshot, false)
      this.store.scheduleFlush()
    })
  }

  /**
   * 复制点赞缓存的浅快照（入队前捕获，避免执行时读到"未来态"）。
   *
   * @returns 缓存副本
   */
  private copyVoteCache(): Record<string, VoteRecord> {
    const snapshot: Record<string, VoteRecord> = {}
    const keys: string[] = Object.keys(this.voteCache)
    for (let i: number = 0; i < keys.length; i++) {
      snapshot[keys[i]] = this.voteCache[keys[i]]
    }
    return snapshot
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

  /**
   * 懒加载投票已投记录（设备级：只加载一次）。
   *
   * @returns 加载是否可用（代际已失效时返回 false）
   */
  private async ensurePollLoaded(): Promise<boolean> {
    if (this.pollLoaded) {
      return true
    }
    const gen: number = this.generationGuard.current()
    const key: string = pollVotedDomainKey()
    const saved: Record<string, number> | null =
      key.length === 0 ? null : await this.store.getJSON<Record<string, number>>(key)
    // 加载期间已登出（reset 推进代际）：放弃本次，避免把过时数据写回内存
    if (!this.generationGuard.isCurrent(gen)) {
      return false
    }
    this.pollCache = saved ?? {}
    this.pollLoaded = true
    return true
  }

  /**
   * 读取已投过票的帖子 tid 列表。
   *
   * @param uid **仅为兼容既有调用点保留**（设备级数据）
   * @returns 已投帖子 tid 字符串列表
   */
  async loadPollVoted(uid: string): Promise<string[]> {
    if (!(await this.ensurePollLoaded())) {
      return []
    }
    return Object.keys(this.pollCache)
  }

  /**
   * 记录对某投票帖已投票（幂等）。
   *
   * @param uid **仅为兼容既有调用点保留**（设备级数据）
   * @param tid 帖子 ID
   */
  async markPollVoted(uid: string, tid: string): Promise<void> {
    if (tid.length === 0) {
      return
    }
    if (!(await this.ensurePollLoaded())) {
      return
    }
    if (this.pollCache[tid] !== undefined) {
      return
    }
    this.pollCache[tid] = Date.now()
    this.evictPollsIfNeeded()
    // 写闭包捕获当前缓存快照：执行时若 cache 已因登出被替换，仍写回发起时的数据，
    // 避免把空缓存写入域键
    const snapshot: Record<string, number> = {}
    const cacheKeys: string[] = Object.keys(this.pollCache)
    for (let i: number = 0; i < cacheKeys.length; i++) {
      snapshot[cacheKeys[i]] = this.pollCache[cacheKeys[i]]
    }
    const key: string = pollVotedDomainKey()
    if (key.length === 0) {
      return
    }
    this.writeQueue.enqueue(async (): Promise<void> => {
      await this.store.putJSON(key, snapshot, false)
      this.store.scheduleFlush()
    })
  }

  private evictPollsIfNeeded(): void {
    const keys = Object.keys(this.pollCache)
    if (keys.length <= VOTE_MAX_ENTRIES) {
      return
    }
    const entries: string[][] = []
    for (let i = 0; i < keys.length; i++) {
      entries.push([keys[i], String(this.pollCache[keys[i]])])
    }
    entries.sort((a: string[], b: string[]): number => {
      return Number(a[1]) - Number(b[1])
    })
    const removeCount: number = entries.length - VOTE_MAX_ENTRIES
    const newCache: Record<string, number> = {}
    for (let i = removeCount; i < entries.length; i++) {
      newCache[entries[i][0]] = this.pollCache[entries[i][0]]
    }
    this.pollCache = newCache
  }
}
