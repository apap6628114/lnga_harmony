import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { parseBBCode } from '../src/parser/bbcode/parser'
import { BBNode, BBNodeType } from '../src/model/BBCodeNode'
import { concatTextNodes } from './helpers'
import { parseHtmlToRawJson } from '../src/parser/nga/html-thread/index'
import { preprocessJson } from '../src/parser/NgaJsonSanitizer'

/**
 * HTML 模式 → JSON 覆盖验证引擎（JSON 为基准，HTML 为被测对象）。
 *
 * 供 tests/html-mode-coverage.test.ts（断言）与 scripts/compare-html-json.ts（报告）共用。
 *
 * 数据来源约定（scripts/fetch-thread-pair.mjs 产出）：
 * - samples/html-pairs.lst：每行一个基准名（如 html-pair-46425481-p1）
 * - samples/html-pair-<tid>-p<page>.json：JSON API 原始响应（tab 已转义）
 * - samples/html-pair-<tid>-p<page>.html：read.php 原始 HTML（GBK 已解码）
 *
 * 对比维度：
 * - 楼层集合：JSON 每楼（lou）在 HTML 输出中是否有对应
 * - 楼层元数据字段：pid/authorid/postdatetimestamp/type/score/score_2/content_length/
 *   from_client/from_client_model/postdate/subject/vote/alterinfo/isanonymous 逐字段相等性
 * - 正文文本覆盖率：JSON content（BBCode 源文）经解析器得到纯文本，与 HTML content
 *   （渲染后 HTML）经同一解析器得到的纯文本做去空白子序列匹配（贪心），量化"可见文字缺失"
 * - 附件：JSON attachs 与 HTML attach.load 解析结果的数量与 URL 覆盖
 * - 用户表 __U：UID 集合覆盖、交集用户用户名一致性、__U 字段出现率
 * - 线程/分页：主题标题、作者、__ROWS、__PAGE
 * - 结构清单（仅报告）：JSON 侧解析树 TABLE/COLLAPSE/LIST/IMAGE/URL 等计数，
 *   用于量化 HTML 渲染丢结构（表格/折叠/列表在渲染后 HTML 中不可恢复）
 */

/** 成对样本目录。 */
const SAMPLES_DIR: string = join(process.cwd(), 'samples')

/** 样本清单文件。 */
const LIST_FILE: string = join(SAMPLES_DIR, 'html-pairs.lst')

/**
 * 读取 html-pairs.lst 中的基准名列表。
 *
 * @returns 基准名数组（如 ['html-pair-46425481-p1']）；清单缺失或为空时返回 []
 */
export function loadPairNames(): string[] {
  if (!existsSync(LIST_FILE)) return []
  return readFileSync(LIST_FILE, 'utf8')
    .split('\n')
    .map((line: string) => line.trim())
    .filter((line: string) => line.length > 0 && !line.startsWith('#'))
}

/**
 * 成对样本的原始文本（JSON 响应 + HTML 页面）。
 */
export interface HtmlPairData {
  name: string
  jsonText: string
  htmlText: string
}

/**
 * 加载一对样本。
 *
 * @param name 基准名（html-pair-<tid>-p<page>）
 * @returns JSON 响应文本与 HTML 页面文本
 */
export function loadPair(name: string): HtmlPairData {
  return {
    name,
    jsonText: readFileSync(join(SAMPLES_DIR, `${name}.json`), 'utf8'),
    htmlText: readFileSync(join(SAMPLES_DIR, `${name}.html`), 'utf8'),
  }
}

/**
 * 已知缺口声明（样本级白名单）。
 *
 * read.php 页面存在"隐楼"行为：被隐藏/删除的楼层在页面中不渲染，
 * 但服务器行号继续递增，导致后续楼层行号与真实 lou 错位（如页面行 12 = JSON lou 11）。
 * HTML 模式从页面无法恢复真实 lou 号，此映射把"页面行号 → JSON lou"对齐，
 * 使对齐后的逐楼校验得以执行，同时报告保留原始错位信息。
 */
export interface PairGaps {
  note?: string
  /** 页面行号 → JSON lou 映射（未列出的行号按原样配对） */
  rowShift: Record<string, number>
}

const GAPS_FILE: string = join(SAMPLES_DIR, 'html-pair-gaps.json')

/**
 * 加载全部样本的已知缺口声明。
 *
 * @returns 基准名 → 缺口声明
 */
export function loadPairGaps(): Record<string, PairGaps> {
  if (!existsSync(GAPS_FILE)) return {}
  const parsed: Record<string, PairGaps> = JSON.parse(readFileSync(GAPS_FILE, 'utf8')) as Record<string, PairGaps>
  return parsed
}

/** 单字段对比结果。 */
export interface FieldReport {
  field: string
  /** JSON 行中该字段是否有非空值 */
  jsonHas: boolean
  /** HTML 行中该字段是否有非空值 */
  htmlHas: boolean
  /** 双方均有值时的相等性；任一侧无值时为 null */
  equal: boolean | null
  jsonValue: string
  htmlValue: string
}

/** 楼层覆盖结果。 */
export interface RowCoverage {
  lou: number
  /** 对应配对的 HTML 页面行号（已知缺口映射后可能与 lou 不同；未映射时相同） */
  htmlRowLou: number
  /** HTML 输出中是否存在该楼层 */
  foundInHtml: boolean
  fields: FieldReport[]
  content: {
    jsonContentLen: number
    htmlContentLen: number
    /** 去空白后 JSON 文本字符在 HTML 文本中的贪心子序列匹配率 0..1；JSON 无文本时为 1 */
    textCoverage: number
    /** 首个未被覆盖的 JSON 文本片段（截断显示） */
    missingText: string
    jsonHasContent: boolean
  }
  attach: {
    jsonCount: number
    htmlCount: number
    /** HTML 附件 URL 命中 JSON 附件 URL 的数量 */
    urlCovered: number
  }
  hotreply: {
    jsonCount: number
    htmlCount: number
    /** 逐条目不一致描述（pid/authorid/type/score/postdate/content/lou 等） */
    mismatches: string[]
  }
}

/** 用户表覆盖结果。 */
export interface UserCoverage {
  jsonCount: number
  htmlCount: number
  /** 交集 UID 数 */
  matched: number
  /** 用户名不一致的 UID 列表 */
  usernameMismatch: Array<{ uid: string; json: string; html: string }>
  /** 交集 UID 内各字段双侧出现率（缺失 = JSON 有值而 HTML 无值） */
  fieldPresence: Array<{ field: string; jsonHas: number; htmlHas: number; total: number }>
}

/** 结构清单（报告用）。 */
export interface StructureCounts {
  table: number
  tableCell: number
  collapse: number
  list: number
  image: number
  url: number
  quote: number
}

/** 单对样本的完整对比报告。 */
export interface PairReport {
  name: string
  rows: RowCoverage[]
  /** 该样本的已知缺口声明（含页面行号错位映射），未声明时为 undefined */
  gaps?: PairGaps
  /** JSON 有而 HTML 缺失的楼层 */
  missingRowLous: number[]
  users: UserCoverage
  thread: {
    subjectJson: string
    subjectHtml: string
    subjectEqual: boolean | null
    authorJson: string
    authorHtml: string
    authorEqual: boolean | null
    forumJson: string
    forumHtml: string
    forumEqual: boolean | null
    lastpostJson: number
    lastpostHtml: number
  }
  paging: {
    rowsJson: number
    rowsHtml: number
    pageJson: number
    pageHtml: number
  }
  /** 楼层元数据字段总体覆盖率（全部楼层聚合） */
  fieldAgg: Array<{ field: string; jsonHas: number; htmlHas: number; equal: number; mismatch: number }>
  /** JSON 行有值但 HTML 行缺失的字段清单（按出现次数降序） */
  missingFields: Array<{ field: string; count: number }>
  /** JSON 侧解析树结构计数（正文侧真值，HTML 渲染后不可恢复的维度） */
  jsonStructure: StructureCounts
  /** HTML 侧 content 经同一解析器后的结构计数（可恢复部分） */
  htmlStructure: StructureCounts
}

/** 参与逐字段对比的楼层元数据字段（content/attachs 单独处理）。 */
const ROW_FIELDS: string[] = [
  'pid', 'fid', 'authorid', 'author', 'subject', 'postdate', 'postdatetimestamp',
  'type', 'score', 'score_2', 'content_length', 'from_client', 'from_client_model',
  'vote', 'alterinfo', 'isanonymous',
]

/**
 * 按已知缺口映射把 JSON lou 换算为页面行号。
 *
 * @param lou JSON 楼层的 lou
 * @param shift 页面行号 → JSON lou 映射
 * @returns 应配对的页面行号；未在映射中时返回 lou 本身
 */
function htmlLouFor(lou: number, shift: Record<string, number>): number {
  const keys: string[] = Object.keys(shift)
  for (let i = 0; i < keys.length; i++) {
    if (shift[keys[i]] === lou) return Number(keys[i])
  }
  return lou
}

/** 需要纳入"缺失字段清单"的 JSON 侧字段（有值却无法从 HTML 恢复）。 */
const INVENTORY_FIELDS: string[] = [
  'hotreply', 'comment', 'comment_to_id', 'signature', 'js_escap_avatar', 'yz',
  'level', 'mute_time', 'aurvrc', 'postCount', 'reputation', 'memberGroup',
  'postnum', 'imageUrlList', 'formattedHtmlData',
]

/** __U 字段出现率统计目标。 */
const USER_FIELDS: string[] = [
  'username', 'avatar', 'signature', 'yz', 'rvrc', 'memberid', 'postnum',
  'mute_time', 'reputation', '__GROUPS',
]

/**
 * 字符串规范化为可比较值（去首尾空白）。
 *
 * @param v 原始值
 * @returns 规范化后的字符串；null/undefined 返回 ''
 */
function norm(v: unknown): string {
  return String(v ?? '').trim()
}

/**
 * 对象取值（任意层级 Record）。
 *
 * @param obj 目标对象
 * @param key 字段名
 * @returns 字段值
 */
function fieldOf(obj: Record<string, unknown>, key: string): unknown {
  return obj[key]
}

/**
 * 去空白贪心子序列文本覆盖率。
 *
 * needle（JSON 纯文本）逐字符在 haystack（HTML 纯文本）中向后贪心查找，
 * 命中数 / needle 总字符 = 覆盖率。O(n·m) 最坏，但真实数据覆盖率通常接近 1，
 * 每次 indexOf 就近命中；仅覆盖率崩塌时退化。
 *
 * @param needle JSON 侧纯文本
 * @param haystack HTML 侧纯文本
 * @returns 覆盖率与首个未覆盖片段（截断 120 字符）
 */
export function textCoverage(needle: string, haystack: string): { ratio: number; missing: string } {
  const a: string = needle.replace(/\s/g, '')
  const b: string = haystack.replace(/\s/g, '')
  if (a.length === 0) return { ratio: 1, missing: '' }
  if (b.length === 0) return { ratio: 0, missing: a.slice(0, 120) }
  let matched: number = 0
  let j: number = 0
  let missingRun: string = ''
  for (let i = 0; i < a.length; i++) {
    const c: string = a[i]
    const found: number = b.indexOf(c, j)
    if (found >= 0) {
      matched++
      j = found + 1
      if (missingRun.length > 0) {
        missingRun = ''
      }
    } else if (missingRun.length === 0) {
      missingRun = c
    } else {
      missingRun += c
      if (missingRun.length >= 120) break
    }
  }
  return { ratio: matched / a.length, missing: missingRun }
}

/**
 * 结构计数累加。
 *
 * @param acc 累加目标
 * @param add 待累加计数
 * @returns 累加结果
 */
function addStructures(acc: StructureCounts, add: StructureCounts): StructureCounts {
  return {
    table: acc.table + add.table,
    tableCell: acc.tableCell + add.tableCell,
    collapse: acc.collapse + add.collapse,
    list: acc.list + add.list,
    image: acc.image + add.image,
    url: acc.url + add.url,
    quote: acc.quote + add.quote,
  }
}

/**
 * 统计解析树结构计数。
 *
 * @param nodes 解析树
 * @returns 各类型节点数
 */
export function countStructures(nodes: BBNode[]): StructureCounts {
  const out: StructureCounts = { table: 0, tableCell: 0, collapse: 0, list: 0, image: 0, url: 0, quote: 0 }
  const walk = (ns: BBNode[]): void => {
    for (const n of ns) {
      switch (n.type) {
        case BBNodeType.TABLE: out.table++; break
        case BBNodeType.TABLE_CELL: out.tableCell++; break
        case BBNodeType.COLLAPSE: out.collapse++; break
        case BBNodeType.LIST: out.list++; break
        case BBNodeType.IMAGE: out.image++; break
        case BBNodeType.URL: out.url++; break
        case BBNodeType.QUOTE: out.quote++; break
        default: break
      }
      walk(n.children)
    }
  }
  walk(nodes)
  return out
}

/**
 * 解析 JSON API 响应为 data 对象。
 *
 * @param jsonText 原始 JSON 响应文本
 * @returns data 对象
 */
function parseJsonData(jsonText: string): Record<string, unknown> {
  const obj: Record<string, unknown> = JSON.parse(preprocessJson(jsonText)) as Record<string, unknown>
  const data: unknown = obj['data']
  if (typeof data !== 'object' || data === null) {
    throw new Error('JSON 响应缺少 data')
  }
  return data as Record<string, unknown>
}

/**
 * 楼层行对象（JSON __R 或 HTML __R 元素）。
 */
function rowOf(m: Record<string, unknown>, lou: number): Record<string, unknown> | undefined {
  const r: unknown = m[String(lou)]
  if (typeof r === 'object' && r !== null) return r as Record<string, unknown>
  return undefined
}

/**
 * 对一对样本执行完整覆盖分析。
 *
 * @param data 成对样本
 * @param gaps 该样本的已知缺口声明（可选；含页面行号错位映射）
 * @returns 对比报告
 */
export function analyzePair(data: HtmlPairData, gaps?: PairGaps): PairReport {
  const jsonData: Record<string, unknown> = parseJsonData(data.jsonText)
  const htmlRaw: unknown = parseHtmlToRawJson(data.htmlText)
  const htmlData: Record<string, unknown> = (htmlRaw as Record<string, unknown>)['data'] as Record<string, unknown>

  const jsonRows: Record<string, unknown> = (jsonData['__R'] ?? {}) as Record<string, unknown>
  const htmlRows: Record<string, unknown> = (htmlData['__R'] ?? {}) as Record<string, unknown>
  const jsonUsers: Record<string, unknown> = (jsonData['__U'] ?? {}) as Record<string, unknown>
  const htmlUsers: Record<string, unknown> = (htmlData['__U'] ?? {}) as Record<string, unknown>
  const jsonT: Record<string, unknown> = (jsonData['__T'] ?? {}) as Record<string, unknown>
  const htmlT: Record<string, unknown> = (htmlData['__T'] ?? {}) as Record<string, unknown>
  const jsonF: Record<string, unknown> = (jsonData['__F'] ?? {}) as Record<string, unknown>
  const htmlF: Record<string, unknown> = (htmlData['__F'] ?? {}) as Record<string, unknown>

  const shift: Record<string, number> = gaps?.rowShift ?? {}

  const louKeys: string[] = Object.keys(jsonRows)
  const rows: RowCoverage[] = []
  const fieldAgg: Record<string, { jsonHas: number; htmlHas: number; equal: number; mismatch: number }> = {}
  for (const f of ROW_FIELDS) {
    fieldAgg[f] = { jsonHas: 0, htmlHas: 0, equal: 0, mismatch: 0 }
  }
  const missingFields: Record<string, number> = {}
  let jsonStructures: StructureCounts = { table: 0, tableCell: 0, collapse: 0, list: 0, image: 0, url: 0, quote: 0 }
  let htmlStructures: StructureCounts = { table: 0, tableCell: 0, collapse: 0, list: 0, image: 0, url: 0, quote: 0 }
  const missingRowLous: number[] = []

  for (let i = 0; i < louKeys.length; i++) {
    const key: string = louKeys[i]
    const jsonRow: Record<string, unknown> | undefined = rowOf(jsonRows, Number(key))
    if (!jsonRow) continue
    const lou: number = Number(key)
    const htmlRowLou: number = htmlLouFor(lou, shift)
    const htmlRow: Record<string, unknown> | undefined = rowOf(htmlRows, htmlRowLou)
    const foundInHtml: boolean = htmlRow !== undefined

    const fields: FieldReport[] = []
    for (const f of ROW_FIELDS) {
      const jv: string = norm(jsonRow[f])
      const hv: string = htmlRow ? norm(htmlRow[f]) : ''
      const jsonHas: boolean = jv.length > 0
      const htmlHas: boolean = hv.length > 0
      let equal: boolean | null = null
      if (jsonHas && htmlHas) {
        equal = jv === hv
        const agg: { jsonHas: number; htmlHas: number; equal: number; mismatch: number } = fieldAgg[f]
        agg.equal += equal ? 1 : 0
        agg.mismatch += equal ? 0 : 1
      }
      if (jsonHas) fieldAgg[f].jsonHas++
      if (htmlHas) fieldAgg[f].htmlHas++
      fields.push({ field: f, jsonHas, htmlHas, equal, jsonValue: jv.slice(0, 60), htmlValue: hv.slice(0, 60) })
    }

    // 缺失字段清单：JSON 有值但 HTML 行中完全无此字段
    for (const f of INVENTORY_FIELDS) {
      if (norm(jsonRow[f]).length > 0 && (htmlRow === undefined || norm(htmlRow[f]).length === 0)) {
        missingFields[f] = (missingFields[f] ?? 0) + 1
      }
    }

    // 正文文本覆盖 + 结构清单
    const jsonContent: string = String(jsonRow['content'] ?? '')
    const htmlContent: string = htmlRow ? String(htmlRow['content'] ?? '') : ''
    const jsonHasContent: boolean = jsonContent.length > 0
    let tc: { ratio: number; missing: string } = { ratio: 1, missing: '' }
    if (jsonHasContent) {
      const jsonText: string = concatTextNodes(parseBBCode(jsonContent))
      const htmlText: string = concatTextNodes(parseBBCode(htmlContent))
      tc = textCoverage(jsonText, htmlText)
      jsonStructures = addStructures(jsonStructures, countStructures(parseBBCode(jsonContent)))
    }
    if (htmlContent.length > 0) {
      htmlStructures = addStructures(htmlStructures, countStructures(parseBBCode(htmlContent)))
    }

    // 附件覆盖
    const jsonAttachs: Record<string, unknown> = (jsonRow['attachs'] ?? {}) as Record<string, unknown>
    const htmlAttachs: Record<string, unknown> = (htmlRow ? htmlRow['attachs'] ?? {} : {}) as Record<string, unknown>
    const jsonUrls: string[] = Object.keys(jsonAttachs).map((k: string) => norm((jsonAttachs[k] as Record<string, unknown>)['attachurl'])).filter((u: string) => u.length > 0)
    const htmlUrls: string[] = Object.keys(htmlAttachs).map((k: string) => norm((htmlAttachs[k] as Record<string, unknown>)['attachurl'])).filter((u: string) => u.length > 0)
    let urlCovered: number = 0
    for (const u of htmlUrls) {
      if (jsonUrls.includes(u)) urlCovered++
    }

    // 热点回复覆盖（JSON 有 hotreply 时对比还原度）
    const jsonHot: Record<string, unknown> = (jsonRow['hotreply'] ?? {}) as Record<string, unknown>
    const htmlHot: Record<string, unknown> = (htmlRow ? htmlRow['hotreply'] ?? {} : {}) as Record<string, unknown>
    const jsonHotKeys: string[] = Object.keys(jsonHot)
    const htmlHotKeys: string[] = Object.keys(htmlHot)
    const hotMismatches: string[] = []
    const HOT_FIELDS: string[] = ['pid', 'authorid', 'type', 'score', 'score_2', 'postdatetimestamp', 'postdate', 'content', 'lou']
    for (let hi = 0; hi < jsonHotKeys.length; hi++) {
      const key: string = jsonHotKeys[hi]
      const jh: Record<string, unknown> = (jsonHot[key] ?? {}) as Record<string, unknown>
      const hh: Record<string, unknown> = (htmlHot[key] ?? {}) as Record<string, unknown>
      for (const f of HOT_FIELDS) {
        const jv: string = norm(jh[f])
        const hv: string = norm(hh[f])
        if (jv.length > 0 && jv !== hv) {
          hotMismatches.push(`hotreply[${key}].${f}: JSON="${jv.slice(0, 40)}" vs HTML="${hv.slice(0, 40)}"`)
        }
      }
    }

    rows.push({
      lou, htmlRowLou, foundInHtml,
      fields,
      content: {
        jsonContentLen: jsonContent.length,
        htmlContentLen: htmlContent.length,
        textCoverage: tc.ratio,
        missingText: tc.missing,
        jsonHasContent,
      },
      attach: {
        jsonCount: jsonUrls.length,
        htmlCount: htmlUrls.length,
        urlCovered,
      },
      hotreply: {
        jsonCount: jsonHotKeys.length,
        htmlCount: htmlHotKeys.length,
        mismatches: hotMismatches,
      },
    })
    if (!foundInHtml) missingRowLous.push(lou)
  }

  // 用户表覆盖
  const jsonUids: string[] = Object.keys(jsonUsers)
  const htmlUids: string[] = Object.keys(htmlUsers)
  const commonUids: string[] = jsonUids.filter((u: string) => htmlUids.includes(u))
  const usernameMismatch: Array<{ uid: string; json: string; html: string }> = []
  const fieldPresence: Array<{ field: string; jsonHas: number; htmlHas: number; total: number }> = []
  for (const f of USER_FIELDS) {
    let jsonHas: number = 0
    let htmlHas: number = 0
    for (const u of commonUids) {
      const ju: unknown = fieldOf((jsonUsers[u] as Record<string, unknown>) ?? {}, f)
      const hu: unknown = fieldOf((htmlUsers[u] as Record<string, unknown>) ?? {}, f)
      if (norm(ju).length > 0) jsonHas++
      if (norm(hu).length > 0) htmlHas++
    }
    fieldPresence.push({ field: f, jsonHas, htmlHas, total: commonUids.length })
  }
  for (const u of commonUids) {
    const jn: string = norm((jsonUsers[u] as Record<string, unknown>)['username'])
    const hn: string = norm((htmlUsers[u] as Record<string, unknown>)['username'])
    if (jn.length > 0 && hn.length > 0 && jn !== hn) {
      usernameMismatch.push({ uid: u, json: jn, html: hn })
    }
  }

  // 线程与分页
  const rowsJson: number = Number(jsonData['__ROWS'] ?? 0)
  const rowsHtml: number = Number(htmlData['__ROWS'] ?? 0)
  const pageJson: number = Number(jsonData['__PAGE'] ?? 0)
  const pageHtml: number = Number(htmlData['__PAGE'] ?? 0)
  const subjJ: string = norm(jsonT['subject'])
  const subjH: string = norm(htmlT['subject'])
  const authJ: string = norm(jsonT['author'])
  const authH: string = norm(htmlT['author'])
  const forumJ: string = norm(jsonF['name'])
  const forumH: string = norm(htmlF['name'])

  return {
    name: data.name,
    gaps,
    rows,
    missingRowLous,
    users: {
      jsonCount: jsonUids.length,
      htmlCount: htmlUids.length,
      matched: commonUids.length,
      usernameMismatch,
      fieldPresence,
    },
    thread: {
      subjectJson: subjJ,
      subjectHtml: subjH,
      subjectEqual: subjJ.length > 0 && subjH.length > 0 ? subjJ === subjH : null,
      authorJson: authJ,
      authorHtml: authH,
      authorEqual: authJ.length > 0 && authH.length > 0 ? authJ === authH : null,
      forumJson: forumJ,
      forumHtml: forumH,
      forumEqual: forumJ.length > 0 && forumH.length > 0 ? forumJ === forumH : null,
      lastpostJson: Number(jsonT['lastpost'] ?? 0),
      lastpostHtml: Number(htmlT['lastpost'] ?? 0),
    },
    paging: { rowsJson, rowsHtml, pageJson, pageHtml },
    fieldAgg: ROW_FIELDS.map((f: string) => ({ field: f, ...fieldAgg[f] })),
    missingFields: Object.keys(missingFields)
      .map((f: string) => ({ field: f, count: missingFields[f] ?? 0 }))
      .sort((a: { count: number }, b: { count: number }): number => b.count - a.count),
    jsonStructure: jsonStructures,
    htmlStructure: htmlStructures,
  }
}
