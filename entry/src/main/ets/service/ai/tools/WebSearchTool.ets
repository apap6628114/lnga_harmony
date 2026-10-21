/**
 * 联网搜索工具（web_search）。
 *
 * 模型侧只看到「搜索关键词 → 一批带 URL 的摘要」；
 * 实际执行走 DeepSeek 官方 Search API，由客户端发起。
 */

import { hasToolSwitchesOn } from '../../../model/AiConfig'
import { AiSearchProfile } from '../../../model/AiSearchConfig'
import { AiToolDefinition } from '../AiProtocolTypes'
import { AiToolAdapter, AiToolContext, AiToolResult, AiToolSource } from './AiToolAdapter'
import { aiSearchProviderRegistry } from '../search/SearchProviderRegistry'
import { WebSearchItem, WebSearchResponse } from '../search/AiSearchTypes'

/** 工具名称。 */
const TOOL_NAME: string = 'web_search'
/** 默认返回条数。 */
const DEFAULT_RESULT_COUNT: number = 5
/** 单次允许的最大条数。 */
const MAX_RESULT_COUNT: number = 10

/**
 * 联网搜索工具。
 */
export class WebSearchTool implements AiToolAdapter {
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
      '搜索互联网并返回带链接的网页摘要。当问题涉及实时信息、新闻、最新版本、' +
        '不确定的事实，或需要站外资料佐证时使用。可以多次调用以覆盖不同关键词。'

    const queryProp: Record<string, Object> = {}
    queryProp['type'] = 'string'
    queryProp['description'] = '搜索关键词或自然语言问题，尽量具体'

    const countProp: Record<string, Object> = {}
    countProp['type'] = 'integer'
    countProp['description'] = '返回条数 1-10，默认 5'

    const properties: Record<string, Object> = {}
    properties['query'] = queryProp
    properties['count'] = countProp

    const required: Object[] = []
    required.push('query')

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
    if (!hasToolSwitchesOn(chat) || !chat.enableWebSearch) {
      return false
    }
    const search: AiSearchProfile | null = context.search
    if (search === null) {
      return false
    }
    return aiSearchProviderRegistry.get(search.providerKind).isAvailable(search)
  }

  /**
   * 执行搜索。
   *
   * @param argumentsText - 模型生成的参数 JSON
   * @param context - 工具执行上下文
   * @param fallbackQuery - 兜底查询
   * @returns 工具结果
   */
  async execute(
    argumentsText: string,
    context: AiToolContext,
    fallbackQuery: string
  ): Promise<AiToolResult> {
    const args: Record<string, Object> = parseArguments(argumentsText)
    let query: string = readString(args, 'query').trim()
    if (query.length === 0) {
      query = fallbackQuery.trim()
    }
    let count: number = DEFAULT_RESULT_COUNT
    const countRaw: Object | undefined = args['count']
    if (typeof countRaw === 'number') {
      count = Math.max(1, Math.min(MAX_RESULT_COUNT, Math.round(countRaw as number)))
    }

    const result: AiToolResult = new AiToolResult()
    result.summary = query
    if (query.length === 0) {
      result.success = false
      result.errorMessage = '搜索词为空'
      result.content = '搜索失败：没有可用的搜索关键词。'
      return result
    }

    const search: AiSearchProfile | null = context.search
    if (search === null) {
      result.success = false
      result.errorMessage = '未配置搜索服务'
      result.content = '搜索失败：未配置搜索服务，请先在 AI 配置中添加并激活搜索服务。'
      return result
    }

    const response: WebSearchResponse = await aiSearchProviderRegistry
      .get(search.providerKind)
      .search(search, query, count, fallbackQuery)
    if (!response.success) {
      result.success = false
      result.errorMessage = response.errorMessage
      result.content = '搜索失败：' + response.errorMessage
      return result
    }
    result.success = true
    result.count = response.results.length
    result.sources = buildSources(response.results)
    result.content = buildSearchContent(query, response.results)
    return result
  }
}

/**
 * 把搜索结果整理为模型可读文本。
 *
 * @param query - 搜索词
 * @param results - 搜索结果
 * @returns 工具输出文本
 */
function buildSearchContent(query: string, results: WebSearchItem[]): string {
  if (results.length === 0) {
    return '搜索「' + query + '」没有返回结果。可以换更具体的关键词重试。'
  }
  let content: string = '搜索「' + query + '」共 ' + results.length.toString() + ' 条结果：\n'
  for (let i: number = 0; i < results.length; i++) {
    const item: WebSearchItem = results[i]
    content += '\n' + (i + 1).toString() + '. ' + item.title + '\n'
    content += '   URL: ' + item.url + '\n'
    if (item.date.length > 0) {
      content += '   发布时间: ' + item.date + '\n'
    }
    if (item.siteName.length > 0) {
      content += '   站点: ' + item.siteName + '\n'
    }
    const abstract: string = item.summary.length > 0 ? item.summary : item.snippet
    if (abstract.length > 0) {
      content += '   摘要: ' + abstract + '\n'
    }
  }
  content += '\n需要网页全文时调用 web_fetch 并传入对应 URL。'
  return content
}

/**
 * 构建引用来源列表。
 *
 * @param results - 搜索结果
 * @returns 来源列表
 */
function buildSources(results: WebSearchItem[]): AiToolSource[] {
  const sources: AiToolSource[] = []
  for (let i: number = 0; i < results.length; i++) {
    const source: AiToolSource = new AiToolSource()
    source.title = results[i].title
    source.url = results[i].url
    sources.push(source)
  }
  return sources
}

/**
 * 解析模型生成的参数 JSON。
 *
 * @param argumentsText - 参数 JSON 文本
 * @returns 参数字典（解析失败时为空字典）
 */
export function parseArguments(argumentsText: string): Record<string, Object> {
  if (argumentsText.trim().length === 0) {
    return {}
  }
  try {
    const parsed: Object = JSON.parse(argumentsText) as Object
    if (parsed === null || parsed === undefined || Array.isArray(parsed)) {
      return {}
    }
    return parsed as Record<string, Object>
  } catch (e) {
    return {}
  }
}

/**
 * 安全读取字符串字段。
 *
 * @param record - 参数字典
 * @param key - 字段名
 * @returns 字符串值
 */
function readString(record: Record<string, Object>, key: string): string {
  const value: Object | undefined = record[key]
  return typeof value === 'string' ? value as string : ''
}
