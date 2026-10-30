/**
 * 旧数据迁移规则（DomainMigrators）— 把旧键/旧格式数据转换为新域载荷。
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §5.4 / §13.1。本文件只做**纯数据转换**
 * （输入旧值 → 输出新载荷），不读写磁盘、不依赖 Store 实例，因此可被 Hypium 单测直接覆盖。
 *
 * 关键约定：
 * - 存量域使用 RAW 载荷（新键下仍是业务 JSON 原样），迁移 = 搬键 + 必要的结构清洗；
 * - 账号镜像域使用 ENVELOPE 载荷（payload 形如 `{ items: T[] }`），旧信封的 uid 字段被丢弃，
 *   归属改由 Hub 写入时传入的 ownerUid 表达；
 * - 多份旧键（不同 uid）的取舍见 `pickPreferred` / 各域合并器——终极目标是"不丢数据"。
 */

import {
  DomainScope,
  DomainSpec,
  MigrationDomainResult,
  MigrationDomainStatus,
  MigrationReport,
  StorageKind
} from './PersistenceTypes'
import { DomainIds, PersistenceCatalog } from './PersistenceCatalog'
import { MAX_AI_SESSIONS } from '../../model/AiSession'
import { TRACK_MAX_COUNT } from '../../model/TrackedThread'

/** 历史域条目上限（与 HistoryStore.HISTORY_MAX_COUNT 对齐；迁移层不 import store，避免循环依赖）。 */
const HISTORY_MAX_COUNT: number = 500
/** 阅读进度上限（与 ReadingProgressStore.PROGRESS_MAX_COUNT 对齐）。 */
const PROGRESS_MAX_COUNT: number = 200
/** 投票记录上限（与 VoteStore.VOTE_MAX_ENTRIES 对齐）。 */
const VOTE_MAX_ENTRIES: number = 200

/**
 * 旧键识别规则。
 *
 * 匹配顺序敏感：先精确键、后前缀键；`LEGACY_RULES` 的数组顺序即优先级。
 */
export class LegacyKeyRule {
  /** 精确键名（非空时优先按精确匹配）。 */
  readonly exactKey: string
  /** 前缀（含分隔符，如 `history_`）；与 `exactKey` 二选一。 */
  readonly prefix: string
  /** 目标域 ID。 */
  readonly domainId: string

  /**
   * 构造规则。
   *
   * @param exactKey - 精确键名（无则为空串）
   * @param prefix - 前缀（无则为空串）
   * @param domainId - 目标域 ID
   */
  constructor(exactKey: string, prefix: string, domainId: string) {
    this.exactKey = exactKey
    this.prefix = prefix
    this.domainId = domainId
  }

  /**
   * 判断键是否命中本规则。
   *
   * @param key - Preferences 键名
   * @returns 是否命中
   */
  matches(key: string): boolean {
    if (this.exactKey.length > 0) {
      return key === this.exactKey
    }
    return this.prefix.length > 0 && key.startsWith(this.prefix)
  }

  /**
   * 从键尾提取旧账号 uid（前缀规则）。
   *
   * @param key - Preferences 键名
   * @returns uid；精确规则或无法提取返回空串
   */
  uidOf(key: string): string {
    if (this.prefix.length === 0 || !key.startsWith(this.prefix)) {
      return ''
    }
    return key.substring(this.prefix.length)
  }
}

/**
 * 一条旧键数据（已 JSON.parse）。
 */
export class LegacyValue {
  /** 旧键名。 */
  readonly key: string
  /** 从键名解析出的旧账号 uid（可能为空）。 */
  readonly uid: string
  /** 旧值对象。 */
  readonly value: Object

  /**
   * 构造旧值条目。
   *
   * @param key - 旧键名
   * @param uid - 旧账号 uid
   * @param value - 旧值
   */
  constructor(key: string, uid: string, value: Object) {
    this.key = key
    this.uid = uid
    this.value = value
  }
}

/**
 * 迁移上下文。
 */
export class MigrationContext {
  /** 当前登录 uid（无则空串）：多份旧键取舍的首选依据。 */
  readonly currentUid: string
  /** 当前时间戳（单测可注入固定值）。 */
  readonly now: number

  /**
   * 构造上下文。
   *
   * @param currentUid - 当前 uid
   * @param now - 当前时间戳
   */
  constructor(currentUid: string, now: number) {
    this.currentUid = currentUid
    this.now = now
  }
}

/**
 * 单域转换结果。
 */
export class MigrationConvertResult {
  /** 是否转换成功。 */
  ok: boolean = false
  /** 新载荷（RAW 模式为业务 JSON；ENVELOPE 模式为 `{items:...}`）。 */
  payload: Object = new Object()
  /** 转换的条目数（整包可记 1）。 */
  items: number = 0
  /** 失败原因（ok=false 时有效，截断 200 字符）。 */
  error: string = ''
  /** 跳过原因（非空表示无需写入新键，按 SKIPPED 记录）。 */
  skippedReason: string = ''
}

/**
 * 旧键识别规则表（顺序即匹配优先级）。
 *
 * 构造参数为 `(exactKey, prefix, domainId)`：**精确键**传第 1 参、**前缀键**传第 2 参。
 * 注意：所有 `_<uid>` 形态的旧键都是前缀规则（第 2 参），写成精确规则会导致
 * `settings_123` 这类键永远匹配不上、整域迁移静默丢失（曾被 A 的代码审查抓到）。
 */
export const LEGACY_RULES: LegacyKeyRule[] = [
  new LegacyKeyRule('auth', '', DomainIds.AUTH),
  new LegacyKeyRule('sessions', '', DomainIds.SESSIONS),
  new LegacyKeyRule('nga_theme', '', DomainIds.THEME),
  new LegacyKeyRule('cached_categories', '', DomainIds.CATEGORIES),
  new LegacyKeyRule('', 'favorite_topic_membership_v1_', DomainIds.FAVORITE_MEMBERSHIP),
  new LegacyKeyRule('', 'cached_notifications_', DomainIds.NOTIFICATIONS),
  new LegacyKeyRule('', 'cached_activities_', DomainIds.ACTIVITIES),
  new LegacyKeyRule('', 'cached_profiles_v2_', DomainIds.PROFILES),
  new LegacyKeyRule('', 'reading_progress_', DomainIds.READING_PROGRESS),
  new LegacyKeyRule('', 'settings_', DomainIds.SETTINGS),
  new LegacyKeyRule('', 'history_', DomainIds.HISTORY),
  new LegacyKeyRule('', 'tracked_threads_', DomainIds.TRACKED_THREADS),
  new LegacyKeyRule('', 'ai_tool_cache_', DomainIds.AI_TOOL_CACHE),
  new LegacyKeyRule('', 'ai_sessions_', DomainIds.AI_SESSIONS),
  new LegacyKeyRule('', 'pollVoted_', DomainIds.POLL_VOTED),
  new LegacyKeyRule('', 'votes_', DomainIds.VOTES),
]

/**
 * 按旧键名解析目标域与旧 uid。
 *
 * @param key - Preferences 键名
 * @returns 命中的规则；未命中返回 null
 */
export function resolveLegacyRule(key: string): LegacyKeyRule | null {
  for (let i: number = 0; i < LEGACY_RULES.length; i++) {
    if (LEGACY_RULES[i].matches(key)) {
      return LEGACY_RULES[i]
    }
  }
  return null
}

/**
 * 判断某个键是否属于"旧格式"（用于启动检测与旧数据清理）。
 *
 * @param key - Preferences 键名
 * @returns 是否旧键
 */
export function isLegacyKey(key: string): boolean {
  return resolveLegacyRule(key) !== null
}

/**
 * 判断某个键是否为新版命名空间键（`v2.` 或 `v2.` 的 pending 变体）。
 *
 * @param key - Preferences 键名
 * @returns 是否新键
 */
export function isNewNamespaceKey(key: string): boolean {
  return key.startsWith('v2.')
}

/**
 * 把一批旧值转换为指定域的新载荷。
 *
 * @param domainId - 目标域 ID
 * @param values - 属于该域的全部旧值
 * @param ctx - 迁移上下文
 * @returns 转换结果
 */
export function convertDomainValues(
  domainId: string,
  values: LegacyValue[],
  ctx: MigrationContext
): MigrationConvertResult {
  if (values.length === 0) {
    const empty: MigrationConvertResult = new MigrationConvertResult()
    empty.skippedReason = '无旧数据'
    return empty
  }
  switch (domainId) {
    case DomainIds.AUTH:
      return convertPassthrough(values, true)
    case DomainIds.SESSIONS:
      return convertPassthrough(values, true)
    case DomainIds.SETTINGS:
      return convertSettings(values, ctx)
    case DomainIds.THEME:
      return convertPassthrough(values, true)
    case DomainIds.CATEGORIES:
      return convertPassthrough(values, true)
    case DomainIds.PROFILES:
      return convertProfiles(values)
    case DomainIds.NOTIFICATIONS:
      return convertMirrorEnvelope(values, ctx, 'notificationId', 200)
    case DomainIds.ACTIVITIES:
      return convertMirrorEnvelope(values, ctx, 'id', 200)
    case DomainIds.FAVORITE_MEMBERSHIP:
      return convertFavoriteMembership(values, ctx)
    case DomainIds.HISTORY:
      return convertHistory(values)
    case DomainIds.READING_PROGRESS:
      return convertReadingProgress(values)
    case DomainIds.VOTES:
      return convertVotes(values)
    case DomainIds.POLL_VOTED:
      return convertPollVoted(values)
    case DomainIds.TRACKED_THREADS:
      return convertMirrorEnvelope(values, ctx, 'tid', TRACK_MAX_COUNT)
    case DomainIds.AI_SESSIONS:
      return convertAiSessions(values, ctx)
    case DomainIds.AI_TOOL_CACHE:
      return convertDropped('工具缓存无迁移价值（TTL 缓存，可重建）')
    default:
      return convertDropped('未知域（无迁移规则）：' + domainId)
  }
}

/**
 * 原样搬迁（仅换键；auth/sessions/theme/categories 等结构稳定的域）。
 *
 * 这些域通常只有一份旧键，因此取第一份即可。
 *
 * @param values - 旧值
 * @param preferCurrent - 兼容参数（当前实现恒取第一份；多份场景由各自转换器处理）
 * @returns 转换结果
 */
function convertPassthrough(values: LegacyValue[], preferCurrent: boolean): MigrationConvertResult {
  const result: MigrationConvertResult = new MigrationConvertResult()
  if (values.length === 0) {
    result.skippedReason = '无可用旧值'
    return result
  }
  result.ok = true
  result.payload = values[0].value
  result.items = 1
  return result
}

/**
 * settings 域：多份 `settings_<uid>` 取当前账号优先的一份。
 *
 * 说明：settings 的字段级合并语义复杂（数组字段并集）且与 `SettingsState` 结构强耦合，迁移层
 * 不做字段合并——取消账号隔离后"设备只保留一份设置"是产品决策，取当前账号那份最符合直觉；
 * 其余账号的设置仍在旧键中保留 30 天（可人工找回）。
 *
 * @param values - 旧值
 * @param ctx - 上下文
 * @returns 转换结果
 */
function convertSettings(values: LegacyValue[], ctx: MigrationContext): MigrationConvertResult {
  const result: MigrationConvertResult = new MigrationConvertResult()
  let picked: LegacyValue | null = null
  for (let i: number = 0; i < values.length; i++) {
    if (ctx.currentUid.length > 0 && values[i].uid === ctx.currentUid) {
      picked = values[i]
      break
    }
  }
  if (picked === null) {
    /*
     * 无法按当前账号匹配时的取舍：
     * - 只有一份旧设置 → 用它（设备上唯一的设置来源，通常就是用户自己的账号）；
     * - 多份且未登录/当前账号无旧键 → **跳过迁移**（不能把别人的设置含 AI Key/备注/黑名单
     *   迁给之后登录的账号）；旧键保留、不进清理清单，用户登录后会重试并正确匹配。
     */
    if (values.length === 1) {
      picked = values[0]
    } else {
      result.skippedReason = '多账号设置旧键且无当前账号匹配（旧键保留，登录后重试）'
      return result
    }
  }
  result.ok = true
  result.payload = picked.value
  result.items = values.length
  return result
}

/**
 * profiles 域：多份 `cached_profiles_v2_<uid>` 的 `Record<uid, ProfileData>` 合并。
 *
 * @param values - 旧值
 * @returns 转换结果
 */
function convertProfiles(values: LegacyValue[]): MigrationConvertResult {
  const result: MigrationConvertResult = new MigrationConvertResult()
  const merged: Record<string, Object> = {}
  for (let i: number = 0; i < values.length; i++) {
    const record: Object = values[i].value
    if (record === null || record === undefined || Array.isArray(record) || typeof record !== 'object') {
      continue
    }
    const entries: Record<string, Object> = record as Record<string, Object>
    const keys: string[] = Object.keys(entries)
    for (let j: number = 0; j < keys.length; j++) {
      merged[keys[j]] = entries[keys[j]]
    }
  }
  result.ok = true
  result.payload = merged
  result.items = Object.keys(merged).length
  return result
}

/**
 * 账号镜像/信封域（notifications / activities / tracked_threads / ai_sessions）：
 * 旧信封 → 新 `{items}` 载荷。
 *
 * 旧信封形态：`{schemaVersion, uid, items: T[], updatedAt}`；
 * 新形态：Hub 写 `{schemaVersion, domain, updatedAt, ownerUid, payload:{items:T[]}}`。
 *
 * 多份旧键（不同账号）合并时按 `keyField` 去重、取时间较新的条目，并按 `maxCount` 截断——
 * 否则取消账号隔离后多账号旧缓存会叠加成重复条目，甚至撑爆后续 Store 的上限（被 Store 二次
 * 截断时又按不确定顺序丢数据）。
 *
 * @param values - 旧值（可能多份：不同 uid 的旧键）
 * @param ctx - 上下文
 * @param keyField - 条目业务键字段名（notificationId / id / tid）
 * @param maxCount - 条目上限（<=0 表示不截断）
 * @returns 转换结果
 */
function convertMirrorEnvelope(
  values: LegacyValue[],
  ctx: MigrationContext,
  keyField: string,
  maxCount: number
): MigrationConvertResult {
  const result: MigrationConvertResult = new MigrationConvertResult()
  const byKey: Map<string, Record<string, Object>> = new Map<string, Record<string, Object>>()
  const noKey: Object[] = []
  let matchedValueCount: number = 0
  for (let i: number = 0; i < values.length; i++) {
    /*
     * 账号镜像域**只合并当前账号**的旧键：不同 uid 的旧缓存是别的账号的状态，
     * 合并后统一写 ownerUid=当前 uid 会让 A 看到 B 的私信通知/关注动态（串号，
     * 且 Store 的 ownerUid 校验会通过）。无 uid 信息的旧值（键名无法解析）保留兼容。
     */
    if (ctx.currentUid.length > 0 && values[i].uid.length > 0 && values[i].uid !== ctx.currentUid) {
      continue
    }
    matchedValueCount++
    const raw: Object = values[i].value
    if (raw === null || raw === undefined || Array.isArray(raw) || typeof raw !== 'object') {
      continue
    }
    const record: Record<string, Object> = raw as Record<string, Object>
    const rawItems: Object | undefined = record['items']
    if (rawItems === undefined || rawItems === null || !Array.isArray(rawItems)) {
      continue
    }
    const list: Object[] = rawItems as Object[]
    for (let j: number = 0; j < list.length; j++) {
      const item: Object = list[j]
      const itemRecord: Record<string, Object> | null = asRecord(item)
      if (itemRecord === null) {
        continue
      }
      const key: string = readString(itemRecord[keyField])
      if (key.length === 0) {
        noKey.push(item)
        continue
      }
      const existing: Record<string, Object> | undefined = byKey.get(key)
      if (existing === undefined || itemTimestamp(itemRecord) >= itemTimestamp(existing)) {
        byKey.set(key, itemRecord)
      }
    }
  }
  let items: Object[] = []
  byKey.forEach((value: Record<string, Object>): void => {
    items.push(value)
  })
  for (let i: number = 0; i < noKey.length; i++) {
    items.push(noKey[i])
  }
  if (matchedValueCount === 0) {
    // 没有任何属于当前账号的旧值：不写新键，旧键保留（不进清理清单）等待登录后重试
    result.skippedReason = '无可归属当前账号的旧缓存（旧键保留，登录后重试）'
    return result
  }
  if (maxCount > 0 && items.length > maxCount) {
    items.sort((a: Object, b: Object): number => {
      const recordA: Record<string, Object> | null = asRecord(a)
      const recordB: Record<string, Object> | null = asRecord(b)
      const timeA: number = recordA === null ? 0 : itemTimestamp(recordA)
      const timeB: number = recordB === null ? 0 : itemTimestamp(recordB)
      return timeB - timeA
    })
    items = items.slice(0, maxCount)
  }
  const payload: Record<string, Object> = {}
  payload['items'] = items
  result.ok = true
  result.payload = payload
  result.items = items.length
  return result
}

/**
 * 读取条目的排序时间戳（依次回退 updatedAt / lastCheckAt / createdAt）。
 *
 * @param record - 条目对象
 * @returns 时间戳；全部缺失返回 0
 */
function itemTimestamp(record: Record<string, Object>): number {
  const updatedAt: number = readNumber(record['updatedAt'], -1)
  if (updatedAt >= 0) {
    return updatedAt
  }
  const lastCheckAt: number = readNumber(record['lastCheckAt'], -1)
  if (lastCheckAt >= 0) {
    return lastCheckAt
  }
  return readNumber(record['createdAt'], 0)
}

/**
 * favorite_membership 域：旧 `{schemaVersion, uid, favoredFolderIds, knownFolderIds}` → `{favoredFolderIds, knownFolderIds}`。
 *
 * @param values - 旧值
 * @param ctx - 上下文
 * @returns 转换结果
 */
function convertFavoriteMembership(
  values: LegacyValue[],
  ctx: MigrationContext
): MigrationConvertResult {
  const result: MigrationConvertResult = new MigrationConvertResult()
  let picked: LegacyValue | null = null
  for (let i: number = 0; i < values.length; i++) {
    if (ctx.currentUid.length > 0 && values[i].uid === ctx.currentUid) {
      picked = values[i]
      break
    }
  }
  if (picked === null) {
    /*
     * 收藏关系是**账号镜像**：当前账号没有旧键时绝不能 fallback 到别的账号的缓存
     * （否则 B 登录后会显示 A 的收藏夹归属）。旧键保留、不进清理清单，等 B 自己产生新缓存。
     */
    result.skippedReason = '无当前账号的旧收藏关系缓存'
    return result
  }
  const raw: Object = picked.value
  if (raw === null || raw === undefined || Array.isArray(raw) || typeof raw !== 'object') {
    result.skippedReason = '旧收藏关系缓存结构非法'
    return result
  }
  const record: Record<string, Object> = raw as Record<string, Object>
  const payload: Record<string, Object> = {}
  const favored: Object | undefined = record['favoredFolderIds']
  const known: Object | undefined = record['knownFolderIds']
  payload['favoredFolderIds'] = favored !== undefined && favored !== null ? favored : new Object()
  payload['knownFolderIds'] = known !== undefined && known !== null ? known : new Object()
  result.ok = true
  result.payload = payload
  result.items = 1
  return result
}

/**
 * history 域：多份 `BrowseHistoryEntry[]` 合并去重（按 tid 取 ts 较新），排序后截断。
 *
 * @param values - 旧值
 * @returns 转换结果
 */
function convertHistory(values: LegacyValue[]): MigrationConvertResult {
  const result: MigrationConvertResult = new MigrationConvertResult()
  const byTid: Map<string, Object> = new Map<string, Object>()
  for (let i: number = 0; i < values.length; i++) {
    const list: Object[] = asObjectArray(values[i].value)
    for (let j: number = 0; j < list.length; j++) {
      const entry: Record<string, Object> | null = asRecord(list[j])
      if (entry === null) {
        continue
      }
      const tid: string = readString(entry['tid'])
      if (tid.length === 0) {
        continue
      }
      const ts: number = readNumber(entry['ts'], 0)
      const existing: Object | undefined = byTid.get(tid)
      if (existing === undefined) {
        byTid.set(tid, entry)
        continue
      }
      const existingTs: number = readNumber((existing as Record<string, Object>)['ts'], 0)
      if (ts >= existingTs) {
        byTid.set(tid, entry)
      }
    }
  }
  const merged: Object[] = []
  byTid.forEach((value: Object): void => {
    merged.push(value)
  })
  merged.sort((a: Object, b: Object): number => {
    return readNumber((b as Record<string, Object>)['ts'], 0) -
      readNumber((a as Record<string, Object>)['ts'], 0)
  })
  const limited: Object[] = merged.length > HISTORY_MAX_COUNT ? merged.slice(0, HISTORY_MAX_COUNT) : merged
  result.ok = true
  result.payload = limited
  result.items = limited.length
  return result
}

/**
 * reading_progress 域：多份条目合并去重（按 tid 取 ts 较新），截断上限。
 *
 * @param values - 旧值
 * @returns 转换结果
 */
function convertReadingProgress(values: LegacyValue[]): MigrationConvertResult {
  const result: MigrationConvertResult = new MigrationConvertResult()
  const byTid: Map<string, Object> = new Map<string, Object>()
  for (let i: number = 0; i < values.length; i++) {
    const list: Object[] = asObjectArray(values[i].value)
    for (let j: number = 0; j < list.length; j++) {
      const entry: Record<string, Object> | null = asRecord(list[j])
      if (entry === null) {
        continue
      }
      const tid: string = readString(entry['tid'])
      if (tid.length === 0) {
        continue
      }
      const ts: number = readNumber(entry['ts'], 0)
      const existing: Object | undefined = byTid.get(tid)
      if (existing === undefined ||
        ts >= readNumber((existing as Record<string, Object>)['ts'], 0)) {
        byTid.set(tid, entry)
      }
    }
  }
  const merged: Object[] = []
  byTid.forEach((value: Object): void => {
    merged.push(value)
  })
  merged.sort((a: Object, b: Object): number => {
    return readNumber((b as Record<string, Object>)['ts'], 0) -
      readNumber((a as Record<string, Object>)['ts'], 0)
  })
  const limited: Object[] = merged.length > PROGRESS_MAX_COUNT ?
    merged.slice(0, PROGRESS_MAX_COUNT) : merged
  result.ok = true
  result.payload = limited
  result.items = limited.length
  return result
}

/**
 * votes 域：多份 `Record<tid, {upPids, downPids, ts}>` 合并（冲突取 ts 较新），截断上限。
 *
 * @param values - 旧值
 * @returns 转换结果
 */
function convertVotes(values: LegacyValue[]): MigrationConvertResult {
  const result: MigrationConvertResult = new MigrationConvertResult()
  const merged: Record<string, Object> = {}
  const timestamps: Record<string, number> = {}
  for (let i: number = 0; i < values.length; i++) {
    const record: Record<string, Object> | null = asRecord(values[i].value)
    if (record === null) {
      continue
    }
    const keys: string[] = Object.keys(record)
    for (let j: number = 0; j < keys.length; j++) {
      const tid: string = keys[j]
      const entry: Record<string, Object> | null = asRecord(record[tid])
      if (entry === null) {
        continue
      }
      const ts: number = readNumber(entry['ts'], 0)
      const existingTs: number = timestamps[tid] !== undefined ? timestamps[tid] : -1
      if (ts >= existingTs) {
        merged[tid] = entry
        timestamps[tid] = ts
      }
    }
  }
  const mergedKeys: string[] = Object.keys(merged)
  if (mergedKeys.length > VOTE_MAX_ENTRIES) {
    mergedKeys.sort((a: string, b: string): number => {
      const tsA: number = timestamps[a] !== undefined ? timestamps[a] : 0
      const tsB: number = timestamps[b] !== undefined ? timestamps[b] : 0
      return tsA - tsB
    })
    // ArkTS 不支持 delete 对象属性（对象布局编译期固定），按"保留较新条目"重建对象
    const kept: Record<string, Object> = {}
    const start: number = mergedKeys.length - VOTE_MAX_ENTRIES
    for (let i: number = start; i < mergedKeys.length; i++) {
      kept[mergedKeys[i]] = merged[mergedKeys[i]]
    }
    result.ok = true
    result.payload = kept
    result.items = Object.keys(kept).length
    return result
  }
  result.ok = true
  result.payload = merged
  result.items = mergedKeys.length
  return result
}

/**
 * poll_voted 域：多份 `Record<tid, ts>` 合并取较大时间戳，截断上限。
 *
 * @param values - 旧值
 * @returns 转换结果
 */
function convertPollVoted(values: LegacyValue[]): MigrationConvertResult {
  const result: MigrationConvertResult = new MigrationConvertResult()
  const merged: Record<string, number> = {}
  for (let i: number = 0; i < values.length; i++) {
    const record: Record<string, Object> | null = asRecord(values[i].value)
    if (record === null) {
      continue
    }
    const keys: string[] = Object.keys(record)
    for (let j: number = 0; j < keys.length; j++) {
      const tid: string = keys[j]
      const ts: number = readNumber(record[tid], 0)
      const existing: number = merged[tid] !== undefined ? merged[tid] : -1
      if (ts >= existing) {
        merged[tid] = ts
      }
    }
  }
  const mergedKeys: string[] = Object.keys(merged)
  if (mergedKeys.length > VOTE_MAX_ENTRIES) {
    mergedKeys.sort((a: string, b: string): number => {
      const tsA: number = merged[a] !== undefined ? merged[a] : 0
      const tsB: number = merged[b] !== undefined ? merged[b] : 0
      return tsA - tsB
    })
    // 同上：重建保留较新条目的对象（ArkTS 无 delete）
    const kept: Record<string, number> = {}
    const start: number = mergedKeys.length - VOTE_MAX_ENTRIES
    for (let i: number = start; i < mergedKeys.length; i++) {
      kept[mergedKeys[i]] = merged[mergedKeys[i]]
    }
    result.ok = true
    result.payload = kept
    result.items = Object.keys(kept).length
    return result
  }
  result.ok = true
  result.payload = merged
  result.items = mergedKeys.length
  return result
}

/**
 * ai_sessions 域：旧信封 items → `{items}`，并**清空每条会话的 ownerUid 字段**。
 *
 * 为什么清空：`AiSession.ownerUid` 是旧版按账号隔离的产物；取消隔离后会话是设备级数据，
 * 保留旧 owner 会让 `AiSessionStore` 的归属校验把迁移过来的数据整体判为非法而丢弃。
 *
 * @param values - 旧值
 * @param ctx - 上下文
 * @returns 转换结果
 */
function convertAiSessions(values: LegacyValue[], ctx: MigrationContext): MigrationConvertResult {
  const base: MigrationConvertResult = convertMirrorEnvelope(values, ctx, 'id', MAX_AI_SESSIONS)
  if (!base.ok) {
    return base
  }
  const payload: Record<string, Object> = base.payload as Record<string, Object>
  const rawItems: Object | undefined = payload['items']
  if (rawItems !== undefined && rawItems !== null && Array.isArray(rawItems)) {
    const items: Object[] = rawItems as Object[]
    for (let i: number = 0; i < items.length; i++) {
      const entry: Record<string, Object> | null = asRecord(items[i])
      if (entry !== null) {
        entry['ownerUid'] = ''
      }
    }
  }
  return base
}

/**
 * 明确丢弃（缓存类）。
 *
 * @param reason - 丢弃原因
 * @returns 转换结果
 */
function convertDropped(reason: string): MigrationConvertResult {
  const result: MigrationConvertResult = new MigrationConvertResult()
  result.skippedReason = reason
  return result
}

/**
 * 判断对象是否为普通对象（非数组、非 null）。
 *
 * @param value - 待判断值
 * @returns 是否为普通对象
 */
function asRecord(value: Object | undefined): Record<string, Object> | null {
  if (value === undefined || value === null || Array.isArray(value) || typeof value !== 'object') {
    return null
  }
  return value as Record<string, Object>
}

/**
 * 判断对象是否为对象数组。
 *
 * @param value - 待判断值
 * @returns 对象数组（非数组时返回空数组）
 */
function asObjectArray(value: Object): Object[] {
  if (value === null || value === undefined || !Array.isArray(value)) {
    return []
  }
  return value as Object[]
}

/**
 * 防御性读取字符串。
 *
 * @param value - 原始值
 * @returns 字符串
 */
function readString(value: Object | undefined): string {
  return typeof value === 'string' ? value as string : ''
}

/**
 * 防御性读取数值。
 *
 * @param value - 原始值
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
 * 生成一个"迁移完成"的单域结果。
 *
 * @param domainId - 域 ID
 * @param items - 条目数
 * @returns 结果
 */
export function migratedResult(domainId: string, items: number): MigrationDomainResult {
  return new MigrationDomainResult(domainId, MigrationDomainStatus.MIGRATED, items, '')
}

/**
 * 生成一个"跳过"的单域结果。
 *
 * @param domainId - 域 ID
 * @param reason - 跳过原因
 * @returns 结果
 */
export function skippedResult(domainId: string, reason: string): MigrationDomainResult {
  return new MigrationDomainResult(domainId, MigrationDomainStatus.SKIPPED, 0, reason)
}

/**
 * 生成一个"失败"的单域结果。
 *
 * @param domainId - 域 ID
 * @param error - 失败原因
 * @returns 结果
 */
export function failedResult(domainId: string, error: string): MigrationDomainResult {
  return new MigrationDomainResult(domainId, MigrationDomainStatus.FAILED, 0, error)
}

/**
 * 生成空迁移报告（未开始时的初始值）。
 *
 * @returns 报告
 */
export function emptyReport(): MigrationReport {
  return new MigrationReport()
}

/**
 * 返回某域是否为账号镜像（迁移时写入 ownerUid）。
 *
 * @param domainId - 域 ID
 * @returns 是否为镜像域
 */
export function isMirrorDomain(domainId: string): boolean {
  const spec: DomainSpec | null = PersistenceCatalog.byId(domainId)
  return spec !== null && spec.scope === DomainScope.ACCOUNT_MIRROR
}

/**
 * 返回某域是否为文件域。
 *
 * @param domainId - 域 ID
 * @returns 是否为文件域
 */
export function isFileDomain(domainId: string): boolean {
  const spec: DomainSpec | null = PersistenceCatalog.byId(domainId)
  return spec !== null && spec.storage === StorageKind.JSON_FILES
}
