/**
 * 自定义 AI 激活配置与调用门面（DeepSeek Responses API）。
 *
 * 统一封装当前激活的 DeepSeek AI 配置校验、调用与错误文案，
 * 页面层不再直接处理配置索引或额外调用分支。
 * 联网搜索由 DeepSeek 服务端内置 web_search 工具执行，
 * 客户端仅透传搜索状态用于 UI 展示，无需任何第三方搜索服务。
 */

import { appStore } from '../../store/AppStore'
import type { AiProviderProfile } from '../../model/AiConfig'
import {
  createResponseStream,
  ChatMessage,
  ChatStreamChunkCallback,
  ResponseResult,
  RequestCanceller
} from './ResponsesApiClient'
import { translateError } from './AiErrorTranslator'
import { Logger, DOMAIN_SERVICE } from '../../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'ActiveAiSvc')

/** AI 处理阶段状态回调，用于 UI 展示不同阶段的提示文案。 */
export type ChatStatusCallback = (status: string) => void

/**
 * 服务端联网搜索阶段信息，用于 UI 展示搜索进度。
 *
 * @property phase - 当前阶段: '' | 'analyzing' | 'searching' | 'compiling' | 'complete'
 * @property summary - 搜索关键词
 * @property count - 结果计数（服务端不返回，恒为 0）
 * @property phaseIcon - 阶段图标 SVG 资源（服务层预计算，UI 层按主题着色）
 * @property phaseDescription - 阶段描述文案（服务层预计算）
 */
export class ToolCallInfo {
  /** 当前阶段: '' | analyzing | searching | compiling | complete */
  phase: string = 'analyzing'
  /** 搜索关键词 */
  summary: string = ''
  /** 结果计数 */
  count: number = 0
  /** 阶段图标 SVG 资源 */
  phaseIcon: Resource = $r('app.media.icon_ai_analyzing')
  /** 阶段描述文案 */
  phaseDescription: string = 'AI 正在分析...'
}

/** 服务端搜索阶段信息回调。 */
export type ToolCallCallback = (info: ToolCallInfo) => void

/** 对话调用结果（含用于多轮回传的输出 items）。 */
export class AiChatResult {
  /** 助手回复完整文本 */
  text: string = ''
  /** 本响应的输出 items（含 web_search_call 等），回传历史时原样展开 */
  outputItems: Object[] = []
  /** 是否因达到输出上限被截断 */
  truncated: boolean = false
}

/**
 * 获取当前激活的自定义 AI 配置。
 *
 * @returns 当前激活配置，若未选择或配置不存在则返回 null
 */
export function getActiveAiProfile(): AiProviderProfile | null {
  return appStore.settingsStore.getActiveAiProfile()
}

/**
 * 获取当前自定义 AI 配置不可用时的用户提示。
 *
 * @returns 空字符串表示配置可用，否则为用户可读的错误提示
 */
export function getActiveAiValidationMessage(): string {
  const profile: AiProviderProfile | null = getActiveAiProfile()
  if (!profile) {
    if (appStore.settings.aiProfiles.length === 0) {
      return '请先在设置中添加 AI 配置'
    }
    return '请先在设置中选择 AI 配置'
  }
  if (profile.apiKey.trim().length === 0) {
    return '请先在 AI 配置中填写 API 密钥'
  }
  if (profile.modelName.trim().length === 0) {
    return '请先在 AI 配置中填写模型名称'
  }
  return ''
}

/**
 * 使用当前激活的自定义 AI 配置发起可流式展示的对话补全。
 *
 * 请求自动携带服务端内置 web_search 工具声明，
 * 模型判断需要联网搜索时由 DeepSeek 服务端执行并自动注入结果。
 *
 * @param messages - 对话消息列表
 * @param onDelta - 文本增量回调
 * @param onStatus - 可选的状态更新回调
 * @param onToolCall - 可选的服务端搜索阶段回调
 * @param canceller - 可选的请求取消令牌（页面销毁时调用 cancel() 中断请求）
 * @returns 对话结果（完整文本与输出 items）
 */
export async function chatCompleteWithActiveAiStream(
  messages: ChatMessage[],
  onDelta: ChatStreamChunkCallback,
  onStatus?: ChatStatusCallback,
  onToolCall?: ToolCallCallback,
  canceller?: RequestCanceller
): Promise<AiChatResult> {
  const profile: AiProviderProfile | null = getActiveAiProfile()
  const validationMessage: string = getActiveAiValidationMessage()
  if (!profile || validationMessage.length > 0) {
    throw new Error(validationMessage.length > 0 ? validationMessage : '请先在设置中选择 AI 配置')
  }

  const toolCallInfo: ToolCallInfo = createToolInfo(
    'analyzing', $r('app.media.icon_ai_analyzing'), 'AI 正在分析...', '', 0)
  onToolCall?.(toolCallInfo)
  onStatus?.('AI 正在分析...')

  let searched: boolean = false
  let searchFailed: boolean = false
  let lastQuery: string = ''
  const result: ResponseResult = await createResponseStream(
    profile,
    messages,
    onDelta,
    (phase: string, query: string): void => {
      if (query.length > 0) {
        lastQuery = query
      }
      if (phase === 'searching') {
        searched = true
        const info: ToolCallInfo = createToolInfo(
          'searching', $r('app.media.icon_search'),
          query.length > 0 ? '正在搜索: ' + query : '正在搜索互联网...',
          query, 0
        )
        onToolCall?.(info)
        onStatus?.('正在搜索互联网...')
      } else if (phase === 'completed') {
        const info: ToolCallInfo = createToolInfo(
          'compiling', $r('app.media.icon_chat_bubble'),
          query.length > 0 ? '搜索完成，正在结合结果回答...' : '搜索完成，正在生成回答...',
          query, 0
        )
        onToolCall?.(info)
        onStatus?.('正在结合搜索结果生成回答...')
      } else if (phase === 'failed') {
        searchFailed = true
        onStatus?.('搜索失败，继续回答...')
      }
    },
    canceller
  )

  // 最终状态：发生过联网搜索时标记完成，供气泡展示搜索摘要（失败时如实提示）
  if (searched) {
    const info: ToolCallInfo = createToolInfo(
      'complete',
      searchFailed ? $r('app.media.icon_globe') : $r('app.media.icon_checkmark'),
      searchFailed ? '搜索失败，已基于已有知识回答' : '已搜索互联网',
      lastQuery, 0
    )
    onToolCall?.(info)
  } else {
    onToolCall?.(createToolInfo('', $r('app.media.icon_ai_analyzing'), '', '', 0))
  }

  const chatResult: AiChatResult = new AiChatResult()
  chatResult.text = result.content
  chatResult.outputItems = result.outputItems
  chatResult.truncated = result.truncated
  logger.info('chatComplete done: text=%d chars, items=%d, truncated=%s',
    result.content.length, result.outputItems.length, String(result.truncated))
  return chatResult
}

// ============================================================
// UI 状态辅助
// ============================================================

/**
 * 创建搜索阶段状态对象。
 *
 * @param phase - 阶段值
 * @param icon - 阶段图标 SVG 资源
 * @param description - 阶段描述
 * @param summary - 搜索关键词
 * @param count - 结果计数
 * @returns 搜索阶段状态
 */
function createToolInfo(
  phase: string,
  icon: Resource,
  description: string,
  summary: string,
  count: number
): ToolCallInfo {
  const info: ToolCallInfo = new ToolCallInfo()
  info.phase = phase
  info.phaseIcon = icon
  info.phaseDescription = description
  info.summary = summary
  info.count = count
  return info
}

/**
 * 将 AI 调用异常转换为页面展示文案。
 *
 * 错误消息可能携带服务端 error.message（格式: "<状态码>\n<详情>"），
 * 有则一并展示给用户。
 *
 * @param err - 调用异常
 * @returns 用户可读错误信息
 */
export function formatAiCompletionError(err: Error): string {
  const code: number = parseInt(err.message)
  if (!isNaN(code)) {
    const info = translateError(code, err.message)
    const newlineIndex: number = err.message.indexOf('\n')
    const detail: string = newlineIndex >= 0 ? err.message.substring(newlineIndex + 1).trim() : ''
    return info.userMessage + '\n' + info.suggestion + (detail.length > 0 ? '\n\n服务端信息：' + detail : '')
  }
  if (err.message.length > 0 && err.message.indexOf('请先') === 0) {
    return err.message
  }
  if (err.message.length > 0 && err.message.indexOf('回答超长') === 0) {
    return err.message
  }
  return 'AI 调用失败：' + (err.message || '未知错误')
}
