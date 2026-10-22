/**
 * NGA 读帖工具（nga_read_thread）。
 *
 * 让模型自己决定读哪一页、哪些楼层、最多读多少字——而不是由调用方
 * 在拼 prompt 时就把正文拍平塞进对话。
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
import { getThread, locatePidPage } from '../../../api/ThreadApi'
import { ThreadResult } from '../../../../model/ThreadResult'
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
        '当前页面有帖子时可省略 tid 直接读当前帖。' +
        '每次只读一页（约 20 楼）：想读更多楼层请翻页（传更大的 page），' +
        'max_floors 只控制本次展示多少楼，不能跨页。' +
        '单楼正文超过 1800 字会被截断，总正文受 max_chars 限制。'

    const properties: Record<string, Object> = {}
    properties['tid'] = stringProperty('帖子 ID；省略时使用当前打开的帖子')
    properties['page'] = intProperty('页码，从 1 开始，默认 1；每次只读一页')
    properties['pid'] = stringProperty('楼层 pid；用于定位到该楼层所在页。' +
      '必须同时提供 tid，只给 pid 会失败')
    properties['max_floors'] = intProperty('本次最多展示多少个楼层，1-50，默认 15；' +
      '受单页楼层数（约 20）限制，不能跨页')
    properties['max_chars'] = intProperty('本次返回正文总字符上限，500-20000，默认 6000')

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
        '也可以从帖子页面进入本次对话（会自动带上 tid）', TOOL_ERROR_BAD_ARGS)
    }
    // 只有 pid 无法构造可点击卡片（卡片按 tid 跳转），也无法做 pid→页码的二分定位；
    // 与其返回一张点了没反应的卡片，不如把缺什么说清楚
    if (tid.length === 0) {
      return failedResult('只给了 pid 而缺少 tid：pid 定位和结果卡片都需要 tid。' +
        '请传 tid（可从帖子链接或 nga_search_topics 得到）', TOOL_ERROR_BAD_ARGS)
    }
    const page: number = readIntArg(args, 'page', 1, 1, 100000)
    const maxFloors: number = readIntArg(args, 'max_floors', DEFAULT_MAX_FLOORS, 1, 50)
    const maxChars: number = readIntArg(args, 'max_chars', DEFAULT_MAX_CHARS, 500, 20000)

    let result: ThreadResult = await getThread(context.token, tid, pid, '', page.toString())
    // read.php 带 pid 时通常直接返回该楼所在页，但不保证；未命中时用项目里
    // pid-only 入口统一的二分定位兜底，避免"读到的其实是第 1 页却声称定位成功"
    const pidLocate: PidLocateState = await ensurePidPage(context.token, tid, pid, result)
    result = pidLocate.result
    if (result.posts.length === 0) {
      return failedResult(result.error.length > 0 ? result.error : '该帖子没有可读楼层',
        TOOL_ERROR_EMPTY)
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
    if (pidLocate.hint.length > 0) {
      content += pidLocate.hint + '\n'
    }

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

/** pid 定位结果：最终取数结果 + 给模型看的定位说明。 */
class PidLocateState {
  /** 最终用于格式化的取数结果 */
  result: ThreadResult = new ThreadResult()
  /** 定位说明（无 pid 参数时为空串） */
  hint: string = ''
}

/**
 * 确保 pid 指定的楼层所在页被正确读取。
 *
 * 取数顺序：先按 pid 直接请求（服务端通常能定位到该楼所在页，只需一次请求）；
 * 若返回页里不含目标 pid，再用项目里所有 pid-only 入口统一的 `locatePidPage`
 * 二分换算页码后重新读取。这样正常路径不增加请求，异常路径才有额外成本。
 *
 * @param token - 会话令牌
 * @param tid - 帖子 ID
 * @param pid - 目标楼层 pid（空串表示不定位）
 * @param initial - 首次取数结果
 * @returns 定位结果
 */
async function ensurePidPage(token: string, tid: string, pid: string,
  initial: ThreadResult): Promise<PidLocateState> {
  const state: PidLocateState = new PidLocateState()
  state.result = initial
  if (pid.length === 0) {
    return state
  }
  // 首页就失败时不要再花多次二分请求，直接把错误交给调用方
  if (initial.posts.length === 0 && initial.error.length > 0) {
    return state
  }
  const targetPid: number = Number(pid)
  if (isNaN(targetPid) || targetPid <= 0) {
    state.hint = '（pid 不是有效数字，已忽略楼层定位）'
    return state
  }
  const initialPage: number = initial.pagination.page > 0 ? initial.pagination.page : 1
  if (containsPostPid(initial.posts, targetPid)) {
    state.hint = '（已定位到目标楼层所在页：第 ' + initialPage.toString() + ' 页）'
    return state
  }
  const locatedPage: number = await locatePidPage(token, tid, targetPid)
  if (locatedPage <= 0) {
    state.hint = '（未能确认 pid=' + pid.toString() + ' 所在页码，可能该楼层已删除；' +
      '当前返回第 ' + initialPage.toString() + ' 页）'
    return state
  }
  if (locatedPage === initialPage) {
    state.hint = '（目标楼层所在页为第 ' + locatedPage.toString() + ' 页，但该页未包含 pid=' +
      pid.toString() + '，可能已被删除）'
    return state
  }
  const refetched: ThreadResult = await getThread(token, tid, pid, '', locatedPage.toString())
  if (refetched.posts.length > 0) {
    state.result = refetched
    state.hint = '（已按 pid 二分定位到第 ' + locatedPage.toString() + ' 页）'
    return state
  }
  state.hint = '（目标楼层所在页为第 ' + locatedPage.toString() + ' 页，但重新读取失败，' +
    '已返回第 ' + initialPage.toString() + ' 页内容）'
  return state
}

/**
 * 判断楼层列表里是否包含指定 pid。
 *
 * @param posts - 楼层列表
 * @param targetPid - 目标 pid
 * @returns true 表示包含
 */
function containsPostPid(posts: PostInfo[], targetPid: number): boolean {
  for (let i: number = 0; i < posts.length; i++) {
    if (posts[i].pid === targetPid) {
      return true
    }
  }
  return false
}
