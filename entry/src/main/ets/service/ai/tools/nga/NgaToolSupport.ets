/**
 * NGA 站内工具的公共支撑。
 *
 * 这一层只做「把 NGA 的模型对象压成模型可读文本 + 可点击卡片」，
 * 不包含任何具体业务逻辑；每个工具各自负责取数与裁剪。
 */

import { AiToolCard, AiToolContext, AiToolResult } from '../AiToolAdapter'
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

/** 截断结果。 */
export class TruncatedText {
  /** 截断后的文本 */
  text: string = ''
  /** 是否发生截断 */
  truncated: boolean = false
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
 * 构造「未登录」失败结果。
 *
 * @returns 失败结果
 */
export function loginRequiredResult(): AiToolResult {
  const result: AiToolResult = new AiToolResult()
  result.success = false
  result.errorMessage = '未登录'
  result.content = '无法读取 NGA 数据：当前未登录。请提示用户先登录后重试，不要臆测内容。'
  return result
}

/**
 * 构造失败结果。
 *
 * @param message - 给模型看的失败原因
 * @returns 失败结果
 */
export function failedResult(message: string): AiToolResult {
  const result: AiToolResult = new AiToolResult()
  result.success = false
  result.errorMessage = message
  result.content = '工具执行失败：' + message
  return result
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
  result.errorMessage = '缺少用户标识'
  result.content = '缺少用户标识。可以：\n' +
    '1. 传 uid；\n' +
    '2. 传 username（我会先搜索再解析）；\n' +
    '3. 不传参数，默认读取当前登录账号；\n' +
    '4. 或者先用 nga_search_user 搜索用户名。'
  return result
}
