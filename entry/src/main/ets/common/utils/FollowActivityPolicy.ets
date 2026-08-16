import type { FollowedActivity } from '../../model/Follow'
import { UnseenListAccessors, UnseenListPolicy } from './UnseenListPolicy'

/**
 * 关注动态本地策略：合并去重、已读维护与未读计数。
 *
 * 服务端 get_push_list 不返回未读标记，动态的「未读/已读」完全由本地判定：
 * - 本地无记录的动态 id 一律视为未读（首次拉取的历史动态同样未读，
 *   红点/圆点如实反映「尚未点开」的状态）；
 * - 已读规则与消息一致：点开对应帖子即标记已读，或右上角一键全部已读。
 */

/**
 * 关注动态访问器：id 为 id；时间取 timestamp 数值；排序第二键为 id（消除同秒抖动）。
 */
const activityAccessors: UnseenListAccessors<FollowedActivity> =
  new UnseenListAccessors<FollowedActivity>(
    (item: FollowedActivity): string => item.id,
    (item: FollowedActivity): boolean => item.seen,
    (item: FollowedActivity, seen: boolean): void => {
      item.seen = seen
    },
    (item: FollowedActivity): number => item.timestamp,
    (item: FollowedActivity): string => item.id
  )

/**
 * 关注动态策略实例（合并去重 / 追加去重 / 已读维护 / 未读计数）。
 */
const activityPolicy: UnseenListPolicy<FollowedActivity> =
  new UnseenListPolicy<FollowedActivity>(activityAccessors)

/**
 * 合并动态列表，重复动态保留原有本地已读状态。
 *
 * @param existing - 当前缓存动态
 * @param incoming - 本次拉取动态
 * @param maxCount - 最大缓存数量
 * @returns 合并、去重并按时间倒序排列的动态；新增动态一律视为未读
 */
export function mergeActivities(
  existing: FollowedActivity[],
  incoming: FollowedActivity[],
  maxCount: number
): FollowedActivity[] {
  return activityPolicy.merge(existing, incoming, maxCount)
}

/**
 * 按分页顺序追加去重：保持 existing 顺序，仅追加 incoming 中 id 不在
 * existing（含本次已追加）的条目，不做重排。
 *
 * @param existing - 当前内存列表
 * @param incoming - 本次分页拉取的条目
 * @returns 追加去重后的列表（新数组，不改动入参）
 */
export function appendDedupe(
  existing: FollowedActivity[],
  incoming: FollowedActivity[]
): FollowedActivity[] {
  return activityPolicy.appendDedupe(existing, incoming)
}

/**
 * 将指定 id 集合的动态标记为已读（点开帖子即已读）。
 *
 * @param activities - 动态列表
 * @param ids - 需要标记为已读的动态 id 集合
 * @returns 是否发生状态变化
 */
export function markActivitiesSeenByIds(
  activities: FollowedActivity[],
  ids: Set<string>
): boolean {
  return activityPolicy.markSeenByIds(activities, ids)
}

/**
 * 将所有动态标记为已读。
 *
 * @param activities - 动态列表
 * @returns 是否发生状态变化
 */
export function markAllActivitiesSeen(activities: FollowedActivity[]): boolean {
  return activityPolicy.markAllSeen(activities)
}

/**
 * 计算未读动态数量。
 *
 * @param activities - 动态列表
 * @returns 未读动态数量
 */
export function countUnseenActivities(activities: FollowedActivity[]): number {
  return activityPolicy.countUnseen(activities)
}
