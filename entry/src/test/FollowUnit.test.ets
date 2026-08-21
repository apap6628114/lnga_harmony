import { describe, expect, it } from '@ohos/hypium'
import {
  parseFollowedUsers,
  extractFollowError,
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
 * fixtures 来自官方 APP 签名接口实测（follow_v2.get_follow / get_follow_by，
 * __output=12 的 {code,result:[...]} 形状；uid 为数字）；get_push_list 官方
 * 形状解析见 AppFollowActivityUnit.test.ets。
 */
export default function followUnitTest(): void {
  describe('followedUsersParser', (): void => {
    it('parsesFollowedUserFields', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":[{"uid":67071786,"username":"发发新闻罢了","groupid":-1,' +
          '"bit_data":168829440,"avatar":""}]}')
      const users = parseFollowedUsers(raw)
      expect(users.length).assertEqual(1)
      expect(users[0].uid).assertEqual('67071786')
      expect(users[0].userName).assertEqual('发发新闻罢了')
      expect(users[0].avatarUrl).assertEqual('')
      expect(users[0].groupId).assertEqual(-1)
      expect(users[0].bitData).assertEqual(168829440)
    })

    it('parsesMultipleUsersAndStringUid', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":[' +
          '{"uid":"41417929","username":"BugenZhao","groupid":-1,"bit_data":135537153,' +
          '"avatar":"https://img.nga.178.com/avatars/a.jpg"},' +
          '{"uid":262054,"username":"mettwu","groupid":-1,"bit_data":169091073,"avatar":""}' +
          ']}')
      const users = parseFollowedUsers(raw)
      expect(users.length).assertEqual(2)
      expect(users[0].uid).assertEqual('41417929')
      expect(users[1].uid).assertEqual('262054')
    })

    it('skipsEntryWithoutUid', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":[{"username":"NoUid"},{"uid":42,"username":"ok"}]}')
      const users = parseFollowedUsers(raw)
      expect(users.length).assertEqual(1)
      expect(users[0].uid).assertEqual('42')
    })

    it('skipsNonObjectEntries', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":[null,42,"str",{"uid":7,"username":"ok"}]}')
      const users = parseFollowedUsers(raw)
      expect(users.length).assertEqual(1)
      expect(users[0].uid).assertEqual('7')
    })

    it('returnsEmptyListForEmptyResult', 0, (): void => {
      const raw: object = JSON.parse('{"code":0,"result":[]}')
      const users = parseFollowedUsers(raw)
      expect(users.length).assertEqual(0)
    })

    it('returnsEmptyListForMissingResult', 0, (): void => {
      const users = parseFollowedUsers(JSON.parse('{}'))
      expect(users.length).assertEqual(0)
    })

    it('returnsEmptyListForBusinessFailure', 0, (): void => {
      const raw: object = JSON.parse('{"code":1,"msg":"请求错误"}')
      const users = parseFollowedUsers(raw)
      expect(users.length).assertEqual(0)
    })

    it('returnsEmptyListForUnrecognizedResultShape', 0, (): void => {
      const raw: object = JSON.parse('{"code":0,"result":{"0":{"0":{"uid":"42"}}}}')
      const users = parseFollowedUsers(raw)
      expect(users.length).assertEqual(0)
    })
  })

  describe('followErrorExtraction', (): void => {
    it('returnsNullForSuccess', 0, (): void => {
      const raw: object = JSON.parse('{"code":0,"result":["操作成功"]}')
      expect(extractFollowError(raw)).assertNull()
    })

    it('returnsMessageForBusinessFailure', 0, (): void => {
      const raw: object = JSON.parse('{"code":1,"msg":"你已经关注这个用户了"}')
      expect(extractFollowError(raw)).assertEqual('你已经关注这个用户了')
    })

    it('fallsBackToErrorCodeWhenMsgMissing', 0, (): void => {
      const raw: object = JSON.parse('{"code":2}')
      expect(extractFollowError(raw)).assertEqual('错误码: 2')
    })

    it('extractsLegacyErrorObject', 0, (): void => {
      const raw: object = JSON.parse('{"error":{"0":"操作失败"}}')
      expect(extractFollowError(raw)).assertEqual('操作失败')
    })

    it('extractsLegacyErrorString', 0, (): void => {
      const raw: object = JSON.parse('{"error":"操作失败"}')
      expect(extractFollowError(raw)).assertEqual('操作失败')
    })

    it('returnsFailureForParseErrorResponse', 0, (): void => {
      // ngaRequest JSON 解析失败形态（error 为 Error 实例，不可遍历）：
      // 必须先于 error/code 分支识别，否则会被误判为成功
      const raw: object = JSON.parse('{"__parseError":true,"__rawLength":12,"error":{}}')
      expect(extractFollowError(raw)).assertEqual('响应解析失败')
    })

    it('returnsNullForMissingShape', 0, (): void => {
      expect(extractFollowError(JSON.parse('{}'))).assertNull()
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
