import { BBNode, BBNodeType } from '../../../model/BBCodeNode'
import { ReadingFontRole, ReadingTypography } from '../../typography/ReadingTypography'

/**
 * 判断 BBCode 节点类型是否为内联（inline）节点。
 *
 * 内联节点在渲染时会被组合进同一个 Text 容器中，与块级（block）节点相对。
 *
 * @param type - BBCode 节点类型
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
 * 计算 SIZE 标签缩放后的字体像素尺寸（受引用上下文影响）。
 *
 * @param size - BBCode size 百分比（如 150 表示 150%）
 * @param inQuote - 是否处于引用块内（引用内基础字号比正文少 1）
 * @param baseFontSize - 基础字号（正文默认 15，引用内自动减 1）
 * @returns 缩放后的字号，最小 8
 */
export function calcScaleSize(size: number, inQuote: boolean, baseFontSize: number = 15): number {
  return ReadingTypography.bbcodeFontSize(size, inQuote, baseFontSize)
}

/**
 * 判断一组内联节点是否整体为空白（仅含空白文本节点）。
 *
 * 用于过滤掉仅由空格/换行组成的内联分组，避免渲染空 Text。
 *
 * @param nodes - 内联节点数组
 * @returns 是否整体为空白
 */
export function isInlineGroupBlank(nodes: BBNode[]): boolean {
  for (let i = 0; i < nodes.length; i++) {
    if (nodes[i].type !== BBNodeType.TEXT) return false
    if (nodes[i].text.replace(/\s/g, '').length > 0) return false
  }
  return true
}

/**
 * 计算下标（subscript）文本的字号。
 *
 * @param baseSize - 基础字号
 * @returns 下标字号
 */
export function calcSubscriptSize(baseSize: number): number {
  return ReadingTypography.fontSize(ReadingFontRole.SUB_SUP, baseSize)
}

/**
 * 计算下标文本的 baselineOffset（向上为负）。
 *
 * @param baseSize - 基础字号
 * @returns baselineOffset 像素值（负数表示向下）
 */
export function calcSubscriptOffset(baseSize: number): number {
  return ReadingTypography.subscriptOffset(baseSize)
}

/**
 * 计算上标（superscript）文本的字号。
 *
 * @param baseSize - 基础字号
 * @returns 上标字号
 */
export function calcSuperscriptSize(baseSize: number): number {
  return ReadingTypography.fontSize(ReadingFontRole.SUB_SUP, baseSize)
}

/**
 * 计算上标文本的 baselineOffset（向上为正）。
 *
 * @param baseSize - 基础字号
 * @returns baselineOffset 像素值（正数表示向上）
 */
export function calcSuperscriptOffset(baseSize: number): number {
  return ReadingTypography.superscriptOffset(baseSize)
}
