import type { NgaNotification } from '../../model/Notification'

/**
 * 判断通知类型是否属于私信。
 *
 * @param type - NGA 通知类型
 * @returns 是否为私信通知
 */
export function isMessageNotificationType(type: number): boolean {
  return type === 10 || type === 11 || type === 12
}

/**
 * 合并通知列表，重复通知保留原有本地查看状态。
 *
 * @param existing - 当前缓存通知
 * @param incoming - 本次拉取通知
 * @param maxCount - 最大缓存数量
 * @returns 合并、去重并按时间倒序排列的通知
 */
export function mergeNotifications(
  existing: NgaNotification[],
  incoming: NgaNotification[],
  maxCount: number
): NgaNotification[] {
  const mergedById: Map<string, NgaNotification> = new Map<string, NgaNotification>()
  for (let index: number = 0; index < existing.length; index++) {
    const notification: NgaNotification = existing[index]
    mergedById.set(notification.notificationId, notification)
  }

  for (let index: number = 0; index < incoming.length; index++) {
    const notification: NgaNotification = incoming[index]
    const previous: NgaNotification | undefined = mergedById.get(notification.notificationId)
    notification.seen = previous ? previous.seen : false
    mergedById.set(notification.notificationId, notification)
  }

  const merged: NgaNotification[] = Array.from(mergedById.values())
  merged.sort((left: NgaNotification, right: NgaNotification): number => {
    const leftTime: number = Number(left.timeStamp)
    const rightTime: number = Number(right.timeStamp)
    const safeLeftTime: number = Number.isFinite(leftTime) ? leftTime : 0
    const safeRightTime: number = Number.isFinite(rightTime) ? rightTime : 0
    return safeRightTime - safeLeftTime
  })
  return merged.length > maxCount ? merged.slice(0, maxCount) : merged
}

/**
 * 将所有通知标记为已查看。
 *
 * @param notifications - 通知列表
 * @returns 是否发生状态变化
 */
export function markAllNotificationsSeen(notifications: NgaNotification[]): boolean {
  let changed: boolean = false
  for (let index: number = 0; index < notifications.length; index++) {
    if (!notifications[index].seen) {
      notifications[index].seen = true
      changed = true
    }
  }
  return changed
}

/**
 * 将私信类通知标记为已查看。
 *
 * @param notifications - 通知列表
 * @returns 是否发生状态变化
 */
export function markMessageNotificationsSeen(notifications: NgaNotification[]): boolean {
  let changed: boolean = false
  for (let index: number = 0; index < notifications.length; index++) {
    const notification: NgaNotification = notifications[index]
    if (!notification.seen && isMessageNotificationType(notification.type)) {
      notification.seen = true
      changed = true
    }
  }
  return changed
}

/**
 * 计算全部未查看通知数量。
 *
 * @param notifications - 通知列表
 * @returns 未查看通知数量
 */
export function countUnseenNotifications(notifications: NgaNotification[]): number {
  let count: number = 0
  for (let index: number = 0; index < notifications.length; index++) {
    if (!notifications[index].seen) {
      count++
    }
  }
  return count
}

/**
 * 计算未查看私信通知数量。
 *
 * @param notifications - 通知列表
 * @returns 未查看私信通知数量
 */
export function countUnseenMessageNotifications(notifications: NgaNotification[]): number {
  let count: number = 0
  for (let index: number = 0; index < notifications.length; index++) {
    const notification: NgaNotification = notifications[index]
    if (!notification.seen && isMessageNotificationType(notification.type)) {
      count++
    }
  }
  return count
}
