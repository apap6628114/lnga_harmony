/**
 * OpenAI 兼容 chat/completions 客户端。
 *
 * 覆盖硅基流动、智谱 GLM、豆包、MiniMax、Kimi、OpenAI 等所有提供
 * OpenAI 兼容 /chat/completions 的服务商：
 * - 请求体为标准 messages 数组（system 作为首条消息传入）
 * - SSE 逐行解析 `data: {...}`，以 `data: [DONE]` 结束
 * - 无服务端联网搜索能力，因此不下发任何 tools 声明
 *
 * HTTP 栈（超时看门狗、外部取消、非 200 错误详情提取）与 ResponsesApiClient
 * 保持同一套实现思路，便于两处行为一致。
 */

import { http } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { Logger, DOMAIN_SERVICE } from '../../common/utils/Logger'
import type { AiProviderProfile } from '../../model/AiConfig'
import { AiTestResult } from '../../model/AiConfig'
import {
  AiCompletionResult,
  ChatMessage,
  ChatStreamChunkCallback,
  RequestCanceller
} from './AiChatTypes'

const logger = new Logger(DOMAIN_SERVICE, 'ChatCompletionsClient')

/** 请求超时毫秒数（长回答流式输出可能持续较久） */
const REQUEST_TIMEOUT: number = 90000
/** 连接超时毫秒数 */
const CONNECT_TIMEOUT: number = 15000
/** SSE 终止标记 */
const SSE_DONE: string = '[DONE]'
/** 因达到输出上限而结束的 finish_reason */
const FINISH_REASON_LENGTH: string = 'length'
/** 对话补全路径 */
const CHAT_COMPLETIONS_PATH: string = '/chat/completions'
/** 连接测试用提示语 */
const TEST_PROMPT: string = '请用一句简短的中文确认连接成功。'

/**
 * OpenAI 兼容 SSE 流解析器。
 *
 * chat/completions 的 SSE 以「一行一个 data: 事件」为约定，
 * 因此按换行切分逐行解析，而不是像 Responses API 那样按空行分块。
 */
class ChatCompletionsParser {
  /** 尚未凑齐整行的残留文本。 */
  private pendingText: string = ''
  /** 累积的助手回复文本。 */
  private text: string = ''
  /** 流内返回的错误信息。 */
  private errorMessage: string = ''
  /** 最后一个 finish_reason。 */
  private finishReason: string = ''

  /**
   * 追加一段响应文本并解析其中完整的行。
   *
   * @param text - 新收到的 UTF-8 文本
   * @param onDelta - 文本增量回调
   */
  append(text: string, onDelta: ChatStreamChunkCallback): void {
    this.pendingText += text
    this.pendingText = this.pendingText.replace(/\r\n/g, '\n').replace(/\r/g, '\n')
    let separatorIndex: number = this.pendingText.indexOf('\n')
    while (separatorIndex >= 0) {
      const line: string = this.pendingText.substring(0, separatorIndex)
      this.pendingText = this.pendingText.substring(separatorIndex + 1)
      this.parseLine(line, onDelta)
      separatorIndex = this.pendingText.indexOf('\n')
    }
  }

  /**
   * 结束解析并处理剩余缓冲。
   *
   * @param onDelta - 文本增量回调
   * @returns 助手回复完整文本
   */
  finish(onDelta: ChatStreamChunkCallback): string {
    if (this.pendingText.trim().length > 0) {
      this.parseLine(this.pendingText, onDelta)
      this.pendingText = ''
    }
    return this.text
  }

  /**
   * 获取流内错误信息。
   *
   * @returns 错误信息，无错误时返回空字符串
   */
  getError(): string {
    return this.errorMessage
  }

  /**
   * 获取最后记录的 finish_reason。
   *
   * @returns finish_reason，未出现时返回空字符串
   */
  getFinishReason(): string {
    return this.finishReason
  }

  /**
   * 解析单行 SSE 文本。
   *
   * @param rawLine - 原始行文本
   * @param onDelta - 文本增量回调
   */
  private parseLine(rawLine: string, onDelta: ChatStreamChunkCallback): void {
    const line: string = rawLine.trim()
    if (line.length === 0 || line.startsWith(':')) {
      // 空行与 SSE 注释（心跳）直接忽略
      return
    }
    if (!line.startsWith('data:')) {
      // event: / id: / retry: 等字段本协议用不到
      return
    }
    const payload: string = line.substring(5).trim()
    if (payload.length === 0) {
      return
    }
    if (payload === SSE_DONE) {
      // 终止标记不是 JSON，不能交给解析器
      return
    }
    try {
      const json: Record<string, Object> = JSON.parse(payload) as Record<string, Object>
      this.handleChunkJson(json, onDelta)
    } catch (e) {
      logger.warn('parseLine: chunk 解析失败')
    }
  }

  /**
   * 处理单个 chunk JSON。
   *
   * @param json - chunk 对象
   * @param onDelta - 文本增量回调
   */
  private handleChunkJson(json: Record<string, Object>, onDelta: ChatStreamChunkCallback): void {
    const errObj: Record<string, Object> = json['error'] as Record<string, Object>
    if (errObj && errObj['message']) {
      this.errorMessage = (errObj['message'] as string) ?? 'AI 响应错误'
      return
    }
    const choices: Object[] = json['choices'] as Object[]
    if (!choices || choices.length === 0) {
      return
    }
    const choice: Record<string, Object> = choices[0] as Record<string, Object>
    const finish: string = (choice['finish_reason'] as string) ?? ''
    if (finish.length > 0) {
      this.finishReason = finish
    }
    const delta: Record<string, Object> = choice['delta'] as Record<string, Object>
    if (delta) {
      // 本客户端不下发 tools；若服务端仍返回工具调用增量，直接忽略，
      // 避免把 arguments 片段当正文渲染出来
      if (delta['tool_calls'] !== undefined) {
        return
      }
      this.emitContent((delta['content'] as string) ?? '', onDelta)
      return
    }
    // 少数实现在最后一块用 message 字段返回完整内容
    const message: Record<string, Object> = choice['message'] as Record<string, Object>
    if (message) {
      this.emitContent((message['content'] as string) ?? '', onDelta)
    }
  }

  /**
   * 累积并派发文本增量。
   *
   * @param content - 文本增量
   * @param onDelta - 文本增量回调
   */
  private emitContent(content: string, onDelta: ChatStreamChunkCallback): void {
    if (content.length === 0) {
      return
    }
    this.text += content
    onDelta(content)
  }
}

/**
 * 向 OpenAI 兼容端点发送流式 chat/completions 请求。
 *
 * 支持外部取消（canceller）与整体超时看门狗，避免请求永久挂起。
 *
 * @param profile - AI 提供方配置
 * @param messages - 对话消息列表
 * @param onDelta - 文本增量回调
 * @param canceller - 可选的取消令牌（页面销毁时调用 cancel() 中断请求）
 * @returns 补全结果（含完整文本）
 */
export async function createChatCompletionStream(
  profile: AiProviderProfile,
  messages: ChatMessage[],
  onDelta: ChatStreamChunkCallback,
  canceller?: RequestCanceller
): Promise<AiCompletionResult> {
  const url: string = buildChatCompletionsUrl(profile.endpoint)
  const body: string = buildChatCompletionsBody(profile, messages, true)
  const decoder: util.TextDecoder = util.TextDecoder.create('utf-8')
  const parser: ChatCompletionsParser = new ChatCompletionsParser()
  const httpRequest: http.HttpRequest = http.createHttp()

  return new Promise<AiCompletionResult>((resolve: (value: AiCompletionResult) => void,
    reject: (reason: Error) => void): void => {
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

    const resolveOnce = (result: AiCompletionResult): void => {
      if (settled) {
        return
      }
      settled = true
      cleanup()
      resolve(result)
    }

    // 整体看门狗：超过请求超时仍未结束则拒绝，防止连接中断时 Promise 永久挂起
    watchdog = setTimeout((): void => {
      logger.warn('createChatCompletionStream watchdog timeout')
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
          errorBody += text
          return
        }
        parser.append(text, onDelta)
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
          if (tail.length > 0) {
            errorBody += tail
          }
          const detail: string = extractServerError(errorBody)
          rejectOnce(new Error(errorStatusCode.toString() + (detail.length > 0 ? '\n' + detail : '')))
          return
        }
        if (tail.length > 0) {
          parser.append(tail, onDelta)
        }
        const content: string = parser.finish(onDelta)
        const errMsg: string = parser.getError()
        if (errMsg.length > 0) {
          rejectOnce(new Error(errMsg))
          return
        }
        if (content.length === 0) {
          rejectOnce(new Error('AI 响应为空或格式不兼容'))
          return
        }
        const result: AiCompletionResult = new AiCompletionResult()
        result.content = content
        result.outputItems = []
        result.status = 'completed'
        // 没有 [DONE] 也照常返回已累积文本，仅在明确 finish_reason=length 时标记截断
        result.truncated = parser.getFinishReason() === FINISH_REASON_LENGTH
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
        logger.warn('createChatCompletionStream failed: HTTP %d, 等待响应体提取详情', statusCode)
        errorStatusCode = statusCode
      }
    }).catch((err: Error): void => {
      logger.warn('createChatCompletionStream request error: %{public}s', err.message ?? '')
      rejectOnce(err)
    })
  })
}

/**
 * 测试与 OpenAI 兼容端点的连接。
 *
 * 发送简短测试消息验证 API Key 有效性和模型可用性。
 *
 * @param profile - AI 提供方配置
 * @returns 测试结果
 */
export async function testChatCompletionsConnection(profile: AiProviderProfile): Promise<AiTestResult> {
  const messages: ChatMessage[] = [new ChatMessage('user', TEST_PROMPT)]
  const result: AiTestResult = new AiTestResult()
  const startTime: number = Date.now()
  try {
    const completion: AiCompletionResult = await createChatCompletion(profile, messages)
    result.durationMs = Date.now() - startTime
    result.success = true
    result.message = completion.content
  } catch (err) {
    result.durationMs = Date.now() - startTime
    result.success = false
    const e: Error = err as Error
    result.errorMessage = e.message || '连接失败'
  }
  return result
}

/**
 * 向 OpenAI 兼容端点发送非流式请求（仅用于连通性探测）。
 *
 * @param profile - AI 提供方配置
 * @param messages - 对话消息列表
 * @returns 补全结果
 */
async function createChatCompletion(
  profile: AiProviderProfile,
  messages: ChatMessage[]
): Promise<AiCompletionResult> {
  const url: string = buildChatCompletionsUrl(profile.endpoint)
  const body: string = buildChatCompletionsBody(profile, messages, false)

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
      logger.warn('createChatCompletion failed: HTTP %d, body: %{public}s',
        statusCode, responseText.substring(0, 300))
      const detail: string = extractServerError(responseText)
      throw new Error(statusCode.toString() + (detail.length > 0 ? '\n' + detail : ''))
    }
    return parseCompletionJson(responseText)
  } finally {
    httpRequest.destroy()
  }
}

/**
 * 构造 chat/completions 请求 URL。
 *
 * 服务地址统一去掉尾部斜杠后补齐 /chat/completions，
 * 因此预设里的 https://xxx/v1 与 https://xxx/v1/chat/completions 都能正确工作。
 *
 * @param endpoint - 配置中的服务地址
 * @returns 完整的 /chat/completions URL
 */
function buildChatCompletionsUrl(endpoint: string): string {
  let base: string = (endpoint ?? '').trim().replace(/\/+$/, '')
  if (base.endsWith(CHAT_COMPLETIONS_PATH)) {
    return base
  }
  return base + CHAT_COMPLETIONS_PATH
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
 * 不携带 max_tokens：输出长度交给服务端按模型能力决定。
 * 不下发 tools：该协议下没有可用的服务端内置联网搜索。
 *
 * @param profile - AI 提供方配置
 * @param messages - 消息列表
 * @param stream - 是否流式
 * @returns JSON 字符串
 */
function buildChatCompletionsBody(
  profile: AiProviderProfile,
  messages: ChatMessage[],
  stream: boolean
): string {
  const bodyObj: Record<string, Object> = {}
  bodyObj['model'] = profile.modelName
  bodyObj['stream'] = stream
  bodyObj['temperature'] = profile.temperature

  const serialized: Object[] = []
  for (let i: number = 0; i < messages.length; i++) {
    const msg: ChatMessage = messages[i]
    if (msg.content.length === 0) {
      continue
    }
    const msgObj: Record<string, string> = {}
    msgObj['role'] = msg.role
    msgObj['content'] = msg.content
    serialized.push(msgObj)
  }
  bodyObj['messages'] = serialized

  return JSON.stringify(bodyObj)
}

/**
 * 解析非流式响应 JSON。
 *
 * @param responseText - 响应 JSON 字符串
 * @returns 补全结果
 */
function parseCompletionJson(responseText: string): AiCompletionResult {
  const result: AiCompletionResult = new AiCompletionResult()
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
  const choices: Object[] = json['choices'] as Object[]
  if (!choices || choices.length === 0) {
    throw new Error('AI 响应为空或格式不兼容')
  }
  const choice: Record<string, Object> = choices[0] as Record<string, Object>
  const message: Record<string, Object> = choice['message'] as Record<string, Object>
  result.content = message ? ((message['content'] as string) ?? '') : ''
  result.outputItems = []
  result.status = 'completed'
  result.truncated = ((choice['finish_reason'] as string) ?? '') === FINISH_REASON_LENGTH
  if (result.content.length === 0) {
    throw new Error('AI 响应为空或格式不兼容')
  }
  return result
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
