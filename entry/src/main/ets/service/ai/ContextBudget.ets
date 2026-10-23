/**
 * 上下文预算（工作记忆的容量控制）。
 *
 * ## 设计立场：上下文是效果，不是成本
 *
 * 早期版本把上下文当成"要省下来的钱"，于是设了 24000 的固定预算、超了就裁到一半、
 * 摘要只留 6 条问题。在 1M 窗口、缓存命中 0.02–0.04 元/百万 token 的价格结构下，
 * 这是**净亏损**：省下的 token 不值钱，丢掉的信息很贵，而且压缩本身还要多一次模型调用。
 *
 * 现在的原则是**先把窗口用满，接近上限才压缩**：
 *
 * 1. **估算**：按字符类型粗估 token（CJK 约 1 字 1 token，其它约 4 字符 1 token）；
 * 2. **定预算**：`窗口 - 输出预留`，剩余全部给历史；窗口未知时假设 128K，而不是 24K；
 * 3. **触发**：占用达到预算的 95%（长记忆档）才动刀，多数会话根本走不到这一步；
 * 4. **压缩**：低频、彻底、高保真——生成式摘要（`ContextSummarizer`），
 *    且**最近 N 轮原文永不参与**（`keepRecentTurns`）。
 *
 * ## 触发阈值为什么定在 95% 而不是"一超就压"
 *
 * 前缀缓存按**前缀**命中（`docs/AI_AGENT_REDESIGN.md` §8.2）。压缩会改写历史前缀，
 * 让该次请求整段 miss。但压缩应该是**低频事件**：阈值高 = 一年只压几次，
 * 每次 miss 的代价被摊得很薄。反过来"超一点就压、每次只压一点"会变成每轮都 miss，
 * 而且信息被切得七零八落——那正是旧设计的问题。
 *
 * ## 预算为什么必须由模型窗口推导
 *
 * 固定 24000 对 8K 窗口必然超窗，对 1M 窗口只用掉 2.4%——同一份常量在两端都是错的。
 * 窗口按三级取值：用户配置 > 已知模型表 > 假设 128K（见 `model/AiModelContextWindows.ets`）。
 */

import { AiToolDefinition, ChatMessage } from './AiProtocolTypes'
import {
  TOKEN_CALIBRATION_MAX,
  TOKEN_CALIBRATION_MIN,
  clampTokenCalibration
} from '../../model/AiMemoryConfig'

/**
 * 未知模型窗口时的假设窗口。
 *
 * 不再用 24000。2026 年的模型下限（DeepSeek V4 系列 1M、主流 128K）远高于 24K；
 * 假设 128K 意味着"窗口未知时也尽量用满"，而不是"未知时先砍到脚脖子"。
 * 保守应该是"防超窗"，不是"少用上下文"——后者只会让效果变差。
 */
export const ASSUMED_CONTEXT_WINDOW: number = 128000

/**
 * 裁剪后默认保留的历史比例。
 *
 * 从 0.5 提高到 0.7：在长上下文模型上，压缩本身是低频事件（窗口大、触发少），
 * 一次压缩应该多留一些，而不是"裁到一半"去讨好缓存命中率。
 */
export const HISTORY_KEEP_RATIO: number = 0.7

/** 默认触发阈值：占用达到预算的这个比例才压缩（长记忆档）。 */
export const HISTORY_TRIGGER_RATIO: number = 0.95

/** 默认永不参与摘要的最近轮数（保持原文，保证当前话题的连贯性）。 */
export const KEEP_RECENT_TURNS: number = 4

/** 折叠说明里最多列出多少条旧问题。 */
export const MAX_FOLDED_QUESTIONS: number = 12

/** 折叠说明里单条问题的最大长度。 */
const FOLDED_QUESTION_MAX: number = 60

/** 折叠说明里单条结论摘要的最大长度。 */
const FOLDED_ANSWER_MAX: number = 60

/** 单条消息的固定开销（role / 分隔符等服务端模板成本）。 */
const MESSAGE_TOKEN_OVERHEAD: number = 4

/** 用户消息角色。 */
const ROLE_USER: string = 'user'

/** 助手消息角色。 */
const ROLE_ASSISTANT: string = 'assistant'

/**
 * 为输出与 system 预留的最小 token 数。
 *
 * 请求**不携带** max_tokens（见 `model/AiConfig.ets`：输出长度交给服务端），
 * 因此这里只能留余量，不能用 maxOutputTokens 做精确扣减。
 */
const MIN_OUTPUT_TOKEN_RESERVE: number = 4096

/** 为输出 / system / 安全余量预留的窗口占比。 */
const OUTPUT_RESERVE_RATIO: number = 0.12

/** 预留最多能占窗口的比例（防止小窗口被预留吃光，反而无法对话）。 */
const MAX_RESERVE_RATIO: number = 0.5

/** 单条工具结果压缩后至少保留的 token 数（不能让模型拿到空内容）。 */
export const MIN_TOOL_RESULT_TOKENS: number = 128

/** 校准的指数移动平均系数：0.3 表示新样本占三成，收敛快但不被单次异常带偏。 */
const CALIBRATION_ALPHA: number = 0.3

/**
 * 根据一次真实观测更新校准系数。
 *
 * 语义：`真实 promptTokens / 本地估算`。系数 >1 表示我们**低估**（真实更大），
 * 预算要相应缩小；<1 表示**高估**，可以放宽。
 *
 * 用 EMA 而不是直接覆盖：单次请求的 promptTokens 会受 system 长度、工具 schema、
 * 缓存开关影响而跳变，取"长期趋势"才稳定。
 *
 * @param current - 当前系数
 * @param estimated - 本地估算的输入 token
 * @param actual - 服务端返回的真实 promptTokens
 * @returns 新系数（夹在 [TOKEN_CALIBRATION_MIN, TOKEN_CALIBRATION_MAX]）
 */
export function nextCalibrationFactor(current: number, estimated: number, actual: number): number {
  const base: number = current > 0 ? current : 1
  if (estimated <= 0 || actual <= 0 || !isFinite(actual)) {
    return clampTokenCalibration(base)
  }
  const ratio: number = actual / estimated
  if (!isFinite(ratio)) {
    return clampTokenCalibration(base)
  }
  const observation: number = Math.min(TOKEN_CALIBRATION_MAX,
    Math.max(TOKEN_CALIBRATION_MIN, ratio))
  const next: number = base * (1 - CALIBRATION_ALPHA) + observation * CALIBRATION_ALPHA
  return clampTokenCalibration(next)
}

/**
 * 被折叠的一轮对话（问题 + 结论首句）。
 *
 * 改造前只记问题不记答案，导致"折叠 = 结论丢失"。这里保留结论首句，
 * 让模型至少知道之前得出过什么，而不是只知道用户问过什么。
 */
export class FoldedTurn {
  /** 用户问题（单行、截断） */
  question: string = ''
  /** 助手结论首句（单行、截断；空串表示该轮没有可用结论） */
  answer: string = ''

  /**
   * 构造一轮折叠记录。
   *
   * @param question - 问题
   * @param answer - 结论首句
   */
  constructor(question: string, answer: string) {
    this.question = question
    this.answer = answer
  }
}

/**
 * 一次历史预算计算的结果。
 */
export class HistoryFitResult {
  /** 实际发送的消息（已裁剪） */
  messages: ChatMessage[] = []
  /** 被移出窗口的旧问题（最近的若干条，已截断）——保留供旧调用方与日志使用 */
  foldedQuestions: string[] = []
  /** 被移出窗口的轮次（问题 + 结论首句） */
  foldedTurns: FoldedTurn[] = []
  /** 因超出列举上限而未列出的旧问题数量 */
  foldedOmitted: number = 0
  /** 被移出窗口的消息数 */
  droppedMessages: number = 0
  /** 裁剪前的估算 token 总量（观测用） */
  estimatedTokens: number = 0
  /** 本次实际生效的预算（观测用） */
  budgetTokens: number = 0
  /** 是否发生了裁剪 */
  truncated: boolean = false
}

/**
 * 一次请求的上下文占用（供 UI 展示「记忆用量」，也供日志观测）。
 *
 * 与 `HistoryFitResult` 的区别：这里覆盖**整轮上下文**（system + 历史 + 工具结果），
 * 而不是只看历史——工具结果往往才是体量的大头。
 */
export class ContextUsage {
  /** 历史可用预算（窗口扣掉输出预留） */
  budgetTokens: number = 0
  /** 本次生效的压缩触发阈值（占用到这个数才压缩） */
  triggerTokens: number = 0
  /** system 段估算（token） */
  systemTokens: number = 0
  /** 历史段估算（token） */
  historyTokens: number = 0
  /** 工具结果估算（token） */
  toolTokens: number = 0
  /**
   * 工具声明（tools schema）估算（token）。
   *
   * 它不随对话变化，但确实占输入窗口；漏掉它会让"离压缩还有多远"偏乐观。
   */
  toolSchemaTokens: number = 0
  /** 被折叠/压缩的轮数 */
  foldedTurns: number = 0
  /** 是否发生了历史裁剪 */
  historyTruncated: boolean = false
  /** 是否有工具结果被压缩 */
  toolCompressed: boolean = false
  /** 本轮服务端返回的输入 token（真实值；未返回时为 0） */
  promptTokens: number = 0
  /** 本轮命中前缀缓存的输入 token */
  cachedTokens: number = 0
  /** 服务端是否真的报告了缓存字段（决定能不能展示 0%） */
  cacheReported: boolean = false

  /**
   * 前缀缓存命中率（0..1）。
   *
   * 这是"上下文前缀是否稳定"的唯一量化依据：命中率高说明历史只追加、
   * system / tools 没有逐轮变化；掉下来通常意味着压缩、任务切换或动态内容混进了前缀。
   *
   * @returns 命中率；服务端没有报告缓存字段或没有真实用量时返回 -1（表示未知）
   */
  cacheHitRatio(): number {
    if (!this.cacheReported || this.promptTokens <= 0) {
      return -1
    }
    const ratio: number = this.cachedTokens / this.promptTokens
    if (ratio < 0) {
      return 0
    }
    return ratio > 1 ? 1 : ratio
  }

  /**
   * 已占用的总 token。
   *
   * @returns system + 历史 + 工具结果
   */
  usedTokens(): number {
    return this.systemTokens + this.historyTokens + this.toolTokens + this.toolSchemaTokens
  }

  /**
   * 占用比例（0..1，供进度条使用）。
   *
   * **相对触发阈值**而不是总预算：用户关心的是"离压缩还有多远"，
   * 而不是"用了 1M 里的 5%"（后者会让进度条永远贴着零，毫无信息量）。
   *
   * @returns 比例；阈值未知时返回 0
   */
  ratio(): number {
    if (this.triggerTokens <= 0) {
      return 0
    }
    const used: number = this.usedTokens()
    const value: number = used / this.triggerTokens
    return value > 1 ? 1 : value
  }
}

/**
 * 一条工具结果的压缩结果。
 */
export class ToolContentFit {
  /** 压缩后的文本（未压缩时等于原文） */
  text: string = ''
  /** 是否发生压缩 */
  truncated: boolean = false
  /** 原文估算 token 数 */
  originalTokens: number = 0
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
  if (message.toolCalls !== undefined && message.toolCalls.length > 0) {
    for (let i: number = 0; i < message.toolCalls.length; i++) {
      tokens += estimateTextTokens(message.toolCalls[i].function.name)
      tokens += estimateTextTokens(message.toolCalls[i].function.arguments)
    }
  }
  /*
   * reasoning 的处理按协议区分：
   * - Chat Completions 不回传 reasoning（`serializeMessages` 只发 role/content/tool_calls），
   *   算进去会让水位虚高、压缩提前；
   * - Responses 会把 assistant 的 outputItems 原样回传，reasoning 确实占输入。
   * `outputItems` 非空就是 Responses 消息，此时才计入。
   */
  if (message.reasoning !== undefined && message.reasoning.length > 0 &&
    message.outputItems !== undefined && message.outputItems.length > 0) {
    tokens += estimateTextTokens(message.reasoning)
  }
  return tokens
}

/**
 * 估算整段对话的 token 数（system + 历史 + 工具结果）。
 *
 * @param messages - 对话消息
 * @returns 估算 token 数
 */
export function estimateConversationTokens(messages: ChatMessage[]): number {
  let total: number = 0
  for (let i: number = 0; i < messages.length; i++) {
    total += estimateMessageTokens(messages[i])
  }
  return total
}

/**
 * 估算工具声明（tools schema）占用的 token。
 *
 * 旧实现只统计消息，工具 schema（十几个工具的 name / description / parameters）
 * 约 2–4K token，全部被漏掉；预算因此偏乐观，工具结果把总量推过窗口时才发现。
 * 序列化口径与 `OpenAiChatClient.serializeTools` 对齐，避免"算的和发的不是一个东西"。
 *
 * @param tools - 工具定义
 * @returns 估算 token 数（无工具时为 0）
 */
export function estimateToolDefinitionsTokens(tools: AiToolDefinition[]): number {
  if (tools.length === 0) {
    return 0
  }
  let total: number = 0
  for (let i: number = 0; i < tools.length; i++) {
    const tool: AiToolDefinition = tools[i]
    total += MESSAGE_TOKEN_OVERHEAD
    total += estimateTextTokens(tool.name)
    total += estimateTextTokens(tool.description)
    total += estimateTextTokens(JSON.stringify(tool.parameters))
  }
  return total
}

/**
 * 判断异常是否为「输入超出模型上下文窗口」。
 *
 * 为什么必须单独识别：这是唯一一种**客户端可以自愈**的失败——本地估算偏乐观、
 * 工具 schema 或服务端模板比预估更大时，真实请求会超窗。旧实现直接把它当普通
 * 400 抛给用户，整轮对话丢失；识别出来后可以强制压缩再重试一次。
 *
 * 只匹配服务商的明确措辞，避免把普通的参数错误（同样 400）误判成超窗、
 * 触发一次没有意义的压缩重试。
 *
 * @param message - 异常消息（格式 `<状态码>\n<服务端详情>`）
 * @returns true 表示是上下文超窗
 */
export function isContextOverflowError(message: string): boolean {
  const text: string = message.toLowerCase()
  const patterns: string[] = [
    'context_length_exceeded',
    'maximum context length',
    'too many tokens',
    'prompt is too long',
    'input is too long',
    'reduce the length',
    '上下文长度',
    '超出上下文',
    '上下文超出',
    'tokens 超过'
  ]
  for (let i: number = 0; i < patterns.length; i++) {
    if (text.indexOf(patterns[i]) >= 0) {
      return true
    }
  }
  return false
}

/**
 * 计算历史前缀的指纹（用于判断缓存的压缩记忆是否仍然有效）。
 *
 * 为什么需要它：压缩记忆（`AiSession.digest`）覆盖的是"前 N 条历史"。
 * 只要历史只追加，前 N 条就不变，记忆可以直接复用；但页面重建历史时
 * （失败气泡被跳过、会话恢复等）可能导致序列错位，此时指纹不匹配，就必须重算，
 * 否则会把"别的对话的摘要"喂给模型。
 *
 * @param messages - 历史消息
 * @param count - 参与计算的前缀条数
 * @returns 十六进制指纹
 */
export function historyFingerprint(messages: ChatMessage[], count: number): string {
  const limit: number = count < messages.length ? count : messages.length
  let hash: number = 2166136261
  for (let i: number = 0; i < limit; i++) {
    hash = fnvStep(hash, messages[i].role)
    hash = fnvStep(hash, messages[i].content)
  }
  return (hash >>> 0).toString(16)
}

/**
 * FNV-1a 单步。
 *
 * @param hash - 当前哈希
 * @param text - 文本
 * @returns 新哈希
 */
function fnvStep(hash: number, text: string): number {
  let h: number = hash
  for (let i: number = 0; i < text.length; i++) {
    h = h ^ text.charCodeAt(i)
    // 16777619 = FNV prime；用 |0 保持在 32 位整数域
    h = (h * 16777619) | 0
  }
  return h
}

/**
 * 由模型窗口推导历史预算。
 *
 * 规则：`窗口 - min(窗口 × 50%, max(4096, 窗口 × 12%))`。
 *
 * 与旧版的区别（这是本次重构的核心）：
 * - **未知窗口不再回落 24000**，而是假设 128K——保守应该是"防超窗"，不是"少用上下文"；
 * - **不再乘 0.75**：那个折扣是为了压裁剪频率，代价是白白扔掉 25% 的可用窗口；
 * - 预留只扣"输出 + system"，剩余**全部**给历史。
 *
 * 为什么送 12% 而不是按 maxOutputTokens 精确扣：请求不带 max_tokens，
 * 输出长度由服务端决定，只能留余量。
 *
 * @param contextWindow - 模型上下文窗口（0 表示未知）
 * @returns 历史可用预算 token 数
 */
export function resolveHistoryBudget(contextWindow: number): number {
  const window: number = contextWindow > 0 ? contextWindow : ASSUMED_CONTEXT_WINDOW
  const rawReserve: number = Math.max(MIN_OUTPUT_TOKEN_RESERVE,
    Math.floor(window * OUTPUT_RESERVE_RATIO))
  const reserve: number = Math.min(Math.floor(window * MAX_RESERVE_RATIO), rawReserve)
  const budget: number = window - reserve
  return budget > 0 ? budget : Math.floor(window * 0.5)
}

/**
 * 由历史预算推导本次请求的触发阈值。
 *
 * 占用达到 `预算 × 触发比例` 才压缩——不是一超预算就压。
 * 长记忆档 95%、平衡 90%、精简 80%（见 `model/AiMemoryConfig.ets`）。
 *
 * @param historyBudget - 历史可用预算
 * @param triggerRatio - 触发比例（0..1，越界回落默认）
 * @returns 触发阈值 token 数
 */
export function resolveTriggerTokens(historyBudget: number, triggerRatio: number): number {
  if (historyBudget <= 0) {
    return 0
  }
  const ratio: number = triggerRatio > 0 && triggerRatio <= 1 ? triggerRatio : HISTORY_TRIGGER_RATIO
  return Math.max(1, Math.floor(historyBudget * ratio))
}

/**
 * 工具结果可占用的预算。
 *
 * **等于整份历史预算**：工具结果不该有独立的折扣系数。
 * 它与历史共享同一个窗口，只有在真的会把总量推过预算时才需要压缩——
 * 提前按比例扣减等于为了让数字好看而牺牲模型真正需要看到的正文。
 *
 * @param historyBudget - 历史可用预算
 * @returns 工具结果预算（<=0 表示不限）
 */
export function resolveToolResultBudget(historyBudget: number): number {
  return historyBudget > 0 ? historyBudget : 0
}

/**
 * 由模型窗口与校准系数推导历史预算。
 *
 * 校准系数是 `真实 promptTokens / 本地估算`：<1 表示我们高估，可以放宽预算；
 * >1 表示低估，要收紧。**但放宽不能突破窗口安全线**——旧实现直接
 * `rawBudget / 0.7`，1M 窗口会算出 1.25M 的预算，主动制造超窗。
 *
 * 安全上限只扣最小输出预留（4096 或窗口一半），而不是完整 12% 预留：
 * 这样校准仍能带来有限的放宽收益（最多从 88% 放宽到约 99.6%），又不会过窗。
 *
 * @param contextWindow - 模型窗口（0 表示未知）
 * @param calibration - 校准系数（非法值按 1 处理）
 * @returns 历史可用预算 token 数
 */
export function resolveCalibratedBudget(contextWindow: number, calibration: number): number {
  const window: number = contextWindow > 0 ? contextWindow : ASSUMED_CONTEXT_WINDOW
  const rawBudget: number = resolveHistoryBudget(contextWindow)
  const factor: number = calibration > 0 && isFinite(calibration) ? calibration : 1
  const widened: number = Math.floor(rawBudget / factor)
  const minReserve: number = Math.min(MIN_OUTPUT_TOKEN_RESERVE, Math.floor(window * 0.5))
  const hardMax: number = Math.max(1, window - minReserve)
  const capped: number = widened < hardMax ? widened : hardMax
  /* 下限也不能超过窗口本身：小窗口（<8K）下 4096 的绝对下限会直接超窗 */
  const floorBudget: number = Math.min(MIN_OUTPUT_TOKEN_RESERVE, Math.floor(window * 0.5))
  return Math.max(floorBudget, capped)
}

/**
 * 按 token 上限压缩一条工具结果。
 *
 * 超限时截断并追加"如何取回剩余部分"的说明。两种模式：
 * - 传了 `archiveId`：完整结果已由调用方存入 `ToolResultArchive`，尾注给出
 *   result_id 与续读偏移，模型调用 `expand_tool_result` 就能拿到后半段；
 * - 没传：退回旧文案（同参数重调），仅作为没有归档能力时的兜底。
 *
 * 尾注本身会占用预算，因此先预留一小段再截断正文——否则"截断 + 说明"会超出
 * 本轮剩余额度，让本来就已经吃紧的请求直接超窗。
 *
 * @param content - 工具结果原文
 * @param maxTokens - 允许的最大 token 数（<=0 表示不限）
 * @param archiveId - 完整结果的归档 ID（空串表示未归档）
 * @returns 压缩结果
 */
export function fitToolResultContent(content: string, maxTokens: number,
  archiveId?: string): ToolContentFit {
  const fit: ToolContentFit = new ToolContentFit()
  fit.text = content
  fit.originalTokens = estimateTextTokens(content)
  if (maxTokens <= 0 || fit.originalTokens <= maxTokens) {
    return fit
  }
  const archived: boolean = archiveId !== undefined && archiveId.length > 0
  // 预留尾注：归档模式约 160 token（含 result_id 与续读指引），兜底模式约 70 token
  const hintReserve: number = archived ? 160 : 70
  /*
   * 剩余额度连「最小正文 + 尾注」都放不下时，不再塞正文：整条结果只放
   * 一句外置说明。否则 128 正文 + 160 尾注反而把已经贴窗口的请求推过上限，
   * 与「防超窗」的目的相反。
   */
  if (archived && maxTokens <= hintReserve + MIN_TOOL_RESULT_TOKENS) {
    const shortId: string = archiveId !== undefined ? archiveId : ''
    fit.text = '（结果较大，已完整外置：result_id=' + shortId + '，共 ' +
      content.length.toString() + ' 字符。用 expand_tool_result(result_id="' +
      shortId + '") 读取。）'
    fit.truncated = true
    return fit
  }
  const contentBudget: number = Math.max(MIN_TOOL_RESULT_TOKENS, maxTokens - hintReserve)
  const limited: string = sliceByTokens(content, contentBudget)
  if (archived) {
    const id: string = archiveId !== undefined ? archiveId : ''
    fit.text = limited + '\n\n（完整结果共 ' + content.length.toString() + ' 字符，已保存为 result_id=' +
      id + '。上面只展示了前 ' + limited.length.toString() + ' 字符；' +
      '需要后续内容时调用 expand_tool_result(result_id="' + id + '", offset=' +
      limited.length.toString() + ')，不要用相同参数重复调用原工具——那只会拿回同样被截断的开头。' +
      '若该 result_id 已失效，再重新调用原工具。）'
  } else {
    fit.text = limited + '\n\n（以上内容已按本轮上下文预算压缩。需要剩余部分时，' +
      '请用相同参数再次调用该工具——客户端有缓存，不会重复请求。）'
  }
  fit.truncated = true
  return fit
}

/**
 * 按估算 token 数截取文本前缀。
 *
 * @param text - 原文
 * @param maxTokens - token 上限
 * @returns 截取后的前缀
 */
function sliceByTokens(text: string, maxTokens: number): string {
  let tokens: number = 0
  let otherRun: number = 0
  let index: number = 0
  while (index < text.length) {
    const code: number = text.charCodeAt(index)
    if (code >= 0x2E80) {
      tokens += 1
      otherRun = 0
    } else {
      otherRun++
      if (otherRun >= 4) {
        tokens += 1
        otherRun = 0
      }
    }
    index++
    if (tokens >= maxTokens) {
      break
    }
  }
  return text.substring(0, index)
}

/**
 * 按 token 预算裁剪历史。
 *
 * 两条保底行为：
 * 1. **最后一条消息一定保留**（它就是本次提问），即使它单条就超预算；
 * 2. **最近 `keepRecentTurns` 轮原样保留**——当前话题的原文永远不参与摘要，
 *    这是"压缩不伤效果"的关键：只有真正老旧的轮次才会被压。
 *
 * @param messages - 完整历史（user / assistant，不含 system）
 * @param triggerTokens - 触发阈值：估算总量超过它才开始裁剪（<=0 时按假设窗口推导）
 * @param keepRatio - 裁剪后保留的历史占触发阈值的比例（缺省 `HISTORY_KEEP_RATIO`）
 * @param keepRecentTurns - 永不参与裁剪的最近轮数（缺省 `KEEP_RECENT_TURNS`）
 * @returns 裁剪结果
 */
export function fitHistoryToBudget(messages: ChatMessage[], triggerTokens: number,
  keepRatio?: number, keepRecentTurns?: number): HistoryFitResult {
  const result: HistoryFitResult = new HistoryFitResult()
  const trigger: number = triggerTokens > 0 ? triggerTokens : resolveHistoryBudget(0)
  result.budgetTokens = trigger
  /* 越界比例（<=0 / >=1）回落默认：裁到 100% 等于没裁，会变成每轮都 miss */
  const ratio: number = keepRatio !== undefined && keepRatio > 0 && keepRatio < 1
    ? keepRatio : HISTORY_KEEP_RATIO
  const recentTurns: number = keepRecentTurns !== undefined && keepRecentTurns >= 0
    ? keepRecentTurns : KEEP_RECENT_TURNS
  let total: number = 0
  for (let i: number = 0; i < messages.length; i++) {
    total += estimateMessageTokens(messages[i])
  }
  result.estimatedTokens = total
  if (total <= trigger) {
    for (let i: number = 0; i < messages.length; i++) {
      result.messages.push(messages[i])
    }
    return result
  }

  const target: number = Math.max(1, Math.floor(trigger * ratio))
  let start: number = messages.length
  let accumulated: number = 0
  let userCount: number = 0
  for (let i: number = messages.length - 1; i >= 0; i--) {
    const cost: number = estimateMessageTokens(messages[i])
    const alreadyKept: boolean = start < messages.length
    /*
     * 最近 N 轮优先保留，但不是无条件：它们的总量仍受 `trigger` 约束。
     * 否则"最后一条就超预算 50 倍"的极端输入会把整个窗口撑爆——
     * 那时必须回到保底语义：只留这一条。
     */
    const cap: number = userCount < recentTurns ? Math.max(1, trigger) : target
    if (alreadyKept && accumulated + cost > cap) {
      break
    }
    accumulated += cost
    start = i
    if (messages[i].role === ROLE_USER) {
      userCount++
    }
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
  collectFoldedTurns(messages, start, result)
  return result
}

/**
 * 收集被裁掉的历史里的轮次，作为折叠说明的素材。
 *
 * 每一轮取「问题 + 结论首句」：只说问过什么、不说得出过什么，等于要求模型
 * 从零重来；而只给首句而非全文，是为了避免它把摘要当原文复述。
 *
 * @param messages - 完整历史
 * @param end - 窗口起点（不含）
 * @param result - 结果对象（原地写入）
 */
function collectFoldedTurns(messages: ChatMessage[], end: number, result: HistoryFitResult): void {
  const turns: FoldedTurn[] = []
  for (let i: number = 0; i < end; i++) {
    if (messages[i].role !== ROLE_USER) {
      continue
    }
    const question: string = clipLine(flatten(messages[i].content), FOLDED_QUESTION_MAX)
    if (question.length === 0) {
      continue
    }
    let answer: string = ''
    if (i + 1 < end && messages[i + 1].role === ROLE_ASSISTANT) {
      answer = clipLine(firstSentence(flatten(messages[i + 1].content)), FOLDED_ANSWER_MAX)
    }
    turns.push(new FoldedTurn(question, answer))
  }
  const kept: FoldedTurn[] = []
  if (turns.length > MAX_FOLDED_QUESTIONS) {
    result.foldedOmitted = turns.length - MAX_FOLDED_QUESTIONS
    for (let i: number = turns.length - MAX_FOLDED_QUESTIONS; i < turns.length; i++) {
      kept.push(turns[i])
    }
  } else {
    for (let i: number = 0; i < turns.length; i++) {
      kept.push(turns[i])
    }
  }
  for (let i: number = 0; i < kept.length; i++) {
    result.foldedTurns.push(kept[i])
    result.foldedQuestions.push(kept[i].question)
  }
}

/**
 * 生成折叠说明文案（由服务层拼进 system）。
 *
 * 只列「问题 + 结论首句」：结论首句给出"之前得出过什么"，但明确告知这是摘要、
 * 细节需重新读取——既不让模型从零重来，也不诱导它把摘要当原文。
 *
 * @param turns - 被折叠的轮次
 * @param omitted - 因超上限省略的条数
 * @returns 文案；无折叠时为空串
 */
export function buildFoldedTurnsSection(turns: FoldedTurn[], omitted: number): string {
  if (turns.length === 0 && omitted <= 0) {
    return ''
  }
  const lines: string[] = []
  lines.push('【较早的对话已折叠】')
  for (let i: number = 0; i < turns.length; i++) {
    lines.push('- 你问：' + turns[i].question)
    if (turns[i].answer.length > 0) {
      lines.push('  我答（摘要）：' + turns[i].answer)
    }
  }
  if (omitted > 0) {
    lines.push('- （更早的 ' + omitted.toString() + ' 轮已省略）')
  }
  lines.push('这些轮次的原文已移出上下文以节省窗口。上面的「我答」只是结论摘要，' +
    '细节可能不完整；需要其中的数据时请重新调用对应工具读取，不要凭摘要编造具体内容；' +
    '涉及用户偏好等尚未确认的信息时，请向用户确认。')
  return lines.join('\n')
}

/**
 * 生成只含问题的折叠说明（兼容旧调用方）。
 *
 * @param questions - 旧问题清单
 * @param omitted - 因超上限省略的条数
 * @returns 文案；无折叠时为空串
 *
 * @deprecated 新代码请用 {@link buildFoldedTurnsSection}（含结论摘要）。
 */
export function buildFoldedHistorySection(questions: string[], omitted: number): string {
  if (questions.length === 0 && omitted <= 0) {
    return ''
  }
  const turns: FoldedTurn[] = []
  for (let i: number = 0; i < questions.length; i++) {
    turns.push(new FoldedTurn(questions[i], ''))
  }
  return buildFoldedTurnsSection(turns, omitted)
}

/**
 * 取文本的首句（用于结论摘要）。
 *
 * 优先按中文句末标点切分，找不到标点时退回整段（由调用方截断）。
 *
 * @param text - 单行文本
 * @returns 首句
 */
function firstSentence(text: string): string {
  for (let i: number = 0; i < text.length; i++) {
    const ch: string = text.charAt(i)
    if (ch === '。' || ch === '！' || ch === '？' || ch === ';' || ch === '.') {
      return text.substring(0, i + 1)
    }
  }
  return text
}

/**
 * 截断到指定长度并加省略号。
 *
 * @param text - 文本
 * @param max - 最大长度
 * @returns 截断后的文本
 */
function clipLine(text: string, max: number): string {
  if (text.length <= max) {
    return text
  }
  return text.substring(0, max) + '…'
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
