import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { BBNode, BBNodeType } from '../src/model/BBCodeNode'

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

// ---------------------------------------------------------------------------
// 官方渲染差分对比公共逻辑（tests/official.test.ts 与 scripts/compare-official.ts 共用）
// ---------------------------------------------------------------------------

/** 官方渲染 run（浏览器提取脚本输出格式）。 */
export interface OfficialRun {
  t: string
  b: boolean
  i: boolean
  u: boolean
  st: boolean
  c: string
  sz: number
  href: string
  k: string
  tbl: boolean
  col: string
}

/** 样式上下文（树遍历时逐层累积）。 */
interface StyleCtx {
  b: boolean
  i: boolean
  u: boolean
  st: boolean
  c: string
  sz: number
  href: string
  tbl: boolean
}

/** 官方 collapse 标题归一：去 "+ " 前缀与 " ..." 截断后缀。 */
export function normalizeCollapseTitle(t: string): string {
  return t.replace(/^\+?\s*/, '').replace(/\s*\.\.\.\s*$/, '').trim()
}

/**
 * 从解析树生成与官方渲染同构的 run 序列。
 *
 * 官方行为对齐：
 * - COLLAPSE：仅输出标题（官方 collapse_content 服务端截断为空）；children 跳过
 * - 表格区（tbl=true）：\n 统一删除（官方 td 边界无分隔，解析树行级有）
 * - IMAGE：跳过（官方懒加载占位）
 */
export function treeToRuns(nodes: BBNode[], ctx: StyleCtx = { b: false, i: false, u: false, st: false, c: '', sz: 0, href: '', tbl: false }): OfficialRun[] {
  const runs: OfficialRun[] = []

  const walk = (nodes: BBNode[], ctx: StyleCtx): void => {
    const push = (text: string, col: string = ''): void => {
      if (text.length === 0) return
      const clean: string = ctx.tbl ? text.replace(/\n/g, '') : text
      if (clean.length === 0) return
      const last: OfficialRun | undefined = runs.length > 0 ? runs[runs.length - 1] : undefined
      if (last !== undefined && last.k === 'text' && last.col === col && last.b === ctx.b && last.i === ctx.i && last.u === ctx.u &&
        last.st === ctx.st && last.c === ctx.c && last.sz === ctx.sz && last.href === ctx.href && last.tbl === ctx.tbl) {
        last.t += clean
        return
      }
      runs.push({ t: clean, b: ctx.b, i: ctx.i, u: ctx.u, st: ctx.st, c: ctx.c, sz: ctx.sz, href: ctx.href, k: 'text', tbl: ctx.tbl, col })
    }
    for (const node of nodes) {
      const nctx = { ...ctx }
      switch (node.type) {
        case BBNodeType.TEXT:
          push(node.text)
          continue
        case BBNodeType.BOLD: nctx.b = true; break
        case BBNodeType.ITALIC: nctx.i = true; break
        case BBNodeType.UNDERLINE: nctx.u = true; break
        case BBNodeType.STRIKETHROUGH: nctx.st = true; break
        case BBNodeType.COLOR:
          if (node.color.length > 0) nctx.c = node.color
          break
        case BBNodeType.SIZE:
          if (node.size > 0) nctx.sz = node.size
          break
        case BBNodeType.URL:
        case BBNodeType.PID_LINK:
        case BBNodeType.UID_LINK:
        case BBNodeType.TID_LINK:
        case BBNodeType.MENTION:
          if (node.href.length > 0) nctx.href = node.href
          break
        case BBNodeType.QUOTE:
        case BBNodeType.FLOAT_LEFT:
        case BBNodeType.FLOAT_RIGHT:
        case BBNodeType.ALIGN:
        case BBNodeType.STYLE_DIV:
        case BBNodeType.PARAGRAPH:
        case BBNodeType.HEADING:
        case BBNodeType.LIST:
        case BBNodeType.LIST_ITEM:
        case BBNodeType.HR:
        case BBNodeType.DICE:
        case BBNodeType.POST_BY:
        case BBNodeType.CODE:
          walk(node.children, nctx)
          continue
        case BBNodeType.TABLE:
          walk(node.children, { ...nctx, tbl: true })
          continue
        case BBNodeType.TABLE_ROW:
        case BBNodeType.TABLE_CELL:
          walk(node.children, nctx)
          continue
        case BBNodeType.COLLAPSE:
          push(normalizeCollapseTitle(node.title), normalizeCollapseTitle(node.title))
          continue
        case BBNodeType.IMAGE:
        case BBNodeType.ALBUM:
        case BBNodeType.VIDEO:
        case BBNodeType.AUDIO:
        case BBNodeType.FLASH:
        case BBNodeType.EMOTION:
          continue
        default:
          if (node.children.length > 0) walk(node.children, nctx)
          else if (node.text.length > 0) push(node.text)
          continue
      }
      walk(node.children, nctx)
    }
  }

  walk(nodes, ctx)
  return runs
}

/**
 * 文本流拼接（表格内 \n 统一删除，两侧对称）。
 *
 * 同时模拟官方网页渲染的块级空白折叠：表格块边界（进入/离开表格）的
 * 连续换行/空格折叠为 1 个换行（NGA 渲染 `[table]` 前后 `<br/><br/>`、
 * `<br/> <br/>` 时只保留 1 个 `<br>`）。官方文本流已折叠，应用此规则幂等。
 */
export function runsText(runs: OfficialRun[]): string {
  let out: string = ''
  let prevTbl: boolean = false
  for (const r of runs) {
    if (r.k !== 'text') continue
    let t: string = r.tbl ? r.t.replace(/\n/g, '') : r.t
    if (r.tbl !== prevTbl) {
      out = out.replace(/[\n ]+$/, '\n')
      t = t.replace(/^[\n ]+/, '\n')
    }
    prevTbl = r.tbl
    out += t
  }
  return out.trim()
}

/**
 * 样式统计。
 *
 * chars 复用 runsText（口径一致：表格边界空白折叠）；
 * 其余字段按 run 累加——表格边界折叠只影响无样式分隔 run，不影响样式统计。
 */
export function countStyles(runs: OfficialRun[]): Record<string, number | string[]> {
  const stats: Record<string, number | string[]> = { chars: 0, boldChars: 0, italicChars: 0, underlineChars: 0, strikeChars: 0, links: 0, imgRuns: 0, tableChars: 0, collapseTitles: [] }
  for (const r of runs) {
    if (r.k === 'img') { stats.imgRuns = (stats.imgRuns as number) + 1; continue }
    const t: string = r.tbl ? r.t.replace(/\n/g, '') : r.t
    const n: number = t.length
    if (r.b) stats.boldChars = (stats.boldChars as number) + n
    if (r.i) stats.italicChars = (stats.italicChars as number) + n
    if (r.u) stats.underlineChars = (stats.underlineChars as number) + n
    if (r.st) stats.strikeChars = (stats.strikeChars as number) + n
    if (r.href.length > 0) stats.links = (stats.links as number) + 1
    if (r.tbl) stats.tableChars = (stats.tableChars as number) + n
    if (r.col.length > 0) (stats.collapseTitles as string[]).push(normalizeCollapseTitle(r.col))
  }
  stats.chars = runsText(runs).length
  return stats
}

/** 拼接全部 COLLAPSE 节点 children 的文本（验证折叠内容在解析树中完整保留）。 */
export function collectCollapseText(nodes: BBNode[]): string {
  let text: string = ''
  for (const n of nodes) {
    if (n.type === BBNodeType.COLLAPSE) text += concatTextNodes(n.children)
    text += collectCollapseText(n.children)
  }
  return text
}
