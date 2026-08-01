import { BBNode, BBNodeType } from '../../../model/BBCodeNode'
import { createBBNode, indexOfIgnoreCase, ParseState } from '../lexer'
import { parseInlineInto } from '../inline-parser'
import { parseBBCode } from '../parser'

/**
 * `[b]Reply to [pid=...]...[/pid] Post by [uid=...]...[/uid] (...):` 块处理器。
 * 匹配整个回复引用头，将头部解析为 POST_BY 节点，再递归解析到 [/b] 前的附加正文。
 *
 * @param state 解析游标
 * @param result 当前块级节点输出数组
 * @returns 是否匹配并消费了该回复引用块
 */
export const handlePostBy = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  let pReplyRef: RegExp = /\[b\]Reply to \[pid=(\d+),(\d+),(\d+)\]Reply\[\/pid\] Post by \[uid=(\d+)\](.*?)\[\/uid\] \(([^)]+)\)/gi
  pReplyRef.lastIndex = state.pos
  const rrm = pReplyRef.exec(state.content)
  if (rrm && rrm.index === state.pos) {
    const headerEnd: number = pReplyRef.lastIndex
    const n = createBBNode()
    n.type = BBNodeType.POST_BY
    const headerBody: string = `pid=${rrm[1]},${rrm[2]},${rrm[3]}]Reply[/pid] Post by [uid=${rrm[4]}]${rrm[5]}[/uid] (${rrm[6]}):`
    const childNodes: BBNode[] = []
    parseInlineInto('[' + headerBody, childNodes)
    n.children = childNodes
    result.push(n)

    state.pos = headerEnd
    if (state.pos < state.len && state.content.charAt(state.pos) === ':') {
      state.pos++
    }

    const closeBIdx: number = indexOfIgnoreCase(state.content, '[/b]', state.pos)
    if (closeBIdx >= 0) {
      if (closeBIdx > state.pos) {
        const extraContent: string = state.content.substring(state.pos, closeBIdx)
        const extraNodes: BBNode[] = parseBBCode(extraContent)
        for (let i = 0; i < extraNodes.length; i++) {
          result.push(extraNodes[i])
        }
      }
      state.pos = closeBIdx + 4
    } else {
      state.pos = state.len
    }
    return true
  }
  state.pos = savedPos
  return false
}
