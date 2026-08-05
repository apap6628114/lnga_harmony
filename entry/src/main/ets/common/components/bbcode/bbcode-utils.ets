import { BBNode, BBNodeType } from '../../../model/BBCodeNode'
import { ReadingFontRole, ReadingTypography } from '../../typography/ReadingTypography'

/**
 * CSS 命名色与 NGA 官方编辑器色板到十六进制颜色的映射。
 *
 * 覆盖 CSS 2.1 全部基础色（含 aqua/fuchsia 别名、gray/grey 拼写归一化）与
 * NGA 编辑器预设色板（排版帖 tid=5355906），未收录的名字由
 * normalizeTextColor 原样透传给 ArkUI 解析。
 */
const NAMED_TEXT_COLORS: Map<string, string> = new Map<string, string>([
  ['aqua', '#00ffff'],
  ['black', '#000000'],
  ['blue', '#0000ff'],
  ['burlywood', '#deb887'],
  ['chocolate', '#d2691e'],
  ['coral', '#ff7f50'],
  ['crimson', '#dc143c'],
  ['cyan', '#00ffff'],
  ['darkblue', '#00008b'],
  ['darkred', '#8b0000'],
  ['deeppink', '#ff1493'],
  ['firebrick', '#b22222'],
  ['fuchsia', '#ff00ff'],
  ['gray', '#808080'],
  ['green', '#008000'],
  ['grey', '#808080'],
  ['indigo', '#4b0082'],
  ['lime', '#00ff00'],
  ['limegreen', '#32cd32'],
  ['magenta', '#ff00ff'],
  ['maroon', '#800000'],
  ['navy', '#000080'],
  ['olive', '#808000'],
  ['orange', '#ffa500'],
  ['orangered', '#ff4500'],
  ['pink', '#ffc0cb'],
  ['purple', '#800080'],
  ['red', '#ff0000'],
  ['royalblue', '#4169e1'],
  ['sandybrown', '#f4a460'],
  ['seagreen', '#2e8b57'],
  ['sienna', '#a0522d'],
  ['silver', '#c0c0c0'],
  ['skyblue', '#87ceeb'],
  ['teal', '#008080'],
  ['tomato', '#ff6347'],
  ['white', '#ffffff'],
  ['yellow', '#ffff00'],
])

/**
 * 内联渲染单元类型。
 */
export enum InlineRunKind {
  /** 普通文字。 */
  TEXT,
  /** 可点击链接。 */
  LINK,
  /** 行内表情图片。 */
  EMOTION,
}

/**
 * 文字基线语义。
 */
export enum InlineBaseline {
  /** 正常基线。 */
  NORMAL,
  /** 下标。 */
  SUBSCRIPT,
  /** 上标。 */
  SUPERSCRIPT,
}

/**
 * 可继承的最终文字样式。
 */
export class InlineTextStyle {
  /** 是否粗体。 */
  bold: boolean = false
  /** 是否斜体。 */
  italic: boolean = false
  /** 是否带下划线。 */
  underline: boolean = false
  /** 是否带删除线。 */
  strikethrough: boolean = false
  /** BBCode 指定的颜色，空字符串表示继承主题颜色。 */
  color: string = ''
  /** 相对正文的累计字号百分比。 */
  scalePercent: number = 100
  /** 字体族或字体回退列表。 */
  fontFamily: string = 'HarmonyOS Sans'
  /** 上下标基线语义。 */
  baseline: InlineBaseline = InlineBaseline.NORMAL
}

/**
 * ArkUI 可以直接渲染的扁平内联单元。
 */
export class InlineRun {
  /** 稳定的 ForEach 键。 */
  key: string = ''
  /** 渲染单元类型。 */
  kind: InlineRunKind = InlineRunKind.TEXT
  /** 文字内容。 */
  text: string = ''
  /** 链接地址。 */
  href: string = ''
  /** 表情分类。 */
  emotionCat: string = ''
  /** 表情代码。 */
  emotionCode: string = ''
  /** 已解析的最终文字样式。 */
  style: InlineTextStyle = new InlineTextStyle()
}

/**
 * 内联 Run 构建过程的可变状态。
 */
class InlineRunBuildState {
  /** 已生成的 Run。 */
  runs: InlineRun[] = []
  /** 当前文档内 Run 序号。 */
  serial: number = 0
}

/**
 * 判断 BBCode 节点类型是否可出现在行内文字流中。
 *
 * @param type BBCode 节点类型
 * @returns 是否为内联节点
 */
export function isInlineNode(type: BBNodeType): boolean {
  return type === BBNodeType.TEXT || type === BBNodeType.BOLD ||
    type === BBNodeType.ITALIC || type === BBNodeType.UNDERLINE ||
    type === BBNodeType.STRIKETHROUGH || type === BBNodeType.COLOR ||
    type === BBNodeType.SIZE || type === BBNodeType.FONT ||
    type === BBNodeType.URL || type === BBNodeType.PID_LINK ||
    type === BBNodeType.UID_LINK || type === BBNodeType.TID_LINK ||
    type === BBNodeType.MENTION || type === BBNodeType.EMOTION ||
    type === BBNodeType.SUBSCRIPT || type === BBNodeType.SUPERSCRIPT
}

/**
 * 克隆文字样式，避免嵌套节点修改父级状态。
 *
 * @param source 原始样式
 * @returns 独立样式副本
 */
export function cloneInlineTextStyle(source: InlineTextStyle): InlineTextStyle {
  const result = new InlineTextStyle()
  result.bold = source.bold
  result.italic = source.italic
  result.underline = source.underline
  result.strikethrough = source.strikethrough
  result.color = source.color
  result.scalePercent = source.scalePercent
  result.fontFamily = source.fontFamily
  result.baseline = source.baseline
  return result
}

/**
 * 校验并规范化 BBCode/CSS 颜色。
 *
 * @param raw 原始颜色值
 * @returns 合法颜色；非法时返回空字符串
 */
export function normalizeTextColor(raw: string): string {
  const color: string = raw.trim()
  if (/^#[0-9a-fA-F]{3}$/.test(color) || /^#[0-9a-fA-F]{4}$/.test(color) ||
    /^#[0-9a-fA-F]{6}$/.test(color) || /^#[0-9a-fA-F]{8}$/.test(color)) {
    return color
  }
  if (!/^[a-zA-Z]+$/.test(color)) return ''
  const lower: string = color.toLowerCase()
  return NAMED_TEXT_COLORS.get(lower) ?? lower
}

/**
 * 将常见网页字体名称映射到 HarmonyOS 可用的通用字体族。
 *
 * @param raw BBCode/CSS 字体名称
 * @returns 字体族或字体回退列表
 */
export function normalizeFontFamily(raw: string): string {
  const family: string = raw.trim().replace(/["']/g, '')
  const lower: string = family.toLowerCase()
  if (family.length === 0 || family.length > 64) return ''
  if (lower.indexOf('simsun') >= 0 || family.indexOf('宋体') >= 0 || lower === 'serif') return 'serif'
  if (lower.indexOf('consolas') >= 0 || lower.indexOf('courier') >= 0 || lower === 'monospace') return 'monospace'
  if (lower.indexOf('arial') >= 0 || lower.indexOf('yahei') >= 0 || family.indexOf('黑体') >= 0 ||
    family.indexOf('微软雅黑') >= 0 || lower === 'sans-serif') return 'sans-serif'
  return family
}

/**
 * 计算相对字号的安全累计结果。
 *
 * @param parentScale 父级字号百分比
 * @param childScale 当前标签字号百分比
 * @returns 50% 至 300% 范围内的累计字号
 */
function combineScalePercent(parentScale: number, childScale: number): number {
  return Math.min(300, Math.max(50, Math.round(parentScale * childScale / 100)))
}

/**
 * 将当前节点的格式语义叠加到父级样式。
 *
 * @param node 当前格式节点
 * @param inherited 父级样式
 * @returns 当前节点的继承结果
 */
function deriveNodeStyle(node: BBNode, inherited: InlineTextStyle): InlineTextStyle {
  const style: InlineTextStyle = cloneInlineTextStyle(inherited)
  if (node.type === BBNodeType.BOLD) style.bold = true
  if (node.type === BBNodeType.ITALIC) style.italic = true
  if (node.type === BBNodeType.UNDERLINE) style.underline = true
  if (node.type === BBNodeType.STRIKETHROUGH) style.strikethrough = true
  if (node.type === BBNodeType.COLOR) {
    const color: string = normalizeTextColor(node.color)
    if (color.length > 0) style.color = color
  }
  if (node.type === BBNodeType.SIZE && node.size > 0) {
    style.scalePercent = combineScalePercent(style.scalePercent, node.size)
  }
  if (node.type === BBNodeType.FONT) {
    const fontFamily: string = normalizeFontFamily(node.fontFamily)
    if (fontFamily.length > 0) style.fontFamily = fontFamily
  }
  if (node.type === BBNodeType.SUBSCRIPT) style.baseline = InlineBaseline.SUBSCRIPT
  if (node.type === BBNodeType.SUPERSCRIPT) style.baseline = InlineBaseline.SUPERSCRIPT
  return style
}

/**
 * 判断两个样式是否可合并为同一 Span。
 *
 * @param left 左侧样式
 * @param right 右侧样式
 * @returns 样式是否完全一致
 */
function areInlineStylesEqual(left: InlineTextStyle, right: InlineTextStyle): boolean {
  return left.bold === right.bold && left.italic === right.italic && left.underline === right.underline &&
    left.strikethrough === right.strikethrough && left.color === right.color &&
    left.scalePercent === right.scalePercent && left.fontFamily === right.fontFamily &&
    left.baseline === right.baseline
}

/**
 * 追加 Run，并合并相邻且语义完全一致的文字。
 *
 * @param state Run 构建状态
 * @param run 待追加 Run
 */
function appendRun(state: InlineRunBuildState, run: InlineRun): void {
  if (run.kind !== InlineRunKind.EMOTION && run.text.length === 0) return
  const previous: InlineRun | undefined = state.runs.length > 0 ? state.runs[state.runs.length - 1] : undefined
  if (previous !== undefined && previous.kind === run.kind && previous.href === run.href &&
    previous.kind !== InlineRunKind.EMOTION && areInlineStylesEqual(previous.style, run.style)) {
    previous.text += run.text
    return
  }
  run.key = `inline_${state.serial}`
  state.serial++
  state.runs.push(run)
}

/**
 * 将单个语义节点递归展开为最终 Run。
 *
 * @param node 当前节点
 * @param inherited 父级样式
 * @param inheritedHref 父级链接地址
 * @param state Run 构建状态
 */
function flattenInlineNode(node: BBNode, inherited: InlineTextStyle, inheritedHref: string,
  state: InlineRunBuildState): void {
  const continuedStyle: InlineTextStyle = node.inheritedFormatTags.length > 0 ?
    applyInlineFormatTags(node.inheritedFormatTags, inherited) : inherited
  const style: InlineTextStyle = deriveNodeStyle(node, continuedStyle)
  const isLink: boolean = node.type === BBNodeType.URL || node.type === BBNodeType.PID_LINK ||
    node.type === BBNodeType.UID_LINK || node.type === BBNodeType.TID_LINK || node.type === BBNodeType.MENTION
  const href: string = isLink ? node.href : inheritedHref

  if (node.type === BBNodeType.EMOTION) {
    const run = new InlineRun()
    run.kind = InlineRunKind.EMOTION
    run.emotionCat = node.emotionCat
    run.emotionCode = node.emotionCode
    run.text = node.text
    run.style = style
    appendRun(state, run)
    return
  }

  if (node.children.length > 0) {
    for (let i: number = 0; i < node.children.length; i++) {
      flattenInlineNode(node.children[i], style, href, state)
    }
    return
  }

  if (node.text.length > 0) {
    const run = new InlineRun()
    run.kind = href.length > 0 ? InlineRunKind.LINK : InlineRunKind.TEXT
    run.text = node.text
    run.href = href
    run.style = style
    appendRun(state, run)
  }
}

/**
 * 将任意深度的内联节点树扁平化为 ArkUI Span 序列。
 *
 * @param nodes 内联节点树
 * @param inherited 可选的块级继承样式
 * @returns 可直接渲染的 Run 数组
 */
export function flattenInlineNodes(nodes: BBNode[], inherited?: InlineTextStyle): InlineRun[] {
  const state = new InlineRunBuildState()
  const baseStyle: InlineTextStyle = inherited === undefined ? new InlineTextStyle() : cloneInlineTextStyle(inherited)
  for (let i: number = 0; i < nodes.length; i++) {
    flattenInlineNode(nodes[i], baseStyle, '', state)
  }
  // 渲染前压缩连续换行：NGA 楼层正文的空行以 <br/> 序列表达，预处理后成为连续 \n。
  // 解析树按"文本零丢失"保留原文（快照、官方差分、纯文本提取均依赖原始 \n），
  // 仅在渲染层把 \n{2,} 折叠为单个 \n，避免 ArkUI Text 渲染出多个空白行。
  for (let i: number = 0; i < state.runs.length; i++) {
    state.runs[i].text = state.runs[i].text.replace(/\n{2,}/g, '\n')
  }
  return state.runs
}

/**
 * 判断已扁平化的 Run 数组是否没有可见内容和有效换行。
 *
 * @param runs 已完成样式继承计算的内联 Run
 * @returns 是否可安全跳过布局
 */
export function isInlineRunsBlank(runs: InlineRun[]): boolean {
  for (let i: number = 0; i < runs.length; i++) {
    if (runs[i].kind === InlineRunKind.EMOTION) return false
    if (runs[i].text.indexOf('\n') >= 0) return false
    if (runs[i].text.trim().length > 0) return false
  }
  return true
}

/**
 * 把 `[style ...]` 中允许的文字 CSS 叠加到父级样式。
 *
 * @param declaration 原始样式声明
 * @param inherited 父级样式
 * @returns 白名单过滤后的文字样式
 */
export function applyTextStyleDeclaration(declaration: string, inherited: InlineTextStyle): InlineTextStyle {
  const style: InlineTextStyle = cloneInlineTextStyle(inherited)
  const properties: string[] = declaration.split(';')
  for (let i: number = 0; i < properties.length; i++) {
    const separator: number = properties[i].indexOf(':')
    if (separator < 0) continue
    const name: string = properties[i].substring(0, separator).trim().toLowerCase()
    const value: string = properties[i].substring(separator + 1).trim()
    if (name === 'color') {
      const color: string = normalizeTextColor(value)
      if (color.length > 0) style.color = color
    }
    if (name === 'font-weight') style.bold = value === 'bold' || parseInt(value, 10) >= 600
    if (name === 'font-style') style.italic = value.toLowerCase() === 'italic'
    if (name === 'font-family') {
      const fontFamily: string = normalizeFontFamily(value)
      if (fontFamily.length > 0) style.fontFamily = fontFamily
    }
    if (name === 'font-size') {
      const sizeMatch: RegExpExecArray | null = /^(\d+)%$/.exec(value)
      if (sizeMatch) style.scalePercent = combineScalePercent(style.scalePercent, parseInt(sizeMatch[1], 10))
    }
    if (name === 'text-decoration') {
      const lowerValue: string = value.toLowerCase()
      style.underline = lowerValue.indexOf('underline') >= 0
      style.strikethrough = lowerValue.indexOf('line-through') >= 0
    }
  }
  return style
}

/**
 * 将跨越块节点的 BBCode 开始标签叠加到文字样式。
 *
 * @param tags 由解析器记录的内联开始标签
 * @param inherited 父级文字样式
 * @returns 块节点后代应继承的文字样式
 */
export function applyInlineFormatTags(tags: string[], inherited: InlineTextStyle): InlineTextStyle {
  const style: InlineTextStyle = cloneInlineTextStyle(inherited)
  for (let i: number = 0; i < tags.length; i++) {
    const match: RegExpExecArray | null = /^\[(b|item|i|u|del|color|size|font|sub|sup)(?:=([^\]]*))?\]$/i.exec(tags[i])
    if (!match) continue
    const name: string = match[1].toLowerCase()
    const value: string = match[2] ?? ''
    if (name === 'b' || name === 'item') style.bold = true
    if (name === 'i') style.italic = true
    if (name === 'u') style.underline = true
    if (name === 'del') style.strikethrough = true
    if (name === 'color') {
      const color: string = normalizeTextColor(value)
      if (color.length > 0) style.color = color
    }
    if (name === 'font') {
      const fontFamily: string = normalizeFontFamily(value)
      if (fontFamily.length > 0) style.fontFamily = fontFamily
    }
    if (name === 'sub') style.baseline = InlineBaseline.SUBSCRIPT
    if (name === 'sup') style.baseline = InlineBaseline.SUPERSCRIPT
    if (name === 'size') {
      const sizeMatch: RegExpExecArray | null = /^(\d+)%$/.exec(value.trim())
      if (sizeMatch) style.scalePercent = combineScalePercent(style.scalePercent, parseInt(sizeMatch[1], 10))
    }
  }
  return style
}

/**
 * 提取 `[style ...]` 中允许的文字对齐方式。
 *
 * @param declaration 原始样式声明
 * @returns left、center、right 或空字符串
 */
export function extractTextStyleAlign(declaration: string): string {
  const match: RegExpExecArray | null = /(?:^|;)\s*text-align\s*:\s*(left|center|right)\s*(?:;|$)/i.exec(declaration)
  return match ? match[1].toLowerCase() : ''
}

/**
 * 计算 SIZE 标签缩放后的字体像素尺寸。
 *
 * @param size BBCode 累计字号百分比
 * @param inQuote 是否处于引用块内
 * @param baseFontSize 基础正文大小
 * @returns 缩放后的字号
 */
export function calcScaleSize(size: number, inQuote: boolean, baseFontSize: number = 15): number {
  return ReadingTypography.bbcodeFontSize(size, inQuote, baseFontSize)
}

/**
 * 判断一组内联节点是否没有可见内容和有效换行。
 *
 * @param nodes 内联节点数组
 * @returns 是否可安全跳过布局
 */
export function isInlineGroupBlank(nodes: BBNode[]): boolean {
  return isInlineRunsBlank(flattenInlineNodes(nodes))
}

/**
 * 计算下标文字字号。
 *
 * @param baseSize 当前继承字号
 * @returns 下标字号
 */
export function calcSubscriptSize(baseSize: number): number {
  return ReadingTypography.fontSize(ReadingFontRole.SUB_SUP, baseSize)
}

/**
 * 计算下标文字基线偏移。
 *
 * @param baseSize 当前继承字号
 * @returns 下标基线偏移
 */
export function calcSubscriptOffset(baseSize: number): number {
  return ReadingTypography.subscriptOffset(baseSize)
}

/**
 * 计算上标文字字号。
 *
 * @param baseSize 当前继承字号
 * @returns 上标字号
 */
export function calcSuperscriptSize(baseSize: number): number {
  return ReadingTypography.fontSize(ReadingFontRole.SUB_SUP, baseSize)
}

/**
 * 计算上标文字基线偏移。
 *
 * @param baseSize 当前继承字号
 * @returns 上标基线偏移
 */
export function calcSuperscriptOffset(baseSize: number): number {
  return ReadingTypography.superscriptOffset(baseSize)
}
