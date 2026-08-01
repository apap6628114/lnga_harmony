import { BBNode, BBNodeType } from '../../../model/BBCodeNode'
import { decodeHtmlEntities } from '../../_shared/HtmlEntityCodec'
import { createBBNode, ParseState } from '../lexer'
import { parseBlockNodes } from '../parser'

/**
 * [collapse=标题]折叠块处理器。递归解析到 [/collapse] 前的正文。
 *
 * @param state 解析游标
 * @param result 当前块级节点输出数组
 * @returns 是否匹配并消费了 [collapse] 块
 */
export const handleCollapse = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  let pCollapse: RegExp = /\[collapse(?:=(.*?))?\]/gi
  pCollapse.lastIndex = state.pos
  const cm = pCollapse.exec(state.content)
  if (cm && cm.index === state.pos) {
    const title = cm[1] || '展开/折叠'
    state.pos = pCollapse.lastIndex
    const n = createBBNode()
    n.type = BBNodeType.COLLAPSE
    n.title = decodeHtmlEntities(title)
    let pCloseCollapse: RegExp = /\[\/collapse\]/gi
    n.children = parseBlockNodes(state, pCloseCollapse)
    result.push(n)
    return true
  }

  state.pos = savedPos
  return false
}
