import { BBNode, BBNodeType } from '../../model/BBCodeNode'
import { decodeHtmlEntities } from '../_shared/HtmlEntityCodec'
import { NGA_CDN_BASE } from '../_shared/AttachUrl'
import { normalizeHeadingLinesOutsideCode } from './heading-normalizer'

/**
 * 词法/状态层：ParseState、节点工厂、文本预处理与 HTML 转义工具。
 * 供 parser / block-handlers / inline-parser 共享，是解析各阶段的公共基础设施。
 */

/** 当前进程内用于生成节点键的递增序号。 */
let bbNodeIdCounter: number = 0

/** 创建一个新的 BBNode 并分配全局自增 id。 */
function createBBNode(): BBNode {
  const n = new BBNode()
  n.id = ++bbNodeIdCounter
  return n
}

/**
 * 解析 [flash] / [flash=video] / [flash=audio] 标签内的媒体 URL。
 * 与 AttachUrl.resolveAttachUrl（附件对象字段语义）不同：此处保留 BBCode 原有语义——
 * http 原样、`./mon_` / `/mon_` 拼 CDN、其余原样返回，不剥离后缀（视频/音频扩展名有意义）。
 *
 * @param raw [flash] 标签原始内容
 * @returns 可访问的媒体 URL
 */
function resolveMediaUrl(raw: string): string {
  if (raw.startsWith('http')) return raw
  if (raw.startsWith('./mon_') || raw.startsWith('/mon_')) {
    const path: string = raw.startsWith('./') ? raw.substring(1) : raw
    return NGA_CDN_BASE + path
  }
  return raw
}

/** 判断 URL 是否属于可安全跳转/加载的白名单协议。 */
function isSafeUrl(url: string): boolean {
  const trimmed = url.trim().toLowerCase()
  if (/^javascript:/i.test(trimmed)) return false
  if (/^vbscript:/i.test(trimmed)) return false
  if (/^data:/i.test(trimmed)) return false
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://') || trimmed.startsWith('mailto:')) return true
  if (trimmed.startsWith('/') && !trimmed.startsWith('//')) return true
  if (trimmed.startsWith('./')) return true
  if (/^\w+\.php\b/i.test(trimmed)) return true
  return false
}

/**
 * 将 ASCII 大写字母编码转换为小写编码。
 *
 * BBCode 标签名只允许 ASCII 字母，因此无需为每次查找构造完整正文的小写副本。
 *
 * @param code UTF-16 编码单元
 * @returns 用于标签比较的小写 ASCII 编码
 */
function toLowerAsciiCode(code: number): number {
  return code >= 65 && code <= 90 ? code + 32 : code
}

/**
 * 以不区分 ASCII 大小写的方式查找标签位置。
 *
 * 查找从 start 开始逐字符比较，避免在表格单元格循环中反复对整篇正文执行
 * `toLowerCase()`，使复杂楼层的解析复杂度保持线性。
 *
 * @param content 完整正文
 * @param search 待查找的 ASCII 标签
 * @param start 起始位置
 * @returns 匹配位置；未找到时返回 -1
 */
function indexOfIgnoreCase(content: string, search: string, start: number): number {
  if (search.length === 0) return Math.min(Math.max(0, start), content.length)
  const normalizedStart: number = Math.max(0, start)
  const lastStart: number = content.length - search.length
  for (let i: number = normalizedStart; i <= lastStart; i++) {
    let matched: boolean = true
    for (let j: number = 0; j < search.length; j++) {
      if (toLowerAsciiCode(content.charCodeAt(i + j)) !== toLowerAsciiCode(search.charCodeAt(j))) {
        matched = false
        break
      }
    }
    if (matched) return i
  }
  return -1
}

/**
 * 判断指定位置是否以不区分 ASCII 大小写的方式匹配目标文本。
 *
 * @param content 完整正文
 * @param search 待匹配的 ASCII 文本
 * @param start 匹配起始位置
 * @returns 指定位置是否完整匹配目标文本
 */
function matchesIgnoreCaseAt(content: string, search: string, start: number): boolean {
  if (start < 0 || start + search.length > content.length) return false
  for (let i: number = 0; i < search.length; i++) {
    if (toLowerAsciiCode(content.charCodeAt(start + i)) !== toLowerAsciiCode(search.charCodeAt(i))) {
      return false
    }
  }
  return true
}

/** 解析器游标状态：当前内容、位置、总长度。 */
class ParseState {
  /** 预处理后的完整正文。 */
  content: string = ''
  /** 当前解析位置。 */
  pos: number = 0
  /** 正文总字符数。 */
  len: number = 0
  /** 当前正在解析的列表嵌套深度。 */
  listDepth: number = 0
}

/** 向节点数组追加已解码文本；相邻文本合并，所有有效换行均保留。 */
function pushTextNode(into: BBNode[], text: string): void {
  if (text.length === 0) return
  const decoded: string = decodeHtmlEntities(text)
  if (decoded.length === 0) return
  const previous: BBNode | undefined = into.length > 0 ? into[into.length - 1] : undefined
  if (previous !== undefined && previous.type === BBNodeType.TEXT) {
    previous.text += decoded
    return
  }
  const n = createBBNode()
  n.type = BBNodeType.TEXT
  n.text = decoded
  into.push(n)
}

/**
 * 在实体解码前规范化服务端真实 HTML，并保留转义后应作为文字显示的尖括号。
 *
 * 所有服务端 HTML 语义替换（blockquote/a/emotion/smile/残余标签）只在代码块之外
 * 执行，代码正文保持原样，避免污染代码内容。
 *
 * @param s NGA 返回的原始 BBCode/HTML 混合正文
 * @returns 仅含 BBCode、文字与换行的解析输入
 */
function preprocessContent(s: string): string {
  const normalized: string = s.replace(/<br\s*\/?>/gi, '\n')
  return normalizeHeadingLinesOutsideCode(cleanHtmlOutsideCode(normalized))
}

/**
 * 清理代码块之外的服务端 HTML 与表情标记，代码正文保持原样。
 *
 * @param content 已完成 <br/> 归一化的正文
 * @returns 清理后的正文
 */
function cleanHtmlOutsideCode(content: string): string {
  const lower: string = content.toLowerCase()
  let result: string = ''
  let position: number = 0
  while (position < content.length) {
    const codeStart: number = lower.indexOf('[code]', position)
    if (codeStart < 0) {
      result += cleanupHtmlSegment(content.substring(position))
      break
    }
    result += cleanupHtmlSegment(content.substring(position, codeStart))
    const codeEnd: number = lower.indexOf('[/code]', codeStart + 6)
    if (codeEnd < 0) {
      result += content.substring(codeStart)
      break
    }
    result += content.substring(codeStart, codeEnd + 7)
    position = codeEnd + 7
  }
  return result
}

/**
 * 对非代码段执行服务端 HTML 语义替换与残余标签删除。
 *
 * 替换顺序与既有行为一致：blockquote → <a> → 表情 <img> → [img]smile → 残余标签。
 *
 * @param segment 不含 [code] 块的正文片段
 * @returns 语义化后的片段
 */
function cleanupHtmlSegment(segment: string): string {
  return segment
    .replace(/<blockquote[^>]*>/gi, '[quote]')
    .replace(/<\/blockquote>/gi, '[/quote]')
    .replace(/<a\s+href="(https?:\/\/[^"]+)"[^>]*>(.*?)<\/a>/gi, '[url=$1]$2[/url]')
    .replace(/<img[^>]+class="nga-emotion"[^>]+alt="([a-z]+):([^"]+)"\s*\/?>/gi, '[s:$1:$2]')
    .replace(/\[img\]https?:\/\/img4\.(?:nga\.cn|nga\.178\.com)\/ngabbs\/post\/smile\/(\w+)\.\w+\[\/img\]/gi,
      (_m: string, fname: string): string => {
        const us: number = fname.indexOf('_')
        if (us >= 0) return `[s:${fname.substring(0, us)}:${fname.substring(us + 1)}]`
        const nm: RegExpExecArray | null = /^([a-z]+?)(\d+)$/i.exec(fname)
        if (nm) return `[s:${nm[1]}:${nm[2]}]`
        return _m
      })
    .replace(/<\/?[a-z][^>]*>/gi, '')
}

export {
  createBBNode,
  resolveMediaUrl,
  isSafeUrl,
  indexOfIgnoreCase,
  matchesIgnoreCaseAt,
  pushTextNode,
  preprocessContent
}
export { ParseState }
