/**
 * Agent 循环。
 *
 * 一次用户提问可能触发多轮「模型请求工具 → 客户端执行 → 结果回传 → 继续生成」。
 * 本模块负责这个循环，并把每次工具调用以 AiToolInvocation 形式推给 UI。
 *
 * 约束：
 * - 工具轮数受 profile.maxAgentSteps 限制，超限后发一次不带工具的收尾请求；
 * - 每轮都可取消，取消后立即中断且不再执行后续工具；
 * - 模型输出始终按不可信输入处理（工具参数解析失败不抛异常）。
 */

import { AiProviderProfile } from '../../model/AiConfig'
import { AiSearchProfile } from '../../model/AiSearchConfig'
import {
  ChatMessage,
  ChatStreamChunkCallback,
  ChatTurnOptions,
  ChatTurnResult,
  RequestCanceller,
  ReasoningStreamCallback,
  ToolCall
} from './AiProtocolTypes'
import { requestChatByProtocol } from './AiChatClient'
import { aiToolRegistry } from './tools/ToolRegistry'
import { AiToolInvocation, AiToolContext, AiToolResult, AiToolSource } from './tools/AiToolAdapter'
import { Logger, DOMAIN_SERVICE } from '../../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'AiAgentRunner')

/** 状态文案回调。 */
export type AiStatusCallback = (status: string) => void

/** 工具调用记录回调。 */
export type AiToolInvocationCallback = (invocation: AiToolInvocation) => void

/** Agent 运行选项。 */
export class AiAgentOptions {
  /** 正文增量回调 */
  onDelta: ChatStreamChunkCallback = (_chunk: string): void => {
  }
  /** 思维链增量回调 */
  onReasoning: ReasoningStreamCallback = (_chunk: string): void => {
  }
  /** 阶段状态回调 */
  onStatus: AiStatusCallback = (_status: string): void => {
  }
  /** 工具调用记录回调 */
  onToolInvocation: AiToolInvocationCallback = (_invocation: AiToolInvocation): void => {
  }
  /** 取消令牌 */
  canceller: RequestCanceller | null = null
}

/** Agent 运行结果。 */
export class AiAgentResult {
  /** 全文 */
  text: string = ''
  /** 思维链全文 */
  reasoning: string = ''
  /** 实际执行的工具轮数 */
  steps: number = 0
  /** 工具调用记录 */
  toolInvocations: AiToolInvocation[] = []
  /** 去重后的引用来源 */
  sources: AiToolSource[] = []
  /** 是否被输出上限截断 */
  truncated: boolean = false
  /** 是否因工具轮数上限被强制收尾 */
  hitStepLimit: boolean = false
}

/**
 * 运行 Agent 循环。
 *
 * @param profile - 对话配置
 * @param searchProfile - 激活的搜索配置（未配置时为 null）
 * @param history - 对话历史（system / user / assistant）
 * @param options - 运行选项
 * @returns Agent 结果
 */
export async function runAiAgent(
  profile: AiProviderProfile,
  searchProfile: AiSearchProfile | null,
  history: ChatMessage[],
  options: AiAgentOptions
): Promise<AiAgentResult> {
  const result: AiAgentResult = new AiAgentResult()
  const conversation: ChatMessage[] = copyMessages(history)
  const context: AiToolContext = new AiToolContext()
  context.chat = profile
  context.search = searchProfile
  const tools = aiToolRegistry.getDefinitions(context)
  const fallbackQuery: string = findLastUserMessage(conversation)
  const maxSteps: number = Math.max(1, profile.maxAgentSteps)
  const sourceKeys: Record<string, boolean> = {}

  let step: number = 0
  let hitLimit: boolean = false

  while (true) {
    if (isCancelled(options.canceller)) {
      throw new Error('请求已取消')
    }

    const useTools: boolean = tools.length > 0 && step < maxSteps
    if (tools.length > 0 && step >= maxSteps) {
      hitLimit = true
    }

    const turnOptions: ChatTurnOptions = new ChatTurnOptions()
    turnOptions.stream = true
    turnOptions.tools = useTools ? tools : []
    turnOptions.onDelta = options.onDelta
    turnOptions.onReasoning = options.onReasoning

    options.onStatus(step === 0 ? 'AI 正在思考...' : 'AI 正在整理回答...')
    const turn: ChatTurnResult = await requestChatByProtocol(profile, conversation, turnOptions,
      options.canceller === null ? undefined : options.canceller)

    if (turn.truncated) {
      result.truncated = true
    }
    if (turn.text.length > 0) {
      result.text += turn.text
    }
    if (turn.reasoning.length > 0) {
      result.reasoning += turn.reasoning
    }

    if (turn.toolCalls.length === 0) {
      break
    }
    if (!useTools) {
      // 不带工具仍然返回 tool_calls：视为服务商行为异常，停止循环避免死锁
      hitLimit = true
      break
    }

    const assistantMsg: ChatMessage = new ChatMessage('assistant', turn.text)
    assistantMsg.toolCalls = turn.toolCalls
    assistantMsg.outputItems = turn.outputItems
    assistantMsg.reasoning = turn.reasoning
    conversation.push(assistantMsg)

    for (let i: number = 0; i < turn.toolCalls.length; i++) {
      if (isCancelled(options.canceller)) {
        throw new Error('请求已取消')
      }
      const call: ToolCall = turn.toolCalls[i]
      const execution: ToolExecution = await executeToolCall(call, context, fallbackQuery, options)
      const invocation: AiToolInvocation = execution.invocation
      const toolResult: AiToolResult = execution.result
      invocation.status = toolResult.success ? 'success' : 'failed'
      invocation.count = toolResult.count
      invocation.errorMessage = toolResult.errorMessage
      invocation.sources = toolResult.sources
      if (toolResult.summary.length > 0) {
        invocation.summary = toolResult.summary
      }
      options.onToolInvocation(invocation)
      result.toolInvocations.push(invocation)
      appendSources(result.sources, sourceKeys, toolResult.sources)

      const toolMsg: ChatMessage = new ChatMessage('tool', toolResult.content)
      toolMsg.toolCallId = call.id
      toolMsg.name = call.function.name
      conversation.push(toolMsg)
    }

    step++
  }

  result.steps = step
  result.hitStepLimit = hitLimit
  logger.info('runAiAgent done: steps=%d, tools=%d, text=%d chars, limit=%s',
    step, result.toolInvocations.length, result.text.length, String(hitLimit))
  return result
}

/** 一次工具执行的结果组合。 */
class ToolExecution {
  /** UI 记录 */
  invocation: AiToolInvocation = new AiToolInvocation()
  /** 工具结果 */
  result: AiToolResult = new AiToolResult()
}

/**
 * 执行单次工具调用并推送「开始执行」记录。
 *
 * @param call - 工具调用
 * @param context - 工具执行上下文
 * @param fallbackQuery - 兜底查询
 * @param options - 运行选项
 * @returns 工具执行结果组合
 */
async function executeToolCall(
  call: ToolCall,
  context: AiToolContext,
  fallbackQuery: string,
  options: AiAgentOptions
): Promise<ToolExecution> {
  const execution: ToolExecution = new ToolExecution()
  const invocation: AiToolInvocation = execution.invocation
  invocation.id = call.id
  invocation.name = call.function.name
  invocation.displayName = toolDisplayName(call.function.name)
  invocation.summary = call.function.arguments
  invocation.status = 'running'
  options.onToolInvocation(invocation)
  options.onStatus(invocation.displayName + '中...')

  const startTime: number = Date.now()
  execution.result = await aiToolRegistry.execute(
    call.function.name, call.function.arguments, context, fallbackQuery)
  invocation.durationMs = Date.now() - startTime
  return execution
}

/**
 * 判断是否已取消。
 *
 * @param canceller - 取消令牌
 * @returns true 表示已取消
 */
function isCancelled(canceller: RequestCanceller | null): boolean {
  return canceller !== null && canceller.isCancelled()
}

/**
 * 工具展示名。
 *
 * @param name - 工具名称
 * @returns 展示名
 */
function toolDisplayName(name: string): string {
  if (name === 'web_search') {
    return '联网搜索'
  }
  if (name === 'web_fetch') {
    return '网页抓取'
  }
  return name
}

/**
 * 查找最后一条用户消息，作为工具参数缺失时的兜底查询。
 *
 * @param messages - 对话消息
 * @returns 用户消息文本
 */
function findLastUserMessage(messages: ChatMessage[]): string {
  for (let i: number = messages.length - 1; i >= 0; i--) {
    if (messages[i].role === 'user' && messages[i].content.trim().length > 0) {
      const text: string = messages[i].content.trim()
      return text.length > 500 ? text.substring(0, 500) : text
    }
  }
  return ''
}

/**
 * 追加去重后的引用来源。
 *
 * @param target - 目标列表
 * @param seen - 已见 URL 集合
 * @param sources - 新增来源
 */
function appendSources(target: AiToolSource[], seen: Record<string, boolean>, sources: AiToolSource[]): void {
  for (let i: number = 0; i < sources.length; i++) {
    const source: AiToolSource = sources[i]
    if (source.url.length === 0 || seen[source.url] === true) {
      continue
    }
    seen[source.url] = true
    target.push(source)
  }
}

/**
 * 复制对话消息数组（浅拷贝：toolCalls / outputItems 共享引用）。
 *
 * Agent 循环只会给数组追加新消息、不修改已有消息的字段，
 * 因此共享内部数组是安全的；这里避免深拷贝带来的额外内存开销。
 *
 * @param messages - 原始消息
 * @returns 拷贝后的消息
 */
function copyMessages(messages: ChatMessage[]): ChatMessage[] {
  const result: ChatMessage[] = []
  for (let i: number = 0; i < messages.length; i++) {
    const src: ChatMessage = messages[i]
    const dest: ChatMessage = new ChatMessage(src.role, src.content)
    dest.toolCalls = src.toolCalls
    dest.toolCallId = src.toolCallId
    dest.name = src.name
    dest.outputItems = src.outputItems
    dest.reasoning = src.reasoning
    result.push(dest)
  }
  return result
}
