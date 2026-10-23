/**
 * Agent 循环。
 *
 * 一次用户提问可能触发多轮「模型请求工具 → 客户端执行 → 结果回传 → 继续生成」。
 * 本模块负责这个循环，并把每次工具调用以 AiToolInvocation 形式推给 UI。
 *
 * 约束：
 * - 工具轮数受全局工具设置 `tools.maxAgentSteps` 限制，超限后发一次不带工具的收尾请求；
 * - 单次运行的**工具调用次数**受 `DEFAULT_MAX_TOOL_CALLS_PER_RUN` 硬限制（与轮数是两个维度：
 *   一轮里模型可以一次返回多个 tool_calls）。超限时剩余调用不再执行，但**仍为每一条
 *   补 tool 消息**——少一条会让对话结构与 tool_calls 不匹配，OpenAI 兼容服务端直接 400；
 * - 每轮都可取消，取消后立即中断且不再执行后续工具；
 * - 模型输出始终按不可信输入处理（工具参数解析失败不抛异常）。
 */

import { AiProviderProfile } from '../../model/AiConfig'
import { DEFAULT_MAX_TOOL_CALLS_PER_RUN, aiToolTitle } from '../../model/AiToolConfig'
import {
  AiTokenUsage,
  ChatMessage,
  ChatStreamChunkCallback,
  ChatTurnOptions,
  ChatTurnResult,
  RequestCanceller,
  ReasoningStreamCallback,
  ToolCall
} from './AiProtocolTypes'
import { requestChatByProtocol } from './AiChatClient'
import {
  ToolContentFit,
  estimateConversationTokens,
  estimateMessageTokens,
  estimateTextTokens,
  estimateToolDefinitionsTokens,
  fitToolResultContent
} from './ContextBudget'
import { aiToolRegistry } from './tools/ToolRegistry'
import { ToolResultArchive } from './tools/ToolResultArchive'
import {
  FRESHNESS_AUTO,
  normalizeToolArguments,
  readFreshnessFromText
} from './tools/ToolResultCache'
import {
  AiToolInvocation,
  AiToolContext,
  AiToolCard,
  AiToolResult,
  AiToolSource,
  TOOL_ERROR_BUDGET_EXHAUSTED,
  TOOL_ERROR_RATE_LIMITED
} from './tools/AiToolAdapter'
import { Logger, DOMAIN_SERVICE } from '../../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'AiAgentRunner')

/** 跳过原因：调用次数预算用尽。 */
const SKIP_REASON_CALLS: string = 'calls'

/** 跳过原因：工具结果体积预算用尽。 */
const SKIP_REASON_VOLUME: string = 'volume'

/** 跳过原因：已触发接口频率限制。 */
const SKIP_REASON_THROTTLE: string = 'throttle'

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
  /**
   * 每轮用量回调。
   *
   * 用途：超窗重试时第一次运行的用量会随异常丢失，调用方可以在这里先累计，
   * 重试成功后再合并进最终结果（否则计费统计与校准样本都少一轮）。
   */
  onUsage: (usage: AiTokenUsage) => void = (_usage: AiTokenUsage): void => {
  }
  /** 取消令牌 */
  canceller: RequestCanceller | null = null
  /**
   * 工具结果可占用的 token 预算（<=0 表示不限）。
   *
   * 与「工具调用次数」是两个维度：次数限制的是**发出去多少请求**，这里限制的是
   * **回传给模型的工具体积**。长会话的真实超窗风险几乎都来自后者——一次读帖
   * 一页 20 楼，单条结果就可能吃掉整个历史预算。
   */
  toolResultTokenBudget: number = 0
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
  /** 去重后的可点击卡片 */
  cards: AiToolCard[] = []
  /** 是否被输出上限截断 */
  truncated: boolean = false
  /** 是否因工具轮数上限被强制收尾 */
  hitStepLimit: boolean = false
  /** 是否因单次运行的调用预算用尽而提前收尾 */
  hitToolBudget: boolean = false
  /** 是否因工具结果体积预算用尽而提前收尾 */
  hitContextBudget: boolean = false
  /** 整个 Agent 循环累计的 token 用量（各轮之和） */
  usage: AiTokenUsage = new AiTokenUsage()
  /** 最终对话（system + 历史 + 工具结果）的估算 token 总量 */
  contextTokens: number = 0
  /** 回传给模型的工具结果估算 token 总量 */
  toolTokens: number = 0
  /** 工具声明（tools schema）估算 token 量 */
  toolSchemaTokens: number = 0
  /** 是否有工具结果被压缩 */
  toolCompressed: boolean = false
  /**
   * 最后一轮请求**发出前**的本地估算（校准样本）。
   *
   * 与 {@link lastActualPromptTokens} 配对，用来估计"本地估算 / 真实 token"的偏差。
   */
  lastEstimatedPromptTokens: number = 0
  /** 最后一轮请求服务端返回的真实 promptTokens（校准样本） */
  lastActualPromptTokens: number = 0
}

/**
 * 运行 Agent 循环。
 *
 * @param profile - 对话配置
 * @param toolContext - 工具执行上下文（含全局工具设置、任务、登录态、页面上下文）
 * @param history - 对话历史（system / user / assistant）
 * @param options - 运行选项
 * @returns Agent 结果
 */
export async function runAiAgent(
  profile: AiProviderProfile,
  toolContext: AiToolContext,
  history: ChatMessage[],
  options: AiAgentOptions
): Promise<AiAgentResult> {
  const result: AiAgentResult = new AiAgentResult()
  const conversation: ChatMessage[] = copyMessages(history)
  const tools = aiToolRegistry.getDefinitions(toolContext)
  /*
   * 大结果外置：归档只服务本次运行。工具结果超出预算时，完整正文留在这里，
   * 上下文只放头部 + result_id，模型可用 expand_tool_result 续读。
   */
  const archive: ToolResultArchive = new ToolResultArchive()
  toolContext.archive = archive
  const fallbackQuery: string = findLastUserMessage(conversation)
  const maxSteps: number = Math.max(1, toolContext.tools.maxAgentSteps)
  const sourceKeys: Record<string, boolean> = {}
  const cardKeys: Record<string, boolean> = {}
  /** 已成功执行过的调用签名（避免模型同参数反复取数） */
  const executedSignatures: Record<string, boolean> = {}

  let step: number = 0
  let hitLimit: boolean = false
  /** 已执行的工具调用数（预算核算用） */
  let executedCalls: number = 0
  /** 调用预算是否已用尽 */
  let budgetExhausted: boolean = false
  /** 工具结果体积预算是否已用尽 */
  let volumeExhausted: boolean = false
  /** 是否已触发风控（触发后本次运行不再发起任何新的取数） */
  let throttled: boolean = false
  /** 当前对话的估算 token 总量（初始 = 工具声明 + system + 历史） */
  let contextTokens: number = estimateConversationTokens(conversation) +
    estimateToolDefinitionsTokens(tools)
  /** 回传给模型的工具结果估算 token 总量 */
  let toolTokens: number = 0
  /** 是否有工具结果被压缩 */
  let toolCompressed: boolean = false
  /** 最后一轮请求前的本地估算（校准样本） */
  let lastEstimatedPrompt: number = 0
  /** 最后一轮请求的真实 promptTokens（校准样本） */
  let lastActualPrompt: number = 0
  /** 工具结果体积预算（<=0 表示不限） */
  const toolBudget: number = options.toolResultTokenBudget

  while (true) {
    if (isCancelled(options.canceller)) {
      throw new Error('请求已取消')
    }

    const useTools: boolean = tools.length > 0 && step < maxSteps && !budgetExhausted &&
      !volumeExhausted && !throttled
    if (tools.length > 0 && step >= maxSteps) {
      hitLimit = true
    }

    const turnOptions: ChatTurnOptions = new ChatTurnOptions()
    turnOptions.stream = true
    turnOptions.tools = useTools ? tools : []
    turnOptions.onDelta = options.onDelta
    turnOptions.onReasoning = options.onReasoning

    options.onStatus(step === 0 ? 'AI 正在思考...' : 'AI 正在整理回答...')
    // 请求发出前的估算值：与返回的 promptTokens 配对，作为一次校准样本
    const estimatedBeforeTurn: number = contextTokens
    const turn: ChatTurnResult = await requestChatByProtocol(profile, conversation, turnOptions,
      options.canceller === null ? undefined : options.canceller)

    if (turn.truncated) {
      result.truncated = true
    }
    if (!turn.usage.isEmpty()) {
      result.usage.add(turn.usage)
      options.onUsage(turn.usage)
      lastEstimatedPrompt = estimatedBeforeTurn
      lastActualPrompt = turn.usage.promptTokens
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
    /* 工具调用轮的 assistant 消息（含 tool_calls 参数）也占输入，必须计入水位 */
    contextTokens += estimateMessageTokens(assistantMsg)

    for (let i: number = 0; i < turn.toolCalls.length; i++) {
      if (isCancelled(options.canceller)) {
        throw new Error('请求已取消')
      }
      const call: ToolCall = turn.toolCalls[i]

      // 预算用尽或已触发风控：不再执行，但仍必须为这条 call 回一条 tool 消息。
      // 少一条会让对话结构不完整，OpenAI 兼容服务端会直接 400
      if (executedCalls >= DEFAULT_MAX_TOOL_CALLS_PER_RUN) {
        budgetExhausted = true
        contextTokens += appendSkippedCall(call, conversation, options, result, SKIP_REASON_CALLS)
        continue
      }
      // 体积预算用尽：继续执行只会把请求推过窗口，模型反而拿不到结果
      if (toolBudget > 0 && contextTokens >= toolBudget) {
        volumeExhausted = true
        contextTokens += appendSkippedCall(call, conversation, options, result, SKIP_REASON_VOLUME)
        continue
      }
      if (throttled) {
        contextTokens += appendSkippedCall(call, conversation, options, result, SKIP_REASON_THROTTLE)
        continue
      }

      /*
       * 重复调用熔断：模型在长循环里经常用完全相同的参数再读一次同一页。
       * 缓存能挡住网络请求，但挡不住上下文里再塞一份同样的正文。
       * 只有 freshness=auto 的调用参与去重；模型明确要 fresh 时允许重取。
       */
      const callSignature: string = buildCallSignature(call)
      if (callSignature.length > 0 && executedSignatures[callSignature] === true) {
        contextTokens += appendDuplicateCall(call, conversation, options, result)
        /*
         * 不计入 executedCalls：这次没有真正取数，占用 30 次调用预算会让
         * 后续真正需要的工具被 budgetExhausted 提前跳过。循环本身仍受
         * maxSteps 约束，重复调用不会无限。
         */
        continue
      }

      const execution: ToolExecution = await executeToolCall(call, toolContext, fallbackQuery, options)
      executedCalls++
      const invocation: AiToolInvocation = execution.invocation
      const toolResult: AiToolResult = execution.result
      if (toolResult.success && toolResult.content.length > 0 && callSignature.length > 0) {
        executedSignatures[callSignature] = true
      }
      /*
       * 工具结果入队前先过体积预算：剩余额度不足时把完整结果归档，
       * 上下文只放头部 + result_id。旧实现直接截断并让模型"同参数重调"，
       * 但重调会命中缓存、拿回同样被截断的开头，等于永久丢信息。
       */
      const remainingTokens: number = toolBudget > 0 ? toolBudget - contextTokens : 0
      let archiveId: string = ''
      if (remainingTokens > 0 && estimateTextTokens(toolResult.content) > remainingTokens) {
        archiveId = archive.put(call.function.name, toolResult.content)
      }
      const fit: ToolContentFit = fitToolResultContent(toolResult.content, remainingTokens, archiveId)
      if (fit.truncated) {
        toolCompressed = true
      }
      invocation.status = toolResult.success ? 'success' : 'failed'
      invocation.count = toolResult.count
      invocation.errorMessage = toolResult.errorMessage
      invocation.errorCode = toolResult.errorCode
      // 记录**实际入队**的字符数：模型看到的是压缩后的内容，UI 不能报原文大小
      invocation.contentChars = fit.text.length
      invocation.fromCache = toolResult.fromCache
      // 一旦触发风控就停止本次运行的所有后续取数：继续调用只会拿到更多 rate_limited，
      // 而冷却期内无论换什么工具都发不出去，模型容易把它误读成「到处都没有数据」
      if (toolResult.errorCode === TOOL_ERROR_RATE_LIMITED) {
        throttled = true
      }
      invocation.sources = toolResult.sources
      invocation.cards = toolResult.cards
      if (toolResult.summary.length > 0) {
        invocation.summary = toolResult.summary
      }
      options.onToolInvocation(invocation)
      result.toolInvocations.push(invocation)
      appendSources(result.sources, sourceKeys, toolResult.sources)
      appendCards(result.cards, cardKeys, toolResult.cards)

      const toolMsg: ChatMessage = new ChatMessage('tool', fit.text)
      toolMsg.toolCallId = call.id
      toolMsg.name = call.function.name
      conversation.push(toolMsg)
      contextTokens += estimateMessageTokens(toolMsg)
      toolTokens += estimateTextTokens(fit.text)
    }

    step++
  }

  result.steps = step
  result.hitStepLimit = hitLimit
  result.hitToolBudget = budgetExhausted
  result.hitContextBudget = volumeExhausted
  result.contextTokens = contextTokens
  result.toolTokens = toolTokens
  result.toolSchemaTokens = estimateToolDefinitionsTokens(tools)
  result.toolCompressed = toolCompressed
  result.lastEstimatedPromptTokens = lastEstimatedPrompt
  result.lastActualPromptTokens = lastActualPrompt
  logger.info('runAiAgent done: steps=%{public}d, calls=%{public}d, tools=%{public}d, cards=%{public}d, text=%{public}d chars, contextTokens=%{public}d (tool=%{public}d, schema=%{public}d, budget=%{public}d, compressed=%{public}s), limit=%{public}s, calls=%{public}s, volume=%{public}s',
    step, executedCalls, result.toolInvocations.length, result.cards.length, result.text.length,
    contextTokens, toolTokens, result.toolSchemaTokens, toolBudget, String(toolCompressed),
    String(hitLimit), String(budgetExhausted), String(volumeExhausted))
  if (!result.usage.isEmpty()) {
    logger.info('runAiAgent usage: prompt=%{public}d, completion=%{public}d, cached=%{public}d, total=%{public}d',
      result.usage.promptTokens, result.usage.completionTokens, result.usage.cachedTokens,
      result.usage.totalTokens)
  }
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
 * 为「因预算用尽 / 触发风控而未执行」的工具调用补一条记录与 tool 消息。
 *
 * 为什么不直接跳过：Agent 循环的对话结构必须与模型返回的 tool_calls 一一对应，
 * 缺一条工具消息会被 OpenAI 兼容服务端判定为非法请求（400），整轮回答直接丢失。
 *
 * @param call - 模型请求的工具调用
 * @param conversation - 对话消息数组（原地追加）
 * @param options - 运行选项
 * @param result - Agent 结果（原地追加时间线）
 * @param reason - 跳过原因（SKIP_REASON_*）
 * @returns 追加的 tool 消息估算 token 数
 */
function appendSkippedCall(call: ToolCall, conversation: ChatMessage[],
  options: AiAgentOptions, result: AiAgentResult, reason: string): number {
  const invocation: AiToolInvocation = new AiToolInvocation()
  invocation.id = call.id
  invocation.name = call.function.name
  invocation.displayName = aiToolTitle(call.function.name)
  invocation.summary = call.function.arguments
  invocation.status = 'failed'
  invocation.errorCode = reason === SKIP_REASON_THROTTLE
    ? TOOL_ERROR_RATE_LIMITED : TOOL_ERROR_BUDGET_EXHAUSTED
  if (reason === SKIP_REASON_CALLS) {
    invocation.errorMessage = '本次运行的工具调用次数已达上限，该调用未执行'
  } else if (reason === SKIP_REASON_VOLUME) {
    invocation.errorMessage = '本轮上下文预算已满，该调用未执行'
  } else {
    invocation.errorMessage = '已触发 NGA 频率限制，该调用未执行'
  }
  invocation.contentChars = 0
  options.onToolInvocation(invocation)
  result.toolInvocations.push(invocation)

  let reasonText: string = 'NGA 接口已触发频率限制，客户端已暂停本次运行的所有站内取数'
  if (reason === SKIP_REASON_CALLS) {
    reasonText = '本次运行的工具调用次数已达上限（' + DEFAULT_MAX_TOOL_CALLS_PER_RUN.toString() + ' 次）'
  } else if (reason === SKIP_REASON_VOLUME) {
    reasonText = '本轮上下文预算已满，客户端已停止继续读取新数据'
  }
  const toolMsg: ChatMessage = new ChatMessage('tool',
    '该工具未执行：' + reasonText + '。' +
    '请基于已经取得的信息给出结论，并明确说明还缺哪些数据；' +
    '如果缺的是必需信息，请建议用户稍后再问或把问题拆小。不要编造未获取到的内容。')
  toolMsg.toolCallId = call.id
  toolMsg.name = call.function.name
  conversation.push(toolMsg)
  return estimateMessageTokens(toolMsg)
}

/**
 * 为「已用相同参数成功调用过」的重复调用补一条短说明。
 *
 * 不执行、不产生网络请求，也不把同一份大正文再塞回上下文；
 * 但必须仍然补一条 tool 消息——否则 tool_calls 与 tool 消息数量不匹配，服务端 400。
 *
 * @param call - 模型请求的工具调用
 * @param conversation - 对话消息数组（原地追加）
 * @param options - 运行选项
 * @param result - Agent 结果（原地追加时间线）
 * @returns 追加消息的估算 token 数
 */
function appendDuplicateCall(call: ToolCall, conversation: ChatMessage[],
  options: AiAgentOptions, result: AiAgentResult): number {
  const displayName: string = aiToolTitle(call.function.name)
  const invocation: AiToolInvocation = new AiToolInvocation()
  invocation.id = call.id
  invocation.name = call.function.name
  invocation.displayName = displayName
  invocation.summary = '相同参数已调用过'
  invocation.status = 'success'
  /* 不是缓存命中：是本次运行内已经执行过。UI 不要打「缓存」标签，避免误导 */
  invocation.fromCache = false
  invocation.contentChars = 0
  options.onToolInvocation(invocation)
  result.toolInvocations.push(invocation)

  const toolMsg: ChatMessage = new ChatMessage('tool',
    '本次运行已经用完全相同的参数成功调用过「' + displayName + '」，结果就是上文那条工具结果。' +
    '请直接使用已有结果；如果上文结果里带 result_id，说明它被截断过，' +
    '请用 expand_tool_result(result_id="…", offset=…) 续读，而不是重新调用原工具。' +
    '只有确实需要最新数据时，才显式传 freshness="fresh" 再调用一次。')
  toolMsg.toolCallId = call.id
  toolMsg.name = call.function.name
  conversation.push(toolMsg)
  return estimateMessageTokens(toolMsg)
}

/**
 * 构造一次工具调用的去重签名。
 *
 * 返回空串表示「不参与去重」：
 * - `get_context` 每次都可能反映最新的上下文 / 工具可用性，不能复用旧输出；
 * - 模型显式要求 fresh / no_cache 时，重复调用是合理意图；
 * - 参数为空且不是已知零参工具时，宁可执行也不要误判成重复。
 *
 * @param call - 工具调用
 * @returns 签名（空串表示不去重）
 */
function buildCallSignature(call: ToolCall): string {
  if (call.function.name === 'get_context') {
    return ''
  }
  if (readFreshnessFromText(call.function.arguments) !== FRESHNESS_AUTO) {
    return ''
  }
  const normalized: string = normalizeToolArguments(call.function.arguments)
  if (normalized.length === 0 && call.function.arguments.trim().length === 0) {
    return ''
  }
  return call.function.name + '|' + normalized
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
  invocation.displayName = aiToolTitle(call.function.name)
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
 * 追加去重后的卡片（按 kind + title + params 去重）。
 *
 * @param target - 目标列表
 * @param seen - 已见键集合
 * @param cards - 新增卡片
 */
function appendCards(target: AiToolCard[], seen: Record<string, boolean>, cards: AiToolCard[]): void {
  for (let i: number = 0; i < cards.length; i++) {
    const card: AiToolCard = cards[i]
    const key: string = card.kind + '|' + card.title + '|' + card.params
    if (seen[key] === true) {
      continue
    }
    seen[key] = true
    target.push(card)
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
