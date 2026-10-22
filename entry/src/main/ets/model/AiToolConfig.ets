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
    name: 'nga_get_me',
    title: '我的账号',
    description: '读取当前登录账号的资料（零参数），是「看看我自己」类问题的起点',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true
  },
  {
    name: 'nga_read_thread',
    title: '读帖',
    description: '读取帖子标题、楼层、作者与正文纯文本，支持指定页码与楼层定位',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true
  },
  {
    name: 'nga_list_topics',
    title: '版块主题列表',
    description: '按版块 ID 拉取主题列表，支持最新 / 热门 / 精华排序与翻页',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true
  },
  {
    name: 'nga_search_topics',
    title: '站内搜索主题',
    description: '在 NGA 搜索主题，可限定版块，返回标题、作者、回复数与链接',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true
  },
  {
    name: 'nga_list_forums',
    title: '我的版块',
    description: '列出账号已订阅的版块与收藏版面，用于拿到 fid 后再翻列表',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true
  },
  {
    name: 'nga_search_forum',
    title: '搜索版块',
    description: '按名称搜索 NGA 版块，返回 fid 与版块名',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true
  },
  {
    name: 'nga_get_user',
    title: '用户资料',
    description: '按 UID 或用户名读取用户资料卡（等级、发帖数、注册时间、签名等）',
    category: AiToolCategory.NGA,
    requires: TOOL_REQUIRES_LOGIN,
    requirementHint: '登录后可用',
    defaultEnabled: true
  },
  {
    name: 'nga_search_user',
    title: '搜索用户',
    description: '按用户名搜索用户，返回 UID 列表',
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
    defaultEnabled: true
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
