/**
 * 主题列表面板纯逻辑工具。
 *
 * 收纳 TopicListPanel 中不依赖组件响应式状态的决策函数：
 * 热门模式时间窗天数映射、排序模式缓存键、版块可管理性判定。
 * 全部为纯函数，可安全独立测试。
 */

/**
 * 热门模式的时间窗档位键：24 小时。
 */
export const HOT_RANGE_DAY: string = 'day'
/** 热门模式的时间窗档位键：7 天。 */
export const HOT_RANGE_WEEK: string = 'week'
/** 热门模式的时间窗档位键：30 天。 */
export const HOT_RANGE_MONTH: string = 'month'

/**
 * 把热门时间窗档位键映射为官方 subject/hot 的 days 参数（服务端时间窗天数）。
 *
 * 与官方 App 的 TopArticleListScope 对齐：24小时→1、本周→7、本月→30。
 *
 * @param hotRange - 热门模式时间窗键（day/week/month）
 * @returns days 参数值（'1' | '7' | '30'）
 */
export function getHotDays(hotRange: string): string {
  if (hotRange === HOT_RANGE_WEEK) {
    return '7'
  }
  if (hotRange === HOT_RANGE_MONTH) {
    return '30'
  }
  return '1'
}

/**
 * 当前排序模式的状态缓存键（热门模式按时间窗细分，模仿 MNGA 的独立数据源隔离）。
 *
 * @param sortMode - 排序模式键
 * @param hotRange - 热门模式时间窗键
 * @returns 模式键
 */
export function currentModeKey(sortMode: string, hotRange: string): string {
  if (sortMode === 'hot') {
    return 'hot:' + hotRange
  }
  return sortMode
}

/**
 * 判断当前页面是否对应一个可管理的普通版块。
 *
 * @param boardFid - 版块 ID
 * @param isFavorites - 是否为收藏聚合列表
 * @param favor - 收藏夹 ID（非空表示收藏夹列表）
 * @param authorid - 作者 ID 过滤
 * @param searchKey - 搜索关键词
 * @param author - 作者名过滤
 * @param searchpost - 是否回帖搜索
 * @returns 是否允许管理当前版块
 */
export function canManageCurrentBoard(boardFid: number, isFavorites: boolean, favor: string,
  authorid: string, searchKey: string, author: string, searchpost: string): boolean {
  return boardFid !== 0 && !isFavorites && !favor
    && !authorid && !searchKey && !author && !searchpost
}
