/**
 * 「智能去水」的 AI 规则生成 —— 按帖子主题推断这个帖子特有的灌水表达。
 *
 * ## 为什么要 AI 参与
 *
 * 内置词表与用户自定义规则都是**字符匹配**：前者只覆盖全站通用的灌水词
 * （mark / 插眼），后者要用户自己想出关键词。而每个帖子有自己的"水法"——
 * 追更帖里满屏「催更」，资源帖里满屏「求个网盘」，攻略帖里满屏「学到了」。
 * 这些词靠固定词表覆盖不到，靠用户手写又要求他先读完整帖，让模型看一眼标题
 * 与主楼就能列出来。
 *
 * ## 与自定义规则的关系
 *
 * AI 规则**只用于本次去水，不写入用户的持久化自定义规则**：规则是按这一帖的
 * 主题生成的，存成全局规则会在别的帖子上乱删（比如把「催更」加进全局规则，
 * 在小说帖里合理、在技术帖里就成了误伤）。这一点必须在 UI 上如实告诉用户。
 *
 * ## 单一调用路径
 *
 * 复用既有的 `chatCompleteWithActiveAiStream`（唯一 AI 调用通道），只是不展示
 * 流式增量、等最终文本一次解析。**不得**为它另开一条 HTTP 调用路径。
 *
 * ## AI 输出是不可信输入
 *
 * 模型可能返回 markdown 代码块、多余解释、非法类型、单字关键词（`图`/`求`
 * 这类单字 contain 规则会命中大量正经回复）。因此解析必须是**防御性**的：
 * 定位 JSON 子串、逐条校验、剥空白、拒单字 contain、去重、限条数，
 * 任何一条不合格就丢掉那一条而不是整体失败。
 */

import { appStore } from '../store/AppStore'
import { AiScenario } from '../model/AiScenarioConfig'
import { WaterFilterRule, WaterRuleType, isWaterRuleType, validateWaterRule } from '../model/WaterFilterRule'
import { compactText } from './WaterFilterEngine'
import {
  chatCompleteWithActiveAiStream,
  getActiveAiValidationMessage,
  AiChatResult
} from './ai/ActiveAiService'
import { ChatMessage, RequestCanceller } from './ai/ResponsesApiClient'
import { Logger, DOMAIN_SERVICE, formatError } from '../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'WaterFilterAiRules')

/** AI 规则条数上限（提示词里同样约束，这里是第二道防线）。 */
export const MAX_AI_RULES: number = 12

/** 注入主楼正文的字符上限（只看主题太薄，看整楼又浪费额度与上下文）。 */
const MAX_OP_TEXT_CHARS: number = 1200

/**
 * `contain` 规则的最短长度。
 *
 * 单字 contain 是**破坏性**的：`图` 会命中「这张图的参数写反了」，`求` 会命中
 * 「求问这个怎么解决」。即使模型给了，也要丢掉。
 */
const MIN_CONTAINS_LENGTH: number = 2

/** AI 规则生成结果。 */
export class WaterFilterAiRulesResult {
  /** 是否成功拿到可用的规则列表（`rules` 为空也算成功）。 */
  ok: boolean = false
  /** 是否被取消。 */
  cancelled: boolean = false
  /** 失败/说明文案（成功且有条数时为「已生成 N 条」）。 */
  message: string = ''
  /** 解析出的规则（已逐条校验）。 */
  rules: WaterFilterRule[] = []
}

/**
 * 组装注入给模型的用户消息。
 *
 * 主楼正文截断到 {@link MAX_OP_TEXT_CHARS}：够模型判断帖子类型（攻略 / 资源 /
 * 追更 / 闲聊），又不会把上下文撑满。
 *
 * @param subject - 帖子标题
 * @param opText - 主楼正文纯文本（可为空）
 * @returns 用户消息文本
 */
export function buildWaterRuleUserPrompt(subject: string, opText: string): string {
  const title: string = subject.trim().length > 0 ? subject.trim() : '（标题未知）'
  const body: string = opText.trim()
  if (body.length === 0) {
    return '帖子标题：' + title + '\n\n（主楼正文未取到，请仅根据标题推断。）\n\n请按系统提示的格式输出 JSON。'
  }
  const clipped: string = body.length > MAX_OP_TEXT_CHARS
    ? body.substring(0, MAX_OP_TEXT_CHARS) + '…（后续内容已省略）'
    : body
  return '帖子标题：' + title + '\n\n主楼正文：\n' + clipped + '\n\n请按系统提示的格式输出 JSON。'
}

/**
 * 从模型回复里截出 JSON 子串。
 *
 * 模型常见违规是裹一层 ```json 代码块或前后加解释。定位第一个 `{` 到最后一个 `}`
 * 是关键：用固定前缀匹配（如找 ```json）会在模型直接输出裸 JSON 时失败。
 *
 * @param raw - 模型回复全文
 * @returns JSON 子串；找不到花括号时返回空串
 */
function extractJsonObject(raw: string): string {
  const start: number = raw.indexOf('{')
  const end: number = raw.lastIndexOf('}')
  if (start < 0 || end <= start) {
    return ''
  }
  return raw.substring(start, end + 1)
}

/**
 * 读取字符串字段（缺失/非字符串时返回空串）。
 *
 * @param source - 源对象
 * @param key - 字段名
 * @returns 字段值
 */
function readString(source: Record<string, Object>, key: string): string {
  const value: Object | undefined = source[key]
  if (value === undefined || value === null) {
    return ''
  }
  return typeof value === 'string' ? value : String(value)
}

/**
 * 把一条候选规则规整为可用的 {@link WaterFilterRule}；不可用则返回 null。
 *
 * @param rawType - 模型给出的 type
 * @param rawValue - 模型给出的 value
 * @returns 规则；不合格时返回 null
 */
function normalizeRule(rawType: string, rawValue: string): WaterFilterRule | null {
  const type: string = rawType.trim().toLowerCase()
  if (!isWaterRuleType(type)) {
    return null
  }
  // contain/equals 的关键词先去掉空白：判定时比对的是紧凑文本，带空格的规则永远匹配不上
  const value: string = type === WaterRuleType.MAX_LENGTH
    ? rawValue.trim()
    : compactText(rawValue.trim().replace(/^["'「『]+/, '').replace(/["'」』]+$/, ''))
  if (validateWaterRule(type, value).length > 0) {
    return null
  }
  if (type === WaterRuleType.CONTAINS && value.length < MIN_CONTAINS_LENGTH) {
    return null
  }
  const rule: WaterFilterRule = new WaterFilterRule()
  rule.enabled = true
  rule.type = type
  rule.value = value
  return rule
}

/**
 * 解析模型回复为规则列表（纯函数，便于单测）。
 *
 * 逐条防御：类型非法、值非法、单字 contain、重复项一律丢弃；任何一条坏数据都不
 * 影响其余条目。**不抛异常**——AI 输出不可信，解析失败按「没拿到规则」处理。
 *
 * @param raw - 模型回复全文
 * @returns 规则列表（保持模型给出的顺序，已去重并限条数）
 */
export function parseWaterRules(raw: string): WaterFilterRule[] {
  const json: string = extractJsonObject(raw)
  if (json.length === 0) {
    return []
  }
  let parsed: Record<string, Object> | null = null
  try {
    parsed = JSON.parse(json) as Record<string, Object>
  } catch (e) {
    logger.warn('ai water rules json parse failed: %{public}s', formatError(e))
    return []
  }
  if (parsed === null) {
    return []
  }
  const rawRules: Object | undefined = parsed['rules']
  if (rawRules === undefined || rawRules === null || !Array.isArray(rawRules)) {
    return []
  }
  const items: Object[] = rawRules as Object[]
  const rules: WaterFilterRule[] = []
  const seen: Set<string> = new Set<string>()
  for (let i: number = 0; i < items.length; i++) {
    if (rules.length >= MAX_AI_RULES) {
      break
    }
    const item: Object | undefined = items[i]
    if (item === undefined || item === null || typeof item !== 'object') {
      continue
    }
    const entry: Record<string, Object> = item as Record<string, Object>
    const rule: WaterFilterRule | null = normalizeRule(readString(entry, 'type'), readString(entry, 'value'))
    if (rule === null) {
      continue
    }
    const key: string = rule.type + ':' + rule.value.toLowerCase()
    if (seen.has(key)) {
      continue
    }
    seen.add(key)
    rule.id = 'ai' + String(i)
    rules.push(rule)
  }
  return rules
}

/**
 * 按帖子主题生成去水规则。
 *
 * @param subject - 帖子标题
 * @param opText - 主楼正文纯文本（可为空）
 * @param canceller - 取消令牌（对话框关闭时调用 cancel()）
 * @returns 生成结果
 */
export async function generateWaterRules(subject: string, opText: string,
  canceller: RequestCanceller): Promise<WaterFilterAiRulesResult> {
  const result: WaterFilterAiRulesResult = new WaterFilterAiRulesResult()
  // 与其它 AI 场景同一套配置门禁（未配置 / 未选择 / 缺密钥 / 缺模型名）
  const validationMessage: string = getActiveAiValidationMessage()
  if (validationMessage.length > 0) {
    result.message = validationMessage
    return result
  }
  const systemPrompt: string = appStore.settingsStore.getScenarioPrompt(AiScenario.WATER_RULE_GEN)
  if (systemPrompt.trim().length === 0) {
    result.message = '去水规则生成的 Prompt 为空，请在 AI 配置中检查'
    return result
  }
  const messages: ChatMessage[] = [
    new ChatMessage('system', systemPrompt),
    new ChatMessage('user', buildWaterRuleUserPrompt(subject, opText))
  ]
  try {
    // 不展示流式增量：这是一次性取结果，交给解析器即可
    const chatResult: AiChatResult = await chatCompleteWithActiveAiStream(
      messages,
      (_chunk: string): void => {},
      undefined,
      undefined,
      canceller
    )
    if (canceller.isCancelled()) {
      result.cancelled = true
      result.message = '已取消生成'
      return result
    }
    const rules: WaterFilterRule[] = parseWaterRules(chatResult.text)
    result.ok = true
    result.rules = rules
    result.message = rules.length > 0
      ? 'AI 生成了 ' + String(rules.length) + ' 条规则'
      : 'AI 认为这个帖子没有需要额外过滤的表达'
    logger.info('ai water rules done subject=%{public}s rules=%{public}d',
      subject, rules.length)
    return result
  } catch (e) {
    const error: Error = e as Error
    logger.warn('ai water rules failed: %{public}s', formatError(error))
    result.message = '规则生成失败：' + error.message
    return result
  }
}
