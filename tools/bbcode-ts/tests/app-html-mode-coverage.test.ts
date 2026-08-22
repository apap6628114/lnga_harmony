import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { analyzePair, loadPair, loadPairNames } from './html-coverage'

/** APP HTML 正文最低文本覆盖率。 */
const TEXT_COVERAGE_THRESHOLD: number = 0.9

/** APP HTML 必须与网页 JSON 一致的楼层字段。 */
const STRICT_FIELDS: string[] = [
  'pid', 'fid', 'authorid', 'postdatetimestamp', 'type', 'score', 'score_2',
  'content_length', 'from_client',
]

/** APP HTML 成对样本清单。 */
const pairNames: string[] = loadPairNames('app-html-pairs.lst')

/**
 * 官方 APP HTML 与网页 JSON 对照回归。
 */
describe('APP output=17 HTML → 网页 JSON 覆盖验证', () => {
  it('成对样本存在', { skip: pairNames.length === 0 }, () => {
    assert.ok(pairNames.length > 0)
  })
})

for (const name of pairNames) {
  describe(`APP 覆盖验证（${name}）`, () => {
    const report = analyzePair(loadPair(name))

    it('普通楼层集合与严格元数据一致', () => {
      const mismatches: string[] = []
      for (const row of report.rows) {
        for (const field of row.fields) {
          if (!STRICT_FIELDS.includes(field.field)) {
            continue
          }
          if (field.jsonHas && (!field.htmlHas || field.equal === false)) {
            mismatches.push(
              `lou${row.lou}.${field.field}: JSON="${field.jsonValue}" APP="${field.htmlValue}"`)
          }
        }
      }
      assert.equal(report.missingRowLous.length, 0,
        `APP HTML 缺楼层: ${report.missingRowLous.join(',')}`)
      assert.equal(mismatches.length, 0, mismatches.join('\n'))
    })

    it('正文可见文本覆盖率达标', () => {
      const low = report.rows.filter((row) =>
        row.content.jsonHasContent && row.content.textCoverage < TEXT_COVERAGE_THRESHOLD)
      assert.equal(low.length, 0,
        low.map((row) => `lou${row.lou}: ${(row.content.textCoverage * 100).toFixed(1)}%`).join('\n'))
    })

    it('主题、分页与用户名称一致', () => {
      assert.equal(report.thread.subjectEqual, true)
      assert.equal(report.thread.authorEqual, true)
      assert.equal(report.thread.forumEqual, true)
      assert.equal(report.thread.lastpostHtml, report.thread.lastpostJson)
      assert.equal(report.paging.rowsHtml, report.paging.rowsJson)
      assert.equal(report.paging.pageHtml, report.paging.pageJson)
      assert.equal(report.users.usernameMismatch.length, 0)
    })

    it('楼中楼贴条完整恢复', () => {
      const failures: string[] = []
      for (const row of report.rows) {
        if (row.comment.jsonCount !== row.comment.htmlCount || row.comment.mismatches.length > 0) {
          failures.push(
            `lou${row.lou}: JSON=${row.comment.jsonCount} APP=${row.comment.htmlCount} ` +
            row.comment.mismatches.join('; '))
        }
      }
      assert.equal(failures.length, 0, failures.join('\n'))
    })
  })
}
