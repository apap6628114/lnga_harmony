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
/** DeepSeek Responses API 固定端点。 */
export const DEFAULT_DEEPSEEK_ENDPOINT: string = 'https://api.deepseek.com'

/**
 * DeepSeek AI 提供方配置。
 *
 * 通过 DeepSeek Responses API 接入，端点固定为 api.deepseek.com，
 * 用户仅需提供 API Key 与模型名称。
 *
 * 不设置输出长度上限：请求不携带 max_output_tokens，由服务端按模型
 * 自身能力决定单次回复长度，避免客户端魔法值把长回答截断。
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
