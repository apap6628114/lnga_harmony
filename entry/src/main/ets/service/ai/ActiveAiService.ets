/**
 * 当前激活 AI 配置的调用门面。
 *
 * 页面只依赖这里：配置校验、Agent 循环、工具时间线、错误文案全部收敛在本层。
 * 协议差异在 AiChatClient 里分流，页面不感知 Responses / Chat Completions。
 */

import { appStore } from '../../store/AppStore'
import {
  AiProviderProfile,
  hasToolSwitchesOn
} from '../../model/AiConfig'
import { AiSearchProfile } from '../../model/AiSearchConfig'
import { ChatMessage, RequestCanceller } from './AiProtocolTypes'
import { runAiAgent, AiAgentOptions, AiAgentResult } from './AiAgentRunner'
import { AiToolInvocation, AiToolSource } from './tools/AiToolAdapter'
import { aiSearchProviderRegistry } from './search/SearchProviderRegistry'
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
 * 获取当前配置的工具可用性提示（不阻断对话，仅用于 UI 提示）。
 *
 * @returns 空字符串表示工具可用；否则为提示文案
 */
export function getToolAvailabilityHint(): string {
  const profile: AiProviderProfile | null = getActiveAiProfile()
  if (!profile || !hasToolSwitchesOn(profile)) {
    return ''
  }
  const search: AiSearchProfile | null = appStore.settingsStore.getActiveAiSearchProfile()
  if (search === null) {
    return '请先在「搜索服务」中添加并激活一套配置'
  }
  const provider = aiSearchProviderRegistry.get(search.providerKind)
  if (provider.isAvailable(search)) {
    return ''
  }
  return provider.getUnavailableHint()
}

/**
 * 使用当前激活配置发起带工具能力的对话。
 *
 * 模型可以多轮请求 web_search / web_fetch，客户端执行后回传，
 * 直到产出最终回答或用完工具轮数。
 *
 * @param messages - 对话消息列表
 * @param onDelta - 文本增量回调
 * @param onStatus - 可选的状态更新回调
 * @param onToolCall - 可选的工具时间线回调
 * @param canceller - 可选的请求取消令牌
 * @returns 对话结果
 */
export async function chatCompleteWithActiveAiStream(
  messages: ChatMessage[],
  onDelta: (chunk: string) => void,
  onStatus?: ChatStatusCallback,
  onToolCall?: ToolInvocationCallback,
  canceller?: RequestCanceller
): Promise<AiChatResult> {
  const profile: AiProviderProfile | null = getActiveAiProfile()
  const validationMessage: string = getActiveAiValidationMessage()
  if (!profile || validationMessage.length > 0) {
    throw new Error(validationMessage.length > 0 ? validationMessage : '请先在设置中选择 AI 配置')
  }

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

  const agentResult: AiAgentResult = await runAiAgent(
    profile, appStore.settingsStore.getActiveAiSearchProfile(), messages, options)

  const result: AiChatResult = new AiChatResult()
  result.text = agentResult.text
  result.reasoning = agentResult.reasoning
  // 工具调用轮次的中间 items 不跨轮保留：最终回答已包含工具结论，
  // 页面历史回传使用纯文本即可（两种协议都能接受）。
  result.outputItems = []
  result.truncated = agentResult.truncated
  result.toolInvocations = agentResult.toolInvocations
  result.sources = agentResult.sources
  result.hitStepLimit = agentResult.hitStepLimit

  if (result.text.trim().length === 0) {
    const failureText: string = buildEmptyAnswerText(agentResult)
    result.text = failureText
    result.localFallback = true
    onDelta(failureText)
  }
  logger.info('chatComplete done: text=%d chars, tools=%d, truncated=%s',
    result.text.length, result.toolInvocations.length, String(result.truncated))
  return result
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
