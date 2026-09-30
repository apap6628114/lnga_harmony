/**
 * 主题列表「已读 / 有新回复」判定策略 — 纯函数集合。
 *
 * 语义口径（完整设计见 `docs/TOPIC_READ_STATE_DESIGN.md`）：
 *  - **看过** = 该 tid 存在于浏览历史（`HistoryStore` 的已读台账），即用户**打开过**这个帖子；
 *  - **有更新** = 列表条目当前的回复数 > 用户读到该帖时的回复数（基线）；
 *  - 首次打开帖子时写入基线，`HistoryStore` 记录浏览历史时**已经**保存了当时的回复数
 *    （`BrowseHistoryEntry.replies`），这里直接复用它，不再新增持久化字段。
 *
 * 判定**只认回复数增加**，与时钟无关：设备时间与服务端时间不一致、时区差异都不影响结论
 * （与 `ThreadTrackPolicy` 的「检查只认总回复数增加」同一口径）。删除楼层导致回复数减少时
 * 不报更新，基线在下次打开该帖时自然收敛。
 *
 * 与 Store / UI 解耦：不依赖 AppStore、网络与 ArkUI，可直接被 Hypium Local Test 覆盖。
 */

/**
 * 基线哨兵：**从未读过**该帖（不在已读台账中）。
 *
 * 列表据此判定「没看过」——标题保持正常权重、不显示更新标记。
 */
export const READ_BASELINE_UNREAD: number = -1

/**
 * 基线哨兵：**读过，但基线未知**。
 *
 * 帖子详情响应未携带主题信息（`ThreadResult.threadInfo` 为空）时无法知道读到时有多少回复，
 * 此时按「读过、不判定更新」处理：宁可漏报「有新回复」，也不能把刚看过的帖子误标成有更新
 * （误报会直接误导用户重复点开同一帖）。
 */
export const READ_BASELINE_UNKNOWN: number = -2

/** 主题在列表中的已读状态。 */
export enum TopicReadState {
  /** 从未打开过。 */
  UNREAD = 0,
  /** 打开过，之后没有新回复。 */
  READ = 1,
  /** 打开过，之后又有新回复。 */
  UPDATED = 2
}

/**
 * 判定主题的已读状态。
 *
 * @param readReplies - 读到该帖时的服务端回复数（或两个基线哨兵之一）
 * @param currentReplies - 列表条目当前的服务端回复数
 * @returns 已读状态
 */
export function resolveTopicReadState(readReplies: number, currentReplies: number): TopicReadState {
  if (readReplies === READ_BASELINE_UNREAD) {
    return TopicReadState.UNREAD
  }
  const current: number = currentReplies > 0 ? currentReplies : 0
  if (readReplies >= 0 && current > readReplies) {
    return TopicReadState.UPDATED
  }
  return TopicReadState.READ
}

/**
 * 该状态是否属于「看过」（含已看且有更新）。
 *
 * 用于列表的内容降权：看过的帖子标题与摘要压暗，使「没看过」的帖子在扫视时自然靠前。
 *
 * @param state - 已读状态
 * @returns 是否看过
 */
export function isTopicRead(state: TopicReadState): boolean {
  return state !== TopicReadState.UNREAD
}

/**
 * 看过后新增的回复数（列表条目底栏展示的「+x」）。
 *
 * 与 {@link resolveTopicReadState} 同源：同一个事实的两种视图——状态回答"有没有新东西"，
 * 本函数回答"多了几条"。口径完全一致，只有**读过且回复数确实增加**才返回正数；
 * 从未读过、基线未知、删楼（回复数减少）一律返回 0（不显示）。
 *
 * 返回的是**真实差值**，不做上限截断：列表里的回复数本身就是原样展示的，
 * 增量再截断会出现"回复数涨了 300，增量只显示 +99"的自相矛盾。
 *
 * @param readReplies - 读到该帖时的服务端回复数（或两个基线哨兵之一）
 * @param currentReplies - 列表条目当前的服务端回复数
 * @returns 新增回复数（无更新时为 0）
 */
export function topicUpdateDelta(readReplies: number, currentReplies: number): number {
  if (readReplies < 0) {
    return 0
  }
  const current: number = currentReplies > 0 ? currentReplies : 0
  return current > readReplies ? current - readReplies : 0
}
