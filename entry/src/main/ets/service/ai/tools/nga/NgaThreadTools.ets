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
  MAX_MAX_CHARS,
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
  topicCard
} from './NgaToolSupport'

/** 工具名称。 */
const TOOL_NAME: string = 'nga_read_thread'
/** 默认读取楼数。 */
const DEFAULT_MAX_FLOORS: number = 15
/** 单次最多展示的楼层数（单页约 20 楼，50 足够覆盖一页并留余量）。 */
const MAX_MAX_FLOORS: number = 50
/**
 * 单楼正文的硬上限。
 *
 * 与 `MAX_MAX_CHARS` 取同一个值：单楼正文不应有比「一次工具调用总预算」更小的
 * 独立天花板。旧实现固定 1800 字，模型把 `max_chars` 调到 20000 也读不到长楼的
 * 后半段——没有任何参数能突破它，属于「看到了上限却拿不到数据」。
 */
const MAX_FLOOR_CHARS: number = MAX_MAX_CHARS

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
        'max_floors 只控制本次展示多少楼，不能跨页；本页还有楼层未展示时结果里会明确提示。' +
        '正文总量受 max_chars 限制（500-20000）；单个楼层过长时会按剩余预算截断，' +
        '并用更大的 max_chars 重读可拿到该楼剩余部分。'

    const properties: Record<string, Object> = {}
    properties['tid'] = stringProperty('帖子 ID；省略时使用当前打开的帖子')
    properties['page'] = intProperty('页码，从 1 开始，默认 1；每次只读一页')
    properties['pid'] = stringProperty('楼层 pid；用于定位到该楼层所在页。' +
      '必须同时提供 tid，只给 pid 会失败')
    properties['max_floors'] = intProperty('本次最多展示多少个楼层，1-' +
      MAX_MAX_FLOORS.toString() + '，默认 ' + DEFAULT_MAX_FLOORS.toString() +
      '；受单页楼层数（约 20）限制，不能跨页')
    properties['max_chars'] = intProperty('本次返回正文总字符上限，500-' +
      MAX_MAX_CHARS.toString() + '，默认 ' + DEFAULT_MAX_CHARS.toString())

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
    const maxFloors: number = readIntArg(args, 'max_floors', DEFAULT_MAX_FLOORS, 1, MAX_MAX_FLOORS)
    const maxChars: number = readIntArg(args, 'max_chars', DEFAULT_MAX_CHARS, 500, MAX_MAX_CHARS)

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
    let shownFloors: number = 0
    /** 因单楼正文超出预算而被截断的楼层号（0 表示未发生）。 */
    let cutFloor: number = 0
    /** 被截断楼层正文的完整字符数（用于说明实际损失了多少）。 */
    let cutFloorChars: number = 0
    for (let i: number = 0; i < limit; i++) {
      const post: PostInfo = result.posts[i]
      const body: string = bbcodeToText(post.content)
      const header: string = '\n—— 第' + post.lou.toString() + '楼 · 作者：' +
        (post.author.length > 0 ? post.author : '匿名') +
        (post.postdate.length > 0 ? ' · ' + post.postdate : '') + ' ——\n'
      const floorText: string = body.length > 0 ? body : '（空正文）'
      const remaining: number = maxChars - consumed
      if (remaining <= header.length + 1) {
        // 连楼层头都放不下：不追加半截标题，剩余楼层统一在循环后提示
        break
      }
      const bodyBudget: number = remaining - header.length - 1
      const bodyLimit: number = Math.min(bodyBudget, MAX_FLOOR_CHARS)
      if (floorText.length <= bodyLimit) {
        const block: string = header + floorText + '\n'
        content += block
        consumed += block.length
        shownFloors++
        continue
      }
      /*
       * 单楼就超出剩余预算：旧实现直接丢弃整个楼层（模型拿到只有标题、没有正文），
       * 或按 1800 字固定截断后再也没有入口读剩余。这里给出前 bodyLimit 字并标注
       * 「用更大的 max_chars 重读」，保证任何长度的楼层都有可执行的下一步。
       */
      content += header + floorText.substring(0, bodyLimit) +
        '…（本楼正文超出本次预算，已截断；用更大的 max_chars 重读本页可拿到剩余部分）' + '\n'
      shownFloors++
      cutFloor = post.lou
      cutFloorChars = floorText.length
      break
    }

    const remainingFloors: number = result.posts.length - shownFloors
    if (cutFloor > 0) {
      if (maxChars >= MAX_MAX_CHARS) {
        // 已经到工具硬上限，再让模型「增大 max_chars」就是给一条走不通的路
        content += '\n（第 ' + cutFloor.toString() + ' 楼正文共 ' + cutFloorChars.toString() +
          ' 字，超过单次输出上限 ' + MAX_MAX_CHARS.toString() +
          ' 字符，本次只展示了前一部分；无法通过增大 max_chars 读全，' +
          '需要完整内容请让用户在客户端打开该楼）\n'
      } else {
        content += '\n（第 ' + cutFloor.toString() + ' 楼正文共 ' + cutFloorChars.toString() +
          ' 字，超出本次 max_chars=' + maxChars.toString() +
          ' 的预算，只展示了前一部分；需要完整正文时增大 max_chars 重读本页）\n'
      }
    } else if (shownFloors < limit) {
      content += '\n（正文已达本次读取上限 max_chars=' + maxChars.toString() + '，本页还有 ' +
        (limit - shownFloors).toString() + ' 个楼层未展示；可增大 max_chars 或翻页）\n'
    } else if (remainingFloors > 0) {
      content += '\n（本页还有 ' + remainingFloors.toString() +
        ' 个楼层未展示，可增大 max_floors 后重读本页）\n'
    }

    const result2: AiToolResult = new AiToolResult()
    result2.success = true
    result2.summary = subject
    result2.count = shownFloors
    result2.content = content

    const cards: AiToolCard[] = []
    cards.push(topicCard(tid, subject,
      (forumName.length > 0 ? forumName + ' · ' : '') + shownFloors.toString() + ' 楼'))
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
