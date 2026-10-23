/**
 * 续读工具结果（expand_tool_result）。
 *
 * ## 用途
 *
 * 当一条工具结果超出本轮上下文预算时，`AiAgentRunner` 不会把它丢掉，而是：
 * 1. 完整内容写进 `ToolResultArchive`；
 * 2. 上下文里只放「头部 + result_id + 总字符数」；
 * 3. 模型需要后半段时调用本工具按偏移读取。
 *
 * 这是「大结果外置 + 按需检索」的最小实现，参考 Claude Code 把长输出落到文件、
 * 再让模型用 Read/Grep 按需取用；也对应 OpenHands 的 observation 外置。
 *
 * ## 与分页工具的关系
 *
 * 分页（`page` 参数）解决的是「还没读到的页」，本工具解决的是「已经读到、
 * 但因上下文预算只展示了一部分」的内容。两者互补，不能互相替代。
 */

import { AiToolDefinition } from '../AiProtocolTypes'
import { AiToolAdapter, AiToolContext, AiToolResult, TOOL_ERROR_BAD_ARGS } from './AiToolAdapter'
import { isAiToolEnabled } from '../../../model/AiToolConfig'
import {
  ARCHIVE_DEFAULT_READ_CHARS,
  ARCHIVE_MAX_READ_CHARS,
  ToolArchiveSlice
} from './ToolResultArchive'

/** 工具名称。 */
const TOOL_NAME: string = 'expand_tool_result'

/** 参数名：结果 ID。 */
const ARG_RESULT_ID: string = 'result_id'
/** 参数名：起始偏移。 */
const ARG_OFFSET: string = 'offset'
/** 参数名：本次读取字符数。 */
const ARG_LIMIT: string = 'limit'

/**
 * 续读工具。
 */
export class ExpandToolResultTool implements AiToolAdapter {
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
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_NAME
    definition.description =
      '续读一条因上下文预算被截断的工具结果。' +
        '只有当工具返回内容里出现「result_id=...」时才有内容可读；' +
        'result_id 与总数会随那条结果一起给出。按 offset/limit 分段读取，不要一次读太多。'
    const properties: Record<string, Object> = {}
    properties[ARG_RESULT_ID] = stringProperty('结果 ID（工具返回中的 result_id，形如 res_3_xxx）')
    properties[ARG_OFFSET] = intProperty('起始字符偏移，从 0 开始；首次续读用返回里的 next_offset')
    properties[ARG_LIMIT] = intProperty('本次读取的字符数，200-16000，默认 ' +
      ARCHIVE_DEFAULT_READ_CHARS.toString())
    const required: string[] = [ARG_RESULT_ID]
    definition.parameters = buildParameters(properties, required)
    return definition
  }

  /**
   * 判断工具是否可用。
   *
   * 零网络请求、只读本次运行的内存归档，因此不受登录态与任务白名单限制，
   * 只受全局开关约束（用户明确关掉就不再提供）。
   *
   * @param context - 工具执行上下文
   * @returns true 表示可用
   */
  isAvailable(context: AiToolContext): boolean {
    /*
     * 刻意不判断 `archive.size() > 0`：工具声明必须在一次运行的**所有轮次里保持稳定**，
     * 否则 tools 数组逐轮变化会让服务商的前缀缓存从 tools 段就开始失效；
     * 而且模型是先看到截断结果、下一轮才调用本工具，声明消失会直接断掉续读路径。
     */
    return isAiToolEnabled(context.tools, TOOL_NAME)
  }

  /**
   * 执行续读。
   *
   * @param argumentsText - 参数 JSON
   * @param context - 工具执行上下文
   * @param fallbackQuery - 兜底查询（不使用）
   * @returns 工具结果
   */
  async execute(argumentsText: string, context: AiToolContext,
    fallbackQuery: string): Promise<AiToolResult> {
    const args: Record<string, Object> = parseArguments(argumentsText)
    const id: string = readString(args, ARG_RESULT_ID).trim()
    if (id.length === 0) {
      return failedResult('缺少 result_id：请使用工具返回里给出的 result_id，' +
        '形如 res_3_k2j4。没有 result_id 说明该结果没有被截断，不需要续读。')
    }
    const offset: number = readInt(args, ARG_OFFSET, 0, 0, 100000000)
    const limit: number = readInt(args, ARG_LIMIT, ARCHIVE_DEFAULT_READ_CHARS,
      200, ARCHIVE_MAX_READ_CHARS)
    const slice: ToolArchiveSlice | null = context.archive.read(id, offset, limit)
    if (slice === null) {
      return failedResult('result_id=' + id + ' 已不存在（归档按容量淘汰，或本次运行已结束）。' +
        '请重新调用产生该结果的工具；客户端有结果缓存，通常不会重复请求。')
    }

    const result: AiToolResult = new AiToolResult()
    result.success = true
    result.summary = '续读 ' + id
    result.content = buildContent(slice, limit)
    return result
  }
}

/**
 * 生成续读结果正文。
 *
 * @param slice - 切片
 * @param limit - 本次请求的字符数上限
 * @returns 正文
 */
function buildContent(slice: ToolArchiveSlice, limit: number): string {
  const parts: string[] = []
  parts.push('【续读结果 ' + slice.id + '】字符 ' + slice.offset.toString() + '–' +
    slice.nextOffset.toString() + ' / ' + slice.totalChars.toString())
  parts.push(slice.text)
  if (slice.hasMore) {
    const remaining: number = slice.totalChars - slice.nextOffset
    parts.push('\n（还有 ' + remaining.toString() + ' 字符未读。继续读取时调用 ' +
      'expand_tool_result(result_id="' + slice.id + '", offset=' +
      slice.nextOffset.toString() + ', limit=' + limit.toString() + ')。' +
      '如果已经拿到回答所需的内容，就不要继续读。）')
  } else {
    parts.push('\n（已读到该结果的末尾。）')
  }
  return parts.join('\n')
}

/**
 * 判断参数是否为 JSON 对象。
 *
 * @param text - 参数文本
 * @returns 解析结果（非法时返回空对象）
 */
function parseArguments(text: string): Record<string, Object> {
  const trimmed: string = text.trim()
  if (trimmed.length === 0) {
    return {}
  }
  try {
    const parsed: Object = JSON.parse(trimmed) as Object
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
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
 * @param args - 参数对象
 * @param key - 参数名
 * @returns 字符串（缺失/类型不符时为空串）
 */
function readString(args: Record<string, Object>, key: string): string {
  const value: Object | undefined = args[key]
  return typeof value === 'string' ? value as string : ''
}

/**
 * 读取整数参数并夹到区间。
 *
 * @param args - 参数对象
 * @param key - 参数名
 * @param fallback - 缺省值
 * @param min - 下限
 * @param max - 上限
 * @returns 整数
 */
function readInt(args: Record<string, Object>, key: string, fallback: number,
  min: number, max: number): number {
  const raw: Object | undefined = args[key]
  let value: number = fallback
  if (typeof raw === 'number') {
    value = raw as number
  } else if (typeof raw === 'string') {
    const parsed: number = Number(raw as string)
    if (!isNaN(parsed)) {
      value = parsed
    }
  }
  if (!isFinite(value)) {
    value = fallback
  }
  const rounded: number = Math.floor(value)
  if (rounded < min) {
    return min
  }
  if (rounded > max) {
    return max
  }
  return rounded
}

/**
 * 构造字符串参数 Schema。
 *
 * @param description - 说明
 * @returns 属性对象
 */
function stringProperty(description: string): Record<string, Object> {
  const property: Record<string, Object> = {}
  property['type'] = 'string'
  property['description'] = description
  return property
}

/**
 * 构造整数参数 Schema。
 *
 * @param description - 说明
 * @returns 属性对象
 */
function intProperty(description: string): Record<string, Object> {
  const property: Record<string, Object> = {}
  property['type'] = 'integer'
  property['description'] = description
  return property
}

/**
 * 构造 object 参数 Schema。
 *
 * @param properties - 属性表
 * @param required - 必填字段
 * @returns parameters 对象
 */
function buildParameters(properties: Record<string, Object>,
  required: string[]): Record<string, Object> {
  const parameters: Record<string, Object> = {}
  parameters['type'] = 'object'
  parameters['properties'] = properties
  parameters['required'] = required
  parameters['additionalProperties'] = false
  return parameters
}

/**
 * 构造参数错误结果。
 *
 * @param message - 给模型看的说明
 * @returns 失败结果
 */
function failedResult(message: string): AiToolResult {
  const result: AiToolResult = new AiToolResult()
  result.success = false
  result.errorCode = TOOL_ERROR_BAD_ARGS
  result.errorMessage = message
  result.content = message
  return result
}
