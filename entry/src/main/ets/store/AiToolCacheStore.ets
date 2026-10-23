/**
 * 工具结果缓存的持久化层。
 *
 * ## 为什么缓存也要落盘
 *
 * `ToolResultCache` 原本是纯内存 LRU：进程一退，上一轮读过的帖子、用户资料、
 * 搜索结果全部消失。用户第二天打开同一个帖子追问，模型会**重新**读一遍同样的页面——
 * 既慢，又白白多一次论坛请求（还可能撞上风控）。
 *
 * 持久化后，同一账号在 TTL 内重进对话可以直接命中本地结果，模型拿到的内容不变，
 * 但首字延迟和上游压力都降下来了。
 *
 * ## 边界
 *
 * - **只持久化成功且未过期的条目**：失败 / 空结果不落盘（同内存缓存语义）；
 * - **按账号隔离**：键 `ai_tool_cache_<uid>`，信封带 schemaVersion 与 uid 校验；
 * - **容量与体积双上限**：最多 80 条 / 约 1.2M 字符，超出按"最旧优先"丢弃；
 * - **未登录不落盘**：anon 桶只活在内存，避免把未归属的数据写到磁盘；
 * - **写盘节流**：每次工具执行后只标脏，800ms 合并写一次，不阻塞 Agent 循环。
 */

import { BaseStore } from './BaseStore'
import { CacheEnvelopeStore } from '../common/infra/CacheEnvelopeStore'
import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { Logger, DOMAIN_STORE, formatError } from '../common/utils/Logger'
import { AiToolCard, AiToolResult, AiToolSource } from '../service/ai/tools/AiToolAdapter'
import {
  ToolCacheSnapshot,
  aiToolResultCache
} from '../service/ai/tools/ToolResultCache'
import { bindToolCacheAccount } from '../service/ai/tools/ToolRegistry'
import type { AuthState } from './AuthStore'

/** 缓存信封结构版本。 */
const TOOL_CACHE_SCHEMA_VERSION: number = 1

/** 缓存键前缀（最终键形如 `ai_tool_cache_<uid>`）。 */
const TOOL_CACHE_KEY_PREFIX: string = 'ai_tool_cache'

/** 最多持久化的条目数。 */
const MAX_PERSISTED_ENTRIES: number = 80

/** 最多持久化的正文字符数（约 1.2MB）。 */
const MAX_PERSISTED_CHARS: number = 1200000

/** 写盘节流延迟（毫秒）。 */
const SAVE_DELAY_MS: number = 800

const logger: Logger = new Logger(DOMAIN_STORE, 'AiToolCacheStore')

/**
 * 工具结果缓存 Store。
 */
export class AiToolCacheStore extends BaseStore<Object> {
  /** BaseStore 状态占位对象（缓存不走 @Observed 状态）。 */
  override state: Object = new Object()

  /** 按账号隔离的信封工具。 */
  private envelope: CacheEnvelopeStore<ToolCacheSnapshot> =
    new CacheEnvelopeStore<ToolCacheSnapshot>(
      TOOL_CACHE_SCHEMA_VERSION,
      TOOL_CACHE_KEY_PREFIX,
      (value: Object): boolean => isValidSnapshot(value)
    )

  /** 写盘节流定时器。 */
  private saveTimer: number = -1

  /**
   * 注入依赖并恢复当前账号的缓存。
   *
   * 先清空内存缓存再加载：`init` 会在账号切换 / 重新登录时再次调用，
   * 不先清会让上一个账号的结果参与当前账号的命中。
   *
   * @param store - 偏好存储
   * @param queue - 串行写队列
   * @param auth - 当前认证状态
   */
  async init(store: PreferencesStore, queue: SerialQueue, auth: AuthState): Promise<void> {
    this.setDeps(store, queue, auth)
    this.cancelScheduledSave()
    aiToolResultCache.setChangeListener(null)
    aiToolResultCache.invalidateAll()
    aiToolResultCache.setChangeListener((): void => {
      this.scheduleSave()
    })
    const uid: string = auth.uid
    if (!uid) {
      bindToolCacheAccount('')
      return
    }
    const generation: number = this.generationGuard.current()
    await this.load(uid)
    /*
     * 加载期间账号可能已经切换 / 登出：把 A 的缓存 hydrate 后再 bind 成 B，
     * 会让 B 命中 A 的帖子 / 资料。代际与 uid 任一不一致都整体丢弃。
     */
    if (!this.isCurrent(generation) || this.auth.uid !== uid) {
      aiToolResultCache.invalidateAll()
      bindToolCacheAccount('')
      return
    }
    bindToolCacheAccount(uid)
  }

  /**
   * 清空内存缓存并停止持久化回调（登出 / 切号）。
   *
   * 磁盘记录保留：重新登录同一账号时还能命中上次的结果（受 TTL 约束）。
   */
  reset(): void {
    this.cancelScheduledSave()
    aiToolResultCache.setChangeListener(null)
    aiToolResultCache.invalidateAll()
    bindToolCacheAccount('')
    super.reset()
  }

  /**
   * 立即落盘（页面退出 / 应用后台时调用）。
   */
  flush(): void {
    this.cancelScheduledSave()
    this.save()
  }

  /**
   * 从磁盘恢复当前账号的缓存。
   *
   * @param uid - 当前账号
   */
  private async load(uid: string): Promise<void> {
    try {
      const items: ToolCacheSnapshot[] | null = await this.envelope.loadTolerant(this.store, uid)
      if (items === null || items.length === 0) {
        return
      }
      const normalized: ToolCacheSnapshot[] = []
      const marker: string = '|' + uid + '|'
      for (let i: number = 0; i < items.length; i++) {
        const item: ToolCacheSnapshot = normalizeSnapshot(items[i])
        /* 只恢复当前账号桶的键：防止历史错误写入的跨账号条目占内存 / 命中 */
        if (item.key.indexOf(marker) >= 0 && item.key.length > 0 &&
          item.result.content.length > 0 && item.result.success) {
          normalized.push(item)
        }
      }
      const restored: number = aiToolResultCache.hydrate(normalized)
      logger.info('restored %{public}d tool cache entries', restored)
    } catch (e) {
      logger.warn('restore tool cache failed: %{public}s', formatError(e))
    }
  }

  /**
   * 安排一次延迟写盘（合并短时间内的多次工具执行）。
   */
  private scheduleSave(): void {
    this.cancelScheduledSave()
    this.saveTimer = setTimeout((): void => {
      this.saveTimer = -1
      this.save()
    }, SAVE_DELAY_MS)
  }

  /**
   * 取消未执行的写盘。
   */
  private cancelScheduledSave(): void {
    if (this.saveTimer >= 0) {
      clearTimeout(this.saveTimer)
      this.saveTimer = -1
    }
  }

  /**
   * 把当前缓存快照写入当前账号的键。
   */
  private save(): void {
    const uid: string = this.auth ? this.auth.uid : ''
    if (uid.length === 0) {
      return
    }
    try {
      const snapshots: ToolCacheSnapshot[] = aiToolResultCache.snapshot()
      const marker: string = '|' + uid + '|'
      const own: ToolCacheSnapshot[] = []
      for (let i: number = 0; i < snapshots.length; i++) {
        if (snapshots[i].key.indexOf(marker) >= 0) {
          own.push(snapshots[i])
        }
      }
      const kept: ToolCacheSnapshot[] = limitSnapshots(own)
      this.envelope.persist(uid, kept, this.store, this.writeQueue)
    } catch (e) {
      /* 缓存持久化是旁路能力：失败只记日志，不能让工具执行 / 刷盘流程失败 */
      logger.warn('save tool cache failed: %{public}s', formatError(e))
    }
  }
}

/**
 * 按「条数 + 总体积」裁剪要持久化的快照。
 *
 * 从最新（LRU 队尾）往前取：最近用过的结果更可能再次被需要。
 *
 * @param snapshots - 全部快照（旧 → 新）
 * @returns 裁剪后的快照（旧 → 新）
 */
function limitSnapshots(snapshots: ToolCacheSnapshot[]): ToolCacheSnapshot[] {
  const kept: ToolCacheSnapshot[] = []
  let chars: number = 0
  for (let i: number = snapshots.length - 1; i >= 0; i--) {
    if (kept.length >= MAX_PERSISTED_ENTRIES) {
      break
    }
    const item: ToolCacheSnapshot = snapshots[i]
    const size: number = item.result.content.length
    if (kept.length > 0 && chars + size > MAX_PERSISTED_CHARS) {
      continue
    }
    kept.push(item)
    chars += size
  }
  kept.reverse()
  return kept
}

/**
 * 校验一条持久化快照的结构。
 *
 * @param value - 原始对象
 * @returns 是否有效
 */
function isValidSnapshot(value: Object): boolean {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return false
  }
  const record: Record<string, Object> = value as Record<string, Object>
  if (typeof record['key'] !== 'string' || (record['key'] as string).length === 0) {
    return false
  }
  if (typeof record['expiresAt'] !== 'number') {
    return false
  }
  const rawResult: Object | undefined = record['result']
  if (rawResult === undefined || rawResult === null || typeof rawResult !== 'object' ||
    Array.isArray(rawResult)) {
    return false
  }
  const result: Record<string, Object> = rawResult as Record<string, Object>
  if (typeof result['content'] !== 'string' || (result['content'] as string).length === 0) {
    return false
  }
  if (result['success'] !== true) {
    return false
  }
  return true
}

/**
 * 把磁盘上的对象逐字段重建为快照（缺字段不会带进 UI / 模型）。
 *
 * @param raw - 原始对象
 * @returns 快照
 */
function normalizeSnapshot(raw: ToolCacheSnapshot): ToolCacheSnapshot {
  const item: ToolCacheSnapshot = new ToolCacheSnapshot()
  if (raw === null || raw === undefined) {
    return item
  }
  item.key = readString(raw.key)
  item.expiresAt = readNumber(raw.expiresAt)
  const result: AiToolResult = new AiToolResult()
  const source: AiToolResult = raw.result
  if (source !== null && source !== undefined) {
    result.success = source.success === true
    result.content = readString(source.content)
    result.summary = readString(source.summary)
    result.count = readNumber(source.count)
    result.errorMessage = readString(source.errorMessage)
    result.errorCode = readString(source.errorCode)
    result.sources = source.sources !== null && source.sources !== undefined
      ? normalizeSources(source.sources as Object[]) : []
    result.cards = source.cards !== null && source.cards !== undefined
      ? normalizeCards(source.cards as Object[]) : []
  }
  item.result = result
  return item
}

/**
 * 归一化来源列表。
 *
 * @param raw - 原始来源
 * @returns 来源数组
 */
function normalizeSources(raw: Object[]): AiToolSource[] {
  const result: AiToolSource[] = []
  if (raw === null || raw === undefined || !Array.isArray(raw)) {
    return result
  }
  for (let i: number = 0; i < raw.length; i++) {
    const item: AiToolSource = raw[i] as AiToolSource
    if (item === null || item === undefined) {
      continue
    }
    const source: AiToolSource = new AiToolSource()
    source.title = readString(item.title)
    source.url = readString(item.url)
    if (source.url.length > 0) {
      result.push(source)
    }
  }
  return result
}

/**
 * 归一化卡片列表。
 *
 * @param raw - 原始卡片
 * @returns 卡片数组
 */
function normalizeCards(raw: Object[]): AiToolCard[] {
  const result: AiToolCard[] = []
  if (raw === null || raw === undefined || !Array.isArray(raw)) {
    return result
  }
  for (let i: number = 0; i < raw.length; i++) {
    const item: AiToolCard = raw[i] as AiToolCard
    if (item === null || item === undefined) {
      continue
    }
    const card: AiToolCard = new AiToolCard()
    card.kind = readString(item.kind)
    card.title = readString(item.title)
    card.subtitle = readString(item.subtitle)
    card.route = readString(item.route)
    card.params = readString(item.params)
    if (card.title.length > 0) {
      result.push(card)
    }
  }
  return result
}

/**
 * 防御性读取字符串。
 *
 * @param value - 原始值
 * @returns 字符串
 */
function readString(value: string): string {
  return typeof value === 'string' ? value : ''
}

/**
 * 防御性读取数值。
 *
 * @param value - 原始值
 * @returns 有限数值（非法时 0）
 */
function readNumber(value: number): number {
  if (typeof value !== 'number' || !isFinite(value)) {
    return 0
  }
  return value
}
