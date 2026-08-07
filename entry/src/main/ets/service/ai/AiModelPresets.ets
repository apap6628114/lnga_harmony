/**
 * AI 提供方预设数据。
 *
 * 全面转向 DeepSeek Responses API 后，仅保留 DeepSeek 预设。
 */

/** AI 服务商预设 */
export class AiProviderPreset {
  /** 服务商标识 */
  id: string
  /** 服务商名称 */
  name: string
  /** 端点地址 */
  endpoint: string
  /** 默认模型名称 */
  defaultModelName: string
  /** 一句话说明 */
  description: string
  /** API Key 格式提示文本，用作输入框占位符 */
  apiKeyPlaceholder: string

  /**
   * 创建 AI 服务商预设。
   *
   * @param id - 服务商标识
   * @param name - 服务商名称
   * @param endpoint - 端点地址
   * @param defaultModelName - 默认模型名称
   * @param description - 一句话说明
   * @param apiKeyPlaceholder - API Key 格式提示
   */
  constructor(
    id: string,
    name: string,
    endpoint: string,
    defaultModelName: string,
    description: string,
    apiKeyPlaceholder: string
  ) {
    this.id = id
    this.name = name
    this.endpoint = endpoint
    this.defaultModelName = defaultModelName
    this.description = description
    this.apiKeyPlaceholder = apiKeyPlaceholder
  }
}

/** 预设 AI 服务商列表（仅 DeepSeek Responses API）。 */
export const PROVIDER_PRESETS: AiProviderPreset[] = [
  new AiProviderPreset(
    'deepseek', 'DeepSeek', 'https://api.deepseek.com',
    'deepseek-v4-flash', 'Responses API，内置服务端联网搜索', 'sk-...'
  )
]
