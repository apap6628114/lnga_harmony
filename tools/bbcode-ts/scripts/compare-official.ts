import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { parseBBCode } from '../src/parser/bbcode/parser'
import { BBNode, BBNodeType } from '../src/model/BBCodeNode'
import {
  OfficialRun, loadSampleContent, treeToRuns, runsText, countStyles, collectCollapseText, normalizeCollapseTitle
} from '../tests/helpers'

/**
 * 官方渲染基准差分对比（人类可读报告版）。
 *
 * 输入：
 * - samples/demo.txt：NGA API content（待验证输入）
 * - samples/official-<tid>-lou0-runs.json：chrome 内脚本提取的官方渲染 run 序列
 *
 * 对比维度：
 * 1. 文本流（规范化后逐字符 diff）——抓漏解释/错解释
 * 2. 样式统计（粗体/颜色/字号/链接/表格/折叠块）——抓样式解释差异
 * 3. 锚点样式链——精确验证已知句子的完整样式
 *
 * 自动化断言见 tests/official.test.ts；本脚本输出完整人类可读报告。
 *
 * 运行：npm run build && node dist/scripts/compare-official.js
 */

const SAMPLES: string = join(process.cwd(), 'samples')
const CONTENT: string = loadSampleContent('demo.txt')
const OFFICIAL: OfficialRun[] = (JSON.parse(readFileSync(join(SAMPLES, 'official-tid46425481-lou0-runs.json'), 'utf8')) as { runs: OfficialRun[] }).runs

const nodes: BBNode[] = parseBBCode(CONTENT)
const ourRuns: OfficialRun[] = treeToRuns(nodes)
const officialText: string = runsText(OFFICIAL)
const ourText: string = runsText(ourRuns)

console.log('=== 文本流对比 ===')
console.log(`官方文本: ${officialText.length} 字符 | 解析树文本: ${ourText.length} 字符 | 差 ${ourText.length - officialText.length}`)
const diffs: Array<{ at: number; o: string; m: string }> = []
let scan: number = 0
while (scan < Math.min(officialText.length, ourText.length)) {
  if (officialText.charCodeAt(scan) === ourText.charCodeAt(scan)) { scan++; continue }
  const at: number = scan
  let oSeg: string = ''
  let mSeg: string = ''
  while (scan < Math.min(officialText.length, ourText.length) && officialText.charCodeAt(scan) !== ourText.charCodeAt(scan)) {
    oSeg += officialText[scan]
    mSeg += ourText[scan]
    scan++
  }
  diffs.push({ at, o: oSeg, m: mSeg })
  if (diffs.length >= 20) break
}
if (diffs.length === 0 && officialText.length === ourText.length) {
  console.log('文本流完全一致 ✓')
} else {
  for (const d of diffs) {
    console.log(`差异 @${d.at}:`)
    console.log(`  官方: ${JSON.stringify(officialText.slice(Math.max(0, d.at - 25), d.at + 25))}`)
    console.log(`  解析: ${JSON.stringify(ourText.slice(Math.max(0, d.at - 25), d.at + 25))}`)
  }
  if (diffs.length >= 20) console.log('  ...（差异过多，仅显示前 20 处）')
}

console.log('\n=== 样式统计对比 ===')
const o = countStyles(OFFICIAL)
const m = countStyles(ourRuns)
const rows: Array<[string, string, number | string[], number | string[]]> = [
  ['chars', '文本字符数', o.chars, m.chars],
  ['boldChars', '粗体字符', o.boldChars, m.boldChars],
  ['italicChars', '斜体字符', o.italicChars, m.italicChars],
  ['underlineChars', '下划线字符', o.underlineChars, m.underlineChars],
  ['strikeChars', '删除线字符', o.strikeChars, m.strikeChars],
  ['links', '链接数', o.links, m.links],
  ['tableChars', '表格区字符', o.tableChars, m.tableChars],
]
for (const [_key, name, ov, mv] of rows) {
  console.log(`  ${ov === mv ? '✓' : '✗'} ${name}: 官方 ${ov} | 解析 ${mv}`)
}

// 颜色/字号分布（从 run 直接统计）
const oColors: Record<string, number> = {}
const mColors: Record<string, number> = {}
const oSizes: Record<string, number> = {}
const mSizes: Record<string, number> = {}
for (const r of OFFICIAL) {
  if (r.k !== 'text') continue
  if (r.c.length > 0) oColors[r.c] = (oColors[r.c] ?? 0) + r.t.length
  if (r.sz > 0) oSizes[String(r.sz)] = (oSizes[String(r.sz)] ?? 0) + r.t.length
}
for (const r of ourRuns) {
  if (r.k !== 'text') continue
  if (r.c.length > 0) mColors[r.c] = (mColors[r.c] ?? 0) + r.t.length
  if (r.sz > 0) mSizes[String(r.sz)] = (mSizes[String(r.sz)] ?? 0) + r.t.length
}
for (const c of new Set([...Object.keys(oColors), ...Object.keys(mColors)])) {
  const ov: number = oColors[c] ?? 0
  const mv: number = mColors[c] ?? 0
  console.log(`  ${ov === mv ? '✓' : '✗'} 颜色 ${c}: 官方 ${ov} 字符 | 解析 ${mv} 字符`)
}
for (const s of new Set([...Object.keys(oSizes), ...Object.keys(mSizes)])) {
  const ov: number = oSizes[s] ?? 0
  const mv: number = mSizes[s] ?? 0
  console.log(`  ${ov === mv ? '✓' : '✗'} 字号 ${s}%: 官方 ${ov} 字符 | 解析 ${mv} 字符`)
}
console.log(`  collapse 标题: 官方 [${(o.collapseTitles as string[]).map(normalizeCollapseTitle).join(', ')}] vs 解析 [${(m.collapseTitles as string[]).join(', ')}]`)

console.log('\n=== 锚点样式链 ===')
const anchors: string[] = ['12.0开始了~~~', '破法者的掩蔽', '萨拉斯竞争者', 'P.O.W.x3', '魔导师的法力之剑']
for (const anchor of anchors) {
  const findRun = (runs: OfficialRun[]): OfficialRun | null => {
    for (const r of runs) {
      if (r.k === 'text' && r.t.includes(anchor)) return r
    }
    return null
  }
  const fo: OfficialRun | null = findRun(OFFICIAL)
  const fm: OfficialRun | null = findRun(ourRuns)
  const fmt = (r: OfficialRun | null): string => {
    if (!r) return '未找到'
    return `b=${r.b} i=${r.i} u=${r.u} st=${r.st} c=${r.c || '-'} sz=${r.sz || '-'} ${r.tbl ? '表格内' : ''}`
  }
  const same: boolean = fo !== null && fm !== null &&
    fo.b === fm.b && fo.i === fm.i && fo.u === fm.u && fo.st === fm.st &&
    fo.c === fm.c && fo.sz === fm.sz && fo.tbl === fm.tbl
  console.log(`  ${same ? '✓' : '✗'} "${anchor}"\n    官方: ${fmt(fo)}\n    解析: ${fmt(fm)}`)
}

console.log('\n=== 表格结构 ===')
const officialMeta: { tdCount?: number; tableCount?: number } = JSON.parse(readFileSync(join(SAMPLES, 'official-tid46425481-lou0-runs.json'), 'utf8'))
const countType = (ns: BBNode[], type: BBNodeType): number => {
  let n: number = 0
  for (const node of ns) {
    if (node.type === type) n++
    n += countType(node.children, type)
  }
  return n
}
console.log(`  官方 td 数: ${officialMeta.tdCount ?? '?'} | 解析树 TABLE_CELL: ${countType(nodes, BBNodeType.TABLE_CELL)}`)
console.log(`  官方 table 数: ${officialMeta.tableCount ?? '?'} | 解析树 TABLE: ${countType(nodes, BBNodeType.TABLE)}`)

console.log('\n=== collapse 内容验证（官方网页截断，仅解析树侧） ===')
const collapseText: string = collectCollapseText(nodes)
const collapsePhrases: string[] = ['熔铸活力', '12.0所有材料和公函', '神话纹章：可升级276-289装备']
for (const phrase of collapsePhrases) {
  console.log(`  ${collapseText.includes(phrase) ? '✓' : '✗'} collapse 内容含 "${phrase}"`)
}
console.log(`  collapse 内容总字符: ${collapseText.length}`)
