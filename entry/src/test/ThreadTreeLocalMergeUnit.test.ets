import { describe, it, expect } from '@ohos/hypium'
import {
  mergeTreePage,
  LocalMergeResult,
  MergePageDecision,
  resolveMergePage
} from '../main/ets/common/utils/ThreadTreeLocalMerge'
import { PostInfo } from '../main/ets/model/PostInfo'
import { buildThreadTree } from '../main/ets/common/utils/ThreadTreeBuilder'
import { computeTreeRowDiff, RowDiffResult } from '../main/ets/common/utils/ThreadTreeRowDiff'
import { ThreadTreeModel, ThreadTreeRow } from '../main/ets/model/ThreadTree'

/**
 * 构造一个楼层。
 *
 * @param pid - 楼层 pid
 * @param lou - 楼层号
 * @param content - 正文
 * @returns 楼层对象
 */
function createPost(pid: number, lou: number, content: string): PostInfo {
  const post: PostInfo = new PostInfo()
  post.pid = pid
  post.lou = lou
  post.content = content
  post.authorid = 1000
  post.author = 'u' + String(pid)
  return post
}

/**
 * 取楼层数组里的 pid 序列（断言顺序用）。
 *
 * @param posts - 楼层数组
 * @returns pid 序列
 */
function pidsOf(posts: PostInfo[]): number[] {
  const pids: number[] = []
  for (let i: number = 0; i < posts.length; i++) {
    pids.push(posts[i].pid)
  }
  return pids
}

/**
 * 取指定 pid 的正文。
 *
 * @param posts - 楼层数组
 * @param pid - 目标 pid
 * @returns 正文；未找到返回空串
 */
function contentOf(posts: PostInfo[], pid: number): string {
  for (let i: number = 0; i < posts.length; i++) {
    if (posts[i].pid === pid) {
      return posts[i].content
    }
  }
  return ''
}

/**
 * 构造一个带服务端引用头的楼层（树构建靠 `[quote][pid=..]` 解析父节点）。
 *
 * @param pid - 楼层 pid
 * @param lou - 楼层号
 * @param targetPid - 被引用楼层 pid
 * @param body - 正文
 * @returns 楼层对象
 */
function createQuotedPost(pid: number, lou: number, targetPid: number, body: string): PostInfo {
  const post: PostInfo = createPost(pid, lou, '')
  post.tid = 100
  post.content = '[quote][pid=' + String(targetPid) + ',100,1]Reply[/pid] ' +
    '[b]Post by [uid=1]u[/uid] (2026-11-08 06:00):[/b]parent[/quote]<br/><br/>' + body
  return post
}

/**
 * 构造主楼（`lou === 0`，树的第一行）。
 *
 * @param pid - 主楼 pid
 * @returns 楼层对象
 */
function createMainPost(pid: number): PostInfo {
  const post: PostInfo = createPost(pid, 0, 'main-body')
  post.tid = 100
  return post
}

/**
 * 行键（与页面 `rowKey` 同构：`kind_pid_rev(highlighted?'_h':'')`）。
 *
 * @param row - 树行
 * @returns 键值
 */
function rowKeyOf(row: ThreadTreeRow): string {
  const pid: number = row.post !== null ? row.post.pid : row.rootPid
  const highlight: string = row.highlighted ? '_h' : ''
  return String(row.kind) + '_' + String(pid) + '_' + String(row.rev) + highlight
}

/**
 * 注册递进树「单页局部合并」的回归测试。
 */
export default function threadTreeLocalMergeTest(): void {
  describe('ThreadTreeLocalMerge', (): void => {
    it('mergeTreePage_emptyBaseAppendsWholePage', 0, (): void => {
      const page: PostInfo[] = [createPost(11, 1, 'a'), createPost(12, 2, 'b')]
      const merged: LocalMergeResult = mergeTreePage([], page, 0, '')
      expect(pidsOf(merged.posts)).assertDeepEquals([11, 12])
      expect(merged.addedPids.length).assertEqual(2)
      expect(merged.replacedPids.length).assertEqual(0)
    })

    it('mergeTreePage_samePidReplacedWithoutAdding', 0, (): void => {
      const current: PostInfo[] = [createPost(1, 0, 'main'), createPost(2, 1, 'old')]
      const page: PostInfo[] = [createPost(2, 1, 'new')]
      const merged: LocalMergeResult = mergeTreePage(current, page, 0, '')
      expect(pidsOf(merged.posts)).assertDeepEquals([1, 2])
      expect(contentOf(merged.posts, 2)).assertEqual('new')
      expect(merged.replacedPids.length).assertEqual(1)
      expect(merged.addedPids.length).assertEqual(0)
    })

    it('mergeTreePage_editKeepsLocalBodyWhenServerReturnsStale', 0, (): void => {
      const current: PostInfo[] = [createPost(2, 1, 'edited-by-local')]
      const page: PostInfo[] = [createPost(2, 1, 'stale-from-cdn')]
      const merged: LocalMergeResult = mergeTreePage(current, page, 2, 'edited-by-local')
      expect(contentOf(merged.posts, 2)).assertEqual('edited-by-local')
    })

    it('mergeTreePage_editTakesServerBodyWhenMatched', 0, (): void => {
      const current: PostInfo[] = [createPost(2, 1, 'old')]
      const page: PostInfo[] = [createPost(2, 1, 'same')]
      const merged: LocalMergeResult = mergeTreePage(current, page, 2, 'same')
      expect(contentOf(merged.posts, 2)).assertEqual('same')
    })

    it('mergeTreePage_guardOnlyAppliesToTargetPid', 0, (): void => {
      const current: PostInfo[] = [createPost(3, 2, 'peer')]
      const page: PostInfo[] = [createPost(3, 2, 'peer-new')]
      const merged: LocalMergeResult = mergeTreePage(current, page, 2, 'guard-body')
      expect(contentOf(merged.posts, 3)).assertEqual('peer-new')
    })

    it('mergeTreePage_keepsOldOrderAndAppendsNewTail', 0, (): void => {
      const current: PostInfo[] = [createPost(1, 0, 'm'), createPost(2, 1, 'a')]
      const page: PostInfo[] = [createPost(2, 1, 'a2'), createPost(3, 2, 'b')]
      const merged: LocalMergeResult = mergeTreePage(current, page, 0, '')
      expect(pidsOf(merged.posts)).assertDeepEquals([1, 2, 3])
      expect(merged.addedPids.length).assertEqual(1)
      expect(merged.addedPids[0]).assertEqual(3)
      expect(merged.replacedPids.length).assertEqual(1)
      expect(merged.replacedPids[0]).assertEqual(2)
    })

    it('mergeTreePage_neverDeletesMissingPosts', 0, (): void => {
      const current: PostInfo[] = [createPost(1, 0, 'm'), createPost(2, 1, 'a'), createPost(3, 2, 'b')]
      const page: PostInfo[] = [createPost(3, 2, 'b2')]
      const merged: LocalMergeResult = mergeTreePage(current, page, 0, '')
      expect(merged.posts.length).assertEqual(3)
      expect(pidsOf(merged.posts)).assertDeepEquals([1, 2, 3])
    })

    it('mergeTreePage_duplicatePidInPageKeepsFirst', 0, (): void => {
      const page: PostInfo[] = [createPost(5, 1, 'first'), createPost(5, 1, 'second')]
      const merged: LocalMergeResult = mergeTreePage([], page, 0, '')
      expect(merged.posts.length).assertEqual(1)
      expect(contentOf(merged.posts, 5)).assertEqual('first')
    })

    it('mergeTreePage_duplicatePidInBaseDeduplicated', 0, (): void => {
      const current: PostInfo[] = [createPost(1, 0, 'm'), createPost(1, 0, 'dup')]
      const merged: LocalMergeResult = mergeTreePage(current, [], 0, '')
      expect(merged.posts.length).assertEqual(1)
    })

    it('mergeTreePage_samePageTwiceIsIdempotent', 0, (): void => {
      const current: PostInfo[] = [createPost(1, 0, 'm')]
      const page: PostInfo[] = [createPost(2, 1, 'a'), createPost(3, 2, 'b')]
      const first: LocalMergeResult = mergeTreePage(current, page, 0, '')
      const second: LocalMergeResult = mergeTreePage(first.posts, page, 0, '')
      expect(pidsOf(second.posts)).assertDeepEquals([1, 2, 3])
      expect(second.addedPids.length).assertEqual(0)
      expect(second.replacedPids.length).assertEqual(2)
    })

    it('contains_coversAddedAndReplaced', 0, (): void => {
      const current: PostInfo[] = [createPost(2, 1, 'old')]
      const page: PostInfo[] = [createPost(2, 1, 'new'), createPost(3, 2, 'x')]
      const merged: LocalMergeResult = mergeTreePage(current, page, 0, '')
      expect(merged.contains(2)).assertTrue()
      expect(merged.contains(3)).assertTrue()
      expect(merged.contains(99)).assertFalse()
    })

    it('mergeTreePage_guardDoesNotMutateServerObjects', 0, (): void => {
      const page: PostInfo[] = [createPost(2, 1, 'stale')]
      const merged: LocalMergeResult = mergeTreePage([], page, 2, 'fresh')
      expect(contentOf(merged.posts, 2)).assertEqual('fresh')
      expect(page[0].content).assertEqual('stale')
    })

    it('mergeTreePage_doesNotMutateBaseArray', 0, (): void => {
      const current: PostInfo[] = [createPost(1, 0, 'm')]
      const page: PostInfo[] = [createPost(2, 1, 'a')]
      const merged: LocalMergeResult = mergeTreePage(current, page, 0, '')
      expect(current.length).assertEqual(1)
      expect(page.length).assertEqual(1)
      expect(merged.posts.length).assertEqual(2)
    })

    it('mergeTreePage_zeroGuardNeverProtects', 0, (): void => {
      const current: PostInfo[] = [createPost(2, 1, 'old')]
      const page: PostInfo[] = [createPost(2, 1, 'server')]
      const merged: LocalMergeResult = mergeTreePage(current, page, 0, 'local')
      expect(contentOf(merged.posts, 2)).assertEqual('server')
    })
  })

  describe('ThreadTreeMergePage', (): void => {
    it('reply_acceptsSameLastPage', 0, (): void => {
      const decision: MergePageDecision = resolveMergePage(false, 'e', 10, 10)
      expect(decision.accept).assertTrue()
      expect(decision.pageNo).assertEqual(10)
    })

    it('reply_acceptsNextPage', 0, (): void => {
      const decision: MergePageDecision = resolveMergePage(false, 'e', 11, 10)
      expect(decision.accept).assertTrue()
      expect(decision.pageNo).assertEqual(11)
    })

    it('reply_rejectsGapOfTwoPages', 0, (): void => {
      const decision: MergePageDecision = resolveMergePage(false, 'e', 12, 10)
      expect(decision.accept).assertFalse()
      expect(decision.pageNo).assertEqual(0)
    })

    it('reply_rejectsLastPageLessThanCommitted', 0, (): void => {
      const decision: MergePageDecision = resolveMergePage(false, 'e', 8, 10)
      expect(decision.accept).assertFalse()
    })

    it('reply_rejectsMissingPageNumber', 0, (): void => {
      const decision: MergePageDecision = resolveMergePage(false, 'e', 0, 10)
      expect(decision.accept).assertFalse()
    })

    it('edit_acceptsMatchingPage', 0, (): void => {
      const decision: MergePageDecision = resolveMergePage(true, '5', 5, 10)
      expect(decision.accept).assertTrue()
      expect(decision.pageNo).assertEqual(5)
    })

    it('edit_rejectsPageDrift', 0, (): void => {
      const decision: MergePageDecision = resolveMergePage(true, '5', 1, 10)
      expect(decision.accept).assertFalse()
    })

    it('edit_rejectsNonNumericRequest', 0, (): void => {
      const decision: MergePageDecision = resolveMergePage(true, 'e', 1, 10)
      expect(decision.accept).assertFalse()
    })
  })

  describe('ThreadTreeMergeDiff', (): void => {
    it('mergedReplyOnlyAddsRowWithoutReload', 0, (): void => {
      const main: PostInfo = createMainPost(1)
      const root: PostInfo = createQuotedPost(2, 1, 1, 'root-body')
      const before: ThreadTreeModel = buildThreadTree([main, root], 1)
      const child: PostInfo = createQuotedPost(3, 2, 2, 'child-body')
      const merged: LocalMergeResult = mergeTreePage([main, root], [child], 0, '')
      const after: ThreadTreeModel = buildThreadTree(merged.posts, 1)
      const diff: RowDiffResult = computeTreeRowDiff(before.rows, after.rows, rowKeyOf)
      expect(after.rows.length).assertEqual(before.rows.length + 1)
      expect(diff.needReload).assertFalse()
    })

    it('mergedEditKeepsRowCountWithoutReload', 0, (): void => {
      const main: PostInfo = createMainPost(1)
      const root: PostInfo = createQuotedPost(2, 1, 1, 'old-body')
      const before: ThreadTreeModel = buildThreadTree([main, root], 1)
      const edited: PostInfo = createQuotedPost(2, 1, 1, 'new-body')
      const merged: LocalMergeResult = mergeTreePage([main, root], [edited], 0, '')
      const after: ThreadTreeModel = buildThreadTree(merged.posts, 1)
      const diff: RowDiffResult = computeTreeRowDiff(before.rows, after.rows, rowKeyOf)
      expect(after.rows.length).assertEqual(before.rows.length)
      expect(diff.needReload).assertFalse()
    })
  })
}
