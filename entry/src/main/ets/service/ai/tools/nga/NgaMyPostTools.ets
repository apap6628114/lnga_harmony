/**
 * NGA「我的发帖 / 我的回帖」工具。
 *
 * 两个工具都走官方 APP 签名接口 `app_api.php user/subjects|replys`（signParams=目标 uid，
 * `__output=12`），也就是「用户主页 → TA 的主题 / TA 的回帖」同一通道，只是 uid 固定为
 * 当前登录账号。参数构建复用 `ForumApi.getTopicList` 的 `authorid` / `searchpost` 分支。
 *
 * **两者的分页语义不同，不能按同一套假设实现**（实测，2026-10）：
 *  - `subjects`：响应带真实 `totalPage`/`total`，可以一直翻到最后一页；
 *  - `replys`：每页 20 条、**不返回总数**，且越往前翻越多条目变成
 *    「帖子发布或回复时间超过限制」的占位——占位条目的 `tid` 是**列表序号**（187/215…）
 *    而不是真实 tid，`postdate` 是空串，正文为空。占位比例还**不是单调**的：
 *    同一个人可能这一页一半占位、下一页又全是真实条目（取决于当时回复的主题是否已超期限）。
 *
 * 因此 `nga_my_replies` 逐条过滤占位、报告本页跳过了多少条，并在整页不可读时明确
 * 告知「更早记录不可获取」，**不提供"翻到底"语义**。把它当成"最近若干页回帖"用，
 * 不要当成全量统计。
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
import { createTopicListParams, getTopicList } from '../../../api/ForumApi'
import type { TopicListParams } from '../../../api/ForumApi'
import type { TopicListResult } from '../../../../model/NgaApiResults'
import type { ThreadPageInfo, TopicListInfo } from '../../../../model/Topic'
import {
  bbcodeToText,
  buildToolParameters,
  failedResult,
  formatToolTime,
  intProperty,
  isNgaReady,
  isPlaceholderSubject,
  loginRequiredResult,
  missingSelfUidResult,
  parseToolArguments,
  pickNumber,
  readIntArg,
  topicCard,
  truncateText
} from './NgaToolSupport'

/** 我的发帖工具名。 */
const TOOL_MY_POSTS: string = 'nga_my_posts'
/** 我的回帖工具名。 */
const TOOL_MY_REPLIES: string = 'nga_my_replies'

/** 默认返回条数。 */
const DEFAULT_LIMIT: number = 20
/** 单次返回条数上限。 */
const MAX_LIMIT: number = 50
/** 单次最多附带的卡片数。 */
const MAX_CARDS: number = 20
/** 回帖正文片段长度上限（字符）。
 *
 * `truncateText` 内部把下限钳到 200，这里直接写 200，避免"注释 120、实际 200"的偏差。
 */
const SNIPPET_MAX: number = 200

/**
 * 判断条目是否为服务端不可读条目（超时限占位 / 权限不足 / 无作者）。
 *
 * 只认文案而不认 tid：占位条目的 tid 是非零的列表序号，靠 tid 判不出来；
 * 反过来真实标题里几乎不会出现这两句固定文案。`authorId === 0` 与既有
 * `UserApi.getUserActivityAnalysis` 的口径一致——这类条目没有可用作者信息，
 * 其 tid 也不能拿去读帖。
 *
 * @param topic - 列表条目
 * @returns true 表示占位/不可读
 */
function isPlaceholder(topic: ThreadPageInfo): boolean {
  return isPlaceholderSubject(topic.subject) || pickNumber(topic.authorId, 0) === 0
}

/**
 * 取「我的回复」正文片段（BBCode → 纯文本 → 去标签 → 截断）。
 *
 * 官方 `post.content` 可能混有 HTML 片段，`bbcodeToText` 只处理 BBCode 与实体，
 * 因此这里补一次标签剥离（与 `UserApi`、`TopicParser` 的既有同类处理一致）。
 *
 * @param topic - 回帖列表条目
 * @returns 片段；无正文时为空串
 */
function replySnippet(topic: ThreadPageInfo): string {
  const raw: string = topic.replyInfo.content
  if (raw.length === 0) {
    return ''
  }
  const plain: string = bbcodeToText(raw).replace(/<[^>]+>/g, '')
  const limited = truncateText(plain, SNIPPET_MAX)
  const text: string = limited.text.replace(/\s+/g, ' ').trim()
  return limited.truncated ? text + '…' : text
}

/**
 * 我的发帖工具（nga_my_posts）。
 */
export class NgaMyPostsTool implements AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_MY_POSTS
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_MY_POSTS
    definition.description =
      '读取当前登录账号自己发布的主题（官方接口 user/subjects，按发帖时间倒序，每页约 35 条）。' +
        '响应带真实总页数，可以翻页到最后一页；**但接口不返回主题总数**，' +
        '所以只能按页描述（「第 3 页 / 共 12 页」），不要声称「一共发了多少帖」。' +
        '只读当前账号；他人的发帖记录请用 nga_user_activity（只有样本）。'

    const properties: Record<string, Object> = {}
    properties['page'] = intProperty('页码，从 1 开始，默认 1')
    properties['limit'] = intProperty('本页展示条数 1-' + MAX_LIMIT.toString() +
      '，默认 ' + DEFAULT_LIMIT.toString() + '；不改变服务端返回页的大小')

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
    return isAiToolEnabled(context.tools, TOOL_MY_POSTS) && isNgaReady(context)
  }

  /**
   * 执行发帖记录读取。
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
    const uid: string = context.selfUid
    if (uid.length === 0) {
      return missingSelfUidResult()
    }
    const args: Record<string, Object> = parseToolArguments(argumentsText)
    const page: number = readIntArg(args, 'page', 1, 1, 1000)
    const limit: number = readIntArg(args, 'limit', DEFAULT_LIMIT, 1, MAX_LIMIT)

    const params: TopicListParams = createTopicListParams()
    params.authorid = uid
    params.page = page.toString()
    const fetched: TopicListResult = await getTopicList(context.token, params)
    const info: TopicListInfo | null = fetched.data
    if (info === null) {
      return failedResult(fetched.error.length > 0 ? fetched.error : '没有取到发帖记录', TOOL_ERROR_UPSTREAM)
    }
    // subjects 现网不下发占位，但仍按统一口径过滤，避免将来口径变化直接漏给模型
    const entries: ThreadPageInfo[] = []
    for (let i: number = 0; i < info.threadPageList.length; i++) {
      if (!isPlaceholder(info.threadPageList[i])) {
        entries.push(info.threadPageList[i])
      }
    }
    const totalPages: number = info.pagination.totalPages
    if (entries.length === 0) {
      // 已知总页数时直接告诉模型越界，别让它去猜「是不是没有公开主题」
      const hint: string = totalPages > 0
        ? '共 ' + totalPages.toString() + ' 页，请求的第 ' + page.toString() + ' 页超出范围。'
        : '第 ' + page.toString() + ' 页没有可用的发帖记录（可能该账号没有公开主题）。'
      return failedResult(hint, TOOL_ERROR_EMPTY)
    }
    let content: string = '我的发帖 · 第 ' + page.toString() + ' 页'
    if (totalPages > 0) {
      content += ' / 共 ' + totalPages.toString() + ' 页'
    }
    content += ' · 本页 ' + entries.length.toString() + ' 条\n'

    const shown: number = Math.min(limit, entries.length)
    const cards: AiToolCard[] = []
    for (let i: number = 0; i < shown; i++) {
      const topic: ThreadPageInfo = entries[i]
      content += '\n' + (i + 1).toString() + '. ' + topic.subject
      const meta: string = this.metaOf(topic)
      if (meta.length > 0) {
        content += '\n   ' + meta
      }
      content += '\n   tid=' + topic.tid.toString() + '\n'
      if (cards.length < MAX_CARDS) {
        cards.push(topicCard(topic.tid.toString(), topic.subject,
          meta.length > 0 ? meta : '我的发帖'))
      }
    }
    if (entries.length > shown) {
      content += '\n（本页还有 ' + (entries.length - shown).toString() + ' 条未展示，可增大 limit）'
    }
    content += '\n\n需要看某一帖的内容时调用 nga_read_thread 并传入 tid。'

    const result: AiToolResult = new AiToolResult()
    result.success = true
    result.summary = '我的发帖'
    result.count = shown
    result.content = content
    result.cards = cards
    return result
  }

  /**
   * 生成「版块 · 回复数 · 发帖时间」元信息。
   *
   * @param topic - 列表条目
   * @returns 元信息文本
   */
  private metaOf(topic: ThreadPageInfo): string {
    const parts: string[] = []
    if (topic.board.length > 0) {
      parts.push(topic.board)
    }
    parts.push(topic.replies.toString() + ' 回复')
    const time: string = formatToolTime(topic.postDate)
    if (time.length > 0) {
      parts.push(time)
    }
    let joined: string = ''
    for (let i: number = 0; i < parts.length; i++) {
      if (i > 0) {
        joined += ' · '
      }
      joined += parts[i]
    }
    return joined
  }
}

/**
 * 我的回帖工具（nga_my_replies）。
 */
export class NgaMyRepliesTool implements AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_MY_REPLIES
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_MY_REPLIES
    definition.description =
      '读取当前登录账号自己的回帖记录（官方接口 user/replys，按我的回复时间倒序，每页 20 条）。' +
        '**限制**：服务端只对较近的回帖保留可读内容，更早的条目会变成「帖子发布或回复时间超过限制」的占位；' +
        '本工具会跳过这些占位并说明跳过了多少条。因此本工具只适合回答' +
        '「我最近回过哪些帖」「我回过这个帖吗」，**不能用于全量回帖统计**——做不到。' +
        '不返回总页数，page 越大有效条目越少；整页不可读时应改用更小的 page。'

    const properties: Record<string, Object> = {}
    properties['page'] = intProperty('页码，从 1 开始，默认 1；越往后有效条目越少，通常只看前几页')
    properties['limit'] = intProperty('本页展示条数 1-' + MAX_LIMIT.toString() +
      '，默认 ' + DEFAULT_LIMIT.toString() + '；不改变服务端每页 20 条的大小')

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
    return isAiToolEnabled(context.tools, TOOL_MY_REPLIES) && isNgaReady(context)
  }

  /**
   * 执行回帖记录读取。
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
    const uid: string = context.selfUid
    if (uid.length === 0) {
      return missingSelfUidResult()
    }
    const args: Record<string, Object> = parseToolArguments(argumentsText)
    const page: number = readIntArg(args, 'page', 1, 1, 1000)
    const limit: number = readIntArg(args, 'limit', DEFAULT_LIMIT, 1, MAX_LIMIT)

    const params: TopicListParams = createTopicListParams()
    params.authorid = uid
    params.searchpost = '1'
    params.page = page.toString()
    const fetched: TopicListResult = await getTopicList(context.token, params)
    const info: TopicListInfo | null = fetched.data
    if (info === null) {
      return failedResult(fetched.error.length > 0 ? fetched.error : '没有取到回帖记录', TOOL_ERROR_UPSTREAM)
    }

    const entries: ThreadPageInfo[] = []
    let skipped: number = 0
    for (let i: number = 0; i < info.threadPageList.length; i++) {
      if (isPlaceholder(info.threadPageList[i])) {
        skipped++
      } else {
        entries.push(info.threadPageList[i])
      }
    }
    if (entries.length === 0) {
      let reason: string = '第 ' + page.toString() + ' 页为空：可能已经超过最后一页。'
      if (skipped > 0) {
        reason = '第 ' + page.toString() + ' 页的 ' + skipped.toString() +
          ' 条回帖记录全部不可读（「帖子发布或回复时间超过限制」或权限不足）：' +
          'NGA 只对较近的回帖保留可读内容，更早的记录无法通过接口获取。'
        reason += page > 1 ? '请改用更小的 page。' : '第 1 页已不可读，说明该账号几乎没有可回溯的回帖。'
      }
      return failedResult(reason, TOOL_ERROR_EMPTY)
    }

    let content: string = '我的回帖 · 第 ' + page.toString() + ' 页 · 可读 ' +
      entries.length.toString() + ' 条'
    if (skipped > 0) {
      content += '（另有 ' + skipped.toString() + ' 条因服务端时限不可读，已跳过）'
    }
    content += '\n'

    const shown: number = Math.min(limit, entries.length)
    const cards: AiToolCard[] = []
    for (let i: number = 0; i < shown; i++) {
      const topic: ThreadPageInfo = entries[i]
      content += '\n' + (i + 1).toString() + '. ' + topic.subject
      const snippet: string = replySnippet(topic)
      if (snippet.length > 0) {
        content += '\n   我的回复：' + snippet
      }
      const meta: string = this.metaOf(topic)
      if (meta.length > 0) {
        content += '\n   ' + meta
      }
      content += '\n   tid=' + topic.tid.toString() + '\n'
      if (cards.length < MAX_CARDS) {
        cards.push(topicCard(topic.tid.toString(), topic.subject,
          meta.length > 0 ? meta : '我的回帖'))
      }
    }
    if (entries.length > shown) {
      content += '\n（本页还有 ' + (entries.length - shown).toString() + ' 条未展示，可增大 limit）'
    }
    content += '\n\n需要看某一帖的内容时调用 nga_read_thread 并传入 tid。'

    const result: AiToolResult = new AiToolResult()
    result.success = true
    result.summary = '我的回帖'
    result.count = shown
    result.content = content
    result.cards = cards
    return result
  }

  /**
   * 生成「版块 · 我的回复时间」元信息。
   *
   * 注意时间取 `replyInfo.postDate`（我回复的那一刻），不是条目顶层的 `postDate`
   * （主题发布时间）——回帖列表里两者通常相差很远。
   *
   * @param topic - 列表条目
   * @returns 元信息文本
   */
  private metaOf(topic: ThreadPageInfo): string {
    const parts: string[] = []
    if (topic.board.length > 0) {
      parts.push(topic.board)
    }
    const replyAt: number = Number(topic.replyInfo.postDate)
    const time: string = formatToolTime(replyAt)
    if (time.length > 0) {
      parts.push('回复于 ' + time)
    }
    let joined: string = ''
    for (let i: number = 0; i < parts.length; i++) {
      if (i > 0) {
        joined += ' · '
      }
      joined += parts[i]
    }
    return joined
  }
}
