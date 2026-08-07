import { BBNode, BBNodeType } from '../../../model/BBCodeNode'

/** 单个语义单元格允许占用的最大逻辑列数，避免畸形属性造成超大循环。 */
const MAX_TABLE_COLUMN_SPAN: number = 256

/**
 * 已归一化的表格渲染单元格。
 */
export class TableLayoutCell {
  /** 原始语义单元格；缺失位置的占位片段为 null。 */
  node: BBNode | null = null
  /** 当前渲染片段的稳定键。 */
  key: string = ''
  /** 当前片段起始列，从 0 开始。 */
  columnStart: number = 0
  /** 当前片段占用的列数。 */
  columnSpan: number = 1
  /** 当前片段是否渲染原始单元格内容。 */
  rendersContent: boolean = false
  /** 当前片段是否与上一行的同一跨行单元格相连。 */
  connectsAbove: boolean = false
  /** 当前片段是否与下一行的同一跨行单元格相连。 */
  connectsBelow: boolean = false

  /**
   * 创建一个归一化表格渲染片段。
   *
   * @param node 原始单元格节点
   * @param key 稳定键
   * @param columnStart 起始列
   * @param columnSpan 跨列数
   * @param rendersContent 是否渲染内容
   * @param connectsAbove 是否连接上一行
   * @param connectsBelow 是否连接下一行
   */
  constructor(node: BBNode | null, key: string, columnStart: number, columnSpan: number,
    rendersContent: boolean, connectsAbove: boolean, connectsBelow: boolean) {
    this.node = node
    this.key = key
    this.columnStart = columnStart
    this.columnSpan = columnSpan
    this.rendersContent = rendersContent
    this.connectsAbove = connectsAbove
    this.connectsBelow = connectsBelow
  }
}

/**
 * 已归一化的表格渲染行。
 */
export class TableLayoutRow {
  /** 当前渲染行的稳定键。 */
  key: string = ''
  /** 按真实列位置排序且已补齐缺口的渲染片段。 */
  cells: TableLayoutCell[] = []

  /**
   * 创建一个归一化表格渲染行。
   *
   * @param key 稳定键
   */
  constructor(key: string) {
    this.key = key
  }
}

/**
 * 表格的严格逻辑网格布局。
 */
export class TableLayout {
  /** 已归一化的渲染行。 */
  rows: TableLayoutRow[] = []
  /** 表格占用的逻辑列数。 */
  columnCount: number = 0
}

/**
 * 当前行仍被占用的跨行单元格。
 */
class ActiveTableSpan {
  /** 原始语义单元格。 */
  node: BBNode
  /** 起始列。 */
  columnStart: number
  /** 跨列数。 */
  columnSpan: number
  /** 最后一个仍被占用的行下标。 */
  endRow: number
  /** 唯一渲染原始内容的中间逻辑行下标。 */
  contentRow: number

  /**
   * 创建一个跨行占用记录。
   *
   * @param node 原始语义单元格
   * @param columnStart 起始列
   * @param columnSpan 跨列数
   * @param endRow 结束行下标
   * @param contentRow 内容渲染行下标
   */
  constructor(node: BBNode, columnStart: number, columnSpan: number, endRow: number,
    contentRow: number) {
    this.node = node
    this.columnStart = columnStart
    this.columnSpan = columnSpan
    this.endRow = endRow
    this.contentRow = contentRow
  }
}

/**
 * 把缺省或无效 span 归一化为 1。
 *
 * @param value 原始 span
 * @returns 至少为 1 的 span
 */
function normalizeRowSpan(value: number): number {
  return value > 1 ? value : 1
}

/**
 * 把缺省或无效跨列数归一化为 1，并限制畸形输入的布局开销。
 *
 * @param value 原始跨列数
 * @returns 安全范围内的跨列数
 */
function normalizeColumnSpan(value: number): number {
  return Math.min(value > 1 ? value : 1, MAX_TABLE_COLUMN_SPAN)
}

/**
 * 标记一段逻辑列已经被当前行的单元格占用。
 *
 * @param occupied 当前行的列占用表
 * @param columnStart 起始列
 * @param columnSpan 跨列数
 */
function markColumnsOccupied(occupied: boolean[], columnStart: number, columnSpan: number): void {
  const end: number = columnStart + columnSpan
  for (let column: number = columnStart; column < end; column++) occupied[column] = true
}

/**
 * 判断从指定列开始的连续区域是否空闲。
 *
 * @param occupied 当前行的列占用表
 * @param columnStart 起始列
 * @param columnSpan 跨列数
 * @returns 连续区域是否空闲
 */
function areColumnsAvailable(occupied: boolean[], columnStart: number, columnSpan: number): boolean {
  const end: number = columnStart + columnSpan
  for (let column: number = columnStart; column < end; column++) {
    if (occupied[column] === true) return false
  }
  return true
}

/**
 * 从给定游标开始查找可容纳单元格的第一段连续空闲列。
 *
 * @param occupied 当前行的列占用表
 * @param cursor 搜索起点
 * @param columnSpan 所需连续列数
 * @returns 可用起始列
 */
function findAvailableColumn(occupied: boolean[], cursor: number, columnSpan: number): number {
  let columnStart: number = cursor
  while (!areColumnsAvailable(occupied, columnStart, columnSpan)) columnStart++
  return columnStart
}

/**
 * 创建缺失逻辑列的空白占位片段。
 *
 * @param rowKey 当前行稳定键
 * @param columnStart 起始列
 * @param columnSpan 跨列数
 * @returns 空白占位片段
 */
function createEmptyCell(rowKey: string, columnStart: number, columnSpan: number): TableLayoutCell {
  return new TableLayoutCell(null, `${rowKey}:empty:${columnStart}`, columnStart, columnSpan,
    false, false, false)
}

/**
 * 按最终列数补齐一行中的全部逻辑缺口。
 *
 * @param row 待补齐的渲染行
 * @param columnCount 表格最终列数
 */
function fillRowGaps(row: TableLayoutRow, columnCount: number): void {
  row.cells.sort((left: TableLayoutCell, right: TableLayoutCell): number =>
    left.columnStart - right.columnStart)
  const completed: TableLayoutCell[] = []
  let cursor: number = 0
  for (let index: number = 0; index < row.cells.length; index++) {
    const cell: TableLayoutCell = row.cells[index]
    if (cell.columnStart > cursor) {
      completed.push(createEmptyCell(row.key, cursor, cell.columnStart - cursor))
    }
    completed.push(cell)
    cursor = Math.max(cursor, cell.columnStart + cell.columnSpan)
  }
  if (cursor < columnCount) completed.push(createEmptyCell(row.key, cursor, columnCount - cursor))
  row.cells = completed
}

/**
 * 将非严格 BBCode 表格转换为每行列位置一致的逻辑网格。
 *
 * `rowspan` 占用的后续行会生成连接片段，内容只在跨度的中间逻辑行渲染一次；
 * 原文缺少的尾列或中间列会生成空白片段。归一化只服务于渲染，不修改解析树。
 *
 * @param table TABLE 语义节点
 * @returns 可直接按行渲染的严格逻辑网格
 */
export function buildTableLayout(table: BBNode): TableLayout {
  const layout = new TableLayout()
  const sourceRows: BBNode[] = []
  for (let childIndex: number = 0; childIndex < table.children.length; childIndex++) {
    const child: BBNode = table.children[childIndex]
    if (child.type === BBNodeType.TABLE_ROW) sourceRows.push(child)
  }

  let activeSpans: ActiveTableSpan[] = []
  for (let rowIndex: number = 0; rowIndex < sourceRows.length; rowIndex++) {
    const sourceRow: BBNode = sourceRows[rowIndex]
    const row = new TableLayoutRow(sourceRow.id.toString())
    const occupied: boolean[] = []
    const remainingSpans: ActiveTableSpan[] = []

    for (let activeIndex: number = 0; activeIndex < activeSpans.length; activeIndex++) {
      const active: ActiveTableSpan = activeSpans[activeIndex]
      if (active.endRow < rowIndex) continue
      row.cells.push(new TableLayoutCell(active.node,
        `${row.key}:continuation:${active.node.id}:${active.columnStart}`,
        active.columnStart, active.columnSpan, active.contentRow === rowIndex,
        true, active.endRow > rowIndex))
      markColumnsOccupied(occupied, active.columnStart, active.columnSpan)
      remainingSpans.push(active)
    }
    activeSpans = remainingSpans

    let cursor: number = 0
    for (let childIndex: number = 0; childIndex < sourceRow.children.length; childIndex++) {
      const cell: BBNode = sourceRow.children[childIndex]
      if (cell.type !== BBNodeType.TABLE_CELL) continue
      const columnSpan: number = normalizeColumnSpan(cell.colSpan)
      const remainingRowCount: number = sourceRows.length - rowIndex
      const rowSpan: number = Math.min(normalizeRowSpan(cell.rowSpan), remainingRowCount)
      const columnStart: number = findAvailableColumn(occupied, cursor, columnSpan)
      const endRow: number = rowIndex + rowSpan - 1
      const contentRow: number = rowIndex + Math.floor(rowSpan / 2)
      row.cells.push(new TableLayoutCell(cell, `${row.key}:cell:${cell.id}`, columnStart, columnSpan,
        contentRow === rowIndex, false, endRow > rowIndex))
      markColumnsOccupied(occupied, columnStart, columnSpan)
      if (endRow > rowIndex) {
        activeSpans.push(new ActiveTableSpan(cell, columnStart, columnSpan, endRow, contentRow))
      }
      cursor = columnStart + columnSpan
      layout.columnCount = Math.max(layout.columnCount, cursor)
    }
    layout.rows.push(row)
  }

  for (let rowIndex: number = 0; rowIndex < layout.rows.length; rowIndex++) {
    fillRowGaps(layout.rows[rowIndex], layout.columnCount)
  }
  return layout
}
