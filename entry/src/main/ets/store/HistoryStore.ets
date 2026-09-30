import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { BaseStore } from './BaseStore'
import type { ThreadResult } from '../model/ThreadResult'
import type { ThreadInfo } from '../model/Thread'
import { PostInfo } from '../model/PostInfo'
import { KEY_BROWSE_HISTORY_VERSION } from '../common/constants/AppStorageKeys'
import { bumpAppStorageVersion } from '../common/utils/AppStorageVersion'
import { READ_BASELINE_UNKNOWN, READ_BASELINE_UNREAD } from '../common/utils/TopicReadPolicy'

/** 浏览历史条目 */
export class BrowseHistoryEntry {
  tid: string = ''
  subject: string = ''
  author: string = ''
  authorid: string = ''
  /**
   * 读到该帖时服务端的回复数。
   *
   * 两个用途同源，因此只存一份：① 「浏览历史」页展示当时的回复数；
   * ② 主题列表「已读 / 有新回复」判定的**基线**（列表当前回复数大于本值即视为有更新，
   * 见 `TopicReadPolicy`）。该值在读帖子时被覆盖为最新值，基线随之推进。
   *
   * **基线未知时存哨兵 {@link READ_BASELINE_UNKNOWN}（−2）**：它是基线的持久化载体，
   * 必须与"读到时有 0 条回复"（合法值 0）区分开——哨兵只活在内存索引里的话，
   * 条目落盘后重建就会退化成 0，该帖会被误报"+全部回复数"。展示层（浏览历史页）
   * 对负值按 0 呈现，不把内部哨兵泄漏到界面。
   */
  replies: number = 0
  postDate: number = 0
  board: string = ''
  ts: number = 0
}

const HISTORY_MAX_COUNT: number = 500

/**
 * 帖子浏览历史管理。
 *
 * 除「浏览历史」列表外，本 Store 还是主题列表**已读台账**的来源：浏览历史天然等价于
 * 「用户打开过的帖子」，主题列表据此对看过的帖子做降权、对看过后又有新回复的帖子打标记
 * （见 `docs/TOPIC_READ_STATE_DESIGN.md`）。为此这里额外维护一份**同步可查**的内存索引
 * `readBaselines`——列表行是在 `build()` 里逐行渲染的，不能对每一行发起异步查询。
 */
export class HistoryStore extends BaseStore<Object> {
  override state: Object = new Object()
  private historyItems: BrowseHistoryEntry[] = []
  private historyLoadedUid: string = ''
  /**
   * tid → 读到该帖时的服务端回复数（已读台账基线）。
   *
   * 与 `historyItems` 同源同步维护：**存在性**表达「看过」（不存在 = 没看过），
   * 值表达基线（`READ_BASELINE_UNKNOWN` = 看过但无法判定更新）。查询 O(1)，
   * 供主题列表行在构建期直接调用（`getReadReplies`）。
   */
  private readBaselines: Map<string, number> = new Map()

  init(store: PreferencesStore, queue: SerialQueue): void {
    this.setDeps(store, queue)
  }

  /** 重置缓存（登出时调用） */
  reset(): void {
    this.historyItems = []
    this.historyLoadedUid = ''
    this.readBaselines.clear()
    // 台账被清空同样是"台账变化"：发布版本号，使仍在屏的主题列表行回到"没看过"的外观
    // （正常路径下登出会销毁面板、下次登录重新载入并 bump，这里只是不让外观依赖销毁时序）
    bumpAppStorageVersion(KEY_BROWSE_HISTORY_VERSION)
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
      this.rebuildReadBaselines()
      /* 载入即「已读台账可用」：必须在**首次载入完成**时发布版本，否则在台账落地前已渲染的
         主题列表行会一直停在「没看过」的外观（列表先于本 Store 载入完成时必然发生）。
         与写入路径共用同一个版本号：消费方（列表行）只关心"台账是否变化"。 */
      bumpAppStorageVersion(KEY_BROWSE_HISTORY_VERSION)
    }
    const result: BrowseHistoryEntry[] = []
    for (let i = 0; i < this.historyItems.length; i++) {
      result.push(this.historyItems[i])
    }
    return result
  }

  /**
   * 预载指定账号的浏览历史（即已读台账）。
   *
   * **不改动任何数据**：已载入时 `getBrowseHistory` 直接返回内存快照；仅在**首次载入**完成时
   * 发布一次 `browseHistoryVersion`（这是 UI 刷新信号，不是数据写入，见 `getBrowseHistory`）。
   * 由 `AppStore.loadUserData` 在冷启动 / 登录后调用，使主题列表的「已读 / 有新回复」标记在
   * **首帧**就正确，而不是等列表渲染完再逐个刷新（那会表现为整屏标记闪一下）。
   *
   * @param uid - 用户 uid
   */
  async preload(uid: string): Promise<void> {
    if (uid.length === 0) {
      return
    }
    await this.getBrowseHistory(uid)
  }

  /**
   * 读该帖时的回复数基线（同步、O(1)，供列表行在构建期直接调用）。
   *
   * @param tid - 主题 tid
   * @returns 基线值；从未读过返回 {@link READ_BASELINE_UNREAD}，
   *   读过但基线未知返回 {@link READ_BASELINE_UNKNOWN}
   */
  getReadReplies(tid: string): number {
    if (tid.length === 0) {
      return READ_BASELINE_UNREAD
    }
    const baseline: number | undefined = this.readBaselines.get(tid)
    return baseline === undefined ? READ_BASELINE_UNREAD : baseline
  }

  /**
   * 由内存中的浏览历史重建已读基线索引。
   *
   * 条目的 `replies` 就是**基线的持久化载体**（读到该帖时的服务端回复数），两条规则：
   *  - 合法非负值（含 0）→ 直接作基线。"读到时有 0 条回复"是真值：此后第一条回复即 +1；
   *  - 缺失 / 非数值 / 负数（含 {@link READ_BASELINE_UNKNOWN} 哨兵）→ 记为"未知"，不判定更新。
   *
   * 一律经 `String()` / `normalizeBaseline` 取值而不是直接访问字段：本方法跑在
   * `AppStore.init → loadUserData → preload` 这条**启动关键路径**上，而该路径的异常会让
   * `AppStore.init` 抛出、`Index` 页停在"应用初始化失败"——历史 JSON 一旦被外部写坏
   * （旧版本格式、半截写入、手工改包），不能让整个应用起不来。
   */
  private rebuildReadBaselines(): void {
    this.readBaselines.clear()
    for (let i = 0; i < this.historyItems.length; i++) {
      const item: BrowseHistoryEntry | null = this.historyItems[i]
      if (item === null || item === undefined) {
        continue
      }
      const tid: string = String(item.tid ?? '')
      if (tid.length > 0) {
        this.readBaselines.set(tid, this.normalizeBaseline(item.replies))
      }
    }
  }

  /**
   * 归一化基线值：非法值（缺失 / NaN / 负数）按「未知」处理，避免把 `undefined` 当成 0
   * 而在首次回复到来时误报更新。`0` 是**合法基线**（读到该帖时确实没有回复）。
   *
   * @param replies - 历史条目中的回复数（或基线哨兵）
   * @returns 合法基线或 {@link READ_BASELINE_UNKNOWN}
   */
  private normalizeBaseline(replies: number): number {
    if (typeof replies !== 'number' || !Number.isFinite(replies) || replies < 0) {
      return READ_BASELINE_UNKNOWN
    }
    return replies
  }

  async addBrowseHistory(uid: string, entry: BrowseHistoryEntry): Promise<void> {
    await this.insertHistory(uid, entry, this.normalizeBaseline(entry.replies))
  }

  /**
   * 写入一条浏览历史并把已读基线推进到 `baseline`。
   *
   * 基线由调用方给出而不是一律取 `entry.replies`：帖子详情未返回主题信息时条目里的回复数
   * 是"未知"（0），却**不能**当成基线 0——那会把每个刚看过的帖子都标成"有新回复"
   * （见 `READ_BASELINE_UNKNOWN`）。
   *
   * @param uid - 当前用户 uid
   * @param entry - 待写入条目
   * @param baseline - 已读基线（读到该帖时的回复数，或 READ_BASELINE_UNKNOWN）
   */
  private async insertHistory(uid: string, entry: BrowseHistoryEntry, baseline: number): Promise<void> {
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
    /* 基线由**条目自身**承载（`entry.replies`）：它是索引重建的唯一数据源，写入时必须一起落盘，
       否则"未知"这个信息只活在内存索引里——下一次写入或下一次冷启动按条目重建时会被当成 0
       （"读到时有 0 条回复"），该帖就会显示"+全部回复数"（见 READ_BASELINE_UNKNOWN 的约定）。
       回归：test/HistoryReadLedgerUnit.test.ets 的 keepsUnknownBaselineAcrossRebuildAndReload
       （去掉本行即失败：expect 0 equals -2）。 */
    entry.replies = baseline
    const newList: BrowseHistoryEntry[] = [entry, ...filtered]
    if (newList.length > HISTORY_MAX_COUNT) {
      this.historyItems = newList.slice(0, HISTORY_MAX_COUNT)
    } else {
      this.historyItems = newList
    }
    /* 索引与列表同源重建：被 LRU 淘汰的条目基线一并消失（淘汰即回到"没看过"），
       本次条目的基线则从刚落盘的 `entry.replies` 读出，无需另行覆盖 */
    this.rebuildReadBaselines()
    this.persistBrowseHistory(uid)
  }

  /**
   * 从帖子详情结果构造浏览历史并写入。
   * 转换逻辑（threadInfo 优先、posts[0] 兜底、subject 空则不记录）逐字外迁自
   * ThreadPanel.recordBrowseHistory，行为保持等价。
   *
   * 同时登记**已读基线**：`threadInfo.replies` 即用户读到该帖时的服务端回复数，
   * 主题列表据此判定"看过后又有新回复"（见 `TopicReadPolicy`）。走 `posts[0]` 兜底路径时
   * 拿不到总数，基线记为**未知哨兵**（随条目一起落盘，见 `insertHistory`）——不判定更新，避免误报。
   *
   * @param uid - 当前用户 uid
   * @param result - getThread 返回的帖子详情结果
   * @param tid - 主题 tid
   */
  async addFromThreadResult(uid: string, result: ThreadResult, tid: string): Promise<void> {
    const entry: BrowseHistoryEntry = new BrowseHistoryEntry()
    entry.tid = tid
    entry.board = result.forumName
    let baseline: number = READ_BASELINE_UNKNOWN
    if (result.threadInfo) {
      const info: ThreadInfo = result.threadInfo
      entry.subject = info.subject
      entry.author = info.author
      entry.authorid = String(info.authorid)
      entry.replies = info.replies
      baseline = this.normalizeBaseline(info.replies)
    } else if (result.posts.length > 0) {
      const firstPost: PostInfo = result.posts[0]
      entry.subject = firstPost.subject
      entry.author = firstPost.author
      entry.authorid = String(firstPost.authorid)
    }
    if (entry.subject.length === 0) {
      return
    }
    await this.insertHistory(uid, entry, baseline)
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
    /* 同步已读台账：删掉历史即回到"没看过"（含更新标记一并消失） */
    this.readBaselines.delete(tid)
    this.persistBrowseHistory(uid)
  }

  async clearBrowseHistory(uid: string): Promise<void> {
    this.historyItems = []
    this.readBaselines.clear()
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
