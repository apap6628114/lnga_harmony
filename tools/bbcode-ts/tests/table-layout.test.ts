import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { parseBBCode } from '../src/parser/bbcode/parser'
import { BBNode, BBNodeType } from '../src/model/BBCodeNode'
import {
  buildTableLayout,
  TableLayout,
  TableLayoutCell,
  TableLayoutRow,
} from '../src/common/components/bbcode/table-layout'
import { loadSampleContent } from './helpers'

/**
 * 从输入正文中取得第一张表格。
 *
 * @param content BBCode 正文
 * @returns 第一张表格节点
 */
function parseFirstTable(content: string): BBNode {
  const nodes: BBNode[] = parseBBCode(content)
  for (let index: number = 0; index < nodes.length; index++) {
    if (nodes[index].type === BBNodeType.TABLE) return nodes[index]
  }
  assert.fail('未找到 TABLE 节点')
}

/**
 * 断言每个布局行都从第 0 列连续覆盖到最终列数。
 *
 * @param layout 已归一化表格布局
 */
function assertRowsAreStrict(layout: TableLayout): void {
  for (let rowIndex: number = 0; rowIndex < layout.rows.length; rowIndex++) {
    const row: TableLayoutRow = layout.rows[rowIndex]
    let cursor: number = 0
    for (let cellIndex: number = 0; cellIndex < row.cells.length; cellIndex++) {
      const cell: TableLayoutCell = row.cells[cellIndex]
      assert.equal(cell.columnStart, cursor, `第 ${rowIndex} 行第 ${cellIndex} 个片段前存在缺口`)
      cursor += cell.columnSpan
    }
    assert.equal(cursor, layout.columnCount, `第 ${rowIndex} 行未覆盖完整列宽`)
  }
}

describe('非严格表格逻辑网格归一化', () => {
  it('rowspan 占用后续行的原列并只在中间逻辑行渲染内容', () => {
    const table: BBNode = parseFirstTable(
      '[table][tr][td rowspan=2]合并行[/td][td]普通[/td][/tr][tr][td]第二行[/td][/tr][/table]')
    const layout: TableLayout = buildTableLayout(table)

    assert.equal(layout.columnCount, 2)
    assert.equal(layout.rows.length, 2)
    assertRowsAreStrict(layout)
    assert.equal(layout.rows[0].cells[0].rendersContent, false)
    assert.equal(layout.rows[1].cells[0].rendersContent, true)
    assert.equal(layout.rows[1].cells[0].connectsAbove, true)
    assert.equal(layout.rows[1].cells[1].columnStart, 1)
    assert.equal(layout.rows[1].cells[1].rendersContent, true)
  })

  it('奇数 rowspan 的内容位于唯一的中央行', () => {
    const table: BBNode = parseFirstTable(
      '[table][tr][td rowspan=3]合并行[/td][td]甲[/td][/tr]' +
      '[tr][td]乙[/td][/tr][tr][td]丙[/td][/tr][/table]')
    const layout: TableLayout = buildTableLayout(table)

    assert.equal(layout.rows[0].cells[0].rendersContent, false)
    assert.equal(layout.rows[1].cells[0].rendersContent, true)
    assert.equal(layout.rows[2].cells[0].rendersContent, false)
  })

  it('rowspan 与 colspan 组合时保留连续的矩形占用区', () => {
    const table: BBNode = parseFirstTable(
      '[table][tr][td rowspan=2 colspan=2]合并[/td][td]右上[/td][/tr][tr][td]右下[/td][/tr][/table]')
    const layout: TableLayout = buildTableLayout(table)

    assert.equal(layout.columnCount, 3)
    assertRowsAreStrict(layout)
    assert.equal(layout.rows[1].cells[0].columnSpan, 2)
    assert.equal(layout.rows[1].cells[1].columnStart, 2)
  })

  it('列数不足的畸形行补空白片段且不复制正文', () => {
    const table: BBNode = parseFirstTable(
      '[table][tr][td]甲[/td][td]乙[/td][td]丙[/td][/tr][tr][td]丁[/td][/tr][/table]')
    const layout: TableLayout = buildTableLayout(table)

    assert.equal(layout.columnCount, 3)
    assertRowsAreStrict(layout)
    assert.equal(layout.rows[1].cells.length, 2)
    assert.equal(layout.rows[1].cells[1].node, null)
    assert.equal(layout.rows[1].cells[1].columnSpan, 2)
  })

  it('demo.txt 第一张复杂表格归一化为严格七列', () => {
    const table: BBNode = parseFirstTable(loadSampleContent('demo.txt'))
    const layout: TableLayout = buildTableLayout(table)

    assert.equal(layout.columnCount, 7)
    assert.ok(layout.rows.length > 40)
    assertRowsAreStrict(layout)
    assert.ok(layout.rows.some((row: TableLayoutRow): boolean =>
      row.cells.some((cell: TableLayoutCell): boolean => cell.connectsAbove)))
  })
})
