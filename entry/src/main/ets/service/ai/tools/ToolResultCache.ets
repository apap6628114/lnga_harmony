/**
 * 工具结果时效性缓存。
 *
 * 设计原则（四条硬线，改动前请先读）：
 * 1. **能不能缓存由行为注解决定，缓存多久由元数据决定**：写操作（`readOnly === false`）、
 *    非幂等、开放世界（`openWorld === true`）、零参数上下文工具一律不缓存；其余按
 *    元数据的 `cacheTtlMs` 取 TTL（缺省短 TTL）。两者必须分开——只给写操作配 TTL
 *    而没有 readOnly 判定，就会把副作用结果缓存下来。
 * 2. **只缓存成功且非空的结果**：失败结果与空正文都不进缓存——缓存一次失败会让后续
 *    整个 TTL 内都拿不到真实数据。
 *
 *    关于「截断」：工具输出里的截断（如 `max_chars` 截掉剩余楼层）是**参数语义的一部分**，
 *    而参数已全部进入缓存键，因此同一个键下的内容就是该参数组合下的完整输出，缓存它是
 *    正确的——不存在「把两次不同参数的结果混淆」的风险。真正需要禁止的是「取数失败但
 *    有半截正文」这类结果，它们由 {@link ToolResultCache.set} 的 success 判定拦掉。
 * 3. **按账号隔离**：缓存键含 uid。未登录工具（联网搜索）用 anon 桶，切换账号不会串味。
 * 4. **键必须含上下文指纹**：工具允许参数缺省并回退到页面上下文（`nga_read_thread`
 *    省略 tid 即读当前帖、`nga_list_topics` 省略 fid 即读当前版块），所以
 *    `tool|uid|args` 不足以唯一标识一次取数——从 A 帖问完切到 B 帖会命中 A 帖的正文，
 *    属于静默错误答案。键固定为 `tool|uid|指纹|规范化参数`，指纹由 ToolRegistry 从
 *    taskContext 生成。
 *
 * 当前工具目录里**没有写操作工具**（全部 readOnly），因此暂不需要「写后失效」；
 * 将来开放写工具时，必须在写成功的分支里调用 {@link ToolResultCache.invalidateAll}
 * 或按 uid 失效，否则用户会读到写之前的快照。
 */

import {
  AI_TOOL_CACHE_TTL_LONG,
  AI_TOOL_CACHE_TTL_SHORT,
  AiToolCategory,
  findAiToolMeta
} from '../../../model/AiToolConfig'
import { AiToolResult } from './AiToolAdapter'

/** 长 TTL 别名：值来自工具元数据层，这里只保留名字给既有调用方与测试用。 */
export const LONG_TTL_MS: number = AI_TOOL_CACHE_TTL_LONG
/** 短 TTL 别名。 */
export const SHORT_TTL_MS: number = AI_TOOL_CACHE_TTL_SHORT

/** 取数新鲜度参数名。 */
export const FRESHNESS_ARG: string = 'freshness'
/** 默认：可用缓存，未命中则取数并写缓存。 */
export const FRESHNESS_AUTO: string = 'auto'
/** 强制取最新：跳过缓存读，取数后刷新缓存。 */
export const FRESHNESS_FRESH: string = 'fresh'
/** 完全不使用缓存：跳过读写。 */
export const FRESHNESS_NO_CACHE: string = 'no_cache'

/** 未登录时的缓存桶名。 */
const ANON_BUCKET: string = 'anon'

/** 内存缓存默认总字符上限：约 8M 字符（UTF-16 下约 16MB）。 */
export const DEFAULT_MAX_TOTAL_CHARS: number = 8000000

/**
 * 按工具名派生缓存 TTL。
 *
 * 判定顺序：先看**能不能缓存**（写操作 / 非幂等 / 开放世界 / 上下文工具一律不缓存），
 * 再看**缓存多久**（元数据里显式标注的 `cacheTtlMs` 优先，缺省按短 TTL）。
 *
 * 这个顺序不能反：`cacheTtlMs` 只回答「多久内重取没意义」，
 * 「能不能缓存」必须由行为注解决定，否则给写操作配上 TTL 就会缓存副作用结果。
 *
 * @param name - 工具名
 * @returns TTL 毫秒；返回 0 表示该工具不缓存
 */
export function toolCacheTtlMs(name: string): number {
  const meta = findAiToolMeta(name)
  if (meta === null) {
    return 0
  }
  if (meta.readOnly === false) {
    return 0
  }
  if (meta.idempotent === false) {
    return 0
  }
  if (meta.openWorld === true) {
    return 0
  }
  if (meta.category === AiToolCategory.CONTEXT) {
    // 零参数、不发起网络请求：缓存没有收益，只会拖长「已可用工具清单」的滞后
    return 0
  }
  if (typeof meta.cacheTtlMs === 'number') {
    // 显式声明优先，且 0 表示「本工具不再叠加缓存」
    return meta.cacheTtlMs > 0 ? meta.cacheTtlMs : 0
  }
  return AI_TOOL_CACHE_TTL_SHORT
}

/**
 * 缓存查询结果：一次解析同时给出键与新鲜度意图。
 */
export class ToolCacheQuery {
  /** 缓存键（不会被缓存时为空串） */
  key: string = ''
  /** 新鲜度意图（FRESHNESS_*） */
  freshness: string = FRESHNESS_AUTO
}

/**
 * 构造缓存键并解析新鲜度意图。
 *
 * 规范化只做两件事：**建键排序**与**剔除 freshness**。这里**刻意不补齐缺省值**——
 * 缺省值由各工具自己回退到页面上下文（例如 `nga_read_thread` 省略 tid 就读当前帖），
 * 所以 `{page:1}` 与 `{}` 是两个含义不同的输入，必须算成两个键。补默认值反而会把
 * "读第 1 页"和"读当前页"折叠到一起，制造错数据。
 *
 * 缺省输入的正确性由三件事保证，而不是靠把参数填满：
 * 1. 键里的**上下文指纹**（不同帖子 / 用户 / 版块 → 不同键）；
 * 2. 参数完全为空时，把 **fallbackQuery 的哈希**并入键——搜索类工具在模型漏传查询词时
 *    会拿"最后一条用户消息"兜底取数，而这个兜底源不在上下文指纹里。同一页面下两个
 *    不同问题都漏传查询词时，若不并入哈希就会互相命中，返回上一个问题的搜索结果；
 * 3. 参数无法解析为 JSON 对象时返回空键（本方法直接拒绝缓存）。
 *
 * @param toolName - 工具名
 * @param uid - 当前账号 UID（未登录传空串）
 * @param argumentsText - 模型生成的参数 JSON
 * @param contextFingerprint - 页面上下文指纹（tid / pid / uid / fid）
 * @param fallbackQuery - 兜底查询（最后一条用户消息；仅参数为空时参与拼键）
 * @returns 查询结果；key 为空串表示本次不可缓存
 */
export function buildCacheQuery(toolName: string, uid: string, argumentsText: string,
  contextFingerprint: string = '', fallbackQuery: string = ''): ToolCacheQuery {
  const query: ToolCacheQuery = new ToolCacheQuery()
  query.freshness = readFreshnessFromText(argumentsText)
  if (!isParsableArguments(argumentsText)) {
    query.key = ''
    return query
  }
  const normalized: string = normalizeToolArguments(argumentsText)
  const bucket: string = uid.length > 0 ? uid : ANON_BUCKET
  // 只有"完全没给参数"时才依赖 fallbackQuery 兜底；有参数的调用不受它影响，
  // 放入哈希会白白拉低命中率（同一帖子连续追问时问题文本每次都不同）。
  // 注意判空要看**参数对象是否为空**，不能看规范化字符串：`{}` 规范化后是 "{}" 而非空串。
  const implicit: string = hasNoArguments(argumentsText) && fallbackQuery.length > 0
    ? '|q:' + hashString(fallbackQuery) : ''
  query.key = toolName + '|' + bucket + '|' + contextFingerprint + implicit + '|' + normalized
  return query
}

/**
 * 判断参数里是否没有任何业务字段（空对象、或只剩 freshness）。
 *
 * @param argumentsText - 参数 JSON
 * @returns true 表示完全依赖上下文回退
 */
function hasNoArguments(argumentsText: string): boolean {
  const text: string = argumentsText.trim()
  if (text.length === 0) {
    return true
  }
  let parsed: Object | null = null
  try {
    parsed = JSON.parse(text) as Object
  } catch (e) {
    return false
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return false
  }
  const record: Record<string, Object> = parsed as Record<string, Object>
  const keys: string[] = Object.keys(record)
  for (let i: number = 0; i < keys.length; i++) {
    if (keys[i] !== FRESHNESS_ARG) {
      return false
    }
  }
  return true
}

/**
 * 32 位 FNV-1a 哈希（十六进制字符串）。
 *
 * 只用于把兜底查询词压成定长片段参与拼键，不承担安全职责；
 * 用位运算实现是为了避免大数乘法在 ArkTS 下的精度问题。
 *
 * @param text - 原文
 * @returns 十六进制哈希
 */
function hashString(text: string): string {
  let hash: number = 0x811c9dc5
  for (let i: number = 0; i < text.length; i++) {
    hash = hash ^ text.charCodeAt(i)
    // hash *= 16777619（用移位加法等价实现，并保持 32 位无符号）
    hash = hash + (hash << 1) + (hash << 4) + (hash << 7) + (hash << 8) + (hash << 24)
    hash = hash >>> 0
  }
  return hash.toString(16)
}

/**
 * 判断参数文本能否解析为 JSON 对象（空串视为合法的「无参数」）。
 *
 * @param argumentsText - 参数 JSON
 * @returns true 表示可以安全地作为缓存键来源
 */
function isParsableArguments(argumentsText: string): boolean {
  const text: string = argumentsText.trim()
  if (text.length === 0) {
    return true
  }
  let parsed: Object | null = null
  try {
    parsed = JSON.parse(text) as Object
  } catch (e) {
    return false
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return false
  }
  return true
}

/**
 * 把参数 JSON 规范化为稳定的字符串（键排序、剔除 freshness）。
 *
 * 解析失败时退回原文——宁可少命中，也不要把不同参数折叠成同一个键。
 *
 * @param argumentsText - 参数 JSON
 * @returns 规范化字符串
 */
export function normalizeToolArguments(argumentsText: string): string {
  const text: string = argumentsText.trim()
  if (text.length === 0) {
    return ''
  }
  let parsed: Object;
  try {
    parsed = JSON.parse(text) as Object
  } catch (e) {
    return text
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return text
  }
  const record: Record<string, Object> = parsed as Record<string, Object>
  const keys: string[] = Object.keys(record).sort()
  // 用 JSON.stringify 而不是 "k=v&k2=v2"：后者没有转义，值里含 & 或 = 时会伪造出
  // 与另一个参数组合相同的键（{"key":"x&page=2"} 与 {"key":"x","page":"2"} 同键）
  const ordered: Record<string, string> = {}
  for (let i: number = 0; i < keys.length; i++) {
    const key: string = keys[i]
    if (key === FRESHNESS_ARG) {
      continue
    }
    ordered[key] = stableValue(record[key])
  }
  return JSON.stringify(ordered)
}

/**
 * 把任意 JSON 值压成稳定字符串（数组按顺序展开，对象递归排序）。
 *
 * @param value - 值
 * @returns 稳定字符串
 */
function stableValue(value: Object | undefined): string {
  if (value === null || value === undefined) {
    return ''
  }
  if (typeof value === 'string') {
    return value as string
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return String(value)
  }
  if (Array.isArray(value)) {
    const items: Object[] = value as Object[]
    const parts: string[] = []
    for (let i: number = 0; i < items.length; i++) {
      parts.push(stableValue(items[i]))
    }
    return '[' + parts.join(',') + ']'
  }
  const record: Record<string, Object> = value as Record<string, Object>
  const keys: string[] = Object.keys(record).sort()
  const parts: string[] = []
  for (let i: number = 0; i < keys.length; i++) {
    parts.push(keys[i] + ':' + stableValue(record[keys[i]]))
  }
  return '{' + parts.join(',') + '}'
}

/**
 * 从参数 JSON 读取新鲜度意图（容错：非法值一律按默认处理）。
 *
 * @param argumentsText - 参数 JSON
 * @returns FRESHNESS_* 之一
 */
export function readFreshnessFromText(argumentsText: string): string {
  if (argumentsText.trim().length === 0) {
    return FRESHNESS_AUTO
  }
  let parsed: Object;
  try {
    parsed = JSON.parse(argumentsText) as Object
  } catch (e) {
    return FRESHNESS_AUTO
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return FRESHNESS_AUTO
  }
  const raw: Object | undefined = (parsed as Record<string, Object>)[FRESHNESS_ARG]
  if (typeof raw !== 'string') {
    return FRESHNESS_AUTO
  }
  const text: string = (raw as string).trim().toLowerCase()
  if (text === FRESHNESS_FRESH || text === FRESHNESS_NO_CACHE) {
    return text
  }
  return FRESHNESS_AUTO
}

/** 缓存条目。 */
class ToolCacheEntry {
  /** 缓存的结果副本 */
  result: AiToolResult = new AiToolResult()
  /** 过期时间戳 */
  expiresAt: number = 0
}

/**
 * 可持久化的缓存快照条目。
 *
 * 只包含「键 + 过期时间 + 结果」，不含 LRU 顺序：恢复顺序无关紧要，
 * 过期时间才是唯一有意义的跨进程信息。
 */
export class ToolCacheSnapshot {
  /** 缓存键（已含工具名 / uid 桶 / 上下文指纹 / 规范化参数） */
  key: string = ''
  /** 过期时间戳（毫秒） */
  expiresAt: number = 0
  /** 缓存的工具结果 */
  result: AiToolResult = new AiToolResult()
}

/**
 * 工具结果 LRU 缓存。
 *
 * 容量与时钟都可注入：单测用假时钟验证过期，不依赖真实 sleep。
 */
export class ToolResultCache {
  /** 键 -> 条目 */
  private map: Map<string, ToolCacheEntry> = new Map()
  /** LRU 顺序（队尾最新） */
  private order: string[] = []
  /** 容量上限 */
  private maxSize: number
  /** 总字符上限（防止 200 条长帖正文把内存撑爆） */
  private maxTotalChars: number
  /** 当前总字符数 */
  private totalChars: number = 0
  /** 时间源（可注入，单测用） */
  private clock: () => number
  /** 命中次数（诊断用） */
  private hits: number = 0
  /** 未命中次数（诊断用） */
  private misses: number = 0
  /** 内容变化回调（持久化层据此标脏；null 表示不持久化） */
  private changeListener: (() => void) | null = null

  /**
   * 注册内容变化回调（由持久化层注入）。
   *
   * 缓存实现不直接依赖 Preferences / Store：它是纯内存结构，单测可以用假时钟
   * 直接构造；持久化只是可选的旁路。
   *
   * @param listener - 变化回调；传 null 取消注册
   */
  setChangeListener(listener: (() => void) | null): void {
    this.changeListener = listener
  }

  /**
   * 构造缓存。
   *
   * @param maxSize - 条目上限（超出时淘汰最久未使用）
   * @param clock - 时间源；缺省用 Date.now
   * @param maxTotalChars - 总字符上限（缺省 8M；防止长帖正文把内存撑爆）
   */
  constructor(maxSize: number = 200, clock?: () => number,
    maxTotalChars: number = DEFAULT_MAX_TOTAL_CHARS) {
    this.maxSize = maxSize
    this.clock = clock !== undefined ? clock : defaultClock
    this.maxTotalChars = maxTotalChars > 0 ? maxTotalChars : DEFAULT_MAX_TOTAL_CHARS
  }

  /**
   * 读取缓存（命中时返回副本，调用方修改不会污染缓存）。
   *
   * @param key - 缓存键
   * @returns 结果副本；未命中或已过期返回 null
   */
  get(key: string): AiToolResult | null {
    const entry: ToolCacheEntry | undefined = this.map.get(key)
    if (entry === undefined) {
      this.misses++
      return null
    }
    if (this.clock() >= entry.expiresAt) {
      this.map.delete(key)
      this.totalChars -= entry.result.content.length
      if (this.totalChars < 0) {
        this.totalChars = 0
      }
      this.removeFromOrder(key)
      this.misses++
      return null
    }
    this.touch(key)
    this.hits++
    const copy: AiToolResult = cloneToolResult(entry.result)
    copy.fromCache = true
    return copy
  }

  /**
   * 写入缓存。
   *
   * 失败结果与空内容不写入：缓存一次失败会让后续 10 分钟都拿不到真实数据。
   *
   * @param key - 缓存键
   * @param result - 工具结果
   * @param ttlMs - 存活时长（<=0 时忽略）
   */
  set(key: string, result: AiToolResult, ttlMs: number): void {
    if (ttlMs <= 0 || !result.success || result.content.length === 0) {
      return
    }
    const entry: ToolCacheEntry = new ToolCacheEntry()
    entry.result = cloneToolResult(result)
    entry.result.fromCache = false
    entry.expiresAt = this.clock() + ttlMs
    const existing: ToolCacheEntry | undefined = this.map.get(key)
    if (existing !== undefined) {
      this.totalChars -= existing.result.content.length
    }
    if (!this.map.has(key)) {
      this.order.push(key)
    } else {
      this.touch(key)
    }
    this.map.set(key, entry)
    this.totalChars += entry.result.content.length
    if (this.totalChars < 0) {
      this.totalChars = 0
    }
    this.evictIfNeeded()
    this.notifyChanged()
  }

  /**
   * 导出未过期条目的快照（供持久化）。
   *
   * 不导出已过期条目：它们对下一次启动没有价值，只会让文件变大。
   *
   * @returns 快照数组
   */
  snapshot(): ToolCacheSnapshot[] {
    const now: number = this.clock()
    const result: ToolCacheSnapshot[] = []
    for (let i: number = 0; i < this.order.length; i++) {
      const key: string = this.order[i]
      const entry: ToolCacheEntry | undefined = this.map.get(key)
      if (entry === undefined || entry.expiresAt <= now) {
        continue
      }
      const item: ToolCacheSnapshot = new ToolCacheSnapshot()
      item.key = key
      item.expiresAt = entry.expiresAt
      item.result = cloneToolResult(entry.result)
      result.push(item)
    }
    return result
  }

  /**
   * 从持久化快照恢复缓存。
   *
   * 只恢复未过期且内容非空的条目；已过期的直接丢弃（同一份 TTL 语义，
   * 不因为"刚启动"就延长生命周期）。
   *
   * @param snapshots - 快照数组
   * @returns 实际恢复的条目数
   */
  hydrate(snapshots: ToolCacheSnapshot[]): number {
    /*
     * 合并而不是清空：`init` 会先 invalidateAll 再 load，但 load 期间工具可能
     * 已经写入了新结果；直接 clear 会把刚取到的数据丢掉。已存在的键保留内存
     * 里的新值，只补缺失的条目。
     */
    let restored: number = 0
    const now: number = this.clock()
    for (let i: number = 0; i < snapshots.length; i++) {
      const item: ToolCacheSnapshot = snapshots[i]
      if (item.key.length === 0 || !isFinite(item.expiresAt) || item.expiresAt <= now ||
        item.result.content.length === 0 || !item.result.success) {
        continue
      }
      if (this.map.has(item.key)) {
        continue
      }
      const entry: ToolCacheEntry = new ToolCacheEntry()
      entry.result = cloneToolResult(item.result)
      entry.result.fromCache = false
      entry.expiresAt = item.expiresAt
      this.map.set(item.key, entry)
      this.order.push(item.key)
      this.totalChars += entry.result.content.length
      restored++
    }
    // 恢复后仍按容量上限收敛，避免旧文件把内存撑大
    this.evictIfNeeded()
    return restored
  }

  /**
   * 清空全部缓存（账号切换 / 结构变更时调用）。
   */
  invalidateAll(): void {
    this.map.clear()
    this.order = []
    this.totalChars = 0
    this.notifyChanged()
  }

  /**
   * 只清空某个账号的缓存（键里含 uid 桶名）。
   *
   * @param uid - 账号 UID；传空串等价于清 anon 桶
   */
  invalidateUser(uid: string): void {
    const bucket: string = uid.length > 0 ? uid : ANON_BUCKET
    const marker: string = '|' + bucket + '|'
    const remaining: string[] = []
    for (let i: number = 0; i < this.order.length; i++) {
      const key: string = this.order[i]
      if (key.indexOf(marker) >= 0) {
        const entry: ToolCacheEntry | undefined = this.map.get(key)
        if (entry !== undefined) {
          this.totalChars -= entry.result.content.length
        }
        this.map.delete(key)
        continue
      }
      remaining.push(key)
    }
    if (this.totalChars < 0) {
      this.totalChars = 0
    }
    this.order = remaining
    this.notifyChanged()
  }

  /**
   * 当前条目数。
   *
   * @returns 条目数
   */
  get size(): number {
    return this.map.size
  }

  /**
   * 命中统计（命中数 / 未命中数），供日志与诊断输出。
   *
   * @returns [命中数, 未命中数]
   */
  getStats(): number[] {
    return [this.hits, this.misses]
  }

  /**
   * 按容量上限淘汰最久未使用的条目。
   */
  private evictIfNeeded(): void {
    while (this.order.length > this.maxSize || this.totalChars > this.maxTotalChars) {
      /*
       * 至少保留最新一条：单条结果本身超过字符上限时（超大读帖 / 网页），
       * 继续淘汰会把刚写入的条目立刻删掉，缓存等于没有。
       */
      if (this.order.length <= 1) {
        break
      }
      const oldest: string | undefined = this.order.shift()
      if (oldest === undefined) {
        break
      }
      const entry: ToolCacheEntry | undefined = this.map.get(oldest)
      if (entry !== undefined) {
        this.totalChars -= entry.result.content.length
      }
      this.map.delete(oldest)
    }
    if (this.totalChars < 0) {
      this.totalChars = 0
    }
  }

  /**
   * 通知持久化层内容已变化。
   */
  private notifyChanged(): void {
    if (this.changeListener !== null) {
      this.changeListener()
    }
  }

  /**
   * 把键移到 LRU 队尾。
   *
   * @param key - 缓存键
   */
  private touch(key: string): void {
    this.removeFromOrder(key)
    this.order.push(key)
  }

  /**
   * 从 LRU 顺序里移除键。
   *
   * @param key - 缓存键
   */
  private removeFromOrder(key: string): void {
    const idx: number = this.order.indexOf(key)
    if (idx >= 0) {
      this.order.splice(idx, 1)
    }
  }
}

/**
 * 默认时间源。
 *
 * @returns 当前时间戳
 */
function defaultClock(): number {
  return Date.now()
}

/**
 * 复制工具结果（数组做浅拷贝，元素本身不被修改）。
 *
 * @param src - 原结果
 * @returns 副本
 */
export function cloneToolResult(src: AiToolResult): AiToolResult {
  const dest: AiToolResult = new AiToolResult()
  dest.success = src.success
  dest.content = src.content
  dest.summary = src.summary
  dest.count = src.count
  dest.errorMessage = src.errorMessage
  dest.errorCode = src.errorCode
  dest.sources = src.sources.slice()
  dest.cards = src.cards.slice()
  dest.fromCache = src.fromCache
  return dest
}

/** 全局工具结果缓存。 */
export const aiToolResultCache: ToolResultCache = new ToolResultCache()
