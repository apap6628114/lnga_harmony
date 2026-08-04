import { BBNode, BBNodeType } from '../../../model/BBCodeNode'
import { createBBNode, ParseState } from '../lexer'
import { parseInlineInto } from '../inline-parser'
import { parseBlockNodes } from '../parser'

/**
 * [quote] 块级引用处理器。
 * 可选地匹配紧跟其后的 [pid=...]Reply[/pid] [b]Post by ...[/b] 头部，再递归解析 [/quote] 前的正文。
 *
 * @param state 解析游标
 * @param result 当前块级节点输出数组
 * @returns 是否匹配并消费了 [quote] 块
 */
export const handleQuote = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  let pQuote: RegExp = /\[quote\]/gi
  pQuote.lastIndex = state.pos
  const qm = pQuote.exec(state.content)
  if (qm && qm.index === state.pos) {
    state.pos = pQuote.lastIndex
    const n = createBBNode()
    n.type = BBNodeType.QUOTE

    let pQuoteHeader: RegExp = /\[pid=(\d+),(\d+),(\d+)\]Reply\[\/pid\] \[b\]Post by \[uid=(\d+)\](.*?)\[\/uid\] \(([^)]+)\):\[\/b\]/gi
    pQuoteHeader.lastIndex = state.pos
    const qhm = pQuoteHeader.exec(state.content)
    if (qhm && qhm.index === state.pos) {
      const headerBody = `pid=${qhm[1]},${qhm[2]},${qhm[3]}]Reply[/pid] Post by [uid=${qhm[4]}]${qhm[5]}[/uid] (${qhm[6]}):`
      const childNodes: BBNode[] = []
      parseInlineInto('[' + headerBody, childNodes)
      const headerNode = createBBNode()
      headerNode.type = BBNodeType.POST_BY
      headerNode.children = childNodes
      n.children.push(headerNode)
      state.pos = pQuoteHeader.lastIndex
      const pSkipBreak: RegExp = /(?:\r?\n)+/g
      pSkipBreak.lastIndex = state.pos
      const breakMatch: RegExpExecArray | null = pSkipBreak.exec(state.content)
      if (breakMatch && breakMatch.index === state.pos) {
        state.pos = pSkipBreak.lastIndex
      }
    }

    let pCloseQuote: RegExp = /\[\/quote\]/gi
    const bodyChildren = parseBlockNodes(state, pCloseQuote)
    for (let i = 0; i < bodyChildren.length; i++) {
      n.children.push(bodyChildren[i])
    }
    result.push(n)
    return true
  }

  state.pos = savedPos
  return false
}
