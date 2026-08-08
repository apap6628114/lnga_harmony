import { describe, it, expect } from '@ohos/hypium'
import { ThreadPaginationManager } from '../main/ets/common/managers/ThreadPaginationManager'
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
  })
}
