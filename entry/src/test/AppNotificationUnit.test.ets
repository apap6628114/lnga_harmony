import { describe, expect, it } from '@ohos/hypium'
import { parseAppNotifications } from '../main/ets/parser/AppNotificationParser'
import type { NotificationParseResult } from '../main/ets/model/Notification'
import {
  ReplyNotification,
  MessageNotification,
  UpvoteNotification,
} from '../main/ets/model/Notification'

/**
 * 官方 APP 通知解析器单元测试（app_api.php notify/list，__output=14）。
 * fixtures 形状来自 ngabbs.com 官方签名接口实测样本（uid/tid/标题已替换为合成数据）。
 */
export default function appNotificationUnitTest(): void {
  describe('appNotificationParser', (): void => {
    it('parsesReplyBatchFields', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"msg":"操作成功","result":{"reply":[' +
          '{"time":"1787302659","type":"2","from_uid":"61165627","to_uid":"42023922",' +
          '"about_id3":"879163948","about_id":"47412557","about_id2":"879167934",' +
          '"about_id4":"2","":"0","from_uname":"测试用户甲","to_uname":"llllllIl",' +
          '"text":"测试主题标题"}' +
          '],"msg":[],"sys":[],"unread":0,"lasttime":"1787338016",' +
          '"unread_cnt":{"reply":0,"msg":0,"sys":0,"follow":0,"unread":0},' +
          '"checked_in":false}}')
      const parsed: NotificationParseResult = parseAppNotifications(raw)
      expect(parsed.valid).assertTrue()
      expect(parsed.items.length).assertEqual(1)
      const item = parsed.items[0] as ReplyNotification
      expect(item.type).assertEqual(2)
      // 字段映射：from_uid/from_uname、about_id→tid、about_id2→replyPid、
      // about_id3→repliedPid、about_id4→page、text→title
      expect(item.userId).assertEqual('61165627')
      expect(item.userName).assertEqual('测试用户甲')
      expect(item.tid).assertEqual('47412557')
      expect(item.replyPid).assertEqual('879167934')
      expect(item.repliedPid).assertEqual('879163948')
      expect(item.page).assertEqual('2')
      expect(item.title).assertEqual('测试主题标题')
      expect(item.timeStamp).assertEqual('1787302659')
      expect(item.seen).assertFalse()
      expect(item.serverUnreadHint).assertEqual(0)
      // 本地稳定 ID 与网页版格式一致（reply|type|tid|replyPid|repliedPid|time|uid）
      expect(item.notificationId).assertEqual(
        'reply|2|47412557|879167934|879163948|1787302659|61165627')
    })

    it('parsesMessageBatchAsMid', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":{"reply":[],' +
          '"msg":[{"time":"1787300000","type":"10","from_uid":"42","from_uname":"发信人",' +
          '"about_id":"3405931","text":"私信标题"}],' +
          '"sys":[],"unread":0}}')
      const parsed: NotificationParseResult = parseAppNotifications(raw)
      expect(parsed.valid).assertTrue()
      expect(parsed.items.length).assertEqual(1)
      const item = parsed.items[0] as MessageNotification
      expect(item.type).assertEqual(10)
      expect(item.mid).assertEqual('3405931')
      expect(item.userName).assertEqual('发信人')
      expect(item.title).assertEqual('私信标题')
      expect(item.notificationId).assertEqual('message|10|3405931|1787300000|42')
    })

    it('parsesSysBatchUpvoteFields', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":{"reply":[],"msg":[],' +
          '"sys":[{"time":"1787301000","type":"17","to_uid":"88",' +
          '"about_id":"47412557","about_id2":"879167934","about_id4":"1",' +
          '"text":"赞了你的主题"}],' +
          '"unread":2}}')
      const parsed: NotificationParseResult = parseAppNotifications(raw)
      expect(parsed.valid).assertTrue()
      expect(parsed.items.length).assertEqual(1)
      const item = parsed.items[0] as UpvoteNotification
      expect(item.type).assertEqual(17)
      expect(item.toUid).assertEqual('88')
      expect(item.tid).assertEqual('47412557')
      expect(item.pid).assertEqual('879167934')
      expect(item.page).assertEqual('1')
      expect(item.notificationId).assertEqual('upvote|17|47412557|879167934|1787301000|88')
      // 顶层 unread 作为服务端未读提示
      expect(parsed.serverUnreadHint).assertEqual(2)
    })

    it('fallsBackToUnreadCntWhenTopUnreadMissing', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":{"reply":[],"msg":[],"sys":[],' +
          '"unread_cnt":{"reply":1,"msg":0,"sys":0,"follow":0,"unread":3}}}')
      const parsed: NotificationParseResult = parseAppNotifications(raw)
      expect(parsed.valid).assertTrue()
      expect(parsed.items.length).assertEqual(0)
      expect(parsed.serverUnreadHint).assertEqual(3)
    })

    it('countsMalformedEntries', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":{"reply":[' +
          '{"time":"","type":"2"},' +
          '{"time":"1787300000","type":"2","about_id":"","about_id2":"1"}' +
          '],"msg":[],"sys":[]}}')
      const parsed: NotificationParseResult = parseAppNotifications(raw)
      expect(parsed.valid).assertTrue()
      expect(parsed.items.length).assertEqual(0)
      expect(parsed.malformedCount).assertEqual(2)
    })

    it('countsUnsupportedTypes', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":{"reply":[],"msg":[],' +
          '"sys":[{"time":"1787300000","type":"99","from_uid":"1","from_uname":"x"}]}}')
      const parsed: NotificationParseResult = parseAppNotifications(raw)
      expect(parsed.valid).assertTrue()
      expect(parsed.items.length).assertEqual(0)
      expect(parsed.unsupportedCount).assertEqual(1)
    })

    it('returnsInvalidForBusinessFailure', 0, (): void => {
      const raw: object = JSON.parse('{"code":4,"msg":"参数错误"}')
      const parsed: NotificationParseResult = parseAppNotifications(raw)
      expect(parsed.valid).assertFalse()
      expect(parsed.items.length).assertEqual(0)
    })

    it('treatsMissingResultAsValidEmpty', 0, (): void => {
      const parsed: NotificationParseResult = parseAppNotifications(JSON.parse('{"code":0}'))
      expect(parsed.valid).assertTrue()
      expect(parsed.items.length).assertEqual(0)
    })

    it('treatsNullResultAsValidEmpty', 0, (): void => {
      const parsed: NotificationParseResult = parseAppNotifications(JSON.parse('{"code":0,"result":null}'))
      expect(parsed.valid).assertTrue()
      expect(parsed.items.length).assertEqual(0)
    })

    it('countsNullAndNonIntegerTypeEntriesAsMalformed', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":{"reply":[' +
          'null,' +
          '{"time":"1787300000","type":"2.5","from_uid":"1","from_uname":"x"},' +
          '{"time":"1787300001","type":2,"from_uid":"2","from_uname":"ok",' +
          '"about_id":"10","about_id2":"20"}' +
          '],"msg":[],"sys":[]}}')
      const parsed: NotificationParseResult = parseAppNotifications(raw)
      expect(parsed.valid).assertTrue()
      // 批内 null 元素与 type 非整数条目计入 malformed，正常条目照常解析
      expect(parsed.malformedCount).assertEqual(2)
      expect(parsed.items.length).assertEqual(1)
      expect(parsed.items[0].userId).assertEqual('2')
    })

    it('treatsNullAsInvalid', 0, (): void => {
      const parsed: NotificationParseResult = parseAppNotifications(null)
      expect(parsed.valid).assertFalse()
      expect(parsed.items.length).assertEqual(0)
    })
  })
}
