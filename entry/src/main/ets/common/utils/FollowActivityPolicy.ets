import type { FollowedActivity } from '../../model/Follow'

/**
 * 关注动态本地策略：合并去重、已读维护与未读计数。
 *
 * 服务端 get_push_list 不返回未读标记，动态的「未读/已读」完全由本地判定：
 * - 本地无记录的动态 id 一律视为未读（首次拉取的历史动态同样未读，
 *   红点/圆点如实反映「尚未点开」的状态）；
 * - 已读规则与消息一致：点开对应帖子即标记已读，或右上角一键全部已读。
 */

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
  const mergedById: Map<string, FollowedActivity> = new Map<string, FollowedActivity>()
  for (let index: number = 0; index < existing.length; index++) {
    const activity: FollowedActivity = existing[index]
    mergedById.set(activity.id, activity)
  }

  for (let index: number = 0; index < incoming.length; index++) {
    const activity: FollowedActivity = incoming[index]
    const previous: FollowedActivity | undefined = mergedById.get(activity.id)
    if (previous !== undefined) {
      // 已有记录：保留本地已读状态，并回填可能更新的展示字段
      activity.seen = previous.seen
    } else {
      // 新增动态：尚未点开，一律视为未读
      activity.seen = false
    }
    mergedById.set(activity.id, activity)
  }

  const merged: FollowedActivity[] = Array.from(mergedById.values())
  merged.sort((left: FollowedActivity, right: FollowedActivity): number => {
    const byTimestamp: number = right.timestamp - left.timestamp
    if (byTimestamp !== 0) {
      return byTimestamp
    }
    // 同秒条目按 id 字符串比较（固定方向），消除排序抖动导致的偶发整体重建
    if (left.id > right.id) {
      return -1
    }
    if (left.id < right.id) {
      return 1
    }
    return 0
  })
  return merged.length > maxCount ? merged.slice(0, maxCount) : merged
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
  const knownIds: Set<string> = new Set<string>()
  for (let index: number = 0; index < existing.length; index++) {
    knownIds.add(existing[index].id)
  }
  const result: FollowedActivity[] = existing.slice()
  for (let index: number = 0; index < incoming.length; index++) {
    const activity: FollowedActivity = incoming[index]
    if (!knownIds.has(activity.id)) {
      knownIds.add(activity.id)
      result.push(activity)
    }
  }
  return result
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
  let changed: boolean = false
  for (let index: number = 0; index < activities.length; index++) {
    const activity: FollowedActivity = activities[index]
    if (!activity.seen && ids.has(activity.id)) {
      activity.seen = true
      changed = true
    }
  }
  return changed
}

/**
 * 将所有动态标记为已读。
 *
 * @param activities - 动态列表
 * @returns 是否发生状态变化
 */
export function markAllActivitiesSeen(activities: FollowedActivity[]): boolean {
  let changed: boolean = false
  for (let index: number = 0; index < activities.length; index++) {
    if (!activities[index].seen) {
      activities[index].seen = true
      changed = true
    }
  }
  return changed
}

/**
 * 计算未读动态数量。
 *
 * @param activities - 动态列表
 * @returns 未读动态数量
 */
export function countUnseenActivities(activities: FollowedActivity[]): number {
  let count: number = 0
  for (let index: number = 0; index < activities.length; index++) {
    if (!activities[index].seen) {
      count++
    }
  }
  return count
}
