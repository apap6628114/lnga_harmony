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

/** 工具定义（协议无关）。 */
export class AiToolDefinition {
  /** 工具名称 */
  name: string = ''
  /** 工具说明 */
  description: string = ''
  /** 参数 JSON Schema */
  parameters: Record<string, Object> = {}
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
