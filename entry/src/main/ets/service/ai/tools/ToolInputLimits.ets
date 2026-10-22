/**
 * 工具输入的硬性长度约束（纯函数，可独立单元测试）。
 *
 * 两类约束都来自服务端实测；客户端不裁剪就等于把「必然失败」的请求发出去：
 *
 * 1. **联网搜索（DeepSeek Search API）**：`query` 必须为 1~128 个 Unicode 字符，
 *    超长直接返回 4xx，服务端**不会**自动截断（见 api-docs.deepseek.com Search）。
 * 2. **NGA 站内主题搜索**（`app_api.php subject/search`）：`key` 的 GBK 编码长度
 *    必须 ≤ 149 字节，超出返回 `code=102`「关键字过短/长」。实测边界：
 *    ASCII 149 字符可用、150 字符失败；汉字 74 字（148 字节）可用、75 字
 *    （150 字节）失败——NGA 是 GBK 站点，服务端按 **GBK 字节** 计算长度，
 *    用 UTF-8 字节数（汉字 3 字节）判断会低估上限。
 *
 * 因此这里提供两类裁剪：
 * - 按 Unicode 码点裁剪（联网搜索用，保证不切坏 emoji 等代理对）；
 * - 按 GBK 字节裁剪（NGA 搜索用）。
 */

/** 联网搜索 query 的字符上限（DeepSeek Search API：1~128 个 Unicode 字符）。 */
export const MAX_WEB_SEARCH_QUERY_CODE_POINTS: number = 128

/** NGA 站内搜索 key 的 GBK 字节上限（实测 149 字节内可用，150 字节起报 102）。 */
export const NGA_SEARCH_KEY_MAX_GBK_BYTES: number = 149

/** 裁剪结果。 */
export class LimitedText {
  /** 裁剪后的文本（未裁剪时等于原文） */
  text: string = ''
  /** 是否发生裁剪 */
  truncated: boolean = false
}

/**
 * 读取指定下标处一个「字符」占用的 UTF-16 单元数。
 *
 * 高代理 + 低代理组成一个码点，占 2 个单元；其余占 1 个。
 *
 * @param text - 原文
 * @param index - 起始下标
 * @returns 1 或 2
 */
function codePointWidthAt(text: string, index: number): number {
  const code: number = text.charCodeAt(index)
  if (code >= 0xD800 && code <= 0xDBFF && index + 1 < text.length) {
    const low: number = text.charCodeAt(index + 1)
    if (low >= 0xDC00 && low <= 0xDFFF) {
      return 2
    }
  }
  return 1
}

/**
 * 计算文本在 GBK 编码下的字节数。
 *
 * GBK 无法表示的字符（emoji 等代理对）按 4 字节保守计：宁可早截断，
 * 也不要让请求落在服务端的「过短/长」判定上。ASCII 计 1 字节，其余计 2 字节。
 *
 * @param text - 原文
 * @returns GBK 字节数
 */
export function gbkByteLength(text: string): number {
  let bytes: number = 0
  let index: number = 0
  while (index < text.length) {
    const width: number = codePointWidthAt(text, index)
    if (width === 2) {
      bytes += 4
      index += 2
      continue
    }
    bytes += text.charCodeAt(index) < 0x80 ? 1 : 2
    index += 1
  }
  return bytes
}

/**
 * 按 Unicode 码点数裁剪文本（不切断代理对）。
 *
 * @param text - 原文
 * @param maxCodePoints - 码点上限
 * @returns 裁剪结果
 */
export function truncateToCodePoints(text: string, maxCodePoints: number): LimitedText {
  const result: LimitedText = new LimitedText()
  const limit: number = Math.max(0, maxCodePoints)
  let index: number = 0
  let count: number = 0
  while (index < text.length && count < limit) {
    index += codePointWidthAt(text, index)
    count += 1
  }
  result.text = text.substring(0, index)
  result.truncated = index < text.length
  return result
}

/**
 * 按 GBK 字节数裁剪文本（不切断代理对）。
 *
 * @param text - 原文
 * @param maxBytes - GBK 字节上限
 * @returns 裁剪结果
 */
export function truncateToGbkBytes(text: string, maxBytes: number): LimitedText {
  const result: LimitedText = new LimitedText()
  const limit: number = Math.max(0, maxBytes)
  let index: number = 0
  let bytes: number = 0
  while (index < text.length) {
    const width: number = codePointWidthAt(text, index)
    const cost: number = width === 2 ? 4 : (text.charCodeAt(index) < 0x80 ? 1 : 2)
    if (bytes + cost > limit) {
      break
    }
    bytes += cost
    index += width
  }
  result.text = text.substring(0, index)
  result.truncated = index < text.length
  return result
}

/**
 * 判断文本是否含非 ASCII 字符。
 *
 * @param text - 原文
 * @returns true 表示含非 ASCII 字符
 */
export function containsNonAscii(text: string): boolean {
  for (let i: number = 0; i < text.length; i++) {
    if (text.charCodeAt(i) > 0x7F) {
      return true
    }
  }
  return false
}
