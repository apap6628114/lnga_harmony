import { BBNode, BBNodeType } from '../../../model/BBCodeNode'
import { createBBNode, indexOfIgnoreCase, matchesIgnoreCaseAt, ParseState } from '../lexer'
import { parseInlineInto } from '../inline-parser'
import { parseBBCode } from '../parser'

/** 回复引用头的完整正则（含惰性匹配，构造与执行成本高）。 */
const P_REPLY_REF: RegExp = /\[b\]Reply to \[pid=(\d+),(\d+),(\d+)\]Reply\[\/pid\] Post by \[uid=(\d+)\](.*?)\[\/uid\] \(([^)]+)\)/iy

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

  // 快速路径：正文中绝大多数 [b] 是普通粗体标签而非回复引用头。
  // 正则以 '[b]Reply to ' 开头，字符级前缀预检不命中时直接返回，
  // 避免对每个 [b] 都执行含惰性匹配的高成本正则。
  if (!matchesIgnoreCaseAt(state.content, '[b]Reply to ', state.pos)) {
    return false
  }

  P_REPLY_REF.lastIndex = state.pos
  const rrm = P_REPLY_REF.exec(state.content)
  if (rrm && rrm.index === state.pos) {
    const headerEnd: number = P_REPLY_REF.lastIndex
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
