import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  loadTopicPairNames, loadTopicPair, loadTopicPairGaps, analyzeTopicPair, TopicPairGaps,
} from './html-topic-coverage'

/** 与 html-mode-coverage.test.ts 相同的正文文本覆盖率阈值。 */
const CONTENT_COVERAGE_THRESHOLD: number = 0.9

/**
 * HTML 主题列表 → JSON 数据覆盖验证测试。
 *
 * 数据来源：samples/html-topicpairs.lst 登记的成对样本
 * （thread.php?lite=js JSON + thread.php 原始 HTML，同 authorid 同 page 同模式）。
 *
 * 以 JSON API 为基准真值，把 HTML 模式解析结果（parseHtmlTopicListToRawJson 镜像）
 * 与之逐条目/逐字段对比，断言"本应一致"的不变量：
 *
 * 1. 条目集合覆盖：JSON 每索引键在 HTML 输出中均有对应（HTML 模式漏条目 = 失败）
 * 2. 条目字段一致：tid/fid/subject/author/authorid/postdate/lastpost/replies/lastposter/
 *    type/topic_misc/quote_from/parent（HTML 与 JSON 同源于页面 topicArg 数据，必须一致）
 * 3. 回帖正文：__P.tid/__P.pid/__P.authorid/__P.subject 严格一致；
 *    __P.content 文本覆盖率 ≥90%（JSON 可见文字在 HTML 正文中的保留度）
 * 4. 反向：HTML 输出不应有多余条目
 *
 * 已知缺口声明（samples/html-topicpair-gaps.json）：
 * - __P.postdate：静态页面无回复时间（官方网页版亦不显示）
 * - __P.type：postDispMini 第 7 参恒为 0
 * - 占位条目（subject 含「超过限制/帐号权限不足」）的 tid/fid/__P.tid/__P.pid
 *   为服务端占位符（HTML 与 JSON 各给一套假值），自动豁免
 *
 * 无样本时不失败：先抓取并登记成对样本后再生效。
 */

const pairNames: string[] = loadTopicPairNames()
const gaps: TopicPairGaps = loadTopicPairGaps()

describe('HTML 主题列表 → JSON 覆盖验证', () => {
  it('成对样本存在（先抓取 thread.php 成对样本并登记 html-topicpairs.lst）',
    { skip: pairNames.length === 0 },
    () => {
      assert.ok(pairNames.length > 0, '无 html-topicpairs.lst 样本，跳过')
    })
})

for (const name of pairNames) {
  describe(`主题列表覆盖验证（${name}）`, () => {
    const report = analyzeTopicPair(loadTopicPair(name), gaps)

    it('条目集合覆盖：JSON 每索引在 HTML 输出中均有对应，且无多余条目', () => {
      assert.equal(report.missingJsonEntries.length, 0,
        `HTML 模式缺失条目索引=${report.missingJsonEntries.join(',')}（JSON 有而 HTML 输出无）`)
      assert.equal(report.extraHtmlEntries.length, 0,
        `HTML 模式多余条目索引=${report.extraHtmlEntries.join(',')}（JSON 无此索引）`)
    })

    it('条目字段一致（tid/fid/subject/author/authorid/postdate/lastpost/replies/lastposter/type/topic_misc/quote_from/parent）', () => {
      const mismatches: string[] = []
      for (const row of report.rows) {
        for (const m of row.fieldMismatches) {
          mismatches.push(`[${row.index}].${m.field}: JSON="${m.jsonValue}" vs HTML="${m.htmlValue}"`)
        }
      }
      assert.equal(mismatches.length, 0,
        `条目字段不一致（HTML 与 JSON 同源于 topicArg，不应有差异）：\n${mismatches.join('\n')}`)
    })

    it(`回帖正文文本覆盖率 ≥ ${CONTENT_COVERAGE_THRESHOLD * 100}%（JSON 可见文字在 HTML 正文中的保留度）`, () => {
      const low: Array<{ index: string; ratio: number }> = []
      for (const row of report.rows) {
        if (row.jsonHasP && row.contentCoverage < CONTENT_COVERAGE_THRESHOLD) {
          low.push({ index: row.index, ratio: row.contentCoverage })
        }
      }
      assert.equal(low.length, 0,
        `以下条目回帖正文文本覆盖不足（阈值 ${CONTENT_COVERAGE_THRESHOLD}）：\n` +
        low.map((l: { index: string; ratio: number }): string =>
          `  [${l.index}] 覆盖率 ${(l.ratio * 100).toFixed(1)}%`).join('\n'))
    })
  })
}

