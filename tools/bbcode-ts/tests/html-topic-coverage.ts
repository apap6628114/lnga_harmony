import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { parseHtmlTopicListToRawJson } from '../src/parser/nga/html-topiclist/index'
import { preprocessJson } from '../src/parser/NgaJsonSanitizer'

/**
 * HTML 主题列表 → JSON 覆盖验证引擎（JSON 为基准，HTML 为被测对象）。
 *
 * 供 tests/html-topic-coverage.test.ts（断言）使用。
 *
 * 数据来源约定（scripts/fetch-topic-pair.mjs 产出，或手工固化）：
 * - samples/html-topicpairs.lst：每行一个基准名（如 html-topicpair-u205511-p1）
 * - samples/html-topicpair-<name>.json：JSON API 响应（thread.php?lite=js，净化后）
 * - samples/html-topicpair-<name>.html：thread.php 原始 HTML（GBK 已解码）
 *
 * 对比维度：
 * - 条目集合：JSON __T 每索引键在 HTML 输出中是否有对应
 * - 条目字段：tid/fid/subject/author/authorid/postdate/lastpost/replies/lastposter/
 *   type/topic_misc/quote_from/parent 逐字段相等性（JSON 与 HTML 同源于 topicArg 数据）
 * - 回帖正文 __P：pid>0 时 __P.tid/__P.pid/__P.authorid/__P.subject 严格一致；
 *   __P.content 文本覆盖率 ≥90%（JSON 可见文字在 HTML 正文中的保留度）
 *
 * 已知缺口（samples/html-topicpair-gaps.json 声明字段级豁免）：
 * - __P.postdate：静态页面无回复时间（官方网页版亦不显示），保持空值不伪造
 * - 占位条目（subject 含「超过限制/帐号权限不足」）的 tid/fid/__P.tid/__P.pid/__P.type
 *   为服务端占位符（HTML 与 JSON 各给一套假值），自动豁免；
 *   __P.type 对真实条目可从 postDispMini 第 7 参恢复，与 JSON 一致
 */

/** 成对样本目录。 */
const SAMPLES_DIR: string = join(process.cwd(), 'samples')

/** 样本清单文件。 */
const LIST_FILE: string = join(SAMPLES_DIR, 'html-topicpairs.lst')

/** 断言严格的条目字段（HTML 与 JSON 同源于 topicArg，必须一致）。 */
const STRICT_FIELDS: string[] = [
  'tid', 'fid', 'subject', 'author', 'authorid', 'postdate', 'lastpost',
  'replies', 'lastposter', 'type', 'topic_misc', 'quote_from',
]

/** __P 中严格一致的基础字段。 */
const STRICT_P_FIELDS: string[] = ['tid', 'pid', 'authorid', 'subject']

/** 回帖正文文本覆盖率阈值（去空白与 <br/> 后的贪心子序列匹配率）。 */
const CONTENT_COVERAGE_THRESHOLD: number = 0.9

/**
 * 读取 html-topicpairs.lst 中的基准名列表。
 *
 * @returns 基准名数组；清单缺失或为空时返回 []
 */
export function loadTopicPairNames(): string[] {
  if (!existsSync(LIST_FILE)) return []
  return readFileSync(LIST_FILE, 'utf8')
    .split('\n')
    .map((line: string) => line.trim())
    .filter((line: string) => line.length > 0 && !line.startsWith('#'))
}

/**
 * 成对样本的原始文本（JSON 响应 + HTML 页面）。
 */
export interface TopicPairData {
  name: string
  jsonText: string
  htmlText: string
}

/**
 * 加载一对样本。
 *
 * @param name 基准名（html-topicpair-<name>）
 * @returns JSON 响应文本与 HTML 页面文本
 */
export function loadTopicPair(name: string): TopicPairData {
  return {
    name,
    jsonText: readFileSync(join(SAMPLES_DIR, `${name}.json`), 'utf8'),
    htmlText: readFileSync(join(SAMPLES_DIR, `${name}.html`), 'utf8'),
  }
}

/**
 * 已知缺口声明（字段级豁免，全局适用所有样本）。
 */
export interface TopicPairGaps {
  note?: string
  /** 全局豁免的字段名（如 __P.postdate / __P.type） */
  fields: string[]
}

const GAPS_FILE: string = join(SAMPLES_DIR, 'html-topicpair-gaps.json')

/**
 * 加载已知缺口声明。
 *
 * @returns 缺口声明；文件缺失或为空时返回 { fields: [] }
 */
export function loadTopicPairGaps(): TopicPairGaps {
  if (!existsSync(GAPS_FILE)) return { fields: [] }
  const parsed: TopicPairGaps = JSON.parse(readFileSync(GAPS_FILE, 'utf8')) as TopicPairGaps
  if (!parsed || !Array.isArray(parsed.fields)) return { fields: [] }
  return parsed
}

/**
 * 单条目逐字段对比报告。
 */
export interface TopicRowReport {
  index: string
  fieldMismatches: Array<{ field: string; jsonValue: string; htmlValue: string }>
  /** __P.content 文本覆盖率（0..1；无 __P 时为 1） */
  contentCoverage: number
  /** JSON 条目是否携带 __P */
  jsonHasP: boolean
  /** 是否为占位条目（subject 含「超过限制/帐号权限不足」） */
  placeholder: boolean
}

/**
 * 成对样本对比报告。
 */
export interface TopicPairReport {
  name: string
  /** JSON 有而 HTML 无的条目索引 */
  missingJsonEntries: string[]
  /** HTML 有而 JSON 无的条目索引 */
  extraHtmlEntries: string[]
  rows: TopicRowReport[]
  jsonRows: number
}

/**
 * 判断条目是否为占位条目（服务端不提供真实数据的「超过限制」等）。
 *
 * 这类条目 tid/fid/__P.tid/__P.pid 是服务端占位符，HTML 与 JSON 各给一套假值，
 * 语义等价但数值不同，断言时豁免。
 *
 * @param entry JSON 条目
 * @returns 是否为占位条目
 */
function isPlaceholderEntry(entry: Record<string, Object>): boolean {
  const subject: string = String(entry['subject'] ?? '')
  return subject.includes('超过限制') || subject.includes('帐号权限不足')
}

/**
 * 判断字段是否需要豁免（占位条目豁免其占位字段，全局豁免 gaps.fields）。
 *
 * @param field 字段名
 * @param placeholder 是否为占位条目
 * @param gaps 已知缺口声明
 * @returns 是否豁免
 */
function isFieldExempt(field: string, placeholder: boolean, gaps: TopicPairGaps): boolean {
  if (gaps.fields.includes(field)) return true
  if (placeholder && (field === 'tid' || field === 'fid' ||
    field === '__P.tid' || field === '__P.pid' || field === '__P.type')) {
    return true
  }
  return false
}

/**
 * 将 __P.content 归一化为可比较文本（去 <br/>、去空白）。
 *
 * @param text 原始正文
 * @returns 归一化文本
 */
function normalizeContent(text: string): string {
  return text.replace(/<br\/?>/gi, '').replace(/\s+/g, '')
}

/**
 * 贪心子序列覆盖率：shortText 的字符在 longText 中按序出现的比例。
 *
 * @param longText 被搜索文本（HTML 侧）
 * @param shortText 基准文本（JSON 侧）
 * @returns 覆盖率 0..1；shortText 为空时返回 1
 */
function subsequenceCoverage(longText: string, shortText: string): number {
  if (shortText.length === 0) return 1
  let li: number = 0
  let si: number = 0
  while (li < longText.length && si < shortText.length) {
    if (longText[li] === shortText[si]) {
      si++
    }
    li++
  }
  return si / shortText.length
}

/**
 * 对比一对样本（JSON 为基准，HTML 为被测对象）。
 *
 * @param data 成对样本
 * @param gaps 已知缺口声明
 * @returns 对比报告
 */
export function analyzeTopicPair(data: TopicPairData, gaps: TopicPairGaps): TopicPairReport {
  const report: TopicPairReport = {
    name: data.name,
    missingJsonEntries: [],
    extraHtmlEntries: [],
    rows: [],
    jsonRows: 0,
  }

  const jsonObj: Object = JSON.parse(preprocessJson(data.jsonText))
  const jsonData: Record<string, Object> = (jsonObj as Record<string, Object>)['data'] as Record<string, Object>
  const jsonT: Record<string, Object> = (jsonData['__T'] ?? {}) as Record<string, Object>

  const htmlObj: Object = parseHtmlTopicListToRawJson(data.htmlText)
  const htmlData: Record<string, Object> = (htmlObj as Record<string, Object>)['data'] as Record<string, Object>
  const htmlT: Record<string, Object> = (htmlData['__T'] ?? {}) as Record<string, Object>

  const jsonKeys: string[] = Object.keys(jsonT)
  const htmlKeys: string[] = Object.keys(htmlT)
  report.jsonRows = jsonKeys.length

  for (const key of jsonKeys) {
    const jsonEntry: Record<string, Object> = jsonT[key] as Record<string, Object>
    const htmlEntry: Record<string, Object> | undefined = htmlT[key] as Record<string, Object> | undefined
    if (!htmlEntry) {
      report.missingJsonEntries.push(key)
      continue
    }
    const placeholder: boolean = isPlaceholderEntry(jsonEntry)
    const row: TopicRowReport = {
      index: key,
      fieldMismatches: [],
      contentCoverage: 1,
      jsonHasP: jsonEntry['__P'] !== undefined,
      placeholder,
    }

    for (const field of STRICT_FIELDS) {
      const jsonValue: string = String(jsonEntry[field] ?? '')
      const htmlValue: string = String(htmlEntry[field] ?? '')
      if (jsonValue !== htmlValue && !isFieldExempt(field, placeholder, gaps)) {
        row.fieldMismatches.push({ field, jsonValue, htmlValue })
      }
    }
    // parent：JSON 与 HTML 的序列化形状必须一致（对象键序无关，JSON.stringify 保序，
    // 但条目组装顺序一致，直接字符串化比较即可）
    const jsonParent: string = JSON.stringify(jsonEntry['parent'] ?? '')
    const htmlParent: string = JSON.stringify(htmlEntry['parent'] ?? '')
    if (jsonParent !== htmlParent) {
      row.fieldMismatches.push({ field: 'parent', jsonValue: jsonParent, htmlValue: htmlParent })
    }

    const jsonP: Record<string, Object> | undefined = jsonEntry['__P'] as Record<string, Object> | undefined
    const htmlP: Record<string, Object> | undefined = htmlEntry['__P'] as Record<string, Object> | undefined
    if (jsonP) {
      for (const field of STRICT_P_FIELDS) {
        const jsonValue: string = String(jsonP[field] ?? '')
        const htmlValue: string = String(htmlP?.[field] ?? '')
        if (jsonValue !== htmlValue && !isFieldExempt(`__P.${field}`, placeholder, gaps)) {
          row.fieldMismatches.push({ field: `__P.${field}`, jsonValue, htmlValue })
        }
      }
      const jsonContent: string = String(jsonP['content'] ?? '')
      const htmlContent: string = String(htmlP?.['content'] ?? '')
      row.contentCoverage = subsequenceCoverage(
        normalizeContent(htmlContent), normalizeContent(jsonContent))
    }
    report.rows.push(row)
  }

  for (const key of htmlKeys) {
    if (jsonT[key] === undefined) {
      report.extraHtmlEntries.push(key)
    }
  }
  return report
}
