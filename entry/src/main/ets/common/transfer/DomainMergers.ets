/**
 * 各域导入合并器（纯逻辑，**禁止 IO**）。
 *
 * ## 职责
 * 把「导出包里的某域 payload」与「本机该域 payload」合并成新 payload，并给出
 * `added / updated / skipped` 计数（供导入计划预览与结果页展示）。域清单与策略以
 * `common/persistence/PersistenceCatalog.ets`（`DomainIds` / `DomainSpec.importPolicy`）为准，
 * 本文件**不维护第二份域清单**。
 *
 * ## 形态约定（与 `DomainMigrators` 的产出、`PersistenceHub` 的载荷一致）
 * - `settings` / `theme`：普通对象（`SettingsState` 结构）；
 * - `history` / `reading_progress` / `tree_reading_progress`：**裸数组**；
 * - `votes` / `poll_voted`：`Record<tid, 值>`；
 * - `tracked_threads` / `ai_sessions`：`{items: T[]}` 信封形态（**输出强制归一为该形态**：
 *   `CacheEnvelopeStore` 只认 `payload.items`，裸数组写回后 Store 会读成空域，见审计 IMP-09）；
 * - `drafts` / `saved_threads`：元素含业务键（`key` / `tid`）的**裸数组**。
 *
 * 裸数组类域（history/reading_progress/tree_reading_progress/drafts/saved_threads）对两种形态都容忍，
 * 输出形态优先跟随导入文件，因此同一份数据导入后再导出不会因形态变化而反复改键。
 *
 * ## 安全与幂等
 * - 所有输入按**不可信**处理：逐条做类型校验，坏条目丢弃并计入 `skipped`；
 * - 幂等：`mergePayload(id, X, X)` 不产生重复条目，`added`/`updated` 均为 0；
 * - 不修改入参对象（重建新对象/新数组返回，ArkTS 无 `delete`，也不依赖对象布局）。
 *
 * 合并语义见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §6.4。
 */

import { DomainIds } from '../persistence/PersistenceCatalog'
import { MAX_AI_SESSIONS } from '../../model/AiSession'
import { TRACK_MAX_COUNT } from '../../model/TrackedThread'

/** 浏览历史上限（与 `HistoryStore.HISTORY_MAX_COUNT` 一致，500）。 */
const HISTORY_MAX_COUNT: number = 500

/** 阅读进度上限（与 `ReadingProgressStore.PROGRESS_MAX_COUNT` 一致，200）。 */
const READING_PROGRESS_MAX_COUNT: number = 200

/** 递进树阅读进度上限（与 `ThreadTreeProgressStore` 的模块常量一致，200）。 */
const TREE_PROGRESS_MAX_COUNT: number = 200

/** 投票记录上限（与 `VoteStore.VOTE_MAX_ENTRIES` 一致，200）。 */
const VOTE_MAX_ENTRIES: number = 200

/** `settings` 中需要"按业务键并集去重"的数组字段 → 业务键字段名。 */
const SETTINGS_ARRAY_KEY_FIELDS: Record<string, string> = {
  'blacklist': 'userId',
  'filterKeywords': 'keyword',
  'notes': 'userId',
  'favorites': 'fid',
  'aiProfiles': 'id',
  'aiSearchProfiles': 'id',
  'aiPresets': 'id'
}

/**
 * 单域合并结果。
 *
 * `merged` 的运行时类型：settings/theme/votes 为对象、数组类域为数组（tracked/ai 为
 * `{items}` 对象），调用方按域约定取用即可。
 */
export class MergeResult {
  /** 合并后的 payload。 */
  merged: Object = new Object()
  /** 新增条目数（local 没有、导入有）。 */
  added: number = 0
  /** 更新条目数（两边都有且导入更新/导入值优先）。 */
  updated: number = 0
  /** 跳过条目数（无效、重复、本机较新、无变化）。 */
  skipped: number = 0
}

/** 数组类 payload 的形态视图（裸数组 / `{items}` 信封）。 */
class ArrayPayloadView {
  /** 数组内容（形态非法时为空数组）。 */
  items: Object[] = []
  /** 是否 `{items: T[]}` 信封形态。 */
  wrapped: boolean = false
  /** 是否成功识别出数组结构。 */
  valid: boolean = false
}

/** 数组合并中间结果。 */
class ArrayMergeOutcome {
  /** 合并后的条目（已排序/截断）。 */
  items: Object[] = []
  /** 新增条目数。 */
  added: number = 0
  /** 更新条目数。 */
  updated: number = 0
  /** 跳过条目数。 */
  skipped: number = 0
}

/** `Record<tid, 对象>` 合并中间结果。 */
class RecordMergeOutcome {
  /** 合并后的记录。 */
  record: Record<string, Object> = {}
  /** 新增键数。 */
  added: number = 0
  /** 更新键数。 */
  updated: number = 0
  /** 跳过键数。 */
  skipped: number = 0
}

/** `Record<string, string>`（如 `scenarioSystemPrompts`）合并中间结果。 */
class StringRecordMergeOutcome {
  /** 合并后的记录。 */
  record: Record<string, string> = {}
  /** 新增键数。 */
  added: number = 0
  /** 更新键数。 */
  updated: number = 0
  /** 跳过键数。 */
  skipped: number = 0
}

// ============== 对外入口 ==============

/**
 * 合并一个域的本地数据与导入数据。
 *
 * @param domainId - 域 ID（取 `DomainIds` 常量）
 * @param localPayload - 本机该域 payload；无本机数据时传 null
 * @param incomingPayload - 导入包里的该域 payload
 * @returns 合并结果（含计数）
 */
export function mergePayload(domainId: string, localPayload: Object | null,
  incomingPayload: Object): MergeResult {
  if (incomingPayload === null || incomingPayload === undefined) {
    const emptyResult: MergeResult = new MergeResult()
    emptyResult.merged = localPayload !== null && localPayload !== undefined ?
      localPayload : new Object()
    emptyResult.skipped++
    return emptyResult
  }
  switch (domainId) {
    case DomainIds.SETTINGS:
      return mergeSettings(localPayload, incomingPayload)
    case DomainIds.THEME:
      return mergeReplace(localPayload, incomingPayload)
    case DomainIds.HISTORY:
      return mergeArrayPayloadByTime(localPayload, incomingPayload, 'tid', 'ts', '', HISTORY_MAX_COUNT,
        false)
    case DomainIds.READING_PROGRESS:
      return mergeArrayPayloadByTime(localPayload, incomingPayload, 'tid', 'ts', '',
        READING_PROGRESS_MAX_COUNT, false)
    case DomainIds.TREE_READING_PROGRESS:
      return mergeArrayPayloadByTime(localPayload, incomingPayload, 'tid', 'ts', '',
        TREE_PROGRESS_MAX_COUNT, false)
    case DomainIds.TRACKED_THREADS:
      return mergeArrayPayloadByTime(localPayload, incomingPayload, 'tid', 'lastCheckAt',
        'createdAt', TRACK_MAX_COUNT, true)
    case DomainIds.AI_SESSIONS:
      return mergeArrayPayloadByTime(localPayload, incomingPayload, 'id', 'updatedAt',
        'createdAt', MAX_AI_SESSIONS, true)
    case DomainIds.VOTES:
      return mergeVotes(localPayload, incomingPayload)
    case DomainIds.POLL_VOTED:
      return mergePollVoted(localPayload, incomingPayload)
    case DomainIds.DRAFTS:
      return mergeArrayPayloadByKey(localPayload, incomingPayload, 'key')
    case DomainIds.SAVED_THREADS:
      return mergeArrayPayloadByKey(localPayload, incomingPayload, 'tid')
    default:
      /*
       * 缓存/账号镜像域（categories/profiles/notifications/activities/favorite_membership/
       * ai_tool_cache）：导入计划在「恢复缓存类数据」开启时按导入值整体覆盖（透传），
       * 关闭时由计划层跳过。此处只做透传，不参与按键/按时间合并。
       */
      return passthrough(incomingPayload)
  }
}

// ============== 各域实现 ==============

/**
 * settings 域：字段级覆盖 + 数组字段按业务键并集（导入值优先）。
 *
 * @param localPayload - 本机 settings
 * @param incomingPayload - 导入的 settings
 * @returns 合并结果
 */
function mergeSettings(localPayload: Object | null, incomingPayload: Object): MergeResult {
  const result: MergeResult = new MergeResult()
  const localRecord: Record<string, Object> | null = asRecord(localPayload)
  const incomingRecord: Record<string, Object> | null = asRecord(incomingPayload)
  if (incomingRecord === null) {
    result.merged = localRecord !== null ? localRecord : new Object()
    result.skipped++
    return result
  }
  const merged: Record<string, Object> = {}
  // 1) 以本机字段为基（保留本机独有字段与顺序）
  if (localRecord !== null) {
    const localKeys: string[] = Object.keys(localRecord)
    for (let i: number = 0; i < localKeys.length; i++) {
      const value: Object | undefined = localRecord[localKeys[i]]
      if (value !== undefined) {
        merged[localKeys[i]] = value
      }
    }
  }
  // 2) 逐个合并导入字段
  const incomingKeys: string[] = Object.keys(incomingRecord)
  for (let i: number = 0; i < incomingKeys.length; i++) {
    const field: string = incomingKeys[i]
    const incomingValue: Object | undefined = incomingRecord[field]
    if (incomingValue === undefined) {
      result.skipped++
      continue
    }
    const localValue: Object | undefined =
      localRecord !== null ? localRecord[field] : undefined
    const arrayKeyField: string | undefined = SETTINGS_ARRAY_KEY_FIELDS[field]
    if (Array.isArray(incomingValue) && arrayKeyField !== undefined) {
      const outcome: ArrayMergeOutcome = mergeArrayPreferIncoming(
        asObjectArray(localValue), incomingValue as Object[], arrayKeyField)
      merged[field] = outcome.items
      result.added += outcome.added
      result.updated += outcome.updated
      result.skipped += outcome.skipped
      continue
    }
    if (field === 'scenarioSystemPrompts' && asRecord(incomingValue) !== null) {
      const prompts: StringRecordMergeOutcome = mergeStringRecord(localValue, incomingValue)
      merged[field] = prompts.record
      result.added += prompts.added
      result.updated += prompts.updated
      result.skipped += prompts.skipped
      continue
    }
    // 标量 / 普通对象 / 未登记数组：整体覆盖（导入值优先）
    if (localValue === undefined) {
      merged[field] = incomingValue
      result.added++
    } else if (sameValue(localValue, incomingValue)) {
      result.skipped++
    } else {
      merged[field] = incomingValue
      result.updated++
    }
  }
  result.merged = merged
  return result
}

/**
 * 覆盖型域（theme）：导入值整体覆盖本机值。
 *
 * @param localPayload - 本机值
 * @param incomingPayload - 导入值
 * @returns 合并结果
 */
function mergeReplace(localPayload: Object | null, incomingPayload: Object): MergeResult {
  const result: MergeResult = new MergeResult()
  const incomingRecord: Record<string, Object> | null = asRecord(incomingPayload)
  if (incomingRecord === null) {
    result.merged = localPayload !== null && localPayload !== undefined ?
      localPayload : new Object()
    result.skipped++
    return result
  }
  result.merged = incomingRecord
  if (localPayload === null || localPayload === undefined) {
    result.added++
    return result
  }
  if (sameValue(localPayload, incomingRecord)) {
    result.skipped++
  } else {
    result.updated++
  }
  return result
}

/**
 * 数组类域：按业务键去重、按时间字段取较新，排序后截断。
 *
 * @param localPayload - 本机 payload（裸数组或 `{items}`）
 * @param incomingPayload - 导入 payload（裸数组或 `{items}`）
 * @param keyField - 业务键字段名
 * @param timeField - 时间字段名（升序数值，越大越新）
 * @param fallbackTimeField - 时间字段为 0 时的回退字段（空串表示不回退）
 * @param maxCount - 条目上限
 * @param forceWrapped - 是否强制输出 `{items: T[]}` 形态（ENVELOPE 域必须为 true：
 *   `CacheEnvelopeStore` 只读 `payload.items`，写出裸数组会被 Store 判为非法并读成空域）
 * @returns 合并结果
 */
function mergeArrayPayloadByTime(localPayload: Object | null, incomingPayload: Object,
  keyField: string, timeField: string, fallbackTimeField: string,
  maxCount: number, forceWrapped: boolean): MergeResult {
  const result: MergeResult = new MergeResult()
  const localView: ArrayPayloadView = readArrayPayload(localPayload)
  const incomingView: ArrayPayloadView = readArrayPayload(incomingPayload)
  const outcome: ArrayMergeOutcome = mergeArrayByTime(localView.items, incomingView.items,
    keyField, timeField, fallbackTimeField, maxCount)
  const outView: ArrayPayloadView = new ArrayPayloadView()
  outView.wrapped = forceWrapped || (incomingView.valid ? incomingView.wrapped : localView.wrapped)
  result.merged = buildArrayPayload(outView, outcome.items)
  result.added = outcome.added
  result.updated = outcome.updated
  result.skipped = outcome.skipped
  if (!incomingView.valid) {
    result.skipped++
  }
  return result
}

/**
 * 按键覆盖型域（drafts / saved_threads）：同键以导入值为准，不看时间。
 *
 * @param localPayload - 本机 payload
 * @param incomingPayload - 导入 payload
 * @param keyField - 业务键字段名
 * @returns 合并结果
 */
function mergeArrayPayloadByKey(localPayload: Object | null, incomingPayload: Object,
  keyField: string): MergeResult {
  const result: MergeResult = new MergeResult()
  const localView: ArrayPayloadView = readArrayPayload(localPayload)
  const incomingView: ArrayPayloadView = readArrayPayload(incomingPayload)
  const outcome: ArrayMergeOutcome =
    mergeArrayPreferIncoming(localView.items, incomingView.items, keyField)
  const outView: ArrayPayloadView = new ArrayPayloadView()
  outView.wrapped = incomingView.valid ? incomingView.wrapped : localView.wrapped
  result.merged = buildArrayPayload(outView, outcome.items)
  result.added = outcome.added
  result.updated = outcome.updated
  result.skipped = outcome.skipped
  if (!incomingView.valid) {
    result.skipped++
  }
  return result
}

/**
 * votes 域：`Record<tid, {upPids, downPids, ts}>` 按 ts 取较新，截断上限。
 *
 * @param localPayload - 本机记录
 * @param incomingPayload - 导入记录
 * @returns 合并结果
 */
function mergeVotes(localPayload: Object | null, incomingPayload: Object): MergeResult {
  const result: MergeResult = new MergeResult()
  const localRecord: Record<string, Object> | null = asRecord(localPayload)
  const incomingRecord: Record<string, Object> | null = asRecord(incomingPayload)
  if (incomingRecord === null) {
    result.merged = localRecord !== null ? localRecord : new Object()
    result.skipped++
    return result
  }
  const outcome: RecordMergeOutcome =
    mergeRecordByTime(localRecord, incomingRecord, 'ts', VOTE_MAX_ENTRIES)
  result.merged = outcome.record
  result.added = outcome.added
  result.updated = outcome.updated
  result.skipped = outcome.skipped
  return result
}

/**
 * poll_voted 域：`Record<tid, 时间戳>` 取较大时间戳，截断上限。
 *
 * 单独实现而不用 `mergeRecordByTime`：值为 number 而非对象，避免把 number 装进
 * `Object` 泛型（ArkTS 对装箱的静态检查更保守）。
 *
 * @param localPayload - 本机记录
 * @param incomingPayload - 导入记录
 * @returns 合并结果
 */
function mergePollVoted(localPayload: Object | null, incomingPayload: Object): MergeResult {
  const result: MergeResult = new MergeResult()
  const localRecord: Record<string, Object> | null = asRecord(localPayload)
  const incomingRecord: Record<string, Object> | null = asRecord(incomingPayload)
  if (incomingRecord === null) {
    result.merged = localRecord !== null ? localRecord : new Object()
    result.skipped++
    return result
  }
  const times: Map<string, number> = new Map<string, number>()
  if (localRecord !== null) {
    const localKeys: string[] = Object.keys(localRecord)
    for (let i: number = 0; i < localKeys.length; i++) {
      const key: string = localKeys[i]
      if (key.length === 0) {
        result.skipped++
        continue
      }
      times.set(key, readFiniteNumber(localRecord[key]))
    }
  }
  const incomingKeys: string[] = Object.keys(incomingRecord)
  for (let i: number = 0; i < incomingKeys.length; i++) {
    const key: string = incomingKeys[i]
    if (key.length === 0) {
      result.skipped++
      continue
    }
    const incomingTime: number = readFiniteNumber(incomingRecord[key])
    const existing: number | undefined = times.get(key)
    if (existing === undefined) {
      times.set(key, incomingTime)
      result.added++
      continue
    }
    if (incomingTime > existing) {
      times.set(key, incomingTime)
      result.updated++
    } else {
      result.skipped++
    }
  }
  // 截断：超上限时按时间降序保留最新（重建对象，ArkTS 无 delete）
  const allKeys: string[] = []
  times.forEach((_value: number, key: string): void => {
    allKeys.push(key)
  })
  const keptKeys: string[] = allKeys.length > VOTE_MAX_ENTRIES ?
    sortKeysByTimeDesc(allKeys, times).slice(0, VOTE_MAX_ENTRIES) : allKeys
  const kept: Record<string, number> = {}
  for (let i: number = 0; i < keptKeys.length; i++) {
    const time: number | undefined = times.get(keptKeys[i])
    if (time !== undefined) {
      kept[keptKeys[i]] = time
    }
  }
  result.merged = kept
  return result
}

/**
 * 未归类域的兜底：导入值原样返回。
 *
 * @param incomingPayload - 导入 payload
 * @returns 合并结果（计数为 0）
 */
function passthrough(incomingPayload: Object): MergeResult {
  const result: MergeResult = new MergeResult()
  result.merged = incomingPayload
  return result
}

// ============== 数组/记录合并核心 ==============

/**
 * 按业务键去重、按时间取较新的数组合并（本地为准，导入较新才覆盖）。
 *
 * @param localItems - 本机条目
 * @param incomingItems - 导入条目
 * @param keyField - 业务键字段
 * @param timeField - 时间字段
 * @param fallbackTimeField - 时间字段为 0 时的回退字段（空串不回退）
 * @param maxCount - 条目上限（按时间降序截断）
 * @returns 合并结果
 */
function mergeArrayByTime(localItems: Object[], incomingItems: Object[], keyField: string,
  timeField: string, fallbackTimeField: string, maxCount: number): ArrayMergeOutcome {
  const outcome: ArrayMergeOutcome = new ArrayMergeOutcome()
  const byKey: Map<string, Object> = new Map<string, Object>()
  const times: Map<string, number> = new Map<string, number>()
  for (let i: number = 0; i < localItems.length; i++) {
    const key: string = itemKey(localItems[i], keyField)
    if (key.length === 0) {
      outcome.skipped++
      continue
    }
    if (byKey.has(key)) {
      // 本机数组内部重复：保留首条
      outcome.skipped++
      continue
    }
    byKey.set(key, localItems[i])
    times.set(key, itemTime(localItems[i], timeField, fallbackTimeField))
  }
  for (let i: number = 0; i < incomingItems.length; i++) {
    const item: Object = incomingItems[i]
    const key: string = itemKey(item, keyField)
    if (key.length === 0) {
      outcome.skipped++
      continue
    }
    const incomingTime: number = itemTime(item, timeField, fallbackTimeField)
    if (!byKey.has(key)) {
      byKey.set(key, item)
      times.set(key, incomingTime)
      outcome.added++
      continue
    }
    const localTime: number = times.get(key) ?? 0
    if (incomingTime > localTime) {
      byKey.set(key, item)
      times.set(key, incomingTime)
      outcome.updated++
    } else {
      outcome.skipped++
    }
  }
  const list: Object[] = []
  byKey.forEach((value: Object): void => {
    list.push(value)
  })
  list.sort((a: Object, b: Object): number => {
    return itemTime(b, timeField, fallbackTimeField) -
      itemTime(a, timeField, fallbackTimeField)
  })
  outcome.items = list.length > maxCount ? list.slice(0, maxCount) : list
  return outcome
}

/**
 * 按业务键并集、同键以导入值为准的数组合并（settings 数组字段 / drafts / saved_threads）。
 *
 * @param localItems - 本机条目
 * @param incomingItems - 导入条目
 * @param keyField - 业务键字段
 * @returns 合并结果
 */
function mergeArrayPreferIncoming(localItems: Object[], incomingItems: Object[],
  keyField: string): ArrayMergeOutcome {
  const outcome: ArrayMergeOutcome = new ArrayMergeOutcome()
  const byKey: Map<string, Object> = new Map<string, Object>()
  for (let i: number = 0; i < localItems.length; i++) {
    const key: string = itemKey(localItems[i], keyField)
    if (key.length === 0) {
      outcome.skipped++
      continue
    }
    if (byKey.has(key)) {
      outcome.skipped++
      continue
    }
    byKey.set(key, localItems[i])
  }
  for (let i: number = 0; i < incomingItems.length; i++) {
    const item: Object = incomingItems[i]
    const key: string = itemKey(item, keyField)
    if (key.length === 0) {
      outcome.skipped++
      continue
    }
    const existing: Object | undefined = byKey.get(key)
    if (existing === undefined) {
      byKey.set(key, item)
      outcome.added++
      continue
    }
    if (sameValue(existing, item)) {
      outcome.skipped++
    } else {
      byKey.set(key, item)
      outcome.updated++
    }
  }
  byKey.forEach((value: Object): void => {
    outcome.items.push(value)
  })
  return outcome
}

/**
 * `Record<key, 对象>` 按对象内时间字段取较新，截断上限。
 *
 * @param localRecord - 本机记录
 * @param incomingRecord - 导入记录
 * @param timeField - 值对象内的时间字段名
 * @param maxCount - 键数上限
 * @returns 合并结果
 */
function mergeRecordByTime(localRecord: Record<string, Object> | null,
  incomingRecord: Record<string, Object>, timeField: string,
  maxCount: number): RecordMergeOutcome {
  const outcome: RecordMergeOutcome = new RecordMergeOutcome()
  const values: Map<string, Object> = new Map<string, Object>()
  const times: Map<string, number> = new Map<string, number>()
  if (localRecord !== null) {
    const localKeys: string[] = Object.keys(localRecord)
    for (let i: number = 0; i < localKeys.length; i++) {
      const key: string = localKeys[i]
      const value: Object | undefined = localRecord[key]
      if (key.length === 0 || value === undefined) {
        outcome.skipped++
        continue
      }
      values.set(key, value)
      times.set(key, recordValueTime(value, timeField))
    }
  }
  const incomingKeys: string[] = Object.keys(incomingRecord)
  for (let i: number = 0; i < incomingKeys.length; i++) {
    const key: string = incomingKeys[i]
    const value: Object | undefined = incomingRecord[key]
    if (key.length === 0 || value === undefined) {
      outcome.skipped++
      continue
    }
    const incomingTime: number = recordValueTime(value, timeField)
    if (!values.has(key)) {
      values.set(key, value)
      times.set(key, incomingTime)
      outcome.added++
      continue
    }
    const localTime: number = times.get(key) ?? 0
    if (incomingTime > localTime) {
      values.set(key, value)
      times.set(key, incomingTime)
      outcome.updated++
    } else {
      outcome.skipped++
    }
  }
  const allKeys: string[] = []
  values.forEach((_value: Object, key: string): void => {
    allKeys.push(key)
  })
  const keptKeys: string[] = allKeys.length > maxCount ?
    sortKeysByTimeDesc(allKeys, times).slice(0, maxCount) : allKeys
  for (let i: number = 0; i < keptKeys.length; i++) {
    const value: Object | undefined = values.get(keptKeys[i])
    if (value !== undefined) {
      outcome.record[keptKeys[i]] = value
    }
  }
  return outcome
}

/**
 * 合并 `Record<string, string>`（settings 的 `scenarioSystemPrompts`），导入值优先。
 *
 * @param localValue - 本机记录（可能不是记录）
 * @param incomingValue - 导入记录
 * @returns 合并结果
 */
function mergeStringRecord(localValue: Object | undefined,
  incomingValue: Object): StringRecordMergeOutcome {
  const outcome: StringRecordMergeOutcome = new StringRecordMergeOutcome()
  const localRecord: Record<string, Object> | null = asRecord(localValue)
  if (localRecord !== null) {
    const localKeys: string[] = Object.keys(localRecord)
    for (let i: number = 0; i < localKeys.length; i++) {
      const value: Object | undefined = localRecord[localKeys[i]]
      if (typeof value === 'string') {
        outcome.record[localKeys[i]] = value as string
      } else {
        outcome.skipped++
      }
    }
  }
  const incomingRecord: Record<string, Object> | null = asRecord(incomingValue)
  if (incomingRecord === null) {
    outcome.skipped++
    return outcome
  }
  const incomingKeys: string[] = Object.keys(incomingRecord)
  for (let i: number = 0; i < incomingKeys.length; i++) {
    const key: string = incomingKeys[i]
    const value: Object | undefined = incomingRecord[key]
    if (key.length === 0 || typeof value !== 'string') {
      outcome.skipped++
      continue
    }
    const existing: string | undefined = outcome.record[key]
    if (existing === undefined) {
      outcome.record[key] = value as string
      outcome.added++
    } else if (existing === value as string) {
      outcome.skipped++
    } else {
      outcome.record[key] = value as string
      outcome.updated++
    }
  }
  return outcome
}

// ============== 工具函数 ==============

/**
 * 解析数组类 payload 的形态（裸数组 / `{items: T[]}` 信封）。
 *
 * @param payload - 域 payload
 * @returns 形态视图
 */
function readArrayPayload(payload: Object | null): ArrayPayloadView {
  const view: ArrayPayloadView = new ArrayPayloadView()
  if (payload === null || payload === undefined) {
    view.valid = true
    return view
  }
  if (Array.isArray(payload)) {
    view.valid = true
    view.items = payload as Object[]
    return view
  }
  const record: Record<string, Object> | null = asRecord(payload)
  if (record !== null) {
    const items: Object | undefined = record['items']
    if (items !== undefined && items !== null && Array.isArray(items)) {
      view.valid = true
      view.wrapped = true
      view.items = items as Object[]
    }
  }
  return view
}

/**
 * 按形态构造数组类 payload。
 *
 * @param view - 形态视图（仅用其 `wrapped`）
 * @param items - 条目数组
 * @returns payload（裸数组或 `{items}` 对象）
 */
function buildArrayPayload(view: ArrayPayloadView, items: Object[]): Object {
  if (view.wrapped) {
    const payload: Record<string, Object> = {}
    payload['items'] = items
    return payload
  }
  return items
}

/**
 * 读取条目业务键（string 原样，number 转十进制字符串，其他视为无效）。
 *
 * @param item - 条目
 * @param field - 键字段名
 * @returns 业务键；无效时为空串
 */
function itemKey(item: Object, field: string): string {
  const record: Record<string, Object> | null = asRecord(item)
  if (record === null) {
    return ''
  }
  const value: Object | undefined = record[field]
  if (typeof value === 'string') {
    return value as string
  }
  if (typeof value === 'number' && isFinite(value as number)) {
    return String(value as number)
  }
  return ''
}

/**
 * 读条目时间（主字段为 0/非法时回退到次字段）。
 *
 * @param item - 条目
 * @param primaryField - 主时间字段
 * @param fallbackField - 回退时间字段（空串表示不回退）
 * @returns 时间戳（非法时 0）
 */
function itemTime(item: Object, primaryField: string, fallbackField: string): number {
  const record: Record<string, Object> | null = asRecord(item)
  if (record === null) {
    return 0
  }
  const primary: number = readNumber(record[primaryField], 0)
  if (primary > 0 || fallbackField.length === 0) {
    return primary
  }
  return readNumber(record[fallbackField], 0)
}

/**
 * 读记录值内的时间字段。
 *
 * @param value - 记录值
 * @param timeField - 时间字段名（空串表示"值本身即时间"）
 * @returns 时间戳（非法时 0）
 */
function recordValueTime(value: Object, timeField: string): number {
  if (timeField.length === 0) {
    return readFiniteNumber(value)
  }
  const record: Record<string, Object> | null = asRecord(value)
  if (record === null) {
    return 0
  }
  return readNumber(record[timeField], 0)
}

/**
 * 按时间降序排序键数组。
 *
 * @param keys - 键数组
 * @param times - 键 → 时间
 * @returns 排序后的新数组
 */
function sortKeysByTimeDesc(keys: string[], times: Map<string, number>): string[] {
  const sorted: string[] = keys.slice()
  sorted.sort((a: string, b: string): number => {
    const timeA: number = times.get(a) ?? 0
    const timeB: number = times.get(b) ?? 0
    return timeB - timeA
  })
  return sorted
}

/**
 * 判断是否普通对象（非 null、非数组）。
 *
 * @param value - 待判断值（可为 undefined）
 * @returns 是否为普通对象
 */
function asRecord(value: Object | null | undefined): Record<string, Object> | null {
  if (value === null || value === undefined || Array.isArray(value) ||
    typeof value !== 'object') {
    return null
  }
  return value as Record<string, Object>
}

/**
 * 把值当作对象数组（非数组返回空数组）。
 *
 * @param value - 待转换值（可为 undefined）
 * @returns 对象数组
 */
function asObjectArray(value: Object | null | undefined): Object[] {
  if (value === null || value === undefined || !Array.isArray(value)) {
    return []
  }
  return value as Object[]
}

/**
 * 防御性读取有限数值。
 *
 * @param value - 原始值（可为 undefined）
 * @param fallback - 非法时的兜底值
 * @returns 有限数值
 */
function readNumber(value: Object | undefined, fallback: number): number {
  if (typeof value !== 'number' || !isFinite(value as number)) {
    return fallback
  }
  return value as number
}

/**
 * 把任意值读成有限数值（非法时 0）。
 *
 * @param value - 原始值（可为 undefined）
 * @returns 有限数值
 */
function readFiniteNumber(value: Object | undefined): number {
  return readNumber(value, 0)
}

/**
 * 判断两个值是否等价（JSON 序列化比较；用于"无变化"计数）。
 *
 * @param left - 值 A（可为 undefined）
 * @param right - 值 B（可为 undefined）
 * @returns 是否等价
 */
function sameValue(left: Object | undefined, right: Object | undefined): boolean {
  if (left === undefined || right === undefined) {
    return left === right
  }
  if (left === null || right === null) {
    return left === right
  }
  return JSON.stringify(left) === JSON.stringify(right)
}
