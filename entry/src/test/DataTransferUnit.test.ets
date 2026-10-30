import { describe, expect, it } from '@ohos/hypium'
import { DomainIds } from '../main/ets/common/persistence/PersistenceCatalog'
import { mergePayload } from '../main/ets/common/transfer/DomainMergers'

/**
 * 数据导入导出工具层单元测试。
 *
 * 覆盖 `DomainMergers.mergePayload` 的纯逻辑：各域合并语义、幂等、坏条目跳过、上限截断。
 *
 * 注意：**加密链路（`TransferCrypto`）不在本 suite 覆盖范围**——它依赖系统
 * `cryptoFramework` 的 native 模块，Hypium Local Test（Previewer 环境）无法加载
 * `libcryptoframework_napi.dll`，一加载即导致测试页崩溃。加密往返的正确性需在真机/模拟器
 * 手动验证（导出→导入同一文件），或后续用 ohosTest 设备侧测试覆盖。
 */

/** 时间型条目样本（history / reading_progress / tracked_threads / ai_sessions 通用）。 */
class TimedEntry {
  /** 业务键（tid）。 */
  tid: string = ''
  /** 会话 ID（ai_sessions 用）。 */
  id: string = ''
  /** 历史/进度时间戳。 */
  ts: number = 0
  /** 跟踪最后检查时间。 */
  lastCheckAt: number = 0
  /** 创建时间（跟踪/AI 会话回退时间）。 */
  createdAt: number = 0
  /** AI 会话更新时间。 */
  updatedAt: number = 0
  /** 标题（内容无关，仅保证非空）。 */
  subject: string = ''
}

/** 黑名单样本。 */
class BlacklistEntrySample {
  /** 用户 UID。 */
  userId: string = ''
  /** 昵称。 */
  nickName: string = ''
}

/** AI 配置样本。 */
class AiProfileSample {
  /** 配置 ID。 */
  id: string = ''
  /** 配置名。 */
  name: string = ''
  /** API Key（用于验证合并器不做字段级脱敏，脱敏在导出侧）。 */
  apiKey: string = ''
}

/** 投票记录样本。 */
class VoteEntrySample {
  /** 点赞 pid。 */
  upPids: string[] = []
  /** 点踩 pid。 */
  downPids: string[] = []
  /** 更新时间戳。 */
  ts: number = 0
}

/** 设置样本（只放参与合并语义的字段）。 */
class SettingsSample {
  /** 正文字号（标量覆盖）。 */
  fontSize: number = 15
  /** 黑名单（按 userId 并集）。 */
  blacklist: BlacklistEntrySample[] = []
  /** AI 配置（按 id 并集）。 */
  aiProfiles: AiProfileSample[] = []
  /** 场景自定义提示词（按 key 合并）。 */
  scenarioSystemPrompts: Record<string, string> = {}
  /** 是否显示签名（标量覆盖）。 */
  showSignature: boolean = true
}

/** 主题样本。 */
class ThemeSample {
  /** 主题名。 */
  theme: string = 'light'
}

/** 草稿样本。 */
class DraftSample {
  /** 草稿键。 */
  key: string = ''
  /** 正文。 */
  content: string = ''
}

/** 保存的帖子样本。 */
class SavedThreadSample {
  /** 主题 ID。 */
  tid: string = ''
  /** 标题。 */
  subject: string = ''
}

/**
 * 构造时间型条目。
 *
 * @param tid - 主题 ID
 * @param ts - 时间戳
 * @returns 条目
 */
function timedEntry(tid: string, ts: number): TimedEntry {
  const entry: TimedEntry = new TimedEntry()
  entry.tid = tid
  entry.ts = ts
  entry.subject = 'subject-' + tid
  return entry
}

/**
 * 构造跟踪条目。
 *
 * @param tid - 主题 ID
 * @param lastCheckAt - 最后检查时间
 * @param createdAt - 创建时间
 * @returns 条目
 */
function trackedEntry(tid: string, lastCheckAt: number, createdAt: number): TimedEntry {
  const entry: TimedEntry = new TimedEntry()
  entry.tid = tid
  entry.lastCheckAt = lastCheckAt
  entry.createdAt = createdAt
  return entry
}

/**
 * 构造 AI 会话条目。
 *
 * @param id - 会话 ID
 * @param updatedAt - 更新时间
 * @returns 条目
 */
function aiSessionEntry(id: string, updatedAt: number): TimedEntry {
  const entry: TimedEntry = new TimedEntry()
  entry.id = id
  entry.updatedAt = updatedAt
  entry.createdAt = updatedAt - 1000
  return entry
}

/**
 * 构造黑名单条目。
 *
 * @param userId - 用户 UID
 * @param nickName - 昵称
 * @returns 条目
 */
function blacklistEntry(userId: string, nickName: string): BlacklistEntrySample {
  const entry: BlacklistEntrySample = new BlacklistEntrySample()
  entry.userId = userId
  entry.nickName = nickName
  return entry
}

/**
 * 构造 AI 配置条目。
 *
 * @param id - 配置 ID
 * @param name - 配置名
 * @returns 条目
 */
function aiProfile(id: string, name: string): AiProfileSample {
  const entry: AiProfileSample = new AiProfileSample()
  entry.id = id
  entry.name = name
  return entry
}

/**
 * 构造投票记录条目。
 *
 * @param ts - 时间戳
 * @returns 条目
 */
function voteEntry(ts: number): VoteEntrySample {
  const entry: VoteEntrySample = new VoteEntrySample()
  entry.ts = ts
  return entry
}

/**
 * 构造设置样本。
 *
 * @param fontSize - 字号
 * @returns 设置
 */
function settingsSample(fontSize: number): SettingsSample {
  const settings: SettingsSample = new SettingsSample()
  settings.fontSize = fontSize
  return settings
}

/**
 * 从合并结果的裸数组形态中取出条目。
 *
 * @param merged - 合并结果 payload
 * @returns 条目数组
 */
function asItemList(merged: Object): Object[] {
  return merged as Object[]
}

/**
 * 从合并结果的 `{items}` 形态中取出条目。
 *
 * @param merged - 合并结果 payload
 * @returns 条目数组
 */
function asWrappedItems(merged: Object): Object[] {
  const record: Record<string, Object> = merged as Record<string, Object>
  const items: Object | undefined = record['items']
  return items !== undefined && items !== null && Array.isArray(items) ? items as Object[] : []
}

/**
 * 读取条目字符串字段。
 *
 * @param item - 条目
 * @param field - 字段名
 * @returns 字符串（缺失时为空串）
 */
function itemString(item: Object, field: string): string {
  const record: Record<string, Object> = item as Record<string, Object>
  const value: Object | undefined = record[field]
  return typeof value === 'string' ? value as string : ''
}

/**
 * 读取条目数值字段。
 *
 * @param item - 条目
 * @param field - 字段名
 * @returns 数值（缺失/非法时 0）
 */
function itemNumber(item: Object, field: string): number {
  const record: Record<string, Object> = item as Record<string, Object>
  const value: Object | undefined = record[field]
  return typeof value === 'number' && isFinite(value as number) ? value as number : 0
}

/**
 * 从记录中取一个对象值（缺失时返回空对象，避免断言处处理 undefined）。
 *
 * @param record - 记录
 * @param key - 键
 * @returns 对象值
 */
function recordObject(record: Record<string, Object>, key: string): Object {
  const value: Object | undefined = record[key]
  return value !== undefined ? value : new Object()
}

/**
 * 注册数据导入导出工具层单元测试。
 */
export default function dataTransferUnitTest(): void {
  describe('dataTransferMergers', (): void => {
    it('mergeHistoryKeepsNewerEntryAndAppendsNew', 0, (): void => {
      const local: Object[] = [timedEntry('1', 100), timedEntry('2', 200)]
      const incoming: Object[] = [timedEntry('2', 50), timedEntry('3', 300)]

      const result = mergePayload(DomainIds.HISTORY, local, incoming)
      const list: Object[] = asItemList(result.merged)

      expect(list.length).assertEqual(3)
      expect(result.added).assertEqual(1)
      expect(result.updated).assertEqual(0)
      expect(result.skipped).assertEqual(1)
      // 按 ts 降序
      expect(itemString(list[0], 'tid')).assertEqual('3')
      expect(itemString(list[1], 'tid')).assertEqual('2')
      expect(itemNumber(list[1], 'ts')).assertEqual(200)
      expect(itemString(list[2], 'tid')).assertEqual('1')
    })

    it('mergeHistoryIsIdempotent', 0, (): void => {
      const local: Object[] = [timedEntry('1', 100), timedEntry('2', 200)]
      const incoming: Object[] = [timedEntry('1', 100), timedEntry('2', 200)]

      const result = mergePayload(DomainIds.HISTORY, local, incoming)
      const list: Object[] = asItemList(result.merged)

      expect(list.length).assertEqual(2)
      expect(result.added).assertEqual(0)
      expect(result.updated).assertEqual(0)
    })

    it('mergeHistoryTruncatesToLimit', 0, (): void => {
      const local: Object[] = []
      for (let i: number = 0; i < 501; i++) {
        local.push(timedEntry(String(i), i + 1))
      }
      const result = mergePayload(DomainIds.HISTORY, null, local)
      const list: Object[] = asItemList(result.merged)

      expect(list.length).assertEqual(500)
      expect(itemNumber(list[0], 'ts')).assertEqual(501)
      expect(result.added).assertEqual(501)
    })

    it('mergeReadingProgressKeepsNewer', 0, (): void => {
      const local: Object[] = [timedEntry('10', 1000)]
      const incoming: Object[] = [timedEntry('10', 2000), timedEntry('11', 1500)]

      const result = mergePayload(DomainIds.READING_PROGRESS, local, incoming)
      const list: Object[] = asItemList(result.merged)

      expect(list.length).assertEqual(2)
      expect(itemString(list[0], 'tid')).assertEqual('10')
      expect(itemNumber(list[0], 'ts')).assertEqual(2000)
      expect(result.added).assertEqual(1)
      expect(result.updated).assertEqual(1)
    })

    it('mergeVotesKeepsNewerTimestamp', 0, (): void => {
      const local: Record<string, Object> = {}
      local['100'] = voteEntry(50)
      local['200'] = voteEntry(500)
      const incoming: Record<string, Object> = {}
      incoming['100'] = voteEntry(80)
      incoming['300'] = voteEntry(10)

      const result = mergePayload(DomainIds.VOTES, local, incoming)
      const merged: Record<string, Object> = result.merged as Record<string, Object>

      expect(result.added).assertEqual(1)
      expect(result.updated).assertEqual(1)
      expect(itemNumber(recordObject(merged, '100'), 'ts')).assertEqual(80)
      expect(itemNumber(recordObject(merged, '200'), 'ts')).assertEqual(500)
      expect(itemNumber(recordObject(merged, '300'), 'ts')).assertEqual(10)
    })

    it('mergeVotesTruncatesToLimit', 0, (): void => {
      const incoming: Record<string, Object> = {}
      for (let i: number = 0; i < 201; i++) {
        incoming[String(i)] = voteEntry(i + 1)
      }
      const result = mergePayload(DomainIds.VOTES, null, incoming)
      const merged: Record<string, Object> = result.merged as Record<string, Object>

      expect(Object.keys(merged).length).assertEqual(200)
      // 最旧的键（ts=1）被淘汰
      expect(merged['0'] === undefined).assertTrue()
    })

    it('mergePollVotedKeepsLargerTimestamp', 0, (): void => {
      const local: Record<string, number> = {}
      local['100'] = 500
      local['200'] = 100
      const incoming: Record<string, number> = {}
      incoming['100'] = 300
      incoming['200'] = 400
      incoming['300'] = 50

      const result = mergePayload(DomainIds.POLL_VOTED, local, incoming)
      const merged: Record<string, number> = result.merged as Record<string, number>

      expect(result.added).assertEqual(1)
      expect(result.updated).assertEqual(1)
      expect(merged['100'] ?? 0).assertEqual(500)
      expect(merged['200'] ?? 0).assertEqual(400)
      expect(merged['300'] ?? 0).assertEqual(50)
    })

    it('mergeTrackedThreadsUsesItemsEnvelopeAndLastCheckAt', 0, (): void => {
      const local: Record<string, Object> = {}
      local['items'] = [trackedEntry('1', 1000, 100)]
      const incoming: Record<string, Object> = {}
      incoming['items'] = [trackedEntry('1', 2000, 100), trackedEntry('2', 0, 500)]

      const result = mergePayload(DomainIds.TRACKED_THREADS, local, incoming)
      const items: Object[] = asWrappedItems(result.merged)

      expect(items.length).assertEqual(2)
      expect(result.added).assertEqual(1)
      expect(result.updated).assertEqual(1)
      expect(itemNumber(items[0], 'lastCheckAt')).assertEqual(2000)
    })

    it('mergeAiSessionsKeepsNewerAndLimitsToMax', 0, (): void => {
      const localList: Object[] = []
      for (let i: number = 0; i < 20; i++) {
        localList.push(aiSessionEntry('s' + String(i), 1000 + i))
      }
      const local: Record<string, Object> = {}
      local['items'] = localList
      const incomingList: Object[] = [aiSessionEntry('s0', 5000), aiSessionEntry('new', 10)]
      const incoming: Record<string, Object> = {}
      incoming['items'] = incomingList

      const result = mergePayload(DomainIds.AI_SESSIONS, local, incoming)
      const items: Object[] = asWrappedItems(result.merged)

      expect(items.length).assertEqual(20)
      expect(result.added).assertEqual(1)
      expect(result.updated).assertEqual(1)
    })

    it('mergeSettingsOverridesScalarsAndUnionsArrays', 0, (): void => {
      const local: SettingsSample = settingsSample(15)
      local.blacklist = [blacklistEntry('u1', 'old')]
      local.aiProfiles = [aiProfile('p1', 'old')]
      local.scenarioSystemPrompts = { 'k1': 'v1' }
      const incoming: SettingsSample = settingsSample(18)
      incoming.blacklist = [blacklistEntry('u1', 'new'), blacklistEntry('u2', 'b')]
      incoming.aiProfiles = [aiProfile('p1', 'new'), aiProfile('p2', 'p2')]
      incoming.scenarioSystemPrompts = { 'k1': 'v2', 'k2': 'v2' }
      incoming.showSignature = false

      const result = mergePayload(DomainIds.SETTINGS, local, incoming)
      const merged: Record<string, Object> = result.merged as Record<string, Object>

      expect(Number(merged['fontSize'])).assertEqual(18)
      expect(String(merged['showSignature'])).assertEqual('false')
      const blacklist: Object[] = merged['blacklist'] as Object[]
      expect(blacklist.length).assertEqual(2)
      expect(itemString(blacklist[0], 'nickName')).assertEqual('new')
      const profiles: Object[] = merged['aiProfiles'] as Object[]
      expect(profiles.length).assertEqual(2)
      expect(itemString(profiles[0], 'name')).assertEqual('new')
      const prompts: Record<string, string> = merged['scenarioSystemPrompts'] as Record<string, string>
      expect(String(prompts['k1'])).assertEqual('v2')
      expect(String(prompts['k2'])).assertEqual('v2')
      // 计数：fontSize/showSignature/黑名单 u1/AI 配置 p1/提示词 k1 共 5 项更新；u2/p2/k2 共 3 项新增
      expect(result.updated).assertEqual(5)
      expect(result.added).assertEqual(3)
    })

    it('mergeSettingsIsIdempotent', 0, (): void => {
      const local: SettingsSample = settingsSample(15)
      local.blacklist = [blacklistEntry('u1', 'a')]
      local.aiProfiles = [aiProfile('p1', 'p1')]
      const incoming: SettingsSample = settingsSample(15)
      incoming.blacklist = [blacklistEntry('u1', 'a')]
      incoming.aiProfiles = [aiProfile('p1', 'p1')]

      const result = mergePayload(DomainIds.SETTINGS, local, incoming)
      const merged: Record<string, Object> = result.merged as Record<string, Object>

      expect(result.added).assertEqual(0)
      expect(result.updated).assertEqual(0)
      const blacklist: Object[] = merged['blacklist'] as Object[]
      expect(blacklist.length).assertEqual(1)
      const profiles: Object[] = merged['aiProfiles'] as Object[]
      expect(profiles.length).assertEqual(1)
    })

    it('mergeThemeReplacesIncoming', 0, (): void => {
      const local: ThemeSample = new ThemeSample()
      local.theme = 'light'
      const incoming: ThemeSample = new ThemeSample()
      incoming.theme = 'dark'

      const result = mergePayload(DomainIds.THEME, local, incoming)
      const merged: Record<string, Object> = result.merged as Record<string, Object>

      expect(String(merged['theme'])).assertEqual('dark')
      expect(result.updated).assertEqual(1)
    })

    it('mergeDraftsReplacesByKey', 0, (): void => {
      const localDraft: DraftSample = new DraftSample()
      localDraft.key = 'k1'
      localDraft.content = 'old'
      const incomingDraft: DraftSample = new DraftSample()
      incomingDraft.key = 'k1'
      incomingDraft.content = 'new'
      const newDraft: DraftSample = new DraftSample()
      newDraft.key = 'k2'
      newDraft.content = 'draft2'

      const result = mergePayload(DomainIds.DRAFTS, [localDraft], [incomingDraft, newDraft])
      const list: Object[] = asItemList(result.merged)

      expect(list.length).assertEqual(2)
      expect(result.added).assertEqual(1)
      expect(result.updated).assertEqual(1)
      expect(itemString(list[0], 'content')).assertEqual('new')
    })

    it('mergeSavedThreadsReplacesByTid', 0, (): void => {
      const localThread: SavedThreadSample = new SavedThreadSample()
      localThread.tid = '44191387'
      localThread.subject = 'old'
      const incomingThread: SavedThreadSample = new SavedThreadSample()
      incomingThread.tid = '44191387'
      incomingThread.subject = 'new'

      const result = mergePayload(DomainIds.SAVED_THREADS, [localThread], [incomingThread])
      const list: Object[] = asItemList(result.merged)

      expect(list.length).assertEqual(1)
      expect(result.updated).assertEqual(1)
      expect(itemString(list[0], 'subject')).assertEqual('new')
    })

    it('skipsInvalidIncomingEntries', 0, (): void => {
      const local: Object[] = [timedEntry('1', 100)]
      const incoming: Object[] = []
      incoming.push(timedEntry('2', 50))
      incoming.push(new Object())
      incoming.push('bad-entry' as Object)
      incoming.push(timedEntry('', 10))

      const result = mergePayload(DomainIds.HISTORY, local, incoming)
      const list: Object[] = asItemList(result.merged)

      expect(list.length).assertEqual(2)
      expect(result.added).assertEqual(1)
      expect(result.skipped >= 3).assertTrue()
    })

    it('passesThroughUnknownDomain', 0, (): void => {
      const incoming: Record<string, Object> = {}
      incoming['foo'] = 'bar'

      const result = mergePayload('not_a_real_domain', null, incoming)
      const merged: Record<string, Object> = result.merged as Record<string, Object>

      expect(String(merged['foo'])).assertEqual('bar')
      expect(result.added).assertEqual(0)
      expect(result.updated).assertEqual(0)
    })
  })
}
