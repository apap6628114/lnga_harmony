/**
 * AI 设置表单纯逻辑。
 *
 * 收纳设置面板中不依赖组件状态的计算：参数裁剪、预设查询、
 * 占位符与协议文案。全部为静态函数，可独立单元测试。
 */

import {
  AiApiProtocol,
  AiProviderKind,
  AiProviderProfile,
  DEFAULT_AI_MAX_AGENT_STEPS,
  DEFAULT_AI_TEMPERATURE,
  DEFAULT_DEEPSEEK_ENDPOINT
} from '../../model/AiConfig'
import { AiProviderPreset, findProviderPreset, PROVIDER_PRESETS } from './AiModelPresets'

/**
 * 按 ID 获取预设。
 *
 * @param presetId - 预设 ID
 * @returns 预设，未找到时返回 DeepSeek 预设
 */
export function getPresetById(presetId: string): AiProviderPreset {
  const preset: AiProviderPreset | null = findProviderPreset(presetId)
  return preset === null ? PROVIDER_PRESETS[0] : preset
}

/**
 * 获取模型输入框占位提示。
 *
 * @param preset - 当前预设
 * @returns 占位提示
 */
export function getModelPlaceholder(preset: AiProviderPreset): string {
  if (preset.defaultModelName.length > 0) {
    return '默认 ' + preset.defaultModelName + '，可拉取或手填'
  }
  return '请输入服务商提供的模型名称'
}

/**
 * 获取 API Key 输入框占位提示。
 *
 * @param preset - 当前预设
 * @returns 占位提示
 */
export function getApiKeyPlaceholder(preset: AiProviderPreset): string {
  if (preset.apiKeyPlaceholder.length > 0) {
    return preset.apiKeyPlaceholder
  }
  return '请输入 API Key'
}

/**
 * 获取协议展示文案。
 *
 * @param protocol - 协议
 * @returns 展示文案
 */
export function protocolLabel(protocol: AiApiProtocol): string {
  if (protocol === AiApiProtocol.RESPONSES) {
    return 'Responses API'
  }
  return 'Chat Completions'
}

/**
 * 获取协议一句话说明。
 *
 * @param protocol - 协议
 * @returns 说明文案
 */
export function protocolDescription(protocol: AiApiProtocol): string {
  if (protocol === AiApiProtocol.RESPONSES) {
    return 'OpenAI Responses 格式，DeepSeek 官方推荐'
  }
  return 'OpenAI Chat Completions 格式，第三方服务商通用'
}

/**
 * 用预设初始化一个新建配置。
 *
 * @param preset - 服务商预设
 * @returns 预填后的配置
 */
export function createProfileFromPreset(preset: AiProviderPreset): AiProviderProfile {
  const profile: AiProviderProfile = new AiProviderProfile()
  profile.presetId = preset.kind
  profile.name = preset.name
  profile.endpoint = preset.endpoint.length > 0 ? preset.endpoint : ''
  profile.modelName = preset.defaultModelName
  profile.protocol = preset.protocol
  profile.temperature = DEFAULT_AI_TEMPERATURE
  profile.toolsEnabled = true
  profile.enableWebSearch = true
  profile.enableWebFetch = true
  profile.maxAgentSteps = DEFAULT_AI_MAX_AGENT_STEPS
  return profile
}

/**
 * 判断配置是否为 DeepSeek 官方。
 *
 * @param profile - 配置
 * @returns true 表示 DeepSeek 官方
 */
export function isDeepSeekProfile(profile: AiProviderProfile): boolean {
  return profile.presetId === AiProviderKind.DEEPSEEK ||
    profile.endpoint.toLowerCase().indexOf('api.deepseek.com') >= 0
}

/**
 * 判断配置是否已完成必填项（可保存）。
 *
 * @param name - 方案名
 * @param endpoint - 端点
 * @param modelName - 模型名
 * @returns 空字符串表示通过，否则为提示文案
 */
export function validateProfileInputs(name: string, endpoint: string, modelName: string): string {
  if (name.trim().length === 0) {
    return '请输入方案名称'
  }
  if (endpoint.trim().length === 0) {
    return '请输入服务地址'
  }
  if (modelName.trim().length === 0) {
    return '请输入模型名称'
  }
  return ''
}

/**
 * 判断端点是否看起来像合法 URL。
 *
 * @param endpoint - 端点
 * @returns true 表示以 http/https 开头
 */
export function isHttpEndpoint(endpoint: string): boolean {
  const trimmed: string = endpoint.trim().toLowerCase()
  return trimmed.startsWith('http://') || trimmed.startsWith('https://')
}

/**
 * 格式化上下文窗口展示文案。
 *
 * @param tokens - token 数，0 表示未知
 * @returns 展示文案
 */
export function formatContextWindow(tokens: number): string {
  if (tokens <= 0) {
    return ''
  }
  if (tokens >= 1000000) {
    return Math.round(tokens / 100000) / 10 + 'M 上下文'
  }
  if (tokens >= 1000) {
    return Math.round(tokens / 1000) + 'K 上下文'
  }
  return tokens.toString() + ' 上下文'
}

/**
 * 拼接端点的预览展示（含实际请求路径）。
 *
 * @param endpoint - 端点
 * @param protocol - 协议
 * @returns 预览文案
 */
export function endpointPreview(endpoint: string, protocol: AiApiProtocol): string {
  const base: string = endpoint.trim().replace(/\/+$/, '')
  if (base.length === 0) {
    return ''
  }
  if (base.endsWith('/chat/completions') || base.endsWith('/responses')) {
    return base
  }
  return base + (protocol === AiApiProtocol.RESPONSES ? '/responses' : '/chat/completions')
}
