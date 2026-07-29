import { describe, it, expect } from '@ohos/hypium'
import {
  countUnseenMessageNotifications,
  countUnseenNotifications,
  markAllNotificationsSeen,
  markMessageNotificationsSeen,
  markNotificationSeen,
  mergeNotifications,
  shouldEnableNotificationPolling
} from '../main/ets/common/utils/NotificationPolicy'
import type {
  MessageNotification,
  NgaNotification,
  NotificationParseResult,
  ReplyNotification,
  UpvoteNotification
} from '../main/ets/model/Notification'
import { parseNotifications } from '../main/ets/parser/NotificationParser'

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
      expect(shouldEnableNotificationPolling(true, true, true)).assertTrue()
      expect(shouldEnableNotificationPolling(false, true, true)).assertFalse()
      expect(shouldEnableNotificationPolling(true, false, true)).assertFalse()
      expect(shouldEnableNotificationPolling(true, true, false)).assertFalse()
    })
  })

  describe('notificationParser', (): void => {
    it('distinguishesInvalidAndEmptyPayloads', 0, (): void => {
      const invalid: NotificationParseResult = parseNotifications(null)
      const emptyRaw: Record<string, Object> = { 'data': new Object() }
      const emptyGroupData: Record<string, Object> = { '0': '' }
      const emptyGroupRaw: Record<string, Object> = { 'data': emptyGroupData }
      const missingDataRaw: Record<string, Object> = {}
      const emptyArrayRaw: Object[] = []
      const empty: NotificationParseResult = parseNotifications(emptyRaw)
      const emptyGroup: NotificationParseResult = parseNotifications(emptyGroupRaw)
      const missingData: NotificationParseResult = parseNotifications(missingDataRaw)
      const emptyArray: NotificationParseResult = parseNotifications(emptyArrayRaw)
      expect(invalid.valid).assertFalse()
      expect(empty.valid).assertTrue()
      expect(empty.items.length).assertEqual(0)
      expect(emptyGroup.valid).assertTrue()
      expect(emptyGroup.items.length).assertEqual(0)
      expect(emptyGroup.malformedCount).assertEqual(0)
      expect(missingData.valid).assertTrue()
      expect(missingData.items.length).assertEqual(0)
      expect(emptyArray.valid).assertTrue()
      expect(emptyArray.items.length).assertEqual(0)
    })

    it('projectsKnownBatchesAndIgnoresContainerVariants', 0, (): void => {
      const group: Record<string, Object> = {
        'unread': 2,
        'lasttime': '400',
        '0': '',
        '1': new Object(),
        'metadata': 'future-field'
      }
      const data: Record<string, Object> = {
        '0': group,
        'future-category': 'future-value'
      }
      const raw: Record<string, Object> = { 'data': data }
      const parsed: NotificationParseResult = parseNotifications(raw)
      expect(parsed.valid).assertTrue()
      expect(parsed.items.length).assertEqual(0)
      expect(parsed.malformedCount).assertEqual(0)
      expect(parsed.unsupportedCount).assertEqual(0)
      expect(parsed.serverUnreadHint).assertEqual(2)
    })

    it('parsesKnownNotificationWithStableId', 0, (): void => {
      const entry: Record<string, Object> = {
        '0': 1,
        '1': '100',
        '2': 'tester',
        '5': 'topic',
        '6': '200',
        '7': '300',
        '8': '',
        '9': '400',
        '10': '1'
      }
      const group: Record<string, Object> = {
        'unread': 1,
        'lasttime': '400',
        '0': [entry]
      }
      const data: Record<string, Object> = { '0': group }
      const raw: Record<string, Object> = { 'data': data }
      const parsed: NotificationParseResult = parseNotifications(raw)
      expect(parsed.valid).assertTrue()
      expect(parsed.items.length).assertEqual(1)
      expect(parsed.items[0].notificationId).assertEqual('reply|1|200|300||400|100')
      expect(parsed.serverUnreadHint).assertEqual(1)
    })

    it('skipsNotificationTypesUnsupportedByMNGA', 0, (): void => {
      const unsupportedEntries: Record<string, Object>[] = [
        { '0': 3, '9': '400' },
        { '0': 4, '9': '401' },
        { '0': 12, '9': '402' },
        { '0': 15, '9': '403' },
        { '0': 999, '9': '404' }
      ]
      const group: Record<string, Object> = {
        'unread': 5,
        '0': unsupportedEntries
      }
      const data: Record<string, Object> = { '0': group }
      const raw: Record<string, Object> = { 'data': data }
      const parsed: NotificationParseResult = parseNotifications(raw)
      expect(parsed.valid).assertTrue()
      expect(parsed.items.length).assertEqual(0)
      expect(parsed.unsupportedCount).assertEqual(5)
    })

    it('parsesMNGASupportedNotificationBatches', 0, (): void => {
      const replyEntry: Record<string, Object> = {
        '0': 2,
        '1': '101',
        '2': 'replier',
        '5': 'replied topic',
        '6': '201',
        '7': '301',
        '8': '300',
        '9': '401',
        '10': '4'
      }
      const messageEntry: Record<string, Object> = {
        '0': 11,
        '1': '102',
        '2': 'sender',
        '6': '501',
        '9': '402'
      }
      const voteEntry: Record<string, Object> = {
        '0': 17,
        '3': '103',
        '5': 'voted topic',
        '6': '202',
        '7': '302',
        '9': '403',
        '10': '5'
      }
      const group: Record<string, Object> = {
        'unread': 3,
        'lasttime': '403',
        '0': [replyEntry],
        '1': [messageEntry],
        '2': [voteEntry]
      }
      const data: Record<string, Object> = { '0': group }
      const raw: Record<string, Object> = { 'data': data }
      const parsed: NotificationParseResult = parseNotifications(raw)
      expect(parsed.valid).assertTrue()
      expect(parsed.items.length).assertEqual(3)
      expect(parsed.items[0].type).assertEqual(2)
      expect((parsed.items[0] as ReplyNotification).replyPid).assertEqual('301')
      expect((parsed.items[1] as MessageNotification).mid).assertEqual('501')
      expect(parsed.items[2].type).assertEqual(17)
      expect((parsed.items[2] as UpvoteNotification).page).assertEqual('5')
      expect(parsed.serverUnreadHint).assertEqual(3)
    })

    it('rejectsKnownNotificationsWithoutNavigationKeys', 0, (): void => {
      const messageWithoutMid: Record<string, Object> = {
        '0': 10,
        '9': '400'
      }
      const replyWithoutTimestamp: Record<string, Object> = {
        '0': 1,
        '6': '200',
        '7': '300'
      }
      const voteWithoutTid: Record<string, Object> = {
        '0': 17,
        '7': '300',
        '9': '400'
      }
      const group: Record<string, Object> = {
        'unread': 1,
        '0': [replyWithoutTimestamp],
        '1': [messageWithoutMid],
        '2': [voteWithoutTid]
      }
      const data: Record<string, Object> = { '0': group }
      const raw: Record<string, Object> = { 'data': data }
      const parsed: NotificationParseResult = parseNotifications(raw)
      expect(parsed.valid).assertTrue()
      expect(parsed.items.length).assertEqual(0)
      expect(parsed.malformedCount).assertEqual(3)
    })
  })
}
