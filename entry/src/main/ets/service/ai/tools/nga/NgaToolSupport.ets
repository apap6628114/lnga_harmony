/**
 * NGA 站内工具的公共支撑。
 *
 * 这一层只做「把 NGA 的模型对象压成模型可读文本 + 可点击卡片」，
 * 不包含任何具体业务逻辑；每个工具各自负责取数与裁剪。
 */

import {
  AiToolCard,
  AiToolContext,
  AiToolResult,
  TOOL_ERROR_BAD_ARGS,
  TOOL_ERROR_LOGIN_REQUIRED
} from '../AiToolAdapter'
import { getCachedBBNodes } from '../../../../parser/bbcode/BBCodeCache'
import { bbNodesToPlainText, formatTimestampCST } from '../../../../common/utils/Utils'

/** 单条工具输出的默认字符上限（模型上下文友好）。 */
export const DEFAULT_MAX_CHARS: number = 6000
/** 单条工具输出允许的最大字符数。 */
export const MAX_MAX_CHARS: number = 20000
/** 列表类工具默认返回条数。 */
export const DEFAULT_LIST_LIMIT: number = 20
/** 列表类工具允许的最大条数。 */
export const MAX_LIST_LIMIT: number = 50
/** 列表类工具允许的最大起始偏移。 */
export const MAX_LIST_OFFSET: number = 5000

/** 截断结果。 */
export class TruncatedText {
  /** 截断后的文本 */
  text: string = ''
  /** 是否发生截断 */
  truncated: boolean = false
}

/**
 * 一次列表读取的窗口（偏移 + 条数）。
 *
 * 工具不能只暴露 `limit`：本地台账（浏览记录）最多 500 条、关注动态缓存可达数百条，
 * 只有 `limit` 时模型最多拿到 50 条，剩余数据**没有任何入口**——而工具描述里还写着
 * 「可增大 limit 继续看」，属于虚假能力。窗口把「从第几条开始、本次看多少、还有没有」
 * 变成显式的三件事，工具只要照着拼文案，就不会再出现「到 50 条就断头」。
 */
export class ListWindow {
  /** 起始下标（已按总数裁剪，0 起） */
  start: number = 0
  /** 本次应展示的条数 */
  count: number = 0
  /** 目标列表总条数 */
  total: number = 0
  /** 是否还有未展示的条目 */
  hasMore: boolean = false
  /** 下一段的起始偏移（hasMore 为 false 时等于 total） */
  nextOffset: number = 0
}

/**
 * 把「偏移 + 条数 + 总数」解析成可安全遍历的窗口。
 *
 * 边界约定：负偏移按 0 处理；偏移超过总数时窗口为空（`count === 0`），
 * 由调用方给出明确的「超出范围」提示，而不是返回空列表让模型以为没有数据。
 *
 * @param total - 列表总条数
 * @param offset - 起始偏移（0 起）
 * @param limit - 本次条数上限
 * @returns 窗口
 */
export function resolveListWindow(total: number, offset: number, limit: number): ListWindow {
  const window: ListWindow = new ListWindow()
  const safeTotal: number = total > 0 ? Math.floor(total) : 0
  window.total = safeTotal
  let start: number = offset > 0 ? Math.floor(offset) : 0
  if (start > safeTotal) {
    start = safeTotal
  }
  const safeLimit: number = limit > 0 ? Math.floor(limit) : 0
  window.start = start
  window.count = Math.min(safeLimit, safeTotal - start)
  window.hasMore = start + window.count < safeTotal
  window.nextOffset = start + window.count
  return window
}

/**
 * 构造列表窗口的续读提示（未读完时给出精确的下一段 offset）。
 *
 * 文案刻意把「总共多少、这次看了哪一段、下一条从哪开始」写全：只写「还有 N 条」
 * 时模型会尝试增大 limit，而 limit 已在上限时它拿不到任何新数据，只能放弃或编造。
 *
 * @param window - 列表窗口
 * @returns 提示文本（已读完且从第 1 条开始时为空串）
 */
export function buildListWindowHint(window: ListWindow): string {
  if (window.count === 0) {
    return '（本次窗口为空：offset=' + window.start.toString() + ' 超出总数 ' +
      window.total.toString() + ' 条）'
  }
  if (window.hasMore) {
    return '（共 ' + window.total.toString() + ' 条，本次显示第 ' +
      (window.start + 1).toString() + '-' + window.nextOffset.toString() + ' 条；还有 ' +
      (window.total - window.nextOffset).toString() + ' 条，传 offset=' +
      window.nextOffset.toString() + ' 继续读）'
  }
  if (window.start > 0) {
    return '（已读到末尾：共 ' + window.total.toString() + ' 条，本次显示第 ' +
      (window.start + 1).toString() + '-' + window.nextOffset.toString() + ' 条）'
  }
  return ''
}

/**
 * 解析工具参数 JSON。
 *
 * @param argumentsText - 模型生成的参数
 * @returns 参数字典（解析失败时为空字典）
 */
export function parseToolArguments(argumentsText: string): Record<string, Object> {
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
 * 读取字符串参数。
 *
 * 数字类型也接受并转成字符串，模型有时会把 tid 写成数字。
 *
 * @param args - 参数字典
 * @param key - 字段名
 * @returns 字符串值（缺失为空串）
 */
export function readStringArg(args: Record<string, Object>, key: string): string {
  const value: Object | undefined = args[key]
  if (typeof value === 'string') {
    return (value as string).trim()
  }
  if (typeof value === 'number') {
    return (value as number).toString()
  }
  return ''
}

/**
 * 读取整数参数（含范围裁剪）。
 *
 * @param args - 参数字典
 * @param key - 字段名
 * @param fallback - 缺失时的默认值
 * @param min - 最小值
 * @param max - 最大值
 * @returns 裁剪后的整数
 */
export function readIntArg(args: Record<string, Object>, key: string, fallback: number,
  min: number, max: number): number {
  const value: Object | undefined = args[key]
  let parsed: number = NaN
  if (typeof value === 'number') {
    parsed = value as number
  } else if (typeof value === 'string') {
    parsed = Number(value as string)
  }
  if (isNaN(parsed)) {
    return fallback
  }
  return Math.max(min, Math.min(max, Math.round(parsed)))
}

/**
 * 按字符数截断文本，并标记是否截断。
 *
 * @param text - 原文
 * @param maxChars - 上限
 * @returns 截断结果
 */
export function truncateText(text: string, maxChars: number): TruncatedText {
  const result: TruncatedText = new TruncatedText()
  const limit: number = Math.max(200, Math.min(MAX_MAX_CHARS, maxChars))
  if (text.length <= limit) {
    result.text = text
    return result
  }
  result.text = text.substring(0, limit)
  result.truncated = true
  return result
}

/**
 * 把 NGA 的 BBCode 正文转成纯文本。
 *
 * @param content - BBCode 原文
 * @returns 纯文本
 */
export function bbcodeToText(content: string): string {
  if (content.length === 0) {
    return ''
  }
  try {
    return bbNodesToPlainText(getCachedBBNodes(content))
  } catch (e) {
    return content
  }
}

/**
 * 格式化时间戳（与服务端展示一致的 CST 文本）。
 *
 * @param timestamp - 秒级时间戳
 * @returns 文本，0 时返回空串
 */
export function formatToolTime(timestamp: number): string {
  if (timestamp <= 0) {
    return ''
  }
  return formatTimestampCST(timestamp)
}

/**
 * 毫秒时间戳转 `formatToolTime` 需要的秒级值。
 *
 * 数据源的单位并不统一（本地台账多是毫秒、服务端字段多是秒），转换只在这里做，
 * 调用点不要自己再除一次 1000。集中成一个导出函数也是为了能被单测钉住。
 *
 * @param ms - 毫秒时间戳
 * @returns 秒级时间戳；非法/非正值返回 0
 */
export function toSeconds(ms: number): number {
  if (!Number.isFinite(ms) || ms <= 0) {
    return 0
  }
  return Math.floor(ms / 1000)
}

/**
 * 读取可能缺失的字符串字段。
 *
 * 本地持久化数据（浏览记录 / 离线存档）可能来自旧格式或外部导入文件，
 * 字段缺失是**预期输入**而不是程序错误；直接访问 `.length` 会抛异常并终止整轮 Agent。
 *
 * 数字也接受并转成字符串：旧版本把 `tid` / `authorid` 存成数字的情况真实存在，
 * 只做 `undefined` 判断会让 `tid` 的比较与拼接落到数字语义上（`123 === '123'` 为 false），
 * 表现为「明明看过却查不到」。
 *
 * @param value - 原始字段值（运行时可能为 undefined）
 * @returns 字符串；缺失时为空串
 */
export function pickText(value: string | number | undefined): string {
  if (value === undefined || value === null) {
    return ''
  }
  return typeof value === 'number' ? String(value) : value
}

/**
 * 读取可能缺失的数字字段。
 *
 * 字符串数字同样接受（外部导入的存档 / 旧格式），非法值回退到 `fallback`。
 *
 * @param value - 原始字段值（运行时可能为 undefined）
 * @param fallback - 缺失或非法时的回退值
 * @returns 数字
 */
export function pickNumber(value: number | string | undefined, fallback: number): number {
  if (value === undefined || value === null) {
    return fallback
  }
  if (typeof value === 'number') {
    return Number.isFinite(value) ? value : fallback
  }
  const parsed: number = Number(value)
  return Number.isFinite(parsed) ? parsed : fallback
}

/**
 * 服务端对「超过时限」主题返回的占位文案。
 *
 * 出现在用户发帖/回帖列表（`app_api.php user/subjects|replys`）的深层条目上：
 * 占位条目的 `tid` 是**列表序号**（不是真实 tid）、`postdate` 为空串、正文为空，
 * 拿它去读帖必然失败。判断只能靠这条固定文案（实测文案不带前后缀，但保留包含匹配）。
 */
const PLACEHOLDER_SUBJECT_TEXT: string = '帖子发布或回复时间超过限制'

/**
 * 受权限限制的占位文案（与上面一类，都是"条目存在但不可读"）。
 */
const PERMISSION_DENIED_TEXT: string = '帐号权限不足'

/**
 * 判断一条主题列表条目的标题是否是不可读条目（超时限 / 权限不足）。
 *
 * 口径与既有消费方 `UserApi.getUserActivityAnalysis` 一致：两者都按文案过滤，
 * 因为这类条目的 tid 不可用（超时限是列表序号，权限不足读不到内容）。
 *
 * @param subject - 条目标题
 * @returns true 表示占位/不可读条目
 */
export function isPlaceholderSubject(subject: string): boolean {
  if (subject.length === 0) {
    return false
  }
  return subject.indexOf(PLACEHOLDER_SUBJECT_TEXT) >= 0 ||
    subject.indexOf(PERMISSION_DENIED_TEXT) >= 0
}

/**
 * 构造「未登录」失败结果。
 *
 * @returns 失败结果
 */
export function loginRequiredResult(): AiToolResult {
  const result: AiToolResult = new AiToolResult()
  result.success = false
  result.errorCode = TOOL_ERROR_LOGIN_REQUIRED
  result.errorMessage = '未登录'
  result.content = '无法读取 NGA 数据：当前未登录。请提示用户先登录后重试，不要臆测内容。'
  return result
}

/**
 * 构造失败结果。
 *
 * @param message - 给模型看的失败原因
 * @param code - 失败分类（TOOL_ERROR_*），缺省按上游接口失败处理
 * @returns 失败结果
 */
export function failedResult(message: string, code: string = ''): AiToolResult {
  const result: AiToolResult = new AiToolResult()
  result.success = false
  result.errorCode = code
  result.errorMessage = message
  result.content = '工具执行失败：' + message
  return result
}

/**
 * 构造「拿不到当前账号 UID」的失败结果。
 *
 * 工具可用性只要求「已登录 + 有令牌」，理论上仍可能出现 uid 缺失；
 * 此时直接说「未登录」会与用户看到的登录状态矛盾，统一用本结果。
 *
 * @returns 失败结果
 */
export function missingSelfUidResult(): AiToolResult {
  return failedResult('拿不到当前登录账号的 UID，请提示用户重新登录后再试', TOOL_ERROR_LOGIN_REQUIRED)
}

/**
 * 判断当前上下文是否可以访问 NGA（已登录 + 有令牌）。
 *
 * @param context - 工具执行上下文
 * @returns true 表示已登录
 */
export function isNgaReady(context: AiToolContext): boolean {
  return context.authenticated && context.token.length > 0
}

/**
 * 构造帖子卡片。
 *
 * @param tid - 帖子 ID
 * @param title - 标题
 * @param subtitle - 副标题
 * @returns 卡片
 */
export function topicCard(tid: string, title: string, subtitle: string): AiToolCard {
  const card: AiToolCard = new AiToolCard()
  card.kind = 'topic'
  card.title = title
  card.subtitle = subtitle
  card.route = 'thread'
  const params: Record<string, string> = {}
  params['tid'] = tid
  card.params = JSON.stringify(params)
  return card
}

/**
 * 构造版块卡片。
 *
 * @param fid - 版块 ID
 * @param name - 版块名
 * @param subtitle - 副标题
 * @returns 卡片
 */
export function forumCard(fid: string, name: string, subtitle: string): AiToolCard {
  const card: AiToolCard = new AiToolCard()
  card.kind = 'forum'
  card.title = name
  card.subtitle = subtitle
  card.route = 'topicList'
  const params: Record<string, string> = {}
  params['fid'] = fid
  params['name'] = name
  card.params = JSON.stringify(params)
  return card
}

/**
 * 构造用户卡片。
 *
 * @param uid - 用户 ID
 * @param name - 用户名
 * @param subtitle - 副标题
 * @returns 卡片
 */
export function userCard(uid: string, name: string, subtitle: string): AiToolCard {
  const card: AiToolCard = new AiToolCard()
  card.kind = 'user'
  card.title = name
  card.subtitle = subtitle
  card.route = 'profile'
  const params: Record<string, string> = {}
  params['uid'] = uid
  card.params = JSON.stringify(params)
  return card
}

/**
 * 构造工具参数 Schema 的公共辅助：一个 object 类型的参数集合。
 *
 * @param properties - 属性表
 * @param required - 必填字段
 * @returns parameters 对象
 */
export function buildToolParameters(properties: Record<string, Object>,
  required: string[]): Record<string, Object> {
  const parameters: Record<string, Object> = {}
  parameters['type'] = 'object'
  parameters['properties'] = properties
  parameters['required'] = required
  parameters['additionalProperties'] = false
  return parameters
}

/**
 * 构造一个字符串类型的参数描述。
 *
 * @param description - 说明
 * @returns 属性描述
 */
export function stringProperty(description: string): Record<string, Object> {
  const prop: Record<string, Object> = {}
  prop['type'] = 'string'
  prop['description'] = description
  return prop
}

/**
 * 构造一个整数类型的参数描述。
 *
 * @param description - 说明
 * @returns 属性描述
 */
export function intProperty(description: string): Record<string, Object> {
  const prop: Record<string, Object> = {}
  prop['type'] = 'integer'
  prop['description'] = description
  return prop
}

/**
 * 构造一个布尔类型的参数描述。
 *
 * @param description - 说明
 * @returns 属性描述
 */
export function boolProperty(description: string): Record<string, Object> {
  const prop: Record<string, Object> = {}
  prop['type'] = 'boolean'
  prop['description'] = description
  return prop
}

/**
 * 构造一个带枚举约束的字符串参数描述。
 *
 * @param description - 说明
 * @param values - 允许的取值
 * @returns 属性描述
 */
export function enumProperty(description: string, values: string[]): Record<string, Object> {
  const prop: Record<string, Object> = {}
  prop['type'] = 'string'
  prop['description'] = description
  const options: Object[] = []
  for (let i: number = 0; i < values.length; i++) {
    options.push(values[i])
  }
  prop['enum'] = options
  return prop
}

/**
 * 读取布尔参数（兼容模型把 true 写成 "true" / 1 的情况）。
 *
 * @param args - 参数字典
 * @param key - 字段名
 * @param fallback - 缺失时的默认值
 * @returns 布尔值
 */
export function readBoolArg(args: Record<string, Object>, key: string, fallback: boolean): boolean {
  const value: Object | undefined = args[key]
  if (typeof value === 'boolean') {
    return value as boolean
  }
  if (typeof value === 'string') {
    const text: string = (value as string).trim().toLowerCase()
    if (text === 'true' || text === '1' || text === 'yes') {
      return true
    }
    if (text === 'false' || text === '0' || text === 'no') {
      return false
    }
  }
  if (typeof value === 'number') {
    return (value as number) !== 0
  }
  return fallback
}

/**
 * 解析"要查谁"的 UID。
 *
 * 优先级：显式 uid 参数 → 当前页面用户 → 当前登录用户。
 * 这样从任何入口都能问"看看我自己"，不需要用户先报 UID。
 *
 * @param context - 工具执行上下文
 * @param args - 参数字典
 * @returns UID，无法确定时为空串
 */
export function resolveTargetUid(context: AiToolContext, args: Record<string, Object>): string {
  const explicit: string = readStringArg(args, 'uid')
  if (explicit.length > 0) {
    return explicit
  }
  const fromPage: string = context.taskContext.uid
  if (fromPage.length > 0) {
    return fromPage
  }
  return context.selfUid
}

/**
 * 构造「不知道查谁」的失败结果，并给出可执行的下一步。
 *
 * @returns 失败结果
 */
export function missingUserResult(): AiToolResult {
  const result: AiToolResult = new AiToolResult()
  result.success = false
  result.errorCode = TOOL_ERROR_BAD_ARGS
  result.errorMessage = '缺少用户标识'
  result.content = '缺少用户标识。可以：\n' +
    '1. 传 uid；\n' +
    '2. 传 username（我会先搜索再解析）；\n' +
    '3. 不传参数，默认读取当前登录账号；\n' +
    '4. 或者先用 nga_search_user 搜索用户名。'
  return result
}
