import { BBNode, BBNodeType } from '../../model/BBCodeNode'
import { ParseState, preprocessContent, createBBNode, indexOfIgnoreCase } from './lexer'
import { MAX_INLINE_DEPTH, MAX_INLINE_TAG_LENGTH, parseInlineInto } from './inline-parser'
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

/** 公共入口：预处理后从顶层解析块级节点。 */
function parseBBCode(content: string): BBNode[] {
  if (!content) return []
  const state = new ParseState()
  state.content = preprocessContent(content)
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

/**
 * 更新跨块节点延续的内联样式栈。
 *
 * @param segment 尚未解码的正文片段
 * @param activeTags 当前仍处于打开状态的开始标签
 */
function updateActiveInlineTags(segment: string, activeTags: string[]): void {
  const tagPattern: RegExp = /\[(\/)?(b|item|i|u|del|color|size|font|sub|sup|url|pid|uid|tid)(?:=[^\]]*)?\]/gi
  let match: RegExpExecArray | null = tagPattern.exec(segment)
  while (match) {
    if (match[0].length > MAX_INLINE_TAG_LENGTH) {
      match = tagPattern.exec(segment)
      continue
    }
    const name: string = match[2].toLowerCase()
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
    match = tagPattern.exec(segment)
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

/** 块级循环：只在真实块标签处分段，遇指定闭合标签时返回。 */
function parseBlockNodes(state: ParseState, closePattern: RegExp | null): BBNode[] {
  const result: BBNode[] = []
  const activeInlineTags: string[] = []
  let inlineStart: number = state.pos

  while (state.pos < state.len) {
    const idx: number = state.content.indexOf('[', state.pos)
    if (idx < 0) {
      appendInlineSegment(state.content.substring(inlineStart, state.len), result, activeInlineTags)
      state.pos = state.len
      return result
    }
    state.pos = idx

    if (closePattern) {
      closePattern.lastIndex = idx
      const closeMatch: RegExpExecArray | null = closePattern.exec(state.content)
      if (closeMatch && closeMatch.index === idx) {
        appendInlineSegment(state.content.substring(inlineStart, idx), result, activeInlineTags)
        state.pos = closePattern.lastIndex
        return result
      }
    }

    const blockNodes: BBNode[] = []
    if (tryMatchBlock(state, blockNodes)) {
      appendInlineSegment(state.content.substring(inlineStart, idx), result, activeInlineTags)
      for (let i: number = 0; i < blockNodes.length; i++) {
        const inheritedTags: string[] = activeInlineTags.slice()
        for (let j: number = 0; j < blockNodes[i].inheritedFormatTags.length; j++) {
          inheritedTags.push(blockNodes[i].inheritedFormatTags[j])
        }
        blockNodes[i].inheritedFormatTags = inheritedTags
        result.push(blockNodes[i])
      }
      inlineStart = state.pos
      continue
    }
    state.pos = idx + 1
  }
  appendInlineSegment(state.content.substring(inlineStart, state.pos), result, activeInlineTags)
  return result
}

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
  if (name === 'h') return handleHeading(state, result)
  if (name === 'hr') return handleHorizontalRule(state, result)
  if (name === 'p') return handleParagraph(state, result)
  if (name === 'b') return handlePostBy(state, result)
  if (name === 'quote') return handleQuote(state, result)
  if (name === 'collapse') return handleCollapse(state, result)
  if (name === 'code') return handleCode(state, result)
  if (name === 'list') return handleList(state, result)
  if (name === 'lessernuke') return handleNuke(state, result)
  if (name === 'album') return handleAlbum(state, result)
  if (name === 'flash') return handleFlash(state, result)
  if (name === 'dice') return handleDice(state, result)
  if (name === 'img') return handleImg(state, result)
  if (name === 'l') return handleFloatLeft(state, result)
  if (name === 'r') return handleFloatRight(state, result)
  if (name === 'align') return handleAlign(state, result)
  if (name === 'table') return handleTable(state, result)
  if (name === 'style') return handleStyle(state, result)
  if (name === 'hip') return handleHip(state, result)
  if (name === 'comment') return handleComment(state, result)
  if (name === 'randomblock') return handleRandomBlock(state, result)
  return false
}

/** 解析表格行：遇 [/table] 返回，遇 [tr] 解析一行单元格。 */
function parseTableContent(state: ParseState, closePattern: RegExp): BBNode[] {
  const rows: BBNode[] = []
  while (state.pos < state.len) {
    closePattern.lastIndex = state.pos
    const cm = closePattern.exec(state.content)
    if (cm && cm.index === state.pos) {
      state.pos = closePattern.lastIndex
      return rows
    }

    let pTr: RegExp = /\[tr\]/gi
    pTr.lastIndex = state.pos
    const trm = pTr.exec(state.content)
    if (trm && trm.index === state.pos) {
      state.pos = pTr.lastIndex
      const row = createBBNode()
      row.type = BBNodeType.TABLE_ROW
      row.children = parseTableRowCells(state)
      rows.push(row)
      continue
    }
    state.pos = state.pos + 1
  }
  return rows
}

/** 解析表格行内的 [td] 单元格，处理 colspan/rowspan/colwidth 属性。 */
function parseTableRowCells(state: ParseState): BBNode[] {
  const cells: BBNode[] = []
  while (state.pos < state.len) {
    const trClose = indexOfIgnoreCase(state.content, '[/tr]', state.pos)
    const tdOpen = state.content.indexOf('[td', state.pos)
    if (tdOpen < 0 || (trClose >= 0 && trClose < tdOpen)) {
      if (trClose >= 0) state.pos = trClose + 5
      break
    }

    let pTd: RegExp = /\[td(?:=(\d+))?(?:,(\d+))?(?:,(\d+))?\]/gi
    pTd.lastIndex = state.pos
    const tdm = pTd.exec(state.content)
    if (tdm && tdm.index === state.pos) {
      state.pos = pTd.lastIndex
      const cell = createBBNode()
      cell.type = BBNodeType.TABLE_CELL
      if (tdm[1]) cell.colSpan = parseInt(tdm[1], 10)
      if (tdm[2]) cell.rowSpan = parseInt(tdm[2], 10)
      if (tdm[3]) cell.colWidth = parseInt(tdm[3], 10)

      const closeTdIdx = indexOfIgnoreCase(state.content, '[/td]', state.pos)
      const cellEnd = closeTdIdx >= 0 ? closeTdIdx : state.len
      const cellText = state.content.substring(state.pos, cellEnd)
      state.pos = closeTdIdx >= 0 ? cellEnd + 5 : state.len
      cell.children = parseBBCode(cellText)
      cells.push(cell)
    } else {
      state.pos = state.pos + 1
    }
  }
  return cells
}

/** 解析列表项：[*] 分隔，每项 trim 后递归解析。 */
function parseListItems(state: ParseState): BBNode[] {
  const items: BBNode[] = []
  while (state.pos < state.len) {
    const starIdx = state.content.indexOf('[*]', state.pos)
    const closeIdx = indexOfIgnoreCase(state.content, '[/list]', state.pos)
    if (starIdx < 0 || (closeIdx >= 0 && starIdx > closeIdx)) {
      if (closeIdx >= 0) state.pos = closeIdx + 7
      else state.pos = state.len
      break
    }
    state.pos = starIdx + 3
    let itemEnd = state.content.indexOf('[*]', state.pos)
    const listClose = indexOfIgnoreCase(state.content, '[/list]', state.pos)
    if (itemEnd < 0 || (listClose >= 0 && itemEnd > listClose)) {
      itemEnd = listClose >= 0 ? listClose : state.len
    }
    const itemText = state.content.substring(state.pos, itemEnd)
    state.pos = itemEnd
    const n = createBBNode()
    n.type = BBNodeType.LIST_ITEM
    n.children = parseBBCode(itemText.trim())
    items.push(n)
  }
  return items
}

export { parseBBCode, parseBlockNodes, parseTableContent, parseListItems }
