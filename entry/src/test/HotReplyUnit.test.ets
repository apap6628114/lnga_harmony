import { describe, it, expect } from '@ohos/hypium'
import { parseThreadData } from '../main/ets/parser/ThreadParser'
import { applyBlacklistStateToPosts } from '../main/ets/common/utils/BlacklistUtils'
import { collectPostContents } from '../main/ets/common/utils/PostWarmup'
import type { ThreadRowInfo } from '../main/ets/model/Thread'
import { PostInfo } from '../main/ets/model/PostInfo'

/**
 * 注册热点回复解析与状态传播单元测试。
 */
export default function hotReplyUnitTest(): void {
  describe('hotReplyParser', (): void => {
    it('parsesHotRepliesRecursively', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"__R":{"0":{"pid":100,"authorid":"10","content":"楼主正文",' +
          '"hotreply":{"0":{"pid":201,"authorid":"42","lou":2,"score":268,' +
          '"postdate":"2026-08-06 10:41","content":"热评一"},' +
          '"1":{"pid":202,"authorid":"43","lou":5,"score":82,"content":"热评二"}},' +
          '"hotreply_id":{"0":"","1":201,"2":202}},' +
          '"1":{"pid":101,"authorid":"11","content":"普通楼层"}},' +
          '"__ROWS":2,"__R__ROWS_PAGE":20}}')
      const result = parseThreadData(raw)
      expect(result.rowList.length).assertEqual(2)
      expect(result.rowList[0].hotReplies.length).assertEqual(2)
      const first: ThreadRowInfo = result.rowList[0].hotReplies[0]
      expect(first.pid).assertEqual(201)
      expect(first.lou).assertEqual(2)
      expect(first.score).assertEqual(268)
      expect(first.authorid).assertEqual(42)
      expect(first.content).assertEqual('热评一')
      expect(first.postdate).assertEqual('2026-08-06 10:41')
      // 递归终止：热评叶子项不携带嵌套数据
      expect(first.attachs.length).assertEqual(0)
      expect(first.comments.length).assertEqual(0)
      expect(first.hotReplies.length).assertEqual(0)
      // 普通楼层无热评
      expect(result.rowList[1].hotReplies.length).assertEqual(0)
    })

    it('hotRepliesEmptyWhenFieldAbsent', 0, (): void => {
      const missing: object = JSON.parse(
        '{"data":{"__R":{"0":{"pid":1,"authorid":"10","content":"正文"}},' +
          '"__ROWS":1,"__R__ROWS_PAGE":20}}')
      expect(parseThreadData(missing).rowList[0].hotReplies.length).assertEqual(0)

      const emptyObject: object = JSON.parse(
        '{"data":{"__R":{"0":{"pid":1,"authorid":"10","content":"正文","hotreply":{}}},' +
          '"__ROWS":1,"__R__ROWS_PAGE":20}}')
      expect(parseThreadData(emptyObject).rowList[0].hotReplies.length).assertEqual(0)

      // hotreply 为非对象时安全降级为空数组
      const nonObject: object = JSON.parse(
        '{"data":{"__R":{"0":{"pid":1,"authorid":"10","content":"正文","hotreply":"oops"}},' +
          '"__ROWS":1,"__R__ROWS_PAGE":20}}')
      expect(parseThreadData(nonObject).rowList[0].hotReplies.length).assertEqual(0)
    })

    it('marksBlacklistedHotReplyAuthor', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"__R":{"0":{"pid":100,"authorid":"10","content":"楼主正文",' +
          '"hotreply":{"0":{"pid":201,"authorid":"42","lou":2,"score":268,"content":"热评一"},' +
          '"1":{"pid":202,"authorid":"43","lou":5,"score":82,"content":"热评二"}}}},' +
          '"__ROWS":1,"__R__ROWS_PAGE":20}}')
      const result = parseThreadData(raw, new Set<string>(['42']))
      const hotReplies: ThreadRowInfo[] = result.rowList[0].hotReplies
      expect(hotReplies.length).assertEqual(2)
      expect(hotReplies[0].isInBlackList).assertTrue()
      expect(hotReplies[1].isInBlackList).assertFalse()
    })

    it('filtersHotReplyByKeyword', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"__R":{"0":{"pid":100,"authorid":"10","content":"楼主正文",' +
          '"hotreply":{"0":{"pid":201,"authorid":"42","lou":2,"score":268,"content":"屏蔽词内容"},' +
          '"1":{"pid":202,"authorid":"43","lou":5,"score":82,"content":"正常热评"}}}},' +
          '"__ROWS":1,"__R__ROWS_PAGE":20}}')
      const result = parseThreadData(raw, new Set<string>(), ['屏蔽词'])
      const hotReplies: ThreadRowInfo[] = result.rowList[0].hotReplies
      expect(hotReplies.length).assertEqual(1)
      expect(hotReplies[0].content).assertEqual('正常热评')
    })

    it('defaultsMissingHotReplyFields', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"__R":{"0":{"pid":100,"authorid":"10","content":"楼主正文",' +
          '"hotreply":{"0":{"pid":201,"authorid":"42"}}}},' +
          '"__ROWS":1,"__R__ROWS_PAGE":20}}')
      const hotReplies: ThreadRowInfo[] = parseThreadData(raw).rowList[0].hotReplies
      expect(hotReplies.length).assertEqual(1)
      expect(hotReplies[0].lou).assertEqual(0)
      expect(hotReplies[0].score).assertEqual(0)
      expect(hotReplies[0].content).assertEqual('')
    })
  })

  describe('hotReplyStatePropagation', (): void => {
    it('updatesHotReplyMaskState', 0, (): void => {
      const floor: PostInfo = new PostInfo()
      floor.authorid = 100
      const reply: PostInfo = new PostInfo()
      reply.authorid = 200
      floor.hotReplies = [reply]

      applyBlacklistStateToPosts([floor], new Set<string>(['200']))
      expect(floor.isInBlackList).assertFalse()
      expect(reply.isInBlackList).assertTrue()

      applyBlacklistStateToPosts([floor], new Set<string>())
      expect(reply.isInBlackList).assertFalse()
    })

    it('warmsHotReplyContentUnderBlacklistedFloor', 0, (): void => {
      const floor: PostInfo = new PostInfo()
      floor.content = '被屏蔽楼层正文'
      floor.isInBlackList = true
      const visibleReply: PostInfo = new PostInfo()
      visibleReply.content = '可见热评正文'
      floor.hotReplies = [visibleReply]
      const blockedReply: PostInfo = new PostInfo()
      blockedReply.content = '被屏蔽热评正文'
      blockedReply.isInBlackList = true
      floor.hotReplies.push(blockedReply)

      const contents: string[] = collectPostContents([floor], true)
      expect(contents.length).assertEqual(1)
      expect(contents[0]).assertEqual('可见热评正文')
    })
  })
}
