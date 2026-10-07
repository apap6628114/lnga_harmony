/**
 * AI 提供方预设数据。
 *
 * 提供各主流服务商的默认端点、默认模型与能力声明，降低用户手动输入门槛。
 * 预设同时声明协议链路与是否支持内置联网搜索：
 * - DeepSeek 走 Responses API，支持服务端 web_search；
 * - 其余服务商走 OpenAI 兼容 chat/completions，不提供内置联网搜索。
 * 客户端按预设决定请求体形态，能力缺失时由 UI 明确提示而非静默失败。
 */

import { DEFAULT_AI_PROVIDER_ID } from '../../model/AiConfig'

/** Responses API 协议（语义化 SSE 事件 + 可选服务端内置联网搜索）。 */
export const AI_PROTOCOL_RESPONSES: string = 'responses'
/** OpenAI 兼容 chat/completions 协议。 */
export const AI_PROTOCOL_CHAT_COMPLETIONS: string = 'chat-completions'

/** AI 服务商预设 */
export class AiProviderPreset {
  /** 服务商标识 */
  id: string
  /** 服务商名称 */
  name: string
  /** 端点地址（历史配置中的服务地址默认取自这里） */
  endpoint: string
  /** 默认模型名称 */
  defaultModelName: string
  /** 协议链路（responses / chat-completions） */
  protocol: string
  /** 是否支持服务端内置联网搜索 */
  supportsWebSearch: boolean
  /** 一句话说明（含联网能力描述，用于选择弹窗与卡片副标题） */
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
   * @param protocol - 协议链路
   * @param supportsWebSearch - 是否支持内置联网搜索
   * @param description - 一句话说明
   * @param apiKeyPlaceholder - API Key 格式提示
   */
  constructor(
    id: string,
    name: string,
    endpoint: string,
    defaultModelName: string,
    protocol: string,
    supportsWebSearch: boolean,
    description: string,
    apiKeyPlaceholder: string
  ) {
    this.id = id
    this.name = name
    this.endpoint = endpoint
    this.defaultModelName = defaultModelName
    this.protocol = protocol
    this.supportsWebSearch = supportsWebSearch
    this.description = description
    this.apiKeyPlaceholder = apiKeyPlaceholder
  }
}

/** 预设 AI 服务商列表（首个为新增配置时的默认选择）。 */
export const PROVIDER_PRESETS: AiProviderPreset[] = [
  new AiProviderPreset(
    'deepseek', 'DeepSeek', 'https://api.deepseek.com', 'deepseek-v4-flash',
    AI_PROTOCOL_RESPONSES, true, 'Responses API，内置服务端联网搜索', 'sk-...'
  ),
  new AiProviderPreset(
    'siliconflow', '硅基流动', 'https://api.siliconflow.cn/v1', 'deepseek-ai/DeepSeek-V3.2',
    AI_PROTOCOL_CHAT_COMPLETIONS, false, 'OpenAI 兼容，无联网搜索', 'sk-...'
  ),
  new AiProviderPreset(
    'zhipu', '智谱 GLM', 'https://open.bigmodel.cn/api/paas/v4', 'glm-5.2',
    AI_PROTOCOL_CHAT_COMPLETIONS, false, 'OpenAI 兼容，无联网搜索', 'xxxxxxxx...xxxxxxxx.xxxxxxxxxxxxxxxx'
  ),
  new AiProviderPreset(
    'doubao', '豆包', 'https://ark.cn-beijing.volces.com/api/v3', 'doubao-seed-2-1-pro-260628',
    AI_PROTOCOL_CHAT_COMPLETIONS, false, 'OpenAI 兼容，无联网搜索', 'ark_... 或 AKID...'
  ),
  new AiProviderPreset(
    'minimax', 'MiniMax', 'https://api.minimaxi.com/v1', 'MiniMax-M3',
    AI_PROTOCOL_CHAT_COMPLETIONS, false, 'OpenAI 兼容，无联网搜索', 'mm-... 或从控制台获取'
  ),
  new AiProviderPreset(
    'moonshot', 'Kimi', 'https://api.moonshot.cn/v1', 'kimi-k2.6',
    AI_PROTOCOL_CHAT_COMPLETIONS, false, 'OpenAI 兼容，无联网搜索', 'sk-...'
  ),
  new AiProviderPreset(
    'openai', 'OpenAI', 'https://api.openai.com/v1', 'gpt-4o-mini',
    AI_PROTOCOL_CHAT_COMPLETIONS, false, 'OpenAI 兼容，无联网搜索', 'sk-...'
  ),
  new AiProviderPreset(
    'custom', '自定义', '', '',
    AI_PROTOCOL_CHAT_COMPLETIONS, false, '手动输入服务地址，无联网搜索', '请输入 API Key'
  )
]

/**
 * 归一化服务商标识。
 *
 * 历史配置可能没有 providerId（多服务商支持被移除期间保存的配置），
 * 统一回退到 DeepSeek——那时的配置只可能是 DeepSeek。
 *
 * @param providerId - 原始服务商标识
 * @returns 归一化后的服务商标识
 */
export function resolveProviderId(providerId: string | undefined): string {
  if (providerId === undefined || providerId === null || providerId.trim().length === 0) {
    return DEFAULT_AI_PROVIDER_ID
  }
  return providerId.trim()
}

/**
 * 按标识查找服务商预设。
 *
 * @param providerId - 服务商标识
 * @returns 匹配的预设，未匹配时返回 null
 */
export function findPresetById(providerId: string | undefined): AiProviderPreset | null {
  const id: string = resolveProviderId(providerId)
  for (let i: number = 0; i < PROVIDER_PRESETS.length; i++) {
    if (PROVIDER_PRESETS[i].id === id) {
      return PROVIDER_PRESETS[i]
    }
  }
  return null
}

/**
 * 解析配置应使用的协议链路。
 *
 * 未匹配到预设时按 OpenAI 兼容协议处理：该协议是行业通用形态，
 * 比 Responses API 的适配面更广。
 *
 * @param providerId - 服务商标识
 * @returns 协议标识
 */
export function resolveProtocol(providerId: string | undefined): string {
  const preset: AiProviderPreset | null = findPresetById(providerId)
  if (preset) {
    return preset.protocol
  }
  return AI_PROTOCOL_CHAT_COMPLETIONS
}

/**
 * 解析配置是否支持服务端内置联网搜索。
 *
 * @param providerId - 服务商标识
 * @returns 是否支持内置联网搜索
 */
export function resolveSupportsWebSearch(providerId: string | undefined): boolean {
  const preset: AiProviderPreset | null = findPresetById(providerId)
  return preset ? preset.supportsWebSearch : false
}

/**
 * 解析服务商的展示名称。
 *
 * @param providerId - 服务商标识
 * @returns 服务商名称，未匹配时返回「自定义」
 */
export function getProviderDisplayName(providerId: string | undefined): string {
  const preset: AiProviderPreset | null = findPresetById(providerId)
  return preset ? preset.name : '自定义'
}
