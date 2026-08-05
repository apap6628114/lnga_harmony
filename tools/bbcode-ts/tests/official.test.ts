import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { parseBBCode } from '../src/parser/bbcode/parser'
import { BBNode, BBNodeType } from '../src/model/BBCodeNode'
import {
  OfficialRun, loadSampleContent, treeToRuns, runsText, countStyles, collectCollapseText
} from './helpers'

/**
 * 官方渲染基准差分测试。
 *
 * 基准来源：chrome devtools 抓取 https://ngabbs.com/read.php?tid=46425481
 * 楼主层 postcontent0 渲染后 DOM，由浏览器内脚本提取为 run 序列
 * （samples/official-tid46425481-lou0-runs.json）。
 *
 * 断言：解析树 run 序列（官方同构格式）与官方渲染 run 序列在
 * 文本流、样式统计、锚点样式链上一致——即"官方网页怎么解释，解析器就怎么解释"。
 *
 * 重新提取官方基准：打开楼层页 → 执行 chrome 脚本（见 compare-official.ts 注释）→
 * 覆盖 samples/official-*-runs.json。
 */

const OFFICIAL_FILE: string = join(process.cwd(), 'samples', 'official-tid46425481-lou0-runs.json')

const officialData: { runs: OfficialRun[]; tdCount?: number; tableCount?: number } | null = existsSync(OFFICIAL_FILE)
  ? (JSON.parse(readFileSync(OFFICIAL_FILE, 'utf8')) as { runs: OfficialRun[]; tdCount?: number; tableCount?: number })
  : null

describe('官方渲染基准差分（tid=46425481 楼主层）', () => {
  it('官方基准样本存在（先通过 chrome devtools 提取）', () => {
    assert.ok(officialData !== null && officialData.runs.length > 0,
      '官方基准缺失。用 chrome devtools 打开楼层页，执行 run 序列提取脚本并保存为 samples/official-tid46425481-lou0-runs.json')
  })

  // 后续断言依赖官方样本，样本缺失时跳过（上面已失败）
  if (officialData === null) return

  const content: string = loadSampleContent('demo.txt')
  const nodes: BBNode[] = parseBBCode(content)
  const ourRuns: OfficialRun[] = treeToRuns(nodes)

  it('文本流与官方渲染逐字符一致', () => {
    assert.equal(runsText(ourRuns), runsText(officialData.runs),
      '文本流与官方渲染不一致（差异可能为漏解释/错解释/官方渲染行为）')
  })

  it('样式统计与官方渲染一致', () => {
    const o: Record<string, number | string[]> = countStyles(officialData.runs)
    const m: Record<string, number | string[]> = countStyles(ourRuns)
    const fields: Array<[string, string]> = [
      ['chars', '文本字符数'],
      ['boldChars', '粗体字符'],
      ['italicChars', '斜体字符'],
      ['underlineChars', '下划线字符'],
      ['strikeChars', '删除线字符'],
      ['links', '链接数'],
      ['tableChars', '表格区字符'],
      ['imgRuns', '图片 run 数']
    ]
    for (const [key, label] of fields) {
      assert.equal(m[key], o[key], `${label}不一致：官方 ${o[key]} vs 解析 ${m[key]}`)
    }
    // 颜色统计：官方颜色 class 名 = BBCode 颜色值，直接可比
    const oColors: string[] = Object.keys(o).filter((k: string) => k.startsWith('color:') || k.startsWith('sz:'))
    for (const k of oColors) {
      assert.equal(m[k], o[k], `样式 ${k} 不一致：官方 ${o[k]} vs 解析 ${m[k]}`)
    }
  })

  it('颜色与字号分布与官方一致', () => {
    const o = countStyles(officialData.runs)
    const m = countStyles(ourRuns)
    // 颜色：red/indigo 等；字号：150 等——从 run 直接统计
    const oColorCounts: Record<string, number> = {}
    const mColorCounts: Record<string, number> = {}
    const oSizeCounts: Record<string, number> = {}
    const mSizeCounts: Record<string, number> = {}
    for (const r of officialData.runs) {
      if (r.k !== 'text') continue
      const n: number = r.t.length
      if (r.c.length > 0) oColorCounts[r.c] = (oColorCounts[r.c] ?? 0) + n
      if (r.sz > 0) oSizeCounts[String(r.sz)] = (oSizeCounts[String(r.sz)] ?? 0) + n
    }
    for (const r of ourRuns) {
      if (r.k !== 'text') continue
      const n: number = r.t.length
      if (r.c.length > 0) mColorCounts[r.c] = (mColorCounts[r.c] ?? 0) + n
      if (r.sz > 0) mSizeCounts[String(r.sz)] = (mSizeCounts[String(r.sz)] ?? 0) + n
    }
    for (const c of new Set([...Object.keys(oColorCounts), ...Object.keys(mColorCounts)])) {
      assert.equal(mColorCounts[c] ?? 0, oColorCounts[c] ?? 0, `颜色 ${c} 字符数不一致：官方 ${oColorCounts[c] ?? 0} vs 解析 ${mColorCounts[c] ?? 0}`)
    }
    for (const s of new Set([...Object.keys(oSizeCounts), ...Object.keys(mSizeCounts)])) {
      assert.equal(mSizeCounts[s] ?? 0, oSizeCounts[s] ?? 0, `字号 ${s}% 字符数不一致：官方 ${oSizeCounts[s] ?? 0} vs 解析 ${mSizeCounts[s] ?? 0}`)
    }
    void o
    void m
  })

  it('锚点样式链与官方一致（精确验证关键句子完整样式）', () => {
    const anchors: string[] = ['12.0开始了~~~', '破法者的掩蔽', '萨拉斯竞争者', 'P.O.W.x3', '魔导师的法力之剑', '熔铸活力']
    const findRun = (runs: OfficialRun[], anchor: string): OfficialRun | null => {
      for (const r of runs) {
        if (r.k === 'text' && r.t.includes(anchor)) return r
      }
      return null
    }
    for (const anchor of anchors) {
      const o = findRun(officialData.runs, anchor)
      const m = findRun(ourRuns, anchor)
      if (o === null) {
        // 官方未渲染（collapse 内容服务端截断）→ 解析树侧另行验证
        continue
      }
      assert.ok(m !== null, `锚点 "${anchor}" 在解析树 run 中缺失`)
      if (m === null) continue
      assert.equal(m.b, o.b, `锚点 "${anchor}" 粗体不一致`)
      assert.equal(m.i, o.i, `锚点 "${anchor}" 斜体不一致`)
      assert.equal(m.u, o.u, `锚点 "${anchor}" 下划线不一致`)
      assert.equal(m.st, o.st, `锚点 "${anchor}" 删除线不一致`)
      assert.equal(m.c, o.c, `锚点 "${anchor}" 颜色不一致：官方 ${o.c} vs 解析 ${m.c}`)
      assert.equal(m.sz, o.sz, `锚点 "${anchor}" 字号不一致：官方 ${o.sz} vs 解析 ${m.sz}`)
      assert.equal(m.tbl, o.tbl, `锚点 "${anchor}" 表格位置不一致`)
    }
  })

  it('表格结构与官方一致', () => {
    const countType = (ns: BBNode[], type: BBNodeType): number => {
      let n: number = 0
      for (const node of ns) {
        if (node.type === type) n++
        n += countType(node.children, type)
      }
      return n
    }
    assert.equal(countType(nodes, BBNodeType.TABLE), 4, 'TABLE 数量应为 4')
    assert.equal(countType(nodes, BBNodeType.TABLE_CELL), 750, 'TABLE_CELL 数量应为 750（官方 td 数）')
    if (officialData.tdCount !== undefined) {
      assert.equal(countType(nodes, BBNodeType.TABLE_CELL), officialData.tdCount,
        `TABLE_CELL 数 ${countType(nodes, BBNodeType.TABLE_CELL)} 与官方 td 数 ${officialData.tdCount} 不一致`)
    }
  })

  it('collapse 折叠内容完整保留（官方网页截断，仅解析树侧验证）', () => {
    const collapseText: string = collectCollapseText(nodes)
    const phrases: string[] = ['熔铸活力', '12.0所有材料和公函', '神话纹章：可升级276-289装备']
    for (const phrase of phrases) {
      assert.ok(collapseText.includes(phrase), `collapse 内容缺失: ${phrase}`)
    }
    assert.ok(collapseText.length > 400, `collapse 内容过短: ${collapseText.length}`)
  })
})
