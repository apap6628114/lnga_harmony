import { describe, it, expect } from '@ohos/hypium'
import { HistoryStore, BrowseHistoryEntry } from '../main/ets/store/HistoryStore'
import { PreferencesStore } from '../main/ets/common/infra/PreferencesStore'
import { SerialQueue } from '../main/ets/common/infra/SerialQueue'
import { ThreadResult } from '../main/ets/model/ThreadResult'
import { ThreadInfo } from '../main/ets/model/Thread'
import { PostInfo } from '../main/ets/model/PostInfo'
import {
  READ_BASELINE_UNKNOWN,
  READ_BASELINE_UNREAD,
  topicUpdateDelta
} from '../main/ets/common/utils/TopicReadPolicy'

/** 浏览历史上限（与 HistoryStore 内部常量同值，用于 LRU 淘汰用例）。 */
const HISTORY_MAX_COUNT: number = 500

/** 测试账号 uid。 */
const TEST_UID: string = 'read-ledger-user'

/**
 * 内存版偏好存储 —— Local Test 专用的 `PreferencesStore` 测试替身。
 *
 * 真实 `PreferencesStore` 在未 `init(context, name)` 时 `getJSON` 恒返回 null、`putJSON`
 * 静默丢弃（`pref` 为 null），Local Test 又没有 Context；而本组用例要验证的恰恰是
 * **基线随条目落盘、跨实例重载后仍然成立**，所以必须有一个能真正存住 JSON 的替身。
 * 只覆盖 `HistoryStore` 用到的两个方法，其余（`init` / `getString` / `putString`）不参与。
 */
class MemoryPreferencesStore extends PreferencesStore {
  /** key → JSON 字符串，模拟落盘内容。 */
  private memory: Map<string, string> = new Map()

  override async getJSON<T>(key: string): Promise<T | null> {
    const raw: string | undefined = this.memory.get(key)
    if (raw === undefined || raw.length === 0) {
      return null
    }
    return JSON.parse(raw) as T
  }

  override async putJSON(key: string, value: Object, flush: boolean = true): Promise<void> {
    this.memory.set(key, JSON.stringify(value))
  }
}

/**
 * 构造帖子详情结果样本。
 *
 * @param replies - 服务端回复总数；传 null 表示响应未携带主题信息（HTML 兜底路径）
 * @returns 帖子详情结果
 */
function buildThreadResult(replies: number | null): ThreadResult {
  const result: ThreadResult = new ThreadResult()
  result.ok = true
  result.forumName = '测试版面'
  const firstPost: PostInfo = new PostInfo()
  firstPost.subject = '样本标题'
  firstPost.author = '样本作者'
  firstPost.authorid = 12345
  result.posts.push(firstPost)
  if (replies !== null) {
    const info: ThreadInfo = {
      tid: 0,
      fid: 7,
      subject: '样本标题',
      replies: replies,
      authorid: 12345,
      author: '样本作者',
      postdate: 0,
      lastpost: 0,
      lastposter: '',
      locked: false,
      recommend: 0,
      digest: 0,
      type: 0,
      topic_misc: '',
      authorKey: '12345'
    }
    result.threadInfo = info
  }
  return result
}

/**
 * 等待串行写队列排空，使历史真正落到偏好存储上。
 *
 * @param queue - Store 使用的写队列
 */
async function flushQueue(queue: SerialQueue): Promise<void> {
  await queue.enqueue(async (): Promise<void> => {})
}

/**
 * 注册「浏览历史即已读台账」的回归测试。
 *
 * 保护的不变量：基线索引在**写入推进**、**按条目重建**、**跨实例重载（冷启动）**、
 * **LRU 淘汰**、**删除 / 清空 / 重置**五条路径上的一致性与安全性。
 * 重点是"基线未知"必须经得起落盘往返——它只活在内存索引里就会被重建当成 0
 * （"读到时有 0 条回复"），从而误报 `+全部回复数`。
 */
export default function historyReadLedgerUnitTest(): void {
  describe('historyReadLedger', (): void => {
    it('keepsUnknownBaselineAcrossRebuildAndReload', 0, async (): Promise<void> => {
      const preferences: MemoryPreferencesStore = new MemoryPreferencesStore()
      const queue: SerialQueue = new SerialQueue()
      const store: HistoryStore = new HistoryStore()
      store.init(preferences, queue)

      /* 响应未带主题信息 → 基线未知：降权、不判定更新 */
      await store.addFromThreadResult(TEST_UID, buildThreadResult(null), '1001')
      expect(store.getReadReplies('1001')).assertEqual(READ_BASELINE_UNKNOWN)

      /* 再写一条别的帖子会触发索引按条目重建——未知基线不得退化成 0 */
      await store.addFromThreadResult(TEST_UID, buildThreadResult(12), '1002')
      expect(store.getReadReplies('1001')).assertEqual(READ_BASELINE_UNKNOWN)
      expect(store.getReadReplies('1002')).assertEqual(12)
      expect(topicUpdateDelta(store.getReadReplies('1001'), 5000)).assertEqual(0)

      /* 冷启动：新实例从同一份存储重新载入，结论必须一致 */
      await flushQueue(queue)
      const reloaded: HistoryStore = new HistoryStore()
      reloaded.init(preferences, queue)
      await reloaded.preload(TEST_UID)
      expect(reloaded.getReadReplies('1001')).assertEqual(READ_BASELINE_UNKNOWN)
      expect(reloaded.getReadReplies('1002')).assertEqual(12)
      expect(topicUpdateDelta(reloaded.getReadReplies('1001'), 5000)).assertEqual(0)
      expect(topicUpdateDelta(reloaded.getReadReplies('1002'), 15)).assertEqual(3)
    })

    it('advancesBaselineOnEveryOpen', 0, async (): Promise<void> => {
      const preferences: MemoryPreferencesStore = new MemoryPreferencesStore()
      const queue: SerialQueue = new SerialQueue()
      const store: HistoryStore = new HistoryStore()
      store.init(preferences, queue)

      await store.addFromThreadResult(TEST_UID, buildThreadResult(12), '2001')
      expect(topicUpdateDelta(store.getReadReplies('2001'), 15)).assertEqual(3)

      /* 再次打开该帖：基线推进到 15，增量归零；删楼回退同样不报更新 */
      await store.addFromThreadResult(TEST_UID, buildThreadResult(15), '2001')
      expect(store.getReadReplies('2001')).assertEqual(15)
      expect(topicUpdateDelta(store.getReadReplies('2001'), 15)).assertEqual(0)
      expect(topicUpdateDelta(store.getReadReplies('2001'), 9)).assertEqual(0)
    })

    it('dropsBaselineOfEvictedEntryWhenOverLimit', 0, async (): Promise<void> => {
      const preferences: MemoryPreferencesStore = new MemoryPreferencesStore()
      const queue: SerialQueue = new SerialQueue()
      const store: HistoryStore = new HistoryStore()
      store.init(preferences, queue)

      const total: number = HISTORY_MAX_COUNT + 1
      for (let index: number = 0; index < total; index++) {
        await store.addFromThreadResult(TEST_UID, buildThreadResult(index), String(3000 + index))
      }

      /* 最早写入的一条被 LRU 淘汰：回到"没看过"；最新一条仍在，基线为写入时的回复数 */
      expect(store.getReadReplies('3000')).assertEqual(READ_BASELINE_UNREAD)
      expect(store.getReadReplies(String(3000 + total - 1))).assertEqual(total - 1)
    })

    it('clearsIndexOnRemoveClearAndReset', 0, async (): Promise<void> => {
      const preferences: MemoryPreferencesStore = new MemoryPreferencesStore()
      const queue: SerialQueue = new SerialQueue()
      const store: HistoryStore = new HistoryStore()
      store.init(preferences, queue)

      await store.addFromThreadResult(TEST_UID, buildThreadResult(7), '4001')
      await store.addFromThreadResult(TEST_UID, buildThreadResult(8), '4002')

      /* 删除单条 */
      await store.removeBrowseHistory(TEST_UID, '4001')
      expect(store.getReadReplies('4001')).assertEqual(READ_BASELINE_UNREAD)
      expect(store.getReadReplies('4002')).assertEqual(8)

      /* 清空全部 */
      await store.clearBrowseHistory(TEST_UID)
      expect(store.getReadReplies('4002')).assertEqual(READ_BASELINE_UNREAD)

      /* 登出重置 */
      await store.addFromThreadResult(TEST_UID, buildThreadResult(9), '4003')
      expect(store.getReadReplies('4003')).assertEqual(9)
      store.reset()
      expect(store.getReadReplies('4003')).assertEqual(READ_BASELINE_UNREAD)
    })

    it('ignoresCorruptedLedgerEntries', 0, async (): Promise<void> => {
      const preferences: MemoryPreferencesStore = new MemoryPreferencesStore()
      const queue: SerialQueue = new SerialQueue()
      /* 外部写坏的条目（缺 tid / 回复数非法）不得让索引重建抛异常 */
      const corrupted: BrowseHistoryEntry[] = []
      const noTid: BrowseHistoryEntry = new BrowseHistoryEntry()
      noTid.subject = '缺 tid'
      corrupted.push(noTid)
      const badReplies: BrowseHistoryEntry = new BrowseHistoryEntry()
      badReplies.tid = '5001'
      badReplies.subject = '回复数非法'
      badReplies.replies = Number.NaN
      corrupted.push(badReplies)
      await preferences.putJSON(`history_${TEST_UID}`, corrupted, false)

      const store: HistoryStore = new HistoryStore()
      store.init(preferences, queue)
      await store.preload(TEST_UID)

      expect(store.getReadReplies('5001')).assertEqual(READ_BASELINE_UNKNOWN)
      expect(store.getReadReplies('')).assertEqual(READ_BASELINE_UNREAD)
    })
  })
}
