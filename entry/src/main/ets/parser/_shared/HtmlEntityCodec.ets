/**
 * HTML 实体解码统一工具
 *
 * 项目内存在两类语义不同的解码需求，此处集中导出，避免多份重复实现：
 * - `decodeHtmlEntities`：BBCode 文字载荷解码。服务端真实 HTML 必须在调用前完成结构化处理，
 *   避免转义文字在解码后又被误判为标签删除。
 * - `unescapeHtml`：纯文本字段（用户名、标题、签名、消息内容等）解码，仅反转实体，
 *   不触碰 `<`、标签或换行，避免吞掉合法文本。
 *
 * 两者都支持 `&#91;` / `&#93;` / `&nbsp;` / `&#十进制;` / `&#x十六进制;`（含 BMP 之外代理对编码）。
 * 命名实体（&amp; / &lt; / &mdash; / &hellip; 等）统一查表转换，未命中则保留原文。
 */

/**
 * 把单个码点转为字符串，码点在 BMP 之外时输出 UTF-16 代理对。
 *
 * @param code Unicode 码点
 * @returns 对应字符（含代理对）
 */
function fromCodePoint(code: number): string {
  if (code <= 0xFFFF) return String.fromCharCode(code)
  const hi: number = 0xD800 + ((code - 0x10000) >> 10)
  const lo: number = 0xDC00 + ((code - 0x10000) & 0x3FF)
  return String.fromCharCode(hi) + String.fromCharCode(lo)
}

const NAMED_ENTITIES: Map<string, string> = new Map<string, string>([
  ['amp', '&'], ['lt', '<'], ['gt', '>'], ['quot', '"'],
  ['nbsp', ' '], ['emsp', '\u2003'], ['ensp', '\u2002'], ['thinsp', '\u2009'],
  ['zwnj', ''], ['zwj', ''],
  ['mdash', '\u2014'], ['ndash', '\u2013'],
  ['lsquo', '\u2018'], ['rsquo', '\u2019'], ['ldquo', '\u201C'], ['rdquo', '\u201D'],
  ['hellip', '\u2026'],
  ['copy', '\u00A9'], ['reg', '\u00AE'], ['trade', '\u2122'],
  ['laquo', '\u00AB'], ['raquo', '\u00BB'],
  ['times', '\u00D7'], ['divide', '\u00F7'], ['plusmn', '\u00B1'],
  ['deg', '\u00B0'], ['middot', '\u00B7'],
])

/**
 * 反转 HTML 实体为字符，不处理标签或换行。适用于纯文本字段显示。
 *
 * @param s 待解码字符串
 * @returns 解码后的字符串
 */
export function unescapeHtml(s: string): string {
  if (!s) return ''
  // 快速路径：不含 & 的字符串不可能命中任何实体模式，原串直返
  //（真实楼层正文绝大多数文本片段无实体，避免每次调用跑 5 个链式 replace）
  if (s.indexOf('&') < 0) return s
  return s
    .replace(/&#91;/g, '[')
    .replace(/&#93;/g, ']')
    .replace(/&(\w+);/g, (_s: string, name: string): string => NAMED_ENTITIES.get(name) ?? _s)
    .replace(/&#(\d+);/g, (_s: string, c: string): string => fromCodePoint(parseInt(c, 10)))
    .replace(/&#x([0-9a-fA-F]+);/g, (_s: string, hex: string): string => fromCodePoint(parseInt(hex, 16)))
}

/**
 * 反转 BBCode 文字载荷中的 HTML 实体，不处理真实 HTML 标签。
 * 标签清理由 BBCode 预处理阶段在实体解码前完成。
 *
 * @param s 待解码的 BBCode 正文片段
 * @returns 解码并清理后的文本
 */
export function decodeHtmlEntities(s: string): string {
  return unescapeHtml(s)
}
