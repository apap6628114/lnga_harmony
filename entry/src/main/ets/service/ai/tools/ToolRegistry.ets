/**
 * 客户端工具注册表。
 *
 * 新增工具只需：在 `AI_TOOL_CATALOG` 登记元数据、实现 `AiToolAdapter`、
 * 在 createAiToolRegistry 注册一行。UI 与 Agent 循环都从注册表取，
 * 不再有任何按工具名写死的分支。
 */

import { AiToolDefinition } from '../AiProtocolTypes'
import { presetAllowsTool } from '../../../model/AiAgentPreset'
import { AiToolCategory, AiToolMeta, findAiToolMeta } from '../../../model/AiToolConfig'
import {
  AiToolAdapter,
  AiToolContext,
  AiToolResult,
  TOOL_ERROR_EMPTY,
  TOOL_ERROR_RATE_LIMITED,
  TOOL_ERROR_UNAVAILABLE,
  TOOL_ERROR_UPSTREAM
} from './AiToolAdapter'
import {
  FRESHNESS_ARG,
  FRESHNESS_AUTO,
  FRESHNESS_FRESH,
  FRESHNESS_NO_CACHE,
  ToolCacheQuery,
  aiToolResultCache,
  buildCacheQuery,
  toolCacheTtlMs
} from './ToolResultCache'
import { ngaThrottler } from '../../../common/concurrency/Throttler'
import { Logger, DOMAIN_SERVICE } from '../../../common/utils/Logger'
import { GetContextTool } from './ContextTool'
import { ExpandToolResultTool } from './ExpandToolResultTool'
import { WebSearchTool } from './WebSearchTool'
import { WebFetchTool } from './WebFetchTool'
import { NgaReadThreadTool } from './nga/NgaThreadTools'
import { NgaListTopicsTool, NgaSearchTopicsTool } from './nga/NgaTopicTools'
import { NgaListForumsTool, NgaSearchForumTool } from './nga/NgaForumTools'
import { NgaGetMeTool, NgaGetUserTool, NgaSearchUserTool, NgaUserActivityTool } from './nga/NgaUserTools'
import { NgaListFavoritesTool } from './nga/NgaFavoriteTools'
import { NgaMyHistoryTool, NgaMySavedTool, NgaMyTrackedTool } from './nga/NgaMyLibraryTools'
import { NgaMyPostsTool, NgaMyRepliesTool } from './nga/NgaMyPostTools'
import { NgaMyFollowingTool, NgaMyNotificationsTool } from './nga/NgaMySocialTools'
import { NgaMyMessagesTool } from './nga/NgaMyMessageTools'

const logger = new Logger(DOMAIN_SERVICE, 'AiToolRegistry')

/** NGA 站内工具分类（只有这类工具受本地风控闸门约束）。 */
const NGA_CATEGORY: string = AiToolCategory.NGA

/**
 * 上一次执行时的账号 UID。
 *
 * 缓存按 uid 分桶，账号切换（含退出登录）必须整体失活，否则会把上一个账号的
 * 帖子 / 资料当成当前账号的数据返回。这里在每次执行入口比对，逻辑最简且不会漏。
 */
let lastCacheUid: string = ''

/**
 * 绑定缓存所属账号（持久化层恢复缓存后调用）。
 *
 * 如果不绑定，`execute` 第一次看到 `lastCacheUid` 与当前 uid 不同，
 * 会把刚从磁盘恢复的缓存整体清掉——持久化就白做了。
 *
 * @param uid - 当前账号（未登录传空串）
 */
export function bindToolCacheAccount(uid: string): void {
  lastCacheUid = uid
}

/**
 * 判断是否为 NGA 站内工具。
 *
 * 用目录里的 `category` 而不是工具名前缀：分类是元数据真源的一部分，
 * 按名字前缀判断会让「改个工具名」悄悄改变风控行为，也与本文件
 * 「不再按工具名写死分支」的约束冲突。
 *
 * @param name - 工具名
 * @returns true 表示站内工具
 */
function isNgaTool(name: string): boolean {
  const meta: AiToolMeta | null = findAiToolMeta(name)
  return meta !== null && meta.category === NGA_CATEGORY
}

/**
 * 判断工具是否纯本地（不发起 NGA 网络请求）。
 *
 * 风控冷却闸门只应挡住"会打服务端"的工具：本地台账类工具（浏览记录 / 离线存档 /
 * 跟踪列表）在冷却期仍应可读，否则网络被限流会连带把本地功能也锁死。
 *
 * @param name - 工具名
 * @returns true 表示纯本地工具
 */
function isLocalOnlyTool(name: string): boolean {
  const meta: AiToolMeta | null = findAiToolMeta(name)
  return meta !== null && meta.localOnly === true
}

/**
 * 构造页面上下文指纹，参与缓存键。
 *
 * 工具普遍允许省略标识参数并回退到当前页面（读当前帖、读当前版块、看当前用户），
 * 因此「同一工具 + 同一组参数」在不同页面下代表**不同数据**。指纹不参与业务，
 * 只负责把这种隐式输入变成显式的键区分。
 *
 * 刻意不含 fallbackQuery（模型参数缺失时兜底用的最后一条用户消息）：
 * 它随每轮提问变化，放进来会让「同一帖子连续追问」永远不命中缓存，
 * 缓存价值直接归零。参数缺失且无法解析时由 key 为空（不缓存）那条规则兜底。
 *
 * @param context - 工具执行上下文
 * @returns 指纹字符串
 */
function buildContextFingerprint(context: AiToolContext): string {
  const task = context.taskContext
  return task.tid + '|' + task.pid + '|' + task.uid + '|' + task.fid
}

/**
 * 构造风控冷却期的工具失败结果。
 *
 * 文案刻意强调「不是没有数据」：否则模型会改用别的工具继续试探，
 * 在冷却期里形成"换工具重试"的风控放大器。
 *
 * @param remainingMs - 剩余冷却时长
 * @returns 失败结果
 */
function throttleGateResult(remainingMs: number): AiToolResult {
  const seconds: number = Math.max(1, Math.ceil(remainingMs / 1000))
  const result: AiToolResult = new AiToolResult()
  result.success = false
  result.errorCode = TOOL_ERROR_RATE_LIMITED
  result.errorMessage = '触发 NGA 频率限制，客户端已暂停站内请求'
  result.content = 'NGA 接口暂时触发了频率限制，客户端已主动暂停站内请求约 ' +
    seconds.toString() + ' 秒。\n' +
    '这不是「没有数据」或「接口坏了」：请直接告诉用户稍后再试，' +
    '不要改用其它站内工具反复尝试，也不要凭已有印象编造内容。'
  return result
}

/**
 * 构造 `freshness` 参数的 Schema。
 *
 * @returns 属性描述
 */
function freshnessProperty(): Record<string, Object> {
  const prop: Record<string, Object> = {}
  prop['type'] = 'string'
  prop['description'] = '取数新鲜度。auto=默认（允许命中短期缓存）；' +
    'fresh=跳过缓存强制取最新（用户说「最新的 / 现在 / 刚发的」时使用）；' +
    'no_cache=完全不使用缓存'
  const options: Object[] = [FRESHNESS_AUTO, FRESHNESS_FRESH, FRESHNESS_NO_CACHE]
  prop['enum'] = options
  return prop
}

/**
 * 给可缓存的工具定义注入公共的 `freshness` 参数。
 *
 * 只给「真的会被缓存」的工具注入：不可缓存的工具多一个无效参数，
 * 只会增加模型的选择负担与参数幻觉概率。
 *
 * @param definition - 工具定义（原地修改）
 */
function injectFreshnessParameter(definition: AiToolDefinition): void {
  if (toolCacheTtlMs(definition.name) <= 0) {
    return
  }
  const rawProperties: Object | undefined = definition.parameters['properties']
  if (rawProperties === undefined || rawProperties === null) {
    return
  }
  const properties: Record<string, Object> = rawProperties as Record<string, Object>
  properties[FRESHNESS_ARG] = freshnessProperty()
  definition.parameters['properties'] = properties as Object
}

/**
 * 工具注册表。
 */
export class AiToolRegistry {
  /** 已注册的工具适配器。 */
  private adapters: AiToolAdapter[] = []

  /**
   * 注册工具。
   *
   * 幂等：同名工具再次注册时替换原有适配器，而不是追加一份。
   * 追加会让同一 function 名在 `tools` 声明里出现两次（部分服务商因此 400），
   * 也会让 `getAdapter` 的返回值取决于注册顺序。
   *
   * @param adapter - 工具适配器
   */
  register(adapter: AiToolAdapter): void {
    const name: string = adapter.getName()
    for (let i: number = 0; i < this.adapters.length; i++) {
      if (this.adapters[i].getName() === name) {
        this.adapters[i] = adapter
        return
      }
    }
    this.adapters.push(adapter)
  }

  /**
   * 获取全部已注册工具的名字（不含可用性过滤，供契约测试与诊断使用）。
   *
   * @returns 工具名数组（注册顺序）
   */
  getRegisteredNames(): string[] {
    const names: string[] = []
    for (let i: number = 0; i < this.adapters.length; i++) {
      names.push(this.adapters[i].getName())
    }
    return names
  }

  /**
   * 获取当前上下文下可用的工具适配器。
   *
   * 判定顺序：任务白名单 → 工具自身可用性（全局开关 + 依赖就绪）。
   *
   * @param context - 工具执行上下文
   * @returns 可用适配器列表
   */
  getAvailableAdapters(context: AiToolContext): AiToolAdapter[] {
    const available: AiToolAdapter[] = []
    for (let i: number = 0; i < this.adapters.length; i++) {
      const adapter: AiToolAdapter = this.adapters[i]
      if (!presetAllowsTool(context.preset, adapter.getName())) {
        continue
      }
      if (adapter.isAvailable(context)) {
        available.push(adapter)
      }
    }
    return available
  }

  /**
   * 获取当前上下文下可用的工具定义。
   *
   * `title` 与 `annotations` 从工具目录派生（单一真源）：适配器只声明名称、
   * 说明与参数 Schema，展示名与行为注解不重复写第二遍，也不会与目录漂移。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义列表
   */
  getDefinitions(context: AiToolContext): AiToolDefinition[] {
    const definitions: AiToolDefinition[] = []
    const available: AiToolAdapter[] = this.getAvailableAdapters(context)
    for (let i: number = 0; i < available.length; i++) {
      const definition: AiToolDefinition = available[i].getDefinition(context)
      applyCatalogMeta(definition)
      injectFreshnessParameter(definition)
      definitions.push(definition)
    }
    return definitions
  }

  /**
   * 获取当前上下文下可用的工具名（供 UI 展示"哪些工具已就绪"）。
   *
   * @param context - 工具执行上下文
   * @returns 可用工具名列表
   */
  getAvailableNames(context: AiToolContext): string[] {
    const names: string[] = []
    const available: AiToolAdapter[] = this.getAvailableAdapters(context)
    for (let i: number = 0; i < available.length; i++) {
      names.push(available[i].getName())
    }
    return names
  }

  /**
   * 按名称查找工具适配器。
   *
   * @param name - 工具名称
   * @param context - 工具执行上下文
   * @returns 适配器，未注册或当前不可用时返回 null
   */
  getAdapter(name: string, context: AiToolContext): AiToolAdapter | null {
    for (let i: number = 0; i < this.adapters.length; i++) {
      if (this.adapters[i].getName() === name && presetAllowsTool(context.preset, name) &&
        this.adapters[i].isAvailable(context)) {
        return this.adapters[i]
      }
    }
    return null
  }

  /**
   * 执行一次工具调用。
   *
   * 三层保护按顺序生效：
   * 1. **时效性缓存**：可缓存工具命中时直接返回副本（`freshness=fresh` 跳过读、
   *    `no_cache` 跳过读写）。缓存读不发起网络请求，所以在冷却期内也照常返回——
   *    把闸门放在缓存前面，会让"本地明明有数据"也拿不到，属于自我伤害。
   * 2. **本地风控闸门**：NGA 冷却期内直接返回 `rate_limited`，不发任何请求；
   * 3. **实际执行**：失败结果与空正文不写缓存。
   *
   * @param name - 工具名称
   * @param argumentsText - 参数 JSON
   * @param context - 工具执行上下文
   * @param fallbackQuery - 兜底查询
   * @returns 工具结果（未找到工具时返回失败结果）
   */
  async execute(
    name: string,
    argumentsText: string,
    context: AiToolContext,
    fallbackQuery: string
  ): Promise<AiToolResult> {
    const adapter: AiToolAdapter | null = this.getAdapter(name, context)
    if (adapter === null) {
      const result: AiToolResult = new AiToolResult()
      result.success = false
      result.errorCode = TOOL_ERROR_UNAVAILABLE
      result.errorMessage = '工具不可用：' + name
      result.content = '工具「' + name + '」当前不可用（未启用、未登录或不在本任务的工具范围内）。' +
        '请换用其它工具或直接基于已有信息回答。'
      return result
    }

    // 1) 缓存：账号变化时整体失活，避免跨账号串数据。
    //    必须先于闸门——命中缓存不产生任何网络请求，冷却期也应放行。
    let query: ToolCacheQuery | null = null
    const ttl: number = toolCacheTtlMs(name)
    if (ttl > 0) {
      if (lastCacheUid !== context.selfUid) {
        aiToolResultCache.invalidateAll()
        lastCacheUid = context.selfUid
      }
      query = buildCacheQuery(
        name, context.selfUid, argumentsText, buildContextFingerprint(context), fallbackQuery)
      const cacheReadable: boolean = query.key.length > 0 &&
        query.freshness !== FRESHNESS_FRESH && query.freshness !== FRESHNESS_NO_CACHE
      if (cacheReadable) {
        const cached: AiToolResult | null = aiToolResultCache.get(query.key)
        if (cached !== null) {
          logger.info('tool cache hit: %{public}s', name)
          return cached
        }
      }
    }

    // 2) 本地风控闸门：冷却期内的站内请求一律不发。这比"发了再被限流"省一次握手，
    //    也避免模型把冷却期当成空数据、进而换工具反复试探。
    //    纯本地工具（浏览记录 / 离线存档 / 跟踪列表）不发请求，不受此闸门约束。
    if (isNgaTool(name) && !isLocalOnlyTool(name) && ngaThrottler.isCoolingDown()) {
      return throttleGateResult(ngaThrottler.cooldownRemainingMs())
    }

    // 3) 实际执行
    const result: AiToolResult = await adapter.execute(argumentsText, context, fallbackQuery)
    // 网络层识别到风控时会拉闸；但工具往往把「限流」表现成空结果或上游失败
    // （例如 read.php 的节流响应没有 html，工具层只能报「没读到楼层」）。
    // 这里用「本次执行后进入了冷却」这个事实反推：本次失败就是风控造成的，
    // 统一改写为 rate_limited，让 Agent 层据此停止本次运行、不要让模型换工具继续试。
    if (!result.success && isNgaTool(name) && !isLocalOnlyTool(name) &&
      ngaThrottler.isCoolingDown() &&
      (result.errorCode === TOOL_ERROR_EMPTY || result.errorCode === TOOL_ERROR_UPSTREAM ||
        result.errorCode.length === 0)) {
      result.errorCode = TOOL_ERROR_RATE_LIMITED
      result.errorMessage = '触发 NGA 频率限制，本次取数失败'
      result.content = 'NGA 接口触发了频率限制，本次取数失败。\n' +
        '这不是「没有数据」或「接口坏了」：请直接告诉用户稍后再试，' +
        '不要改用其它站内工具继续尝试，也不要凭已有印象编造内容。'
    }
    if (query !== null && query.key.length > 0 && query.freshness !== FRESHNESS_NO_CACHE) {
      aiToolResultCache.set(query.key, result, ttl)
    }
    return result
  }
}

/**
 * 用工具目录补齐定义里的展示名与行为注解。
 *
 * 目录是元数据的唯一真源：新增工具只改目录 + 适配器，不必在两处维护
 * title / 只读标记 / 幂等标记。
 *
 * @param definition - 工具定义（原地修改）
 */
function applyCatalogMeta(definition: AiToolDefinition): void {
  const meta: AiToolMeta | null = findAiToolMeta(definition.name)
  if (definition.title.length === 0) {
    definition.title = meta !== null ? meta.title : definition.name
  }
  if (meta === null) {
    return
  }
  const readOnly: boolean = meta.readOnly !== false
  definition.annotations.readOnly = readOnly
  // 写操作一律视为破坏性：真正的"可恢复写"在开放出来时应显式区分
  definition.annotations.destructive = !readOnly
  definition.annotations.idempotent = meta.idempotent !== false
  definition.annotations.openWorld = meta.openWorld === true
}

/**
 * 创建并初始化工具注册表。
 *
 * @returns 已注册全部内置工具的注册表
 */
function createAiToolRegistry(): AiToolRegistry {
  const registry: AiToolRegistry = new AiToolRegistry()
  // 对话上下文：零参数、不发起网络请求，可用性清单由注册表回调注入
  registry.register(new GetContextTool((context: AiToolContext): string[] =>
    registry.getAvailableNames(context)))
  // 大结果续读：零网络请求，只读本次运行的内存归档
  registry.register(new ExpandToolResultTool())
  // NGA 站内只读工具（登录后即可用）
  registry.register(new NgaGetMeTool())
  registry.register(new NgaReadThreadTool())
  registry.register(new NgaListTopicsTool())
  registry.register(new NgaSearchTopicsTool())
  registry.register(new NgaListForumsTool())
  registry.register(new NgaSearchForumTool())
  registry.register(new NgaGetUserTool())
  registry.register(new NgaSearchUserTool())
  registry.register(new NgaUserActivityTool())
  registry.register(new NgaListFavoritesTool())
  // 「我的」本地资料（浏览记录 / 离线保存 / 跟踪）：零网络请求
  registry.register(new NgaMyHistoryTool())
  registry.register(new NgaMySavedTool())
  registry.register(new NgaMyTrackedTool())
  // 「我的」站内记录（发帖 / 回帖）：走官方 user/subjects|replys，签名 uid 固定为当前账号
  registry.register(new NgaMyPostsTool())
  registry.register(new NgaMyRepliesTool())
  // 「我的」社交推送（关注动态 / 通知）：数据来自 Store 缓存，与消息中心同源
  registry.register(new NgaMyFollowingTool())
  registry.register(new NgaMyNotificationsTool())
  // 私信：消息中心「私信」Tab（列表 / 会话详情），只读
  registry.register(new NgaMyMessagesTool())
  // 联网工具（需要搜索服务）
  registry.register(new WebSearchTool())
  registry.register(new WebFetchTool())
  return registry
}

/** 全局工具注册表。 */
export const aiToolRegistry: AiToolRegistry = createAiToolRegistry()
