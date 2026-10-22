/**
 * NGA 读帖工具（nga_read_thread）。
 *
 * 让模型自己决定读哪一页、哪些楼层、最多读多少字——而不是由调用方
 * 在拼 prompt 时就把正文拍平塞进对话。
 */

import { AiToolDefinition } from '../../AiProtocolTypes'
import { AiToolAdapter, AiToolCard, AiToolContext, AiToolResult } from '../AiToolAdapter'
import { isAiToolEnabled } from '../../../../model/AiToolConfig'
import { getThread } from '../../../api/ThreadApi'
import type { ThreadResult } from '../../../../model/ThreadResult'
import type { PostInfo } from '../../../../model/PostInfo'
import {
  DEFAULT_MAX_CHARS,
  TruncatedText,
  bbcodeToText,
  buildToolParameters,
  failedResult,
  intProperty,
  isNgaReady,
  loginRequiredResult,
  parseToolArguments,
  readIntArg,
  readStringArg,
  stringProperty,
  topicCard,
  truncateText
} from './NgaToolSupport'

/** 工具名称。 */
const TOOL_NAME: string = 'nga_read_thread'
/** 默认读取楼数。 */
const DEFAULT_MAX_FLOORS: number = 15
/** 单楼正文上限。 */
const MAX_FLOOR_CHARS: number = 1800

/**
 * 读帖工具。
 */
export class NgaReadThreadTool implements AiToolAdapter {
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
      '读取 NGA 帖子的标题、版块、页码与楼层正文（已转纯文本）。' +
        '当前页面有帖子时可省略 tid 直接读当前帖。想读更多楼层时传更大的 page 或 max_floors。'

    const properties: Record<string, Object> = {}
    properties['tid'] = stringProperty('帖子 ID；省略时使用当前打开的帖子')
    properties['page'] = intProperty('页码，从 1 开始，默认 1')
    properties['pid'] = stringProperty('楼层 pid；指定时直接定位到该楼层所在页')
    properties['max_floors'] = intProperty('最多返回多少个楼层，1-50，默认 15')
    properties['max_chars'] = intProperty('正文总字符上限，默认 6000')

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
    return isAiToolEnabled(context.tools, TOOL_NAME) && isNgaReady(context)
  }

  /**
   * 执行读帖。
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
    let tid: string = readStringArg(args, 'tid')
    if (tid.length === 0) {
      tid = context.taskContext.tid
    }
    const pid: string = readStringArg(args, 'pid')
    if (tid.length === 0 && pid.length === 0) {
      return failedResult('缺少帖子 ID：传 tid，或先用 nga_search_topics 搜索帖子，' +
        '也可以从帖子页面进入本次对话（会自动带上 tid）')
    }
    const page: number = readIntArg(args, 'page', 1, 1, 100000)
    const maxFloors: number = readIntArg(args, 'max_floors', DEFAULT_MAX_FLOORS, 1, 50)
    const maxChars: number = readIntArg(args, 'max_chars', DEFAULT_MAX_CHARS, 500, 20000)

    const result: ThreadResult = await getThread(context.token, tid, pid, '', page.toString())
    if (result.posts.length === 0) {
      return failedResult(result.error.length > 0 ? result.error : '该帖子没有可读楼层')
    }

    const subject: string = result.threadInfo !== null ? result.threadInfo.subject : '（无标题）'
    const forumName: string = result.forumName
    const totalPages: number = result.pagination.totalPages
    const currentPage: number = result.pagination.page > 0 ? result.pagination.page : page

    let content: string = '帖子《' + subject + '》'
    if (forumName.length > 0) {
      content += ' · 版块：' + forumName
    }
    content += ' · 第 ' + currentPage.toString() + '/' +
      (totalPages > 0 ? totalPages.toString() : '?') + ' 页\n'
    content += 'tid=' + tid + '\n'

    const limit: number = Math.min(maxFloors, result.posts.length)
    let consumed: number = content.length
    let truncatedAny: boolean = false
    for (let i: number = 0; i < limit; i++) {
      const post: PostInfo = result.posts[i]
      let body: string = bbcodeToText(post.content)
      const bodyCut: TruncatedText = truncateText(body, MAX_FLOOR_CHARS)
      body = bodyCut.text
      if (bodyCut.truncated) {
        truncatedAny = true
      }
      const header: string = '\n—— 第' + post.lou.toString() + '楼 · 作者：' +
        (post.author.length > 0 ? post.author : '匿名') +
        (post.postdate.length > 0 ? ' · ' + post.postdate : '') + ' ——\n'
      const block: string = header + (body.length > 0 ? body : '（空正文）') + '\n'
      if (consumed + block.length > maxChars) {
        truncatedAny = true
        content += '\n（正文已达本次读取上限，剩余 ' + (limit - i).toString() +
          ' 个楼层未展示；需要时增大 max_chars 或翻页）\n'
        break
      }
      content += block
      consumed += block.length
    }

    const readCount: number = Math.min(limit, result.posts.length)
    const result2: AiToolResult = new AiToolResult()
    result2.success = true
    result2.summary = subject
    result2.count = readCount
    result2.content = content +
      (truncatedAny ? '\n（部分正文已截断，可按需继续读取）' : '')

    const cards: AiToolCard[] = []
    cards.push(topicCard(tid, subject,
      (forumName.length > 0 ? forumName + ' · ' : '') + readCount.toString() + ' 楼'))
    result2.cards = cards
    return result2
  }
}
