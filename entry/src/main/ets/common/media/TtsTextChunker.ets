/**
 * TTS 文本分块纯函数。
 *
 * 按 TTS 单次请求上限与自然断句位置拆分长文本，避免在 Unicode 代理项中间
 * 切分。不依赖任何状态，可安全独立测试。
 */

/** TTS 单次合成请求的最大文本长度。 */
export const TTS_MAX_CHUNK_LEN: number = 10000

/**
 * 判断指定 UTF-16 编码单元是否为高位代理项。
 *
 * @param code UTF-16 编码单元。
 * @returns 是否为高位代理项。
 */
export function isHighSurrogate(code: number): boolean {
  return code >= 0xD800 && code <= 0xDBFF
}

/**
 * 判断指定 UTF-16 编码单元是否为低位代理项。
 *
 * @param code UTF-16 编码单元。
 * @returns 是否为低位代理项。
 */
export function isLowSurrogate(code: number): boolean {
  return code >= 0xDC00 && code <= 0xDFFF
}

/**
 * 避免在 Unicode 代理项中间切分文本。
 *
 * @param text 原始文本。
 * @param cutPosition 初始切分位置。
 * @returns 安全的切分位置。
 */
export function adjustSurrogateBoundary(text: string, cutPosition: number): number {
  if (cutPosition <= 0 || cutPosition >= text.length) {
    return cutPosition
  }
  const previousCode: number = text.charCodeAt(cutPosition - 1)
  const nextCode: number = text.charCodeAt(cutPosition)
  if (isHighSurrogate(previousCode) && isLowSurrogate(nextCode)) {
    return cutPosition - 1
  }
  return cutPosition
}

/**
 * 判断字符是否适合作为 TTS 文本段落的结束位置。
 *
 * @param character 待判断字符。
 * @returns 是否为自然断句字符。
 */
export function isSentenceBoundary(character: string): boolean {
  return character === '\n' || character === '。' || character === '！' ||
    character === '？' || character === '；' || character === '，' ||
    character === '.' || character === '!' || character === '?' ||
    character === ';' || character === ','
}

/**
 * 按 TTS 单次请求上限和自然断句位置拆分文本。
 *
 * @param text 待朗读文本。
 * @returns 拆分后的文本段落。
 */
export function splitText(text: string): string[] {
  if (text.length <= TTS_MAX_CHUNK_LEN) {
    return [text]
  }
  const chunks: string[] = []
  let start: number = 0
  while (start < text.length) {
    if (start + TTS_MAX_CHUNK_LEN >= text.length) {
      chunks.push(text.substring(start))
      break
    }
    let cutPosition: number = start + TTS_MAX_CHUNK_LEN
    for (let index: number = cutPosition - 1; index > start; index--) {
      if (isSentenceBoundary(text.charAt(index))) {
        cutPosition = index + 1
        break
      }
    }
    cutPosition = adjustSurrogateBoundary(text, cutPosition)
    chunks.push(text.substring(start, cutPosition))
    start = cutPosition
  }
  return chunks
}
