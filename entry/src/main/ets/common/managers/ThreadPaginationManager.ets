import type { PostInfo } from '../../model/PostInfo'
import { PaginationManager } from './PaginationManager'

/**
 * 帖子详情的连续分页窗口管理器。
 *
 * 管理器始终只允许提交与当前窗口相邻的页面，使已加载内容保持为
 * `[loadedPageStart, loadedPageEnd]` 的连续区间。向前、向后预取共用按页缓存，
 * 缓存可以乱序到达，但只有紧邻窗口边界的页面才能提交到可见列表。
 * 修改窗口语义前必须先阅读 `docs/THREAD_DESIGN.md`。
 */
@Observed
export class ThreadPaginationManager extends PaginationManager {
  /** 当前连续窗口内的帖子列表。 */
  posts: PostInfo[] = []

  /** 与 posts 一一对应的所属页码。 */
  pageOfIndex: number[] = []

  /** 当前连续窗口的起始页。 */
  loadedPageStart: number = 1

  /** 当前连续窗口的结束页。 */
  loadedPageEnd: number = 1

  /** 已加载帖子的稳定标识集合。 */
  private loadedPidSet: Set<number> = new Set()

  /**
   * 重置分页窗口并推进会话代际，使此前的异步结果全部失效。
   */
  reset(): void {
    this.posts = []
    this.pageOfIndex = []
    this.loadedPidSet.clear()
    this.loadedPageStart = 1
    this.loadedPageEnd = 1
    this.currentPage = 1
    this.totalPages = 0
    this.hasMore = true
    this.clearPrefetchedPages()
    this.resetGeneration()
  }

  /**
   * 用单页内容建立新的连续窗口。
   *
   * @param newPosts - 页面帖子
   * @param page - 服务端确认的页码
   * @param totalPages - 服务端确认的总页数
   */
  replaceWith(newPosts: PostInfo[], page: number, totalPages: number): void {
    this.clearPrefetchedPages()
    this.loadedPidSet.clear()
    for (let i: number = 0; i < newPosts.length; i++) {
      this.loadedPidSet.add(newPosts[i].pid)
    }
    this.posts = newPosts
    this.pageOfIndex = newPosts.map((): number => page)
    this.loadedPageStart = page
    this.loadedPageEnd = page
    this.applyState(page, Math.max(page, totalPages))
  }

  /**
   * 返回窗口下一相邻页。
   *
   * @returns 下一页页码
   */
  getNextPage(): number {
    return this.loadedPageEnd + 1
  }

  /**
   * 返回窗口上一相邻页。
   *
   * @returns 上一页页码，不存在时为 0
   */
  getPreviousPage(): number {
    return Math.max(this.loadedPageStart - 1, 0)
  }

  /**
   * 判断窗口后方是否还有页面。
   *
   * @returns 是否可以向下加载
   */
  hasNextPage(): boolean {
    return this.loadedPageEnd < this.totalPages
  }

  /**
   * 判断窗口前方是否还有页面。
   *
   * @returns 是否可以向上加载
   */
  hasPreviousPage(): boolean {
    return this.loadedPageStart > 1
  }

  /**
   * 判断指定页是否已处于连续窗口中。
   *
   * @param page - 待判断页码
   * @returns 是否已经加载
   */
  isPageLoaded(page: number): boolean {
    return this.totalPages > 0 && page >= this.loadedPageStart && page <= this.loadedPageEnd
  }

  /**
   * 向窗口末尾提交相邻下一页，并按 pid 去重。
   *
   * @param rawPosts - 页面原始帖子
   * @param page - 页面页码
   * @param totalPages - 总页数
   * @returns 实际新增的帖子；非相邻页不会被提交
   */
  appendPosts(rawPosts: PostInfo[], page: number, totalPages: number): PostInfo[] {
    if (page !== this.getNextPage()) {
      return []
    }
    const added: PostInfo[] = this.collectNewPosts(rawPosts)
    if (added.length > 0) {
      const combinedPosts: PostInfo[] = this.posts.concat(added)
      const combinedPages: number[] = this.pageOfIndex.concat(added.map((): number => page))
      this.posts = combinedPosts
      this.pageOfIndex = combinedPages
    }
    this.loadedPageEnd = page
    this.deletePrefetched(page)
    const stableTotalPages: number = Math.max(this.totalPages, totalPages, this.loadedPageEnd)
    this.applyState(this.loadedPageEnd, stableTotalPages)
    return added
  }

  /**
   * 向窗口开头提交相邻上一页，并按 pid 去重。
   *
   * @param rawPosts - 页面原始帖子
   * @param page - 页面页码
   * @param totalPages - 总页数
   * @returns 实际新增的帖子；非相邻页不会被提交
   */
  prependPosts(rawPosts: PostInfo[], page: number, totalPages: number): PostInfo[] {
    if (page !== this.getPreviousPage()) {
      return []
    }
    const added: PostInfo[] = this.collectNewPosts(rawPosts)
    if (added.length > 0) {
      const combinedPosts: PostInfo[] = added.concat(this.posts)
      const combinedPages: number[] = added.map((): number => page).concat(this.pageOfIndex)
      this.posts = combinedPosts
      this.pageOfIndex = combinedPages
    }
    this.loadedPageStart = page
    this.deletePrefetched(page)
    const stableTotalPages: number = Math.max(this.totalPages, totalPages, this.loadedPageEnd)
    this.applyState(this.loadedPageEnd, stableTotalPages)
    return added
  }

  /**
   * 缓存一页乱序到达的预取结果。
   *
   * @param page - 页码
   * @param posts - 页面帖子
   * @param totalPages - 总页数
   */
  setPrefetchedPage(page: number, posts: PostInfo[], totalPages: number): void {
    if (this.isPageLoaded(page)) {
      return
    }
    const items: object[] = []
    for (let i: number = 0; i < posts.length; i++) {
      items.push(posts[i])
    }
    this.setPrefetchedRaw(page, items, totalPages)
  }

  /**
   * 提交缓存中的相邻下一页。
   *
   * @returns 实际新增的帖子
   */
  commitPrefetchedNextPage(): PostInfo[] {
    const page: number = this.getNextPage()
    const holder = this.getPrefetchedRaw(page)
    if (holder === undefined) {
      return []
    }
    return this.appendPosts(this.toPosts(holder.items), page, holder.totalPages)
  }

  /**
   * 提交缓存中的相邻上一页。
   *
   * @returns 实际新增的帖子
   */
  commitPrefetchedPreviousPage(): PostInfo[] {
    const page: number = this.getPreviousPage()
    const holder = this.getPrefetchedRaw(page)
    if (holder === undefined) {
      return []
    }
    return this.prependPosts(this.toPosts(holder.items), page, holder.totalPages)
  }

  /**
   * 根据列表中心帖子索引计算当前显示页。
   *
   * @param centerIndex - 中心帖子的数组索引
   * @returns 对应页码
   */
  getDisplayPage(centerIndex: number): number {
    if (centerIndex >= 0 && centerIndex < this.pageOfIndex.length) {
      return this.pageOfIndex[centerIndex]
    }
    return this.loadedPageEnd
  }

  /**
   * 按 pid 查找帖子索引。
   *
   * @param pid - 帖子 pid
   * @returns 索引，未找到返回 -1
   */
  findPostIndex(pid: number): number {
    for (let i: number = 0; i < this.posts.length; i++) {
      if (this.posts[i].pid === pid) {
        return i
      }
    }
    return -1
  }

  /**
   * 给指定 pid 的帖子累加投票分数。
   *
   * @param pid - 帖子 pid
   * @param scoreDelta - score 增量
   * @param score2Delta - score_2 增量
   * @returns 被更新帖子的索引，未找到返回 -1
   */
  updateVoteScore(pid: number, scoreDelta: number, score2Delta: number): number {
    for (let i: number = 0; i < this.posts.length; i++) {
      if (this.posts[i].pid === pid) {
        this.posts[i].score += scoreDelta
        this.posts[i].score_2 += score2Delta
        return i
      }
    }
    return -1
  }

  /**
   * 从页面结果中筛出尚未加载的帖子，并登记稳定标识。
   *
   * @param rawPosts - 页面原始帖子
   * @returns 去重后的帖子
   */
  private collectNewPosts(rawPosts: PostInfo[]): PostInfo[] {
    const added: PostInfo[] = []
    for (let i: number = 0; i < rawPosts.length; i++) {
      const post: PostInfo = rawPosts[i]
      if (!this.loadedPidSet.has(post.pid)) {
        added.push(post)
        this.loadedPidSet.add(post.pid)
      }
    }
    return added
  }

  /**
   * 将基类缓存中的对象数组恢复为帖子数组。
   *
   * @param items - 基类缓存条目
   * @returns 帖子数组
   */
  private toPosts(items: object[]): PostInfo[] {
    const posts: PostInfo[] = []
    for (let i: number = 0; i < items.length; i++) {
      posts.push(items[i] as PostInfo)
    }
    return posts
  }
}
