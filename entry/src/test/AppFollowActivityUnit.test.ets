import { describe, expect, it } from '@ohos/hypium'
import { parseAppFollowedActivity } from '../main/ets/parser/FollowParser'
import {
  FollowedActivity,
  FollowedActivityParseResult,
  FollowedActivityType,
} from '../main/ets/model/Follow'

/**
 * 官方 APP 关注动态解析器单元测试（follow_v2.get_push_list __output=12）。
 * fixtures 形状来自 ngabbs.com 官方签名接口实测样本（动态 id/uid/tid 已替换为合成数据）。
 */
export default function appFollowActivityUnitTest(): void {
  describe('appFollowedActivityParser', (): void => {
    it('parsesAppActivityItemsWithSummaryBackfill', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":[' +
          '{"0":13402751,"1":1,"2":67071786,"3":47407086,"4":0,"5":0,' +
          '"6":1787217026,"7":0,"8":0,' +
          '"summary":"你关注的 [uid=67071786]发发新闻罢了[/uid] 发布了主题 ' +
          '[tid=47407086]PNAS:X 算法向民主党用户推送更多激发愤怒的内容[/tid]"},' +
          '{"0":13395255,"1":2,"2":60362479,"3":47397636,"4":88776655,"5":88776654,' +
          '"6":1787102271,"7":0,"8":0,' +
          '"summary":"你关注的 [uid=60362479]霜叶蓝了[/uid] 回复了主题 ' +
          '[tid=47397636]通过 Zoom 解雇 900 名雇员的 CEO 被解雇[/tid]"}' +
          ']}')
      const result: FollowedActivityParseResult = parseAppFollowedActivity(raw)
      expect(result.activities.length).assertEqual(2)
      // 官方接口不分页：pages 恒 1
      expect(result.pages).assertEqual(1)

      const topic: FollowedActivity = result.activities[0]
      expect(topic.id).assertEqual('13402751')
      expect(topic.type).assertEqual(FollowedActivityType.POST_TOPIC)
      expect(topic.actorUid).assertEqual('67071786')
      expect(topic.tid).assertEqual('47407086')
      expect(topic.pid).assertEqual('0')
      expect(topic.timestamp).assertEqual(1787217026)
      expect(topic.favorTableId).assertEqual('0')
      // 无用户表/主题表：行为者名与主题标题从 summary 提取回填
      expect(topic.actorName).assertEqual('发发新闻罢了')
      expect(topic.subject).assertEqual('PNAS:X 算法向民主党用户推送更多激发愤怒的内容')
      expect(topic.summary.length).assertLarger(0)

      const reply: FollowedActivity = result.activities[1]
      expect(reply.type).assertEqual(FollowedActivityType.POST_REPLY)
      expect(reply.pid).assertEqual('88776655')
      expect(reply.replyTarget).assertEqual('88776654')
      expect(reply.actorName).assertEqual('霜叶蓝了')
    })

    it('leavesNamesEmptyWhenSummaryLacksTags', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":[' +
          '{"0":100,"1":1,"2":42,"3":99,"4":0,"5":0,"6":1787000000,"7":0,"8":0,' +
          '"summary":"无标签摘要文本"}' +
          ']}')
      const result: FollowedActivityParseResult = parseAppFollowedActivity(raw)
      expect(result.activities.length).assertEqual(1)
      expect(result.activities[0].actorName).assertEqual('')
      expect(result.activities[0].subject).assertEqual('')
      expect(result.activities[0].summary).assertEqual('无标签摘要文本')
    })

    it('parsesFavorTypeWithReplyTargetAndTableId', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":[' +
          '{"0":200,"1":3,"2":42,"3":999,"4":0,"5":77,"6":1787000100,"7":9,"8":0,' +
          '"summary":"你关注的 [uid=42]收藏家[/uid] 收藏了主题 [tid=999]收藏标题[/tid]"}' +
          ']}')
      const result: FollowedActivityParseResult = parseAppFollowedActivity(raw)
      expect(result.activities.length).assertEqual(1)
      expect(result.activities[0].type).assertEqual(FollowedActivityType.FAVOR)
      expect(result.activities[0].replyTarget).assertEqual('77')
      expect(result.activities[0].favorTableId).assertEqual('9')
      expect(result.activities[0].subject).assertEqual('收藏标题')
    })

    it('fallsBackTimestampAndTypeForInvalidValues', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":[' +
          '{"0":300,"1":99,"2":42,"3":999,"4":0,"5":0,"6":0,"7":0,"8":0,"summary":""},' +
          '{"0":301,"1":2,"2":42,"3":999,"4":0,"5":0,"6":"abc","7":0,"8":0,"summary":""}' +
          ']}')
      const result: FollowedActivityParseResult = parseAppFollowedActivity(raw)
      expect(result.activities.length).assertEqual(2)
      // 非法类型（99）→ UNKNOWN；非法时间戳（0/非数字）→ 0
      expect(result.activities[0].type).assertEqual(FollowedActivityType.UNKNOWN)
      expect(result.activities[0].timestamp).assertEqual(0)
      expect(result.activities[1].timestamp).assertEqual(0)
    })

    it('extractsTitleWithEmbeddedBbcodeFromSummary', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":[' +
          '{"0":400,"1":1,"2":42,"3":999,"4":0,"5":0,"6":1787000200,"7":0,"8":0,' +
          '"summary":"你关注的 [uid=42]测试员[/uid] 发布了主题 ' +
          '[tid=999][color=red]标题含 BBCode[/color][b]加粗[/b][/tid]"}' +
          ']}')
      const result: FollowedActivityParseResult = parseAppFollowedActivity(raw)
      expect(result.activities.length).assertEqual(1)
      expect(result.activities[0].actorName).assertEqual('测试员')
      // 非贪婪提取到 [/tid] 为止，标题内 BBCode 原样保留
      expect(result.activities[0].subject).assertEqual('[color=red]标题含 BBCode[/color][b]加粗[/b]')
    })

    it('returnsEmptyForEmptyResult', 0, (): void => {
      const raw: object = JSON.parse('{"code":0,"result":[]}')
      const result: FollowedActivityParseResult = parseAppFollowedActivity(raw)
      expect(result.activities.length).assertEqual(0)
      expect(result.pages).assertEqual(1)
    })

    it('returnsEmptyForBusinessFailure', 0, (): void => {
      const raw: object = JSON.parse('{"code":1,"msg":"请求错误"}')
      const result: FollowedActivityParseResult = parseAppFollowedActivity(raw)
      expect(result.activities.length).assertEqual(0)
    })

    it('returnsEmptyForUnrecognizedResultShape', 0, (): void => {
      const raw: object = JSON.parse('{"code":0,"result":{"0":{"0":1}}}')
      const result: FollowedActivityParseResult = parseAppFollowedActivity(raw)
      expect(result.activities.length).assertEqual(0)
    })

    it('skipsEntryWithoutId', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":[' +
          '{"1":1,"2":42,"3":99,"summary":"缺 id 条目"},' +
          '{"0":7,"1":1,"2":42,"3":99,"summary":"正常条目"}' +
          ']}')
      const result: FollowedActivityParseResult = parseAppFollowedActivity(raw)
      expect(result.activities.length).assertEqual(1)
      expect(result.activities[0].id).assertEqual('7')
    })
  })
}
