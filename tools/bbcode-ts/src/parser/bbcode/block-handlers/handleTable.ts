import { BBNode, BBNodeType } from '../../../model/BBCodeNode'
import { createBBNode, ParseState } from '../lexer'
import { parseTableContent } from '../parser'

/**
 * [table]表格块处理器。按行/列结构解析到 [/table] 前的内容。
 *
 * @param state 解析游标
 * @param result 当前块级节点输出数组
 * @returns 是否匹配并消费了 [table] 块
 */
/** [table] 开始标签正则。 */
const P_TABLE: RegExp = /\[table\]/gi

export const handleTable = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  P_TABLE.lastIndex = state.pos
  const tm = P_TABLE.exec(state.content)
  if (tm && tm.index === state.pos) {
    state.pos = P_TABLE.lastIndex
    const n = createBBNode()
    n.type = BBNodeType.TABLE
    n.children = parseTableContent(state, '[/table]')
    result.push(n)
    return true
  }

  state.pos = savedPos
  return false
}
