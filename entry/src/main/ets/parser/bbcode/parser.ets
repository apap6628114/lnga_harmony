import { BBNode, BBNodeType } from '../../model/BBCodeNode'
import { ParseState, preprocessContent, createBBNode, indexOfIgnoreCase, matchesIgnoreCaseAt, pushTextNode } from './lexer'
import { MAX_INLINE_DEPTH, MAX_INLINE_TAG_LENGTH, MAX_INLINE_LINK_TAG_LENGTH, parseInlineInto } from './inline-parser'
import { isInlineStyleTagName, isValidInlineStyleTag } from './inline-tag-policy'
import { handlePostBy } from './block-handlers/handlePostBy'
import { handleQuote } from './block-handlers/handleQuote'
import { handleCollapse } from './block-handlers/handleCollapse'
import { handleCode } from './block-handlers/handleCode'
import { handleList } from './block-handlers/handleList'
import { handleNuke, handleAlbum } from './block-handlers/handleNuke'
import { handleFlash } from './block-handlers/handleFlash'
import { handleImg } from './block-handlers/handleImg'
import { handleTable } from './block-handlers/handleTable'
import {
  handleDice,
  handleFloatLeft,
  handleFloatRight,
  handleAlign,
  handleStyle,
  handleHip,
  handleComment,
  handleHeading,
  handleHorizontalRule,
  handleParagraph,
  handleRandomBlock
} from './block-handlers/handleFormat'

/**
 * 编排层：parseBBCode 公共入口、parseBlockNodes 块级循环、tryMatchBlock 标签族分发，
 * 以及表格/列表的结构化辅助解析。tryMatchBlock 按标签名快速分派到原块级 handler。
 */

/**
 * 块级解析结果，同时记录触发返回的边界标签。
 */
class BlockParseResult {
  /** 已解析的语义节点。 */
  nodes: BBNode[] = []
  /** 已消费的边界标签；解析至正文末尾时为空字符串。 */
  terminator: string = ''
}

/**
 * 公共入口：预处理后从顶层解析块级节点。
 *
 * 快速路径：无 `[`、`<`、`===` 的纯文本（如表格单元格正文）经 preprocessContent
 * 恒等不变——`<br/>` 替换需 `<`、HTML 清理需 `<`/`[code]`、标题规范化需
 * `[h]` 标签或 `===...===` 分隔行。跳过预处理省去表格单元格递归中
 * 每个单元格重复的 6 正则链 + toLowerCase + 逐行扫描。
 */
function parseBBCode(content: string): BBNode[] {
  if (!content) return []
  const state = new ParseState()
  if (content.indexOf('[') < 0 && content.indexOf('<') < 0 && content.indexOf('===') < 0) {
    state.content = content
  } else {
    state.content = preprocessContent(content)
  }
  state.pos = 0
  state.len = state.content.length
  return parseBlockNodes(state, null)
}

/**
 * 读取指定左方括号后的 ASCII 标签名。
 *
 * 闭合标签、原样方括号和不含字母名称的内容返回空字符串，交由内联解析器处理。
 *
 * @param content 完整解析正文
 * @param start 左方括号位置
 * @returns 小写标签名；当前位置不是开始标签时返回空字符串
 */
function getBlockTagNameAt(content: string, start: number): string {
  const nameStart: number = start + 1
  if (nameStart >= content.length || content.charAt(nameStart) === '/') return ''
  let end: number = nameStart
  while (end < content.length) {
    const code: number = content.charCodeAt(end)
    if (!((code >= 65 && code <= 90) || (code >= 97 && code <= 122))) break
    end++
  }
  if (end === nameStart) return ''
  return content.substring(nameStart, end).toLowerCase()
}

/**
 * 从内联开始标签中提取规范化名称。
 *
 * @param tag 内联开始标签原文
 * @returns 小写标签名
 */
function getInlineTagName(tag: string): string {
  const match: RegExpExecArray | null = /^\[([a-z]+)/i.exec(tag)
  return match ? match[1].toLowerCase() : ''
}

/**
 * 为内联开始标签生成闭合标签。
 *
 * @param tag 内联开始标签原文
 * @returns 对应闭合标签
 */
function getInlineCloseTag(tag: string): string {
  const name: string = getInlineTagName(tag)
  return name.length > 0 ? `[/${name}]` : ''
}

/**
 * 判断内联样式开始标签是否与主栈解析器采用相同的合法属性。
 *
 * @param rawTag 开始标签原文
 * @param name 小写标签名
 * @returns 是否可进入跨块样式栈
 */
function isTrackableInlineOpenTag(rawTag: string, name: string): boolean {
  const equalIndex: number = rawTag.indexOf('=')
  const attribute: string = equalIndex >= 0 ? rawTag.substring(equalIndex + 1, rawTag.length - 1).trim() : ''
  if (isInlineStyleTagName(name)) return isValidInlineStyleTag(name, attribute)
  return true
}

/** 跨块内联标签扫描正则（模块级常量，避免每片段重复构造）。 */
const P_INLINE_TAG: RegExp = /\[(\/)?(b|item|i|u|del|color|size|font|sub|sup|url|pid|uid|tid)(?:=[^\]]*)?\]/gi

/**
 * 更新跨块节点延续的内联样式栈。
 *
 * @param segment 尚未解码的正文片段
 * @param activeTags 当前仍处于打开状态的开始标签
 */
function updateActiveInlineTags(segment: string, activeTags: string[]): void {
  P_INLINE_TAG.lastIndex = 0
  let match: RegExpExecArray | null = P_INLINE_TAG.exec(segment)
  while (match) {
    const name: string = match[2].toLowerCase()
    // 链接类标签属性是数据而非样式（官方对 URL 长度不设限），按类别选择长度上限
    const limit: number = /^(url|pid|uid|tid)$/.test(name) ?
      MAX_INLINE_LINK_TAG_LENGTH : MAX_INLINE_TAG_LENGTH
    if (match[0].length > limit) {
      match = P_INLINE_TAG.exec(segment)
      continue
    }
    if (match[1]) {
      for (let i: number = activeTags.length - 1; i >= 0; i--) {
        if (getInlineTagName(activeTags[i]) === name) {
          activeTags.splice(i)
          break
        }
      }
    } else if (activeTags.length < MAX_INLINE_DEPTH && isTrackableInlineOpenTag(match[0], name)) {
      activeTags.push(match[0])
    }
    match = P_INLINE_TAG.exec(segment)
  }
}

/**
 * 在内联节点树中查找最后一个有效 URL 地址。
 *
 * @param nodes 当前片段生成的内联节点树
 * @returns 最后一个有效 URL；不存在时返回空字符串
 */
function findLastUrlHref(nodes: BBNode[]): string {
  let href: string = ''
  for (let i: number = 0; i < nodes.length; i++) {
    if (nodes[i].type === BBNodeType.URL && nodes[i].href.length > 0) {
      href = nodes[i].href
    }
    const childHref: string = findLastUrlHref(nodes[i].children)
    if (childHref.length > 0) href = childHref
  }
  return href
}

/**
 * 将无属性 `[url]` 从片段文字推导出的地址写回跨块标签栈。
 *
 * @param activeTags 跨块延续的内联开始标签
 * @param segmentNodes 当前片段生成的节点
 */
function promoteDerivedUrlTag(activeTags: string[], segmentNodes: BBNode[]): void {
  let urlIndex: number = -1
  for (let i: number = activeTags.length - 1; i >= 0; i--) {
    if (/^\[url\]$/i.test(activeTags[i])) {
      urlIndex = i
      break
    }
  }
  if (urlIndex < 0) return
  const href: string = findLastUrlHref(segmentNodes)
  if (href.length === 0) return
  activeTags[urlIndex] = `[url=${href.replace(/\]/g, '&#93;')}]`
}

/**
 * 解析可能被图片、引用等块节点截断的内联片段。
 *
 * @param segment 尚未解码的正文片段
 * @param result 当前节点输出数组
 * @param activeTags 跨块延续的文字样式栈
 */
function appendInlineSegment(segment: string, result: BBNode[], activeTags: string[]): void {
  if (segment.length === 0) return
  let prefix: string = ''
  for (let i: number = 0; i < activeTags.length; i++) {
    prefix += activeTags[i]
  }
  updateActiveInlineTags(segment, activeTags)
  let suffix: string = ''
  for (let i: number = activeTags.length - 1; i >= 0; i--) {
    suffix += getInlineCloseTag(activeTags[i])
  }
  const segmentNodes: BBNode[] = []
  parseInlineInto(prefix + segment + suffix, segmentNodes)
  promoteDerivedUrlTag(activeTags, segmentNodes)
  for (let i: number = 0; i < segmentNodes.length; i++) {
    result.push(segmentNodes[i])
  }
}

/**
 * 块级循环：只在真实块标签处分段，遇指定边界标签时返回。
 *
 * @param state 解析游标
 * @param closePattern 可选的边界标签表达式
 * @returns 当前层解析得到的语义节点
 */
function parseBlockNodes(state: ParseState, closePattern: RegExp | null): BBNode[] {
  return parseBlockNodesUntil(state, closePattern).nodes
}

/**
 * 解析当前层块节点，并返回已消费的边界标签。
 *
 * 嵌套块由对应处理器完整消费，因此边界表达式只会截断当前结构层级。
 *
 * @param state 解析游标
 * @param closePattern 可选的边界标签表达式
 * @returns 节点及触发返回的边界标签
 */
function parseBlockNodesUntil(state: ParseState, closePattern: RegExp | null): BlockParseResult {
  const parsed: BlockParseResult = new BlockParseResult()
  const activeInlineTags: string[] = []
  let inlineStart: number = state.pos

  while (state.pos < state.len) {
    const idx: number = state.content.indexOf('[', state.pos)
    if (idx < 0) {
      appendInlineSegment(state.content.substring(inlineStart, state.len), parsed.nodes, activeInlineTags)
      state.pos = state.len
      return parsed
    }
    state.pos = idx

    if (closePattern) {
      closePattern.lastIndex = idx
      const closeMatch: RegExpExecArray | null = closePattern.exec(state.content)
      if (closeMatch && closeMatch.index === idx) {
        appendInlineSegment(state.content.substring(inlineStart, idx), parsed.nodes, activeInlineTags)
        parsed.terminator = closeMatch[0]
        state.pos = closePattern.lastIndex
        return parsed
      }
    }

    const blockNodes: BBNode[] = []
    if (tryMatchBlock(state, blockNodes)) {
      appendInlineSegment(state.content.substring(inlineStart, idx), parsed.nodes, activeInlineTags)
      for (let i: number = 0; i < blockNodes.length; i++) {
        const inheritedTags: string[] = activeInlineTags.slice()
        for (let j: number = 0; j < blockNodes[i].inheritedFormatTags.length; j++) {
          inheritedTags.push(blockNodes[i].inheritedFormatTags[j])
        }
        blockNodes[i].inheritedFormatTags = inheritedTags
        parsed.nodes.push(blockNodes[i])
      }
      inlineStart = state.pos
      continue
    }
    state.pos = idx + 1
  }
  appendInlineSegment(state.content.substring(inlineStart, state.pos), parsed.nodes, activeInlineTags)
  return parsed
}

/** 块级 handler 函数签名。 */
type BlockHandler = (state: ParseState, result: BBNode[]) => boolean

/**
 * 标签名到块级 handler 的分派表。
 *
 * 每个 handler 仍复用原正则完成完整校验（如 [b] 仅 handlePostBy 会完整 exec），
 * 查表分派只跳过不可能匹配的 handler，不改变校验语义。
 */
const BLOCK_HANDLERS: Map<string, BlockHandler> = new Map<string, BlockHandler>([
  ['h', handleHeading],
  ['hr', handleHorizontalRule],
  ['p', handleParagraph],
  ['b', handlePostBy],
  ['quote', handleQuote],
  ['collapse', handleCollapse],
  ['code', handleCode],
  ['list', handleList],
  ['lessernuke', handleNuke],
  ['album', handleAlbum],
  ['flash', handleFlash],
  ['dice', handleDice],
  ['img', handleImg],
  ['l', handleFloatLeft],
  ['r', handleFloatRight],
  ['align', handleAlign],
  ['table', handleTable],
  ['style', handleStyle],
  ['hip', handleHip],
  ['comment', handleComment],
  ['randomblock', handleRandomBlock]
])

/**
 * 根据已读取的标签名调用唯一可能命中的块级 handler。
 *
 * 每个分支仍复用原 handler 完成完整正则校验，快速分派只跳过不可能匹配的 handler。
 *
 * @param state 解析游标
 * @param result 当前块级节点输出数组
 * @returns 是否命中任一块级标签
 */
function tryMatchBlock(state: ParseState, result: BBNode[]): boolean {
  const name: string = getBlockTagNameAt(state.content, state.pos)
  const handler: BlockHandler | undefined = BLOCK_HANDLERS.get(name)
  if (handler === undefined) return false
  return handler(state, result)
}

/**
 * 表格单元格标签属性（colspan/rowspan/colwidth）。
 */
class TdAttr {
  /** 跨列数。 */
  colSpan: number = 0
  /** 跨行数。 */
  rowSpan: number = 0
  /** 建议列宽。 */
  colWidth: number = 0
}

/**
 * 解析 [td...] 标签属性。
 *
 * 支持两种 NGA 真实语法：`[td=N]` / `[td=N,M]` / `[td=N,M,K]`（数字位置参数，
 * 依次为跨列、跨行、列宽）与 `[td rowspan=N]` / `[td colspan=N]`（空格命名参数，
 * 可组合）。其余属性形式忽略。
 *
 * @param attrRaw 标签内方括号之间的原文
 * @returns 解析出的单元格属性
 */
function parseTdAttributes(attrRaw: string): TdAttr {
  const attrs = new TdAttr()
  const trimmed: string = attrRaw.trim()
  if (trimmed.startsWith('=')) {
    const parts: string[] = trimmed.substring(1).split(',')
    if (parts.length >= 1 && /^\d+$/.test(parts[0])) attrs.colSpan = parseInt(parts[0], 10)
    if (parts.length >= 2 && /^\d+$/.test(parts[1])) attrs.rowSpan = parseInt(parts[1], 10)
    if (parts.length >= 3 && /^\d+$/.test(parts[2])) attrs.colWidth = parseInt(parts[2], 10)
    return attrs
  }
  P_SPAN_ATTR.lastIndex = 0
  let spanMatch: RegExpExecArray | null = P_SPAN_ATTR.exec(trimmed)
  while (spanMatch) {
    if (spanMatch[1].toLowerCase() === 'rowspan') attrs.rowSpan = parseInt(spanMatch[2], 10)
    else attrs.colSpan = parseInt(spanMatch[2], 10)
    spanMatch = P_SPAN_ATTR.exec(trimmed)
  }
  return attrs
}

/**
 * 查找与当前单元格匹配的 [/td] 位置，跳过单元格内嵌套表格的 [/td]。
 *
 * 嵌套 [table] 深度不为 0 时的 [/td] 属于内层表格，不作为单元格结束符；
 * 与 findListBlockEnd 的配对策略一致。嵌套 [table] 未闭合（扫描至正文末尾
 * 深度仍未归零）时退化为按最近一个 [/td] 结束，避免单元格吞噬整个剩余正文，
 * 未闭合的 [table] 交由单元格内递归解析降级为文字，后续单元格内容不丢失。
 *
 * @param state 已位于单元格内容起点之后的解析游标
 * @returns 单元格 [/td] 位置；不存在任何 [/td] 时返回 -1
 */
function findTdClose(state: ParseState): number {
  let depth: number = 0
  let position: number = state.pos
  const firstTdClose: number = indexOfIgnoreCase(state.content, '[/td]', state.pos)
  while (position < state.len) {
    const bracketIndex: number = state.content.indexOf('[', position)
    if (bracketIndex < 0) return firstTdClose
    if (matchesIgnoreCaseAt(state.content, '[table]', bracketIndex)) {
      depth++
      position = bracketIndex + 7
    } else if (matchesIgnoreCaseAt(state.content, '[/table]', bracketIndex)) {
      depth--
      position = bracketIndex + 8
    } else if (matchesIgnoreCaseAt(state.content, '[/td]', bracketIndex)) {
      if (depth === 0) return bracketIndex
      position = bracketIndex + 5
    } else {
      position = bracketIndex + 1
    }
  }
  return firstTdClose
}

/** 单元格 span 属性正则（模块级常量，避免每单元格重复构造）。 */
const P_SPAN_ATTR: RegExp = /\b(rowspan|colspan)\s*=\s*(\d+)/gi

/**
 * 解析表格行：遇 [/table] 返回，遇 [tr] 解析一行单元格。
 *
 * 快路径实现：三个"从 state.pos 找下一个出现"的独立扫描（边界正则 exec、
 * [tr] 正则 exec、indexOf('[')）合并为单次 indexOf + 当前位置字符级匹配。
 * 原 closePattern.exec 每轮可能扫描至表尾（284 行 × 表长 的重复扫描），
 * 现仅对命中的 `[` 位置做常数次 matchesIgnoreCaseAt。
 *
 * @param state 解析游标
 * @param closeTag 表格结束标签（如 '[/table]'，大小写不敏感匹配）
 * @returns 表格行与表级杂散文本节点
 */
function parseTableContent(state: ParseState, closeTag: string): BBNode[] {
  const rows: BBNode[] = []
  while (state.pos < state.len) {
    // 边界优先于 [tr]，与既有行为一致（原 closePattern 检查在前）
    if (matchesIgnoreCaseAt(state.content, closeTag, state.pos)) {
      state.pos += closeTag.length
      return rows
    }
    if (matchesIgnoreCaseAt(state.content, '[tr]', state.pos)) {
      state.pos += 4
      const row = createBBNode()
      row.type = BBNodeType.TABLE_ROW
      row.children = parseTableRowCells(state)
      rows.push(row)
      continue
    }
    // [tr] 之间的杂散内容（含 <br/> 预处理后的换行分隔）保留为表级文本节点。
    // 渲染层按 TABLE_ROW 消费时忽略，纯文本提取可保留行间分隔。
    const nextBracket: number = state.content.indexOf('[', state.pos)
    if (nextBracket < 0) {
      pushTextNode(rows, state.content.substring(state.pos, state.len))
      state.pos = state.len
      break
    }
    if (nextBracket > state.pos) {
      pushTextNode(rows, state.content.substring(state.pos, nextBracket))
      state.pos = nextBracket
    } else {
      state.pos = state.pos + 1
    }
  }
  return rows
}

/** 单元格开始标签正则（模块级常量，避免每单元格重复构造）。 */
const P_TD: RegExp = /\[td([^\]]*)\]/gi

/** 解析表格行内的 [td] 单元格，处理 colspan/rowspan/colwidth 属性。 */
function parseTableRowCells(state: ParseState): BBNode[] {
  const cells: BBNode[] = []
  while (state.pos < state.len) {
    const trClose = indexOfIgnoreCase(state.content, '[/tr]', state.pos)
    // 与 trClose 一致使用大小写不敏感查找，避免 [TD ROWSPAN=...] 大写变体整行丢失
    const tdOpen = indexOfIgnoreCase(state.content, '[td', state.pos)
    if (tdOpen < 0 || (trClose >= 0 && trClose < tdOpen)) {
      if (trClose >= 0) state.pos = trClose + 5
      break
    }

    P_TD.lastIndex = state.pos
    const tdm = P_TD.exec(state.content)
    // 匹配 [td...] 即视为单元格；未知属性由 parseTdAttributes 忽略，
    // 确保 [td foo=1] 等非法属性形式的单元格内容不丢失
    if (tdm && tdm.index === state.pos) {
      state.pos = P_TD.lastIndex
      const attr: TdAttr = parseTdAttributes(tdm[1])
      const cell = createBBNode()
      cell.type = BBNodeType.TABLE_CELL
      if (attr.colSpan > 0) cell.colSpan = attr.colSpan
      if (attr.rowSpan > 0) cell.rowSpan = attr.rowSpan
      if (attr.colWidth > 0) cell.colWidth = attr.colWidth

      const closeTdIdx = findTdClose(state)
      const cellEnd = closeTdIdx >= 0 ? closeTdIdx : state.len
      const cellText = state.content.substring(state.pos, cellEnd)
      state.pos = closeTdIdx >= 0 ? cellEnd + 5 : state.len
      cell.children = parseBBCode(cellText)
      cells.push(cell)
    } else {
      // [td] 之间的杂散内容（含 <br/> 预处理后的换行分隔）保留为行级文本节点。
      // 渲染层按 TABLE_CELL 消费时忽略，纯文本提取可保留单元格间分隔。
      const nextBracket: number = state.content.indexOf('[', state.pos)
      if (nextBracket < 0) {
        pushTextNode(cells, state.content.substring(state.pos, state.len))
        state.pos = state.len
        break
      }
      if (nextBracket > state.pos) {
        pushTextNode(cells, state.content.substring(state.pos, nextBracket))
        state.pos = nextBracket
      } else {
        state.pos = state.pos + 1
      }
    }
  }
  return cells
}

/**
 * 移除列表项边缘的空白文本节点，保持原有 itemText.trim() 的显示语义。
 *
 * @param nodes 列表项的块级与内联节点
 */
function trimListItemWhitespace(nodes: BBNode[]): void {
  if (nodes.length > 0 && nodes[0].type === BBNodeType.TEXT) {
    nodes[0].text = nodes[0].text.replace(/^\s+/, '')
    if (nodes[0].text.length === 0) nodes.splice(0, 1)
  }
  if (nodes.length > 0 && nodes[nodes.length - 1].type === BBNodeType.TEXT) {
    const lastIndex: number = nodes.length - 1
    nodes[lastIndex].text = nodes[lastIndex].text.replace(/\s+$/, '')
    if (nodes[lastIndex].text.length === 0) nodes.splice(lastIndex, 1)
  }
}

/**
 * 创建列表项节点并接管给定的子节点。
 *
 * @param children 列表项正文节点
 * @returns 列表项节点
 */
function createListItem(children: BBNode[]): BBNode {
  const item: BBNode = createBBNode()
  item.type = BBNodeType.LIST_ITEM
  item.children = children
  return item
}

/**
 * 解析列表项：只在当前列表层级的 [*] 或 [/list] 处截断。
 *
 * 嵌套列表与代码、引用等块由 parseBlockNodesUntil 完整消费，内部边界不会泄漏到外层。
 * 列表开头存在非空正文时将其保留为隐式列表项，避免异常输入丢失内容。
 *
 * @param state 已位于 [list] 开始标签之后的解析游标
 * @returns 当前列表直属的列表项节点
 */
function parseListItems(state: ParseState): BBNode[] {
  const items: BBNode[] = []
  const boundaryPattern: RegExp = /\[\*\]|\[\/list\]/gi
  const leading: BlockParseResult = parseBlockNodesUntil(state, boundaryPattern)
  trimListItemWhitespace(leading.nodes)
  if (leading.nodes.length > 0) items.push(createListItem(leading.nodes))

  let terminator: string = leading.terminator.toLowerCase()
  while (terminator === '[*]') {
    const itemBody: BlockParseResult = parseBlockNodesUntil(state, boundaryPattern)
    trimListItemWhitespace(itemBody.nodes)
    items.push(createListItem(itemBody.nodes))
    terminator = itemBody.terminator.toLowerCase()
  }
  return items
}

export { parseBBCode, parseBlockNodes, parseTableContent, parseListItems }
