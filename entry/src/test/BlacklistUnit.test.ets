import { describe, it, expect } from '@ohos/hypium'
import {
  applyBlacklistStateToPosts,
  areBlacklistEntriesEqual,
  normalizeBlacklistEntries,
  normalizeBlacklistUserId
} from '../main/ets/common/utils/BlacklistUtils'
import type { BlacklistEntry } from '../main/ets/model/SocialEntries'
import { PostInfo } from '../main/ets/model/PostInfo'
import { TopicPaginationManager } from '../main/ets/common/managers/TopicPaginationManager'
import { parseTopicList } from '../main/ets/parser/TopicParser'
import { parseThreadData } from '../main/ets/parser/ThreadParser'
import { collectPostContents } from '../main/ets/common/utils/PostWarmup'
import { parseBBCode } from '../main/ets/parser/bbcode/parser'
import { BBNode, BBNodeType } from '../main/ets/model/BBCodeNode'
import {
  isQuoteFromBlacklistedUser,
  splitQuoteChildren
} from '../main/ets/common/components/bbcode/BBCodeRenderContext'

/**
 * 注册黑名单策略单元测试。
 */
export default function blacklistUnitTest(): void {
  describe('blacklistPolicy', (): void => {
    it('normalizesPositiveUserIds', 0, (): void => {
      expect(normalizeBlacklistUserId(' 00123 ')).assertEqual('123')
      expect(normalizeBlacklistUserId('0') === null).assertTrue()
      expect(normalizeBlacklistUserId('-1') === null).assertTrue()
      expect(normalizeBlacklistUserId('abc') === null).assertTrue()
    })

    it('deduplicatesAndExcludesCurrentUser', 0, (): void => {
      const entries: BlacklistEntry[] = [
        { userId: '00123', nickName: 'first' },
        { userId: '123', nickName: 'duplicate' },
        { userId: '456', nickName: 'self' },
        { userId: 'abc', nickName: 'invalid' }
      ]
      const normalized: BlacklistEntry[] = normalizeBlacklistEntries(entries, '456')
      expect(normalized.length).assertEqual(1)
      expect(normalized[0].userId).assertEqual('123')
      expect(normalized[0].nickName).assertEqual('first')
      expect(areBlacklistEntriesEqual(normalized, entries)).assertFalse()
    })

    it('updatesFloorAndCommentMaskState', 0, (): void => {
      const floor: PostInfo = new PostInfo()
      floor.authorid = 100
      const comment: PostInfo = new PostInfo()
      comment.authorid = 200
      floor.comments = [comment]

      applyBlacklistStateToPosts([floor], new Set<string>(['100', '200']))
      expect(floor.isInBlackList).assertTrue()
      expect(comment.isInBlackList).assertTrue()

      applyBlacklistStateToPosts([floor], new Set<string>())
      expect(floor.isInBlackList).assertFalse()
      expect(comment.isInBlackList).assertFalse()
    })

    it('retainsBlacklistedTopicWithMaskState', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"__T":{"0":{"tid":1,"fid":2,"author":"blocked","authorid":"42",' +
          '"subject":"原主题标题"}},"__ROWS":1,"__T__ROWS_PAGE":35,"__F":{"name":"测试版面"}}}')
      const result = parseTopicList(raw, new Set<string>(['42']))
      expect(result.threadPageList.length).assertEqual(1)
      expect(result.threadPageList[0].isInBlackList).assertTrue()
      expect(result.threadPageList[0].subject).assertEqual('原主题标题')
    })

    it('tracksPreviewAuthorIndependentlyFromTopicAuthor', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"__T":{"0":{"tid":1,"fid":2,"author":"topic-author","authorid":"10",' +
          '"subject":"主题标题","__P":{"pid":2,"tid":1,"authorid":"42","content":"回复摘要"}}},' +
          '"__ROWS":1,"__T__ROWS_PAGE":35,"__F":{"name":"测试版面"}}}')
      const result = parseTopicList(raw, new Set<string>(['42']))
      expect(result.threadPageList.length).assertEqual(1)
      expect(result.threadPageList[0].isInBlackList).assertFalse()
      expect(result.threadPageList[0].previewAuthorId).assertEqual('42')
      expect(result.threadPageList[0].previewSnippet).assertEqual('回复摘要')
    })

    it('retainsBlacklistedNestedCommentWithMaskState', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"__R":{"0":{"pid":1,"authorid":"10","content":"楼层正文",' +
          '"comment":{"0":{"pid":2,"authorid":"42","content":"楼中楼正文"}}}},' +
          '"__ROWS":1,"__R__ROWS_PAGE":20}}')
      const result = parseThreadData(raw, new Set<string>(['42']))
      expect(result.rowList.length).assertEqual(1)
      expect(result.rowList[0].comments.length).assertEqual(1)
      expect(result.rowList[0].comments[0].isInBlackList).assertTrue()
      expect(result.rowList[0].comments[0].content).assertEqual('楼中楼正文')
    })

    it('warmsVisibleCommentUnderBlacklistedFloor', 0, (): void => {
      const floor: PostInfo = new PostInfo()
      floor.content = '被屏蔽楼层正文'
      floor.isInBlackList = true
      const visibleComment: PostInfo = new PostInfo()
      visibleComment.content = '可见楼中楼正文'
      floor.comments = [visibleComment]

      const contents: string[] = collectPostContents([floor], true)
      expect(contents.length).assertEqual(1)
      expect(contents[0]).assertEqual('可见楼中楼正文')
    })

    it('recognizesBlacklistedStandardQuoteAuthor', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[quote][pid=1,2,1]Reply[/pid] [b]Post by [uid=42]blocked[/uid] (2026-01-01):[/b]' +
          '引用正文[/quote]')
      expect(nodes.length).assertEqual(1)
      expect(nodes[0].type).assertEqual(BBNodeType.QUOTE)
      expect(splitQuoteChildren(nodes[0].children).sourceAuthorId).assertEqual('42')
      expect(isQuoteFromBlacklistedUser(nodes[0].children, new Set<string>(['42']))).assertTrue()
      expect(isQuoteFromBlacklistedUser(nodes[0].children, new Set<string>())).assertFalse()
    })

    it('recognizesNestedQuoteAuthorIndependently', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[quote][pid=1,2,1]Reply[/pid] [b]Post by [uid=10]visible[/uid] (2026-01-01):[/b]' +
          '外层正文[quote][pid=3,2,1]Reply[/pid] [b]Post by [uid=42]blocked[/uid] ' +
          '(2026-01-01):[/b]内层正文[/quote][/quote]')
      const outerQuote: BBNode = nodes[0]
      const nestedQuote: BBNode = outerQuote.children[2]
      expect(isQuoteFromBlacklistedUser(outerQuote.children, new Set<string>(['42']))).assertFalse()
      expect(nestedQuote.type).assertEqual(BBNodeType.QUOTE)
      expect(isQuoteFromBlacklistedUser(nestedQuote.children, new Set<string>(['42']))).assertTrue()
    })

    it('keepsSourceLessQuoteUnmasked', 0, (): void => {
      const nodes: BBNode[] = parseBBCode('[quote]无来源引用[/quote]')
      expect(splitQuoteChildren(nodes[0].children).sourceAuthorId).assertEqual('')
      expect(isQuoteFromBlacklistedUser(nodes[0].children, new Set<string>(['42']))).assertFalse()
    })

    it('advancesAcrossEmptyPrefetchedTopicPage', 0, (): void => {
      const manager: TopicPaginationManager = new TopicPaginationManager()
      manager.replaceWith([], 1, 3)
      manager.setPrefetchedPage(2, [], 3)
      const added: object[] = manager.commitPrefetchedPage(2)
      expect(added.length).assertEqual(0)
      expect(manager.currentPage).assertEqual(2)
      expect(manager.hasMore).assertTrue()
    })
  })
}
