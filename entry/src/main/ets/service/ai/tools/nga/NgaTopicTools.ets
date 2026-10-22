/**
 * NGA 主题列表 / 搜索工具。
 *
 * 两个工具共用同一套输出格式：模型看到「序号 + 标题 + 作者 + 回复数 + tid」，
 * UI 拿到每个主题一张可点击卡片。
 */

import { AiToolDefinition } from '../../AiProtocolTypes'
import {
  AiToolAdapter,
  AiToolCard,
  AiToolContext,
  AiToolResult,
  TOOL_ERROR_BAD_ARGS,
  TOOL_ERROR_EMPTY
} from '../AiToolAdapter'
import { isAiToolEnabled } from '../../../../model/AiToolConfig'
import { createTopicListParams, getTopicList } from '../../../api/ForumApi'
import type { TopicListParams } from '../../../api/ForumApi'
import type { TopicListResult } from '../../../../model/NgaApiResults'
import type { TopicListInfo, ThreadPageInfo } from '../../../../model/Topic'
import {
  DEFAULT_LIST_LIMIT,
  boolProperty,
  buildToolParameters,
  enumProperty,
  failedResult,
  formatToolTime,
  intProperty,
  isNgaReady,
  loginRequiredResult,
  parseToolArguments,
  readBoolArg,
  readIntArg,
  readStringArg,
  stringProperty,
  topicCard
} from './NgaToolSupport'

/** 版块列表工具名。 */
const TOOL_LIST: string = 'nga_list_topics'
/** 主题搜索工具名。 */
const TOOL_SEARCH: string = 'nga_search_topics'

/**
 * 版块主题列表工具（nga_list_topics）。
 */
export class NgaListTopicsTool implements AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_LIST
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_LIST
    definition.description =
      '按版块读取 NGA 主题列表（标题、作者、回复数、tid）。' +
        '当前页面有版块时可省略 fid。排序方式：latest=最新回复，new=最新发帖，hot=近期热帖，digest=精华。'

    const properties: Record<string, Object> = {}
    properties['fid'] = stringProperty('版块 ID；省略时使用当前版块')
    properties['page'] = intProperty('页码，从 1 开始，默认 1')
    properties['sort'] = enumProperty(
      '排序方式：latest=最新回复（默认），new=最新发帖，hot=近期热帖，digest=精华',
      ['latest', 'new', 'hot', 'digest'])
    properties['limit'] = intProperty('返回条数 1-50，默认 20')

    const required: string[] = []
    definition.parameters = buildToolParameters(properties, required)
    return definition
  }

  /**
   * 判断工具是否可用。
   *
   * @param context - 工具执行上下文
   * @returns true 表示可用
   */
  isAvailable(context: AiToolContext): boolean {
    return isAiToolEnabled(context.tools, TOOL_LIST) && isNgaReady(context)
  }

  /**
   * 执行列表读取。
   *
   * @param argumentsText - 模型生成的参数 JSON
   * @param context - 工具执行上下文
   * @param fallbackQuery - 兜底查询（不使用）
   * @returns 工具结果
   */
  async execute(argumentsText: string, context: AiToolContext,
    fallbackQuery: string): Promise<AiToolResult> {
    if (!isNgaReady(context)) {
      return loginRequiredResult()
    }
    const args: Record<string, Object> = parseToolArguments(argumentsText)
    let fid: string = readStringArg(args, 'fid')
    if (fid.length === 0) {
      fid = context.taskContext.fid
    }
    if (fid.length === 0) {
      return failedResult('缺少版块 ID：请传入 fid，或调用 nga_search_forum 先查到 fid',
        TOOL_ERROR_BAD_ARGS)
    }
    const params: TopicListParams = createTopicListParams()
    params.fid = fid
    params.page = readIntArg(args, 'page', 1, 1, 1000).toString()
    applySort(params, readStringArg(args, 'sort'))
    const limit: number = readIntArg(args, 'limit', DEFAULT_LIST_LIMIT, 1, 50)
    return fetchAndFormat(context.token, params, limit, '版块')
  }
}

/**
 * 站内主题搜索工具（nga_search_topics）。
 */
export class NgaSearchTopicsTool implements AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_SEARCH
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_SEARCH
    definition.description =
      '在 NGA 站内搜索主题。返回标题、作者、回复数、发帖时间与 tid。' +
        '可只搜标题（默认）或同时搜正文（in_content=true），可用 fid 限定版块。'

    const properties: Record<string, Object> = {}
    properties['key'] = stringProperty('搜索关键词，尽量具体，避免单个常见字')
    properties['fid'] = stringProperty('限定版块 ID（可选）')
    properties['in_content'] = boolProperty('是否同时搜索正文，默认 false（只搜标题）')
    properties['page'] = intProperty('页码，从 1 开始，默认 1')
    properties['limit'] = intProperty('返回条数 1-50，默认 20')

    const required: string[] = []
    required.push('key')
    definition.parameters = buildToolParameters(properties, required)
    return definition
  }

  /**
   * 判断工具是否可用。
   *
   * @param context - 工具执行上下文
   * @returns true 表示可用
   */
  isAvailable(context: AiToolContext): boolean {
    return isAiToolEnabled(context.tools, TOOL_SEARCH) && isNgaReady(context)
  }

  /**
   * 执行搜索。
   *
   * @param argumentsText - 模型生成的参数 JSON
   * @param context - 工具执行上下文
   * @param fallbackQuery - 兜底查询（参数缺 key 时使用）
   * @returns 工具结果
   */
  async execute(argumentsText: string, context: AiToolContext,
    fallbackQuery: string): Promise<AiToolResult> {
    if (!isNgaReady(context)) {
      return loginRequiredResult()
    }
    const args: Record<string, Object> = parseToolArguments(argumentsText)
    let key: string = readStringArg(args, 'key')
    if (key.length === 0) {
      key = fallbackQuery.trim()
    }
    if (key.length === 0) {
      return failedResult('缺少搜索关键词', TOOL_ERROR_BAD_ARGS)
    }
    const params: TopicListParams = createTopicListParams()
    params.key = key
    params.fid = readStringArg(args, 'fid')
    params.page = readIntArg(args, 'page', 1, 1, 1000).toString()
    if (readBoolArg(args, 'in_content', false)) {
      params.content = '1'
    }
    const limit: number = readIntArg(args, 'limit', DEFAULT_LIST_LIMIT, 1, 50)
    return fetchAndFormat(context.token, params, limit, '搜索「' + key + '」')
  }
}

/**
 * 把排序参数应用到主题列表请求。
 *
 * @param params - 主题列表参数
 * @param sort - 排序标识
 */
function applySort(params: TopicListParams, sort: string): void {
  if (sort === 'hot') {
    params.hotDays = '7'
    return
  }
  if (sort === 'digest') {
    params.recommend = '1'
    return
  }
  if (sort === 'new') {
    params.orderBy = 'postdatedesc'
    return
  }
  // latest：默认按最后回复，不额外传参数
}

/**
 * 请求主题列表并整理为工具结果。
 *
 * @param token - 会话令牌
 * @param params - 请求参数
 * @param limit - 展示条数
 * @param label - 结果标题（版块名 / 搜索词）
 * @returns 工具结果
 */
export async function fetchAndFormat(token: string, params: TopicListParams, limit: number,
  label: string): Promise<AiToolResult> {
  const result: TopicListResult = await getTopicList(token, params)
  const info: TopicListInfo | null = result.data
  if (info === null || info.threadPageList.length === 0) {
    return failedResult(result.error.length > 0 ? result.error : '没有取到主题列表', TOOL_ERROR_EMPTY)
  }

  const total: number = info.threadPageList.length
  const count: number = Math.min(limit, total)
  let content: string = label + (info.name.length > 0 ? '《' + info.name + '》' : '') +
    ' · 第 ' + info.pagination.page.toString() + '/' +
    (info.pagination.totalPages > 0 ? info.pagination.totalPages.toString() : '?') + ' 页' +
    ' · 本页 ' + total.toString() + ' 条\n'
  const cards: AiToolCard[] = []
  for (let i: number = 0; i < count; i++) {
    const topic: ThreadPageInfo = info.threadPageList[i]
    content += '\n' + (i + 1).toString() + '. ' + topic.subject + '\n'
    content += '   作者：' + (topic.author.length > 0 ? topic.author : '匿名') +
      ' · 回复：' + topic.replies.toString()
    const time: string = formatToolTime(topic.postDate)
    if (time.length > 0) {
      content += ' · 发帖：' + time
    }
    content += ' · tid=' + topic.tid.toString() + '\n'
    cards.push(topicCard(topic.tid.toString(), topic.subject,
      '作者 ' + (topic.author.length > 0 ? topic.author : '匿名') + ' · 回复 ' +
        topic.replies.toString() + ' · ' + info.name))
  }
  if (total > count) {
    content += '\n（本页还有 ' + (total - count).toString() + ' 条未展示，可增大 limit）\n'
  }
  content += '\n需要看某一帖的内容时调用 nga_read_thread 并传入对应 tid。'

  const toolResult: AiToolResult = new AiToolResult()
  toolResult.success = true
  toolResult.summary = info.name.length > 0 ? info.name : label
  toolResult.count = count
  toolResult.content = content
  toolResult.cards = cards
  return toolResult
}
