/**
 * NGA「我的」本地资料工具（浏览记录 / 离线保存 / 跟踪）。
 *
 * 三个工具都读客户端本地数据，**不发起任何网络请求**，因此也不会消耗风控额度：
 *  - `nga_my_history`：浏览记录（顺带给出已读基线，可判断"之后有没有新回复"）
 *  - `nga_my_saved`：离线保存的帖子存档（设备级，登出流程不清它，免登录）
 *  - `nga_my_tracked`：跟踪中的帖子（总回复 / 已读基准 / 未读新增 / 锁定态）
 *
 * 共同形态：**列表 + 单帖查询**。不传 `tid` 时返回最近 N 条；传 `tid` 时只回答
 * "这帖我看过吗 / 保存了吗 / 在跟踪吗"。两类问题在对话里同样高频，而单帖查询
 * 的成本只是一个可选参数，不额外增加工具数量。
 *
 * 时间单位约定（三处数据源不一致，转换集中在这里与 `NgaToolSupport.toSeconds`）：
 *  - `BrowseHistoryEntry.ts`、`SavedThread.savedAt`、`TrackedThread.createdAt` 是**毫秒**
 *  - `TrackedThread.lastPostTs` 是**秒**
 *  - `formatToolTime` 只接受**秒**
 *
 * 防御性读取：本地持久化数据可能来自旧格式、外部导入文件或半截写入，
 * 字段缺失是**预期输入**（`HistoryStore.rebuildReadBaselines` 也在防同一件事）。
 * 这里所有字段都经 `pickText` / `pickNumber` 读取——工具抛异常会冒泡到
 * `AiAgentRunner` 并终止整轮对话，代价远高于回退成空串。
 */

import { AiToolDefinition } from '../../AiProtocolTypes'
import {
  AiToolAdapter,
  AiToolCard,
  AiToolContext,
  AiToolResult,
  TOOL_ERROR_EMPTY
} from '../AiToolAdapter'
import { isAiToolEnabled } from '../../../../model/AiToolConfig'
import { appStore } from '../../../../store/AppStore'
import type { BrowseHistoryEntry } from '../../../../store/HistoryStore'
import type { SavedThread } from '../../../../model/SavedThread'
import type { TrackedThread } from '../../../../model/TrackedThread'
import { remainingTrackDays, unreadReplyCount } from '../../../../common/utils/ThreadTrackPolicy'
import { READ_BASELINE_UNKNOWN } from '../../../../common/utils/TopicReadPolicy'
import {
  buildToolParameters,
  failedResult,
  formatToolTime,
  intProperty,
  isNgaReady,
  loginRequiredResult,
  missingSelfUidResult,
  parseToolArguments,
  pickNumber,
  pickText,
  readIntArg,
  readStringArg,
  stringProperty,
  toSeconds,
  topicCard
} from './NgaToolSupport'

/** 浏览记录工具名。 */
const TOOL_HISTORY: string = 'nga_my_history'
/** 离线保存工具名。 */
const TOOL_SAVED: string = 'nga_my_saved'
/** 跟踪工具名。 */
const TOOL_TRACKED: string = 'nga_my_tracked'

/** 默认返回条数。 */
const DEFAULT_LIMIT: number = 20
/** 单次返回条数上限。 */
const MAX_LIMIT: number = 50
/** 单次最多附带的卡片数（卡片是 UI 元素，过多会拖慢列表渲染）。 */
const MAX_CARDS: number = 20
/** 浏览记录本地保留上限（与 HistoryStore 的 HISTORY_MAX_COUNT 一致）。 */
const HISTORY_CAP: number = 500

/**
 * 生成「版块 · 作者」形式的副标题片段（空字段自动省略）。
 *
 * @param forum - 版块名（运行时可能缺失）
 * @param author - 作者名（运行时可能缺失）
 * @returns 拼接结果（两者皆空时为空串）
 */
function byline(forum: string | undefined, author: string | undefined): string {
  const parts: string[] = []
  const forumText: string = pickText(forum)
  const authorText: string = pickText(author)
  if (forumText.length > 0) {
    parts.push(forumText)
  }
  if (authorText.length > 0) {
    parts.push(authorText)
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

/**
 * 取展示用标题（缺失时以 tid 兜底，避免出现「《》」）。
 *
 * @param subject - 标题（运行时可能缺失）
 * @param tid - 主题 ID
 * @returns 展示标题
 */
function titleOf(subject: string | undefined, tid: string): string {
  const text: string = pickText(subject)
  return text.length > 0 ? text : '帖子 ' + tid
}

/**
 * 浏览记录工具（nga_my_history）。
 */
export class NgaMyHistoryTool implements AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_HISTORY
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_HISTORY
    definition.description =
      '读取当前登录账号的本地浏览记录：最近打开过的帖子，按时间倒序，客户端最多保留 ' +
        HISTORY_CAP.toString() + ' 条。这是本地台账，不发起网络请求。' +
        '不传 tid 时列出最近 N 条；传 tid 时只查该帖是否看过，并给出读帖时的回复数基线' +
        '（基线小于当前回复数即表示之后有新回复）。' +
        '用户问「我最近看了哪些帖」「这帖我看过吗」时使用。'

    const properties: Record<string, Object> = {}
    properties['limit'] = intProperty('返回条数 1-50，默认 20；仅在列表模式下生效')
    properties['tid'] = stringProperty('只查这一个帖子是否在浏览记录里；省略时返回最近浏览列表')

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
    return isAiToolEnabled(context.tools, TOOL_HISTORY) && isNgaReady(context)
  }

  /**
   * 执行浏览记录读取。
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
    const tid: string = readStringArg(args, 'tid')
    // 浏览记录按账号分键存放：必须先有 uid 才能读到正确的台账
    const entries: BrowseHistoryEntry[] = await appStore.getBrowseHistory(uid)
    if (tid.length > 0) {
      return this.describeSingle(entries, tid)
    }
    if (entries.length === 0) {
      return failedResult('本地还没有浏览记录：打开任意帖子后会自动记录（最多 ' +
        HISTORY_CAP.toString() + ' 条）。', TOOL_ERROR_EMPTY)
    }
    return this.describeList(entries, readIntArg(args, 'limit', DEFAULT_LIMIT, 1, MAX_LIMIT))
  }

  /**
   * 描述单个帖子的浏览状态。
   *
   * @param entries - 浏览记录（按时间倒序）
   * @param tid - 目标帖子
   * @returns 工具结果
   */
  private describeSingle(entries: BrowseHistoryEntry[], tid: string): AiToolResult {
    let hit: BrowseHistoryEntry | null = null
    for (let i: number = 0; i < entries.length; i++) {
      const entry: BrowseHistoryEntry | null = entries[i]
      if (entry === null || entry === undefined) {
        continue
      }
      if (pickText(entry.tid) === tid) {
        hit = entry
        break
      }
    }
    const result: AiToolResult = new AiToolResult()
    if (hit === null) {
      result.success = true
      result.summary = '未看过'
      result.count = 0
      result.content = 'tid=' + tid + ' 不在本地浏览记录里：可能从未打开过，也可能已被 ' +
        HISTORY_CAP.toString() + ' 条上限淘汰。'
      return result
    }

    const subject: string = titleOf(hit.subject, tid)
    let content: string = '《' + subject + '》（tid=' + tid + '）在浏览记录里。'
    const meta: string = byline(hit.board, hit.author)
    if (meta.length > 0) {
      content += '\n- ' + meta
    }
    const baseline: number = pickNumber(hit.replies, READ_BASELINE_UNKNOWN)
    if (baseline >= 0) {
      content += '\n- 读到时的回复数：' + baseline.toString() + '（当前回复数大于该值即表示之后有新回复）'
    } else {
      content += '\n- 读到时的回复数：未知（读帖时未取到服务端总数，无法判定是否有新回复）'
    }
    const opened: string = formatToolTime(toSeconds(pickNumber(hit.ts, 0)))
    if (opened.length > 0) {
      content += '\n- 最近打开：' + opened
    }

    result.success = true
    result.summary = subject
    result.count = 1
    result.content = content
    const cards: AiToolCard[] = []
    cards.push(topicCard(tid, subject, meta.length > 0 ? meta : '浏览记录'))
    result.cards = cards
    return result
  }

  /**
   * 描述最近浏览列表。
   *
   * @param entries - 浏览记录（按时间倒序）
   * @param limit - 返回条数
   * @returns 工具结果
   */
  private describeList(entries: BrowseHistoryEntry[], limit: number): AiToolResult {
    const shown: number = Math.min(limit, entries.length)
    let content: string = '本地浏览记录（共 ' + entries.length.toString() +
      ' 条，显示最近 ' + shown.toString() + ' 条）：'
    const cards: AiToolCard[] = []
    for (let i: number = 0; i < shown; i++) {
      const entry: BrowseHistoryEntry | null = entries[i]
      if (entry === null || entry === undefined) {
        continue
      }
      const tid: string = pickText(entry.tid)
      const subject: string = titleOf(entry.subject, tid)
      const meta: string = byline(entry.board, entry.author)
      const opened: string = formatToolTime(toSeconds(pickNumber(entry.ts, 0)))
      content += '\n' + (i + 1).toString() + '. ' + subject + '（tid=' + tid
      if (meta.length > 0) {
        content += ' · ' + meta
      }
      content += '）'
      if (opened.length > 0) {
        content += ' ' + opened
      }
      if (cards.length < MAX_CARDS && tid.length > 0) {
        cards.push(topicCard(tid, subject, meta.length > 0 ? meta : '浏览记录'))
      }
    }
    if (entries.length > shown) {
      content += '\n（还有 ' + (entries.length - shown).toString() + ' 条更早的记录，可增大 limit 继续看）'
    }

    const result: AiToolResult = new AiToolResult()
    result.success = true
    result.summary = '浏览记录'
    result.count = shown
    result.content = content
    result.cards = cards
    return result
  }
}

/**
 * 离线保存工具（nga_my_saved）。
 *
 * **不要求登录**：存档是设备本地文件，登出流程不清它，与账号无关；
 * 因此登出后用户仍能问"我保存了哪些帖子"，工具也照常回答。
 * 代价是 AI 必须知道这层语义——描述里显式写明"设备级、跨账号"。
 */
export class NgaMySavedTool implements AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_SAVED
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_SAVED
    definition.description =
      '读取本地离线保存的帖子存档（「收藏、保存与跟踪」里的离线保存）。' +
        '这是**设备本地文件**，与登录账号无关、不随登出清空，未登录也可用；' +
        '因此不要把它当成「当前账号保存的」。不发起网络请求。' +
        '不传 tid 时列出最近保存的 N 条（含已存页数与最后楼层）；传 tid 时只查该帖是否已保存。'

    const properties: Record<string, Object> = {}
    properties['limit'] = intProperty('返回条数 1-50，默认 20；仅在列表模式下生效')
    properties['tid'] = stringProperty('只查这一个帖子是否已有离线存档；省略时返回保存列表')

    const required: string[] = []
    definition.parameters = buildToolParameters(properties, required)
    return definition
  }

  /**
   * 判断工具是否可用（免登录，只受全局开关约束）。
   *
   * @param context - 工具执行上下文
   * @returns true 表示可用
   */
  isAvailable(context: AiToolContext): boolean {
    return isAiToolEnabled(context.tools, TOOL_SAVED)
  }

  /**
   * 执行离线存档读取。
   *
   * @param argumentsText - 模型生成的参数 JSON
   * @param context - 工具执行上下文
   * @param fallbackQuery - 兜底查询（不使用）
   * @returns 工具结果
   */
  async execute(argumentsText: string, context: AiToolContext,
    fallbackQuery: string): Promise<AiToolResult> {
    const args: Record<string, Object> = parseToolArguments(argumentsText)
    const tid: string = readStringArg(args, 'tid')
    if (tid.length > 0) {
      return this.describeSingle(appStore.savedThreadStore.getByTid(tid), tid)
    }
    const items: SavedThread[] = appStore.savedThreadStore.getAll()
    if (items.length === 0) {
      return failedResult('本地还没有离线保存的帖子：在帖子页保存后才会出现在这里。', TOOL_ERROR_EMPTY)
    }
    return this.describeList(items, readIntArg(args, 'limit', DEFAULT_LIMIT, 1, MAX_LIMIT))
  }

  /**
   * 描述单个帖子的保存状态。
   *
   * @param saved - 存档（不存在为 null）
   * @param tid - 目标帖子
   * @returns 工具结果
   */
  private describeSingle(saved: SavedThread | null, tid: string): AiToolResult {
    const result: AiToolResult = new AiToolResult()
    if (saved === null || saved === undefined) {
      result.success = true
      result.summary = '未保存'
      result.count = 0
      result.content = 'tid=' + tid + ' 没有本地离线存档。'
      return result
    }

    const subject: string = titleOf(saved.subject, tid)
    let content: string = '《' + subject + '》（tid=' + tid + '）有离线存档。'
    const meta: string = byline(saved.forumName, saved.author)
    if (meta.length > 0) {
      content += '\n- ' + meta
    }
    const savedPages: number = pickNumber(saved.savedPages, 0)
    const totalPages: number = pickNumber(saved.totalPages, 0)
    if (totalPages > 0) {
      content += '\n- 已存页数：' + savedPages.toString() + ' / 共 ' + totalPages.toString() + ' 页'
    } else {
      content += '\n- 已存页数：' + savedPages.toString() + ' 页（总页数未知）'
    }
    const lastLou: number = pickNumber(saved.lastLou, 0)
    if (lastLou > 0) {
      content += '\n- 最后一楼：' + lastLou.toString() + ' 楼'
    }
    const savedAt: string = formatToolTime(toSeconds(pickNumber(saved.savedAt, 0)))
    if (savedAt.length > 0) {
      content += '\n- 保存时间：' + savedAt
    }

    result.success = true
    result.summary = subject
    result.count = 1
    result.content = content
    const cards: AiToolCard[] = []
    cards.push(topicCard(tid, subject, meta.length > 0 ? meta : '离线存档'))
    result.cards = cards
    return result
  }

  /**
   * 描述离线存档列表。
   *
   * @param items - 存档列表（按保存时间降序）
   * @param limit - 返回条数
   * @returns 工具结果
   */
  private describeList(items: SavedThread[], limit: number): AiToolResult {
    const shown: number = Math.min(limit, items.length)
    let content: string = '本地离线存档（共 ' + items.length.toString() +
      ' 条，显示最近 ' + shown.toString() + ' 条；设备级，跨账号）：'
    const cards: AiToolCard[] = []
    for (let i: number = 0; i < shown; i++) {
      const item: SavedThread | null = items[i]
      if (item === null || item === undefined) {
        continue
      }
      const tid: string = pickText(item.tid)
      const subject: string = titleOf(item.subject, tid)
      const meta: string = byline(item.forumName, item.author)
      const savedPages: number = pickNumber(item.savedPages, 0)
      const totalPages: number = pickNumber(item.totalPages, 0)
      const lastLou: number = pickNumber(item.lastLou, 0)
      const savedAt: string = formatToolTime(toSeconds(pickNumber(item.savedAt, 0)))
      content += '\n' + (i + 1).toString() + '. ' + subject + '（tid=' + tid
      if (meta.length > 0) {
        content += ' · ' + meta
      }
      content += totalPages > 0
        ? ' · ' + savedPages.toString() + '/' + totalPages.toString() + ' 页'
        : ' · 已存 ' + savedPages.toString() + ' 页'
      if (lastLou > 0) {
        content += ' · 到 ' + lastLou.toString() + ' 楼'
      }
      content += '）'
      if (savedAt.length > 0) {
        content += ' ' + savedAt
      }
      if (cards.length < MAX_CARDS && tid.length > 0) {
        cards.push(topicCard(tid, subject, meta.length > 0 ? meta : '离线存档'))
      }
    }
    if (items.length > shown) {
      content += '\n（还有 ' + (items.length - shown).toString() + ' 条更早的存档，可增大 limit 继续看）'
    }

    const result: AiToolResult = new AiToolResult()
    result.success = true
    result.summary = '离线存档'
    result.count = shown
    result.content = content
    result.cards = cards
    return result
  }
}

/**
 * 跟踪工具（nga_my_tracked）。
 */
export class NgaMyTrackedTool implements AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_TRACKED
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_TRACKED
    definition.description =
      '读取当前账号正在跟踪的帖子（客户端最多同时跟踪 50 条）。' +
        '每条返回总回复数、已读基准、未读新增数、最后回复时间与锁定状态——' +
        '这是判断「这帖有没有新回复」的唯一本地数据源。' +
        '数据是轮询快照（前台每 10 分钟检查一次），不发起网络请求；' +
        '要拿最新状态请让用户先打开客户端刷新。' +
        '不传 tid 时列出跟踪列表（有未读的排前面）；传 tid 时只查该帖是否在跟踪。'

    const properties: Record<string, Object> = {}
    properties['limit'] = intProperty('返回条数 1-50，默认 20；仅在列表模式下生效')
    properties['tid'] = stringProperty('只查这一个帖子是否在跟踪；省略时返回跟踪列表')

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
    return isAiToolEnabled(context.tools, TOOL_TRACKED) && isNgaReady(context)
  }

  /**
   * 执行跟踪列表读取。
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
    const tid: string = readStringArg(args, 'tid')
    if (tid.length > 0) {
      return this.describeSingle(appStore.trackedThreadStore.getByTid(tid), tid)
    }
    const items: TrackedThread[] = appStore.getTrackedThreads()
    if (items.length === 0) {
      return failedResult('当前没有跟踪中的帖子：在帖子页开启跟踪后才会出现在这里。', TOOL_ERROR_EMPTY)
    }
    return this.describeList(items, readIntArg(args, 'limit', DEFAULT_LIMIT, 1, MAX_LIMIT))
  }

  /**
   * 描述单个帖子的跟踪状态。
   *
   * @param tracked - 跟踪任务（未跟踪为 null）
   * @param tid - 目标帖子
   * @returns 工具结果
   */
  private describeSingle(tracked: TrackedThread | null, tid: string): AiToolResult {
    const result: AiToolResult = new AiToolResult()
    if (tracked === null || tracked === undefined) {
      result.success = true
      result.summary = '未跟踪'
      result.count = 0
      result.content = 'tid=' + tid + ' 不在跟踪列表里。'
      return result
    }

    const subject: string = titleOf(tracked.subject, tid)
    const totalReplies: number = pickNumber(tracked.totalReplies, 0)
    const seenReplies: number = pickNumber(tracked.seenReplies, 0)
    const unread: number = unreadReplyCount(tracked)
    let content: string = '《' + subject + '》（tid=' + tid + '）正在跟踪。'
    const meta: string = byline(tracked.forumName, tracked.author)
    if (meta.length > 0) {
      content += '\n- ' + meta
    }
    content += '\n- 总回复数：' + totalReplies.toString()
    content += '\n- 已读基准：' + seenReplies.toString()
    content += '\n- 未读新增：' + unread.toString() + ' 条'
    const lastPost: string = formatToolTime(pickNumber(tracked.lastPostTs, 0))
    if (lastPost.length > 0) {
      content += '\n- 最后回复：' + lastPost
    }
    const remaining: number = remainingTrackDays(tracked, Date.now())
    content += '\n- 剩余跟踪：' + remaining.toString() + ' 天（连续 ' +
      pickNumber(tracked.keepDays, 0).toString() + ' 天无新回复自动停止）'
    if (tracked.locked === true) {
      content += '\n- 状态：帖子已被锁定'
    }
    const failCount: number = pickNumber(tracked.failCount, 0)
    if (failCount > 0) {
      const lastError: string = pickText(tracked.lastError)
      content += '\n- 最近一次检查失败 ' + failCount.toString() + ' 次' +
        (lastError.length > 0 ? '（' + lastError + '）' : '') + '，数据可能偏旧'
    }

    result.success = true
    result.summary = subject
    result.count = 1
    result.content = content
    const cards: AiToolCard[] = []
    cards.push(topicCard(tid, subject, unread > 0 ? '未读 +' + unread.toString() : '跟踪中'))
    result.cards = cards
    return result
  }

  /**
   * 描述跟踪列表。
   *
   * @param items - 跟踪任务（有未读的在前）
   * @param limit - 返回条数
   * @returns 工具结果
   */
  private describeList(items: TrackedThread[], limit: number): AiToolResult {
    const shown: number = Math.min(limit, items.length)
    let unreadItems: number = 0
    for (let i: number = 0; i < items.length; i++) {
      const item: TrackedThread | null = items[i]
      if (item !== null && item !== undefined && unreadReplyCount(item) > 0) {
        unreadItems++
      }
    }
    let content: string = '跟踪中的帖子（共 ' + items.length.toString() + ' 条，其中 ' +
      unreadItems.toString() + ' 条有未读新增；显示前 ' + shown.toString() + ' 条）：'
    const cards: AiToolCard[] = []
    for (let i: number = 0; i < shown; i++) {
      const item: TrackedThread | null = items[i]
      if (item === null || item === undefined) {
        continue
      }
      const tid: string = pickText(item.tid)
      const subject: string = titleOf(item.subject, tid)
      const unread: number = unreadReplyCount(item)
      const meta: string = byline(item.forumName, item.author)
      const lastPost: string = formatToolTime(pickNumber(item.lastPostTs, 0))
      content += '\n' + (i + 1).toString() + '. ' + subject + '（tid=' + tid
      if (meta.length > 0) {
        content += ' · ' + meta
      }
      content += ' · ' + pickNumber(item.totalReplies, 0).toString() + ' 回复'
      content += ' · 已读 ' + pickNumber(item.seenReplies, 0).toString()
      if (unread > 0) {
        content += ' · 未读 +' + unread.toString()
      }
      if (item.locked === true) {
        content += ' · 已锁定'
      }
      content += '）'
      if (lastPost.length > 0) {
        content += ' ' + lastPost
      }
      if (cards.length < MAX_CARDS && tid.length > 0) {
        cards.push(topicCard(tid, subject,
          unread > 0 ? '未读 +' + unread.toString() : '跟踪中'))
      }
    }
    if (items.length > shown) {
      content += '\n（还有 ' + (items.length - shown).toString() + ' 条，可增大 limit 继续看）'
    }

    const result: AiToolResult = new AiToolResult()
    result.success = true
    result.summary = '跟踪列表'
    result.count = shown
    result.content = content
    result.cards = cards
    return result
  }
}
