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
/** [flash=video] 标签正则。 */
const P_FLASH_VIDEO: RegExp = /\[flash=video\]/iy

/** [flash=audio] 标签正则。 */
const P_FLASH_AUDIO: RegExp = /\[flash=audio\]/iy

/** 无类型 [flash] 标签正则（含惰性匹配内容捕获）。 */
const P_FLASH: RegExp = /\[flash\](.*?)\[\/flash\]/iy

export const handleFlash = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  P_FLASH_VIDEO.lastIndex = state.pos
  const fvm = P_FLASH_VIDEO.exec(state.content)
  if (fvm && fvm.index === state.pos) {
    state.pos = P_FLASH_VIDEO.lastIndex
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

  P_FLASH_AUDIO.lastIndex = state.pos
  const fam = P_FLASH_AUDIO.exec(state.content)
  if (fam && fam.index === state.pos) {
    state.pos = P_FLASH_AUDIO.lastIndex
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

  P_FLASH.lastIndex = state.pos
  const ffm = P_FLASH.exec(state.content)
  if (ffm && ffm.index === state.pos) {
    state.pos = P_FLASH.lastIndex
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
