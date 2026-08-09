import {
  loadPairNames, loadPair, loadPairGaps, analyzePair,
  PairReport, PairGaps, RowCoverage,
} from '../tests/html-coverage'

/**
 * HTML 模式 → JSON 覆盖对比（人类可读报告版）。
 *
 * 输入：samples/html-pairs.lst 登记的成对样本（JSON API 响应 + read.php 原始 HTML）。
 * 以 JSON 为基准，输出 HTML 模式解析结果的覆盖情况：
 *
 * 1. 楼层集合与元数据字段逐楼对比（pid/authorid/postdate/score/from_client 等）
 * 2. 正文文本覆盖率（JSON BBCode 纯文本在 HTML 渲染文本中的保留度）+ 未覆盖片段
 * 3. 附件覆盖（数量与 URL 命中）
 * 4. 用户表 __U（UID 集合、交集用户名、字段出现率）
 * 5. 线程/分页元数据（主题标题/作者/版块/__ROWS/__PAGE）
 * 6. 缺失字段清单（JSON 有值但 HTML 输出无法提供的字段，按出现次数排序）
 * 7. 结构清单（表格/折叠/列表等：JSON 侧真值 vs HTML 渲染后经解析器可恢复的量）
 *
 * 自动化断言见 tests/html-mode-coverage.test.ts；本脚本输出完整人类可读报告。
 *
 * 运行：npm run build && node dist/scripts/compare-html-json.js
 */

function pct(n: number): string {
  return (n * 100).toFixed(1) + '%'
}

function printRowTable(report: PairReport): void {
  console.log('--- 楼层明细（JSON 为基准） ---')
  const header: string = 'lou | 页面行 | 楼层存在 | 正文覆盖率 | 附件 J/H | 元数据不一致字段'
  console.log(header)
  console.log('-'.repeat(header.length))
  for (const row of report.rows) {
    const badFields: string[] = row.fields
      .filter((f): boolean => f.jsonHas && f.htmlHas && f.equal === false)
      .map((f): string => f.field)
    const missingFields: string[] = row.fields
      .filter((f): boolean => f.jsonHas && !f.htmlHas)
      .map((f): string => f.field + '(缺)')
    const bad: string[] = badFields.concat(missingFields)
    const cov: string = row.content.jsonHasContent ? pct(row.content.textCoverage) : '无正文'
    const rowLou: string = row.htmlRowLou !== row.lou ? `${row.htmlRowLou}(映射)` : String(row.htmlRowLou)
    const hotInfo: string = row.hotreply.jsonCount > 0
      ? ` | 热点回复 ${row.hotreply.jsonCount}/${row.hotreply.htmlCount}${row.hotreply.mismatches.length > 0 ? ' 不一致' : ''}`
      : ''
    console.log(`${row.lou} | ${rowLou} | ${row.foundInHtml ? '✓' : '✗ 缺失!'} | ${cov}` +
      ` | ${row.attach.jsonCount}/${row.attach.htmlCount} | ${bad.join(',') || '-'}${hotInfo}`)
    for (const m of row.hotreply.mismatches) {
      console.log(`   热点回复差异: ${m}`)
    }
    if (row.content.jsonHasContent && row.content.textCoverage < 1 && row.content.missingText.length > 0) {
      console.log(`   未覆盖文本片段: "${row.content.missingText}"`)
    }
  }
  if (report.rows.length === 0) console.log('（JSON 响应无楼层行）')
}

function printFieldMatrix(report: PairReport): void {
  console.log('--- 楼层元数据字段总体一致性（JSON 有值楼层为基数） ---')
  for (const agg of report.fieldAgg) {
    if (agg.jsonHas === 0) continue
    const icon: string = agg.mismatch === 0 && agg.htmlHas === agg.jsonHas ? '✓' : '✗'
    console.log(`  ${icon} ${agg.field}: JSON 有值 ${agg.jsonHas} 楼 | HTML 有值 ${agg.htmlHas} 楼 | 值一致 ${agg.equal} | 不一致 ${agg.mismatch}`)
  }
}

function printUserCoverage(report: PairReport): void {
  console.log('--- 用户表 __U 覆盖 ---')
  console.log(`  JSON UID: ${report.users.jsonCount} | HTML UID: ${report.users.htmlCount} | 交集: ${report.users.matched}`)
  if (report.users.usernameMismatch.length > 0) {
    for (const m of report.users.usernameMismatch) {
      console.log(`  ✗ uid=${m.uid} 用户名 JSON="${m.json}" vs HTML="${m.html}"`)
    }
  } else if (report.users.matched > 0) {
    console.log('  ✓ 交集 UID 用户名全部一致')
  }
  for (const f of report.users.fieldPresence) {
    if (f.total === 0) continue
    const missing: number = f.jsonHas - f.htmlHas
    const icon: string = missing <= 0 ? '✓' : '✗'
    console.log(`  ${icon} 用户字段 ${f.field}: JSON 有值 ${f.jsonHas}/${f.total} | HTML 有值 ${f.htmlHas}/${f.total}` +
      (missing > 0 ? ` | 缺失 ${missing}` : ''))
  }
}

function printMissingFields(report: PairReport): void {
  console.log('--- 缺失字段清单（JSON 有值但 HTML 行中无此字段，按出现楼数排序） ---')
  if (report.missingFields.length === 0) {
    console.log('  （无）')
    return
  }
  for (const m of report.missingFields) {
    console.log(`  ✗ ${m.field}: ${m.count} 楼`)
  }
}

function printStructure(report: PairReport): void {
  console.log('--- 结构清单（表格/折叠等：JSON 真值 vs HTML 渲染后经解析器可恢复量） ---')
  const s = report.jsonStructure
  const h = report.htmlStructure
  console.log(`  表格 TABLE: JSON ${s.table} | HTML 解析 ${h.table}`)
  console.log(`  单元格 TABLE_CELL: JSON ${s.tableCell} | HTML 解析 ${h.tableCell}`)
  console.log(`  折叠 COLLAPSE: JSON ${s.collapse} | HTML 解析 ${h.collapse}`)
  console.log(`  列表 LIST: JSON ${s.list} | HTML 解析 ${h.list}`)
  console.log(`  图片 IMAGE: JSON ${s.image} | HTML 解析 ${h.image}`)
  console.log(`  链接 URL: JSON ${s.url} | HTML 解析 ${h.url}`)
  console.log(`  引用 QUOTE: JSON ${s.quote} | HTML 解析 ${h.quote}`)
}

function printPair(report: PairReport): void {
  console.log(`\n================ ${report.name} ================`)
  if (report.gaps && report.gaps.note) {
    console.log(`[已知缺口] ${report.gaps.note}`)
  }
  const rowsCov: number = report.rows.length > 0
    ? (report.rows.length - report.missingRowLous.length) / report.rows.length
    : 0
  const texts: RowCoverage[] = report.rows.filter((r: RowCoverage): boolean => r.content.jsonHasContent)
  const textAvg: number = texts.length > 0
    ? texts.reduce((a: number, r: RowCoverage): number => a + r.content.textCoverage, 0) / texts.length
    : 1
  console.log(`楼层覆盖: ${report.rows.length - report.missingRowLous.length}/${report.rows.length} (${pct(rowsCov)})` +
    ` | 正文文本平均覆盖: ${pct(textAvg)}`)
  console.log(`线程: 主题标题 ${report.thread.subjectEqual === true ? '✓' : report.thread.subjectEqual === false ? '✗' : '-'}` +
    ` | 作者 ${report.thread.authorEqual === true ? '✓' : report.thread.authorEqual === false ? '✗' : '-'}` +
    ` | 版块 ${report.thread.forumEqual === true ? '✓' : report.thread.forumEqual === false ? '✗' : '-'}`)
  console.log(`分页: __ROWS JSON=${report.paging.rowsJson} HTML=${report.paging.rowsHtml}` +
    ` | __PAGE JSON=${report.paging.pageJson} HTML=${report.paging.pageHtml}` +
    ` | __T.lastpost ${report.thread.lastpostJson === report.thread.lastpostHtml ? '✓' : '✗'} JSON=${report.thread.lastpostJson} HTML=${report.thread.lastpostHtml}`)
  printRowTable(report)
  printFieldMatrix(report)
  printUserCoverage(report)
  printMissingFields(report)
  printStructure(report)
}

const names: string[] = loadPairNames()
if (names.length === 0) {
  console.log('samples/html-pairs.lst 无成对样本。')
  console.log('先运行: NGA_COOKIE=<document.cookie> node scripts/fetch-thread-pair.mjs <tid> [page]')
  process.exit(0)
}

const allGaps: Record<string, PairGaps> = loadPairGaps()
for (const name of names) {
  printPair(analyzePair(loadPair(name), allGaps[name]))
}
