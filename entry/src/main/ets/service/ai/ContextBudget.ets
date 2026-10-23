/**
 * 会话历史预算（工作记忆的容量控制）。
 *
 * 改造前 `buildHistory` 把**全部**历史原样回传：聊到几十轮后，请求会先撞服务端上下文窗口、
 * 再撞用户的账单，最后表现为"回答超长被截断"或干脆 400。这里补三件事：
 *
 * 1. **估算**：按字符类型粗估 token（CJK 约 1 字 1 token，其它约 4 字符 1 token）；
 * 2. **裁剪**：超预算时保留"最近的一段"连续历史，且保证以用户消息开头；
 * 3. **折叠说明**：被移出窗口的旧轮次压成一条问题清单，由服务层拼进 system，
 *    让模型至少知道"之前聊过什么"，不会把用户已经交代过的信息当新问题。
 *
 * ## 为什么裁剪是一次裁到 50% 而不是逐条裁
 *
 * 服务商的前缀缓存按**前缀**命中（`docs/AI_AGENT_REDESIGN.md` §8.2）。裁剪会改写历史前缀，
 * 让该次请求整段 miss——这是无法避免的代价，但可以控制频率：逐条裁 = 每轮都 miss；
 * 一次性裁到预算的 50% = 每若干轮才 miss 一次。所以触发阈值是 100%、目标窗口是 50%。
 */

import { ChatMessage } from './AiProtocolTypes'

/** 历史可用的默认 token 预算（保守值：覆盖主流 32K 窗口模型的绝大部分可用空间）。 */
export const DEFAULT_HISTORY_TOKEN_BUDGET: number = 24000

/** 裁剪后保留的历史占预算比例（见文件头：一次裁到一半，降低缓存失效频率）。 */
export const HISTORY_KEEP_RATIO: number = 0.5

/** 折叠说明里最多列出多少条旧问题。 */
export const MAX_FOLDED_QUESTIONS: number = 6

/** 折叠说明里单条问题的最大长度。 */
const FOLDED_QUESTION_MAX: number = 60

/** 单条消息的固定开销（role / 分隔符等服务端模板成本）。 */
const MESSAGE_TOKEN_OVERHEAD: number = 4

/** 用户消息角色。 */
const ROLE_USER: string = 'user'

/**
 * 一次历史预算计算的结果。
 */
export class HistoryFitResult {
  /** 实际发送的消息（已裁剪） */
  messages: ChatMessage[] = []
  /** 被移出窗口的旧问题（最近的若干条，已截断） */
  foldedQuestions: string[] = []
  /** 因超出列举上限而未列出的旧问题数量 */
  foldedOmitted: number = 0
  /** 被移出窗口的消息数 */
  droppedMessages: number = 0
  /** 裁剪前的估算 token 总量（观测用） */
  estimatedTokens: number = 0
  /** 是否发生了裁剪 */
  truncated: boolean = false
}

/**
 * 估算纯文本的 token 数。
 *
 * 只求"量级正确且偏保守"：中文按 1 字 1 token，拉丁字母/数字按 4 字符 1 token。
 * 精确值只有服务端分词器知道，客户端不该为此引入词表；估值偏大一点更安全。
 *
 * @param text - 文本
 * @returns 估算 token 数
 */
export function estimateTextTokens(text: string): number {
  if (text.length === 0) {
    return 0
  }
  let cjk: number = 0
  let other: number = 0
  for (let i: number = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i)
    if (code >= 0x2E80) {
      cjk++
    } else {
      other++
    }
  }
  return cjk + Math.ceil(other / 4)
}

/**
 * 估算单条消息的 token 数（含固定开销）。
 *
 * @param message - 消息
 * @returns 估算 token 数
 */
export function estimateMessageTokens(message: ChatMessage): number {
  let tokens: number = MESSAGE_TOKEN_OVERHEAD + estimateTextTokens(message.content)
  if (message.name !== undefined && message.name.length > 0) {
    tokens += estimateTextTokens(message.name)
  }
  if (message.reasoning !== undefined && message.reasoning.length > 0) {
    tokens += estimateTextTokens(message.reasoning)
  }
  return tokens
}

/**
 * 按 token 预算裁剪历史。
 *
 * 保底行为：**最后一条消息一定保留**（它就是本次提问），即使它单条就超预算——
 * 丢掉当前问题会让整个请求失去意义。
 *
 * @param messages - 完整历史（user / assistant，不含 system）
 * @param budgetTokens - 预算 token 数（<=0 时用默认值）
 * @returns 裁剪结果
 */
export function fitHistoryToBudget(messages: ChatMessage[], budgetTokens: number): HistoryFitResult {
  const result: HistoryFitResult = new HistoryFitResult()
  const budget: number = budgetTokens > 0 ? budgetTokens : DEFAULT_HISTORY_TOKEN_BUDGET
  let total: number = 0
  for (let i: number = 0; i < messages.length; i++) {
    total += estimateMessageTokens(messages[i])
  }
  result.estimatedTokens = total
  if (total <= budget) {
    for (let i: number = 0; i < messages.length; i++) {
      result.messages.push(messages[i])
    }
    return result
  }

  const target: number = Math.max(1, Math.floor(budget * HISTORY_KEEP_RATIO))
  let start: number = messages.length
  let accumulated: number = 0
  for (let i: number = messages.length - 1; i >= 0; i--) {
    const cost: number = estimateMessageTokens(messages[i])
    // `start < messages.length` 表示已经保住了至少一条（最后一条），此后才允许因超预算停下
    if (start < messages.length && accumulated + cost > target) {
      break
    }
    accumulated += cost
    start = i
  }

  // 窗口必须从用户消息开始：以 AI 的答复开头会让恢复/裁剪后的历史语义断裂
  while (start > 0 && messages[start].role !== ROLE_USER) {
    start--
  }

  result.truncated = start > 0
  result.droppedMessages = start
  for (let i: number = start; i < messages.length; i++) {
    result.messages.push(messages[i])
  }
  collectFoldedQuestions(messages, start, result)
  return result
}

/**
 * 收集被裁掉的历史里的用户问题，作为折叠说明的素材。
 *
 * @param messages - 完整历史
 * @param end - 窗口起点（不含）
 * @param result - 结果对象（原地写入）
 */
function collectFoldedQuestions(messages: ChatMessage[], end: number, result: HistoryFitResult): void {
  const all: string[] = []
  for (let i: number = 0; i < end; i++) {
    if (messages[i].role !== ROLE_USER) {
      continue
    }
    const text: string = flatten(messages[i].content)
    if (text.length === 0) {
      continue
    }
    all.push(text.length > FOLDED_QUESTION_MAX ? text.substring(0, FOLDED_QUESTION_MAX) + '…' : text)
  }
  if (all.length > MAX_FOLDED_QUESTIONS) {
    result.foldedOmitted = all.length - MAX_FOLDED_QUESTIONS
    for (let i: number = all.length - MAX_FOLDED_QUESTIONS; i < all.length; i++) {
      result.foldedQuestions.push(all[i])
    }
    return
  }
  for (let i: number = 0; i < all.length; i++) {
    result.foldedQuestions.push(all[i])
  }
}

/**
 * 生成折叠说明文案（由服务层拼进 system）。
 *
 * 只列"问过什么"，不列 AI 的回答：回答里的事实可能已经过时，列出来反而诱导模型
 * 凭记忆复述；问题清单的作用是提示"这些要求已经在更早的地方提过，必要时可让用户重述"。
 *
 * @param questions - 旧问题清单
 * @param omitted - 因超上限省略的条数
 * @returns 文案；无折叠时为空串
 */
export function buildFoldedHistorySection(questions: string[], omitted: number): string {
  if (questions.length === 0 && omitted <= 0) {
    return ''
  }
  const lines: string[] = []
  lines.push('【较早的对话已折叠】')
  for (let i: number = 0; i < questions.length; i++) {
    lines.push('- ' + questions[i])
  }
  if (omitted > 0) {
    lines.push('- （更早的 ' + omitted.toString() + ' 轮提问已省略）')
  }
  lines.push('这些轮次的原文已移出上下文以节省窗口。需要其中的数据时请重新调用工具读取，' +
    '不要凭记忆复述细节；涉及用户偏好等尚未确认的信息时，请向用户确认。')
  return lines.join('\n')
}

/**
 * 把多行文本压成单行（折叠清单里每条只占一行）。
 *
 * @param text - 原文
 * @returns 单行文本
 */
function flatten(text: string): string {
  return text.replace(/\s+/g, ' ').trim()
}
