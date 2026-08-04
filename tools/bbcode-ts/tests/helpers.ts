import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { BBNode } from '../src/model/BBCodeNode'

/**
 * 仓库根目录（tools/bbcode-ts）。
 *
 * 使用 process.cwd() 而非 __dirname：编译产物位于 dist/ 时目录层级变化，
 * 而 npm scripts 始终在仓库根执行。
 */
const ROOT_DIR = process.cwd()

/** 样本目录（samples/，含样本正文与 samples.lst 清单）。 */
const SAMPLES_DIR = join(ROOT_DIR, 'samples')

/**
 * 尝试将字符串解析为 JSON 对象；失败返回 null。
 *
 * @param s 待解析文本
 * @returns 解析结果或 null
 */
function tryParseObject(s: string): Record<string, unknown> | null {
  try {
    return JSON.parse(s) as Record<string, unknown>
  } catch {
    return null
  }
}

/**
 * 读取楼层回复样本的 content 字段。
 *
 * 样本文件多为 NGA API 响应摘取的单行字段 `"content": "...",`（带尾逗号），
 * 依次尝试：完整 JSON 对象 → 包装为对象（去尾逗号）→ 正则直接提取。
 *
 * @param name 样本文件名（如 demo.txt）
 * @returns 楼层回复正文
 * @throws 三种方式均无法提取时抛出
 */
export function loadSampleContent(name: string): string {
  const raw: string = readFileSync(join(SAMPLES_DIR, name), 'utf8').trim()
  const trimmed: string = raw.endsWith(',') ? raw.slice(0, -1) : raw

  const obj: Record<string, unknown> | null =
    tryParseObject(raw) ?? tryParseObject(`{${trimmed}}`)
  if (obj !== null) {
    const content: unknown = obj['content']
    if (typeof content === 'string') return content
  }

  const match: RegExpExecArray | null = /^"content"\s*:\s*"([\s\S]*)"\s*,?\s*$/.exec(raw)
  if (match) return match[1]

  throw new Error(`无法从样本 ${name} 提取 content 字段`)
}

/**
 * 将解析树序列化为可读 JSON（快照与 diff 用）。
 *
 * 节点类型用枚举名而非数字索引，便于人工审查；id 为进程内自增不稳定，跳过。
 *
 * @param nodes 解析树
 * @returns 序列化结果
 */
export function nodeToJson(nodes: BBNode[]): unknown[] {
  return nodes.map((n: BBNode) => {
    const o: Record<string, unknown> = { type: BBNodeTypeName(n.type) }
    if (n.text.length > 0) o.text = n.text
    if (n.href.length > 0) o.href = n.href
    if (n.color.length > 0) o.color = n.color
    if (n.size !== 0) o.size = n.size
    if (n.src.length > 0) o.src = n.src
    if (n.title.length > 0) o.title = n.title
    if (n.emotionCat.length > 0) o.emotionCat = n.emotionCat
    if (n.emotionCode.length > 0) o.emotionCode = n.emotionCode
    if (n.fontFamily.length > 0) o.fontFamily = n.fontFamily
    if (n.align.length > 0) o.align = n.align
    if (n.colSpan !== 0) o.colSpan = n.colSpan
    if (n.rowSpan !== 0) o.rowSpan = n.rowSpan
    if (n.colWidth !== 0) o.colWidth = n.colWidth
    if (n.inheritedFormatTags.length > 0) o.inheritedFormatTags = n.inheritedFormatTags
    if (n.children.length > 0) o.children = nodeToJson(n.children)
    return o
  })
}

/** 从枚举数字反向取类型名（避免测试代码循环依赖枚举）。 */
function BBNodeTypeName(t: number): string {
  switch (t) {
    case 0: return 'TEXT'
    case 1: return 'BOLD'
    case 2: return 'ITALIC'
    case 3: return 'UNDERLINE'
    case 4: return 'STRIKETHROUGH'
    case 5: return 'COLOR'
    case 6: return 'SIZE'
    case 7: return 'FONT'
    case 8: return 'URL'
    case 9: return 'IMAGE'
    case 10: return 'QUOTE'
    case 11: return 'COLLAPSE'
    case 12: return 'CODE'
    case 13: return 'LIST'
    case 14: return 'LIST_ITEM'
    case 15: return 'PID_LINK'
    case 16: return 'UID_LINK'
    case 17: return 'TID_LINK'
    case 18: return 'MENTION'
    case 19: return 'POST_BY'
    case 20: return 'EMOTION'
    case 21: return 'VIDEO'
    case 22: return 'AUDIO'
    case 23: return 'DICE'
    case 24: return 'WARN'
    case 25: return 'ALBUM'
    case 26: return 'FLOAT_LEFT'
    case 27: return 'FLOAT_RIGHT'
    case 28: return 'ALIGN'
    case 29: return 'TABLE'
    case 30: return 'TABLE_ROW'
    case 31: return 'TABLE_CELL'
    case 32: return 'STYLE_DIV'
    case 33: return 'FLASH'
    case 34: return 'HR'
    case 35: return 'PARAGRAPH'
    case 36: return 'SUBSCRIPT'
    case 37: return 'SUPERSCRIPT'
    case 38: return 'HEADING'
    default: return String(t)
  }
}

/**
 * 判断 needle 是否为 haystack 的子序列（字符按序出现，允许间隔）。
 *
 * 文本零丢失断言使用子序列而非相等：解析器可能合并/规范化空白，
 * 且无法识别为标签的 `[` 会被保留为文字，两侧并不严格相等；
 * 但"解析结果缺少原文中的某个字符"（漏解释）必然导致子序列失败。
 *
 * @param needle 原文剥离标签后的文本
 * @param haystack 解析树拼接出的纯文本
 * @returns 是否子序列
 */
export function isSubsequence(needle: string, haystack: string): boolean {
  let i: number = 0
  for (let j: number = 0; i < needle.length && j < haystack.length; j++) {
    if (needle.charCodeAt(i) === haystack.charCodeAt(j)) i++
  }
  return i === needle.length
}

/**
 * 递归统计解析树中的节点类型数量。
 *
 * @param nodes 解析树
 * @param typeName 目标类型名（如 'TABLE'）
 * @returns 计数
 */
export function countNodes(nodes: BBNode[], typeName: string): number {
  let count: number = 0
  for (const n of nodes) {
    if (BBNodeTypeName(n.type) === typeName) count++
    count += countNodes(n.children, typeName)
  }
  return count
}

/**
 * 纯拼接全部 TEXT 节点文本（不做任何 trim / 跳过）。
 *
 * 与 bbNodesToPlainText 不同：后者为纯文本提取语义会剥除每个样式子树
 * 的边缘空白，不适合字符级零丢失断言；本函数逐字保留。
 *
 * @param nodes 解析树
 * @returns 全部文本逐字拼接
 */
export function concatTextNodes(nodes: BBNode[]): string {
  let s: string = ''
  for (const n of nodes) {
    s += n.text
    s += concatTextNodes(n.children)
  }
  return s
}
