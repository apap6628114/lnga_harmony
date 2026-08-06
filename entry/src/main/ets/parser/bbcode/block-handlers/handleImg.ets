import { BBNode, BBNodeType } from '../../../model/BBCodeNode'
import { resolveImgUrl } from '../../_shared/AttachUrl'
import { createBBNode, isSafeUrl, resolveMediaUrl, ParseState } from '../lexer'
import { guessMediaTypeFromExt } from '../inline-parser'

/**
 * [img]图片块处理器。匹配 NGA 相对路径 [img]./mon_...[/img] 与普通 [img]URL[/img]，
 * 按扩展名推测真实媒体类型（GIF 转 MP4 等情况），否则按 IMAGE 处理。
 *
 * @param state 解析游标
 * @param result 当前块级节点输出数组
 * @returns 是否匹配并消费了某个 [img] 变体
 */
/** NGA 相对路径 [img]./mon_...[/img] 标签正则。 */
const P_NGA_IMG: RegExp = /\[img\]\.(\/mon_\S+?)\[\/img\]/iy

/** 普通 [img]URL[/img] 标签正则（含惰性匹配 URL 捕获）。 */
const P_IMG: RegExp = /\[img\](.*?)\[\/img\]/iy

export const handleImg = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  P_NGA_IMG.lastIndex = state.pos
  const ncm = P_NGA_IMG.exec(state.content)
  if (ncm && ncm.index === state.pos) {
    const rawUrl = ncm[1]
    state.pos = P_NGA_IMG.lastIndex
    const n = createBBNode()
    const guessedType: BBNodeType = guessMediaTypeFromExt(rawUrl)
    if (guessedType === BBNodeType.VIDEO || guessedType === BBNodeType.AUDIO) {
      n.type = guessedType
      n.src = isSafeUrl(rawUrl) ? resolveMediaUrl(rawUrl) : ''
    } else {
      n.type = BBNodeType.IMAGE
      n.src = resolveImgUrl(rawUrl)
    }
    result.push(n)
    return true
  }

  P_IMG.lastIndex = state.pos
  const im = P_IMG.exec(state.content)
  if (im && im.index === state.pos) {
    const rawUrl = im[1]
    state.pos = P_IMG.lastIndex
    const n = createBBNode()
    const guessedType: BBNodeType = guessMediaTypeFromExt(rawUrl)
    if (guessedType === BBNodeType.VIDEO || guessedType === BBNodeType.AUDIO) {
      n.type = guessedType
      n.src = isSafeUrl(rawUrl) ? resolveMediaUrl(rawUrl) : ''
    } else {
      n.type = BBNodeType.IMAGE
      n.src = resolveImgUrl(rawUrl)
    }
    result.push(n)
    return true
  }

  state.pos = savedPos
  return false
}
