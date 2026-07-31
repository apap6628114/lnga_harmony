import { GenerationGuard } from '../concurrency/GenerationGuard'

/**
 * 分页管理器基类（共性层）。
 *
 * 封装 Thread/Topic 两个分页管理器共有的状态与逻辑：
 * - generation 计数器：用于在异步翻页/预取时丢弃过期响应
 * - prefetchedPages 缓存：预取页数据暂存，待 commit 时合并
 * - currentPage / totalPages / hasMore 三元状态：翻页进度
 *
 * 子类负责提供各自的去重 key 与追加/替换逻辑（如 Thread 用 lou 去重并维护 pageOfIndex，
 * Topic 用 tid 去重）。基类不定义 setPrefetchedPage/commitPrefetchedPage 等签名各异的
 * 方法（ArkTS 不支持方法协变重写），而是暴露 PrefetchMap 操作原语供子类复用。
 *
 * 注意：本基类不加 @Observed 装饰器。ArkUI 的状态观测按具体类注册，@Observed 必须放在
 * 最终子类（ThreadPaginationManager / TopicPaginationManager）上，否则分页 UI 不会响应式更新。
 */
export abstract class PaginationManager {
  /** 当前页码（1 基）。 */
  currentPage: number = 1
  /** 服务端返回的总页数。 */
  totalPages: number = 0
  /** 是否还有更多页可加载。 */
  hasMore: boolean = true

  private prefetchedPages: Map<number, PrefetchedPageHolder> = new Map()
  private generationGuard: GenerationGuard = new GenerationGuard()

  /**
   * 推进代际计数器并返回新值。翻页前调用以标记一次新的异步会话，
   * 响应到达后通过 getGeneration 比对以丢弃过期结果。
   * @returns 新的代际值
   */
  nextGeneration(): number {
    return this.generationGuard.bump()
  }

  /**
   * 获取当前代际值，用于响应到达时校验是否过期。
   * @returns 当前代际
   */
  getGeneration(): number {
    return this.generationGuard.current()
  }

  /**
   * 根据页码与总页数刷新三元状态（currentPage/totalPages/hasMore）。
   * 子类的 replaceWith / append 逻辑在各自维护完数组后调用本方法统一收口状态。
   * @param page - 本次提交对应的页码
   * @param totalPages - 服务端返回的总页数
   */
  protected applyState(page: number, totalPages: number): void {
    this.currentPage = page
    this.totalPages = totalPages
    this.hasMore = page < totalPages
  }

  /**
   * 推进代际使旧异步会话失效。子类 reset 须调用。
   * 采用 bump 语义（不归零），避免"捕获 0 后归零 → 0 === 0 误判有效"的边界缺陷。
   */
  protected resetGeneration(): void {
    this.generationGuard.bump()
  }

  /**
   * 判断指定页是否已有预取缓存。
   * @param page - 页码
   * @returns 是否已缓存
   */
  hasPrefetchedPage(page: number): boolean {
    return this.prefetchedPages.has(page)
  }

  /**
   * 将一页预取数据写入缓存（object[] 形式）。子类的 setPrefetchedPage 负责把
   * 强类型数组（如 PostInfo[]）拷贝成 object[] 后调用本方法。
   * @param page - 页码
   * @param items - 该页条目（object[]）
   * @param totalPages - 该页响应携带的总页数
   */
  protected setPrefetchedRaw(page: number, items: object[], totalPages: number): void {
    const holder: PrefetchedPageHolder = new PrefetchedPageHolder()
    for (let i = 0; i < items.length; i++) {
      holder.items.push(items[i])
    }
    holder.totalPages = totalPages
    this.prefetchedPages.set(page, holder)
  }

  /**
   * 读取某页的预取缓存条目（object[]），不存在时返回 undefined。
   * 子类 commitPrefetchedPage 取出后按需做类型转换与 append 去重。
   * @param page - 页码
   * @returns 缓存 holder 或 undefined
   */
  protected getPrefetchedRaw(page: number): PrefetchedPageHolder | undefined {
    return this.prefetchedPages.get(page)
  }

  /**
   * 删除指定页的预取缓存。commit 完成后调用以释放。
   * @param page - 页码
   */
  protected deletePrefetched(page: number): void {
    this.prefetchedPages.delete(page)
  }

  /**
   * 清空全部预取缓存。切换主题/重置时调用。
   */
  clearPrefetchedPages(): void {
    this.prefetchedPages.clear()
  }
}

/**
 * 预取页数据持有者。使用具体 class（非泛型）以避开 ArkTS 泛型继承限制，
 * 子类在 commit/set 时负责强类型与 object[] 的互转。
 */
class PrefetchedPageHolder {
  /** 该页条目，统一以 object[] 暂存。 */
  items: object[] = []
  /** 该页响应携带的总页数。 */
  totalPages: number = 0
}
