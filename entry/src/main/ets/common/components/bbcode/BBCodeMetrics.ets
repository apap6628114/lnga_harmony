import {
  InlineBaseline,
  InlineRun,
  calcScaleSize,
  calcSubscriptOffset,
  calcSubscriptSize,
  calcSuperscriptOffset,
  calcSuperscriptSize
} from './bbcode-utils'
import { RenderContext } from './BBCodeRenderContext'
import {
  ReadingFontRole,
  ReadingLineHeightRole,
  ReadingTypography
} from '../../typography/ReadingTypography'

/**
 * BBCode 内容渲染度量计算。
 *
 * 收纳 BBCodeContentView 中不依赖组件状态的字号/行高/表情尺寸计算，
 * 全部为静态纯函数，`contentFontSize` 由调用方传入，可安全独立测试。
 */

/**
 * 返回当前正文上下文的语义字号。
 *
 * @param ctx BBCode 渲染上下文
 * @param contentFontSize 用户设置的正文基础字号
 * @returns 正文或引用正文的实际字号
 */
export function inlineFontSize(ctx: RenderContext, contentFontSize: number): number {
  return calcScaleSize(ctx.inlineStyle.scalePercent, ctx.inQuote, contentFontSize)
}

/**
 * 返回当前正文上下文的语义行高。
 *
 * @param ctx BBCode 渲染上下文
 * @param contentFontSize 用户设置的正文基础字号
 * @returns 正文或引用正文的实际行高
 */
export function inlineLineHeight(ctx: RenderContext, contentFontSize: number): number {
  const role: ReadingLineHeightRole =
    ctx.inQuote ? ReadingLineHeightRole.QUOTE : ReadingLineHeightRole.CONTENT
  return ReadingTypography.lineHeight(role, inlineFontSize(ctx, contentFontSize))
}

/**
 * 返回当前正文上下文中辅助文本的语义字号。
 *
 * @param ctx BBCode 渲染上下文
 * @param contentFontSize 用户设置的正文基础字号
 * @returns 辅助文本的实际字号
 */
export function fallbackFontSize(ctx: RenderContext, contentFontSize: number): number {
  return ReadingTypography.fontSize(ReadingFontRole.FALLBACK, inlineFontSize(ctx, contentFontSize))
}

/**
 * 返回当前正文上下文中代码块的语义字号。
 *
 * @param ctx BBCode 渲染上下文
 * @param contentFontSize 用户设置的正文基础字号
 * @returns 代码块的实际字号
 */
export function codeFontSize(ctx: RenderContext, contentFontSize: number): number {
  return ReadingTypography.fontSize(ReadingFontRole.CODE, inlineFontSize(ctx, contentFontSize))
}

/**
 * 返回当前正文上下文中代码块的语义行高。
 *
 * @param ctx BBCode 渲染上下文
 * @param contentFontSize 用户设置的正文基础字号
 * @returns 代码块的实际行高
 */
export function codeLineHeight(ctx: RenderContext, contentFontSize: number): number {
  return ReadingTypography.lineHeight(ReadingLineHeightRole.CODE, codeFontSize(ctx, contentFontSize))
}

/**
 * 返回 Run 在应用上下标前的继承字号。
 *
 * @param run 内联 Run
 * @param ctx 渲染上下文
 * @param contentFontSize 用户设置的正文基础字号
 * @returns 基础字号
 */
export function inlineRunBaseFontSize(run: InlineRun, ctx: RenderContext, contentFontSize: number): number {
  return calcScaleSize(run.style.scalePercent, ctx.inQuote, contentFontSize)
}

/**
 * 返回 Run 的最终字号。
 *
 * @param run 内联 Run
 * @param ctx 渲染上下文
 * @param contentFontSize 用户设置的正文基础字号
 * @returns 最终字号
 */
export function inlineRunFontSize(run: InlineRun, ctx: RenderContext, contentFontSize: number): number {
  const baseSize: number = inlineRunBaseFontSize(run, ctx, contentFontSize)
  if (run.style.baseline === InlineBaseline.SUBSCRIPT) return calcSubscriptSize(baseSize)
  if (run.style.baseline === InlineBaseline.SUPERSCRIPT) return calcSuperscriptSize(baseSize)
  return baseSize
}

/**
 * 返回 Run 的基线偏移。
 *
 * @param run 内联 Run
 * @param ctx 渲染上下文
 * @param contentFontSize 用户设置的正文基础字号
 * @returns ArkUI 基线偏移
 */
export function inlineRunBaselineOffset(run: InlineRun, ctx: RenderContext, contentFontSize: number): number {
  const baseSize: number = inlineRunBaseFontSize(run, ctx, contentFontSize)
  if (run.style.baseline === InlineBaseline.SUBSCRIPT) return calcSubscriptOffset(baseSize)
  if (run.style.baseline === InlineBaseline.SUPERSCRIPT) return calcSuperscriptOffset(baseSize)
  return 0
}

/**
 * 根据周围字号计算紧凑的行内表情尺寸。
 *
 * @param run 表情 Run
 * @param ctx 渲染上下文
 * @param contentFontSize 用户设置的正文基础字号
 * @returns 表情边长
 */
export function inlineEmotionSize(run: InlineRun, ctx: RenderContext, contentFontSize: number): number {
  const factor: number = ctx.inQuote ? 1.8 : 2.4
  return Math.min(50, Math.max(24, Math.round(inlineRunBaseFontSize(run, ctx, contentFontSize) * factor)))
}

/**
 * 根据当前行内组的最大字号计算安全行高，避免放大文字发生裁切或重叠。
 *
 * @param runs 当前行内节点组的扁平化结果
 * @param ctx 渲染上下文
 * @param contentFontSize 用户设置的正文基础字号
 * @returns 行内组统一行高
 */
export function inlineGroupLineHeight(runs: InlineRun[], ctx: RenderContext, contentFontSize: number): number {
  let largestFontSize: number = inlineFontSize(ctx, contentFontSize)
  for (let i: number = 0; i < runs.length; i++) {
    largestFontSize = Math.max(largestFontSize, inlineRunFontSize(runs[i], ctx, contentFontSize))
  }
  const role: ReadingLineHeightRole = ctx.inQuote ? ReadingLineHeightRole.QUOTE : ReadingLineHeightRole.CONTENT
  return ReadingTypography.lineHeight(role, largestFontSize)
}
