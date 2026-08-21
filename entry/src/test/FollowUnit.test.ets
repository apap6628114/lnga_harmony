import { describe, expect, it } from '@ohos/hypium'
import {
  parseFollowedUsers,
} from '../main/ets/parser/FollowParser'
import {
  appendDedupe,
  countUnseenActivities,
  markActivitiesSeenByIds,
  markAllActivitiesSeen,
  mergeActivities
} from '../main/ets/common/utils/FollowActivityPolicy'
import { FollowedActivity, FollowedActivityType } from '../main/ets/model/Follow'

/**
 * 创建关注动态测试数据。
 *
 * @param id - 动态 ID
 * @param timestamp - 行为时间戳
 * @param seen - 是否已读
 * @returns 关注动态
 */
function createActivity(id: string, timestamp: number, seen: boolean): FollowedActivity {
  const activity: FollowedActivity = new FollowedActivity()
  activity.id = id
  activity.type = FollowedActivityType.POST_TOPIC
  activity.actorUid = '42'
  activity.actorName = 'tester'
  activity.tid = '999'
  activity.pid = '0'
  activity.fid = '1'
  activity.subject = 'topic'
  activity.timestamp = timestamp
  activity.replyTarget = ''
  activity.favorTableId = ''
  activity.summary = ''
  activity.seen = seen
  return activity
}

/**
 * 关注系统解析器单元测试。
 * fixtures 来自 bbs.nga.cn 真实抓包（follow_v2.get_follow / get_push_list）。
 */
export default function followUnitTest(): void {
  describe('followedUsersParser', (): void => {
    it('parsesFollowedUserFields', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"0":{"0":{"uid":"41417929","username":"BugenZhao","groupid":-1,' +
          '"bit_data":135537153,"avatar":"https://img.nga.178.com/avatars/a.jpg"}}}}')
      const users = parseFollowedUsers(raw)
      expect(users.length).assertEqual(1)
      expect(users[0].uid).assertEqual('41417929')
      expect(users[0].userName).assertEqual('BugenZhao')
      expect(users[0].avatarUrl).assertEqual('https://img.nga.178.com/avatars/a.jpg')
      expect(users[0].groupId).assertEqual(-1)
      expect(users[0].bitData).assertEqual(135537153)
    })

    it('skipsEntryWithoutUid', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"0":{"0":{"username":"NoUid"},"1":{"uid":"42","username":"ok"}}}}')
      const users = parseFollowedUsers(raw)
      expect(users.length).assertEqual(1)
      expect(users[0].uid).assertEqual('42')
    })

    it('returnsEmptyListForEmptyContainer', 0, (): void => {
      const raw: object = JSON.parse('{"data":{"0":{}}}')
      const users = parseFollowedUsers(raw)
      expect(users.length).assertEqual(0)
    })

    it('returnsEmptyListForMissingData', 0, (): void => {
      const users = parseFollowedUsers(JSON.parse('{}'))
      expect(users.length).assertEqual(0)
    })
  })

  describe('followActivityPolicy', (): void => {
    it('mergesActivitiesWithSeenPreservedAndStableOrder', 0, (): void => {
      const existing: FollowedActivity[] = [createActivity('a', 100, true)]
      const incoming: FollowedActivity[] = [
        createActivity('b', 200, false),
        createActivity('a', 100, false)
      ]
      const merged: FollowedActivity[] = mergeActivities(existing, incoming, 200)
      expect(merged.length).assertEqual(2)
      expect(merged[0].id).assertEqual('b')
      expect(merged[0].seen).assertFalse()
      expect(merged[1].id).assertEqual('a')
      expect(merged[1].seen).assertTrue()
    })

    it('keepsActivityOrderStableWithinSameTimestamp', 0, (): void => {
      const incoming: FollowedActivity[] = [
        createActivity('z', 100, false),
        createActivity('a', 100, false)
      ]
      const merged: FollowedActivity[] = mergeActivities([], incoming, 200)
      expect(merged.length).assertEqual(2)
      expect(merged[0].id).assertEqual('z')
      expect(merged[1].id).assertEqual('a')
    })

    it('appendsDedupeInOrderWithoutResorting', 0, (): void => {
      const existing: FollowedActivity[] = [
        createActivity('a', 300, false),
        createActivity('b', 200, false)
      ]
      const incoming: FollowedActivity[] = [
        createActivity('b', 200, false),
        createActivity('c', 100, false)
      ]
      const appended: FollowedActivity[] = appendDedupe(existing, incoming)
      expect(appended.length).assertEqual(3)
      expect(appended[0].id).assertEqual('a')
      expect(appended[1].id).assertEqual('b')
      expect(appended[2].id).assertEqual('c')
    })

    it('marksActivitiesSeenByIdsOnly', 0, (): void => {
      const activities: FollowedActivity[] = [
        createActivity('a', 100, false),
        createActivity('b', 200, false)
      ]
      const ids: Set<string> = new Set<string>()
      ids.add('a')
      const changed: boolean = markActivitiesSeenByIds(activities, ids)
      expect(changed).assertTrue()
      expect(activities[0].seen).assertTrue()
      expect(activities[1].seen).assertFalse()
      expect(countUnseenActivities(activities)).assertEqual(1)
    })

    it('marksAllActivitiesSeen', 0, (): void => {
      const activities: FollowedActivity[] = [
        createActivity('a', 100, false),
        createActivity('b', 200, true)
      ]
      const changed: boolean = markAllActivitiesSeen(activities)
      expect(changed).assertTrue()
      expect(countUnseenActivities(activities)).assertEqual(0)
    })

    it('countsNewIncomingActivitiesAsUnseen', 0, (): void => {
      const existing: FollowedActivity[] = [createActivity('a', 100, true)]
      const incoming: FollowedActivity[] = [createActivity('b', 200, false)]
      const merged: FollowedActivity[] = mergeActivities(existing, incoming, 200)
      expect(countUnseenActivities(merged)).assertEqual(1)
    })
  })
}
