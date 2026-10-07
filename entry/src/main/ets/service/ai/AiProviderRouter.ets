/**
 * AI 提供方调用路由。
 *
 * 上层（ActiveAiService / 设置页）只依赖本模块，不感知具体协议：
 * 按配置的 providerId 解析出协议链路，再分发到对应客户端。
 *
 * 能力降级约定：非 DeepSeek 服务商没有服务端内置联网搜索，
 * 此时静默只发普通对话请求，并由 getCapabilityNotice 给出用户可读提示，
 * 避免用户以为"AI 查过了"却拿到的是模型旧知识。
 */

import type { AiProviderProfile } from '../../model/AiConfig'
import { AiTestResult, DEFAULT_DEEPSEEK_ENDPOINT } from '../../model/AiConfig'
import {
  AI_PROTOCOL_RESPONSES,
  findPresetById,
  getProviderDisplayName,
  resolveProtocol,
  resolveSupportsWebSearch
} from './AiModelPresets'
import type { AiProviderPreset } from './AiModelPresets'
import {
  createResponseStream,
  testResponsesConnection
} from './ResponsesApiClient'
import {
  createChatCompletionStream,
  testChatCompletionsConnection
} from './ChatCompletionsClient'
import {
  AiCompletionResult,
  ChatMessage,
  ChatStreamChunkCallback,
  RequestCanceller,
  WebSearchStateCallback
} from './AiChatTypes'

/**
 * 按配置的协议链路发起流式对话补全。
 *
 * @param profile - AI 提供方配置
 * @param messages - 对话消息列表
 * @param onDelta - 文本增量回调
 * @param onSearch - 可选的服务端搜索状态回调（仅 Responses 链路会触发）
 * @param canceller - 可选的取消令牌
 * @param allowWebSearch - 调用方是否允许联网搜索（纯 JSON 生成类场景应传 false）
 * @returns 补全结果
 */
export async function streamChatCompletion(
  profile: AiProviderProfile,
  messages: ChatMessage[],
  onDelta: ChatStreamChunkCallback,
  onSearch: WebSearchStateCallback | undefined,
  canceller: RequestCanceller | undefined,
  allowWebSearch: boolean
): Promise<AiCompletionResult> {
  const useWebSearch: boolean = allowWebSearch && resolveSupportsWebSearch(profile.providerId)
  if (resolveProtocol(profile.providerId) === AI_PROTOCOL_RESPONSES) {
    return createResponseStream(profile, messages, onDelta, onSearch, canceller, useWebSearch)
  }
  // chat/completions 无服务端搜索能力，onSearch 不会被触发
  return createChatCompletionStream(profile, messages, onDelta, canceller)
}

/**
 * 按配置的协议链路测试连接。
 *
 * @param profile - AI 提供方配置
 * @returns 测试结果
 */
export async function testProviderConnection(profile: AiProviderProfile): Promise<AiTestResult> {
  if (resolveProtocol(profile.providerId) === AI_PROTOCOL_RESPONSES) {
    return testResponsesConnection(profile)
  }
  return testChatCompletionsConnection(profile)
}

/**
 * 获取服务商的协议展示名。
 *
 * @param providerId - 服务商标识
 * @returns 协议展示名
 */
export function getProtocolLabel(providerId: string | undefined): string {
  return resolveProtocol(providerId) === AI_PROTOCOL_RESPONSES
    ? 'Responses API'
    : 'OpenAI 兼容接口'
}

/**
 * 获取配置卡片副标题。
 *
 * @param profile - AI 提供方配置
 * @returns 形如「DeepSeek · Responses API · 支持联网搜索」的副标题
 */
export function getProfileSubtitle(profile: AiProviderProfile): string {
  const searchLabel: string = resolveSupportsWebSearch(profile.providerId) ? '支持联网搜索' : '无联网搜索'
  return getProviderDisplayName(profile.providerId) + ' · ' +
    getProtocolLabel(profile.providerId) + ' · ' + searchLabel
}

/**
 * 获取能力缺失提示文案。
 *
 * @param providerId - 服务商标识
 * @returns 不支持联网搜索时的提示文案，支持时返回空字符串
 */
export function getCapabilityNotice(providerId: string | undefined): string {
  if (resolveSupportsWebSearch(providerId)) {
    return ''
  }
  return getProviderDisplayName(providerId) +
    ' 不提供内置联网搜索，回答仅基于模型已有知识与你已注入的内容'
}

/**
 * 解析配置实际生效的服务地址。
 *
 * 优先使用配置里保存的值；历史配置或新建未填时回退到预设端点，
 * 再兜底 DeepSeek 官方端点。
 *
 * @param profile - AI 提供方配置
 * @returns 生效的服务地址
 */
export function resolveProfileEndpoint(profile: AiProviderProfile): string {
  const endpoint: string = (profile.endpoint ?? '').trim()
  if (endpoint.length > 0) {
    return endpoint
  }
  const preset: AiProviderPreset | null = findPresetById(profile.providerId)
  if (preset && preset.endpoint.length > 0) {
    return preset.endpoint
  }
  return DEFAULT_DEEPSEEK_ENDPOINT
}
