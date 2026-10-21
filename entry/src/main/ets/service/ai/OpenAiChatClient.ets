/**
 * OpenAI Chat Completions 兼容客户端。
 *
 * 面向自定义服务商（第三方聚合平台、自建网关、本地模型等）：
 * 只依赖 OpenAI 公开的 `/chat/completions` 契约——`messages` /
 * `tools` / `tool_calls` / `finish_reason`，不猜测任何厂商私有字段。
 *
 * 支持流式增量、思维链增量、流式 tool_calls 参数拼接与取消。
 */

import { http } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { AiApiProtocol, AiProviderProfile } from '../../model/AiConfig'
import { buildChatUrl, extractServerError } from './AiEndpoint'
import {
  AiToolDefinition,
  ChatMessage,
  ChatStreamChunkCallback,
  ChatTurnOptions,
  ChatTurnResult,
  ReasoningStreamCallback,
  RequestCanceller,
  ToolCall,
  ToolCallFunction
} from './AiProtocolTypes'
import { Logger, DOMAIN_SERVICE } from '../../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'OpenAiChatClient')

/** 请求超时毫秒数。 */
const REQUEST_TIMEOUT: number = 90000
/** 连接超时毫秒数。 */
const CONNECT_TIMEOUT: number = 15000

/** 流式工具调用累积项。 */
class PendingToolCall {
  /** 调用 ID */
  id: string = ''
  /** 函数名称 */
  name: string = ''
  /** 参数 JSON 片段累积 */
  arguments: string = ''
}

/**
 * Chat Completions 流式解析器。
 *
 * 负责把 SSE 文本切块、解析 `choices[0].delta` 并拼接 tool_calls 参数。
 */
class ChatCompletionsStreamParser {
  /** 尚未形成完整事件块的缓冲文本。 */
  private pendingText: string = ''
  /** 累积正文。 */
  private text: string = ''
  /** 累积思维链。 */
  private reasoning: string = ''
  /** 累积工具调用（按出现顺序）。 */
  private pendingToolCalls: PendingToolCall[] = []
  /** finish_reason。 */
  private finishReason: string = ''
  /** 是否已收到 [DONE]。 */
  private done: boolean = false

  /**
   * 追加一段响应文本并解析其中完整的事件块。
   *
   * @param text - 新收到的文本
   * @param onDelta - 正文增量回调
   * @param onReasoning - 思维链增量回调
   */
  append(text: string, onDelta: ChatStreamChunkCallback, onReasoning: ReasoningStreamCallback): void {
    this.pendingText += text
    this.pendingText = this.pendingText.replace(/\r\n/g, '\n').replace(/\r/g, '\n')
    let separatorIndex: number = this.pendingText.indexOf('\n\n')
    while (separatorIndex >= 0) {
      const block: string = this.pendingText.substring(0, separatorIndex)
      this.pendingText = this.pendingText.substring(separatorIndex + 2)
      this.parseBlock(block, onDelta, onReasoning)
      separatorIndex = this.pendingText.indexOf('\n\n')
    }
  }

  /**
   * 结束解析并处理剩余缓冲。
   *
   * @param onDelta - 正文增量回调
   * @param onReasoning - 思维链增量回调
   */
  finish(onDelta: ChatStreamChunkCallback, onReasoning: ReasoningStreamCallback): void {
    if (this.pendingText.trim().length > 0) {
      this.parseBlock(this.pendingText, onDelta, onReasoning)
      this.pendingText = ''
    }
  }

  /**
   * 解析单个 SSE 事件块。
   *
   * @param block - 事件块文本
   * @param onDelta - 正文增量回调
   * @param onReasoning - 思维链增量回调
   */
  private parseBlock(block: string, onDelta: ChatStreamChunkCallback, onReasoning: ReasoningStreamCallback): void {
    const lines: string[] = block.split('\n')
    let dataText: string = ''
    for (let i: number = 0; i < lines.length; i++) {
      const line: string = lines[i].trim()
      if (!line.startsWith('data:')) {
        continue
      }
      const payload: string = line.substring(5).trim()
      if (payload.length === 0) {
        continue
      }
      if (dataText.length > 0) {
        dataText += '\n'
      }
      dataText += payload
    }
    if (dataText.length === 0) {
      return
    }
    if (dataText === '[DONE]') {
      this.done = true
      return
    }
    this.parseChunk(dataText, onDelta, onReasoning)
  }

  /**
   * 解析单条 data JSON。
   *
   * @param dataText - data JSON 文本
   * @param onDelta - 正文增量回调
   * @param onReasoning - 思维链增量回调
   */
  private parseChunk(dataText: string, onDelta: ChatStreamChunkCallback, onReasoning: ReasoningStreamCallback): void {
    let json: Record<string, Object> = {}
    try {
      json = JSON.parse(dataText) as Record<string, Object>
    } catch (e) {
      logger.warn('parseChunk: 非 JSON 数据块已跳过')
      return
    }
    const errObj: Object | undefined = json['error']
    if (errObj !== undefined && errObj !== null) {
      const errRecord: Record<string, Object> = errObj as Record<string, Object>
      const messageRaw: Object | undefined = errRecord['message']
      const message: string = typeof messageRaw === 'string' ? messageRaw as string : 'AI 响应错误'
      throw new Error(message)
    }

    const choicesRaw: Object | undefined = json['choices']
    if (choicesRaw === undefined || choicesRaw === null || !Array.isArray(choicesRaw)) {
      return
    }
    const choices: Object[] = choicesRaw as Object[]
    if (choices.length === 0) {
      return
    }
    const choice: Record<string, Object> = choices[0] as Record<string, Object>

    const finishRaw: Object | undefined = choice['finish_reason']
    if (typeof finishRaw === 'string' && (finishRaw as string).length > 0) {
      this.finishReason = finishRaw as string
    }

    const deltaRaw: Object | undefined = choice['delta']
    if (deltaRaw === undefined || deltaRaw === null) {
      return
    }
    const delta: Record<string, Object> = deltaRaw as Record<string, Object>

    const contentRaw: Object | undefined = delta['content']
    if (typeof contentRaw === 'string') {
      const content: string = contentRaw as string
      if (content.length > 0) {
        this.text += content
        onDelta(content)
      }
    }

    const reasoningRaw: Object | undefined = delta['reasoning_content']
    if (typeof reasoningRaw === 'string') {
      const reasoning: string = reasoningRaw as string
      if (reasoning.length > 0) {
        this.reasoning += reasoning
        onReasoning(reasoning)
      }
    }

    const toolCallsRaw: Object | undefined = delta['tool_calls']
    if (toolCallsRaw !== undefined && toolCallsRaw !== null && Array.isArray(toolCallsRaw)) {
      this.appendToolCalls(toolCallsRaw as Object[])
    }
  }

  /**
   * 拼接流式 tool_calls 片段。
   *
   * @param rawCalls - delta.tool_calls 数组
   */
  private appendToolCalls(rawCalls: Object[]): void {
    for (let i: number = 0; i < rawCalls.length; i++) {
      const raw: Record<string, Object> = rawCalls[i] as Record<string, Object>
      const indexRaw: Object | undefined = raw['index']
      const index: number = typeof indexRaw === 'number' ? indexRaw as number : i
      const slot: PendingToolCall = this.ensureSlot(index)

      const idRaw: Object | undefined = raw['id']
      if (typeof idRaw === 'string' && (idRaw as string).length > 0) {
        slot.id = idRaw as string
      }

      const funcRaw: Object | undefined = raw['function']
      if (funcRaw !== undefined && funcRaw !== null) {
        const func: Record<string, Object> = funcRaw as Record<string, Object>
        const nameRaw: Object | undefined = func['name']
        if (typeof nameRaw === 'string' && (nameRaw as string).length > 0) {
          slot.name = nameRaw as string
        }
        const argsRaw: Object | undefined = func['arguments']
        if (typeof argsRaw === 'string') {
          slot.arguments += argsRaw as string
        }
      }
    }
  }

  /**
   * 取得指定下标的累积槽位。
   *
   * @param index - tool_calls 下标
   * @returns 累积槽位
   */
  private ensureSlot(index: number): PendingToolCall {
    while (this.pendingToolCalls.length <= index) {
      this.pendingToolCalls.push(new PendingToolCall())
    }
    return this.pendingToolCalls[index]
  }

  /**
   * 导出累积的工具调用列表。
   *
   * @returns 工具调用列表（无名称的槽位被丢弃）
   */
  toToolCalls(): ToolCall[] {
    const result: ToolCall[] = []
    for (let i: number = 0; i < this.pendingToolCalls.length; i++) {
      const pending: PendingToolCall = this.pendingToolCalls[i]
      if (pending.name.length === 0) {
        continue
      }
      const call: ToolCall = new ToolCall()
      call.id = pending.id.length > 0 ? pending.id : 'call_' + Date.now().toString(36) + '_' + i.toString()
      call.type = 'function'
      call.function = new ToolCallFunction()
      call.function.name = pending.name
      call.function.arguments = pending.arguments
      result.push(call)
    }
    return result
  }

  /**
   * 获取累积正文。
   *
   * @returns 正文文本
   */
  getText(): string {
    return this.text
  }

  /**
   * 获取累积思维链。
   *
   * @returns 思维链文本
   */
  getReasoning(): string {
    return this.reasoning
  }

  /**
   * 获取 finish_reason。
   *
   * @returns finish_reason 文本
   */
  getFinishReason(): string {
    return this.finishReason
  }

  /**
   * 判断是否已收到 [DONE]。
   *
   * @returns true 表示流已正常结束
   */
  isDone(): boolean {
    return this.done
  }
}

/**
 * 发起一次 Chat Completions 请求。
 *
 * @param profile - AI 配置
 * @param messages - 对话消息
 * @param options - 请求选项（工具、流式、回调）
 * @param canceller - 可选取消令牌
 * @returns 单轮结果
 */
export async function requestChatCompletions(
  profile: AiProviderProfile,
  messages: ChatMessage[],
  options: ChatTurnOptions,
  canceller?: RequestCanceller
): Promise<ChatTurnResult> {
  const url: string = buildChatUrl(profile.endpoint, AiApiProtocol.CHAT_COMPLETIONS)
  const body: string = buildChatBody(profile, messages, options)
  if (options.stream) {
    return streamChatCompletions(url, profile.apiKey, body, options, canceller)
  }
  return requestChatCompletionsOnce(url, profile.apiKey, body, options)
}

/**
 * 非流式请求。
 *
 * @param url - 请求 URL
 * @param apiKey - API 密钥
 * @param body - 请求体 JSON
 * @param options - 请求选项
 * @returns 单轮结果
 */
async function requestChatCompletionsOnce(
  url: string,
  apiKey: string,
  body: string,
  options: ChatTurnOptions
): Promise<ChatTurnResult> {
  const httpRequest: http.HttpRequest = http.createHttp()
  try {
    const response: http.HttpResponse = await httpRequest.request(url, {
      method: http.RequestMethod.POST,
      header: buildHeaders(apiKey, false),
      extraData: body,
      expectDataType: http.HttpDataType.STRING,
      readTimeout: REQUEST_TIMEOUT,
      connectTimeout: CONNECT_TIMEOUT
    })
    const statusCode: number = response.responseCode
    const responseText: string = (response.result as string) ?? ''
    if (statusCode !== 200) {
      const detail: string = extractServerError(responseText)
      throw new Error(statusCode.toString() + (detail.length > 0 ? '\n' + detail : ''))
    }
    const result: ChatTurnResult = parseChatResponse(responseText)
    if (result.text.length > 0) {
      options.onDelta(result.text)
    }
    if (result.reasoning.length > 0) {
      options.onReasoning(result.reasoning)
    }
    return result
  } finally {
    httpRequest.destroy()
  }
}

/**
 * 流式请求。
 *
 * @param url - 请求 URL
 * @param apiKey - API 密钥
 * @param body - 请求体 JSON
 * @param options - 请求选项
 * @param canceller - 可选取消令牌
 * @returns 单轮结果
 */
function streamChatCompletions(
  url: string,
  apiKey: string,
  body: string,
  options: ChatTurnOptions,
  canceller?: RequestCanceller
): Promise<ChatTurnResult> {
  const decoder: util.TextDecoder = util.TextDecoder.create('utf-8')
  const parser: ChatCompletionsStreamParser = new ChatCompletionsStreamParser()
  const httpRequest: http.HttpRequest = http.createHttp()

  return new Promise<ChatTurnResult>(
    (resolve: (value: ChatTurnResult) => void, reject: (reason: Error) => void): void => {
      let settled: boolean = false
      let streamError: Error | null = null
      let watchdog: number = -1
      let errorStatusCode: number = 0
      let errorBody: string = ''

      const cleanup = (): void => {
        if (watchdog >= 0) {
          clearTimeout(watchdog)
          watchdog = -1
        }
        httpRequest.off('dataReceive', dataReceiveCallback)
        httpRequest.off('dataEnd', dataEndCallback)
        httpRequest.destroy()
      }

      const rejectOnce = (error: Error): void => {
        if (settled) {
          return
        }
        settled = true
        cleanup()
        reject(error)
      }

      const resolveOnce = (result: ChatTurnResult): void => {
        if (settled) {
          return
        }
        settled = true
        cleanup()
        resolve(result)
      }

      watchdog = setTimeout((): void => {
        logger.warn('streamChatCompletions watchdog timeout')
        rejectOnce(new Error('AI 请求超时，请稍后重试'))
      }, REQUEST_TIMEOUT)

      const dataReceiveCallback = (data: ArrayBuffer): void => {
        try {
          const text: string = decoder.decodeToString(new Uint8Array(data), { stream: true })
          if (text.length === 0) {
            return
          }
          if (errorStatusCode !== 0) {
            errorBody += text
            return
          }
          parser.append(text, options.onDelta, options.onReasoning)
        } catch (err) {
          const e: Error = err as Error
          streamError = new Error(e.message || 'AI 流式响应解析失败')
        }
      }

      const dataEndCallback = (): void => {
        try {
          if (streamError) {
            rejectOnce(streamError)
            return
          }
          const tail: string = decoder.decodeToString(new Uint8Array(new ArrayBuffer(0)), { stream: false })
          if (errorStatusCode !== 0) {
            if (tail.length > 0) {
              errorBody += tail
            }
            const detail: string = extractServerError(errorBody)
            rejectOnce(new Error(errorStatusCode.toString() + (detail.length > 0 ? '\n' + detail : '')))
            return
          }
          if (tail.length > 0) {
            parser.append(tail, options.onDelta, options.onReasoning)
          }
          parser.finish(options.onDelta, options.onReasoning)
          const text: string = parser.getText()
          const toolCalls: ToolCall[] = parser.toToolCalls()
          if (text.length === 0 && toolCalls.length === 0) {
            rejectOnce(new Error('AI 响应为空或格式不兼容'))
            return
          }
          const result: ChatTurnResult = new ChatTurnResult()
          result.text = text
          result.reasoning = parser.getReasoning()
          result.toolCalls = toolCalls
          result.status = parser.getFinishReason()
          result.truncated = parser.getFinishReason() === 'length'
          resolveOnce(result)
        } catch (err) {
          const e: Error = err as Error
          rejectOnce(new Error(e.message || 'AI 流式响应解析失败'))
        }
      }

      if (canceller) {
        canceller.setHandler((): void => {
          httpRequest.destroy()
          rejectOnce(new Error('请求已取消'))
        })
      }

      httpRequest.on('dataReceive', dataReceiveCallback)
      httpRequest.on('dataEnd', dataEndCallback)
      httpRequest.requestInStream(url, {
        method: http.RequestMethod.POST,
        header: buildHeaders(apiKey, true),
        extraData: body,
        readTimeout: REQUEST_TIMEOUT,
        connectTimeout: CONNECT_TIMEOUT
      }).then((statusCode: number): void => {
        if (statusCode !== 200) {
          logger.warn('streamChatCompletions: HTTP %{public}d', statusCode)
          errorStatusCode = statusCode
        }
      }).catch((err: Error): void => {
        logger.warn('streamChatCompletions request error: %{public}s', err.message ?? '')
        rejectOnce(err)
      })
    })
}

/**
 * 解析非流式响应 JSON。
 *
 * @param responseText - 响应文本
 * @returns 单轮结果
 */
function parseChatResponse(responseText: string): ChatTurnResult {
  const result: ChatTurnResult = new ChatTurnResult()
  let json: Record<string, Object> = {}
  try {
    json = JSON.parse(responseText) as Record<string, Object>
  } catch (e) {
    throw new Error('AI 响应解析失败')
  }
  const choicesRaw: Object | undefined = json['choices']
  if (choicesRaw === undefined || choicesRaw === null || !Array.isArray(choicesRaw)) {
    throw new Error('AI 响应缺少 choices')
  }
  const choices: Object[] = choicesRaw as Object[]
  if (choices.length === 0) {
    return result
  }
  const choice: Record<string, Object> = choices[0] as Record<string, Object>
  const finishRaw: Object | undefined = choice['finish_reason']
  result.status = typeof finishRaw === 'string' ? finishRaw as string : ''
  result.truncated = result.status === 'length'

  const messageRaw: Object | undefined = choice['message']
  if (messageRaw === undefined || messageRaw === null) {
    return result
  }
  const message: Record<string, Object> = messageRaw as Record<string, Object>
  const contentRaw: Object | undefined = message['content']
  result.text = typeof contentRaw === 'string' ? contentRaw as string : ''
  const reasoningRaw: Object | undefined = message['reasoning_content']
  result.reasoning = typeof reasoningRaw === 'string' ? reasoningRaw as string : ''

  const toolCallsRaw: Object | undefined = message['tool_calls']
  if (toolCallsRaw !== undefined && toolCallsRaw !== null && Array.isArray(toolCallsRaw)) {
    result.toolCalls = parseToolCalls(toolCallsRaw as Object[])
  }
  return result
}

/**
 * 解析非流式 tool_calls 数组。
 *
 * @param rawCalls - tool_calls 数组
 * @returns 工具调用列表
 */
function parseToolCalls(rawCalls: Object[]): ToolCall[] {
  const result: ToolCall[] = []
  for (let i: number = 0; i < rawCalls.length; i++) {
    const raw: Record<string, Object> = rawCalls[i] as Record<string, Object>
    const funcRaw: Object | undefined = raw['function']
    if (funcRaw === undefined || funcRaw === null) {
      continue
    }
    const func: Record<string, Object> = funcRaw as Record<string, Object>
    const nameRaw: Object | undefined = func['name']
    const name: string = typeof nameRaw === 'string' ? nameRaw as string : ''
    if (name.length === 0) {
      continue
    }
    const idRaw: Object | undefined = raw['id']
    const argsRaw: Object | undefined = func['arguments']
    const call: ToolCall = new ToolCall()
    call.id = typeof idRaw === 'string' ? idRaw as string : 'call_' + Date.now().toString(36) + '_' + i.toString()
    call.type = 'function'
    call.function = new ToolCallFunction()
    call.function.name = name
    call.function.arguments = typeof argsRaw === 'string' ? argsRaw as string : ''
    result.push(call)
  }
  return result
}

/**
 * 构造请求头。
 *
 * @param apiKey - API 密钥
 * @param stream - 是否流式
 * @returns 请求头
 */
function buildHeaders(apiKey: string, stream: boolean): Record<string, string> {
  const headers: Record<string, string> = {}
  headers['Content-Type'] = 'application/json'
  headers['Accept'] = stream ? 'text/event-stream' : 'application/json'
  headers['Authorization'] = 'Bearer ' + apiKey
  return headers
}

/**
 * 构造请求体 JSON。
 *
 * @param profile - AI 配置
 * @param messages - 对话消息
 * @param options - 请求选项
 * @returns 请求体 JSON 文本
 */
function buildChatBody(profile: AiProviderProfile, messages: ChatMessage[], options: ChatTurnOptions): string {
  const body: Record<string, Object | null> = {}
  body['model'] = profile.modelName
  body['stream'] = options.stream
  body['temperature'] = profile.temperature
  body['messages'] = serializeMessages(messages)
  if (options.tools.length > 0) {
    body['tools'] = serializeTools(options.tools)
    body['tool_choice'] = 'auto'
  }
  return JSON.stringify(body)
}

/**
 * 序列化消息列表。
 *
 * @param messages - 对话消息
 * @returns 协议消息数组
 */
function serializeMessages(messages: ChatMessage[]): Object[] {
  const result: Object[] = []
  for (let i: number = 0; i < messages.length; i++) {
    const msg: ChatMessage = messages[i]
    const item: Record<string, Object | null> = {}
    item['role'] = msg.role
    if (msg.role === 'assistant' && msg.toolCalls !== undefined && msg.toolCalls.length > 0) {
      item['content'] = msg.content.length > 0 ? msg.content : null
      item['tool_calls'] = serializeToolCalls(msg.toolCalls)
    } else if (msg.role === 'tool') {
      item['content'] = msg.content
      item['tool_call_id'] = msg.toolCallId ?? ''
      if (msg.name !== undefined && msg.name.length > 0) {
        item['name'] = msg.name
      }
    } else {
      item['content'] = msg.content
    }
    result.push(item)
  }
  return result
}

/**
 * 序列化工具调用列表（回传历史用）。
 *
 * @param toolCalls - 工具调用
 * @returns 协议 tool_calls 数组
 */
function serializeToolCalls(toolCalls: ToolCall[]): Object[] {
  const result: Object[] = []
  for (let i: number = 0; i < toolCalls.length; i++) {
    const call: ToolCall = toolCalls[i]
    const item: Record<string, Object> = {}
    item['id'] = call.id
    item['type'] = call.type
    const func: Record<string, string> = {}
    func['name'] = call.function.name
    func['arguments'] = call.function.arguments
    item['function'] = func
    result.push(item)
  }
  return result
}

/**
 * 序列化工具声明。
 *
 * @param tools - 协议无关工具定义
 * @returns Chat Completions tools 数组
 */
function serializeTools(tools: AiToolDefinition[]): Object[] {
  const result: Object[] = []
  for (let i: number = 0; i < tools.length; i++) {
    const tool: AiToolDefinition = tools[i]
    const func: Record<string, Object> = {}
    func['name'] = tool.name
    func['description'] = tool.description
    func['parameters'] = tool.parameters
    const item: Record<string, Object> = {}
    item['type'] = 'function'
    item['function'] = func
    result.push(item)
  }
  return result
}
