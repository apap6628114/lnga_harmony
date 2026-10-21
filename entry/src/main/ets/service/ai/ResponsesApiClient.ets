/**
 * OpenAI Responses API 客户端。
 *
 * 面向 DeepSeek 官方（`/responses`）以及任何兼容 Responses 契约的服务商：
 * - 语义化 SSE 事件流（response.* 事件，以 completed / incomplete / failed 结束）
 * - 无状态 API：多轮上下文由客户端回传历史 items（含 reasoning / function_call）
 * - function 工具：客户端执行后以 function_call_output 回传
 *
 * 协议细节与厂商无关，只使用 OpenAI Responses 公开字段；
 * 服务端内置工具（web_search 等）不在此声明，联网能力统一走客户端工具层。
 */

import { http } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { AiProviderProfile } from '../../model/AiConfig'
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

const logger = new Logger(DOMAIN_SERVICE, 'ResponsesApiClient')

/** 请求超时毫秒数（多步工具调用可能较长）。 */
const REQUEST_TIMEOUT: number = 120000
/** 连接超时毫秒数。 */
const CONNECT_TIMEOUT: number = 15000

/** 尚未完成的 function_call 累积项。 */
class PendingFunctionCall {
  /** 输出 item ID */
  itemId: string = ''
  /** 输出下标 */
  outputIndex: number = -1
  /** 调用 ID */
  callId: string = ''
  /** 函数名 */
  name: string = ''
  /** 参数 JSON 累积 */
  arguments: string = ''
}

/**
 * Responses 语义化 SSE 解析器。
 *
 * 只关心四类信息：正文增量、思维链增量、function_call 参数、最终 response。
 */
class ResponsesEventParser {
  /** 尚未解析成完整事件块的文本。 */
  private pendingText: string = ''
  /** 累积正文。 */
  private text: string = ''
  /** 累积思维链。 */
  private reasoning: string = ''
  /** 最终 response.output。 */
  private outputItems: Object[] = []
  /** response.failed 的错误信息。 */
  private errorMessage: string = ''
  /** 最终状态。 */
  private status: string = ''
  /** 未完成的 function_call 累积表。 */
  private pendingCalls: PendingFunctionCall[] = []

  /**
   * 追加响应文本并解析完整事件块。
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
    let eventType: string = ''
    let dataText: string = ''
    for (let i: number = 0; i < lines.length; i++) {
      const line: string = lines[i].trim()
      if (line.startsWith('event:')) {
        eventType = line.substring(6).trim()
      } else if (line.startsWith('data:')) {
        const payload: string = line.substring(5).trim()
        if (payload.length > 0) {
          if (dataText.length > 0) {
            dataText += '\n'
          }
          dataText += payload
        }
      }
    }
    if (dataText.length === 0) {
      return
    }

    let json: Record<string, Object> = {}
    try {
      json = JSON.parse(dataText) as Record<string, Object>
    } catch (e) {
      logger.warn('parseBlock: 非 JSON 数据块已跳过')
      return
    }
    if (eventType.length === 0) {
      const typeRaw: Object | undefined = json['type']
      eventType = typeof typeRaw === 'string' ? typeRaw as string : ''
    }
    if (eventType.length === 0) {
      return
    }
    this.dispatch(eventType, json, onDelta, onReasoning)
  }

  /**
   * 按事件类型分发。
   *
   * @param eventType - 事件类型
   * @param json - data JSON
   * @param onDelta - 正文增量回调
   * @param onReasoning - 思维链增量回调
   */
  private dispatch(
    eventType: string,
    json: Record<string, Object>,
    onDelta: ChatStreamChunkCallback,
    onReasoning: ReasoningStreamCallback
  ): void {
    if (eventType === 'response.output_text.delta') {
      const delta: string = readString(json, 'delta')
      if (delta.length > 0) {
        this.text += delta
        onDelta(delta)
      }
      return
    }
    if (eventType === 'response.reasoning_text.delta') {
      const delta: string = readString(json, 'delta')
      if (delta.length > 0) {
        this.reasoning += delta
        onReasoning(delta)
      }
      return
    }
    if (eventType === 'response.output_item.added') {
      this.handleOutputItemAdded(json)
      return
    }
    if (eventType === 'response.function_call_arguments.delta') {
      this.handleArgumentsDelta(json)
      return
    }
    if (eventType === 'response.function_call_arguments.done') {
      this.handleArgumentsDone(json)
      return
    }
    if (eventType === 'response.completed' || eventType === 'response.incomplete') {
      this.handleFinal(json)
      return
    }
    if (eventType === 'response.failed') {
      this.handleFailed(json)
    }
  }

  /**
   * 处理 output_item.added：登记 function_call 槽位。
   *
   * @param json - data JSON
   */
  private handleOutputItemAdded(json: Record<string, Object>): void {
    const itemRaw: Object | undefined = json['item']
    if (itemRaw === undefined || itemRaw === null) {
      return
    }
    const item: Record<string, Object> = itemRaw as Record<string, Object>
    if (readString(item, 'type') !== 'function_call') {
      return
    }
    const pending: PendingFunctionCall = new PendingFunctionCall()
    pending.itemId = readString(item, 'id')
    pending.callId = readString(item, 'call_id')
    pending.name = readString(item, 'name')
    pending.arguments = readString(item, 'arguments')
    const indexRaw: Object | undefined = json['output_index']
    pending.outputIndex = typeof indexRaw === 'number' ? indexRaw as number : -1
    this.pendingCalls.push(pending)
  }

  /**
   * 处理参数增量。
   *
   * @param json - data JSON
   */
  private handleArgumentsDelta(json: Record<string, Object>): void {
    const delta: string = readString(json, 'delta')
    if (delta.length === 0) {
      return
    }
    const target: PendingFunctionCall | null = this.findPendingCall(json)
    if (target !== null) {
      target.arguments += delta
    }
  }

  /**
   * 处理参数完整事件。
   *
   * @param json - data JSON
   */
  private handleArgumentsDone(json: Record<string, Object>): void {
    const args: string = readString(json, 'arguments')
    const target: PendingFunctionCall | null = this.findPendingCall(json)
    if (target !== null && args.length > target.arguments.length) {
      target.arguments = args
    }
  }

  /**
   * 定位参数增量所属的 function_call 槽位。
   *
   * @param json - data JSON
   * @returns 槽位，无匹配时返回 null
   */
  private findPendingCall(json: Record<string, Object>): PendingFunctionCall | null {
    const itemId: string = readString(json, 'item_id')
    if (itemId.length > 0) {
      for (let i: number = 0; i < this.pendingCalls.length; i++) {
        if (this.pendingCalls[i].itemId === itemId) {
          return this.pendingCalls[i]
        }
      }
    }
    const indexRaw: Object | undefined = json['output_index']
    if (typeof indexRaw === 'number') {
      const outputIndex: number = indexRaw as number
      for (let i: number = 0; i < this.pendingCalls.length; i++) {
        if (this.pendingCalls[i].outputIndex === outputIndex) {
          return this.pendingCalls[i]
        }
      }
    }
    if (this.pendingCalls.length > 0) {
      return this.pendingCalls[this.pendingCalls.length - 1]
    }
    return null
  }

  /**
   * 处理最终响应事件。
   *
   * @param json - data JSON
   */
  private handleFinal(json: Record<string, Object>): void {
    const responseRaw: Object | undefined = json['response']
    if (responseRaw === undefined || responseRaw === null) {
      return
    }
    const response: Record<string, Object> = responseRaw as Record<string, Object>
    const outputRaw: Object | undefined = response['output']
    if (outputRaw !== undefined && outputRaw !== null && Array.isArray(outputRaw)) {
      this.outputItems = outputRaw as Object[]
    }
    const status: string = readString(response, 'status')
    if (status.length > 0) {
      this.status = status
    }
    // 兜底：delta 丢失时从完整 output 提取正文
    const fullText: string = extractOutputText(this.outputItems)
    if (fullText.length > this.text.length) {
      this.text = fullText
    }
    this.mergePendingCallsFromOutput()
  }

  /**
   * 用最终 output 中的 function_call item 补全累积参数。
   */
  private mergePendingCallsFromOutput(): void {
    for (let i: number = 0; i < this.outputItems.length; i++) {
      const item: Record<string, Object> = this.outputItems[i] as Record<string, Object>
      if (readString(item, 'type') !== 'function_call') {
        continue
      }
      const callId: string = readString(item, 'call_id')
      const name: string = readString(item, 'name')
      const args: string = readString(item, 'arguments')
      let matched: PendingFunctionCall | null = null
      for (let j: number = 0; j < this.pendingCalls.length; j++) {
        const pending: PendingFunctionCall = this.pendingCalls[j]
        if ((callId.length > 0 && pending.callId === callId) ||
          (pending.name === name && pending.callId.length === 0)) {
          matched = pending
          break
        }
      }
      if (matched === null) {
        matched = new PendingFunctionCall()
        matched.callId = callId
        matched.name = name
        this.pendingCalls.push(matched)
      }
      if (callId.length > 0) {
        matched.callId = callId
      }
      if (name.length > 0) {
        matched.name = name
      }
      if (args.length > 0) {
        matched.arguments = args
      }
    }
  }

  /**
   * 处理 response.failed。
   *
   * @param json - data JSON
   */
  private handleFailed(json: Record<string, Object>): void {
    let message: string = ''
    const responseRaw: Object | undefined = json['response']
    if (responseRaw !== undefined && responseRaw !== null) {
      const response: Record<string, Object> = responseRaw as Record<string, Object>
      const errorRaw: Object | undefined = response['error']
      if (errorRaw !== undefined && errorRaw !== null) {
        message = readString(errorRaw as Record<string, Object>, 'message')
      }
    }
    if (message.length === 0) {
      const errorRaw: Object | undefined = json['error']
      if (errorRaw !== undefined && errorRaw !== null) {
        message = readString(errorRaw as Record<string, Object>, 'message')
      }
    }
    this.errorMessage = message.length > 0 ? message : 'AI 响应失败'
    logger.error('response.failed: %{public}s', this.errorMessage)
  }

  /**
   * 获取累积正文。
   *
   * @returns 正文
   */
  getText(): string {
    return this.text
  }

  /**
   * 获取累积思维链。
   *
   * @returns 思维链
   */
  getReasoning(): string {
    return this.reasoning
  }

  /**
   * 获取最终输出 items。
   *
   * @returns output items
   */
  getOutputItems(): Object[] {
    return this.outputItems
  }

  /**
   * 获取错误信息。
   *
   * @returns 错误信息，无错误时为空字符串
   */
  getError(): string {
    return this.errorMessage
  }

  /**
   * 获取响应状态。
   *
   * @returns status
   */
  getStatus(): string {
    return this.status
  }

  /**
   * 导出本轮工具调用。
   *
   * @returns 工具调用列表
   */
  getToolCalls(): ToolCall[] {
    const result: ToolCall[] = []
    for (let i: number = 0; i < this.pendingCalls.length; i++) {
      const pending: PendingFunctionCall = this.pendingCalls[i]
      if (pending.name.length === 0) {
        continue
      }
      const call: ToolCall = new ToolCall()
      call.id = pending.callId.length > 0 ? pending.callId : 'call_' + Date.now().toString(36) + '_' + i.toString()
      call.type = 'function'
      call.function = new ToolCallFunction()
      call.function.name = pending.name
      call.function.arguments = pending.arguments
      result.push(call)
    }
    return result
  }
}

/**
 * 发起一次 Responses API 请求。
 *
 * @param profile - AI 配置
 * @param messages - 对话消息
 * @param options - 请求选项
 * @param canceller - 可选取消令牌
 * @returns 单轮结果
 */
export async function requestResponses(
  profile: AiProviderProfile,
  messages: ChatMessage[],
  options: ChatTurnOptions,
  canceller?: RequestCanceller
): Promise<ChatTurnResult> {
  const url: string = buildChatUrl(profile.endpoint, profile.protocol)
  const body: string = buildResponsesBody(profile, messages, options)
  if (options.stream) {
    return streamResponses(url, profile.apiKey, body, options, canceller)
  }
  return requestResponsesOnce(url, profile.apiKey, body, options)
}

/**
 * 非流式请求。
 *
 * @param url - 请求 URL
 * @param apiKey - API 密钥
 * @param body - 请求体
 * @param options - 请求选项
 * @returns 单轮结果
 */
async function requestResponsesOnce(
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
    const result: ChatTurnResult = parseResponsesJson(responseText)
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
 * @param body - 请求体
 * @param options - 请求选项
 * @param canceller - 可选取消令牌
 * @returns 单轮结果
 */
function streamResponses(
  url: string,
  apiKey: string,
  body: string,
  options: ChatTurnOptions,
  canceller?: RequestCanceller
): Promise<ChatTurnResult> {
  const decoder: util.TextDecoder = util.TextDecoder.create('utf-8')
  const parser: ResponsesEventParser = new ResponsesEventParser()
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
        logger.warn('streamResponses watchdog timeout')
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
          const errMsg: string = parser.getError()
          if (errMsg.length > 0) {
            rejectOnce(new Error(errMsg))
            return
          }
          const text: string = parser.getText()
          const toolCalls: ToolCall[] = parser.getToolCalls()
          if (text.length === 0 && toolCalls.length === 0) {
            if (parser.getStatus() === 'incomplete') {
              rejectOnce(new Error('回答超长被截断，请更换支持更长输出的模型'))
            } else {
              rejectOnce(new Error('AI 响应为空或格式不兼容'))
            }
            return
          }
          const result: ChatTurnResult = new ChatTurnResult()
          result.text = text
          result.reasoning = parser.getReasoning()
          result.toolCalls = toolCalls
          result.outputItems = parser.getOutputItems()
          result.status = parser.getStatus()
          result.truncated = parser.getStatus() === 'incomplete'
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
          logger.warn('streamResponses: HTTP %{public}d', statusCode)
          errorStatusCode = statusCode
        }
      }).catch((err: Error): void => {
        logger.warn('streamResponses request error: %{public}s', err.message ?? '')
        rejectOnce(err)
      })
    })
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
 * 构造 Responses 请求体。
 *
 * 不携带 max_output_tokens：输出长度交给服务端按模型能力决定。
 *
 * @param profile - AI 配置
 * @param messages - 对话消息
 * @param options - 请求选项
 * @returns 请求体 JSON
 */
function buildResponsesBody(profile: AiProviderProfile, messages: ChatMessage[], options: ChatTurnOptions): string {
  const body: Record<string, Object> = {}
  body['model'] = profile.modelName
  body['stream'] = options.stream
  body['temperature'] = profile.temperature
  body['input'] = buildInputItems(messages)

  const instructions: string = collectInstructions(messages)
  if (instructions.length > 0) {
    body['instructions'] = instructions
  }
  if (options.tools.length > 0) {
    body['tools'] = serializeTools(options.tools)
    body['tool_choice'] = 'auto'
  }
  return JSON.stringify(body)
}

/**
 * 收集 system 消息作为 instructions。
 *
 * @param messages - 对话消息
 * @returns 拼接后的指令文本
 */
function collectInstructions(messages: ChatMessage[]): string {
  const parts: string[] = []
  for (let i: number = 0; i < messages.length; i++) {
    const msg: ChatMessage = messages[i]
    if (msg.role === 'system' && msg.content.trim().length > 0) {
      parts.push(msg.content)
    }
  }
  return parts.join('\n\n')
}

/**
 * 构造 Responses 输入 items。
 *
 * assistant 消息携带 outputItems 时原样展开（保持 reasoning / function_call
 * 原始顺序）；tool 消息转为 function_call_output。
 *
 * @param messages - 对话消息
 * @returns 输入 items 数组
 */
function buildInputItems(messages: ChatMessage[]): Object[] {
  const items: Object[] = []
  for (let i: number = 0; i < messages.length; i++) {
    const msg: ChatMessage = messages[i]
    if (msg.role === 'system') {
      continue
    }
    if (msg.role === 'tool') {
      const outputItem: Record<string, Object> = {}
      outputItem['type'] = 'function_call_output'
      outputItem['call_id'] = msg.toolCallId ?? ''
      outputItem['output'] = msg.content
      items.push(outputItem)
      continue
    }
    if (msg.role === 'assistant' && msg.outputItems !== undefined && msg.outputItems.length > 0) {
      for (let j: number = 0; j < msg.outputItems.length; j++) {
        items.push(msg.outputItems[j])
      }
      continue
    }
    if (msg.content.length === 0) {
      continue
    }
    const item: Record<string, Object> = {}
    item['type'] = 'message'
    item['role'] = msg.role === 'assistant' ? 'assistant' : 'user'
    const part: Record<string, string> = {}
    part['type'] = msg.role === 'assistant' ? 'output_text' : 'input_text'
    part['text'] = msg.content
    const content: Object[] = []
    content.push(part)
    item['content'] = content
    items.push(item)
  }
  return items
}

/**
 * 序列化工具声明（Responses 格式：函数字段扁平）。
 *
 * @param tools - 协议无关工具定义
 * @returns Responses tools 数组
 */
function serializeTools(tools: AiToolDefinition[]): Object[] {
  const result: Object[] = []
  for (let i: number = 0; i < tools.length; i++) {
    const tool: AiToolDefinition = tools[i]
    const item: Record<string, Object> = {}
    item['type'] = 'function'
    item['name'] = tool.name
    item['description'] = tool.description
    item['parameters'] = tool.parameters
    result.push(item)
  }
  return result
}

/**
 * 解析非流式响应 JSON。
 *
 * @param responseText - 响应文本
 * @returns 单轮结果
 */
function parseResponsesJson(responseText: string): ChatTurnResult {
  let json: Record<string, Object> = {}
  try {
    json = JSON.parse(responseText) as Record<string, Object>
  } catch (e) {
    throw new Error('AI 响应解析失败')
  }
  const errObj: Object | undefined = json['error']
  if (errObj !== undefined && errObj !== null) {
    const message: string = readString(errObj as Record<string, Object>, 'message')
    throw new Error(message.length > 0 ? message : 'AI 响应错误')
  }
  const result: ChatTurnResult = new ChatTurnResult()
  const outputRaw: Object | undefined = json['output']
  if (outputRaw !== undefined && outputRaw !== null && Array.isArray(outputRaw)) {
    result.outputItems = outputRaw as Object[]
  }
  result.text = extractOutputText(result.outputItems)
  result.reasoning = extractReasoningText(result.outputItems)
  result.toolCalls = extractToolCalls(result.outputItems)
  result.status = readString(json, 'status')
  result.truncated = result.status === 'incomplete'
  return result
}

/**
 * 从输出 items 提取正文。
 *
 * @param output - output items
 * @returns 正文文本
 */
function extractOutputText(output: Object[]): string {
  let text: string = ''
  for (let i: number = 0; i < output.length; i++) {
    const item: Record<string, Object> = output[i] as Record<string, Object>
    if (readString(item, 'type') !== 'message') {
      continue
    }
    const contentRaw: Object | undefined = item['content']
    if (contentRaw === undefined || contentRaw === null || !Array.isArray(contentRaw)) {
      continue
    }
    const content: Object[] = contentRaw as Object[]
    for (let j: number = 0; j < content.length; j++) {
      const part: Record<string, Object> = content[j] as Record<string, Object>
      if (readString(part, 'type') === 'output_text') {
        text += readString(part, 'text')
      }
    }
  }
  return text
}

/**
 * 从输出 items 提取思维链。
 *
 * @param output - output items
 * @returns 思维链文本
 */
function extractReasoningText(output: Object[]): string {
  let text: string = ''
  for (let i: number = 0; i < output.length; i++) {
    const item: Record<string, Object> = output[i] as Record<string, Object>
    if (readString(item, 'type') !== 'reasoning') {
      continue
    }
    const contentRaw: Object | undefined = item['content']
    if (contentRaw === undefined || contentRaw === null || !Array.isArray(contentRaw)) {
      continue
    }
    const content: Object[] = contentRaw as Object[]
    for (let j: number = 0; j < content.length; j++) {
      const part: Record<string, Object> = content[j] as Record<string, Object>
      if (readString(part, 'type') === 'reasoning_text') {
        text += readString(part, 'text')
      }
    }
  }
  return text
}

/**
 * 从输出 items 提取 function_call。
 *
 * @param output - output items
 * @returns 工具调用列表
 */
function extractToolCalls(output: Object[]): ToolCall[] {
  const result: ToolCall[] = []
  for (let i: number = 0; i < output.length; i++) {
    const item: Record<string, Object> = output[i] as Record<string, Object>
    if (readString(item, 'type') !== 'function_call') {
      continue
    }
    const name: string = readString(item, 'name')
    if (name.length === 0) {
      continue
    }
    const call: ToolCall = new ToolCall()
    const callId: string = readString(item, 'call_id')
    call.id = callId.length > 0 ? callId : 'call_' + Date.now().toString(36) + '_' + i.toString()
    call.type = 'function'
    call.function = new ToolCallFunction()
    call.function.name = name
    call.function.arguments = readString(item, 'arguments')
    result.push(call)
  }
  return result
}

/**
 * 安全读取字符串字段。
 *
 * @param record - 记录对象
 * @param key - 字段名
 * @returns 字符串值，缺失时为空字符串
 */
function readString(record: Record<string, Object>, key: string): string {
  const value: Object | undefined = record[key]
  return typeof value === 'string' ? value as string : ''
}
