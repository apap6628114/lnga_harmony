import { BBNode, BBNodeType } from '../../../model/BBCodeNode'
import { createBBNode, indexOfIgnoreCase, isSafeUrl, resolveMediaUrl, ParseState } from '../lexer'
import { guessMediaTypeFromExt } from '../inline-parser'

/**
 * [flash] / [flash=video] / [flash=audio] 媒体块处理器。
 * - flash=video/audio：按标签显式确定 VIDEO/AUDIO 类型
 * - flash：根据 URL 扩展名推测 VIDEO/AUDIO/FLASH
 *
 * @param state 解析游标
 * @param result 当前块级节点输出数组
 * @returns 是否匹配并消费了某个 [flash] 变体
 */
export const handleFlash = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  let pFv: RegExp = /\[flash=video\]/gi
  pFv.lastIndex = state.pos
  const fvm = pFv.exec(state.content)
  if (fvm && fvm.index === state.pos) {
    state.pos = pFv.lastIndex
    let end = indexOfIgnoreCase(state.content, '[/flash]', state.pos)
    if (end < 0) end = state.len
    const rawUrl = state.content.substring(state.pos, end).trim()
    state.pos = end < state.len ? end + 8 : state.len
    const n = createBBNode()
    n.type = BBNodeType.VIDEO
    n.src = isSafeUrl(rawUrl) ? resolveMediaUrl(rawUrl) : ''
    result.push(n)
    return true
  }

  let pFa: RegExp = /\[flash=audio\]/gi
  pFa.lastIndex = state.pos
  const fam = pFa.exec(state.content)
  if (fam && fam.index === state.pos) {
    state.pos = pFa.lastIndex
    let end = indexOfIgnoreCase(state.content, '[/flash]', state.pos)
    if (end < 0) end = state.len
    const rawUrl = state.content.substring(state.pos, end).trim()
    state.pos = end < state.len ? end + 8 : state.len
    const n = createBBNode()
    n.type = BBNodeType.AUDIO
    n.src = isSafeUrl(rawUrl) ? resolveMediaUrl(rawUrl) : ''
    result.push(n)
    return true
  }

  let pFlash: RegExp = /\[flash\](.*?)\[\/flash\]/gi
  pFlash.lastIndex = state.pos
  const ffm = pFlash.exec(state.content)
  if (ffm && ffm.index === state.pos) {
    state.pos = pFlash.lastIndex
    const rawUrl: string = ffm[1].trim()
    const resolved: string = resolveMediaUrl(rawUrl)
    const safeSrc: string = isSafeUrl(resolved) ? resolved : ''
    const guessedType: BBNodeType = guessMediaTypeFromExt(resolved)
    const n = createBBNode()
    if (guessedType === BBNodeType.VIDEO) {
      n.type = BBNodeType.VIDEO
      n.src = safeSrc
    } else if (guessedType === BBNodeType.AUDIO) {
      n.type = BBNodeType.AUDIO
      n.src = safeSrc
    } else {
      /* 非视频/音频扩展名：flash 标签语义上即 FLASH 播放器，兜底为 FLASH 类型。 */
      n.type = BBNodeType.FLASH
      n.href = safeSrc
    }
    result.push(n)
    return true
  }

  state.pos = savedPos
  return false
}
