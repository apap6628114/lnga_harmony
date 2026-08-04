import { BBNode, BBNodeType } from '../../../model/BBCodeNode'
import { createBBNode, indexOfIgnoreCase, matchesIgnoreCaseAt, ParseState, pushTextNode } from '../lexer'
import { parseListItems } from '../parser'

/** 列表解析允许的最大嵌套层数。 */
export const MAX_LIST_DEPTH: number = 32

/**
 * 查找当前列表对应的闭合位置，供深度超限时整体降级为文字。
 *
 * 代码块内容按原文跳过，避免其中的列表标记参与结构计数。
 *
 * @param content 完整正文
 * @param start 当前 [list] 开始标签之后的位置
 * @returns 匹配闭合标签之后的位置；缺少闭合标签时返回正文末尾
 */
function findListBlockEnd(content: string, start: number): number {
  let depth: number = 1
  let position: number = start
  while (position < content.length) {
    const bracketIndex: number = content.indexOf('[', position)
    if (bracketIndex < 0) return content.length
    if (matchesIgnoreCaseAt(content, '[code]', bracketIndex)) {
      const codeClose: number = indexOfIgnoreCase(content, '[/code]', bracketIndex + 6)
      if (codeClose < 0) return content.length
      position = codeClose + 7
    } else if (matchesIgnoreCaseAt(content, '[list]', bracketIndex)) {
      depth++
      position = bracketIndex + 6
    } else if (matchesIgnoreCaseAt(content, '[/list]', bracketIndex)) {
      depth--
      position = bracketIndex + 7
      if (depth === 0) return position
    } else {
      position = bracketIndex + 1
    }
  }
  return content.length
}

/**
 * [list]列表块处理器。解析 [*] 分隔的列表项。
 *
 * @param state 解析游标
 * @param result 当前块级节点输出数组
 * @returns 是否匹配并消费了 [list] 块
 */
export const handleList = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  let pList: RegExp = /\[list\]/gi
  pList.lastIndex = state.pos
  const lm = pList.exec(state.content)
  if (lm && lm.index === state.pos) {
    state.pos = pList.lastIndex
    if (state.listDepth >= MAX_LIST_DEPTH) {
      const literalEnd: number = findListBlockEnd(state.content, state.pos)
      pushTextNode(result, state.content.substring(savedPos, literalEnd))
      state.pos = literalEnd
      return true
    }
    const n = createBBNode()
    n.type = BBNodeType.LIST
    state.listDepth++
    n.children = parseListItems(state)
    state.listDepth--
    result.push(n)
    return true
  }

  state.pos = savedPos
  return false
}
