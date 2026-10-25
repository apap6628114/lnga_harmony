/**
 * 全局 AI 工具配置。
 *
 * 设计要点（与改造前的关键差异）：
 * - 工具是**客户端能力**，不是模型属性：同一台设备上所有 AI 配置共用一套工具开关，
 *   不存在「A 模型能联网、B 模型不能」；
 * - 工具元数据集中在 `AI_TOOL_CATALOG`，设置页与 Agent 循环共用，新增工具只改
 *   目录 + 注册表 + 适配器，UI 自动出现；
 * - 工具可用性只由三件事决定：全局开关、依赖是否就绪（登录态 / 搜索服务）、
 *   当前任务的白名单。配置里不再出现任何按模型区分的工具字段。
 */

import { AiProviderProfile, DEFAULT_AI_MAX_AGENT_STEPS, clampAgentSteps } from './AiConfig'

/**
 * 单次 Agent 运行允许执行的工具调用次数上限。
 *
 * 与 `maxAgentSteps`（模型请求轮数）是两个维度：一轮里模型可以一次返回多个
 * tool_calls，只限轮数挡不住「一轮十个工具、每个工具内部再翻页」的请求放大。
 * 这是抵御风控的最后一道闸，因此是硬上限，不放进用户设置——需要更多数据时
 * 应该提示模型拆分任务，而不是提高这个值。
 */
export const DEFAULT_MAX_TOOL_CALLS_PER_RUN: number = 30

/**
 * 工具结果缓存的长 TTL（重接口：一次取数要解析整页 HTML 或聚合多个上游接口）。
 *
 * 放在 model 层而不是缓存实现里：TTL 是「这个工具取一次有多贵、多久内重取没意义」
 * 的能力属性，属于工具元数据。缓存的读者（ToolResultCache）与元数据真源
 * （AI_TOOL_CATALOG）必须共用同一个值，否则就是第二份工具清单。
 */
export const AI_TOOL_CACHE_TTL_LONG: number = 600000

/** 工具结果缓存的短 TTL（列表 / 搜索类，变化快）。 */
export const AI_TOOL_CACHE_TTL_SHORT: number = 45000

/** 工具分类。 */
export enum AiToolCategory {
  /** 对话上下文（页面标识、工具可用性），不发起网络请求 */
  CONTEXT = 'context',
  /** NGA 站内能力（读帖、翻版块、查用户等） */
  NGA = 'nga',
  /** 联网能力（搜索 / 抓取） */
  WEB = 'web'
}

/** 依赖类型：无额外依赖。 */
export const TOOL_REQUIRES_NONE: string = 'none'
/** 依赖类型：需要登录态。 */
export const TOOL_REQUIRES_LOGIN: string = 'login'
/** 依赖类型：需要已配置搜索服务。 */
export const TOOL_REQUIRES_SEARCH: string = 'search'

/**
 * 工具元数据。
 *
 * `name` 是稳定标识，必须与 function calling 的工具名一致；
 * 其余字段只用于 UI 展示与默认值。
 */
export interface AiToolMeta {
  /** 工具名称（function.name） */
  name: string
  /** UI 展示名（同时作为工具定义的 title） */
  title: string
  /** UI 说明 */
  description: string
  /** 分类 */
  category: string
  /** 依赖类型（TOOL_REQUIRES_*） */
  requires: string
  /** 依赖未就绪时的提示 */
  requirementHint: string
  /** 首次运行时的默认开关 */
  defaultEnabled: boolean
  /**
   * 是否只读（缺省 true）。
   *
   * 写操作工具必须显式写 false：Agent 层据此决定是否需要用户确认，
   * 也是"AI 不开放写操作"这条约束在元数据上的落点。
   */
  readOnly?: boolean
  /**
   * 是否幂等（缺省 true）：同参数重复调用无副作用，可安全重试 / 合并请求。
   */
  idempotent?: boolean
  /**
   * 是否开放世界（缺省 false）：结果依赖站外或实时数据，缓存价值低。
   */
  openWorld?: boolean
  /**
   * 缓存存活时长（毫秒；缺省按分类派生为短 TTL）。
   *
   * 只表达「多久内重取没意义」，**不表达「能不能缓存」**：能不能缓存仍由
   * `readOnly` / `idempotent` / `openWorld` 三个字段决定。重接口在这里标
   * {@link AI_TOOL_CACHE_TTL_LONG}，其余留空走短 TTL。
   */
  cacheTtlMs?: number
  /**
   * 是否纯本地工具（缺省 false）：不发起任何 NGA 网络请求。
   *
   * 这类工具（浏览记录 / 离线存档 / 跟踪列表）不能走风控冷却闸门——
   * 冷却只该挡住"会打服务端"的工具，否则网络被限流时连本地台账都读不到。
   * 也不要求登录态的工具（离线存档）同样适用。
   */
  localOnly?: boolean
}

/**
 * 全局工具设置。
 *
 * 持久化在 `SettingsState.aiToolSettings`，与任何 AI 配置无关。
 */
export class AiToolSettings {
  /**
   * 工具名 -> 是否启用。
   *
   * 缺失的键表示「使用工具目录的 defaultEnabled」，因此新增工具后老用户
   * 无需迁移即可获得默认行为。
   */
  enabled: Record<string, boolean> = {}
  /** Agent 单轮对话内最大工具轮数（全局） */
  maxAgentSteps: number = DEFAULT_AI_MAX_AGENT_STEPS
}

/**
 * 元工具：由客户端在 Agent 循环内部消费、不取站外数据、不需要任务白名单。
 *
 * 目前只有 `expand_tool_result`：它是「工具结果被上下文预算截断」时的续读入口，
 * 必须始终可用，否则截断就退化成永久丢信息。是否暴露仍受全局工具开关约束。
 */
const META_TOOL_NAMES: string[] = ['expand_tool_result']

/**
 * 判断是否为元工具。
 *
 * @param name - 工具名
 * @returns true 表示元工具
 */
export function isMetaTool(name: string): boolean {
  return META_TOOL_NAMES.indexOf(name) >= 0
}

/**
 * 可由任务白名单挑选的工具（排除元工具）。
 *
 * 元工具始终可用，不应出现在「任务可用工具」多选里——让用户以为能关掉它，
 * 比不展示更糟。
 *
 * @returns 工具目录副本
 */
export function listTaskToolCatalog(): AiToolMeta[] {
  const result: AiToolMeta[] = []
  for (let i: number = 0; i < AI_TOOL_CATALOG.length; i++) {
    if (!isMetaTool(AI_TOOL_CATALOG[i].name)) {
      result.push(AI_TOOL_CATALOG[i])
    }
  }
  return result
}

/** 工具目录：全部内置工具的元数据（顺序即 UI 展示顺序）。 */
export const AI_TOOL_CATALOG: AiToolMeta[] = [
  {
    name: 'get_context',
    title: '当前上下文',
    description: '读取本次对话所在的帖子 / 用户 / 版块标识，以及当前可用与不可用的工具清单（零参数）',
    category: AiToolCategory.CONTEXT,
    requires: TOOL_REQUIRES_NONE,
    requirementHint: '',
    defaultEnabled: true
  },
  {
    name: 'expand_tool_result',
    title: '续读工具结果',
    description: '按 result_id 续读一条因上下文预算被截断的工具结果（大结果外置，需要时再取，不丢信息）',
    category: AiToolCategory.CONTEXT,
    requires: TOOL_REQUIRES_NONE,
    requirementHint: '',
    defaultEnabled: true
  },
  {
    name: 'nga_get_me',
    title: '我的账号',
    description: '读取当前登录账号的资料（零参数），是「看看我自己」类问题的起点',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true,
    // 不叠加缓存：资料已经由 ProfileStore 的 LRU（5 分钟）缓存，工具层再包一层
    // 会变成两个 TTL 两套失效，UI 刷新后 AI 还能读到更旧的快照
    cacheTtlMs: 0
  },
  {
    name: 'nga_read_thread',
    title: '读帖',
    description: '读取帖子标题、楼层、作者与正文纯文本，支持指定页码与楼层定位（每次一页约 20 楼，正文按上限截断）',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true,
    cacheTtlMs: AI_TOOL_CACHE_TTL_LONG
  },
  {
    name: 'nga_list_topics',
    title: '版块主题列表',
    description: '按版块 ID 拉取主题列表，支持最新 / 热门 / 精华排序与翻页（hot 固定近 7 天、不分页）',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true
  },
  {
    name: 'nga_search_topics',
    title: '站内搜索主题',
    description: '在 NGA 搜索主题，可限定版块，返回标题、作者、回复数与 tid（关键词需简短）',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true
  },
  {
    name: 'nga_list_forums',
    title: '我的版块',
    description: '列出收藏版面，或 scope=all 时列出全部分类版块（拿到 fid 后再翻列表）',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true,
    cacheTtlMs: AI_TOOL_CACHE_TTL_LONG
  },
  {
    name: 'nga_search_forum',
    title: '搜索版块',
    description: '按英文版块名搜索 NGA 版块，返回 fid 与版块名（中文关键词会被服务端拒绝）',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true
  },
  {
    name: 'nga_get_user',
    title: '用户资料',
    description: '按 UID 或完整用户名读取用户资料卡（等级、发帖数、注册时间、签名等）',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true,
    // 同 nga_get_me：资料由 ProfileStore 缓存，工具层不叠加第二层
    cacheTtlMs: 0
  },
  {
    name: 'nga_search_user',
    title: '搜索用户',
    description: '按完整用户名或 UID 精确查找用户，一次返回一个匹配结果（非模糊搜索）',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true
  },
  {
    name: 'nga_user_activity',
    title: '用户活跃分析',
    description: '读取用户版块活跃分布、时段分布与近期发帖回复样本',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true,
    cacheTtlMs: AI_TOOL_CACHE_TTL_LONG
  },
  {
    name: 'nga_list_favorites',
    title: '收藏夹',
    description: '列出主题收藏夹，或读取某个收藏夹内的主题',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true
  },
  {
    name: 'nga_my_history',
    title: '浏览记录',
    description: '读取本地浏览记录（最近打开过的帖子，最多 500 条），可按 tid 查单帖是否看过',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true,
    // 本地台账（内存 + Preferences）：工具层缓存只会读到更旧的快照
    cacheTtlMs: 0,
    // 不发网络请求：风控冷却期也应可用
    localOnly: true
  },
  {
    name: 'nga_my_saved',
    title: '离线保存',
    description: '读取本地离线保存的帖子存档（设备级、跨账号，未登录也可用）',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_NONE,
    requirementHint: '',
    defaultEnabled: true,
    // 存档是本地文件，读写都在本进程内完成，缓存无意义
    cacheTtlMs: 0,
    // 不发网络请求且不要求登录：必须绕过风控冷却闸门
    localOnly: true
  },
  {
    name: 'nga_my_tracked',
    title: '跟踪中的帖子',
    description: '读取跟踪列表：总回复、未读新增、最后回复时间与锁定状态，可按 tid 查单帖',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true,
    // 轮询快照由 Store 维护，工具层不得再叠加 TTL
    cacheTtlMs: 0,
    // 只读 Store 快照，不发网络请求
    localOnly: true
  },
  {
    name: 'nga_my_posts',
    title: '我的发帖',
    description: '读取我发布的主题（官方接口带真实总页数，可翻页），用于「我一共发了多少帖」',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true,
    cacheTtlMs: AI_TOOL_CACHE_TTL_SHORT
  },
  {
    name: 'nga_my_replies',
    title: '我的回帖',
    description: '读取我最近的回帖（每页 20 条，更早的记录服务端不可读；不能用于全量统计）',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true,
    cacheTtlMs: AI_TOOL_CACHE_TTL_SHORT
  },
  {
    name: 'nga_my_following',
    title: '关注动态',
    description: '读取关注动态：我关注的用户最近发主题 / 回帖 / 收藏，可按 refresh 拉取最新一页',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true,
    // 动态由 Store 轮询刷新，工具层再缓存会读到更旧的快照
    cacheTtlMs: 0
  },
  {
    name: 'nga_my_notifications',
    title: '我的通知',
    description: '读取我的通知（消息 Tab，不含私信），含本地已读状态；缓存为空时自动拉取一次',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true,
    // 已读状态是本地易变状态：缓存会让「未读」在用户读完后继续显示旧值
    cacheTtlMs: 0
  },
  {
    name: 'nga_my_messages',
    title: '我的私信',
    description: '读取私信会话列表，或按 mid 读取会话内消息正文（只读，不含发送）',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true,
    cacheTtlMs: AI_TOOL_CACHE_TTL_SHORT
  },
  {
    name: 'web_search',
    title: '联网搜索',
    description: '搜索互联网并返回带链接的网页摘要',
    category: AiToolCategory.WEB,
    requires: TOOL_REQUIRES_SEARCH,
    requirementHint: '需要先在「搜索服务」中配置密钥',
    defaultEnabled: true,
    openWorld: true
  },
  {
    name: 'web_fetch',
    title: '网页抓取',
    description: '抓取指定网页的正文内容',
    category: AiToolCategory.WEB,
    requires: TOOL_REQUIRES_SEARCH,
    requirementHint: '需要先在「搜索服务」中配置密钥',
    defaultEnabled: true,
    openWorld: true
  }
]

/**
 * 按名称查找工具元数据。
 *
 * @param name - 工具名称
 * @returns 元数据，未收录时返回 null
 */
export function findAiToolMeta(name: string): AiToolMeta | null {
  for (let i: number = 0; i < AI_TOOL_CATALOG.length; i++) {
    if (AI_TOOL_CATALOG[i].name === name) {
      return AI_TOOL_CATALOG[i]
    }
  }
  return null
}

/**
 * 取工具展示名（未收录时回退工具名）。
 *
 * @param name - 工具名称
 * @returns 展示名
 */
export function aiToolTitle(name: string): string {
  const meta: AiToolMeta | null = findAiToolMeta(name)
  return meta !== null ? meta.title : name
}

/**
 * 判断某个工具是否被全局启用。
 *
 * 未显式设置过时按目录默认值处理，保证新增工具对老用户默认可用。
 *
 * @param settings - 全局工具设置
 * @param name - 工具名称
 * @returns true 表示启用
 */
export function isAiToolEnabled(settings: AiToolSettings, name: string): boolean {
  if (settings === null || settings === undefined) {
    const meta: AiToolMeta | null = findAiToolMeta(name)
    return meta !== null ? meta.defaultEnabled : false
  }
  const explicit: boolean | undefined = settings.enabled[name]
  if (typeof explicit === 'boolean') {
    return explicit as boolean
  }
  const meta: AiToolMeta | null = findAiToolMeta(name)
  return meta !== null ? meta.defaultEnabled : false
}

/**
 * 返回一份修改了单个工具开关的新设置（不可变更新，便于 @State 感知）。
 *
 * @param settings - 原设置
 * @param name - 工具名称
 * @param enabled - 是否启用
 * @returns 新设置
 */
export function withAiToolEnabled(settings: AiToolSettings, name: string,
  enabled: boolean): AiToolSettings {
  const next: AiToolSettings = new AiToolSettings()
  next.maxAgentSteps = settings.maxAgentSteps
  const keys: string[] = Object.keys(settings.enabled)
  for (let i: number = 0; i < keys.length; i++) {
    next.enabled[keys[i]] = settings.enabled[keys[i]]
  }
  next.enabled[name] = enabled
  return next
}

/**
 * 取当前启用的工具名列表（按目录顺序）。
 *
 * @param settings - 全局工具设置
 * @returns 工具名数组
 */
export function enabledAiToolNames(settings: AiToolSettings): string[] {
  const names: string[] = []
  for (let i: number = 0; i < AI_TOOL_CATALOG.length; i++) {
    const name: string = AI_TOOL_CATALOG[i].name
    if (isAiToolEnabled(settings, name)) {
      names.push(name)
    }
  }
  return names
}

/**
 * 归一化全局工具设置。
 *
 * 迁移规则：`aiToolSettings` 字段缺失（老版本）时，从激活的对话配置里读一次
 * `enableWebSearch` / `enableWebFetch` / `maxAgentSteps` 作为 Web 工具与轮数的初值；
 * NGA 工具此前不存在，一律按目录默认值（开启）。
 *
 * @param raw - 持久化读出的原始值（可能为 undefined）
 * @param profiles - 当前全部对话配置（用于迁移）
 * @param activeProfileId - 当前激活配置 ID
 * @returns 归一化后的设置
 */
export function normalizeAiToolSettings(raw: AiToolSettings | undefined,
  profiles: AiProviderProfile[], activeProfileId: string): AiToolSettings {
  if (raw !== undefined && raw !== null) {
    const settings: AiToolSettings = new AiToolSettings()
    const steps: number = typeof raw.maxAgentSteps === 'number'
      ? raw.maxAgentSteps : DEFAULT_AI_MAX_AGENT_STEPS
    settings.maxAgentSteps = clampAgentSteps(steps)
    if (raw.enabled !== undefined && raw.enabled !== null) {
      const keys: string[] = Object.keys(raw.enabled)
      for (let i: number = 0; i < keys.length; i++) {
        const value: boolean | undefined = raw.enabled[keys[i]]
        if (typeof value === 'boolean') {
          settings.enabled[keys[i]] = value as boolean
        }
      }
    }
    return settings
  }

  const settings: AiToolSettings = new AiToolSettings()
  settings.maxAgentSteps = DEFAULT_AI_MAX_AGENT_STEPS
  const legacy: AiProviderProfile | null = pickLegacyProfile(profiles, activeProfileId)
  if (legacy !== null) {
    settings.maxAgentSteps = clampAgentSteps(legacy.maxAgentSteps)
    settings.enabled['web_search'] = legacy.enableWebSearch !== false
    settings.enabled['web_fetch'] = legacy.enableWebFetch !== false
  }
  return settings
}

/**
 * 挑选用于迁移的旧配置：优先激活项，其次第一项。
 *
 * @param profiles - 全部对话配置
 * @param activeProfileId - 激活配置 ID
 * @returns 旧配置，无配置时返回 null
 */
function pickLegacyProfile(profiles: AiProviderProfile[],
  activeProfileId: string): AiProviderProfile | null {
  if (profiles === null || profiles === undefined || profiles.length === 0) {
    return null
  }
  for (let i: number = 0; i < profiles.length; i++) {
    if (profiles[i].id === activeProfileId) {
      return profiles[i]
    }
  }
  return profiles[0]
}

/**
 * 说明文案：某个依赖类型未就绪时给用户看什么。
 *
 * @param requires - 依赖类型
 * @returns 提示文案
 */
export function toolRequirementText(requires: string): string {
  if (requires === TOOL_REQUIRES_LOGIN) {
    return '需要登录 NGA 账号'
  }
  if (requires === TOOL_REQUIRES_SEARCH) {
    return '需要配置搜索服务'
  }
  return ''
}
