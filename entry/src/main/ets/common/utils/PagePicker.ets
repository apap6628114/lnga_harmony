/**
 * 页码选择器纯逻辑：条目构造与输入校验。
 *
 * 不依赖组件状态，输入输出均为基本类型，可安全独立测试。
 */

/** 页码选择器省略号占位哨兵（0 不是合法页码）。 */
export const PAGE_PICKER_ELLIPSIS: number = 0

/** 页码选择器直接展示全部页码的总页数上限；超过后改用省略号分页。 */
export const PAGE_PICKER_MAX_DIRECT: number = 7

/** 省略号分页时当前页两侧各展示的页码数（首尾页除外）。 */
export const PAGE_PICKER_WINDOW_RADIUS: number = 2

/**
 * 构造页码选择器的数据源。
 *
 * 总页数不超过 {@link PAGE_PICKER_MAX_DIRECT} 时返回全部页码；
 * 否则返回有界的省略号分页条目：首尾页 + 当前页两侧
 * {@link PAGE_PICKER_WINDOW_RADIUS} 页，缺口用 {@link PAGE_PICKER_ELLIPSIS}（0）占位，
 * 保证渲染的页码按钮数量恒定有界，避免上千页时一次性创建大量组件造成卡顿。
 *
 * @param totalPages - 总页数
 * @param currentPage - 当前页
 * @returns 页码与省略号哨兵组成的条目数组
 */
export function buildPageArray(totalPages: number, currentPage: number): number[] {
  const total: number = totalPages
  const cur: number = currentPage
  if (total <= PAGE_PICKER_MAX_DIRECT) {
    const arr: number[] = []
    for (let i: number = 1; i <= total; i++) {
      arr.push(i)
    }
    return arr
  }
  const arr: number[] = []
  arr.push(1)
  const start: number = Math.max(2, cur - PAGE_PICKER_WINDOW_RADIUS)
  const end: number = Math.min(total - 1, cur + PAGE_PICKER_WINDOW_RADIUS)
  if (start > 2) {
    arr.push(PAGE_PICKER_ELLIPSIS)
  }
  for (let i: number = start; i <= end; i++) {
    arr.push(i)
  }
  if (end < total - 1) {
    arr.push(PAGE_PICKER_ELLIPSIS)
  }
  arr.push(total)
  return arr
}

/**
 * 解析页码输入框文本并校验范围。
 *
 * @param raw - 输入框原始文本
 * @param totalPages - 总页数
 * @returns 合法页码（1..totalPages 内的整数）；非法输入返回 -1
 */
export function parsePageInput(raw: string, totalPages: number): number {
  const trimmed: string = raw.trim()
  if (trimmed.length === 0) {
    return -1
  }
  const parsed: number = Number(trimmed)
  if (isNaN(parsed) || parsed < 1 || parsed > totalPages) {
    return -1
  }
  return Math.floor(parsed)
}
