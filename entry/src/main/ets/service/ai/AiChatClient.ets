/**
 * 对话协议路由。
 *
 * 页面与服务层只依赖这一个入口，协议差异被收敛在
 * `requestResponses` 与 `requestChatCompletions` 两个客户端里。
 */

import { AiApiProtocol, AiProviderProfile, AiTestResult } from '../../model/AiConfig'
import { AiModelInfo } from '../../model/AiModelInfo'
import { buildModelsUrl, extractServerError, parseModelList } from './AiEndpoint'
import { requestResponses } from './ResponsesApiClient'
import { requestChatCompletions } from './OpenAiChatClient'
import { ChatMessage, ChatTurnOptions, ChatTurnResult, RequestCanceller } from './AiProtocolTypes'
import { http } from '@kit.NetworkKit'
import { Logger, DOMAIN_SERVICE } from '../../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'AiChatClient')

/** 模型列表请求超时（毫秒）。 */
const MODELS_TIMEOUT: number = 20000

/**
 * 按配置的协议发起一次对话请求。
 *
 * @param profile - AI 配置
 * @param messages - 对话消息
 * @param options - 请求选项
 * @param canceller - 可选取消令牌
 * @returns 单轮结果
 */
export async function requestChatByProtocol(
  profile: AiProviderProfile,
  messages: ChatMessage[],
  options: ChatTurnOptions,
  canceller?: RequestCanceller
): Promise<ChatTurnResult> {
  if (profile.protocol === AiApiProtocol.RESPONSES) {
    return requestResponses(profile, messages, options, canceller)
  }
  return requestChatCompletions(profile, messages, options, canceller)
}

/**
 * 测试连接。
 *
 * 发送一条极短的测试消息，验证网络、密钥与模型是否可用。
 *
 * @param profile - AI 配置
 * @returns 测试结果
 */
export async function testConnection(profile: AiProviderProfile): Promise<AiTestResult> {
  const messages: ChatMessage[] = [new ChatMessage('user', '请用一句简短的中文确认连接成功。')]
  const options: ChatTurnOptions = new ChatTurnOptions()
  options.stream = false
  options.tools = []
  const result: AiTestResult = new AiTestResult()
  const startTime: number = Date.now()
  try {
    const turn: ChatTurnResult = await requestChatByProtocol(profile, messages, options)
    result.durationMs = Date.now() - startTime
    result.success = true
    result.message = turn.text
  } catch (err) {
    const e: Error = err as Error
    result.durationMs = Date.now() - startTime
    result.success = false
    result.errorMessage = e.message || '连接失败'
  }
  return result
}

/**
 * 拉取模型列表结果。
 *
 * 保留失败原因，供设置页提示用户
 * 「该服务商不支持模型列表，请手动填写」。
 */
export class ModelListResult {
  /** 模型列表 */
  models: AiModelInfo[] = []
  /** 错误信息（成功时为空） */
  errorMessage: string = ''
}

/**
 * 拉取模型列表（带错误信息）。
 *
 * @param profile - AI 配置
 * @returns 模型列表结果
 */
export async function fetchModelList(profile: AiProviderProfile): Promise<ModelListResult> {
  const result: ModelListResult = new ModelListResult()
  const url: string = buildModelsUrl(profile.endpoint)
  const httpRequest: http.HttpRequest = http.createHttp()
  try {
    const response: http.HttpResponse = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: buildHeaders(profile.apiKey),
      expectDataType: http.HttpDataType.STRING,
      readTimeout: MODELS_TIMEOUT,
      connectTimeout: MODELS_TIMEOUT
    })
    const statusCode: number = response.responseCode
    const responseText: string = (response.result as string) ?? ''
    if (statusCode !== 200) {
      const detail: string = extractServerError(responseText)
      result.errorMessage = '获取模型列表失败（HTTP ' + statusCode.toString() + '）' +
        (detail.length > 0 ? '：' + detail : '')
      return result
    }
    result.models = parseModelList(responseText)
    if (result.models.length === 0) {
      result.errorMessage = '服务商没有返回可用模型，请手动填写模型名称'
    }
    return result
  } catch (err) {
    const e: Error = err as Error
    result.errorMessage = '获取模型列表失败：' + (e.message.length > 0 ? e.message : '网络异常')
    return result
  } finally {
    httpRequest.destroy()
  }
}

/**
 * 构造请求头。
 *
 * @param apiKey - API 密钥
 * @returns 请求头
 */
function buildHeaders(apiKey: string): Record<string, string> {
  const headers: Record<string, string> = {}
  headers['Accept'] = 'application/json'
  headers['Authorization'] = 'Bearer ' + apiKey
  return headers
}
