import { describe, it, expect } from '@ohos/hypium'
import { ThreadPaginationManager, MergePageResult } from '../main/ets/common/managers/ThreadPaginationManager'
import { PostInfo } from '../main/ets/model/PostInfo'

/**
 * 创建分页测试使用的帖子。
 *
 * @param pid - 帖子稳定标识
 * @param lou - 楼层号
 * @returns 测试帖子
 */
function createPost(pid: number, lou: number): PostInfo {
  const post: PostInfo = new PostInfo()
  post.pid = pid
  post.lou = lou
  return post
}

/**
 * 注册帖子连续分页窗口单元测试。
 */
export default function threadPaginationUnitTest(): void {
  describe('threadPaginationWindow', (): void => {
    it('commitsOnlyAdjacentPagesInBothDirections', 0, (): void => {
      const manager: ThreadPaginationManager = new ThreadPaginationManager()
      manager.replaceWith([createPost(50, 50)], 5, 8)
      manager.setPrefetchedPage(3, [createPost(30, 30)], 8)
      manager.setPrefetchedPage(4, [createPost(40, 40)], 8)
      manager.setPrefetchedPage(7, [createPost(70, 70)], 8)

      const page4: PostInfo[] = manager.commitPrefetchedPreviousPage()
      expect(page4.length).assertEqual(1)
      expect(manager.loadedPageStart).assertEqual(4)
      expect(manager.posts[0].pid).assertEqual(40)
      expect(manager.posts[1].pid).assertEqual(50)

      const page3: PostInfo[] = manager.commitPrefetchedPreviousPage()
      expect(page3.length).assertEqual(1)
      expect(manager.loadedPageStart).assertEqual(3)
      expect(manager.posts[0].pid).assertEqual(30)

      const missingPage6: PostInfo[] = manager.commitPrefetchedNextPage()
      expect(missingPage6.length).assertEqual(0)
      expect(manager.loadedPageEnd).assertEqual(5)

      manager.setPrefetchedPage(6, [createPost(60, 60)], 8)
      const page6: PostInfo[] = manager.commitPrefetchedNextPage()
      const page7: PostInfo[] = manager.commitPrefetchedNextPage()
      expect(page6.length).assertEqual(1)
      expect(page7.length).assertEqual(1)
      expect(manager.loadedPageEnd).assertEqual(7)
      expect(manager.pageOfIndex[0]).assertEqual(3)
      expect(manager.pageOfIndex[manager.pageOfIndex.length - 1]).assertEqual(7)
    })

    it('advancesWindowAcrossEmptyPages', 0, (): void => {
      const manager: ThreadPaginationManager = new ThreadPaginationManager()
      manager.replaceWith([], 5, 7)
      manager.setPrefetchedPage(4, [], 7)
      manager.setPrefetchedPage(6, [], 7)

      manager.commitPrefetchedPreviousPage()
      manager.commitPrefetchedNextPage()

      expect(manager.loadedPageStart).assertEqual(4)
      expect(manager.loadedPageEnd).assertEqual(6)
      expect(manager.posts.length).assertEqual(0)
      expect(manager.hasPreviousPage()).assertTrue()
      expect(manager.hasNextPage()).assertTrue()
    })

    it('deduplicatesByPidInsteadOfFloorNumber', 0, (): void => {
      const manager: ThreadPaginationManager = new ThreadPaginationManager()
      manager.replaceWith([createPost(50, 1)], 5, 6)
      const added: PostInfo[] = manager.prependPosts([createPost(40, 1)], 4, 6)

      expect(added.length).assertEqual(1)
      expect(manager.posts.length).assertEqual(2)
      expect(manager.posts[0].pid).assertEqual(40)
      expect(manager.posts[1].pid).assertEqual(50)
    })

    it('rejectsNonAdjacentDirectCommits', 0, (): void => {
      const manager: ThreadPaginationManager = new ThreadPaginationManager()
      manager.replaceWith([createPost(50, 50)], 5, 8)

      expect(manager.appendPosts([createPost(70, 70)], 7, 8).length).assertEqual(0)
      expect(manager.prependPosts([createPost(30, 30)], 3, 8).length).assertEqual(0)
      expect(manager.loadedPageStart).assertEqual(5)
      expect(manager.loadedPageEnd).assertEqual(5)
      expect(manager.posts.length).assertEqual(1)
    })

    it('keepsOneGenerationForBidirectionalWindowGrowth', 0, (): void => {
      const manager: ThreadPaginationManager = new ThreadPaginationManager()
      manager.replaceWith([createPost(50, 50)], 5, 8)
      const windowGeneration: number = manager.getGeneration()

      manager.appendPosts([createPost(60, 60)], 6, 8)
      manager.prependPosts([createPost(40, 40)], 4, 7)

      expect(manager.getGeneration()).assertEqual(windowGeneration)
      expect(manager.loadedPageStart).assertEqual(4)
      expect(manager.loadedPageEnd).assertEqual(6)
      expect(manager.totalPages).assertEqual(8)
      manager.reset()
      expect(manager.getGeneration() === windowGeneration).assertFalse()
    })

    it('mergesWindowPageInPlaceWithoutAdvancingGeneration', 0, (): void => {
      const manager: ThreadPaginationManager = new ThreadPaginationManager()
      manager.replaceWith([createPost(50, 50)], 5, 8)
      const windowGeneration: number = manager.getGeneration()

      const fresh: PostInfo = createPost(50, 50)
      fresh.content = 'updated'
      const result = manager.mergePage([fresh], 5, 8)

      expect(result.updatedIndices.length).assertEqual(1)
      expect(result.updatedIndices[0]).assertEqual(0)
      expect(result.appendedPosts.length).assertEqual(0)
      expect(manager.posts[0].content).assertEqual('updated')
      expect(manager.posts.length).assertEqual(1)
      expect(manager.loadedPageStart).assertEqual(5)
      expect(manager.loadedPageEnd).assertEqual(5)
      expect(manager.getGeneration()).assertEqual(windowGeneration)
    })

    it('appendsNewFloorOnLastPageWhenTotalPagesUnchanged', 0, (): void => {
      const manager: ThreadPaginationManager = new ThreadPaginationManager()
      manager.replaceWith([createPost(50, 50)], 5, 5)

      const result = manager.mergePage([createPost(50, 50), createPost(51, 51)], 5, 5)

      expect(result.updatedIndices.length).assertEqual(1)
      expect(result.updatedIndices[0]).assertEqual(0)
      expect(result.appendedPosts.length).assertEqual(1)
      expect(result.appendedPosts[0].pid).assertEqual(51)
      expect(manager.posts.length).assertEqual(2)
      expect(manager.posts[1].pid).assertEqual(51)
      expect(manager.pageOfIndex[1]).assertEqual(5)
      expect(manager.loadedPageStart).assertEqual(5)
      expect(manager.loadedPageEnd).assertEqual(5)
      expect(manager.totalPages).assertEqual(5)
    })

    it('appendsAdjacentNewPageWhenServerTotalPagesGrew', 0, (): void => {
      const manager: ThreadPaginationManager = new ThreadPaginationManager()
      manager.replaceWith([createPost(50, 50)], 5, 5)

      const oldPage: MergePageResult = manager.mergePage([createPost(50, 50)], 5, 6)
      expect(oldPage.appendedPosts.length).assertEqual(0)
      expect(manager.totalPages).assertEqual(6)

      const newPage: MergePageResult = manager.mergePage(
        [createPost(60, 60), createPost(61, 61)], 6, 6)
      expect(newPage.appendedPosts.length).assertEqual(2)
      expect(manager.loadedPageEnd).assertEqual(6)
      expect(manager.posts.length).assertEqual(3)
      expect(manager.pageOfIndex[2]).assertEqual(6)

      /**
       * 同一新页重复提交按 pid 去重，只追加未见过的新帖。
       */
      const again: MergePageResult = manager.mergePage(
        [createPost(60, 60), createPost(62, 62)], 6, 6)
      expect(again.appendedPosts.length).assertEqual(1)
      expect(again.appendedPosts[0].pid).assertEqual(62)
      expect(manager.posts.length).assertEqual(4)
    })

    it('rejectsNonWindowOrNonAdjacentMergeAndOnlySyncsTotalPages', 0, (): void => {
      const manager: ThreadPaginationManager = new ThreadPaginationManager()
      manager.replaceWith([createPost(50, 50)], 5, 8)

      const farPage: MergePageResult = manager.mergePage([createPost(80, 80)], 8, 8)
      expect(farPage.updatedIndices.length).assertEqual(0)
      expect(farPage.appendedPosts.length).assertEqual(0)
      expect(manager.posts.length).assertEqual(1)
      expect(manager.loadedPageEnd).assertEqual(5)
      expect(manager.totalPages).assertEqual(8)
    })

    it('refusesNewPidOnMiddleWindowPageToKeepPageOrder', 0, (): void => {
      const manager: ThreadPaginationManager = new ThreadPaginationManager()
      manager.replaceWith([createPost(50, 50)], 5, 8)
      manager.appendPosts([createPost(60, 60)], 6, 8)
      expect(manager.loadedPageEnd).assertEqual(6)

      /**
       * 第 5 页是窗口内页而非服务端末页（totalPages=8 > 5）：异常新 pid 不得追加。
       */
      const result: MergePageResult = manager.mergePage(
        [createPost(50, 50), createPost(55, 55)], 5, 8)
      expect(result.updatedIndices.length).assertEqual(1)
      expect(result.appendedPosts.length).assertEqual(0)
      expect(manager.posts.length).assertEqual(2)
    })

    it('advancesWindowOnEmptyAdjacentPageMerge', 0, (): void => {
      const manager: ThreadPaginationManager = new ThreadPaginationManager()
      manager.replaceWith([createPost(50, 50)], 5, 5)

      const result: MergePageResult = manager.mergePage([], 6, 6)

      expect(result.appendedPosts.length).assertEqual(0)
      expect(manager.loadedPageEnd).assertEqual(6)
      expect(manager.totalPages).assertEqual(6)
    })

    it('refusesNewPidOnLastPageWhenServerTotalPagesGrew', 0, (): void => {
      const manager: ThreadPaginationManager = new ThreadPaginationManager()
      manager.replaceWith([createPost(50, 50)], 5, 5)

      // 窗口末页 5 但服务端已翻到 6：第 5 页出现的新 pid 属异常（新楼层应在第 6 页），不得追加
      const result: MergePageResult = manager.mergePage(
        [createPost(50, 50), createPost(55, 55)], 5, 6)
      expect(result.updatedIndices.length).assertEqual(1)
      expect(result.appendedPosts.length).assertEqual(0)
      expect(manager.posts.length).assertEqual(1)
      expect(manager.totalPages).assertEqual(6)

      // 随后相邻新页整页追加，新楼层到达窗口
      const next: MergePageResult = manager.mergePage([createPost(60, 60)], 6, 6)
      expect(next.appendedPosts.length).assertEqual(1)
      expect(manager.loadedPageEnd).assertEqual(6)
      expect(manager.posts.length).assertEqual(2)
    })

    it('mergeConsumesPrefetchAndKeepsPidSetInSync', 0, (): void => {
      const manager: ThreadPaginationManager = new ThreadPaginationManager()
      manager.replaceWith([createPost(50, 50)], 5, 5)
      manager.setPrefetchedPage(6, [createPost(60, 60)], 6)
      expect(manager.hasPrefetchedPage(6)).assertTrue()

      // mergePage 提交相邻新页后清除该页预取缓存（与 appendPosts 语义一致）
      manager.mergePage([createPost(60, 60)], 6, 6)
      expect(manager.hasPrefetchedPage(6)).assertFalse()
      expect(manager.posts.length).assertEqual(2)

      // 相邻下一页携带同一 pid：loadedPidSet 已登记，追加被去重但窗口仍推进
      const dup: PostInfo[] = manager.appendPosts([createPost(60, 60)], 7, 7)
      expect(dup.length).assertEqual(0)
      expect(manager.loadedPageEnd).assertEqual(7)
      expect(manager.posts.length).assertEqual(2)
    })

    it('mergeLastPageAppendIsIdempotentByPid', 0, (): void => {
      const manager: ThreadPaginationManager = new ThreadPaginationManager()
      manager.replaceWith([createPost(50, 50)], 5, 5)
      manager.mergePage([createPost(50, 50), createPost(51, 51)], 5, 5)
      expect(manager.posts.length).assertEqual(2)

      // 同一页再次合并：51 已登记，只原地更新不重复追加
      const again: MergePageResult = manager.mergePage(
        [createPost(50, 50), createPost(51, 51)], 5, 5)
      expect(again.updatedIndices.length).assertEqual(2)
      expect(again.appendedPosts.length).assertEqual(0)
      expect(manager.posts.length).assertEqual(2)
    })

    it('bumpsUiRevOnContentChangeToDriveKeyRefresh', 0, (): void => {
      const manager: ThreadPaginationManager = new ThreadPaginationManager()
      manager.replaceWith([createPost(50, 50)], 5, 8)
      expect(manager.posts[0].uiRev).assertEqual(0)

      // 内容变化：uiRev 递增（LazyForEach 键值 pid_0 -> pid_1，触发该楼层重建刷新）
      const fresh: PostInfo = createPost(50, 50)
      fresh.content = 'updated'
      const result: MergePageResult = manager.mergePage([fresh], 5, 8)
      expect(result.updatedIndices.length).assertEqual(1)
      expect(manager.posts[0].content).assertEqual('updated')
      expect(manager.posts[0].uiRev).assertEqual(1)

      // 内容相同：替换对象但 uiRev 保持不变（键值稳定、组件复用、无冗余重建）
      const same: PostInfo = createPost(50, 50)
      same.content = 'updated'
      const again: MergePageResult = manager.mergePage([same], 5, 8)
      expect(again.updatedIndices.length).assertEqual(1)
      expect(manager.posts[0].content).assertEqual('updated')
      expect(manager.posts[0].uiRev).assertEqual(1)
    })

    it('skipsStaleCacheOverwriteWhenProtectedContentMismatches', 0, (): void => {
      const manager: ThreadPaginationManager = new ThreadPaginationManager()
      manager.replaceWith([createPost(50, 50)], 5, 8)

      // 模拟乐观更新：用户编辑提交新正文
      manager.posts[0].content = 'new text after edit'
      manager.posts[0].uiRev++

      // 静默刷新返回 read.php 旧缓存（仍是编辑前旧正文），且与保护值不一致 → 跳过覆盖
      const stale: PostInfo = createPost(50, 50)
      stale.content = 'old cached text'
      const protectedContent: Map<number, string> = new Map<number, string>()
      protectedContent.set(50, 'new text after edit')
      const result: MergePageResult = manager.mergePage([stale], 5, 8, protectedContent)

      expect(result.updatedIndices.length).assertEqual(0)
      expect(manager.posts[0].content).assertEqual('new text after edit')
      expect(manager.posts[0].uiRev).assertEqual(1)

      // 缓存失效后服务端返回新正文（与保护值一致）→ 正常覆盖确认；
      // 内容一致则 uiRev 不变，无冗余重建
      const confirmed: PostInfo = createPost(50, 50)
      confirmed.content = 'new text after edit'
      const confirmedResult: MergePageResult = manager.mergePage(
        [confirmed], 5, 8, protectedContent)
      expect(confirmedResult.updatedIndices.length).assertEqual(1)
      expect(manager.posts[0].content).assertEqual('new text after edit')
      expect(manager.posts[0].uiRev).assertEqual(1)
    })
  })
}
