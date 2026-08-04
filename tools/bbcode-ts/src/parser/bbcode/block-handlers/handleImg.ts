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
export const handleImg = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  let pNgaImg: RegExp = /\[img\]\.(\/mon_\S+?)\[\/img\]/gi
  pNgaImg.lastIndex = state.pos
  const ncm = pNgaImg.exec(state.content)
  if (ncm && ncm.index === state.pos) {
    const rawUrl = ncm[1]
    state.pos = pNgaImg.lastIndex
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

  let pImg: RegExp = /\[img\](.*?)\[\/img\]/gi
  pImg.lastIndex = state.pos
  const im = pImg.exec(state.content)
  if (im && im.index === state.pos) {
    const rawUrl = im[1]
    state.pos = pImg.lastIndex
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
