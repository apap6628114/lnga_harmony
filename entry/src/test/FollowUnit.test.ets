import { describe, expect, it } from '@ohos/hypium'
import {
  parseFollowedUsers,
  parseFollowedActivity,
} from '../main/ets/parser/FollowParser'
import { FollowedActivityType } from '../main/ets/model/Follow'

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

  describe('followedActivityParser', (): void => {
    it('parsesPostTopicActivityWithLookupBackfill', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"0":{"0":[123,1,"42","999","0","0","1700000000",0]},' +
          '"1":{"42":{"uid":"42","username":"tester"}},' +
          '"2":"3","3":"1",' +
          '"4":{"999":{"tid":"999","fid":"1","author":"tester","authorid":"42","subject":"test topic"}}}}')
      const result = parseFollowedActivity(raw)
      expect(result.activities.length).assertEqual(1)
      expect(result.pages).assertEqual(3)
      const activity = result.activities[0]
      expect(activity.id).assertEqual('123')
      expect(activity.type).assertEqual(FollowedActivityType.POST_TOPIC)
      expect(activity.actorUid).assertEqual('42')
      expect(activity.actorName).assertEqual('tester')
      expect(activity.tid).assertEqual('999')
      expect(activity.pid).assertEqual('0')
      expect(activity.timestamp).assertEqual(1700000000)
      expect(activity.subject).assertEqual('test topic')
      expect(activity.fid).assertEqual('1')
    })

    it('parsesPostReplyAndFavorTypes', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"0":{"0":[1,2,"42","999","88","77","1700000001",0],' +
          '"1":[2,3,"42","999","0","55","1700000002",9]},' +
          '"1":{},"4":{}}}')
      const result = parseFollowedActivity(raw)
      expect(result.activities.length).assertEqual(2)
      expect(result.activities[0].type).assertEqual(FollowedActivityType.POST_REPLY)
      expect(result.activities[0].pid).assertEqual('88')
      expect(result.activities[0].replyTarget).assertEqual('77')
      expect(result.activities[1].type).assertEqual(FollowedActivityType.FAVOR)
      expect(result.activities[1].replyTarget).assertEqual('55')
      expect(result.activities[1].favorTableId).assertEqual('9')
    })

    it('mapsUnknownTypeToUnknown', 0, (): void => {
      const raw: object = JSON.parse('{"data":{"0":{"0":[1,99,"42","999","0","0","0",0]}}}')
      const result = parseFollowedActivity(raw)
      expect(result.activities[0].type).assertEqual(FollowedActivityType.UNKNOWN)
    })

    it('handlesEmptyPayloadShape', 0, (): void => {
      const raw: object = JSON.parse('{"data":{"0":{},"1":"","2":"","3":"","4":""}}')
      const result = parseFollowedActivity(raw)
      expect(result.activities.length).assertEqual(0)
      expect(result.pages).assertEqual(0)
    })

    it('parsesPagesFromStringField', 0, (): void => {
      const raw: object = JSON.parse('{"data":{"0":{},"2":"5"}}')
      const result = parseFollowedActivity(raw)
      expect(result.pages).assertEqual(5)
    })

    it('toleratesMissingUsersAndTopics', 0, (): void => {
      const raw: object = JSON.parse('{"data":{"0":{"0":[1,1,"42","999","0","0","0",0]}}}')
      const result = parseFollowedActivity(raw)
      expect(result.activities.length).assertEqual(1)
      expect(result.activities[0].actorName).assertEqual('')
      expect(result.activities[0].subject).assertEqual('')
    })

    it('skipsEntryWithoutId', 0, (): void => {
      const raw: object = JSON.parse('{"data":{"0":{"0":["",1,"42","999","0","0","0",0],' +
        '"1":[7,2,"42","888","0","0","0",0]}}}')
      const result = parseFollowedActivity(raw)
      expect(result.activities.length).assertEqual(1)
      expect(result.activities[0].id).assertEqual('7')
    })

    it('parsesObjectFormEntryWithSummary', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"0":{"0":{"0":"55","1":2,"2":"42","3":"999","4":"3","5":"0","6":"1700000000","7":"0","summary":"hello &amp; world"}}}}')
      const result = parseFollowedActivity(raw)
      expect(result.activities.length).assertEqual(1)
      expect(result.activities[0].type).assertEqual(FollowedActivityType.POST_REPLY)
      expect(result.activities[0].pid).assertEqual('3')
      expect(result.activities[0].summary).assertEqual('hello &amp; world')
    })
  })
}
