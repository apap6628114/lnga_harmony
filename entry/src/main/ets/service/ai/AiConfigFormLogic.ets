/**
 * AI 设置表单纯逻辑。
 *
 * 收纳 AiSettingsPanel 中不依赖组件状态的计算：参数范围裁剪、服务商预设
 * 查询与占位符解析。全部为静态函数，可安全独立测试。
 */

import {
  MAX_AI_MAX_TOKENS,
  MAX_AI_TEMPERATURE,
  MIN_AI_MAX_TOKENS,
  MIN_AI_TEMPERATURE
} from '../../model/AiConfig'
import { PROVIDER_PRESETS } from './AiModelPresets'
import type { AiProviderPreset } from './AiModelPresets'

/**
 * 将温度参数限制到可编辑范围并规范到一位小数。
 *
 * @param value - 待规范化的温度参数
 * @returns 规范化后的温度参数
 */
export function clampTemperature(value: number): number {
  const clamped: number = Math.max(MIN_AI_TEMPERATURE, Math.min(MAX_AI_TEMPERATURE, value))
  return Math.round(clamped * 10) / 10
}

/**
 * 将输出上限限制到可编辑范围并规范到整数。
 *
 * @param value - 待规范化的输出上限
 * @returns 规范化后的输出上限
 */
export function clampMaxTokens(value: number): number {
  const clamped: number = Math.max(MIN_AI_MAX_TOKENS, Math.min(MAX_AI_MAX_TOKENS, value))
  return Math.round(clamped)
}

/**
 * 获取当前唯一预设（DeepSeek）。
 *
 * @returns DeepSeek 预设，列表为空时返回 null
 */
export function getPreset(): AiProviderPreset | null {
  if (PROVIDER_PRESETS.length > 0) {
    return PROVIDER_PRESETS[0]
  }
  return null
}

/**
 * 获取模型输入框占位提示。
 *
 * @param preset - 当前平台预设（可空）
 * @returns 当前平台默认模型或通用提示
 */
export function getModelPlaceholder(preset: AiProviderPreset | null): string {
  if (preset && preset.defaultModelName.length > 0) {
    return preset.defaultModelName
  }
  return '请输入模型名称'
}

/**
 * 获取 API Key 输入框占位提示。
 *
 * @param preset - 当前平台预设（可空）
 * @returns DeepSeek 的 API Key 格式提示
 */
export function getApiKeyPlaceholder(preset: AiProviderPreset | null): string {
  if (preset && preset.apiKeyPlaceholder.length > 0) {
    return preset.apiKeyPlaceholder
  }
  return '请输入 API Key'
}
