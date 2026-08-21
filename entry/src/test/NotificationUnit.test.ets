import { describe, it, expect } from '@ohos/hypium'
import {
  countUnseenMessageNotifications,
  countUnseenNotifications,
  markAllNotificationsSeen,
  markMessageNotificationsSeen,
  markNotificationSeen,
  mergeNotifications
} from '../main/ets/common/utils/NotificationPolicy'
import { shouldEnablePolling } from '../main/ets/common/concurrency/PollingController'
import type {
  MessageNotification,
  NgaNotification,
  ReplyNotification
} from '../main/ets/model/Notification'

/**
 * 创建帖子互动通知测试数据。
 *
 * @param notificationId - 通知 ID
 * @param timeStamp - 通知时间戳
 * @param seen - 是否已查看
 * @returns 帖子互动通知
 */
function createReplyNotification(
  notificationId: string,
  timeStamp: string,
  seen: boolean
): ReplyNotification {
  return {
    notificationId: notificationId,
    type: 1,
    userId: '100',
    userName: 'tester',
    title: 'topic',
    timeStamp: timeStamp,
    seen: seen,
    serverUnreadHint: 1,
    repliedId: '',
    repliedName: '',
    tid: '200',
    replyPid: '300',
    repliedPid: '',
    page: '1'
  }
}

/**
 * 创建私信通知测试数据。
 *
 * @param notificationId - 通知 ID
 * @param timeStamp - 通知时间戳
 * @param seen - 是否已查看
 * @returns 私信通知
 */
function createMessageNotification(
  notificationId: string,
  timeStamp: string,
  seen: boolean
): MessageNotification {
  return {
    notificationId: notificationId,
    type: 10,
    userId: '101',
    userName: 'sender',
    title: '',
    timeStamp: timeStamp,
    seen: seen,
    serverUnreadHint: 1,
    mid: '400'
  }
}

/**
 * 注册通知策略单元测试。
 */
export default function notificationUnitTest(): void {
  describe('notificationPolicy', (): void => {
    it('mergesWithoutReplacingHistory', 0, (): void => {
      const existing: NgaNotification[] = [
        createReplyNotification('old', '100', true)
      ]
      const incoming: NgaNotification[] = [
        createMessageNotification('new', '200', false)
      ]
      const merged: NgaNotification[] = mergeNotifications(existing, incoming, 200)
      expect(merged.length).assertEqual(2)
      expect(merged[0].notificationId).assertEqual('new')
      expect(merged[1].notificationId).assertEqual('old')
    })

    it('preservesSeenStateForDuplicates', 0, (): void => {
      const existing: NgaNotification[] = [
        createReplyNotification('same', '100', true)
      ]
      const incoming: NgaNotification[] = [
        createReplyNotification('same', '100', false)
      ]
      const merged: NgaNotification[] = mergeNotifications(existing, incoming, 200)
      expect(merged.length).assertEqual(1)
      expect(merged[0].seen).assertTrue()
    })

    it('keepsStateWhenIncomingIsEmpty', 0, (): void => {
      const existing: NgaNotification[] = [
        createReplyNotification('old', '100', false)
      ]
      const merged: NgaNotification[] = mergeNotifications(existing, [], 200)
      expect(merged.length).assertEqual(1)
      expect(countUnseenNotifications(merged)).assertEqual(1)
    })

    it('marksMessageNotificationsIndependently', 0, (): void => {
      const notifications: NgaNotification[] = [
        createReplyNotification('reply', '100', false),
        createMessageNotification('message', '200', false)
      ]
      const changed: boolean = markMessageNotificationsSeen(notifications)
      expect(changed).assertTrue()
      expect(countUnseenMessageNotifications(notifications)).assertEqual(0)
      expect(countUnseenNotifications(notifications)).assertEqual(1)
    })

    it('marksAllNotificationsSeen', 0, (): void => {
      const notifications: NgaNotification[] = [
        createReplyNotification('reply', '100', false),
        createMessageNotification('message', '200', false)
      ]
      const changed: boolean = markAllNotificationsSeen(notifications)
      expect(changed).assertTrue()
      expect(countUnseenNotifications(notifications)).assertEqual(0)
    })

    it('marksOnlyTheSelectedNotificationSeen', 0, (): void => {
      const notifications: NgaNotification[] = [
        createReplyNotification('reply', '100', false),
        createMessageNotification('message', '200', false)
      ]
      const changed: boolean = markNotificationSeen(notifications, 'message')
      expect(changed).assertTrue()
      expect(notifications[0].seen).assertFalse()
      expect(notifications[1].seen).assertTrue()
      expect(countUnseenNotifications(notifications)).assertEqual(1)
    })

    it('enablesPollingOnlyForAuthenticatedForegroundApp', 0, (): void => {
      expect(shouldEnablePolling(true, true, true)).assertTrue()
      expect(shouldEnablePolling(false, true, true)).assertFalse()
      expect(shouldEnablePolling(true, false, true)).assertFalse()
      expect(shouldEnablePolling(true, true, false)).assertFalse()
    })
  })
}
