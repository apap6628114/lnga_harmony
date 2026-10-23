/**
 * 较早对话的**生成式压缩**（高保真）。
 *
 * ## 设计立场
 *
 * 压缩不是"把 token 变少"，而是**把即将离开窗口的信息，换成一份能支撑后续工作的记忆**。
 * 所以这里不做"6 条 40 字"的抽句式摘要——那会丢掉结论的理由、用户的原话、关键数据，
 * 后续对话只能重新问一遍，等于压缩没做。
 *
 * 参考成熟 Agent（Claude Code auto-compact、LangChain SummaryBufferMemory）的做法：
 * - 阈值高（接近窗口上限才压），压缩频率低；
 * - 一次压缩**彻底且结构化**（结论 / 用户要求 / 关键数据 / 待办）；
 * - 最近若干轮原文永不参与摘要（由 `ContextBudget` 的 `keepRecentTurns` 保证）；
 * - 输入尽量给足（按模型窗口的一半），而不是截到几千字符。
 *
 * ## 三条硬约束
 *
 * 1. **不阻断主流程**：失败一律返回空串，调用方回落到抽取式折叠清单；
 * 2. **摘要请求自己不能超窗**：输入按 token 封顶；
 * 3. **输出可清洗**：去掉 markdown / 前言，长度封顶。
 */

import { AiProviderProfile } from '../../model/AiConfig'
import { ChatMessage, ChatTurnOptions, RequestCanceller } from './AiProtocolTypes'
import { requestChatByProtocol } from './AiChatClient'
import { estimateTextTokens } from './ContextBudget'
import { Logger, DOMAIN_SERVICE } from '../../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'ContextSummarizer')

/**
 * 摘要输出的最大字符数。
 *
 * 3000 字（约 1500–2500 token）：足够装下结论、用户要求、关键数据、待办四段，
 * 而不是挤成 800 字的提纲。
 */
export const SUMMARY_MAX_CHARS: number = 3000

/**
 * 送进摘要请求的输入 token 下限。
 *
 * 与"按窗口一半"取较大值：小窗口模型也至少给 12K token 的对话量，
 * 避免因为窗口小就把摘要做薄。
 */
export const SUMMARY_INPUT_MIN_TOKENS: number = 12000

/** 摘要输入可占模型窗口的比例（给系统提示与输出留出余量）。 */
export const SUMMARY_INPUT_WINDOW_RATIO: number = 0.5

/**
 * 单条消息送进摘要时的最大字符数。
 *
 * 4000 字：长帖正文也能保留住关键段落。旧值 600 会把一楼几百字的正文
 * 切成一句半，摘要自然就只剩"用户读了帖子"这种空话。
 */
export const SUMMARY_MESSAGE_MAX_CHARS: number = 4000

/** 摘要系统提示词（逐字节稳定，不拼运行时数据）。 */
const SUMMARY_SYSTEM_PROMPT: string = '你是一个对话记忆压缩器。' +
  '你的任务是把较早的对话压缩成能支撑后续工作的记忆，而不是写概要。' +
  '你只输出规定的四段结构，不寒暄、不解释、不输出代码块。'

/**
 * 构造摘要请求的正文。
 *
 * 输入从 `dropped` 的尾部往前取（越靠近保留窗口的对话越可能仍被需要），
 * 直到用满输入预算。
 *
 * @param dropped - 被裁掉的历史消息
 * @param maxInputTokens - 输入 token 上限（<=0 时用最小值）
 * @returns 请求正文；无有效内容时为空串
 */
export function buildSummaryPrompt(dropped: ChatMessage[], maxInputTokens?: number,
  previousDigest?: string): string {
  const limit: number = maxInputTokens !== undefined && maxInputTokens > 0
    ? maxInputTokens : SUMMARY_INPUT_MIN_TOKENS
  const lines: string[] = []
  let used: number = 0
  const previous: string = previousDigest !== undefined ? previousDigest.trim() : ''
  // 旧记忆也占输入预算：否则"增量更新"会悄悄让摘要请求超窗
  if (previous.length > 0) {
    used += estimateTextTokens(previous)
  }
  for (let i: number = dropped.length - 1; i >= 0; i--) {
    const line: string = formatMessageLine(dropped[i])
    if (line.length === 0) {
      continue
    }
    const cost: number = estimateTextTokens(line)
    if (used + cost > limit) {
      break
    }
    lines.push(line)
    used += cost
  }
  if (lines.length === 0 && previous.length === 0) {
    return ''
  }
  lines.reverse()
  const parts: string[] = []
  if (previous.length > 0) {
    /*
     * 增量模式：已有记忆是前几次压缩的成果，必须在它基础上补充，
     * 而不是把旧结论丢掉重写——那等于每次压缩都丢一段历史。
     */
    parts.push('【已有记忆】（此前压缩的成果，必须在它基础上更新，不要丢弃其中的结论）')
    parts.push(previous)
  }
  parts.push('【任务】把下面这段较早的对话压缩成「继续工作所需的记忆」，供后续对话直接使用。')
  parts.push('【必须保留】\n' +
    '1. 已得出的结论与判断（连同理由要点）；\n' +
    '2. 用户明确表达过的偏好、要求、禁忌（优先保留原话）；\n' +
    '3. 已确认的事实与数据（tid / uid / 楼层号 / 数字 / 时间）；\n' +
    '4. 已经完成的事项与尚未完成的待办。')
  parts.push('【可以舍弃】\n' +
    '寒暄、试错过程、工具调用的参数细节、已被推翻的中间结论。')
  parts.push('【输出格式】\n' +
    '严格按下面四段输出；没有内容的段落写「无」；每段可有多条，用分号分隔；' +
    '总长度控制在 2000 字以内；不要输出解释、前言或标题以外的任何内容。\n' +
    '结论：\n用户要求：\n关键数据：\n待办：')
  if (lines.length > 0) {
    parts.push('【对话】\n' + lines.join('\n'))
  }
  return parts.join('\n\n')
}

/**
 * 把一条消息格式化成摘要素材。
 *
 * @param message - 对话消息
 * @returns 一行文本；system / tool 等无价值消息返回空串
 */
function formatMessageLine(message: ChatMessage): string {
  if (message.role !== 'user' && message.role !== 'assistant') {
    return ''
  }
  const raw: string = message.content.replace(/\s+/g, ' ').trim()
  if (raw.length === 0) {
    return ''
  }
  const text: string = raw.length > SUMMARY_MESSAGE_MAX_CHARS
    ? raw.substring(0, SUMMARY_MESSAGE_MAX_CHARS) + '…'
    : raw
  return (message.role === 'user' ? '用户：' : '助手：') + text
}

/**
 * 清洗模型输出的摘要。
 *
 * 只做**保守清洗**：去掉代码围栏、装饰性前缀、模型偶尔加的前言。
 * 四段结构里的换行与「结论：」这类行必须保留——那是信息本身。
 *
 * @param raw - 模型输出
 * @returns 干净的摘要文本；无有效内容时为空串
 */
export function cleanSummaryText(raw: string): string {
  if (raw === undefined || raw === null) {
    return ''
  }
  const withoutFence: string = raw.replace(/```[a-zA-Z]*/g, '')
  const lines: string[] = withoutFence.split('\n')
  const kept: string[] = []
  for (let i: number = 0; i < lines.length; i++) {
    // 去掉行首的 markdown 装饰：标题、引用、粗体
    let line: string = lines[i].replace(/^[\s>#*+]+/, '').replace(/\*\*/g, '').trim()
    // 规范列表符：保留「- 」形式，去掉「1.」「•」等变体
    line = line.replace(/^(\d+[.、)]|•|·)\s*/, '- ')
    if (line.length === 0) {
      continue
    }
    // 丢掉模型偶尔冒出来的前言
    if (line.indexOf('以下是') === 0 || line.indexOf('这段对话') === 0 ||
      line.indexOf('好的，') === 0) {
      continue
    }
    kept.push(line)
  }
  if (kept.length === 0) {
    return ''
  }
  let text: string = kept.join('\n')
  if (text.length > SUMMARY_MAX_CHARS) {
    text = text.substring(0, SUMMARY_MAX_CHARS) + '…'
  }
  return text
}

/**
 * 生成式压缩一段被裁掉的历史。
 *
 * 失败一律返回空串（调用方回落抽取式），**绝不抛异常**：
 * 压缩是"更好"，不是"必须有"——不能因为它让整轮对话失败。
 *
 * @param profile - AI 配置（复用当前对话的模型）
 * @param dropped - 被裁掉的历史消息
 * @param contextWindow - 模型窗口（决定送多少对话进去，<=0 时用最小值）
 * @param canceller - 取消令牌（用户停止时一并中止）
 * @param previousDigest - 上一次压缩的记忆（增量更新用；空串表示首次压缩）
 * @returns 摘要文本；失败或无内容时为空串
 */
export async function summarizeFoldedHistory(profile: AiProviderProfile,
  dropped: ChatMessage[], contextWindow: number,
  canceller: RequestCanceller | null, previousDigest?: string): Promise<string> {
  const windowBased: number = contextWindow > 0
    ? Math.floor(contextWindow * SUMMARY_INPUT_WINDOW_RATIO)
    : 0
  const inputLimit: number = Math.max(SUMMARY_INPUT_MIN_TOKENS, windowBased)
  const prompt: string = buildSummaryPrompt(dropped, inputLimit, previousDigest)
  if (prompt.length === 0) {
    return ''
  }
  if (canceller !== null && canceller.isCancelled()) {
    return ''
  }
  const messages: ChatMessage[] = []
  messages.push(new ChatMessage('system', SUMMARY_SYSTEM_PROMPT))
  messages.push(new ChatMessage('user', prompt))
  const options: ChatTurnOptions = new ChatTurnOptions()
  options.stream = false
  options.tools = []
  const startTime: number = Date.now()
  try {
    const turn = await requestChatByProtocol(profile, messages, options,
      canceller === null ? undefined : canceller)
    const cleaned: string = cleanSummaryText(turn.text)
    logger.info('summarize done: dropped=%{public}d, inputTokens≈%{public}d (limit=%{public}d), outputChars=%{public}d, cost=%{public}dms',
      dropped.length, estimateTextTokens(prompt), inputLimit, cleaned.length, Date.now() - startTime)
    return cleaned
  } catch (err) {
    const e: Error = err as Error
    // 降级而不是失败：主请求必须照常发出
    logger.warn('summarize failed, fallback to extractive: %{public}s', e.message)
    return ''
  }
}

/**
 * 把摘要拼成 system 段落。
 *
 * 措辞刻意区分「记忆」与「原文」：让模型知道这是二次加工过的内容，
 * 需要细节时应重新取数，而不是把摘要当事实复述。
 *
 * @param summary - 摘要文本
 * @param omitted - 被省略的轮次数量（0 表示未省略）
 * @returns system 段落；无摘要时为空串
 */
export function buildSummarySection(summary: string, omitted: number): string {
  if (summary.length === 0) {
    return ''
  }
  const lines: string[] = []
  lines.push('【较早对话的记忆】')
  lines.push(summary)
  if (omitted > 0) {
    lines.push('（更早的 ' + omitted.toString() + ' 轮已省略）')
  }
  lines.push('以上是从更早的对话里压缩出来的记忆，不是原文。' +
    '需要具体原文数据时请重新调用对应工具读取（客户端有缓存，不会重复请求）；' +
    '涉及用户偏好等尚未确认的信息时，请向用户确认。')
  return lines.join('\n')
}
