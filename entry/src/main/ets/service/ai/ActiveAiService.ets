/**
 * 当前激活 AI 配置的调用门面。
 *
 * 页面只依赖这里：配置校验、任务提示词、工具上下文装配、Agent 循环、
 * 工具时间线、错误文案全部收敛在本层。协议差异在 AiChatClient 里分流，
 * 页面不感知 Responses / Chat Completions。
 */

import { appStore } from '../../store/AppStore'
import { AiProviderProfile } from '../../model/AiConfig'
import { AiSearchProfile } from '../../model/AiSearchConfig'
import {
  AI_TOOL_CATALOG,
  AiToolMeta,
  TOOL_REQUIRES_LOGIN,
  TOOL_REQUIRES_SEARCH,
  isAiToolEnabled
} from '../../model/AiToolConfig'
import {
  AiAgentPreset,
  AiTaskContext,
  buildContextPreamble,
  presetAllowsTool,
  resolvePresetPrompt
} from '../../model/AiAgentPreset'
import { ChatMessage, RequestCanceller } from './AiProtocolTypes'
import { runAiAgent, AiAgentOptions, AiAgentResult } from './AiAgentRunner'
import { AiToolCard, AiToolContext, AiToolInvocation, AiToolSource } from './tools/AiToolAdapter'
import { aiToolRegistry } from './tools/ToolRegistry'
import { aiSearchProviderRegistry } from './search/SearchProviderRegistry'
import { AiSearchProvider } from './search/AiSearchProvider'
import { translateError } from './AiErrorTranslator'
import { Logger, DOMAIN_SERVICE } from '../../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'ActiveAiService')

/** AI 处理阶段状态回调。 */
export type ChatStatusCallback = (status: string) => void

/**
 * 工具调用时间线回调。
 *
 * 每次工具开始执行、执行完成或失败时回调一次，携带当前完整时间线快照，
 * 页面直接整体替换即可（避免局部合并导致的状态漏更新）。
 */
export type ToolInvocationCallback = (invocations: AiToolInvocation[]) => void

/** 对话调用结果。 */
export class AiChatResult {
  /** 助手回复完整文本 */
  text: string = ''
  /** 思维链文本（模型支持时非空） */
  reasoning: string = ''
  /** 本响应的输出 items（Responses 历史回传用） */
  outputItems: Object[] = []
  /** 是否因达到服务端输出长度上限被截断 */
  truncated: boolean = false
  /** 工具调用时间线 */
  toolInvocations: AiToolInvocation[] = []
  /** 引用来源（搜索 / 抓取结果） */
  sources: AiToolSource[] = []
  /** 可点击卡片（帖子 / 版块 / 用户） */
  cards: AiToolCard[] = []
  /** 是否因工具轮数上限被强制收尾 */
  hitStepLimit: boolean = false
  /**
   * 本次文本是否为本机生成的兜底文案（模型没有产出内容时）。
   *
   * 页面据此标记气泡，避免把本机提示当成模型回复写回历史。
   */
  localFallback: boolean = false
}

/**
 * 获取当前激活的 AI 配置。
 *
 * @returns 当前激活配置，若未选择或配置不存在则返回 null
 */
export function getActiveAiProfile(): AiProviderProfile | null {
  return appStore.settingsStore.getActiveAiProfile()
}

/**
 * 获取当前 AI 配置不可用时的用户提示。
 *
 * @returns 空字符串表示配置可用，否则为用户可读的错误提示
 */
export function getActiveAiValidationMessage(): string {
  const profile: AiProviderProfile | null = getActiveAiProfile()
  if (!profile) {
    if (appStore.settings.aiProfiles.length === 0) {
      return '请先在设置中添加 AI 配置'
    }
    return '请先在设置中选择 AI 配置'
  }
  if (profile.endpoint.trim().length === 0) {
    return '请先在 AI 配置中填写服务地址'
  }
  if (profile.modelName.trim().length === 0) {
    return '请先在 AI 配置中填写模型名称'
  }
  if (profile.apiKey.trim().length === 0) {
    return '请先在 AI 配置中填写 API 密钥'
  }
  return ''
}

/**
 * 装配一次工具执行上下文。
 *
 * 工具是全局能力：这里只读全局开关、登录态与激活的搜索服务，
 * 不再看任何按模型区分的工具字段。
 *
 * @param preset - 当前任务（可为 null）
 * @param taskContext - 页面上下文（帖子 / 用户 / 版块标识）
 * @returns 工具执行上下文
 */
export function buildToolContext(preset: AiAgentPreset | null,
  taskContext: AiTaskContext): AiToolContext {
  const context: AiToolContext = new AiToolContext()
  const profile: AiProviderProfile | null = getActiveAiProfile()
  if (profile !== null) {
    context.chat = profile
  }
  context.search = appStore.settingsStore.getActiveAiSearchProfile()
  context.tools = appStore.settingsStore.getAiToolSettings()
  context.preset = preset
  context.taskContext = taskContext
  context.token = appStore.auth.token
  context.authenticated = appStore.auth.isAuthenticated
  // "读我自己"类工具的兜底身份：没有页面上下文时也能查当前登录账号
  context.selfUid = appStore.auth.uid
  context.selfUserName = appStore.auth.nickName
  return context
}

/**
 * 当前上下文下已就绪的工具名。
 *
 * @param preset - 当前任务（可为 null）
 * @param taskContext - 页面上下文
 * @returns 工具名数组
 */
export function getReadyToolNames(preset: AiAgentPreset | null,
  taskContext: AiTaskContext): string[] {
  return aiToolRegistry.getAvailableNames(buildToolContext(preset, taskContext))
}

/**
 * 获取工具可用性提示（不阻断对话，仅用于 UI 提示）。
 *
 * @returns 空字符串表示全部依赖就绪；否则为提示文案
 */
export function getToolAvailabilityHint(): string {
  const problems: string[] = []
  if (!appStore.auth.isAuthenticated) {
    problems.push('未登录，站内工具不可用')
  }
  const settings = appStore.settingsStore.getAiToolSettings()
  const needsSearch: boolean = isAiToolEnabled(settings, 'web_search') ||
    isAiToolEnabled(settings, 'web_fetch')
  if (needsSearch) {
    const search: AiSearchProfile | null = appStore.settingsStore.getActiveAiSearchProfile()
    if (search === null) {
      problems.push('未配置搜索服务，联网工具暂不可用')
    } else {
      const provider: AiSearchProvider = aiSearchProviderRegistry.get(search.providerKind)
      if (!provider.isAvailable(search)) {
        problems.push(provider.getUnavailableHint())
      }
    }
  }
  return problems.join('；')
}

/**
 * 使用当前激活配置发起带工具能力的对话。
 *
 * 模型可以多轮请求工具（NGA 站内 + 联网），客户端执行后回传，
 * 直到产出最终回答或用完工具轮数。
 *
 * @param messages - 对话消息列表
 * @param onDelta - 文本增量回调
 * @param onStatus - 可选的状态更新回调
 * @param onToolCall - 可选的工具时间线回调
 * @param canceller - 可选的请求取消令牌
 * @param preset - 可选的任务（决定提示词与工具白名单）
 * @param taskContext - 可选的页面上下文
 * @returns 对话结果
 */
export async function chatCompleteWithActiveAiStream(
  messages: ChatMessage[],
  onDelta: (chunk: string) => void,
  onStatus?: ChatStatusCallback,
  onToolCall?: ToolInvocationCallback,
  canceller?: RequestCanceller,
  preset?: AiAgentPreset | null,
  taskContext?: AiTaskContext
): Promise<AiChatResult> {
  const profile: AiProviderProfile | null = getActiveAiProfile()
  const validationMessage: string = getActiveAiValidationMessage()
  if (!profile || validationMessage.length > 0) {
    throw new Error(validationMessage.length > 0 ? validationMessage : '请先在设置中选择 AI 配置')
  }

  const effectivePreset: AiAgentPreset | null = preset ?? null
  const effectiveContext: AiTaskContext = taskContext ?? new AiTaskContext()
  const toolContext: AiToolContext = buildToolContext(effectivePreset, effectiveContext)

  // 任务提示词 + 上下文说明 + 工具可用性：放在 system 消息里，
  // 正文数据仍由模型调用工具读取
  const conversation: ChatMessage[] = buildConversation(
    messages, effectivePreset, effectiveContext, toolContext)

  const invocations: AiToolInvocation[] = []
  const options: AiAgentOptions = new AiAgentOptions()
  options.onDelta = onDelta
  options.onStatus = (status: string): void => {
    onStatus?.(status)
  }
  options.onToolInvocation = (invocation: AiToolInvocation): void => {
    replaceInvocation(invocations, invocation)
    onToolCall?.(copyInvocations(invocations))
  }
  options.canceller = canceller ?? null

  const agentResult: AiAgentResult = await runAiAgent(profile, toolContext, conversation, options)

  const result: AiChatResult = new AiChatResult()
  result.text = agentResult.text
  result.reasoning = agentResult.reasoning
  // 工具调用轮次的中间 items 不跨轮保留：最终回答已包含工具结论，
  // 页面历史回传使用纯文本即可（两种协议都能接受）。
  result.outputItems = []
  result.truncated = agentResult.truncated
  result.toolInvocations = agentResult.toolInvocations
  result.sources = agentResult.sources
  result.cards = agentResult.cards
  result.hitStepLimit = agentResult.hitStepLimit

  if (result.text.trim().length === 0) {
    const failureText: string = buildEmptyAnswerText(agentResult)
    result.text = failureText
    result.localFallback = true
    onDelta(failureText)
  }
  logger.info('chatComplete done: text=%d chars, tools=%d, cards=%d, truncated=%s',
    result.text.length, result.toolInvocations.length, result.cards.length, String(result.truncated))
  return result
}

/**
 * 组装最终发给模型的对话：system（任务提示词 + 上下文说明 + 工具可用性）+ 历史。
 *
 * 已有 system 消息时把内容合并进去，避免部分服务商只接受单条 system。
 *
 * @param messages - 页面历史
 * @param preset - 任务（可为 null）
 * @param context - 页面上下文
 * @param toolContext - 工具执行上下文（用于计算工具可用性）
 * @returns 组装后的消息
 */
function buildConversation(messages: ChatMessage[], preset: AiAgentPreset | null,
  context: AiTaskContext, toolContext: AiToolContext): ChatMessage[] {
  const systemParts: string[] = []
  if (preset !== null) {
    const prompt: string = resolvePresetPrompt(preset, appStore.settings.scenarioSystemPrompts)
    if (prompt.trim().length > 0) {
      systemParts.push(prompt.trim())
    }
  }
  const preamble: string = buildContextPreamble(context, preset)
  if (preamble.length > 0) {
    systemParts.push(preamble)
  }
  // 工具声明：可用工具由 tools 参数声明；这里补上"存在但当前不可用"的工具，
  // 避免模型把能力缺失误判成"没有这个功能"。
  const unavailableHint: string = buildUnavailableToolsHint(toolContext)
  if (unavailableHint.length > 0) {
    systemParts.push(unavailableHint)
  }

  const result: ChatMessage[] = []
  let systemMerged: boolean = false
  for (let i: number = 0; i < messages.length; i++) {
    const src: ChatMessage = messages[i]
    if (src.role === 'system' && !systemMerged && systemParts.length > 0) {
      const merged: string = systemParts.join('\n\n') + '\n\n' + src.content
      result.push(new ChatMessage('system', merged))
      systemMerged = true
      continue
    }
    result.push(src)
  }
  if (!systemMerged && systemParts.length > 0) {
    result.unshift(new ChatMessage('system', systemParts.join('\n\n')))
  }
  return result
}

/**
 * 生成「存在但当前不可用」的工具说明。
 *
 * 这是把工具能力显式声明给模型的关键一环：可用工具在 tools 参数里，
 * 而被依赖挡住的工具如果完全不提，模型会以为客户端没有这个能力。
 *
 * @param context - 工具执行上下文
 * @returns 说明文本，无不可用工具时为空串
 */
function buildUnavailableToolsHint(context: AiToolContext): string {
  const available: string[] = aiToolRegistry.getAvailableNames(context)
  const lines: string[] = []
  for (let i: number = 0; i < AI_TOOL_CATALOG.length; i++) {
    const meta: AiToolMeta = AI_TOOL_CATALOG[i]
    if (!isAiToolEnabled(context.tools, meta.name)) {
      continue
    }
    if (!presetAllowsTool(context.preset, meta.name)) {
      continue
    }
    if (available.indexOf(meta.name) >= 0) {
      continue
    }
    lines.push('- ' + meta.title + '（' + meta.name + '）：' + unavailableToolReason(meta, context))
  }
  if (lines.length === 0) {
    return ''
  }
  return '【暂不可用的工具】\n' + lines.join('\n') + '\n' +
    '这些工具因登录态或配置缺失不可用：不要假装调用，也不要声称自己"没有这个能力"，' +
    '可以告诉用户缺什么（例如先登录、去「AI 配置 → 搜索服务」填密钥）。'
}

/**
 * 计算单个工具不可用的原因。
 *
 * @param meta - 工具元数据
 * @param context - 工具执行上下文
 * @returns 原因文案
 */
function unavailableToolReason(meta: AiToolMeta, context: AiToolContext): string {
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

/**
 * 在时间线中替换同名同 ID 的记录，不存在则追加。
 *
 * @param invocations - 时间线
 * @param invocation - 新记录
 */
function replaceInvocation(invocations: AiToolInvocation[], invocation: AiToolInvocation): void {
  for (let i: number = 0; i < invocations.length; i++) {
    if (invocations[i].id === invocation.id) {
      invocations[i] = invocation
      return
    }
  }
  invocations.push(invocation)
}

/**
 * 拷贝时间线，避免页面状态与内部数组共享引用。
 *
 * @param invocations - 时间线
 * @returns 拷贝
 */
function copyInvocations(invocations: AiToolInvocation[]): AiToolInvocation[] {
  const result: AiToolInvocation[] = []
  for (let i: number = 0; i < invocations.length; i++) {
    result.push(invocations[i])
  }
  return result
}

/**
 * 构造空回答时的用户可读文案。
 *
 * @param agentResult - Agent 结果
 * @returns 文案
 */
function buildEmptyAnswerText(agentResult: AiAgentResult): string {
  if (agentResult.toolInvocations.length > 0) {
    let reason: string = ''
    for (let i: number = 0; i < agentResult.toolInvocations.length; i++) {
      if (agentResult.toolInvocations[i].errorMessage.length > 0) {
        reason = agentResult.toolInvocations[i].errorMessage
        break
      }
    }
    if (reason.length > 0) {
      return '工具执行失败：' + reason + '\n\n我没有获取到可用信息，因此不会基于未确认的内容继续推断。'
    }
    return '工具执行完成，但模型没有给出回答。可以换一种问法重试。'
  }
  return 'AI 没有返回内容，请稍后重试。'
}

/**
 * 将 AI 调用异常转换为页面展示文案。
 *
 * 错误消息可能携带服务端 error.message（格式: "<状态码>\n<详情>"），
 * 有则一并展示给用户。
 *
 * @param err - 调用异常
 * @returns 用户可读错误信息
 */
export function formatAiCompletionError(err: Error): string {
  if (err.message === '请求已取消') {
    return '已停止生成'
  }
  const code: number = parseInt(err.message)
  if (!isNaN(code)) {
    const info = translateError(code, err.message)
    const newlineIndex: number = err.message.indexOf('\n')
    const detail: string = newlineIndex >= 0 ? err.message.substring(newlineIndex + 1).trim() : ''
    return info.userMessage + '\n' + info.suggestion + (detail.length > 0 ? '\n\n服务端信息：' + detail : '')
  }
  if (err.message.length > 0 && err.message.indexOf('请先') === 0) {
    return err.message
  }
  if (err.message.length > 0 && err.message.indexOf('回答超长') === 0) {
    return err.message
  }
  return 'AI 调用失败：' + (err.message || '未知错误')
}
