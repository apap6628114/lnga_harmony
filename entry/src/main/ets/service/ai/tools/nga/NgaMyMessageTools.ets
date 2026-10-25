/**
 * NGA 私信工具（nga_my_messages）。
 *
 * 消息中心有 4 个 Tab，能力已按 Tab 拆成 4 个工具，本文件补齐最后一块：
 *  - 消息（通知）→ `nga_my_notifications`
 *  - **私信 → 本文件 `nga_my_messages`**
 *  - 动态 → `nga_my_following`
 *  - 跟踪 → `nga_my_tracked`
 *
 * 两种形态（与「我的发帖 / 回帖」同一套"列表 + 单项"模式）：
 *  - 不传 `mid`：私信会话列表（谁发来的、标题、消息数、最后回复人/时间）
 *  - 传 `mid`：该会话内的消息正文
 *
 * 数据源：`app_api.php message/list|detail`（`__output=12`，detail 的 signParams=did）。
 * 注意 `content` 在解析层已去掉 HTML 标签，但仍可能残留 BBCode（引用块等），
 * 所以展示前再过一次 `bbcodeToText`。
 */

import { AiToolDefinition } from '../../AiProtocolTypes'
import {
  AiToolAdapter,
  AiToolCard,
  AiToolContext,
  AiToolResult,
  TOOL_ERROR_EMPTY,
  TOOL_ERROR_UPSTREAM
} from '../AiToolAdapter'
import { isAiToolEnabled } from '../../../../model/AiToolConfig'
import { getMessageDetail, getMessageList } from '../../../api/MessageApi'
import type { MessageDetailResult, MessageListResult } from '../../../../model/MessageResult'
import type { MessageArticle, MessageDetailInfo, MessageListInfo, MessageThreadInfo } from '../../../../model/Message'
import {
  bbcodeToText,
  buildToolParameters,
  failedResult,
  formatToolTime,
  intProperty,
  isNgaReady,
  loginRequiredResult,
  parseToolArguments,
  readIntArg,
  readStringArg,
  stringProperty,
  truncateText
} from './NgaToolSupport'

/** 工具名称。 */
const TOOL_MESSAGES: string = 'nga_my_messages'

/** 默认返回条数。 */
const DEFAULT_LIMIT: number = 20
/** 单次返回条数上限。 */
const MAX_LIMIT: number = 50
/** 单次最多附带的卡片数。 */
const MAX_CARDS: number = 20
/** 单个会话正文的展示上限（字符）。 */
const BODY_MAX: number = 200

/**
 * 私信正文转纯文本并截断。
 *
 * @param content - 解析层产出的正文（已去 HTML，可能残留 BBCode）
 * @returns 单行化后的片段
 */
function bodySnippet(content: string): string {
  if (content.length === 0) {
    return ''
  }
  const plain: string = bbcodeToText(content).replace(/\s+/g, ' ').trim()
  const limited = truncateText(plain, BODY_MAX)
  return limited.truncated ? limited.text + '…' : limited.text
}

/**
 * 私信工具。
 */
export class NgaMyMessagesTool implements AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_MESSAGES
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_MESSAGES
    definition.description =
      '读取我的私信（消息中心「私信」Tab）。不传 mid 时列出私信会话（对方、标题、消息数、最后回复）；' +
        '传 mid 时读取该会话内的消息正文（每条截断到 200 字）。' +
        '只读：不能代替用户发私信或标记已读，需要回复时请引导用户在客户端操作。'

    const properties: Record<string, Object> = {}
    properties['mid'] = stringProperty('会话 ID（先不带 mid 列出会话，再把对应 mid 传回来）；省略时列出会话')
    properties['page'] = intProperty('页码，从 1 开始，默认 1；列表与会话详情都支持翻页，可看更早的会话 / 消息')
    properties['limit'] = intProperty('返回条数 1-' + MAX_LIMIT.toString() +
      '，默认 ' + DEFAULT_LIMIT.toString() + '；超出单页条数时需配合 page 翻页')

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
    return isAiToolEnabled(context.tools, TOOL_MESSAGES) && isNgaReady(context)
  }

  /**
   * 执行私信读取。
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
    const mid: string = readStringArg(args, 'mid')
    const page: number = readIntArg(args, 'page', 1, 1, 1000)
    const limit: number = readIntArg(args, 'limit', DEFAULT_LIMIT, 1, MAX_LIMIT)
    if (mid.length > 0) {
      return this.describeThread(context.token, mid, page, limit)
    }
    return this.describeList(context.token, page, limit)
  }

  /**
   * 描述私信会话列表。
   *
   * @param token - 会话令牌
   * @param page - 页码
   * @param limit - 返回条数
   * @returns 工具结果
   */
  private async describeList(token: string, page: number, limit: number): Promise<AiToolResult> {
    const fetched: MessageListResult = await getMessageList(token, page.toString())
    const info: MessageListInfo | null = fetched.data
    if (info === null) {
      return failedResult(fetched.error.length > 0 ? fetched.error : '获取私信会话失败', TOOL_ERROR_UPSTREAM)
    }
    const list: MessageThreadInfo[] = info.messageEntryList
    if (list.length === 0) {
      return failedResult('第 ' + page.toString() + ' 页没有私信会话。', TOOL_ERROR_EMPTY)
    }

    const shown: number = Math.min(limit, list.length)
    let content: string = '私信会话 · 第 ' + info.currentPage.toString() + ' 页 · ' +
      list.length.toString() + ' 个\n'
    const cards: AiToolCard[] = []
    for (let i: number = 0; i < shown; i++) {
      const thread: MessageThreadInfo = list[i]
      const mid: string = thread.mid.toString()
      const lastAt: string = formatToolTime(Number(thread.lasttime))
      const from: string = thread.from_username.length > 0 ? thread.from_username : '未知'
      const lastFrom: string = thread.last_from_username.length > 0
        ? thread.last_from_username : from
      content += '\n' + (i + 1).toString() + '. ' +
        (thread.subject.length > 0 ? thread.subject : '（无标题）')
      content += '\n   ' + from + ' 发起 · 最后回复 ' + lastFrom
      if (lastAt.length > 0) {
        content += ' · ' + lastAt
      }
      content += ' · ' + thread.posts.toString() + ' 条 · mid=' + mid + '\n'
      if (cards.length < MAX_CARDS) {
        cards.push(this.buildCard(mid,
          thread.subject.length > 0 ? thread.subject : '（无标题私信）',
          from + ' · ' + thread.posts.toString() + ' 条'))
      }
    }
    if (list.length > shown) {
      content += '\n（本页还有 ' + (list.length - shown).toString() +
        ' 个未展示，可增大 limit（上限 50））'
    }
    if (info.nextPage > 0) {
      content += '\n（还有更早的会话，可传 page=' + info.nextPage.toString() + '）'
    }
    content += '\n需要看某个会话的正文时，传对应 mid 调用本工具。'

    const result: AiToolResult = new AiToolResult()
    result.success = true
    result.summary = '私信会话'
    result.count = shown
    result.content = content
    result.cards = cards
    return result
  }

  /**
   * 描述单个会话内的消息。
   *
   * @param token - 会话令牌
   * @param mid - 会话 ID
   * @param page - 页码
   * @param limit - 返回条数
   * @returns 工具结果
   */
  private async describeThread(token: string, mid: string, page: number,
    limit: number): Promise<AiToolResult> {
    const fetched: MessageDetailResult = await getMessageDetail(token, mid, page.toString())
    const info: MessageDetailInfo | null = fetched.data
    if (info === null) {
      return failedResult(fetched.error.length > 0 ? fetched.error : '获取私信内容失败', TOOL_ERROR_UPSTREAM)
    }
    const articles: MessageArticle[] = info.messageEntryList
    if (articles.length === 0) {
      return failedResult('会话 mid=' + mid + ' 第 ' + page.toString() + ' 页没有消息。', TOOL_ERROR_EMPTY)
    }

    const shown: number = Math.min(limit, articles.length)
    const title: string = info.title.length > 0 ? info.title : ''
    const header: string = title.length > 0 ? ('私信会话《' + title + '》') : '私信会话'
    let content: string = header + '（mid=' + mid + ' · 第 ' + info.currentPage.toString() + ' 页 · ' +
      articles.length.toString() + ' 条）\n'
    for (let i: number = 0; i < shown; i++) {
      const article: MessageArticle = articles[i]
      const author: string = article.from.length > 0 ? article.from : '未知'
      const time: string = formatToolTime(Number(article.time))
      content += '\n' + (i + 1).toString() + '. ' + author
      if (time.length > 0) {
        content += ' · ' + time
      }
      const snippet: string = bodySnippet(article.content)
      if (snippet.length > 0) {
        content += '\n   ' + snippet
      }
      content += '\n'
    }
    if (articles.length > shown) {
      content += '\n（本页还有 ' + (articles.length - shown).toString() +
        ' 条未展示，可增大 limit（上限 50）或翻页）'
    }
    if (info.nextPage > 0) {
      content += '\n（还有更早的消息，可传 page=' + info.nextPage.toString() + '）'
    }
    content += '\n本工具只读：回复私信需要用户在客户端「私信」Tab 中操作。'

    const result: AiToolResult = new AiToolResult()
    result.success = true
    result.summary = info.title.length > 0 ? info.title : ('私信 mid=' + mid)
    result.count = shown
    result.content = content
    const cards: AiToolCard[] = []
    cards.push(this.buildCard(mid, info.title.length > 0 ? info.title : ('私信 mid=' + mid),
      articles.length.toString() + ' 条'))
    result.cards = cards
    return result
  }

  /**
   * 构造私信会话卡片（点击打开会话详情）。
   *
   * @param mid - 会话 ID
   * @param title - 卡片标题
   * @param subtitle - 卡片副标题
   * @returns 卡片
   */
  private buildCard(mid: string, title: string, subtitle: string): AiToolCard {
    const card: AiToolCard = new AiToolCard()
    card.kind = 'message'
    card.title = title
    card.subtitle = subtitle
    card.route = 'message'
    const params: Record<string, string> = {}
    params['mid'] = mid
    card.params = JSON.stringify(params)
    return card
  }
}
