/**
 * DeepSeek Responses API 客户端。
 *
 * 全面对接 DeepSeek 的 /responses 端点：
 * - 内置服务端联网搜索工具 web_search，无需任何第三方搜索服务
 * - 语义化 SSE 事件流（response.* 事件序列，以 response.completed / incomplete / failed 结束）
 * - 无状态 API：多轮上下文由客户端回传历史 items（含 web_search_call 原样回传）
 */

import { http } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { Logger, DOMAIN_SERVICE } from '../../common/utils/Logger'
import type { AiProviderProfile } from '../../model/AiConfig'
import { AiTestResult, DEFAULT_DEEPSEEK_ENDPOINT } from '../../model/AiConfig'

const logger = new Logger(DOMAIN_SERVICE, 'ResponsesCli')

/** 请求超时毫秒数（联网搜索可能比普通对话耗时更长） */
const REQUEST_TIMEOUT: number = 90000
/** 连接超时毫秒数 */
const CONNECT_TIMEOUT: number = 15000
/** 服务端内置联网搜索工具类型名 */
const WEB_SEARCH_TOOL_TYPE: string = 'web_search'

/** 流式响应文本增量回调。 */
export type ChatStreamChunkCallback = (chunk: string) => void

/** 服务端联网搜索状态回调。phase: searching | completed | failed */
export type WebSearchStateCallback = (phase: string, query: string) => void

/**
 * 对话消息。
 *
 * 用于构建 Responses API 输入 items。
 * assistant 消息可携带该轮原始输出 items（含 web_search_call），回传历史时原样展开。
 */
export class ChatMessage {
  /** 消息角色（user / assistant / system） */
  role: string
  /** 消息内容 */
  content: string
  /** 该条 assistant 消息对应的原始响应输出 items（可选） */
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

/** Responses API 调用结果。 */
export class ResponseResult {
  /** 助手回复完整文本 */
  content: string = ''
  /** 本响应的输出 items 数组（用于多轮对话回传） */
  outputItems: Object[] = []
  /** 响应状态（'completed' | 'incomplete'） */
  status: string = ''
  /** 是否因达到 max_output_tokens 被截断 */
  truncated: boolean = false
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
 * Responses API 语义化 SSE 事件解析器。
 *
 * 事件格式为 OpenAI Responses 兼容的：
 *   event: <type>
 *   data: { ...json... }
 * 同时兼容 data JSON 内直接携带 event 字段的格式（DeepSeek 文档描述）。
 */
class ResponsesEventParser {
  /** 尚未解析成完整事件的文本。 */
  private pendingText: string = ''
  /** 累积的助手回复文本。 */
  private text: string = ''
  /** 最终响应携带的完整输出 items。 */
  private outputItems: Object[] = []
  /** response.failed 事件携带的错误信息。 */
  private errorMessage: string = ''
  /** 最终响应状态（'completed' | 'incomplete'）。 */
  private status: string = ''
  /** 最近一次搜索关键词。 */
  private lastSearchQuery: string = ''

  /**
   * 追加一段响应文本并解析其中完整的事件。
   *
   * @param text - 新收到的 UTF-8 文本
   * @param onDelta - 文本增量回调
   * @param onSearch - 服务端搜索状态回调
   */
  append(text: string, onDelta: ChatStreamChunkCallback, onSearch: WebSearchStateCallback): void {
    this.pendingText += text
    this.pendingText = this.pendingText.replace(/\r\n/g, '\n').replace(/\r/g, '\n')
    this.parseAvailableEvents(onDelta, onSearch)
  }

  /**
   * 结束解析并处理剩余缓冲。
   *
   * @param onDelta - 文本增量回调
   * @param onSearch - 服务端搜索状态回调
   * @returns 助手回复完整文本
   */
  finish(onDelta: ChatStreamChunkCallback, onSearch: WebSearchStateCallback): string {
    if (this.pendingText.trim().length > 0) {
      this.parseEvent(this.pendingText, onDelta, onSearch)
      this.pendingText = ''
    }
    return this.text
  }

  /**
   * 获取解析到的错误信息。
   *
   * @returns 错误信息，无错误时返回空字符串
   */
  getError(): string {
    return this.errorMessage
  }

  /**
   * 获取响应携带的完整输出 items。
   *
   * @returns 输出 items 数组
   */
  getOutputItems(): Object[] {
    return this.outputItems
  }

  /**
   * 获取最终响应状态。
   *
   * @returns 状态值（'completed' | 'incomplete'），未知时返回空字符串
   */
  getStatus(): string {
    return this.status
  }

  /**
   * 循环解析当前缓冲中完整的事件块。
   *
   * @param onDelta - 文本增量回调
   * @param onSearch - 服务端搜索状态回调
   */
  private parseAvailableEvents(onDelta: ChatStreamChunkCallback, onSearch: WebSearchStateCallback): void {
    let separatorIndex: number = this.pendingText.indexOf('\n\n')
    while (separatorIndex >= 0) {
      const eventText: string = this.pendingText.substring(0, separatorIndex)
      this.pendingText = this.pendingText.substring(separatorIndex + 2)
      this.parseEvent(eventText, onDelta, onSearch)
      separatorIndex = this.pendingText.indexOf('\n\n')
    }
  }

  /**
   * 解析单个 SSE 事件块（event: 行 + data: 行）。
   *
   * @param block - SSE 事件块文本
   * @param onDelta - 文本增量回调
   * @param onSearch - 服务端搜索状态回调
   */
  private parseEvent(block: string, onDelta: ChatStreamChunkCallback, onSearch: WebSearchStateCallback): void {
    const lines: string[] = block.split('\n')
    let eventType: string = ''
    let dataText: string = ''
    for (let i: number = 0; i < lines.length; i++) {
      const line: string = lines[i].trim()
      if (line.startsWith('event:')) {
        eventType = line.substring(6).trim()
      } else if (line.startsWith('data:')) {
        dataText = line.substring(5).trim()
      }
    }
    // 兼容 data JSON 内直接携带 event 字段的格式
    if (eventType.length === 0 && dataText.length > 0) {
      try {
        const json: Record<string, Object> = JSON.parse(dataText) as Record<string, Object>
        eventType = (json['event'] as string) ?? ''
      } catch (e) {
        return
      }
    }
    if (eventType.length === 0) {
      return
    }
    this.dispatch(eventType, dataText, onDelta, onSearch)
  }

  /**
   * 按事件类型分发处理。
   *
   * @param eventType - 事件类型
   * @param dataText - data JSON 字符串
   * @param onDelta - 文本增量回调
   * @param onSearch - 服务端搜索状态回调
   */
  private dispatch(
    eventType: string,
    dataText: string,
    onDelta: ChatStreamChunkCallback,
    onSearch: WebSearchStateCallback
  ): void {
    if (eventType === 'response.output_text.delta') {
      this.handleTextDelta(dataText, onDelta)
      return
    }
    if (eventType.indexOf('response.web_search_call') === 0) {
      this.handleWebSearch(eventType, dataText, onSearch)
      return
    }
    if (eventType === 'response.completed' || eventType === 'response.incomplete') {
      this.handleResponseFinal(dataText)
      return
    }
    if (eventType === 'response.failed') {
      this.handleFailed(dataText)
      return
    }
    // 其他事件（created / in_progress / output_item.* / content_part.* / reasoning.* 等）忽略
  }

  /**
   * 处理文本增量事件。
   *
   * @param dataText - data JSON 字符串
   * @param onDelta - 文本增量回调
   */
  private handleTextDelta(dataText: string, onDelta: ChatStreamChunkCallback): void {
    try {
      const json: Record<string, Object> = JSON.parse(dataText) as Record<string, Object>
      const delta: string = (json['delta'] as string) ?? ''
      if (delta.length > 0) {
        this.text += delta
        onDelta(delta)
      }
    } catch (e) {
      logger.warn('handleTextDelta: 解析失败')
    }
  }

  /**
   * 处理服务端联网搜索状态事件。
   *
   * @param eventType - 事件类型
   * @param dataText - data JSON 字符串
   * @param onSearch - 服务端搜索状态回调
   */
  private handleWebSearch(eventType: string, dataText: string, onSearch: WebSearchStateCallback): void {
    let query: string = ''
    try {
      const json: Record<string, Object> = JSON.parse(dataText) as Record<string, Object>
      const item: Record<string, Object> = json['item'] as Record<string, Object>
      if (item) {
        query = (item['query'] as string) ?? ''
      }
      if (query.length === 0) {
        query = (json['query'] as string) ?? ''
      }
    } catch (e) {
      // 静默跳过
    }
    if (query.length > 0) {
      this.lastSearchQuery = query
    }
    if (eventType === 'response.web_search_call.completed') {
      onSearch('completed', this.lastSearchQuery)
    } else if (eventType === 'response.web_search_call.failed') {
      onSearch('failed', this.lastSearchQuery)
    } else {
      onSearch('searching', this.lastSearchQuery)
    }
  }

  /**
   * 处理最终响应事件（completed / incomplete），保存完整输出 items。
   *
   * @param dataText - data JSON 字符串
   */
  private handleResponseFinal(dataText: string): void {
    try {
      const json: Record<string, Object> = JSON.parse(dataText) as Record<string, Object>
      const response: Record<string, Object> = json['response'] as Record<string, Object>
      if (!response) {
        return
      }
      const output: Object[] = (response['output'] as Object[]) ?? []
      this.outputItems = output
      const respStatus: string = (response['status'] as string) ?? ''
      if (respStatus.length > 0) {
        this.status = respStatus
      }
      // 从 output 提取完整文本（兜底，防止 delta 遗漏）
      const fullText: string = extractOutputText(output)
      if (fullText.length > this.text.length) {
        this.text = fullText
      }
    } catch (e) {
      logger.warn('handleResponseFinal: 解析失败')
    }
  }

  /**
   * 处理响应失败事件。
   *
   * @param dataText - data JSON 字符串
   */
  private handleFailed(dataText: string): void {
    try {
      const json: Record<string, Object> = JSON.parse(dataText) as Record<string, Object>
      const response: Record<string, Object> = json['response'] as Record<string, Object>
      let errMsg: string = ''
      if (response && response['error']) {
        const errObj: Record<string, Object> = response['error'] as Record<string, Object>
        errMsg = (errObj['message'] as string) ?? ''
      }
      if (errMsg.length === 0) {
        const topErr: Record<string, Object> = json['error'] as Record<string, Object>
        if (topErr) {
          errMsg = (topErr['message'] as string) ?? ''
        }
      }
      this.errorMessage = errMsg.length > 0 ? errMsg : 'AI 响应失败'
      logger.error('response.failed: %{public}s', this.errorMessage)
    } catch (e) {
      this.errorMessage = 'AI 响应解析失败'
    }
  }
}

/**
 * 向 DeepSeek /responses 端点发送流式请求。
 *
 * 自动携带服务端内置 web_search 工具声明，
 * 实时解析语义化 SSE 事件并输出文本增量与搜索状态。
 * 支持外部取消（canceller）与整体超时看门狗，避免请求永久挂起。
 *
 * @param profile - AI 提供方配置
 * @param messages - 对话消息列表
 * @param onDelta - 文本增量回调
 * @param onSearch - 可选的服务端搜索状态回调
 * @param canceller - 可选的取消令牌（页面销毁时调用 cancel() 中断请求）
 * @returns 响应结果（含完整文本与输出 items）
 */
export async function createResponseStream(
  profile: AiProviderProfile,
  messages: ChatMessage[],
  onDelta: ChatStreamChunkCallback,
  onSearch?: WebSearchStateCallback,
  canceller?: RequestCanceller
): Promise<ResponseResult> {
  const url: string = buildResponsesUrl()
  const body: string = buildRequestBody(profile, messages, true)
  const decoder: util.TextDecoder = util.TextDecoder.create('utf-8')
  const parser: ResponsesEventParser = new ResponsesEventParser()
  const httpRequest: http.HttpRequest = http.createHttp()
  const searchCallback: WebSearchStateCallback = onSearch ?? ((phase: string, query: string): void => {
  })

  return new Promise<ResponseResult>((resolve: (value: ResponseResult) => void, reject: (reason: Error) => void): void => {
    let settled: boolean = false
    let streamError: Error | null = null
    let watchdog: number = -1
    /** 非 200 状态码（不为 0 时表示响应为错误体，累积后提取详情）。 */
    let errorStatusCode: number = 0
    /** 非 200 时累积的错误响应体文本。 */
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

    const resolveOnce = (result: ResponseResult): void => {
      if (settled) {
        return
      }
      settled = true
      cleanup()
      resolve(result)
    }

    // 整体看门狗：超过请求超时仍未结束则拒绝，防止连接中断时 Promise 永久挂起
    watchdog = setTimeout((): void => {
      logger.warn('createResponseStream watchdog timeout')
      rejectOnce(new Error('AI 请求超时，请稍后重试'))
    }, REQUEST_TIMEOUT)

    const dataReceiveCallback = (data: ArrayBuffer): void => {
      try {
        const decodedText: string | undefined = decoder.decodeWithStream(new Uint8Array(data), { stream: true })
        const text: string = decodedText ?? ''
        if (text.length === 0) {
          return
        }
        if (errorStatusCode !== 0) {
          // 错误响应体：累积文本，待 dataEnd 时提取服务端错误详情
          errorBody += text
          return
        }
        parser.append(text, onDelta, searchCallback)
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
        const decodedTail: string | undefined = decoder.decodeWithStream(new Uint8Array(new ArrayBuffer(0)), {
          stream: false
        })
        const tail: string = decodedTail ?? ''
        if (errorStatusCode !== 0) {
          // 非 200：先冲刷解码器剩余文本，再提取服务端 error.message 作为详情
          if (tail.length > 0) {
            errorBody += tail
          }
          const detail: string = extractServerError(errorBody)
          rejectOnce(new Error(errorStatusCode.toString() + (detail.length > 0 ? '\n' + detail : '')))
          return
        }
        if (tail.length > 0) {
          parser.append(tail, onDelta, searchCallback)
        }
        const content: string = parser.finish(onDelta, searchCallback)
        const errMsg: string = parser.getError()
        if (errMsg.length > 0) {
          rejectOnce(new Error(errMsg))
          return
        }
        if (content.length === 0) {
          // response.incomplete 表示达到 max_output_tokens 截断，与"格式不兼容"区分提示
          if (parser.getStatus() === 'incomplete') {
            rejectOnce(new Error('回答超长被截断，请增大输出上限或更换模型'))
          } else {
            rejectOnce(new Error('AI 响应为空或格式不兼容'))
          }
          return
        }
        const result: ResponseResult = new ResponseResult()
        result.content = content
        result.outputItems = parser.getOutputItems()
        result.status = parser.getStatus()
        result.truncated = parser.getStatus() === 'incomplete'
        resolveOnce(result)
      } catch (err) {
        const e: Error = err as Error
        rejectOnce(new Error(e.message || 'AI 流式响应解析失败'))
      }
    }

    // 注册外部取消：销毁请求并拒绝，由调用方决定是否吞掉该错误
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
      header: buildHeaders(profile.apiKey),
      extraData: body,
      readTimeout: REQUEST_TIMEOUT,
      connectTimeout: CONNECT_TIMEOUT
    }).then((statusCode: number): void => {
      if (statusCode !== 200) {
        logger.warn('createResponseStream failed: HTTP %d, 等待响应体提取详情', statusCode)
        // 不立即拒绝：继续接收错误响应体，dataEnd 时提取 error.message 后统一拒绝
        errorStatusCode = statusCode
      }
    }).catch((err: Error): void => {
      logger.warn('createResponseStream request error: %{public}s', err.message ?? '')
      rejectOnce(err)
    })
  })
}

/**
 * 向 DeepSeek /responses 端点发送非流式请求。
 *
 * @param profile - AI 提供方配置
 * @param messages - 对话消息列表
 * @returns 响应结果
 */
export async function createResponse(profile: AiProviderProfile, messages: ChatMessage[]): Promise<ResponseResult> {
  const url: string = buildResponsesUrl()
  const body: string = buildRequestBody(profile, messages, false)

  const httpRequest: http.HttpRequest = http.createHttp()
  try {
    const response: http.HttpResponse = await httpRequest.request(url, {
      method: http.RequestMethod.POST,
      header: buildHeaders(profile.apiKey),
      extraData: body,
      expectDataType: http.HttpDataType.STRING,
      readTimeout: REQUEST_TIMEOUT,
      connectTimeout: CONNECT_TIMEOUT
    })

    const statusCode: number = response.responseCode
    const responseText: string = (response.result as string) ?? ''

    if (statusCode !== 200) {
      logger.warn('createResponse failed: HTTP %d, body: %{public}s', statusCode, responseText.substring(0, 300))
      const detail: string = extractServerError(responseText)
      throw new Error(statusCode.toString() + (detail.length > 0 ? '\n' + detail : ''))
    }
    return parseResponseJson(responseText)
  } finally {
    httpRequest.destroy()
  }
}

/**
 * 测试与 DeepSeek 端点的连接。
 *
 * 发送简短测试消息验证 API Key 有效性和模型可用性。
 *
 * @param profile - AI 提供方配置
 * @returns 测试结果
 */
export async function testConnection(profile: AiProviderProfile): Promise<AiTestResult> {
  const messages: ChatMessage[] = [
    new ChatMessage('user', '请用一句简短的中文确认连接成功。')
  ]
  const result: AiTestResult = new AiTestResult()
  const startTime: number = Date.now()
  try {
    const response: ResponseResult = await createResponse(profile, messages)
    result.durationMs = Date.now() - startTime
    result.success = true
    result.message = response.content
  } catch (err) {
    result.durationMs = Date.now() - startTime
    result.success = false
    const e: Error = err as Error
    result.errorMessage = e.message || '连接失败'
  }
  return result
}

/**
 * 构造 Responses API 请求 URL。
 *
 * 全面转向 DeepSeek 后端点恒定，忽略配置中的旧端点字段
 * （旧 OpenAI 兼容端点不支持 Responses API，不提供任何兼容）。
 *
 * @returns 完整的 /responses URL
 */
function buildResponsesUrl(): string {
  return DEFAULT_DEEPSEEK_ENDPOINT + '/responses'
}

/**
 * 构造请求头。
 *
 * @param apiKey - API 密钥
 * @returns HTTP 请求头对象
 */
function buildHeaders(apiKey: string): Record<string, string> {
  const headers: Record<string, string> = {}
  headers['Content-Type'] = 'application/json'
  headers['Accept'] = 'text/event-stream'
  headers['Authorization'] = 'Bearer ' + apiKey
  return headers
}

/**
 * 构造请求体 JSON 字符串。
 *
 * 始终携带服务端内置 web_search 工具声明（tool_choice=auto），
 * 由模型自行判断是否需要联网搜索。
 *
 * @param profile - AI 提供方配置
 * @param messages - 消息列表
 * @param stream - 是否流式
 * @returns JSON 字符串
 */
function buildRequestBody(profile: AiProviderProfile, messages: ChatMessage[], stream: boolean): string {
  const bodyObj: Record<string, Object> = {}
  bodyObj['model'] = profile.modelName
  bodyObj['stream'] = stream
  bodyObj['temperature'] = profile.temperature
  bodyObj['max_output_tokens'] = profile.maxTokens

  const toolObj: Record<string, string> = {}
  toolObj['type'] = WEB_SEARCH_TOOL_TYPE
  bodyObj['tools'] = [toolObj]
  bodyObj['tool_choice'] = 'auto'

  bodyObj['input'] = buildInputItems(messages)
  const instructions: string = collectInstructions(messages)
  if (instructions.length > 0) {
    bodyObj['instructions'] = instructions
  }

  return JSON.stringify(bodyObj)
}

/**
 * 收集所有 system 消息作为 instructions 参数。
 *
 * @param messages - 消息列表
 * @returns 拼接后的 system 指令文本
 */
function collectInstructions(messages: ChatMessage[]): string {
  const parts: string[] = []
  for (let i: number = 0; i < messages.length; i++) {
    if (messages[i].role === 'system' && messages[i].content.trim().length > 0) {
      parts.push(messages[i].content)
    }
  }
  return parts.join('\n\n')
}

/**
 * 将消息列表构建为 Responses API 输入 items。
 *
 * assistant 消息携带 outputItems 时原样展开（保持 message 与
 * web_search_call 的原始顺序，服务端自动恢复搜索结果）。
 *
 * @param messages - 消息列表
 * @returns 输入 items 数组
 */
function buildInputItems(messages: ChatMessage[]): Object[] {
  const items: Object[] = []
  for (let i: number = 0; i < messages.length; i++) {
    const msg: ChatMessage = messages[i]
    if (msg.role === 'system') {
      continue
    }
    if (msg.role === 'assistant' && msg.outputItems && msg.outputItems.length > 0) {
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
    const contentArr: Object[] = []
    contentArr.push(part)
    item['content'] = contentArr
    items.push(item)
  }
  return items
}

/**
 * 解析非流式响应 JSON。
 *
 * @param responseText - 响应 JSON 字符串
 * @returns 响应结果
 */
function parseResponseJson(responseText: string): ResponseResult {
  const result: ResponseResult = new ResponseResult()
  let json: Record<string, Object> = {}
  try {
    json = JSON.parse(responseText) as Record<string, Object>
  } catch (e) {
    throw new Error('AI 响应解析失败')
  }
  const errObj: Record<string, Object> = json['error'] as Record<string, Object>
  if (errObj && errObj['message']) {
    throw new Error((errObj['message'] as string) ?? 'AI 响应错误')
  }
  const output: Object[] = (json['output'] as Object[]) ?? []
  result.outputItems = output
  result.content = extractOutputText(output)
  result.status = (json['status'] as string) ?? ''
  result.truncated = result.status === 'incomplete'
  return result
}

/**
 * 从输出 items 中提取 message 类型的完整文本。
 *
 * @param output - 输出 items 数组
 * @returns 拼接后的助手回复文本
 */
function extractOutputText(output: Object[]): string {
  let text: string = ''
  for (let i: number = 0; i < output.length; i++) {
    const item: Record<string, Object> = output[i] as Record<string, Object>
    if ((item['type'] as string) !== 'message') {
      continue
    }
    const content: Object[] = (item['content'] as Object[]) ?? []
    for (let j: number = 0; j < content.length; j++) {
      const part: Record<string, Object> = content[j] as Record<string, Object>
      if ((part['type'] as string) === 'output_text') {
        text += (part['text'] as string) ?? ''
      }
    }
  }
  return text
}

/**
 * 从非 200 响应体中提取服务端 error.message。
 *
 * @param responseText - 响应体文本
 * @returns 服务端错误描述，无则返回空字符串
 */
function extractServerError(responseText: string): string {
  if (responseText.length === 0) {
    return ''
  }
  try {
    const json: Record<string, Object> = JSON.parse(responseText) as Record<string, Object>
    const errObj: Record<string, Object> = json['error'] as Record<string, Object>
    if (errObj && errObj['message']) {
      return (errObj['message'] as string) ?? ''
    }
  } catch (e) {
    // 响应体非 JSON 时忽略
  }
  return ''
}
