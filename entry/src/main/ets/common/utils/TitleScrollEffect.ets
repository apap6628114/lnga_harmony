import {
  NAV_BAR_H,
  TITLE_BLUR_FADE_DISTANCE,
  TITLE_BLUR_RADIUS,
  TITLE_SCROLL_EFFECT_DISTANCE
} from '../constants/Constants'

/**
 * 固定标题栏与可滚动正文之间的共享视觉联动计算。
 */
export class TitleScrollEffect {
  /**
   * 将列表绝对滚动偏移换算为标题栏效果进度。
   *
   * `List.contentStartOffset` 会使列表起点的绝对滚动偏移为其相反数；
   * 因此正文实际侵入标题区的距离需要加回同一份起始避让距离。
   *
   * @param offsetY - 列表纵向绝对滚动偏移
   * @param statusBarHeight - 状态栏高度
   * @param contentStartOffset - 自定义起始避让距离（默认 = statusBarHeight + NAV_BAR_H）
   * @returns 取值范围为 0 到 1 的联动进度
   */
  static getProgress(offsetY: number, statusBarHeight: number, contentStartOffset?: number): number {
    const start: number = contentStartOffset ?? TitleScrollEffect.getContentStartOffset(statusBarHeight)
    const overlapDistance: number = Math.max(offsetY + start, 0)
    return Math.min(overlapDistance / TITLE_SCROLL_EFFECT_DISTANCE, 1)
  }

  /**
   * 判断新的联动进度是否值得写入响应式状态。
   *
   * @param currentProgress - 当前进度
   * @param nextProgress - 新进度
   * @returns 是否应更新响应式状态
   */
  static shouldUpdateProgress(currentProgress: number, nextProgress: number): boolean {
    return nextProgress !== currentProgress &&
      (nextProgress === 0 || nextProgress === 1 || Math.abs(nextProgress - currentProgress) >= 0.001)
  }

  /**
   * 获取正文首次展示时避让固定标题栏的距离。
   *
   * @param statusBarHeight - 状态栏高度
   * @returns 标题区总高度
   */
  static getContentStartOffset(statusBarHeight: number): number {
    return statusBarHeight + NAV_BAR_H
  }

  /**
   * 获取正文渐变模糊的空间停靠点。
   *
   * 标题区内保持最大模糊，标题底部以下连续衰减到零。
   *
   * @param viewportHeight - 滚动容器当前视口高度
   * @param statusBarHeight - 状态栏高度
   * @param titleHeight - 自定义标题区高度（默认 = statusBarHeight + NAV_BAR_H）
   * @returns 渐变模糊强度与位置组成的停靠点
   */
  static getBlurStops(viewportHeight: number, statusBarHeight: number, titleHeight?: number): FractionStop[] {
    const th: number = titleHeight ?? TitleScrollEffect.getContentStartOffset(statusBarHeight)
    const minimumViewportHeight: number = th + TITLE_BLUR_FADE_DISTANCE
    const safeViewportHeight: number = Math.max(viewportHeight, minimumViewportHeight)
    const titleEnd: number = Math.min(th / safeViewportHeight, 0.8)
    const fadeEnd: number = Math.min(
      (th + TITLE_BLUR_FADE_DISTANCE) / safeViewportHeight,
      0.9
    )
    return [[1, 0], [1, titleEnd], [0, fadeEnd], [0, 1]]
  }

  /**
   * 获取当前滚动进度对应的渐变模糊半径。
   *
   * @param progress - 标题栏效果进度
   * @returns 当前模糊半径
   */
  static getBlurRadius(progress: number): number {
    const safeProgress: number = Math.max(0, Math.min(progress, 1))
    return TITLE_BLUR_RADIUS * safeProgress
  }

  /**
   * 获取标题背景偏色的当前透明度。
   *
   * @param progress - 标题栏原始滚动进度
   * @returns 经过边界约束的背景透明度
   */
  static getBackdropOpacity(progress: number): number {
    return Math.max(0, Math.min(progress, 1))
  }
}
