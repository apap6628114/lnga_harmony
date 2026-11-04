import { describe, it, expect } from '@ohos/hypium'
import {
  buildThreadTree,
  extractPrimaryQuoteRef,
  flattenThreadTree,
  expandRoot,
  findRowIndexByPid,
  findRootPidByPid,
  stripQuoteArea
} from '../main/ets/common/utils/ThreadTreeBuilder'
import {
  ThreadTreeChild,
  ThreadTreeModel,
  ThreadTreeQuoteRef,
  ThreadTreeRoot,
  ThreadTreeRow,
  ThreadTreeRowKind
} from '../main/ets/model/ThreadTree'
import { PostInfo } from '../main/ets/model/PostInfo'

/** 测试用当前帖子 tid。 */
const TID: number = 123456

/** 测试用另一个帖子的 tid（跨帖引用）。 */
const OTHER_TID: number = 43936925

/** 引用块头匹配关键词（构造样本用）。 */
const QUOTE_BODY: string = '被引用的正文内容[/quote]<br/>本层回复正文'

/**
 * 构造测试楼层。
 *
 * @param pid - 楼层 pid
 * @param lou - 楼层号
 * @param content - 楼层正文
 * @returns 测试楼层
 */
function createPost(pid: number, lou: number, content: string): PostInfo {
  const post: PostInfo = new PostInfo()
  post.tid = TID
  post.pid = pid
  post.lou = lou
  post.content = content
  post.author = '作者' + String(pid)
  post.authorid = pid
  return post
}

/**
 * 构造标准引用块头（`[quote][pid=A,tid,C]Reply[/pid] [b]Post by …[/b]`）。
 *
 * @param pid - 被引用楼层 pid
 * @param tid - 被引用楼层所属主题 tid
 * @param page - 被引用楼层页码（C 段）
 * @returns 楼层正文
 */
function quotePidHeader(pid: number, tid: number, page: number): string {
  return '[quote][pid=' + String(pid) + ',' + String(tid) + ',' + String(page)
    + ']Reply[/pid] [b]Post by [uid=1197343]miniyoyo[/uid] (2025-05-26 18:55):[/b]'
    + QUOTE_BODY
}

/**
 * 构造带前导空白与换行的引用块头（验证「引用区可以在前导噪音之后」）。
 *
 * 注意前缀只允许空白/换行：引用区前面出现任何正文文字都说明不是服务端生成的
 * 引用头，不应被识别为回复关系（见 `doesNotExtractHeaderAfterBodyPrefix`）。
 *
 * @param pid - 被引用楼层 pid
 * @param page - 页码
 * @returns 楼层正文
 */
function quotePidHeaderWithPrefix(pid: number, page: number): string {
  return '  <br/>\n  [quote][pid=' + String(pid) + ',' + String(TID) + ',' + String(page)
    + ']Reply[/pid] [b]Post by [uid=1197343]miniyoyo[/uid] (2025-05-26 18:55):[/b]' + QUOTE_BODY
}

/**
 * 构造标准回复头（`[b]Reply to [pid=A,tid,C]Reply[/pid] Post by …[/b]`）。
 *
 * @param pid - 被引用楼层 pid
 * @param tid - 被引用楼层所属主题 tid
 * @param page - 页码
 * @returns 楼层正文
 */
function replyToHeader(pid: number, tid: number, page: number): string {
  return '[b]Reply to [pid=' + String(pid) + ',' + String(tid) + ',' + String(page)
    + ']Reply[/pid] Post by [uid=360579]迷惘中的骑士[/uid] (2025-05-26 17:37)[/b]<br/><br/>本层回复正文'
}

/**
 * 构造主楼引用头（`[quote][tid=T]Topic[/tid] [b]Post by …[/b]`）。
 *
 * @param tid - 主题 tid
 * @returns 楼层正文
 */
function topicRefHeader(tid: number): string {
  return '[quote][tid=' + String(tid)
    + ']Topic[/tid] [b]Post by [uid=10315413]清风拂过的气息[/uid] (2026-10-22 11:12):[/b]'
    + QUOTE_BODY
}

/**
 * 构造「主楼 + 根 A + A 的 N 个直接回复」样本（用于折叠用例）。
 *
 * @param childCount - A 的直接回复数（2..5）
 * @returns 楼层数组（逆序构造，同时验证内部按楼号排序）
 */
function createRootWithChildren(childCount: number): PostInfo[] {
  const posts: PostInfo[] = []
  for (let index: number = childCount; index >= 1; index--) {
    posts.push(createPost(1001 + index, index + 1, quotePidHeader(101, TID, 1)))
  }
  posts.push(createPost(101, 1, '根 A，无引用'))
  posts.push(createPost(0, 0, '主楼正文'))
  return posts
}

/**
 * 取树行的楼层 pid。
 *
 * @param row - 树行
 * @returns 楼层 pid；MORE 行返回 -1
 */
function rowPid(row: ThreadTreeRow): number {
  if (row.post === null) {
    return -1
  }
  return (row.post as PostInfo).pid
}

/**
 * 构造混合场景：主楼 + 无引用根 + 主楼引用根 + 深层引用 + 目标缺失 + 跨帖 + 自引用。
 *
 * @returns 楼层数组（顺序打乱）
 */
function createMixedPosts(): PostInfo[] {
  const posts: PostInfo[] = []
  posts.push(createPost(107, 7, quotePidHeader(107, TID, 1)))
  posts.push(createPost(0, 0, '主楼正文'))
  posts.push(createPost(101, 1, '根 A，无引用'))
  posts.push(createPost(103, 3, quotePidHeader(101, TID, 1)))
  posts.push(createPost(102, 2, topicRefHeader(TID)))
  posts.push(createPost(104, 4, quotePidHeader(103, TID, 3)))
  posts.push(createPost(105, 5, quotePidHeader(999999, TID, 2)))
  posts.push(createPost(106, 6, quotePidHeader(777, OTHER_TID, 2)))
  return posts
}

/**
 * 注册帖子两层递进树构建器单元测试。
 */
export default function threadTreeBuilderUnitTest(): void {
  describe('threadTreeQuoteRef', (): void => {
    it('extractsQuotePidHeader', 0, (): void => {
      const ref: ThreadTreeQuoteRef | null =
        extractPrimaryQuoteRef(quotePidHeader(824931876, TID, 1), TID)
      expect(ref).not().assertNull()
      const quote: ThreadTreeQuoteRef = ref as ThreadTreeQuoteRef
      expect(quote.targetPid).assertEqual(824931876)
      expect(quote.targetPage).assertEqual(1)
      expect(quote.targetUid).assertEqual('1197343')
      expect(quote.targetAuthor).assertEqual('miniyoyo')
      expect(quote.isTopicRef).assertFalse()
      expect(quote.external).assertFalse()
      expect(quote.rawHeader.length <= 200).assertTrue()
    })

    it('extractsReplyToHeader', 0, (): void => {
      const ref: ThreadTreeQuoteRef | null =
        extractPrimaryQuoteRef(replyToHeader(824921217, TID, 2), TID)
      expect(ref).not().assertNull()
      const quote: ThreadTreeQuoteRef = ref as ThreadTreeQuoteRef
      expect(quote.targetPid).assertEqual(824921217)
      expect(quote.targetPage).assertEqual(2)
      expect(quote.targetUid).assertEqual('360579')
      expect(quote.targetAuthor).assertEqual('迷惘中的骑士')
      expect(quote.isTopicRef).assertFalse()
      expect(quote.external).assertFalse()
    })

    it('extractsTopicRefHeader', 0, (): void => {
      const ref: ThreadTreeQuoteRef | null =
        extractPrimaryQuoteRef(topicRefHeader(TID), TID)
      expect(ref).not().assertNull()
      const quote: ThreadTreeQuoteRef = ref as ThreadTreeQuoteRef
      expect(quote.targetPid).assertEqual(0)
      expect(quote.targetPage).assertEqual(-1)
      expect(quote.isTopicRef).assertTrue()
      expect(quote.external).assertFalse()
      expect(quote.targetUid).assertEqual('10315413')
      expect(quote.targetAuthor).assertEqual('清风拂过的气息')
    })

    it('marksOtherTopicIdAsExternal', 0, (): void => {
      const ref: ThreadTreeQuoteRef | null =
        extractPrimaryQuoteRef(topicRefHeader(OTHER_TID), TID)
      expect(ref).not().assertNull()
      const quote: ThreadTreeQuoteRef = ref as ThreadTreeQuoteRef
      expect(quote.external).assertTrue()
      expect(quote.isTopicRef).assertFalse()
      expect(quote.targetPid).assertEqual(0)
    })

    it('marksCrossThreadPidHeaderAsExternal', 0, (): void => {
      const crossRef: ThreadTreeQuoteRef | null =
        extractPrimaryQuoteRef(replyToHeader(820789420, OTHER_TID, 11), TID)
      expect(crossRef).not().assertNull()
      const cross: ThreadTreeQuoteRef = crossRef as ThreadTreeQuoteRef
      expect(cross.targetPid).assertEqual(820789420)
      expect(cross.targetPage).assertEqual(11)
      expect(cross.external).assertTrue()

      const sameRef: ThreadTreeQuoteRef | null =
        extractPrimaryQuoteRef(replyToHeader(820789420, TID, 11), TID)
      expect(sameRef).not().assertNull()
      const same: ThreadTreeQuoteRef = sameRef as ThreadTreeQuoteRef
      expect(same.external).assertFalse()
    })

    it('extractsAnonymousBareUidWithFloorHint', 0, (): void => {
      const content: string = '[quote][pid=833650176,' + String(TID)
        + ',14]Reply[/pid] [b]Post by [uid]#anony_cc3a651d57c626f524cefaa58d94bddd[/uid]'
        + '[color=gray](276楼)[/color] (2025-07-27 22:54):[/b]匿名正文[/quote]<br/>本层回复'
      const ref: ThreadTreeQuoteRef | null = extractPrimaryQuoteRef(content, TID)
      expect(ref).not().assertNull()
      const quote: ThreadTreeQuoteRef = ref as ThreadTreeQuoteRef
      expect(quote.targetUid).assertEqual('#anony_cc3a651d57c626f524cefaa58d94bddd')
      expect(quote.targetAuthor).assertEqual('')
      expect(quote.targetPid).assertEqual(833650176)
      expect(quote.targetPage).assertEqual(14)
      expect(quote.isTopicRef).assertFalse()
    })

    it('extractsAnonymousAttributeUid', 0, (): void => {
      const content: string = '[quote][pid=833170412,' + String(TID)
        + ',2]Reply[/pid] [b]Post by [uid=#anony_2ac8f7558d8d181e2c7095cf9fe85ad8][/uid]'
        + '[color=gray](27楼)[/color] (2025-07-24 09:59):[/b]匿名正文[/quote]<br/>本层回复'
      const ref: ThreadTreeQuoteRef | null = extractPrimaryQuoteRef(content, TID)
      expect(ref).not().assertNull()
      const quote: ThreadTreeQuoteRef = ref as ThreadTreeQuoteRef
      expect(quote.targetUid).assertEqual('#anony_2ac8f7558d8d181e2c7095cf9fe85ad8')
      expect(quote.targetPid).assertEqual(833170412)
    })

    it('extractsFloorHintWithoutColorWrapper', 0, (): void => {
      const content: string = '[quote][pid=833275116,' + String(TID)
        + ',2]Reply[/pid] [b]Post by [uid]#anony_329fb3aec19781f8dee00759e0b20312[/uid]'
        + '(31楼) (2025-07-24 22:21):[/b]匿名正文[/quote]<br/>本层回复'
      const ref: ThreadTreeQuoteRef | null = extractPrimaryQuoteRef(content, TID)
      expect(ref).not().assertNull()
      const quote: ThreadTreeQuoteRef = ref as ThreadTreeQuoteRef
      expect(quote.targetUid).assertEqual('#anony_329fb3aec19781f8dee00759e0b20312')
      expect(quote.targetPid).assertEqual(833275116)
    })

    it('treatsMainFloorSentinelPidZeroAsTopicRef', 0, (): void => {
      const content: string = '[quote][pid=0,' + String(TID)
        + ',1]Reply[/pid] [b]Post by [uid=205511]gerraerd[/uid] (2025-05-26 17:27):[/b]'
        + QUOTE_BODY
      const ref: ThreadTreeQuoteRef | null = extractPrimaryQuoteRef(content, TID)
      expect(ref).not().assertNull()
      const quote: ThreadTreeQuoteRef = ref as ThreadTreeQuoteRef
      expect(quote.targetPid).assertEqual(0)
      expect(quote.isTopicRef).assertTrue()
      expect(quote.external).assertFalse()
    })

    it('prefersEarliestHeader', 0, (): void => {
      const bothKinds: string = replyToHeader(333, TID, 1) + '<br/>' + quotePidHeader(111, TID, 1)
      const firstRef: ThreadTreeQuoteRef | null = extractPrimaryQuoteRef(bothKinds, TID)
      expect(firstRef).not().assertNull()
      const first: ThreadTreeQuoteRef = firstRef as ThreadTreeQuoteRef
      expect(first.targetPid).assertEqual(333)

      const twoQuotes: string = quotePidHeader(111, TID, 1) + '<br/>' + quotePidHeader(222, TID, 2)
      const secondRef: ThreadTreeQuoteRef | null = extractPrimaryQuoteRef(twoQuotes, TID)
      expect(secondRef).not().assertNull()
      const second: ThreadTreeQuoteRef = secondRef as ThreadTreeQuoteRef
      expect(second.targetPid).assertEqual(111)
    })

    it('findsHeaderAfterLeadingWhitespace', 0, (): void => {
      const ref: ThreadTreeQuoteRef | null = extractPrimaryQuoteRef(quotePidHeaderWithPrefix(555, 3), TID)
      expect(ref).not().assertNull()
      const quote: ThreadTreeQuoteRef = ref as ThreadTreeQuoteRef
      expect(quote.targetPid).assertEqual(555)
      expect(quote.targetPage).assertEqual(3)
    })

    it('doesNotExtractHeaderAfterBodyPrefix', 0, (): void => {
      /** 引用头前面已经有正文文字：这层楼的引用样式属于用户正文，不是服务端回复头 */
      const content: string = '前缀文字<br/>\n  [quote][pid=555,' + String(TID)
        + ',3]Reply[/pid] [b]Post by [uid=1]甲[/uid] (2025-01-01):[/b]被引正文[/quote]'
      expect(extractPrimaryQuoteRef(content, TID)).assertNull()
    })

    it('doesNotExtractHeaderInMidBody', 0, (): void => {
      /** 正文中部复制的引用样式：不构成回复关系 */
      const content: string = '正文开头' + quotePidHeader(111, TID, 1) + '结尾'
      expect(extractPrimaryQuoteRef(content, TID)).assertNull()
    })

    it('doesNotExtractPlainQuoteWithoutLinkHeader', 0, (): void => {
      /** 用户把 [quote] 当排版容器（无 pid/tid 链接头） */
      expect(extractPrimaryQuoteRef('[quote]用户排版引用[/quote]<br/>正文', TID)).assertNull()
      /** 链接头出现在块中部（块首是用户正文）：同样不是服务端引用块 */
      const midLink: string = '[quote]用户正文 [pid=111,' + String(TID)
        + ',1]Reply[/pid] [b]Post by [uid=1]甲[/uid] (2025-01-01):[/b][/quote]'
      expect(extractPrimaryQuoteRef(midLink, TID)).assertNull()
    })

    it('returnsNullWithoutValidHeader', 0, (): void => {
      expect(extractPrimaryQuoteRef('', TID)).assertNull()
      expect(extractPrimaryQuoteRef('普通正文，没有任何引用', TID)).assertNull()
      expect(extractPrimaryQuoteRef('[quote]@echo off<br/>&gt;nul 2&gt;&amp;1[/quote]', TID)).assertNull()
    })

    it('handlesPidHeaderWithoutPagePart', 0, (): void => {
      const content: string = '[quote][pid=123]Reply[/pid] [b]Post by [uid=42]某人[/uid] (2025-01-01):[/b]'
        + QUOTE_BODY
      const ref: ThreadTreeQuoteRef | null = extractPrimaryQuoteRef(content, TID)
      expect(ref).not().assertNull()
      const quote: ThreadTreeQuoteRef = ref as ThreadTreeQuoteRef
      expect(quote.targetPid).assertEqual(123)
      expect(quote.targetPage).assertEqual(-1)
      expect(quote.external).assertFalse()
    })

    it('extractsUnclosedReplyToHeaderWithoutStripping', 0, (): void => {
      /** 回复头缺少[/b]：关系仍要提取，但不能把后面的正文当引用区剥掉 */
      const content: string = '[b]Reply to [pid=777,' + String(TID)
        + ',2]Reply[/pid] Post by [uid=1]甲[/uid] (2025-01-01 00:00)<br/>正文'
      const ref: ThreadTreeQuoteRef | null = extractPrimaryQuoteRef(content, TID)
      expect(ref).not().assertNull()
      expect((ref as ThreadTreeQuoteRef).targetPid).assertEqual(777)
      expect(stripQuoteArea(content)).assertEqual(content)
    })

    it('extractsReplyToTopicHeader', 0, (): void => {
      /** 回复楼主：`[b]Reply to [tid=T]Topic[/tid]`（真实数据存在，不能只认 pid 形态） */
      const content: string = '[b]Reply to [tid=' + String(TID)
        + ']Topic[/tid] Post by [uid=1132502]dawn28[/uid] (2026-08-10 13:02)[/b]<br/><br/>希望高通赢'
      const ref: ThreadTreeQuoteRef | null = extractPrimaryQuoteRef(content, TID)
      expect(ref).not().assertNull()
      const quote: ThreadTreeQuoteRef = ref as ThreadTreeQuoteRef
      expect(quote.targetPid).assertEqual(0)
      expect(quote.isTopicRef).assertTrue()
      expect(quote.external).assertFalse()
      expect(quote.targetUid).assertEqual('1132502')
      expect(quote.targetAuthor).assertEqual('dawn28')
      expect(stripQuoteArea(content)).assertEqual('希望高通赢')
    })

    it('doesNotStripWhenReplyHeaderCloseBelongsToBodyBold', 0, (): void => {
      /** 头缺[/b]时不能把正文里 [b]…[/b] 的闭合当成头部结束 */
      const content: string = '[b]Reply to [pid=778,' + String(TID)
        + ',2]Reply[/pid] Post by [uid=1]甲[/uid] (2025-01-01 00:00) 正文开始 [b]加粗强调内容[/b] 结尾正文'
      const ref: ThreadTreeQuoteRef | null = extractPrimaryQuoteRef(content, TID)
      expect(ref).not().assertNull()
      expect(stripQuoteArea(content)).assertEqual(content)
    })

    it('extractsQuoteBlockAfterLeadingLineBreaks', 0, (): void => {
      const content: string = '[quote]<br/>[pid=444,' + String(TID)
        + ',1]Reply[/pid] [b]Post by [uid=9]乙[/uid] (2025-01-01):[/b]被引正文[/quote]<br/>本层正文'
      const ref: ThreadTreeQuoteRef | null = extractPrimaryQuoteRef(content, TID)
      expect(ref).not().assertNull()
      expect((ref as ThreadTreeQuoteRef).targetPid).assertEqual(444)
      expect(stripQuoteArea(content)).assertEqual('本层正文')
    })

    it('parsesAuthorFromHeaderNotQuotedBody', 0, (): void => {
      /** 作者只从头部解析，被引正文里的 [uid] 提及不能顶替作者 */
      const content: string = '[quote][pid=557,' + String(TID)
        + ',1]Reply[/pid] [b]Post by [uid=2]丙[/uid] (2025-01-01):[/b]'
        + '正文里提到 [uid=999]别人[/uid][/quote]<br/>本层正文'
      const ref: ThreadTreeQuoteRef | null = extractPrimaryQuoteRef(content, TID)
      expect(ref).not().assertNull()
      expect((ref as ThreadTreeQuoteRef).targetUid).assertEqual('2')
      expect((ref as ThreadTreeQuoteRef).targetAuthor).assertEqual('丙')
    })
  })

  describe('threadTreeBuild', (): void => {
    it('buildsTwoLayerTreeWithRootsAndFlatDescendants', 0, (): void => {
      const model: ThreadTreeModel = buildThreadTree(createMixedPosts(), 3)
      expect(model.totalPosts).assertEqual(8)
      expect(model.totalPages).assertEqual(3)
      expect(model.mainPid).assertEqual(0)
      expect(model.roots.length).assertEqual(6)

      const mainRoot: ThreadTreeRoot = model.roots[0]
      expect(mainRoot.post.lou).assertEqual(0)
      expect(mainRoot.children.length).assertEqual(0)

      const rootA: ThreadTreeRoot = model.roots[1]
      expect(rootA.post.pid).assertEqual(101)
      expect(rootA.children.length).assertEqual(2)
      const childC: ThreadTreeChild = rootA.children[0]
      expect(childC.post.pid).assertEqual(103)
      expect(childC.parentPid).assertEqual(101)
      const childD: ThreadTreeChild = rootA.children[1]
      expect(childD.post.pid).assertEqual(104)
      expect(childD.parentPid).assertEqual(103)

      expect(model.rootPidOfPid.get(103)).assertEqual(101)
      expect(model.rootPidOfPid.get(104)).assertEqual(101)
      expect(model.quoteCount).assertEqual(6)
      expect(model.postByPid.get(104) !== undefined).assertTrue()
    })

    it('treatsTopicExternalMissingAndSelfRefsAsRoots', 0, (): void => {
      const model: ThreadTreeModel = buildThreadTree(createMixedPosts(), 1)
      const rootPids: number[] = []
      for (let i: number = 0; i < model.roots.length; i++) {
        rootPids.push(model.roots[i].post.pid)
      }
      expect(rootPids.indexOf(102) >= 0).assertTrue()
      expect(rootPids.indexOf(105) >= 0).assertTrue()
      expect(rootPids.indexOf(106) >= 0).assertTrue()
      expect(rootPids.indexOf(107) >= 0).assertTrue()

      const topicRoot: ThreadTreeRoot = model.roots[rootPids.indexOf(102)]
      expect(topicRoot.ref !== null).assertTrue()
      const topicRef: ThreadTreeQuoteRef = topicRoot.ref as ThreadTreeQuoteRef
      expect(topicRef.isTopicRef).assertTrue()

      const externalRoot: ThreadTreeRoot = model.roots[rootPids.indexOf(106)]
      const externalRef: ThreadTreeQuoteRef = externalRoot.ref as ThreadTreeQuoteRef
      expect(externalRef.external).assertTrue()

      const selfRoot: ThreadTreeRoot = model.roots[rootPids.indexOf(107)]
      expect(selfRoot.children.length).assertEqual(0)
      const selfRef: ThreadTreeQuoteRef = selfRoot.ref as ThreadTreeQuoteRef
      expect(selfRef.targetPid).assertEqual(107)
    })

    it('treatsRefToNonZeroMainPidAsRoot', 0, (): void => {
      const main: PostInfo = createPost(500, 0, '主楼正文')
      const replyToMain: PostInfo = createPost(501, 1, quotePidHeader(500, TID, 1))
      const replyToReply: PostInfo = createPost(502, 2, quotePidHeader(501, TID, 2))
      const model: ThreadTreeModel = buildThreadTree([replyToReply, main, replyToMain], 1)

      expect(model.mainPid).assertEqual(500)
      expect(model.roots.length).assertEqual(2)
      expect(model.roots[0].post.pid).assertEqual(500)
      expect(model.roots[1].post.pid).assertEqual(501)
      expect(model.roots[1].children.length).assertEqual(1)
      expect(model.roots[1].children[0].post.pid).assertEqual(502)
      expect(model.roots[1].children[0].parentPid).assertEqual(501)
    })

    it('treatsLaterTargetAsRoot', 0, (): void => {
      const laterFloor: PostInfo = createPost(205, 5, '后面楼层')
      const earlierFloor: PostInfo = createPost(202, 2, quotePidHeader(205, TID, 1))
      const model: ThreadTreeModel = buildThreadTree([laterFloor, earlierFloor], 1)
      expect(model.roots.length).assertEqual(2)
      expect(model.rootPidOfPid.get(202)).assertEqual(202)
      expect(model.roots[0].post.pid).assertEqual(202)
      expect(model.roots[1].post.pid).assertEqual(205)
    })

    it('keepsAllFloorsWhenFloorsReferenceEachOther', 0, (): void => {
      const postA: PostInfo = createPost(202, 2, quotePidHeader(205, TID, 1))
      const postB: PostInfo = createPost(205, 5, quotePidHeader(202, TID, 2))
      const model: ThreadTreeModel = buildThreadTree([postA, postB], 1)
      expect(model.roots.length).assertEqual(1)
      expect(model.roots[0].post.pid).assertEqual(202)
      expect(model.roots[0].children.length).assertEqual(1)
      expect(model.roots[0].children[0].post.pid).assertEqual(205)
      expect(model.roots[0].children[0].parentPid).assertEqual(202)
      expect(findRootPidByPid(model, 205)).assertEqual(202)
      expect(model.rows.length).assertEqual(2)
    })

    it('keepsEveryFloorExactlyOnce', 0, (): void => {
      const model: ThreadTreeModel = buildThreadTree(createMixedPosts(), 1)
      let nodeCount: number = 0
      for (let i: number = 0; i < model.roots.length; i++) {
        nodeCount++
        nodeCount += model.roots[i].children.length
      }
      expect(nodeCount).assertEqual(8)
      expect(model.roots[0].children.length).assertEqual(0)
    })

    it('sortsRootsByFloorNumberAscending', 0, (): void => {
      const model: ThreadTreeModel =
        buildThreadTree([createPost(300, 3, ''), createPost(200, 2, ''), createPost(100, 1, '')], 1)
      expect(model.roots.length).assertEqual(3)
      expect(model.roots[0].post.pid).assertEqual(100)
      expect(model.roots[1].post.pid).assertEqual(200)
      expect(model.roots[2].post.pid).assertEqual(300)
    })

    it('returnsEmptyModelForEmptyInput', 0, (): void => {
      const model: ThreadTreeModel = buildThreadTree([], 5)
      expect(model.totalPosts).assertEqual(0)
      expect(model.roots.length).assertEqual(0)
      expect(model.rows.length).assertEqual(0)
      expect(model.totalPages).assertEqual(5)
      expect(model.pageByPid.size).assertEqual(0)
    })

    it('keepsUserWrittenQuoteAreaAsBodyAndRoot', 0, (): void => {
      const main: PostInfo = createPost(0, 0, '主楼正文')
      const userQuote: PostInfo = createPost(101, 1, '[quote]用户排版内容[/quote]<br/>本层正文')
      const midLink: PostInfo = createPost(102, 2, '正文前缀' + quotePidHeader(101, TID, 1))
      const model: ThreadTreeModel = buildThreadTree([userQuote, main, midLink], 1)
      /** 两楼都不构成引用关系（引用样式不在正文开头）→ 都是根，且正文不被剥离 */
      expect(model.quoteCount).assertEqual(0)
      expect(model.roots.length).assertEqual(3)
      const firstRoot: ThreadTreeRoot = model.roots[1]
      expect(firstRoot.post.pid).assertEqual(101)
      expect(firstRoot.displayContent).assertEqual('[quote]用户排版内容[/quote]<br/>本层正文')
      const secondRoot: ThreadTreeRoot = model.roots[2]
      expect(secondRoot.post.pid).assertEqual(102)
      expect(secondRoot.displayContent).assertEqual('正文前缀' + quotePidHeader(101, TID, 1))
    })
  })

  describe('threadTreeFlatten', (): void => {
    it('showsAllChildrenWhenCountIsThree', 0, (): void => {
      const model: ThreadTreeModel = buildThreadTree(createRootWithChildren(3), 1)
      expect(model.rows.length).assertEqual(5)
      for (let i: number = 0; i < model.rows.length; i++) {
        expect(model.rows[i].kind === ThreadTreeRowKind.MORE).assertFalse()
      }
      let childRows: number = 0
      for (let i: number = 0; i < model.rows.length; i++) {
        if (model.rows[i].kind === ThreadTreeRowKind.CHILD) {
          childRows++
        }
      }
      expect(childRows).assertEqual(3)
    })

    it('foldsToTwoVisibleChildrenAndMoreRowWhenCountIsFour', 0, (): void => {
      const model: ThreadTreeModel = buildThreadTree(createRootWithChildren(4), 1)
      expect(model.rows.length).assertEqual(5)
      expect(model.rows[0].kind).assertEqual(ThreadTreeRowKind.ROOT)
      expect(model.rows[0].post !== null).assertTrue()
      expect(model.rows[1].kind).assertEqual(ThreadTreeRowKind.ROOT)
      expect(model.rows[2].kind).assertEqual(ThreadTreeRowKind.CHILD)
      expect(model.rows[2].childIndex).assertEqual(0)
      expect(model.rows[2].rootPid).assertEqual(101)
      expect(model.rows[3].kind).assertEqual(ThreadTreeRowKind.CHILD)
      expect(model.rows[3].childIndex).assertEqual(1)
      expect(model.rows[4].kind).assertEqual(ThreadTreeRowKind.MORE)
      expect(model.rows[4].post === null).assertTrue()
      expect(model.rows[4].rootPid).assertEqual(101)
      expect(model.rows[4].totalCount).assertEqual(4)
      expect(model.rows[4].hiddenCount).assertEqual(2)
      expect(model.rows[4].childIndex).assertEqual(-1)
    })

    it('expandsRootAndRebuildsAllRows', 0, (): void => {
      const model: ThreadTreeModel = buildThreadTree(createRootWithChildren(4), 1)
      expect(findRowIndexByPid(model.rows, 1005)).assertEqual(-1)
      expect(rowPid(model.rows[2])).assertEqual(1002)

      const expanded: boolean = expandRoot(model, 101)
      expect(expanded).assertTrue()
      flattenThreadTree(model)
      expect(model.rows.length).assertEqual(6)
      for (let i: number = 0; i < model.rows.length; i++) {
        expect(model.rows[i].kind === ThreadTreeRowKind.MORE).assertFalse()
      }
      expect(findRowIndexByPid(model.rows, 1005)).assertEqual(5)
      expect(findRowIndexByPid(model.rows, 1002)).assertEqual(2)
      expect(expandRoot(model, 101)).assertFalse()
    })

    it('doesNotExpandMainRootOrUnknownRoot', 0, (): void => {
      const model: ThreadTreeModel = buildThreadTree(createRootWithChildren(4), 1)
      expect(expandRoot(model, 0)).assertFalse()
      expect(expandRoot(model, 987654)).assertFalse()
    })

    it('keepsUnchangedRowPidsStableAcrossExpand', 0, (): void => {
      const model: ThreadTreeModel = buildThreadTree(createRootWithChildren(4), 1)
      const rootRowBefore: ThreadTreeRow = model.rows[1]
      const rootPidBefore: number = rowPid(rootRowBefore)
      expect(rootPidBefore).assertEqual(101)
      expect(rootRowBefore.rev).assertEqual(0)

      expandRoot(model, 101)
      flattenThreadTree(model)
      const rootRowAfter: ThreadTreeRow = model.rows[1]
      expect(rowPid(rootRowAfter)).assertEqual(rootPidBefore)
      expect(rootRowAfter.rev).assertEqual(1)

      const mainRow: ThreadTreeRow = model.rows[0]
      expect(mainRow.kind).assertEqual(ThreadTreeRowKind.ROOT)
      expect(findRowIndexByPid(model.rows, 0)).assertEqual(0)
    })
  })

  describe('threadTreeLookup', (): void => {
    it('findsRootPidForRootAndChild', 0, (): void => {
      const model: ThreadTreeModel = buildThreadTree(createMixedPosts(), 1)
      expect(findRootPidByPid(model, 104)).assertEqual(101)
      expect(findRootPidByPid(model, 101)).assertEqual(101)
      expect(findRootPidByPid(model, 0)).assertEqual(0)
      expect(findRootPidByPid(model, 102)).assertEqual(102)
      expect(findRootPidByPid(model, 987654)).assertEqual(-1)
    })

    it('findsRowIndexByPid', 0, (): void => {
      const model: ThreadTreeModel = buildThreadTree(createMixedPosts(), 1)
      expect(findRowIndexByPid(model.rows, 0)).assertEqual(0)
      expect(findRowIndexByPid(model.rows, 101)).assertEqual(1)
      expect(findRowIndexByPid(model.rows, 987654)).assertEqual(-1)
    })
  })

  describe('threadTreeStripQuote', (): void => {
    it('stripsLeadingQuoteBlockAndKeepsBody', 0, (): void => {
      const content: string = '[quote][pid=101,123456,1]Reply[/pid] [b]Post by [uid=1]甲[/uid]'
        + ' (2026-01-01 00:00):[/b]被引用正文[/quote]<br/><br/>本层正文'
      expect(stripQuoteArea(content)).assertEqual('本层正文')
    })

    it('stripsLeadingReplyToHeader', 0, (): void => {
      const content: string = '[b]Reply to [pid=101,123456,1]Reply[/pid] Post by [uid=1]甲[/uid]'
        + ' (2026-01-01 00:00)[/b]<br/><br/>本层正文'
      expect(stripQuoteArea(content)).assertEqual('本层正文')
    })

    it('stripsNestedServiceQuoteBlockByBalancedScan', 0, (): void => {
      /** 服务端引用块内层出现嵌套 [quote]（防御异常数据）：按深度平衡剥到最外层闭合 */
      const content: string = '[quote][pid=101,' + String(TID)
        + ',1]Reply[/pid] [b]Post by [uid=1]甲[/uid] (2026-01-01):[/b][quote]内层[/quote]外层[/quote]<br/>正文'
      expect(stripQuoteArea(content)).assertEqual('正文')
    })

    it('keepsUserWrittenNestedQuote', 0, (): void => {
      /** 没有链接头的嵌套 [quote] 是用户排版内容，不能被当成引用区剥掉 */
      const content: string = '[quote][quote]内层引用[/quote]外层引用[/quote]<br/>正文'
      expect(stripQuoteArea(content)).assertEqual(content)
      expect(extractPrimaryQuoteRef(content, TID)).assertNull()
    })

    it('stripsServiceQuoteBlockAndKeepsUserQuoteAfterIt', 0, (): void => {
      const content: string = quotePidHeader(111, TID, 1) + '<br/>'
        + '[quote]用户自己补充的引用样式[/quote]'
      expect(stripQuoteArea(content)).assertEqual('本层回复正文<br/>[quote]用户自己补充的引用样式[/quote]')
      const ref: ThreadTreeQuoteRef | null = extractPrimaryQuoteRef(content, TID)
      expect(ref).not().assertNull()
      expect((ref as ThreadTreeQuoteRef).targetPid).assertEqual(111)
    })

    it('keepsUserWrittenQuoteArea', 0, (): void => {
      const content: string = '[quote]用户自己写的引用样式[/quote]<br/>正文'
      expect(stripQuoteArea(content)).assertEqual(content)
      expect(extractPrimaryQuoteRef(content, TID)).assertNull()
    })

    it('stripsTopicQuoteBlock', 0, (): void => {
      expect(stripQuoteArea(topicRefHeader(TID))).assertEqual('本层回复正文')
    })

    it('stripsOnlyFirstServiceQuoteBlock', 0, (): void => {
      /** 连续两个服务端引用块：只剥第一个，第二个属于用户拼接的正文 */
      const content: string = quotePidHeader(111, TID, 1) + '<br/>' + quotePidHeader(222, TID, 2)
      const ref: ThreadTreeQuoteRef | null = extractPrimaryQuoteRef(content, TID)
      expect(ref).not().assertNull()
      expect((ref as ThreadTreeQuoteRef).targetPid).assertEqual(111)
      const stripped: string = stripQuoteArea(content)
      expect(stripped.indexOf('[quote][pid=222') >= 0).assertTrue()
    })

    it('extractsUnclosedQuoteBlockWithoutStripping', 0, (): void => {
      /** 引用块未闭合：关系仍提取，但不剥离（无法确定块的结束位置） */
      const content: string = '[quote][pid=445,' + String(TID)
        + ',1]Reply[/pid] [b]Post by [uid=9]乙[/uid] (2025-01-01):[/b]没有闭合的正文'
      const ref: ThreadTreeQuoteRef | null = extractPrimaryQuoteRef(content, TID)
      expect(ref).not().assertNull()
      expect((ref as ThreadTreeQuoteRef).targetPid).assertEqual(445)
      expect(stripQuoteArea(content)).assertEqual(content)
    })

    it('stripsLongQuoteBlockLinearly', 0, (): void => {
      /** 长引用块（约 8K 字符）必须正确且线性完成，防止平衡扫描退化为 O(n²) */
      let longBody: string = ''
      for (let i: number = 0; i < 2000; i++) {
        longBody += '被引正文'
      }
      const content: string = '[quote][pid=556,' + String(TID)
        + ',1]Reply[/pid] [b]Post by [uid=2]丙[/uid] (2025-01-01):[/b]' + longBody + '[/quote]<br/>本层正文'
      expect(stripQuoteArea(content)).assertEqual('本层正文')
    })

    it('keepsMidBodyQuoteUntouched', 0, (): void => {
      const content: string = '正文开头[quote]用户自己写的字面标签[/quote]结尾'
      expect(stripQuoteArea(content)).assertEqual(content)
    })

    it('returnsEmptyWhenOnlyQuoteRemains', 0, (): void => {
      const content: string = '[quote][pid=101,123456,1]Reply[/pid] 只有引用[/quote]'
      expect(stripQuoteArea(content)).assertEqual('')
    })

    it('keepsPlainContentUnchanged', 0, (): void => {
      const content: string = '普通正文<br/>第二行'
      expect(stripQuoteArea(content)).assertEqual(content)
    })
  })
}
