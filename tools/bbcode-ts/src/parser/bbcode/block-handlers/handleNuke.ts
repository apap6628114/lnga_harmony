import { BBNode, BBNodeType } from '../../../model/BBCodeNode'
import { decodeHtmlEntities } from '../../_shared/HtmlEntityCodec'
import { createBBNode, indexOfIgnoreCase, ParseState } from '../lexer'
import { parseBlockNodes, parseBBCode } from '../parser'

/**
 * [lessernuke] 警告块处理器。递归解析到 [/lessernuke] 前的正文（decode 后整段重新解析）。
 *
 * @param state 解析游标
 * @param result 当前块级节点输出数组
 * @returns 是否匹配并消费了 [lessernuke] 块
 */
/** [lessernuke] 开始标签正则。 */
const P_LESSERNUKE: RegExp = /\[lessernuke\]/gi

/** [album=标题] 开始标签正则（含惰性匹配标题捕获）。 */
const P_ALBUM: RegExp = /\[album=(.*?)\]/gi

/** [album] 闭合标签正则。 */
const P_CLOSE_ALBUM: RegExp = /\[\/album\]/gi

export const handleNuke = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  P_LESSERNUKE.lastIndex = state.pos
  const lnm = P_LESSERNUKE.exec(state.content)
  if (lnm && lnm.index === state.pos) {
    state.pos = P_LESSERNUKE.lastIndex
    let end = indexOfIgnoreCase(state.content, '[/lessernuke]', state.pos)
    if (end < 0) end = state.len
    state.pos = end < state.len ? end + 13 : state.len
    const n = createBBNode()
    n.type = BBNodeType.WARN
    const bodyContent = parseBBCode(state.content.substring(P_LESSERNUKE.lastIndex, end < state.len ? end : state.len))
    n.children = bodyContent
    result.push(n)
    return true
  }

  state.pos = savedPos
  return false
}

/**
 * [album=标题]相册块处理器。递归解析到 [/album] 前的正文。
 *
 * @param state 解析游标
 * @param result 当前块级节点输出数组
 * @returns 是否匹配并消费了 [album] 块
 */
export const handleAlbum = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  P_ALBUM.lastIndex = state.pos
  const am = P_ALBUM.exec(state.content)
  if (am && am.index === state.pos) {
    const albumTitle = am[1]
    state.pos = P_ALBUM.lastIndex
    const n = createBBNode()
    n.type = BBNodeType.ALBUM
    n.title = decodeHtmlEntities(albumTitle)
    n.children = parseBlockNodes(state, P_CLOSE_ALBUM)
    result.push(n)
    return true
  }

  state.pos = savedPos
  return false
}
