import { PaginationManager } from './PaginationManager'

/**
 * 主题列表（Topic）分页管理器。继承共性基类 PaginationManager，额外维护：
 * - threads：当前已加载的主题列表（object[]，按 tid 去重）
 * - prefetchInProgress：预取进行中标志
 *
 * @Observed 装饰器在本子类上，确保 ArkUI 能观测到本类实例的字段变化。
 */
@Observed
export class TopicPaginationManager extends PaginationManager {
  /** 当前已加载的主题列表，按 tid 去重。 */
  threads: object[] = []

  /** 是否有预取正在进行，用于防止重复发起。 */
  prefetchInProgress: boolean = false

  /**
   * 重置到初始分页状态。
   *
   * hasMore 复位为 true：reset 后乐观假设还有更多页，避免 UI 立即判定无可加载内容；
   * 这与 {@link PaginationManager.applyState} 根据实际响应（page < totalPages）设置 hasMore
   * 的语义不同——后者反映服务端事实，前者只是 reset 的安全默认值。
   */
  reset(): void {
    this.threads = []
    this.currentPage = 1
    this.totalPages = 0
    // 乐观假设还有更多页，待首次加载响应到达后由 applyState 按实际页数修正
    this.hasMore = true
    this.clearPrefetchedPages()
    this.resetGeneration()
  }

  /**
   * 用新的一页主题整体替换当前内容（跳页/首次加载场景）。
   * @param list - 该页主题
   * @param page - 页码
   * @param totalPages - 总页数
   */
  replaceWith(list: object[], page: number, totalPages: number): void {
    this.threads = list
    this.applyState(page, totalPages)
  }

  /**
   * 向后追加一页主题，按 tid 去重。
   * @param list - 待追加的主题
   * @param page - 页码
   * @param totalPages - 总页数
   * @returns 实际新增（去重后）的主题
   */
  appendWith(list: object[], page: number, totalPages: number): object[] {
    const existingTids: Set<number> = new Set()
    for (let i: number = 0; i < this.threads.length; i++) {
      const t: number = Number((this.threads[i] as Record<string, Object>)['tid'] ?? 0)
      if (t) existingTids.add(t)
    }
    const deduped: object[] = []
    for (let i: number = 0; i < list.length; i++) {
      const t: number = Number((list[i] as Record<string, Object>)['tid'] ?? 0)
      if (!existingTids.has(t)) {
        deduped.push(list[i])
        existingTids.add(t)
      }
    }
    if (deduped.length > 0) {
      const arr: object[] = []
      for (let i: number = 0; i < this.threads.length; i++) arr.push(this.threads[i])
      for (let i: number = 0; i < deduped.length; i++) arr.push(deduped[i])
      this.threads = arr
    }
    this.applyState(page, totalPages)
    return deduped
  }

  /**
   * 缓存一页预取主题。
   * @param page - 页码
   * @param threads - 该页主题
   * @param totalPages - 总页数
   */
  setPrefetchedPage(page: number, threads: object[], totalPages: number): void {
    this.setPrefetchedRaw(page, threads, totalPages)
  }

  /**
   * 提交某页预取缓存，合并进 threads（按 tid 去重）。
   * @param page - 页码
   * @returns 实际新增的主题（空数组表示无缓存或全部去重）
   */
  commitPrefetchedPage(page: number): object[] {
    const holder = this.getPrefetchedRaw(page)
    if (holder === undefined) {
      return []
    }
    if (holder.items.length === 0) {
      this.applyState(page, holder.totalPages)
      this.deletePrefetched(page)
      return []
    }
    const added: object[] = this.appendWith(holder.items, page, holder.totalPages)
    this.deletePrefetched(page)
    return added
  }
}
