import { describe, it, expect } from '@ohos/hypium'
import {
  countUnseenMessageNotifications,
  countUnseenNonMessageNotifications,
  countUnseenNotifications,
  filterNonMessageNotifications,
  markAllNotificationsSeen,
  markMessageNotificationsSeen,
  markMessageNotificationsSeenByMid,
  markNonMessageNotificationsSeen,
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
 * notificationId 按生产真实格式构造（`message|type|mid|timeStamp|userId`，
 * 见 AppNotificationParser.messageNotificationId），锁定「可索引 ID 内含 mid」契约。
 *
 * @param timeStamp - 通知时间戳
 * @param seen - 是否已查看
 * @param mid - 私信会话 ID
 * @returns 私信通知
 */
function createMessageNotification(
  timeStamp: string,
  seen: boolean,
  mid: string = '400'
): MessageNotification {
  return {
    notificationId: `message|10|${mid}|${timeStamp}|101`,
    type: 10,
    userId: '101',
    userName: 'sender',
    title: '',
    timeStamp: timeStamp,
    seen: seen,
    serverUnreadHint: 1,
    mid: mid
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
        createMessageNotification('200', false)
      ]
      const merged: NgaNotification[] = mergeNotifications(existing, incoming, 200)
      expect(merged.length).assertEqual(2)
      expect(merged[0].notificationId).assertEqual('message|10|400|200|101')
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
        createMessageNotification('200', false)
      ]
      const changed: boolean = markMessageNotificationsSeen(notifications)
      expect(changed).assertTrue()
      expect(countUnseenMessageNotifications(notifications)).assertEqual(0)
      expect(countUnseenNotifications(notifications)).assertEqual(1)
    })

    it('marksAllNotificationsSeen', 0, (): void => {
      const notifications: NgaNotification[] = [
        createReplyNotification('reply', '100', false),
        createMessageNotification('200', false)
      ]
      const changed: boolean = markAllNotificationsSeen(notifications)
      expect(changed).assertTrue()
      expect(countUnseenNotifications(notifications)).assertEqual(0)
    })

    it('marksOnlyTheSelectedNotificationSeen', 0, (): void => {
      const notifications: NgaNotification[] = [
        createReplyNotification('reply', '100', false),
        createMessageNotification('200', false)
      ]
      const changed: boolean = markNotificationSeen(notifications, 'message|10|400|200|101')
      expect(changed).assertTrue()
      expect(notifications[0].seen).assertFalse()
      expect(notifications[1].seen).assertTrue()
      expect(countUnseenNotifications(notifications)).assertEqual(1)
    })

    it('countsOnlyNonMessageNotifications', 0, (): void => {
      const notifications: NgaNotification[] = [
        createReplyNotification('reply', '100', false),
        createMessageNotification('200', false),
        createReplyNotification('reply2', '300', true)
      ]
      expect(countUnseenNonMessageNotifications(notifications)).assertEqual(1)
      expect(countUnseenMessageNotifications(notifications)).assertEqual(1)
    })

    it('marksNonMessageNotificationsIndependently', 0, (): void => {
      const notifications: NgaNotification[] = [
        createReplyNotification('reply', '100', false),
        createMessageNotification('200', false)
      ]
      const changed: boolean = markNonMessageNotificationsSeen(notifications)
      expect(changed).assertTrue()
      expect(notifications[0].seen).assertTrue()
      expect(notifications[1].seen).assertFalse()
      expect(countUnseenNotifications(notifications)).assertEqual(1)
      expect(countUnseenMessageNotifications(notifications)).assertEqual(1)
    })

    it('marksMessageNotificationsSeenByMidOnly', 0, (): void => {
      const notifications: NgaNotification[] = [
        createReplyNotification('reply', '100', false),
        createMessageNotification('200', false, '400'),
        createMessageNotification('300', false, '401')
      ]
      const changed: boolean = markMessageNotificationsSeenByMid(notifications, '400')
      expect(changed).assertTrue()
      expect(notifications[0].seen).assertFalse()
      expect(notifications[1].seen).assertTrue()
      expect(notifications[2].seen).assertFalse()
      expect(countUnseenMessageNotifications(notifications)).assertEqual(1)
    })

    it('marksMessageNotificationsSeenByMidNoOpWhenAlreadySeen', 0, (): void => {
      const notifications: NgaNotification[] = [
        createMessageNotification('200', true, '400'),
        createMessageNotification('300', false, '401')
      ]
      const changed: boolean = markMessageNotificationsSeenByMid(notifications, '400')
      expect(changed).assertFalse()
      expect(countUnseenMessageNotifications(notifications)).assertEqual(1)
    })

    it('marksAllUnseenForSameMid', 0, (): void => {
      const notifications: NgaNotification[] = [
        createMessageNotification('200', false, '400'),
        createMessageNotification('300', false, '400'),
        createMessageNotification('400', false, '401')
      ]
      const changed: boolean = markMessageNotificationsSeenByMid(notifications, '400')
      expect(changed).assertTrue()
      expect(notifications[0].seen).assertTrue()
      expect(notifications[1].seen).assertTrue()
      expect(notifications[2].seen).assertFalse()
      expect(countUnseenMessageNotifications(notifications)).assertEqual(1)
    })

    it('filtersOutMessageNotifications', 0, (): void => {
      const notifications: NgaNotification[] = [
        createReplyNotification('reply', '100', false),
        createMessageNotification('200', false, '400'),
        createReplyNotification('reply2', '300', true)
      ]
      const filtered: NgaNotification[] = filterNonMessageNotifications(notifications)
      expect(filtered.length).assertEqual(2)
      expect(filtered[0].notificationId).assertEqual('reply')
      expect(filtered[1].notificationId).assertEqual('reply2')
    })

    it('enablesPollingOnlyForAuthenticatedForegroundApp', 0, (): void => {
      expect(shouldEnablePolling(true, true, true)).assertTrue()
      expect(shouldEnablePolling(false, true, true)).assertFalse()
      expect(shouldEnablePolling(true, false, true)).assertFalse()
      expect(shouldEnablePolling(true, true, false)).assertFalse()
    })
  })
}
