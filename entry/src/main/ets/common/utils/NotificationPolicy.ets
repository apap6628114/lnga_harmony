import type { MessageNotification, NgaNotification } from '../../model/Notification'
import { UnseenListAccessors, UnseenListPolicy } from './UnseenListPolicy'

/**
 * 判断通知类型是否属于私信。
 *
 * @param type - NGA 通知类型
 * @returns 是否为私信通知
 */
export function isMessageNotificationType(type: number): boolean {
  return type === 10 || type === 11
}

/**
 * 通知列表访问器：id 为 notificationId；时间取 timeStamp 数值（NaN 兜底为 0）；
 * 无排序第二键（返回固定空串，退化为纯时间排序）。
 */
const notificationAccessors: UnseenListAccessors<NgaNotification> =
  new UnseenListAccessors<NgaNotification>(
    (item: NgaNotification): string => item.notificationId,
    (item: NgaNotification): boolean => item.seen,
    (item: NgaNotification, seen: boolean): void => {
      item.seen = seen
    },
    (item: NgaNotification): number => {
      const raw: number = Number(item.timeStamp)
      return Number.isFinite(raw) ? raw : 0
    },
    (): string => ''
  )

/**
 * 通知列表策略实例（合并去重 / 已读维护 / 未读计数）。
 */
const notificationPolicy: UnseenListPolicy<NgaNotification> =
  new UnseenListPolicy<NgaNotification>(notificationAccessors)

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
  return notificationPolicy.merge(existing, incoming, maxCount)
}

/**
 * 将指定通知标记为已查看。
 *
 * @param notifications - 通知列表
 * @param notificationId - 本地稳定通知 ID
 * @returns 是否发生状态变化
 */
export function markNotificationSeen(
  notifications: NgaNotification[],
  notificationId: string
): boolean {
  return notificationPolicy.markSeenById(notifications, notificationId)
}

/**
 * 将所有通知（含私信）标记为已查看。
 *
 * @deprecated 生产侧已不使用：消息 Tab「全部已读」请用
 * markNonMessageNotificationsSeen（不波及私信通知）；本函数仅保留
 * 供策略层单测验证「全部含私信」语义。
 *
 * @param notifications - 通知列表
 * @returns 是否发生状态变化
 */
export function markAllNotificationsSeen(notifications: NgaNotification[]): boolean {
  return notificationPolicy.markAllSeen(notifications)
}

/**
 * 将私信类通知标记为已查看。
 *
 * @param notifications - 通知列表
 * @returns 是否发生状态变化
 */
export function markMessageNotificationsSeen(notifications: NgaNotification[]): boolean {
  return notificationPolicy.markSeenWhere(notifications,
    (item: NgaNotification): boolean => isMessageNotificationType(item.type))
}

/**
 * 将指定会话（mid）的私信通知标记为已查看。
 *
 * 私信 Tab 会话行的已读按可索引 ID（notificationId 内含 mid）精确表达：
 * 点击会话时仅标记该会话对应的私信通知，不波及其它会话。
 *
 * @param notifications - 通知列表
 * @param mid - 私信会话 ID
 * @returns 是否发生状态变化
 */
export function markMessageNotificationsSeenByMid(
  notifications: NgaNotification[],
  mid: string
): boolean {
  return notificationPolicy.markSeenWhere(notifications,
    (item: NgaNotification): boolean => {
      if (!isMessageNotificationType(item.type)) {
        return false
      }
      return (item as MessageNotification).mid === mid
    })
}

/**
 * 将非私信类通知全部标记为已查看。
 *
 * 消息 Tab 的「全部已读」只作用于帖子互动/点赞等通知，
 * 不波及私信通知（私信 Tab 的已读由 markMessageNotificationsSeen 系列管理）。
 *
 * @param notifications - 通知列表
 * @returns 是否发生状态变化
 */
export function markNonMessageNotificationsSeen(notifications: NgaNotification[]): boolean {
  return notificationPolicy.markSeenWhere(notifications,
    (item: NgaNotification): boolean => !isMessageNotificationType(item.type))
}

/**
 * 计算全部未查看通知数量。
 *
 * @param notifications - 通知列表
 * @returns 未查看通知数量
 */
export function countUnseenNotifications(notifications: NgaNotification[]): number {
  return notificationPolicy.countUnseen(notifications)
}

/**
 * 计算非私信未查看通知数量（消息 Tab 角标与铃铛计数的数据源）。
 *
 * @param notifications - 通知列表
 * @returns 未查看的非私信通知数量
 */
export function countUnseenNonMessageNotifications(notifications: NgaNotification[]): number {
  return notificationPolicy.countUnseenWhere(notifications,
    (item: NgaNotification): boolean => !isMessageNotificationType(item.type))
}

/**
 * 过滤出非私信通知（消息 Tab 展示数据源）。
 *
 * 私信通知保留在缓存中作为私信未读数与会话行已读（可索引 ID）的数据源，
 * 展示层通过本函数隔离。
 *
 * @param notifications - 通知列表
 * @returns 非私信通知数组（新数组）
 */
export function filterNonMessageNotifications(notifications: NgaNotification[]): NgaNotification[] {
  const result: NgaNotification[] = []
  for (let index: number = 0; index < notifications.length; index++) {
    const item: NgaNotification = notifications[index]
    if (!isMessageNotificationType(item.type)) {
      result.push(item)
    }
  }
  return result
}

/**
 * 计算未查看私信通知数量。
 *
 * @param notifications - 通知列表
 * @returns 未查看私信通知数量
 */
export function countUnseenMessageNotifications(notifications: NgaNotification[]): number {
  return notificationPolicy.countUnseenWhere(notifications,
    (item: NgaNotification): boolean => isMessageNotificationType(item.type))
}
