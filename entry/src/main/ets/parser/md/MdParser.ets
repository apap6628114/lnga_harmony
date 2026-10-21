import { MdNode, MdNodeType } from '../../model/MdNode'

/**
 * Markdown 流式友好解析器。
 *
 * 采用全量重解析策略：每次文本更新时重新解析全部累积文本。
 * AI 输出通常 500-3000 字符，O(n) 解析耗时 < 1ms。
 *
 * 解析分两步：
 * 1. 块级解析 (parseBlocks) — 按行识别标题、段落、列表、代码块等
 * 2. 内联解析 (parseInline) — 在文本内识别粗体、斜体、链接等
 *
 * ╔══════════════════════════════════════════════════════════════╗
 * ║  ⚠️  ARKTS 类型标注陷阱 — 后续 AI / 维护者必读  ⚠️       ║
 * ╠══════════════════════════════════════════════════════════════╣
 * ║                                                            ║
 * ║  不要对 regex.exec() 的返回值标注 RegExpMatchArray | null  ║
 * ║  类型！ArkTS 不支持结构类型联合（arkts-no-structural-     ║
 * ║  typing），编译直接报错。                                  ║
 * ║                                                            ║
 * ║  ❌ const m: RegExpMatchArray | null = RE.exec(str)        ║
 * ║  ✅ const m = RE.exec(str)   // 靠类型推断                ║
 * ║                                                            ║
 * ║  同理：不要用 RegExp.test() 后再 exec()，非全局正则会      ║
 * ║  在 test() 中修改 lastIndex 导致 exec() 行为异常。        ║
 * ║  直接用 exec() + null 检查即可。                           ║
 * ╚══════════════════════════════════════════════════════════════╝
 */

/** 标题行正则：`# ` 到 `###### ` */
const HEADING_RE: RegExp = /^(#{1,6})\s+(.+)$/
/** 代码围栏正则：` ``` ` 或 ` ```lang ` */
const FENCE_RE: RegExp = /^```(\w*)\s*$/
/** 无序列表项正则：`- ` / `* ` / `+ ` */
const UL_ITEM_RE: RegExp = /^[-*+]\s+(.+)$/
/** 有序列表项正则：`1. ` */
const OL_ITEM_RE: RegExp = /^(\d+)\.\s+(.+)$/
/** 引用行正则：`> ` 或 `>` */
const BLOCKQUOTE_RE: RegExp = /^>\s?(.*)$/
/** 分隔线正则：3 个以上 `-` / `*` / `_` */
const HR_RE: RegExp = /^[-*_]{3,}\s*$/
/** 块级图片正则：整行只包含一个 `![alt](url)` */
const IMAGE_LINE_RE: RegExp = /^!\[([^\]]*)\]\(\s*([^)\s]+)\s*\)\s*$/
/** 表格分隔行正则：`| --- | :---: | ---: |` */
const TABLE_DIVIDER_RE: RegExp = /^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/
/** 任务列表项前缀正则：`[ ]` / `[x]` */
const TASK_PREFIX_RE: RegExp = /^\[([ xX])\]\s+(.*)$/

/** 块级稳定 key 的序列号计数器，每次 parseMd 调用时重置。 */
let keySerialMap: Record<string, number> = {}

/**
 * 解析 Markdown 文本为 AST 节点数组。
 *
 * 每次文本更新时调用，对流式输出友好。
 *
 * @param text - 完整的累积 Markdown 文本
 * @returns 解析后的 MdNode 数组（顶层为块级节点列表），空文本返回空数组
 */
export function parseMd(text: string): MdNode[] {
  if (text.length === 0) {
    return []
  }
  keySerialMap = {}
  const normalized: string = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n')
  const lines: string[] = normalized.split('\n')
  return parseBlocks(lines)
}

// ============================================================
// 块级解析
// ============================================================

/**
 * 按行扫描识别块级结构并构建块级节点列表。
 *
 * 支持嵌套结构：列表包含列表项，引用块内可递归解析段落。
 *
 * @param lines - 已规范化换行符的文本行数组
 * @returns 块级 MdNode 数组
 */
function parseBlocks(lines: string[]): MdNode[] {
  const result: MdNode[] = []
  const len: number = lines.length
  let i: number = 0

  while (i < len) {
    const line: string = lines[i]

    // 空行 — 块分隔符
    if (line.trim().length === 0) {
      i++
      continue
    }

    // 代码围栏 — 进入代码块模式
    const fenceMatch = FENCE_RE.exec(line)
    if (fenceMatch !== null) {
      const lang: string = fenceMatch[1]
      const fenceResult: CodeFenceResult = consumeCodeFence(lines, i + 1)
      const codeNode: MdNode = new MdNode(MdNodeType.CODE_BLOCK)
      codeNode.text = fenceResult.content
      codeNode.language = lang.length > 0 ? lang : ''
      assignStableKeys(codeNode, buildStableKey('code', fenceResult.content))
      result.push(codeNode)
      i = fenceResult.nextLine
      continue
    }

    // 表格 — 当前行含竖线且下一行是分隔行
    if (line.indexOf('|') >= 0 && i + 1 < len && isTableDivider(lines[i + 1])) {
      const tableResult: TableResult = consumeTable(lines, i)
      assignStableKeys(tableResult.node, buildStableKey('table', tableSignature(tableResult.node)))
      result.push(tableResult.node)
      i = tableResult.nextLine
      continue
    }

    // 块级图片 — 整行只有一个 ![alt](url)
    const imageMatch = IMAGE_LINE_RE.exec(line)
    if (imageMatch !== null) {
      const imageNode: MdNode = new MdNode(MdNodeType.IMAGE)
      imageNode.text = imageMatch[1]
      imageNode.href = imageMatch[2]
      assignStableKeys(imageNode, buildStableKey('img', imageMatch[2]))
      result.push(imageNode)
      i++
      continue
    }

    // 标题
    const headingMatch = HEADING_RE.exec(line)
    if (headingMatch !== null) {
      const level: number = headingMatch[1].length
      const headingText: string = headingMatch[2]
      const headingNode: MdNode = new MdNode(MdNodeType.HEADING)
      headingNode.level = level
      headingNode.children = parseInline(headingText)
      assignStableKeys(headingNode, buildStableKey('heading', headingText))
      result.push(headingNode)
      i++
      continue
    }

    // 分隔线
    if (HR_RE.test(line)) {
      const hrNode: MdNode = new MdNode(MdNodeType.THEMATIC_BREAK)
      assignStableKeys(hrNode, buildStableKey('hr', ''))
      result.push(hrNode)
      i++
      continue
    }

    // 无序列表
    const ulMatch = UL_ITEM_RE.exec(line)
    if (ulMatch !== null) {
      const listResult: ListResult = consumeList(lines, i, MdNodeType.UNORDERED_LIST)
      let ulContent: string = ''
      for (let j: number = i; j < listResult.nextLine; j++) {
        ulContent += lines[j] + '\n'
      }
      assignStableKeys(listResult.node, buildStableKey('ul', ulContent))
      result.push(listResult.node)
      i = listResult.nextLine
      continue
    }

    // 有序列表
    const olMatch = OL_ITEM_RE.exec(line)
    if (olMatch !== null) {
      const listResult: ListResult = consumeList(lines, i, MdNodeType.ORDERED_LIST)
      let olContent: string = ''
      for (let j: number = i; j < listResult.nextLine; j++) {
        olContent += lines[j] + '\n'
      }
      assignStableKeys(listResult.node, buildStableKey('ol', olContent))
      result.push(listResult.node)
      i = listResult.nextLine
      continue
    }

    // 引用块
    const bqMatch = BLOCKQUOTE_RE.exec(line)
    if (bqMatch !== null) {
      const bqResult: BlockquoteResult = consumeBlockquote(lines, i)
      let bqContent: string = ''
      for (let j: number = i; j < bqResult.nextLine; j++) {
        bqContent += lines[j] + '\n'
      }
      assignStableKeys(bqResult.node, buildStableKey('bq', bqContent))
      result.push(bqResult.node)
      i = bqResult.nextLine
      continue
    }

    // 普通段落 — 收集连续文本行直到块分隔符
    const paraResult: ParaResult = consumeParagraph(lines, i)
    const paraNode: MdNode = new MdNode(MdNodeType.PARAGRAPH)
    paraNode.children = parseInline(paraResult.text)
    assignStableKeys(paraNode, buildStableKey('para', paraResult.text))
    result.push(paraNode)
    i = paraResult.nextLine
  }

  return result
}

// ============================================================
// 块级辅助结构体
// ============================================================

/** consumeCodeFence 返回值 */
class CodeFenceResult {
  /** 围栏内的代码文本 */
  content: string = ''
  /** 消费结束后下一个待处理行索引 */
  nextLine: number = 0
}

/** consumeTable 返回值 */
class TableResult {
  /** 构建的表格节点 */
  node: MdNode = new MdNode(MdNodeType.TABLE)
  /** 消费结束后下一个待处理行索引 */
  nextLine: number = 0
}

/** 任务列表前缀解析结果 */
class TaskPrefixResult {
  /** 勾选状态：-1 非任务，0 未完成，1 已完成 */
  checked: number = -1
  /** 去除前缀后的文本 */
  text: string = ''
}

/** consumeList 返回值 */
class ListResult {
  /** 构建的列表节点 */
  node: MdNode = new MdNode(MdNodeType.UNORDERED_LIST)
  /** 消费结束后下一个待处理行索引 */
  nextLine: number = 0
}

/** consumeBlockquote 返回值 */
class BlockquoteResult {
  /** 构建的引用块节点 */
  node: MdNode = new MdNode(MdNodeType.BLOCKQUOTE)
  /** 消费结束后下一个待处理行索引 */
  nextLine: number = 0
}

/** consumeParagraph 返回值 */
class ParaResult {
  /** 段落文本（已合并多行） */
  text: string = ''
  /** 消费结束后下一个待处理行索引 */
  nextLine: number = 0
}

// ============================================================
// 块级消费函数
// ============================================================

/**
 * 消费从 startLine 开始的代码块内容直到闭合围栏或文本末尾。
 *
 * @param lines - 全部文本行
 * @param startLine - 代码块内容起始行号（围栏之后的第一行）
 * @returns 代码文本及下一行索引
 */
function consumeCodeFence(lines: string[], startLine: number): CodeFenceResult {
  const result: CodeFenceResult = new CodeFenceResult()
  const parts: string[] = []
  const len: number = lines.length

  let i: number = startLine
  while (i < len) {
    if (FENCE_RE.test(lines[i])) {
      // 闭合围栏
      i++
      break
    }
    parts.push(lines[i])
    i++
  }

  result.content = parts.join('\n')
  result.nextLine = i
  return result
}

/**
 * 判断一行是否为 GFM 表格分隔行（`| --- | :---: |`）。
 *
 * @param line - 文本行
 * @returns true 表示分隔行
 */
function isTableDivider(line: string): boolean {
  const trimmed: string = line.trim()
  if (trimmed.indexOf('-') < 0 || trimmed.indexOf('|') < 0) {
    return false
  }
  return TABLE_DIVIDER_RE.test(trimmed)
}

/**
 * 按竖线拆分表格行，去掉首尾竖线与单元格空白。
 *
 * @param line - 表格行文本
 * @returns 单元格文本数组
 */
function splitTableRow(line: string): string[] {
  let trimmed: string = line.trim()
  if (trimmed.startsWith('|')) {
    trimmed = trimmed.substring(1)
  }
  if (trimmed.endsWith('|')) {
    trimmed = trimmed.substring(0, trimmed.length - 1)
  }
  if (trimmed.length === 0) {
    return []
  }
  const parts: string[] = trimmed.split('|')
  const result: string[] = []
  for (let i: number = 0; i < parts.length; i++) {
    result.push(parts[i].trim())
  }
  return result
}

/**
 * 解析表格分隔行中的对齐声明。
 *
 * @param line - 分隔行
 * @returns 每个单元格的对齐方式（left / center / right）
 */
function parseTableAligns(line: string): string[] {
  const cells: string[] = splitTableRow(line)
  const result: string[] = []
  for (let i: number = 0; i < cells.length; i++) {
    const cell: string = cells[i].trim()
    const left: boolean = cell.startsWith(':')
    const right: boolean = cell.endsWith(':')
    if (left && right) {
      result.push('center')
    } else if (right) {
      result.push('right')
    } else {
      result.push('left')
    }
  }
  return result
}

/**
 * 构建表格行节点。
 *
 * @param cells - 单元格文本
 * @param aligns - 对齐方式
 * @param header - 是否为表头行
 * @param columnCount - 表格列数（不足补空单元格）
 * @returns TABLE_ROW 节点
 */
function buildTableRow(cells: string[], aligns: string[], header: boolean, columnCount: number): MdNode {
  const row: MdNode = new MdNode(MdNodeType.TABLE_ROW)
  row.level = header ? 1 : 0
  for (let i: number = 0; i < columnCount; i++) {
    const cell: MdNode = new MdNode(MdNodeType.TABLE_CELL)
    cell.align = aligns.length > i ? aligns[i] : 'left'
    const cellText: string = i < cells.length ? cells[i] : ''
    cell.children = parseInline(cellText)
    row.children.push(cell)
  }
  return row
}

/**
 * 消费从 startLine 开始的 GFM 表格。
 *
 * @param lines - 全部文本行
 * @param startLine - 表头行索引
 * @returns 表格节点及下一行索引
 */
function consumeTable(lines: string[], startLine: number): TableResult {
  const result: TableResult = new TableResult()
  const tableNode: MdNode = new MdNode(MdNodeType.TABLE)
  const headerCells: string[] = splitTableRow(lines[startLine])
  const aligns: string[] = parseTableAligns(lines[startLine + 1])
  const columnCount: number = headerCells.length
  if (columnCount > 0) {
    tableNode.children.push(buildTableRow(headerCells, aligns, true, columnCount))
  }

  let i: number = startLine + 2
  const len: number = lines.length
  while (i < len) {
    const line: string = lines[i]
    if (line.trim().length === 0 || line.indexOf('|') < 0) {
      break
    }
    if (isTableDivider(line)) {
      break
    }
    const cells: string[] = splitTableRow(line)
    if (cells.length === 0) {
      break
    }
    tableNode.children.push(buildTableRow(cells, aligns, false, columnCount))
    i++
  }

  result.node = tableNode
  result.nextLine = i
  return result
}

/**
 * 生成表格的稳定签名（用于 ForEach key）。
 *
 * @param table - 表格节点
 * @returns 内容签名
 */
function tableSignature(table: MdNode): string {
  let signature: string = ''
  for (let i: number = 0; i < table.children.length; i++) {
    const row: MdNode = table.children[i]
    for (let j: number = 0; j < row.children.length; j++) {
      const cell: MdNode = row.children[j]
      for (let k: number = 0; k < cell.children.length; k++) {
        signature += cell.children[k].text + '|'
      }
      signature += ';'
    }
    signature += '/'
  }
  return signature
}

/**
 * 解析任务列表项前缀（`[ ]` / `[x]`）。
 *
 * @param text - 列表项文本
 * @returns 勾选状态与去前缀文本
 */
function parseTaskPrefix(text: string): TaskPrefixResult {
  const result: TaskPrefixResult = new TaskPrefixResult()
  const match = TASK_PREFIX_RE.exec(text)
  if (match === null) {
    result.text = text
    return result
  }
  result.checked = match[1] === ' ' ? 0 : 1
  result.text = match[2]
  return result
}

/**
 * 消费从 startLine 开始的连续列表项，构建 UNORDERED_LIST 或 ORDERED_LIST 节点。
 *
 * 支持两种扩展：
 * - 任务列表项（`- [ ]` / `- [x]`）记录勾选状态；
 * - 缩进 ≥ 2 空格的列表项作为上一项的子列表（仅一层）。
 *
 * @param lines - 全部文本行
 * @param startLine - 第一个列表项所在行号
 * @param listType - 列表类型
 * @returns 列表节点及下一行索引
 */
function consumeList(lines: string[], startLine: number, listType: MdNodeType): ListResult {
  const result: ListResult = new ListResult()
  const listNode: MdNode = new MdNode(listType)
  const itemRe: RegExp = listType === MdNodeType.ORDERED_LIST ? OL_ITEM_RE : UL_ITEM_RE
  const groupIndex: number = listType === MdNodeType.ORDERED_LIST ? 2 : 1
  const len: number = lines.length

  let i: number = startLine
  let currentSubList: MdNode | null = null
  while (i < len) {
    const rawLine: string = lines[i]

    // 空行 — 列表结束
    if (rawLine.trim().length === 0) {
      break
    }

    // 统计缩进量，用于识别子列表
    let indent: number = 0
    while (indent < rawLine.length) {
      const ch: string = rawLine.charAt(indent)
      if (ch !== ' ' && ch !== '\t') {
        break
      }
      indent++
    }
    const content: string = rawLine.substring(indent)
    const match = itemRe.exec(content)
    if (match === null) {
      break
    }

    const itemText: string = match[groupIndex]
    const itemNode: MdNode = new MdNode(MdNodeType.LIST_ITEM)
    const task: TaskPrefixResult = parseTaskPrefix(itemText)
    itemNode.checked = task.checked
    itemNode.children = parseInline(task.text)

    if (indent >= 2 && listNode.children.length > 0) {
      // 子列表：挂到上一个列表项的 children 末尾
      if (currentSubList === null) {
        currentSubList = new MdNode(listType)
        const parent: MdNode = listNode.children[listNode.children.length - 1]
        parent.children.push(currentSubList)
      }
      currentSubList.children.push(itemNode)
    } else {
      currentSubList = null
      listNode.children.push(itemNode)
    }
    i++
  }

  result.node = listNode
  result.nextLine = i
  return result
}

/**
 * 消费从 startLine 开始的连续引用行，构建 BLOCKQUOTE 节点。
 *
 * 连续的 `> ` 行被合并为一个引用块，各行内容以换行符连接。
 *
 * @param lines - 全部文本行
 * @param startLine - 第一个引用行所在行号
 * @returns 引用块节点及下一行索引
 */
function consumeBlockquote(lines: string[], startLine: number): BlockquoteResult {
  const result: BlockquoteResult = new BlockquoteResult()
  const parts: string[] = []
  const len: number = lines.length

  let i: number = startLine
  while (i < len) {
    const line: string = lines[i]

    if (line.trim().length === 0) {
      // 空行 — 如果下一行仍是引用行则继续，否则结束
      if (i + 1 < len) {
        const bqMatchNext = BLOCKQUOTE_RE.exec(lines[i + 1])
        if (bqMatchNext !== null) {
          parts.push('')
          i++
          continue
        }
      }
      break
    }

    const bqMatch = BLOCKQUOTE_RE.exec(line)
    if (bqMatch === null) {
      break
    }

    parts.push(bqMatch[1])
    i++
  }

  const bqNode: MdNode = new MdNode(MdNodeType.BLOCKQUOTE)
  bqNode.children = parseInline(parts.join('\n'))
  result.node = bqNode
  result.nextLine = i
  return result
}

/**
 * 消费从 startLine 开始的连续文本行，构建段落文本。
 *
 * 段落以空行、块级标记（标题/列表/代码围栏/引用/分隔线）为结束标志。
 * 段落内部的多行以换行符连接，保留软换行。
 *
 * @param lines - 全部文本行
 * @param startLine - 段落起始行号
 * @returns 段落文本及下一行索引
 */
function consumeParagraph(lines: string[], startLine: number): ParaResult {
  const result: ParaResult = new ParaResult()
  const parts: string[] = []
  const len: number = lines.length

  let i: number = startLine
  while (i < len) {
    const line: string = lines[i]

    // 空行 — 段落结束
    if (line.trim().length === 0) {
      break
    }

    // 块级标记 — 段落结束
    if (isBlockStart(line) || isTableStart(lines, i)) {
      break
    }

    parts.push(line)
    i++
  }

  result.text = parts.join('\n')
  result.nextLine = i
  return result
}

/**
 * 判断一行文本是否为块级结构的起始行。
 *
 * @param line - 待判断的文本行
 * @returns 如果是块级起始行返回 true
 */
function isBlockStart(line: string): boolean {
  return HEADING_RE.test(line) ||
    FENCE_RE.test(line) ||
    UL_ITEM_RE.test(line) ||
    OL_ITEM_RE.test(line) ||
    BLOCKQUOTE_RE.test(line) ||
    HR_RE.test(line) ||
    IMAGE_LINE_RE.test(line)
}

/**
 * 判断从指定行开始是否为 GFM 表格（当前行含竖线且下一行是分隔行）。
 *
 * @param lines - 全部文本行
 * @param index - 待判断行索引
 * @returns true 表示表格起始行
 */
function isTableStart(lines: string[], index: number): boolean {
  if (index + 1 >= lines.length) {
    return false
  }
  if (lines[index].indexOf('|') < 0) {
    return false
  }
  return isTableDivider(lines[index + 1])
}

// ============================================================
// 内联解析
// ============================================================

/**
 * 解析文本中的内联格式，返回内联节点列表。
 *
 * 采用递归下降策略：在 BOLD/ITALIC/STRIKETHROUGH 内部
 * 再次调用 parseInline 实现嵌套格式（如 `**粗体中的 *斜体***`）。
 *
 * 流式友好：未闭合的标记（如 `**未闭合）按普通文本处理，
 * 下次收到更多文本时全量重解析会自动修正。
 *
 * @param text - 待解析的文本（不含块级标记）
 * @returns 内联 MdNode 数组
 */
export function parseInline(text: string): MdNode[] {
  const result: MdNode[] = []
  const len: number = text.length

  // 空文本直接返回空数组
  if (len === 0) {
    return result
  }

  let pos: number = 0
  // 当前待刷新的纯文本段起始位置
  let textStart: number = 0

  while (pos < len) {
    const ch: string = text.charAt(pos)

    // 转义字符 — 跳过反斜杠，下一个字符作为普通文本
    if (ch === '\\' && pos + 1 < len) {
      // 刷新转义符之前的文本
      flushText(text, textStart, pos, result)
      // 将转义后的字符作为 TEXT 节点
      const escapedNode: MdNode = new MdNode(MdNodeType.TEXT)
      escapedNode.text = text.charAt(pos + 1)
      result.push(escapedNode)
      pos += 2
      textStart = pos
      continue
    }

    // 行内代码 `` `code` ``
    if (ch === '`') {
      const end: number = text.indexOf('`', pos + 1)
      if (end >= 0) {
        flushText(text, textStart, pos, result)
        const codeNode: MdNode = new MdNode(MdNodeType.CODE_INLINE)
        codeNode.text = text.substring(pos + 1, end)
        result.push(codeNode)
        pos = end + 1
        textStart = pos
        continue
      }
      // 未闭合的反引号 — 当作普通文本继续
      pos++
      continue
    }

    // 粗体 `**text**`（优先于斜体）
    if (ch === '*' && pos + 1 < len && text.charAt(pos + 1) === '*') {
      const end: number = text.indexOf('**', pos + 2)
      if (end >= 0) {
        flushText(text, textStart, pos, result)
        const innerText: string = text.substring(pos + 2, end)
        const boldNode: MdNode = new MdNode(MdNodeType.BOLD)
        boldNode.children = parseInline(innerText)
        // 优化：单 TEXT 子节点时提升文本到父节点
        compressSingleTextChild(boldNode)
        result.push(boldNode)
        pos = end + 2
        textStart = pos
        continue
      }
      // 未闭合 — 当作普通文本继续
      pos += 2
      continue
    }

    // 斜体 `*text*`（单星号，不匹配 `**`）
    if (ch === '*') {
      const end: number = findSingleCharMarker(text, '*', pos + 1, len)
      if (end >= 0) {
        flushText(text, textStart, pos, result)
        const innerText: string = text.substring(pos + 1, end)
        const italicNode: MdNode = new MdNode(MdNodeType.ITALIC)
        italicNode.children = parseInline(innerText)
        compressSingleTextChild(italicNode)
        result.push(italicNode)
        pos = end + 1
        textStart = pos
        continue
      }
      // 未闭合 — 当作普通文本
      pos++
      continue
    }

    // 删除线 `~~text~~`
    if (ch === '~' && pos + 1 < len && text.charAt(pos + 1) === '~') {
      const end: number = text.indexOf('~~', pos + 2)
      if (end >= 0) {
        flushText(text, textStart, pos, result)
        const innerText: string = text.substring(pos + 2, end)
        const strikeNode: MdNode = new MdNode(MdNodeType.STRIKETHROUGH)
        strikeNode.children = parseInline(innerText)
        compressSingleTextChild(strikeNode)
        result.push(strikeNode)
        pos = end + 2
        textStart = pos
        continue
      }
      // 未闭合 — 当作普通文本
      pos += 2
      continue
    }

    // 图片 `![alt](url)`
    if (ch === '!' && pos + 1 < len && text.charAt(pos + 1) === '[') {
      const closeBracket: number = text.indexOf(']', pos + 2)
      if (closeBracket >= 0 && closeBracket + 1 < len && text.charAt(closeBracket + 1) === '(') {
        const closeParen: number = text.indexOf(')', closeBracket + 2)
        if (closeParen >= 0) {
          flushText(text, textStart, pos, result)
          const imageNode: MdNode = new MdNode(MdNodeType.IMAGE)
          imageNode.text = text.substring(pos + 2, closeBracket)
          imageNode.href = text.substring(closeBracket + 2, closeParen)
          result.push(imageNode)
          pos = closeParen + 1
          textStart = pos
          continue
        }
      }
      pos++
      continue
    }

    // 链接 `[text](url)`
    if (ch === '[') {
      const linkEnd: number = findLinkClose(text, pos, len)
      if (linkEnd >= 0) {
        const closeBracket: number = text.indexOf(']', pos + 1)
        flushText(text, textStart, pos, result)
        const linkText: string = text.substring(pos + 1, closeBracket)
        const linkUrl: string = text.substring(closeBracket + 2, linkEnd)
        const linkNode: MdNode = new MdNode(MdNodeType.LINK)
        linkNode.text = linkText
        linkNode.href = linkUrl
        result.push(linkNode)
        pos = linkEnd + 1
        textStart = pos
        continue
      }
      // 不是合法链接 — 当作普通文本
      pos++
      continue
    }

    // 无标记匹配，前进一个字符
    pos++
  }

  // 刷新尾部剩余文本
  flushText(text, textStart, len, result)

  return result
}

/**
 * 将 text[start..end] 段作为 TEXT 节点追加到 result（如果非空）。
 *
 * @param text - 源文本
 * @param start - 段起始位置
 * @param end - 段结束位置（不含）
 * @param result - 目标节点数组
 */
function flushText(text: string, start: number, end: number, result: MdNode[]): void {
  if (end <= start) {
    return
  }
  const segment: string = text.substring(start, end)
  let pos: number = 0
  while (pos < segment.length) {
    const urlStart: number = findUrlStart(segment, pos)
    if (urlStart < 0) {
      pushTextNode(segment.substring(pos), result)
      return
    }
    if (urlStart > pos) {
      pushTextNode(segment.substring(pos, urlStart), result)
    }
    const urlEnd: number = findUrlEnd(segment, urlStart)
    const url: string = segment.substring(urlStart, urlEnd)
    if (url.length > 8) {
      const link: MdNode = new MdNode(MdNodeType.LINK)
      link.text = url
      link.href = url
      result.push(link)
    } else {
      pushTextNode(url, result)
    }
    pos = urlEnd
  }
}

/**
 * 追加一个纯文本节点。
 *
 * @param value - 文本内容
 * @param result - 目标节点数组
 */
function pushTextNode(value: string, result: MdNode[]): void {
  if (value.length === 0) {
    return
  }
  const node: MdNode = new MdNode(MdNodeType.TEXT)
  node.text = value
  result.push(node)
}

/**
 * 查找文本段中下一个裸链接的起点。
 *
 * @param segment - 文本段
 * @param from - 搜索起点
 * @returns 链接起点，未找到返回 -1
 */
function findUrlStart(segment: string, from: number): number {
  const httpIndex: number = segment.indexOf('http://', from)
  const httpsIndex: number = segment.indexOf('https://', from)
  if (httpIndex < 0) {
    return httpsIndex
  }
  if (httpsIndex < 0) {
    return httpIndex
  }
  return Math.min(httpIndex, httpsIndex)
}

/**
 * 查找裸链接的结束位置。
 *
 * 遇到空白、常见分隔符或中文标点即结束；尾部的英文标点会被剥离。
 *
 * @param segment - 文本段
 * @param start - 链接起点
 * @returns 链接结束位置（不含）
 */
function findUrlEnd(segment: string, start: number): number {
  let i: number = start
  const len: number = segment.length
  while (i < len) {
    const ch: string = segment.charAt(i)
    if (ch === ' ' || ch === '\n' || ch === '\t') {
      break
    }
    if (ch === ')' || ch === ']' || ch === '}' || ch === '>' || ch === '"' || ch === '\'') {
      break
    }
    if (ch === '，' || ch === '。' || ch === '；' || ch === '：' || ch === '！' ||
      ch === '？' || ch === '、' || ch === '（' || ch === '）' || ch === '“' || ch === '”') {
      break
    }
    i++
  }
  // 剥离尾部英文标点
  while (i > start) {
    const last: string = segment.charAt(i - 1)
    if (last === '.' || last === ',' || last === ';' || last === ':' || last === '!' || last === '?') {
      i--
    } else {
      break
    }
  }
  return i
}

/**
 * 查找单字符标记（`*`）的闭合位置。
 *
 * 与双字符标记（`**`、`~~`）不同，单字符 `*` 需要跳过连续的 `**`，
 * 避免将 `**bold**` 中的起始 `*` 误匹配。
 *
 * @param text - 源文本
 * @param marker - 标记字符
 * @param from - 搜索起始位置
 * @param len - 文本长度
 * @returns 闭合位置，-1 表示未找到
 */
function findSingleCharMarker(text: string, marker: string, from: number, len: number): number {
  let i: number = from
  while (i < len) {
    if (text.charAt(i) === marker) {
      // 如果下一个字符也是 marker，说明这是双字符标记的一部分，跳过
      if (i + 1 < len && text.charAt(i + 1) === marker) {
        i += 2
        continue
      }
      return i
    }
    i++
  }
  return -1
}

/**
 * 查找链接闭合位置 `[text](url)`。
 *
 * 匹配 `]` 后紧跟 `(` 和 `)` 的完整链接语法。
 *
 * @param text - 源文本
 * @param openPos - `[` 的位置
 * @param len - 文本长度
 * @returns `)` 的位置，-1 表示不是合法链接
 */
function findLinkClose(text: string, openPos: number, len: number): number {
  const closeBracket: number = text.indexOf(']', openPos + 1)
  if (closeBracket < 0) {
    return -1
  }
  // 必须紧跟 `(`
  if (closeBracket + 1 >= len || text.charAt(closeBracket + 1) !== '(') {
    return -1
  }
  const closeParen: number = text.indexOf(')', closeBracket + 2)
  if (closeParen < 0) {
    return -1
  }
  return closeParen
}

/**
 * 优化：如果节点仅有一个 TEXT 子节点，将文本提升到父节点 text 字段并清空 children。
 *
 * 此优化减少树深度，简化渲染层的工作量（与 BBNode 的 inline-parser 做法一致）。
 *
 * @param node - 待优化的父节点（BOLD / ITALIC / STRIKETHROUGH）
 */
function compressSingleTextChild(node: MdNode): void {
  if (node.children.length === 1 && node.children[0].type === MdNodeType.TEXT) {
    node.text = node.children[0].text
    node.children = []
  }
}

/**
 * 32-bit FNV-1a 哈希，输出 36 进制短字符串。
 *
 * 用于从块内容生成稳定的 ForEach key，避免行号漂移
 * 导致组件实例全量重建。
 *
 * @param str - 待哈希字符串
 * @returns 36 进制哈希字符串
 */
function hashString(str: string): string {
  let hash: number = 0
  for (let i: number = 0; i < str.length; i++) {
    hash = ((hash << 5) - hash) + str.charCodeAt(i)
    hash |= 0
  }
  return (hash >>> 0).toString(36)
}

/**
 * 构建基于块类型和内容的稳定 key。
 *
 * 使用内容哈希作为主 key，块类型序列号作为后缀
 * 防止相同内容块的 key 冲突。
 *
 * @param prefix - 块类型前缀
 * @param content - 块文本内容
 * @returns 稳定 key
 */
function buildStableKey(prefix: string, content: string): string {
  const serial: number = (keySerialMap[prefix] ?? 0) + 1
  keySerialMap[prefix] = serial
  if (content.length > 0) {
    return prefix + '_' + hashString(content) + '_' + serial.toString()
  }
  return prefix + '_' + serial.toString()
}

/**
 * 为节点及其子节点递归分配稳定 key。
 *
 * @param node - 待分配 key 的节点
 * @param key - 当前节点 key
 */
function assignStableKeys(node: MdNode, key: string): void {
  node.key = key
  for (let i: number = 0; i < node.children.length; i++) {
    const child: MdNode = node.children[i]
    assignStableKeys(child, key + '_' + child.type.toString() + '_' + i.toString())
  }
}
