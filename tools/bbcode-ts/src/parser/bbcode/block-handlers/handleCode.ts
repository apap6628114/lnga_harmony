import { BBNode, BBNodeType } from '../../../model/BBCodeNode'
import { decodeHtmlEntities } from '../../_shared/HtmlEntityCodec'
import { createBBNode, indexOfIgnoreCase, ParseState } from '../lexer'

/**
 * [code]代码块处理器。提取到 [/code] 前的内容并解码实体，不做内联解析。
 *
 * @param state 解析游标
 * @param result 当前块级节点输出数组
 * @returns 是否匹配并消费了 [code] 块
 */
/** [code] 开始标签正则。 */
const P_CODE: RegExp = /\[code\]/iy

export const handleCode = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  P_CODE.lastIndex = state.pos
  const cdm = P_CODE.exec(state.content)
  if (cdm && cdm.index === state.pos) {
    state.pos = P_CODE.lastIndex
    let end = indexOfIgnoreCase(state.content, '[/code]', state.pos)
    if (end < 0) end = state.len
    const codeText = state.content.substring(state.pos, end)
    state.pos = end < state.len ? end + 7 : state.len
    const n = createBBNode()
    n.type = BBNodeType.CODE
    n.text = decodeHtmlEntities(codeText)
    result.push(n)
    return true
  }

  state.pos = savedPos
  return false
}
