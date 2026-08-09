import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  loadPairNames, loadPair, loadPairGaps, analyzePair, PairGaps,
} from './html-coverage'

/**
 * HTML 模式 → JSON 数据覆盖验证测试。
 *
 * 数据来源：samples/html-pairs.lst 登记的成对样本
 * （scripts/fetch-thread-pair.mjs 抓取：JSON API 响应 + read.php 原始 HTML，同 tid 同 page）。
 *
 * 以 JSON API（__output=8）为基准真值，把 HTML 模式解析结果（parseHtmlToRawJson 镜像）
 * 与之逐楼层/逐字段对比，断言"本应一致"的不变量：
 *
 * 1. 楼层集合覆盖：JSON 每楼在 HTML 输出中均有对应（HTML 模式漏楼层 = 失败）
 * 2. 楼层元数据一致：pid/authorid/postdatetimestamp/type/score/score_2/content_length/
 *    from_client 等字段（HTML 与 JSON 同源于页面 JS postArg 数据，必须一致）
 * 3. 正文文本覆盖：JSON content 纯文本去空白后 ≥90% 字符在 HTML content 纯文本中出现
 *    （HTML 渲染会丢样式/结构，但可见文字原则上应保留；阈值见 TEXT_COVERAGE_THRESHOLD）
 * 4. 用户表 __U：交集 UID 的用户名必须一致
 * 5. 线程/分页：主题标题、__ROWS、__PAGE 一致
 *
 * 已知缺口声明（samples/html-pair-gaps.json）：read.php 页面存在"隐楼"行为
 * （被隐藏楼层不渲染但行号继续递增，后续楼层行号错位），HTML 模式无法恢复真实
 * lou 号，样本级 rowShift 映射把页面行号对齐到 JSON lou 后再断言。声明之外的
 * 新增缺口会导致断言失败（套件告警）。
 *
 * 已知会丢失的维度（渲染后 HTML 无法恢复，报告而非断言）：
 * - 结构：表格/折叠/列表/图片/链接（见 compare-html-json.ts 结构清单）
 * - 字段：hotreply（热门回复）/ comment（楼中楼评论）/ signature / js_escap_avatar 等
 *   （JSON 有值而 HTML 输出无此字段，统计进 missingFields 报告）
 * - __U 用户字段：avatar/signature/mute_time/__GROUPS 页面 setAll 不提供
 * - alterinfo（如"主楼"标记）：HTML 行硬编码为空
 *
 * 无样本时不失败：先运行 scripts/fetch-thread-pair.mjs 抓取并登记后再生效。
 */

/** 正文文本覆盖率阈值（去空白贪心子序列匹配率）。 */
const TEXT_COVERAGE_THRESHOLD: number = 0.9

/** 断言严格的楼层元数据字段（HTML 与 JSON 同源，必须一致）。 */
const STRICT_FIELDS: string[] = [
  'pid', 'fid', 'authorid', 'postdatetimestamp', 'type', 'score', 'score_2',
  'content_length', 'from_client',
]

const pairNames: string[] = loadPairNames()
const pairGaps: Record<string, PairGaps> = loadPairGaps()

describe('HTML 模式 → JSON 覆盖验证', () => {
  it('成对样本存在（先运行 fetch-thread-pair.mjs 抓取）', { skip: pairNames.length === 0 },
    () => {
      assert.ok(pairNames.length > 0, '无 html-pairs.lst 样本，跳过（抓取方法见 README）')
    })
})

for (const name of pairNames) {
  describe(`覆盖验证（${name}）`, () => {
    const report = analyzePair(loadPair(name), pairGaps[name])

    it('楼层集合覆盖：JSON 每楼在 HTML 输出中均有对应', () => {
      assert.equal(report.missingRowLous.length, 0,
        `HTML 模式缺失楼层 lou=${report.missingRowLous.join(',')}（JSON 有而 HTML 输出无）`)
    })

    it('楼层元数据一致（pid/fid/authorid/postdatetimestamp/type/score/score_2/content_length/from_client）', () => {
      const mismatches: string[] = []
      for (const row of report.rows) {
        for (const f of row.fields) {
          if (!STRICT_FIELDS.includes(f.field)) continue
          if (f.jsonHas && f.htmlHas && f.equal === false) {
            mismatches.push(`lou${row.lou}.${f.field}: JSON="${f.jsonValue}" vs HTML="${f.htmlValue}"`)
          } else if (f.jsonHas && !f.htmlHas) {
            mismatches.push(`lou${row.lou}.${f.field}: JSON 有值但 HTML 缺失`)
          }
        }
      }
      assert.equal(mismatches.length, 0,
        `楼层元数据不一致（HTML 与 JSON 同源于 postArg，不应有差异）：\n${mismatches.join('\n')}`)
    })

    it(`正文文本覆盖率 ≥ ${TEXT_COVERAGE_THRESHOLD * 100}%（JSON 可见文字在 HTML 渲染中的保留度）`, () => {
      const low: Array<{ lou: number; ratio: number; missing: string }> = []
      for (const row of report.rows) {
        if (row.content.jsonHasContent && row.content.textCoverage < TEXT_COVERAGE_THRESHOLD) {
          low.push({ lou: row.lou, ratio: row.content.textCoverage, missing: row.content.missingText })
        }
      }
      assert.equal(low.length, 0,
        `以下楼层 HTML 模式正文文本覆盖不足（阈值 ${TEXT_COVERAGE_THRESHOLD}）：\n` +
        low.map((l: { lou: number; ratio: number; missing: string }): string =>
          `  lou${l.lou} 覆盖率 ${(l.ratio * 100).toFixed(1)}% 未覆盖片段: "${l.missing}"`).join('\n'))
    })

    it('用户表 __U：交集 UID 用户名一致', () => {
      const mm: Array<{ uid: string; json: string; html: string }> = report.users.usernameMismatch
      assert.equal(mm.length, 0,
        `用户名不一致：\n${mm.map((m: { uid: string; json: string; html: string }): string =>
          `  uid=${m.uid} JSON="${m.json}" vs HTML="${m.html}"`).join('\n')}`)
    })

    it('热点回复（hotreply）还原：JSON 有 hotreply 的楼必须完整还原', () => {
      const missing: Array<{ lou: number; jsonCount: number; htmlCount: number; mismatches: string[] }> = []
      for (const row of report.rows) {
        if (row.hotreply.jsonCount === 0) continue
        if (row.hotreply.htmlCount === 0 || row.hotreply.mismatches.length > 0) {
          missing.push({ lou: row.lou, jsonCount: row.hotreply.jsonCount, htmlCount: row.hotreply.htmlCount, mismatches: row.hotreply.mismatches })
        }
      }
      assert.equal(missing.length, 0,
        `热点回复还原失败（HTML 模式应尽力从 hightlight_for 容器恢复）：\n` +
        missing.map((m: { lou: number; jsonCount: number; htmlCount: number; mismatches: string[] }): string =>
          `  lou${m.lou} JSON ${m.jsonCount} 条 vs HTML ${m.htmlCount} 条${m.mismatches.length > 0 ? '\n    ' + m.mismatches.join('\n    ') : ''}`).join('\n'))
    })

    it('线程/分页元数据一致（主题标题/__ROWS/__PAGE）', () => {
      assert.equal(report.thread.subjectEqual, true,
        `主题标题不一致：JSON="${report.thread.subjectJson}" vs HTML="${report.thread.subjectHtml}"`)
      assert.equal(report.paging.rowsJson, report.paging.rowsHtml,
        `__ROWS 不一致：JSON=${report.paging.rowsJson} vs HTML=${report.paging.rowsHtml}`)
      assert.equal(report.paging.pageJson, report.paging.pageHtml,
        `__PAGE 不一致：JSON=${report.paging.pageJson} vs HTML=${report.paging.pageHtml}`)
    })
  })
}
