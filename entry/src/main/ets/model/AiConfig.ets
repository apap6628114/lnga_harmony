/**
 * AI 配置数据模型。
 *
 * 定义 AI 提供方配置的数据结构，支持多服务商：
 * 各服务商通过 providerId 关联 AiModelPresets 中的预设（协议、默认模型、
 * 是否支持内置联网搜索），端点地址由用户在配置中显式保存。
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
 * 默认服务商标识。
 *
 * 历史配置（多服务商支持被移除期间保存的配置）没有 providerId 字段，
 * 读取时统一回退到该值，从而落到 DeepSeek Responses API 链路上。
 */
export const DEFAULT_AI_PROVIDER_ID: string = 'deepseek'

/**
 * AI 提供方配置。
 *
 * 用户在设置页添加的一条服务商配置：选定服务商预设后填写 API Key
 * 与模型名称，服务地址默认取预设端点且允许手动修改。
 *
 * 不设置输出长度上限：请求不携带 max_output_tokens，由服务端按模型
 * 自身能力决定单次回复长度，避免客户端魔法值把长回答截断。
 */
export class AiProviderProfile {
  /** 唯一标识（生成时赋值） */
  id: string = ''
  /** 用户命名的方案名称 */
  name: string = ''
  /**
   * 服务商标识（对应 AiModelPresets 的预设 id）。
   *
   * 决定走哪条协议链路以及是否支持内置联网搜索。
   * 历史配置可能为空，读取时用 resolveProviderId 回退到 deepseek。
   */
  providerId: string = DEFAULT_AI_PROVIDER_ID
  /** 服务地址（预设端点，允许用户修改） */
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
