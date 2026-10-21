/**
 * 网页抓取工具（web_fetch）。
 *
 * 模型给出 URL，客户端经搜索服务适配器抓取 Markdown 正文；
 * 用于需要阅读具体页面而非仅看搜索摘要的场景。
 */

import { hasToolSwitchesOn } from '../../../model/AiConfig'
import { AiSearchProfile } from '../../../model/AiSearchConfig'
import { AiToolDefinition } from '../AiProtocolTypes'
import { AiToolAdapter, AiToolContext, AiToolResult, AiToolSource } from './AiToolAdapter'
import { aiSearchProviderRegistry } from '../search/SearchProviderRegistry'
import { truncateFetchedContent } from '../DeepSeekToolsClient'
import { WebFetchResponse } from '../search/AiSearchTypes'
import { parseArguments } from './WebSearchTool'

/** 工具名称。 */
const TOOL_NAME: string = 'web_fetch'

/**
 * 网页抓取工具。
 */
export class WebFetchTool implements AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_NAME
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_NAME
    definition.description =
      '抓取指定网页并返回其 Markdown 正文。当搜索摘要不足以回答问题、' +
        '或者用户直接给出链接时使用。一次只抓一个 URL。'

    const urlProp: Record<string, Object> = {}
    urlProp['type'] = 'string'
    urlProp['description'] = '要抓取的网页地址，必须是 http 或 https 开头'

    const properties: Record<string, Object> = {}
    properties['url'] = urlProp

    const required: Object[] = []
    required.push('url')

    const parameters: Record<string, Object> = {}
    parameters['type'] = 'object'
    parameters['properties'] = properties
    parameters['required'] = required
    parameters['additionalProperties'] = false
    definition.parameters = parameters
    return definition
  }

  /**
   * 判断工具是否可用。
   *
   * @param context - 工具执行上下文
   * @returns true 表示可用
   */
  isAvailable(context: AiToolContext): boolean {
    const chat = context.chat
    if (!hasToolSwitchesOn(chat) || !chat.enableWebFetch) {
      return false
    }
    const search: AiSearchProfile | null = context.search
    if (search === null) {
      return false
    }
    return aiSearchProviderRegistry.get(search.providerKind).isAvailable(search)
  }

  /**
   * 执行抓取。
   *
   * @param argumentsText - 模型生成的参数 JSON
   * @param context - 工具执行上下文
   * @param fallbackQuery - 兜底查询（抓取工具不使用）
   * @returns 工具结果
   */
  async execute(
    argumentsText: string,
    context: AiToolContext,
    fallbackQuery: string
  ): Promise<AiToolResult> {
    const args: Record<string, Object> = parseArguments(argumentsText)
    const urlRaw: Object | undefined = args['url']
    let url: string = typeof urlRaw === 'string' ? (urlRaw as string).trim() : ''

    const result: AiToolResult = new AiToolResult()
    result.summary = url
    if (url.length === 0) {
      result.success = false
      result.errorMessage = '网页地址为空'
      result.content = '抓取失败：没有提供网页地址。'
      return result
    }

    const search: AiSearchProfile | null = context.search
    if (search === null) {
      result.success = false
      result.errorMessage = '未配置搜索服务'
      result.content = '抓取失败：未配置搜索服务，请先在 AI 配置中添加并激活搜索服务。'
      return result
    }

    const response: WebFetchResponse = await aiSearchProviderRegistry
      .get(search.providerKind)
      .fetchPage(search, url)
    if (!response.success) {
      result.success = false
      result.errorMessage = response.errorMessage
      result.content = '抓取「' + url + '」失败：' + response.errorMessage
      return result
    }

    const title: string = response.title.trim().length > 0 ? response.title.trim() : url
    const source: AiToolSource = new AiToolSource()
    source.title = title
    source.url = url

    result.success = true
    result.count = 1
    result.summary = title
    const sources: AiToolSource[] = []
    sources.push(source)
    result.sources = sources
    result.content = buildFetchContent(title, url, response.content)
    return result
  }
}

/**
 * 构造回传给模型的抓取结果文本。
 *
 * @param title - 页面标题
 * @param url - 页面地址
 * @param content - Markdown 正文
 * @returns 工具输出文本
 */
function buildFetchContent(title: string, url: string, content: string): string {
  let text: string = '标题：' + title + '\n'
  text += 'URL: ' + url + '\n\n'
  text += '正文（Markdown）：\n'
  text += truncateFetchedContent(content)
  return text
}
