/**
 * AI 服务商预设。
 *
 * 开箱只提供 DeepSeek 官方：端点、协议、默认模型全部预填，用户只需填 Key
 * 并可从 `/models` 拉取模型；自定义服务商的端点、协议、模型一律由用户填写，
 * 客户端不猜测任何厂商私有约定。
 */

import { AiApiProtocol, AiProviderKind, DEFAULT_DEEPSEEK_ENDPOINT } from '../../model/AiConfig'

/** AI 服务商预设。 */
export class AiProviderPreset {
  /** 服务商标识 */
  id: string
  /** 服务商名称 */
  name: string
  /** 默认端点（自定义预设为空） */
  endpoint: string
  /** 默认模型名称（自定义预设为空） */
  defaultModelName: string
  /** 默认对话协议 */
  protocol: AiApiProtocol
  /** 服务商类型 */
  kind: AiProviderKind
  /** 一句话说明 */
  description: string
  /** API Key 格式提示文本，用作输入框占位符 */
  apiKeyPlaceholder: string

  /**
   * 创建服务商预设。
   *
   * @param id - 服务商标识
   * @param name - 服务商名称
   * @param endpoint - 默认端点
   * @param defaultModelName - 默认模型
   * @param protocol - 默认协议
   * @param kind - 服务商类型
   * @param description - 一句话说明
   * @param apiKeyPlaceholder - API Key 格式提示
   */
  constructor(
    id: string,
    name: string,
    endpoint: string,
    defaultModelName: string,
    protocol: AiApiProtocol,
    kind: AiProviderKind,
    description: string,
    apiKeyPlaceholder: string
  ) {
    this.id = id
    this.name = name
    this.endpoint = endpoint
    this.defaultModelName = defaultModelName
    this.protocol = protocol
    this.kind = kind
    this.description = description
    this.apiKeyPlaceholder = apiKeyPlaceholder
  }
}

/** 预设服务商列表：DeepSeek 官方 + 自定义。 */
export const PROVIDER_PRESETS: AiProviderPreset[] = [
  new AiProviderPreset(
    AiProviderKind.DEEPSEEK,
    'DeepSeek 官方',
    DEFAULT_DEEPSEEK_ENDPOINT,
    'deepseek-flash',
    AiApiProtocol.RESPONSES,
    AiProviderKind.DEEPSEEK,
    '官方 API，参数已预填，支持拉取模型',
    'sk-...'
  ),
  new AiProviderPreset(
    AiProviderKind.CUSTOM,
    '自定义服务商',
    '',
    '',
    AiApiProtocol.CHAT_COMPLETIONS,
    AiProviderKind.CUSTOM,
    '任意兼容 OpenAI 协议的服务，参数自行填写',
    '请输入服务商提供的 API Key'
  )
]

/**
 * 按 ID 查找预设。
 *
 * @param id - 预设 ID
 * @returns 预设，未找到时返回 null
 */
export function findProviderPreset(id: string): AiProviderPreset | null {
  for (let i: number = 0; i < PROVIDER_PRESETS.length; i++) {
    if (PROVIDER_PRESETS[i].id === id) {
      return PROVIDER_PRESETS[i]
    }
  }
  return null
}
