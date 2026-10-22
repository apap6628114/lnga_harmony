/**
 * 客户端工具适配器契约。
 *
 * 工具由客户端声明给模型、由客户端执行，因此工具能力与对话服务商解耦：
 * 只要服务商支持 OpenAI 标准的 function calling，就能使用同一套工具。
 *
 * 工具执行需要两类配置：对话配置（决定是否启用工具）与搜索配置
 * （决定由哪家搜索服务、用哪个密钥执行）。二者通过 AiToolContext 传入。
 */

import { AiProviderProfile } from '../../../model/AiConfig'
import { AiSearchProfile } from '../../../model/AiSearchConfig'
import { AiToolSettings } from '../../../model/AiToolConfig'
import { AiAgentPreset, AiTaskContext } from '../../../model/AiAgentPreset'
import { AiToolDefinition } from '../AiProtocolTypes'

/**
 * 工具执行上下文。
 */
export class AiToolContext {
  /** 对话配置（提供协议 / 端点等；工具本身不再受它限制） */
  chat: AiProviderProfile = new AiProviderProfile()
  /** 激活的搜索配置（未配置时为 null） */
  search: AiSearchProfile | null = null
  /** 全局工具设置（所有 AI 配置共用） */
  tools: AiToolSettings = new AiToolSettings()
  /** 当前任务（决定工具白名单；自由对话时为 null） */
  preset: AiAgentPreset | null = null
  /** 当前页面上下文（帖子 / 用户 / 版块标识，供工具在缺参时回退） */
  taskContext: AiTaskContext = new AiTaskContext()
  /** 当前登录用户 UID（"读我自己"类工具的兜底参数） */
  selfUid: string = ''
  /** 当前登录用户昵称 */
  selfUserName: string = ''
  /** NGA 会话令牌（NGA 工具用，未登录为空串） */
  token: string = ''
  /** 是否已登录（由服务层统一判定） */
  authenticated: boolean = false
}

/** 工具结果中的可点击卡片。 */
export class AiToolCard {
  /** 卡片类型：topic / forum / user */
  kind: string = ''
  /** 主标题 */
  title: string = ''
  /** 副标题（作者、回复数、版块等） */
  subtitle: string = ''
  /** 跳转目标（应用内路由标识） */
  route: string = ''
  /** 跳转参数（JSON 字符串） */
  params: string = ''
}

/**
 * 工具失败原因分类（对齐 MCP `isError` 的语义：能区分"重试有用"与"重试无用"）。
 *
 * 仅供客户端与后续 Agent 策略使用；模型侧仍以 `content` 里的可读文本为准，
 * 因此这里填错不会改变模型行为，只会让统计与重试策略变形。
 */
export const TOOL_ERROR_BAD_ARGS: string = 'bad_args'
/** 缺少登录态 */
export const TOOL_ERROR_LOGIN_REQUIRED: string = 'login_required'
/** 目标不存在（用户 / 帖子 / 版块查不到） */
export const TOOL_ERROR_NOT_FOUND: string = 'not_found'
/** 被服务端限流（可退避后重试） */
export const TOOL_ERROR_RATE_LIMITED: string = 'rate_limited'
/** 上游接口失败（网络 / 5xx / 解析异常） */
export const TOOL_ERROR_UPSTREAM: string = 'upstream_error'
/** 工具本身在当前上下文不可用（未启用 / 依赖缺失） */
export const TOOL_ERROR_UNAVAILABLE: string = 'unavailable'
/** 调用成功但结果为空 */
export const TOOL_ERROR_EMPTY: string = 'empty_result'
/** 本次运行的调用预算已用尽，该工具未执行 */
export const TOOL_ERROR_BUDGET_EXHAUSTED: string = 'budget_exhausted'

/** 工具结果中的引用来源。 */
export class AiToolSource {
  /** 来源标题 */
  title: string = ''
  /** 来源链接 */
  url: string = ''
}

/**
 * 工具执行结果。
 *
 * content 会作为工具输出回传给模型，因此必须是模型可读的纯文本；
 * summary / count / sources 只用于 UI 展示。
 */
export class AiToolResult {
  /** 是否成功 */
  success: boolean = false
  /** 回传给模型的内容 */
  content: string = ''
  /** UI 摘要（通常为搜索词或网页标题） */
  summary: string = ''
  /** UI 结果计数 */
  count: number = 0
  /** 错误信息 */
  errorMessage: string = ''
  /** 失败分类（TOOL_ERROR_*；成功时为空串） */
  errorCode: string = ''
  /** 引用来源列表 */
  sources: AiToolSource[] = []
  /** 可点击卡片（帖子 / 版块 / 用户） */
  cards: AiToolCard[] = []
  /**
   * 本次结果是否来自时效性缓存。
   *
   * 只影响 UI 展示（「缓存于 x 分钟前」）与诊断日志，不改写 content：
   * 模型看不到这个标记，避免它把「缓存」当成数据不完整的借口。
   */
  fromCache: boolean = false
}

/**
 * 工具适配器接口。
 *
 * 每个工具声明自己的定义、可用性判断与执行逻辑。
 */
export interface AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称（对应 function.name）
   */
  getName(): string

  /**
   * 获取协议无关的工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition

  /**
   * 判断工具当前是否可用。
   *
   * @param context - 工具执行上下文
   * @returns true 表示可以加入本次请求的 tools 声明
   */
  isAvailable(context: AiToolContext): boolean

  /**
   * 执行工具调用。
   *
   * @param argumentsText - 模型生成的 JSON 参数字符串
   * @param context - 工具执行上下文
   * @param fallbackQuery - 参数解析失败时的兜底查询（通常为最后一条用户消息）
   * @returns 工具执行结果
   */
  execute(
    argumentsText: string,
    context: AiToolContext,
    fallbackQuery: string
  ): Promise<AiToolResult>
}

/**
 * 一次工具调用的展示记录。
 *
 * 服务层在 Agent 循环中填充，聊天页据此渲染工具时间线。
 */
export class AiToolInvocation {
  /** 调用 ID */
  id: string = ''
  /** 工具名称 */
  name: string = ''
  /** 工具展示名 */
  displayName: string = ''
  /** 参数摘要（搜索词 / 网页地址） */
  summary: string = ''
  /** 状态：running / success / failed */
  status: string = 'running'
  /** 结果计数 */
  count: number = 0
  /** 耗时（毫秒） */
  durationMs: number = 0
  /** 回传给模型的正文长度（字符数，用于上下文预算核算） */
  contentChars: number = 0
  /** 错误信息 */
  errorMessage: string = ''
  /** 失败分类（TOOL_ERROR_*；成功时为空串） */
  errorCode: string = ''
  /** 引用来源 */
  sources: AiToolSource[] = []
  /** 可点击卡片（帖子 / 版块 / 用户） */
  cards: AiToolCard[] = []
  /** 本次结果是否来自时效性缓存（UI 展示「缓存」标记用） */
  fromCache: boolean = false
}
