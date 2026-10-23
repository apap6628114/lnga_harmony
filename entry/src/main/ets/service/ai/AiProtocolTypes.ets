/**
 * AI 协议无关的公共类型。
 *
 * 两种对话协议（Responses / Chat Completions）共用同一套消息、工具与
 * 回调类型，协议差异只存在于各自的客户端里。
 */

/** 流式文本增量回调。 */
export type ChatStreamChunkCallback = (chunk: string) => void

/** 思维链增量回调。 */
export type ReasoningStreamCallback = (chunk: string) => void

/** 工具调用参数。 */
export class ToolCallFunction {
  /** 工具名称 */
  name: string = ''
  /** JSON 字符串参数 */
  arguments: string = ''
}

/** 模型发起的一次工具调用。 */
export class ToolCall {
  /** 调用 ID（回传结果时配对） */
  id: string = ''
  /** 工具类型，固定 function */
  type: string = 'function'
  /** 函数信息 */
  function: ToolCallFunction = new ToolCallFunction()
}

/**
 * 对话消息。
 *
 * 同一对象在两种协议下分别序列化：
 * - Chat Completions 用 role/content/toolCalls/toolCallId；
 * - Responses 用 role/content/outputItems（原始 items 原样回传）。
 */
export class ChatMessage {
  /** 消息角色（system / user / assistant / tool） */
  role: string
  /** 消息内容 */
  content: string
  /** assistant 消息请求的工具调用（Chat Completions 用） */
  toolCalls?: ToolCall[]
  /** tool 消息对应的调用 ID（Chat Completions 用） */
  toolCallId?: string
  /** tool 消息对应的工具名（部分服务商要求） */
  name?: string
  /** Responses API 的原始输出 items（含 reasoning / function_call） */
  outputItems?: Object[]
  /** assistant 思维链文本（可选） */
  reasoning?: string

  /**
   * 创建对话消息。
   *
   * @param role - 消息角色
   * @param content - 消息内容
   */
  constructor(role: string, content: string) {
    this.role = role
    this.content = content
  }
}

/**
 * 工具行为注解（对齐 MCP `Tool.annotations`）。
 *
 * 只作为客户端元数据使用，**不参与请求体序列化**：OpenAI 的 function 定义
 * 只认 name / description / parameters / strict，多塞字段会被部分服务商以
 * 400 拒绝。这些标记供 Agent 循环与 UI 判定「能否并行、能否缓存、要不要确认」。
 */
export class AiToolAnnotations {
  /** 只读：不改变任何远端状态 */
  readOnly: boolean = true
  /** 破坏性：可能造成不可逆变更（写操作） */
  destructive: boolean = false
  /** 幂等：同参数重复调用结果一致，可安全重试 */
  idempotent: boolean = true
  /** 开放世界：结果依赖站外 / 实时数据，缓存价值低 */
  openWorld: boolean = false
}

/**
 * 工具定义（协议无关）。
 *
 * `title` 与 `annotations` 是客户端侧字段：前者用于 UI 展示（对齐 MCP `Tool.title`），
 * 后者用于行为判定。序列化请求体时只发送协议认识的字段。
 */
export class AiToolDefinition {
  /** 工具名称 */
  name: string = ''
  /** 人类可读展示名（客户端用，不下发） */
  title: string = ''
  /** 工具说明 */
  description: string = ''
  /** 参数 JSON Schema */
  parameters: Record<string, Object> = {}
  /** 行为注解（客户端用，不下发） */
  annotations: AiToolAnnotations = new AiToolAnnotations()
}

/**
 * 一次模型请求的 token 用量。
 *
 * 服务端返回 usage 时才有值；`cachedTokens` 是前缀缓存命中的输入 token 数，
 * 是判断「上下文前缀是否稳定」的唯一量化依据。
 */
export class AiTokenUsage {
  /** 输入 token 数 */
  promptTokens: number = 0
  /** 输出 token 数 */
  completionTokens: number = 0
  /** 总 token 数 */
  totalTokens: number = 0
  /** 命中前缀缓存的输入 token 数（不计费或按折扣计费） */
  cachedTokens: number = 0
  /**
   * 服务端是否真的报告了缓存字段。
   *
   * 不能只看 `cachedTokens > 0`：有的服务商返回了缓存字段但本次恰好 0 命中，
   * 这与"根本不返回缓存统计"是两件事。只有 `cacheReported=true` 时，页面
   * 展示的 0% 才是可信的"未命中"，否则应显示"未知"。
   */
  cacheReported: boolean = false

  /**
   * 判断是否拿到任何用量信息。
   *
   * @returns true 表示至少有一个字段非零
   */
  isEmpty(): boolean {
    return this.promptTokens === 0 && this.completionTokens === 0 &&
      this.totalTokens === 0 && this.cachedTokens === 0
  }

  /**
   * 累加另一份额度。
   *
   * @param other - 待累加的用量
   */
  add(other: AiTokenUsage): void {
    this.promptTokens += other.promptTokens
    this.completionTokens += other.completionTokens
    this.totalTokens += other.totalTokens
    this.cachedTokens += other.cachedTokens
    this.cacheReported = this.cacheReported || other.cacheReported
  }
}

/** 单轮请求结果。 */
export class ChatTurnResult {
  /** 本轮正文文本 */
  text: string = ''
  /** 本轮思维链文本 */
  reasoning: string = ''
  /** 本轮模型请求的工具调用 */
  toolCalls: ToolCall[] = []
  /** Responses API 原始输出 items（回传历史用） */
  outputItems: Object[] = []
  /** 协议原始状态（Responses: completed/incomplete；Chat: finish_reason） */
  status: string = ''
  /** 是否因输出上限被截断 */
  truncated: boolean = false
  /** 本轮 token 用量（服务端未返回时为空用量） */
  usage: AiTokenUsage = new AiTokenUsage()
}

/** 单轮请求选项。 */
export class ChatTurnOptions {
  /** 工具声明（空数组表示不带工具） */
  tools: AiToolDefinition[] = []
  /** 是否流式 */
  stream: boolean = true
  /** 文本增量回调 */
  onDelta: ChatStreamChunkCallback = (_chunk: string): void => {
  }
  /** 思维链增量回调 */
  onReasoning: ReasoningStreamCallback = (_chunk: string): void => {
  }
}

/**
 * 请求取消令牌。
 *
 * 页面销毁或用户点「停止」时调用 cancel() 中断进行中的流式请求。
 */
export class RequestCanceller {
  /** 是否已取消。 */
  private cancelled: boolean = false
  /** 取消处理器（由客户端内部注册）。 */
  private handler: (() => void) | null = null

  /**
   * 发起取消，触发客户端中断请求。
   */
  cancel(): void {
    if (this.cancelled) {
      return
    }
    this.cancelled = true
    if (this.handler) {
      this.handler()
    }
  }

  /**
   * 判断是否已取消。
   *
   * @returns true 表示已取消
   */
  isCancelled(): boolean {
    return this.cancelled
  }

  /**
   * 注册取消处理器（仅供客户端内部使用）。
   *
   * @param handler - 取消时执行的回调
   */
  setHandler(handler: () => void): void {
    this.handler = handler
  }
}
