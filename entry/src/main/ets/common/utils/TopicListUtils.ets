/**
 * 主题列表面板纯逻辑工具。
 *
 * 收纳 TopicListPanel 中不依赖组件响应式状态的决策函数：
 * 热门模式并发页数/时间窗换算、排序模式缓存键、版块可管理性判定。
 * 全部为纯函数，可安全独立测试。
 */

/** 热门模式的时间窗键：7 天。 */
export const HOT_RANGE_WEEK: string = 'week'
/** 热门模式的时间窗键：30 天。 */
export const HOT_RANGE_MONTH: string = 'month'

/**
 * 热门模式的并发拉取页数（按时间窗调整，模仿 MNGA 的大窗口下限保护）。
 *
 * @param hotRange - 热门模式时间窗键（day/week/month）
 * @returns 并发页数
 */
export function getHotFetchPages(hotRange: string): number {
  if (hotRange === HOT_RANGE_WEEK) {
    return 8
  }
  if (hotRange === HOT_RANGE_MONTH) {
    return 10
  }
  return 5
}

/**
 * 热门模式的过滤时间窗（秒），以服务端 curTime 为基准。
 *
 * @param hotRange - 热门模式时间窗键（day/week/month）
 * @returns 时间窗秒数
 */
export function getHotWindowSeconds(hotRange: string): number {
  if (hotRange === HOT_RANGE_WEEK) {
    return 7 * 24 * 60 * 60
  }
  if (hotRange === HOT_RANGE_MONTH) {
    return 30 * 24 * 60 * 60
  }
  return 24 * 60 * 60
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
