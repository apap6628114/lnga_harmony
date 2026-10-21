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
import { AiToolDefinition } from '../AiProtocolTypes'

/**
 * 工具执行上下文。
 */
export class AiToolContext {
  /** 对话配置（提供工具开关 / Agent 参数） */
  chat: AiProviderProfile = new AiProviderProfile()
  /** 激活的搜索配置（未配置时为 null） */
  search: AiSearchProfile | null = null
}

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
  /** 引用来源列表 */
  sources: AiToolSource[] = []
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
  /** 错误信息 */
  errorMessage: string = ''
  /** 引用来源 */
  sources: AiToolSource[] = []
}
