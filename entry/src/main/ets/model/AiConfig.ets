/**
 * AI 配置数据模型。
 *
 * 定义 DeepSeek Responses API 提供方配置的数据结构。
 */

/** AI 温度参数默认值。 */
export const DEFAULT_AI_TEMPERATURE: number = 0.7
/** AI 温度参数最小值。 */
export const MIN_AI_TEMPERATURE: number = 0
/** AI 温度参数最大值。 */
export const MAX_AI_TEMPERATURE: number = 1.5
/** AI 输出上限默认值。 */
export const DEFAULT_AI_MAX_TOKENS: number = 2000
/** AI 输出上限最小值。 */
export const MIN_AI_MAX_TOKENS: number = 400
/** AI 输出上限最大值。 */
export const MAX_AI_MAX_TOKENS: number = 20000
/** DeepSeek Responses API 固定端点。 */
export const DEFAULT_DEEPSEEK_ENDPOINT: string = 'https://api.deepseek.com'

/**
 * DeepSeek AI 提供方配置。
 *
 * 通过 DeepSeek Responses API 接入，端点固定为 api.deepseek.com，
 * 用户仅需提供 API Key 与模型名称。
 */
export class AiProviderProfile {
  /** 唯一标识（生成时赋值） */
  id: string = ''
  /** 用户命名的方案名称 */
  name: string = ''
  /** DeepSeek API 端点地址（固定为 https://api.deepseek.com） */
  endpoint: string = DEFAULT_DEEPSEEK_ENDPOINT
  /** API 密钥（不记录到日志） */
  apiKey: string = ''
  /** 模型名称 */
  modelName: string = ''
  /** 温度参数（0.0 - 1.5，默认 0.7） */
  temperature: number = DEFAULT_AI_TEMPERATURE
  /** 输出上限（400 - 20000，默认 2000） */
  maxTokens: number = DEFAULT_AI_MAX_TOKENS
}

/** 连接测试结果 */
export class AiTestResult {
  /** 是否成功 */
  success: boolean = false
  /** 模型回复文本（成功时） */
  message: string = ''
  /** 耗时（毫秒） */
  durationMs: number = 0
  /** 错误信息（失败时） */
  errorMessage: string = ''
}
