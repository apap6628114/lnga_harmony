/**
 * 搜索服务配置数据模型。
 *
 * 与对话配置（AiProviderProfile）完全解耦：一套对话配置可以搭配任意一套
 * 搜索配置。搜索配置决定「联网工具由哪家服务、用哪个端点与密钥执行」。
 *
 * 当前只内置 DeepSeek 官方一种服务商，但结构按多服务商设计：
 * 新增服务商时只需在 SearchProviderRegistry 注册适配器。
 */

import {
  AiProviderProfile,
  DEFAULT_AI_TOOLS_ENDPOINT,
  SEARCH_PROVIDER_DEEPSEEK,
  isDeepSeekEndpoint
} from './AiConfig'

/**
 * 搜索服务配置。
 */
export class AiSearchProfile {
  /** 唯一标识（生成时赋值） */
  id: string = ''
  /** 用户命名的方案名称 */
  name: string = ''
  /** 搜索服务商标识（当前仅 deepseek） */
  providerKind: string = SEARCH_PROVIDER_DEEPSEEK
  /** 服务端点（DeepSeek 官方为 https://api.deepseek.com） */
  endpoint: string = DEFAULT_AI_TOOLS_ENDPOINT
  /** API 密钥（不记录到日志） */
  apiKey: string = ''
}

/**
 * 防御性读取字符串字段。
 *
 * @param value - 原始字段值
 * @returns 字符串值，缺失时为空字符串
 */
function readString(value: string): string {
  return typeof value === 'string' ? value : ''
}

/**
 * 归一化搜索配置（补齐旧数据缺失字段）。
 *
 * @param raw - 持久化读出的原始配置
 * @returns 归一化后的配置
 */
export function normalizeAiSearchProfile(raw: AiSearchProfile): AiSearchProfile {
  if (raw === null || raw === undefined) {
    return createDefaultAiSearchProfile()
  }
  const profile: AiSearchProfile = new AiSearchProfile()
  profile.id = readString(raw.id)
  profile.name = readString(raw.name)

  const providerKind: string = readString(raw.providerKind).trim()
  profile.providerKind = providerKind.length > 0 ? providerKind : SEARCH_PROVIDER_DEEPSEEK

  const endpoint: string = readString(raw.endpoint).trim()
  profile.endpoint = endpoint.length > 0 ? endpoint : DEFAULT_AI_TOOLS_ENDPOINT
  profile.apiKey = readString(raw.apiKey)
  return profile
}

/**
 * 创建默认搜索配置（DeepSeek 官方、密钥为空）。
 *
 * @returns 默认搜索配置
 */
export function createDefaultAiSearchProfile(): AiSearchProfile {
  const profile: AiSearchProfile = new AiSearchProfile()
  profile.name = 'DeepSeek 官方'
  profile.providerKind = SEARCH_PROVIDER_DEEPSEEK
  profile.endpoint = DEFAULT_AI_TOOLS_ENDPOINT
  profile.apiKey = ''
  return profile
}

/**
 * 从旧版本 AI 配置迁移搜索配置。
 *
 * 旧版本把工具密钥与端点存在对话配置里，迁移时取激活对话配置的值：
 * 优先 toolsApiKey，其次（对话端点为 DeepSeek 时）复用对话密钥。
 *
 * @param chatProfile - 激活的对话配置（可为 null）
 * @returns 迁移后的搜索配置
 */
export function migrateSearchProfileFromChat(chatProfile: AiProviderProfile | null): AiSearchProfile {
  const profile: AiSearchProfile = createDefaultAiSearchProfile()
  if (chatProfile === null) {
    return profile
  }
  const legacyKey: string = readString(chatProfile.toolsApiKey).trim()
  const legacyEndpoint: string = readString(chatProfile.toolsEndpoint).trim()
  const legacyProvider: string = readString(chatProfile.searchProvider).trim()

  if (legacyProvider.length > 0) {
    profile.providerKind = legacyProvider
  }
  if (legacyEndpoint.length > 0) {
    profile.endpoint = legacyEndpoint
  }
  if (legacyKey.length > 0) {
    profile.apiKey = legacyKey
  } else if (isDeepSeekEndpoint(readString(chatProfile.endpoint))) {
    profile.apiKey = readString(chatProfile.apiKey).trim()
  }
  return profile
}
