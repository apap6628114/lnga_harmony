/**
 * AI 对话协议中立类型。
 *
 * 项目同时支持两条协议链路：
 * - Responses API（DeepSeek /responses，语义化 SSE 事件，服务端内置联网搜索）
 * - OpenAI 兼容 chat/completions（硅基流动、智谱、豆包、MiniMax、Kimi、OpenAI 等）
 *
 * 两条链路共用同一组入参/出参类型，因此这些类型必须放在不依赖任一协议
 * 实现的模块里，避免两个客户端互相 import 造成循环依赖。
 */

/** 流式响应文本增量回调。 */
export type ChatStreamChunkCallback = (chunk: string) => void

/** 服务端联网搜索状态回调。phase: searching | completed | failed */
export type WebSearchStateCallback = (phase: string, query: string) => void

/**
 * 对话消息。
 *
 * Responses API 用它构建输入 items；chat/completions 用它构建 messages 数组。
 * assistant 消息可携带该轮原始输出 items（含 web_search_call）用于多轮回传，
 * chat/completions 协议不识别该字段，序列化时直接忽略。
 */
export class ChatMessage {
  /** 消息角色（user / assistant / system） */
  role: string
  /** 消息内容 */
  content: string
  /** 该条 assistant 消息对应的原始响应输出 items（仅 Responses API 使用） */
  outputItems?: Object[]

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
 * 请求取消令牌。
 *
 * 页面销毁等场景可调用 cancel() 中断进行中的流式请求。
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

/**
 * 一次补全调用的中立结果。
 *
 * 两条协议解析后统一收敛到该结构，上层（ActiveAiService / 页面）无需区分协议。
 */
export class AiCompletionResult {
  /** 助手回复完整文本 */
  content: string = ''
  /** 本响应的输出 items（仅 Responses API 有值，用于多轮回传）；chat/completions 恒为空数组 */
  outputItems: Object[] = []
  /** 响应状态（Responses: 'completed' | 'incomplete'；chat/completions: 'completed'） */
  status: string = ''
  /** 是否因达到输出长度上限被截断 */
  truncated: boolean = false
}
