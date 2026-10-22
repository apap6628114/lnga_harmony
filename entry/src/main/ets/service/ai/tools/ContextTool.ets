/**
 * 上下文工具（get_context）。
 *
 * 存在的首要原因是**保护模型侧的前缀缓存**：页面上下文（tid / uid / fid）、
 * 登录账号、工具可用性都是每次请求都可能变化的内容。把它们拼进 system prompt
 * 会让 DeepSeek / OpenAI 的前缀缓存整段失效（命中要求前缀逐字节稳定）。
 *
 * 改成工具后：
 * - system 只保留稳定文案，历史逐轮累积不变 → 前缀稳定，命中率大幅提升；
 * - 模型什么时候需要标识，什么时候自己取，且取到的永远是**当前**上下文
 *   （比把上下文快照塞进历史更准确）。
 *
 * 工具可用性清单由注册表在装配时以回调注入，避免本文件反向依赖 ToolRegistry
 * 形成循环 import。
 */

import { AiToolDefinition } from '../AiProtocolTypes'
import { AiToolAdapter, AiToolContext, AiToolResult } from './AiToolAdapter'
import {
  AI_TOOL_CATALOG,
  AiToolMeta,
  DEFAULT_MAX_TOOL_CALLS_PER_RUN,
  TOOL_REQUIRES_LOGIN,
  TOOL_REQUIRES_SEARCH,
  aiToolTitle,
  isAiToolEnabled
} from '../../../model/AiToolConfig'
import { buildContextDetail, presetAllowsTool } from '../../../model/AiAgentPreset'
import { aiSearchProviderRegistry } from '../search/SearchProviderRegistry'
import { AiSearchProvider } from '../search/AiSearchProvider'
import { AiSearchProfile } from '../../../model/AiSearchConfig'

/** 工具名称。 */
const TOOL_NAME: string = 'get_context'

/** 可用工具名查询回调（由注册表注入）。 */
export type AiToolAvailabilityLookup = (context: AiToolContext) => string[]

/**
 * 当前上下文工具。
 */
export class GetContextTool implements AiToolAdapter {
  /** 可用工具名查询（注册表注入，避免循环依赖） */
  private lookupAvailability: AiToolAvailabilityLookup

  /**
   * 构造上下文工具。
   *
   * @param lookupAvailability - 返回当前可用工具名的回调
   */
  constructor(lookupAvailability: AiToolAvailabilityLookup) {
    this.lookupAvailability = lookupAvailability
  }

  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_NAME
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_NAME
    definition.title = '当前上下文'
    definition.description =
      '读取本次对话所在的页面上下文（帖子 tid / 楼层 pid / 用户 uid / 版块 fid）、' +
        '当前登录账号，以及此刻可用与不可用的工具清单。不需要任何参数。' +
        '多数工具会自动带入当前页面标识，因此只在工具回报"缺少 tid / uid / fid"、' +
        '或需要确认"我当前在哪、还能用什么工具"时调用它。'
    definition.parameters = buildEmptyParameters()
    return definition
  }

  /**
   * 判断工具是否可用。
   *
   * 只受全局开关与任务白名单约束：未登录时它同样可用（正是要告诉模型"未登录"）。
   *
   * @param context - 工具执行上下文
   * @returns true 表示可用
   */
  isAvailable(context: AiToolContext): boolean {
    return isAiToolEnabled(context.tools, TOOL_NAME)
  }

  /**
   * 执行上下文读取。
   *
   * @param argumentsText - 模型生成的参数 JSON（本工具无参数）
   * @param context - 工具执行上下文
   * @param fallbackQuery - 兜底查询（不使用）
   * @returns 工具结果
   */
  async execute(argumentsText: string, context: AiToolContext,
    fallbackQuery: string): Promise<AiToolResult> {
    const available: string[] = this.lookupAvailability(context)
    const sections: string[] = []
    sections.push(buildContextDetail(context.taskContext))
    sections.push(buildIdentitySection(context))
    sections.push(buildToolSection(context, available))

    const result: AiToolResult = new AiToolResult()
    result.success = true
    result.summary = '当前上下文'
    result.count = available.length
    result.content = sections.join('\n\n')
    return result
  }
}

/**
 * 构造空参数 Schema。
 *
 * @returns parameters 对象
 */
function buildEmptyParameters(): Record<string, Object> {
  const properties: Record<string, Object> = {}
  const required: string[] = []
  const parameters: Record<string, Object> = {}
  parameters['type'] = 'object'
  parameters['properties'] = properties
  parameters['required'] = required
  parameters['additionalProperties'] = false
  return parameters
}

/**
 * 构造"当前登录账号"段落。
 *
 * @param context - 工具执行上下文
 * @returns 文本
 */
function buildIdentitySection(context: AiToolContext): string {
  if (!context.authenticated || context.selfUid.length === 0) {
    return '【当前登录账号】\n未登录。站内 NGA 工具不可用；需要时请提示用户先登录。'
  }
  const name: string = context.selfUserName.length > 0 ? '，用户名「' + context.selfUserName + '」' : ''
  return '【当前登录账号】\nuid=' + context.selfUid + name +
    '\n问"我"相关的问题时，可以省略 uid 参数直接调用站内工具。'
}

/**
 * 构造"工具可用性"段落。
 *
 * 这是把契约显式声明给模型的关键：可用工具在 `tools` 参数里，
 * 被依赖挡住的工具如果完全不提，模型会误以为客户端没有这个能力。
 *
 * @param context - 工具执行上下文
 * @param available - 当前可用工具名
 * @returns 文本
 */
function buildToolSection(context: AiToolContext, available: string[]): string {
  const readyLines: string[] = []
  const blockedLines: string[] = []
  for (let i: number = 0; i < AI_TOOL_CATALOG.length; i++) {
    const meta: AiToolMeta = AI_TOOL_CATALOG[i]
    if (meta.name === TOOL_NAME) {
      continue
    }
    if (!isAiToolEnabled(context.tools, meta.name) || !presetAllowsTool(context.preset, meta.name)) {
      continue
    }
    if (available.indexOf(meta.name) >= 0) {
      readyLines.push('- ' + aiToolTitle(meta.name) + '（' + meta.name + '）')
      continue
    }
    blockedLines.push('- ' + aiToolTitle(meta.name) + '（' + meta.name + '）：' +
      unavailableReason(meta, context))
  }

  const parts: string[] = []
  // 预算必须让模型在**规划时**就知道，而不是等它撞上「该工具未执行」才发现。
  // 这里能从常量单点派生，是 get_context 存在的意义：把客户端契约显式声明给模型。
  parts.push('【可用工具】\n' + (readyLines.length > 0 ? readyLines.join('\n') : '（无）') +
    '\n本次运行最多可调用工具 ' + DEFAULT_MAX_TOOL_CALLS_PER_RUN.toString() +
    ' 次；请在取数上有所取舍，优先获取回答所必需的数据。')
  if (blockedLines.length > 0) {
    parts.push('【暂不可用的工具】\n' + blockedLines.join('\n') +
      '\n这些工具因登录态或配置缺失不可用：不要假装调用，也不要声称自己"没有这个能力"，' +
      '可以告诉用户缺什么（例如先登录、去「AI 配置 → 搜索服务」填密钥）。')
  }
  return parts.join('\n\n')
}

/**
 * 计算单个工具不可用的原因。
 *
 * @param meta - 工具元数据
 * @param context - 工具执行上下文
 * @returns 原因文案
 */
function unavailableReason(meta: AiToolMeta, context: AiToolContext): string {
  if (meta.requires === TOOL_REQUIRES_LOGIN) {
    return '需要登录 NGA 账号'
  }
  if (meta.requires === TOOL_REQUIRES_SEARCH) {
    const search: AiSearchProfile | null = context.search
    if (search === null) {
      return '未配置搜索服务'
    }
    const provider: AiSearchProvider = aiSearchProviderRegistry.get(search.providerKind)
    return provider.isAvailable(search) ? '暂不可用' : provider.getUnavailableHint()
  }
  return '暂不可用'
}
