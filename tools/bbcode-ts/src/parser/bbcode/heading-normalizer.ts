import { isInlineStyleTagName, isValidInlineStyleTag } from './inline-tag-policy'

/** 标题行外层单个格式标签允许的最大长度。 */
const MAX_HEADING_WRAPPER_TAG_LENGTH: number = 512

/**
 * 标题行开头已通过校验的格式标签。
 */
class HeadingOpenTag {
  /** 标签原文。 */
  raw: string = ''
  /** 规范化后的小写标签名。 */
  name: string = ''
  /** 标签结束后的字符位置。 */
  end: number = 0
}

/**
 * 从标题行指定位置读取一个合法的 `[h]` 或内联样式开始标签。
 *
 * @param line 不含换行符的原始行
 * @param start 标签开始位置
 * @returns 合法标签；当前位置不是可用于标题包装的标签时返回 null
 */
function readHeadingOpenTag(line: string, start: number): HeadingOpenTag | null {
  if (start >= line.length || line.charAt(start) !== '[' || line.charAt(start + 1) === '/') return null
  const closeBracket: number = line.indexOf(']', start + 1)
  if (closeBracket < 0 || closeBracket - start + 1 > MAX_HEADING_WRAPPER_TAG_LENGTH) return null
  const raw: string = line.substring(start, closeBracket + 1)
  const body: string = line.substring(start + 1, closeBracket).trim()
  const equalIndex: number = body.indexOf('=')
  const name: string = (equalIndex >= 0 ? body.substring(0, equalIndex) : body).trim().toLowerCase()
  if (!/^[a-z]+$/.test(name)) return null
  const attribute: string = equalIndex >= 0 ? body.substring(equalIndex + 1).trim() : ''
  if (name === 'h') {
    if (equalIndex >= 0) return null
  } else if (!isInlineStyleTagName(name) || !isValidInlineStyleTag(name, attribute)) {
    return null
  }
  const tag: HeadingOpenTag = new HeadingOpenTag()
  tag.raw = raw
  tag.name = name
  tag.end = closeBracket + 1
  return tag
}

/**
 * 把一行支持的标题写法规范化为唯一的 `[h]...[/h]` 结构。
 *
 * 外层格式标签必须属性合法且严格嵌套；不完整或异常输入保持原文。
 *
 * @param line 不含换行符的原始行
 * @returns 规范化标题行；不是标题时返回原文
 */
function normalizeHeadingLine(line: string): string {
  const source: string = line.trim()
  if (source.length === 0) return line
  const openTags: HeadingOpenTag[] = []
  let bodyStart: number = 0
  let headingTagCount: number = 0
  while (bodyStart < source.length) {
    const tag: HeadingOpenTag | null = readHeadingOpenTag(source, bodyStart)
    if (tag === null) break
    openTags.push(tag)
    if (tag.name === 'h') headingTagCount++
    bodyStart = tag.end
  }
  if (headingTagCount > 1) return line

  let bodyEnd: number = source.length
  for (let i: number = 0; i < openTags.length; i++) {
    const closeTag: string = `[/${openTags[i].name}]`
    const closeStart: number = bodyEnd - closeTag.length
    if (closeStart < bodyStart || source.substring(closeStart, bodyEnd).toLowerCase() !== closeTag) return line
    bodyEnd = closeStart
  }

  const body: string = source.substring(bodyStart, bodyEnd).trim()
  const separatorMatch: RegExpExecArray | null = /^={3,}(.+)={3,}$/.exec(body)
  const hasHeadingTag: boolean = headingTagCount === 1
  if (!hasHeadingTag && separatorMatch === null) return line
  const title: string = (separatorMatch === null ? body : separatorMatch[1]).trim()
  if (title.length === 0 || /^=+$/.test(title)) return line

  const parts: string[] = ['[h]']
  for (let i: number = 0; i < openTags.length; i++) {
    if (openTags[i].name !== 'h') parts.push(openTags[i].raw)
  }
  parts.push(title)
  for (let i: number = openTags.length - 1; i >= 0; i--) {
    if (openTags[i].name !== 'h') parts.push(`[/${openTags[i].name}]`)
  }
  parts.push('[/h]')
  return parts.join('')
}

/**
 * 根据当前行中的 `[code]` 与 `[/code]` 更新跨行代码块状态。
 *
 * @param line 不含换行符的原始行
 * @param inCode 行开始位置是否处于代码块
 * @returns 下一行开始位置是否处于代码块
 */
/** [code] 开始/闭合标签正则（模块级常量，避免每行重复构造）。 */
const P_CODE_TAG: RegExp = /\[(\/)?code\]/gi

function updateCodeBlockState(line: string, inCode: boolean): boolean {
  let result: boolean = inCode
  P_CODE_TAG.lastIndex = 0
  let match: RegExpExecArray | null = P_CODE_TAG.exec(line)
  while (match !== null) {
    result = match[1] === undefined
    match = P_CODE_TAG.exec(line)
  }
  return result
}

/**
 * 以单次逐行扫描规范化代码块外的标题语法，并完整保留原换行格式。
 *
 * @param content 已完成 HTML 清理的 BBCode 正文
 * @returns 仅将有效标题行统一为 `[h]...[/h]` 的正文
 */
export function normalizeHeadingLinesOutsideCode(content: string): string {
  const parts: string[] = []
  let position: number = 0
  let inCode: boolean = false
  while (position < content.length) {
    const newlineIndex: number = content.indexOf('\n', position)
    const lineEnd: number = newlineIndex >= 0 ? newlineIndex : content.length
    const rawLine: string = content.substring(position, lineEnd)
    const hasCarriageReturn: boolean = rawLine.endsWith('\r')
    const line: string = hasCarriageReturn ? rawLine.substring(0, rawLine.length - 1) : rawLine
    parts.push(inCode ? line : normalizeHeadingLine(line))
    if (hasCarriageReturn) parts.push('\r')
    if (newlineIndex >= 0) parts.push('\n')
    inCode = updateCodeBlockState(line, inCode)
    position = newlineIndex >= 0 ? newlineIndex + 1 : content.length
  }
  return parts.join('')
}
