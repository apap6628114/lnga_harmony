import { taskpool } from '@kit.ArkTS'

import { appStore } from '../store/AppStore'
import { getThread } from './api/ThreadApi'
import { looksLikeThrottle } from './api/NgaThrottleSignals'
import { PostInfo } from '../model/PostInfo'
import type { ThreadInfo } from '../model/Thread'
import { ThreadResult } from '../model/ThreadResult'
import { preWarmPosts } from '../common/utils/PostWarmup'
import { withTimeout } from '../common/utils/TimeoutUtils'
import { Logger, DOMAIN_SERVICE, formatError } from '../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'ThreadTreeFetchService')

/** 相邻两页请求之间的最小间隔（毫秒）：顺序抓取、不并发，对 NGA 保持节流礼貌。 */
const TREE_PAGE_INTERVAL_MS: number = 300

/** 单页请求超时（毫秒）。 */
const TREE_PAGE_TIMEOUT_MS: number = 15000

/** 抓取完成后做首屏正文预热的楼层数上限（只预热首屏，不预热全量）。 */
const TREE_WARMUP_POST_LIMIT: number = 60

/** 命中风控时的统一提示文案（不自动重试，避免加深限流）。 */
const TREE_THROTTLE_HINT: string = '访问过于频繁，请稍后再试'

/**
 * 全帖抓取结果。
 *
 * 调用方（ThreadTreePanel）用它提交结果：`ok` 为 true 时
 * `posts` / `pageByPid` / `totalPages` / `threadInfo` / `forumName` 可用；
 * `cancelled` 与失败区分（取消不弹错误）；失败时 `posts` 为空数组、不提交半成品。
 */
export class ThreadTreeFetchResult {
  /** 本次抓取的任务代际（服务内部递增，调用方可用于诊断；提交校验以调用方自身代际为准）。 */
  generation: number = 0

  /** 是否抓取成功（完整抓完全部页并按 pid 合并）。 */
  ok: boolean = false

  /** 是否被取消（与失败区分，UI 不弹错误、回到原视图）。 */
  cancelled: boolean = false

  /** 失败文案（ok 为 true 或 cancelled 时为空串）。 */
  error: string = ''

  /** 合并后的全帖楼层（按 pid 去重、按 `lou` 升序）；失败/取消时为空数组。 */
  posts: PostInfo[] = []

  /** 服务端页码映射：楼层 pid → 抓取时所在页（含主楼 pid=0 → 1）。 */
  pageByPid: Map<number, number> = new Map<number, number>()

  /** 服务端总页数（至少为 1）。 */
  totalPages: number = 0

  /** 主题元数据（取自第 1 页响应）。 */
  threadInfo: ThreadInfo | null = null

  /** 版块名（取自第 1 页响应）。 */
  forumName: string = ''
}

/**
 * 递进树全帖抓取服务。
 *
 * 流程（参照 `SavedThreadService.saveThread` 的逐页/节流/取消范式，但**不落盘**）：
 * 1. 取第 1 页（整页请求不带 pid、空黑名单/关键词/备注，保证引用图完整）→ 拿
 *    `totalPages`、主楼、主题信息；
 * 2. 顺序抓 2..N 页；每页间隔 {@link TREE_PAGE_INTERVAL_MS}、每页
 *    {@link TREE_PAGE_TIMEOUT_MS} 超时；任一页失败重试 1 次，仍失败则整体失败；
 *    命中风控（`looksLikeThrottle`）直接失败，不再重试；
 * 3. 合并按 pid 去重、按 `lou` 升序，逐页记录 `pageByPid`（每页抓到时就记）；
 * 4. `cancel(owner)` 在当前页完成后终止；每次启动递增内部 `generation`；
 * 5. 完成后 `preWarmPosts(前 min(60, n) 个, false, HIGH)` 预热首屏 BBCode 解析缓存。
 *
 * ## 并发与取消语义（页面级隔离的关键）
 *
 * 树阅读页是独立栈页面，快速切帖 / 返回再进入时会出现「新页面已开始加载、旧页面
 * 尚未销毁」的时序。服务因此必须做到：
 *
 * - **新任务等待旧任务退场**：`fetchAll` 若发现上一个任务的 Promise 仍在途，先置取消
 *   并 await 它结束（旧任务最多再等当前页请求），再启动新任务——不会出现
 *   「已有任务进行中」把新页面直接拒掉；
 * - **cancel 按页面实例精确匹配**：旧页面销毁回调晚于新页面启动时，`cancel(oldOwner)`
 *   不会误杀新页面的任务；
 * - 抓取期间不写 `savedThreadProgress`、不碰 `ThreadPaginationManager`，与离线保存、
 *   自然列表页互不干扰。
 */
export class ThreadTreeFetchService {
  /** 当前任务代际（每次成功启动 fetchAll 递增）。 */
  private generation: number = 0

  /** 是否有抓取任务在途。 */
  private fetching: boolean = false

  /** 取消标记：置位后当前页完成即终止。 */
  private cancelled: boolean = false

  /** 当前任务所属页面实例标识（`cancel` 精确匹配用）。 */
  private activeOwner: string = ''

  /** 当前任务所属主题（诊断用）。 */
  private activeTid: string = ''

  /** 当前在途任务的 Promise（新任务启动前先等待它退场）。 */
  private activeTask: Promise<ThreadTreeFetchResult> | null = null

  /** 是否有抓取任务在途。 */
  get isFetching(): boolean {
    return this.fetching
  }

  /** 当前任务代际（诊断用）。 */
  get currentGeneration(): number {
    return this.generation
  }

  /**
   * 请求取消当前抓取任务（当前页完成后终止；无任务时为空操作）。
   *
   * @param owner - 页面实例标识；传空串表示无条件取消当前任务。
   *   传具体 owner 时只有「当前任务正属于该页面」才生效，避免旧页面的销毁回调
   *   晚于新页面启动时误杀新任务。
   */
  cancel(owner: string = ''): void {
    if (!this.fetching) {
      return
    }
    if (owner.length > 0 && this.activeOwner !== owner) {
      return
    }
    this.cancelled = true
  }

  /**
   * 抓取全帖并合并。
   *
   * @param owner - 调用页面实例标识（用于精确取消/串行化，不能用 tid 代替：
   *   同一帖子返回再进入会出现两个页面实例）
   * @param tid - 主题 ID
   * @param onProgress - 每页完成回调（done 已完成页数，total 总页数）
   * @returns 抓取结果；调用方提交前应校验自身代际/帖子是否已变化
   */
  async fetchAll(owner: string, tid: string,
    onProgress?: (done: number, total: number) => void): Promise<ThreadTreeFetchResult> {
    if (tid.length === 0) {
      const invalid: ThreadTreeFetchResult = new ThreadTreeFetchResult()
      invalid.error = '帖子参数无效'
      return invalid
    }
    const token: string = appStore.auth.token
    if (!appStore.getSession(token)) {
      const denied: ThreadTreeFetchResult = new ThreadTreeFetchResult()
      denied.error = '请先登录'
      return denied
    }
    // 上一个树页面可能尚未退场（快速切帖 / 返回再进入）：先请求它取消并等它结束，
    // 否则会以「已有任务进行中」把新页面直接拒掉（旧任务最多再等当前页请求返回）
    const previousTask: Promise<ThreadTreeFetchResult> | null = this.activeTask
    if (previousTask !== null) {
      this.cancelled = true
      logger.info('tree-fetch await previous owner=%{public}s tid=%{public}s',
        this.activeOwner, this.activeTid)
      try {
        await previousTask
      } catch (e) {
        logger.warn('tree-fetch previous task error: %{public}s', formatError(e))
      }
    }

    this.fetching = true
    this.cancelled = false
    this.generation++
    const generation: number = this.generation
    this.activeOwner = owner
    this.activeTid = tid
    const task: Promise<ThreadTreeFetchResult> = this.runFetch(token, tid, generation, onProgress)
    this.activeTask = task
    try {
      return await task
    } finally {
      if (this.activeTask === task) {
        this.activeTask = null
        this.activeOwner = ''
        this.activeTid = ''
        this.fetching = false
      }
    }
  }

  /**
   * 执行一次完整抓取（`fetchAll` 的串行化外壳之外的纯抓取流程）。
   *
   * @param token - 会话令牌
   * @param tid - 主题 ID
   * @param generation - 本次任务代际
   * @param onProgress - 每页完成回调
   * @returns 抓取结果
   */
  private async runFetch(token: string, tid: string, generation: number,
    onProgress?: (done: number, total: number) => void): Promise<ThreadTreeFetchResult> {
    const result: ThreadTreeFetchResult = new ThreadTreeFetchResult()
    result.generation = generation
    const seenPids: Set<number> = new Set<number>()
    const collected: PostInfo[] = []
    const pageByPid: Map<number, number> = new Map<number, number>()
    let done: number = 0
    let totalPages: number = 1

    logger.info('tree-fetch begin tid=%{public}s gen=%{public}d', tid, generation)
    try {
      const first: ThreadResult = await this.fetchPage(token, tid, 1)
      if (!first.ok) {
        result.error = this.pageFailureMessage(1, first)
        return result
      }
      if (first.posts.length === 0) {
        result.error = '无法加载帖子楼层'
        return result
      }
      this.mergePosts(first.posts, 1, seenPids, collected, pageByPid)
      result.threadInfo = first.threadInfo
      result.forumName = first.forumName
      totalPages = first.pagination.totalPages > 0 ? first.pagination.totalPages : 1
      done = 1
      this.notifyProgress(done, totalPages, onProgress)
      if (this.cancelled || generation !== this.generation) {
        result.cancelled = true
        return result
      }

      for (let page: number = 2; page <= totalPages; page++) {
        await this.sleep(TREE_PAGE_INTERVAL_MS)
        if (this.cancelled || generation !== this.generation) {
          result.cancelled = true
          return result
        }
        const pageResult: ThreadResult = await this.fetchPage(token, tid, page)
        if (!pageResult.ok) {
          result.error = this.pageFailureMessage(page, pageResult)
          logger.warn('tree-fetch page failed tid=%{public}s page=%{public}d: %{public}s',
            tid, page, pageResult.error)
          return result
        }
        this.mergePosts(pageResult.posts, page, seenPids, collected, pageByPid)
        done++
        this.notifyProgress(done, totalPages, onProgress)
      }

      if (this.cancelled || generation !== this.generation) {
        result.cancelled = true
        return result
      }
      collected.sort((a: PostInfo, b: PostInfo): number => a.lou - b.lou)
      result.posts = collected
      result.pageByPid = pageByPid
      result.totalPages = totalPages
      result.ok = true
      await this.warmUp(collected)
      logger.info('tree-fetch done tid=%{public}s gen=%{public}d posts=%{public}d pages=%{public}d',
        tid, generation, collected.length, totalPages)
      return result
    } catch (e) {
      result.ok = false
      result.posts = []
      result.pageByPid = new Map<number, number>()
      result.error = '全帖加载失败：' + formatError(e)
      logger.error('tree-fetch failed tid=%{public}s gen=%{public}d: %{public}s',
        tid, generation, formatError(e))
      return result
    }
  }

  /**
   * 抓取一页，失败重试 1 次（命中风控时不重试）。
   *
   * @param token - 会话令牌
   * @param tid - 主题 ID
   * @param page - 页码（从 1 开始）
   * @returns 页面结果；重试后仍失败时 `ok = false`
   */
  private async fetchPage(token: string, tid: string, page: number): Promise<ThreadResult> {
    let result: ThreadResult = await this.requestPage(token, tid, page)
    if (result.ok) {
      return result
    }
    if (looksLikeThrottle(result.error)) {
      return result
    }
    logger.warn('tree-fetch page retry tid=%{public}s page=%{public}d: %{public}s',
      tid, page, result.error)
    await this.sleep(TREE_PAGE_INTERVAL_MS)
    result = await this.requestPage(token, tid, page)
    return result
  }

  /**
   * 发起单页整页请求（不带 pid、空过滤条件），并加超时保护。
   *
   * @param token - 会话令牌
   * @param tid - 主题 ID
   * @param page - 页码（从 1 开始）
   * @returns 页面结果；超时或异常时返回 `ok = false` 的结果对象
   */
  private async requestPage(token: string, tid: string, page: number): Promise<ThreadResult> {
    const emptyBlacklist: Set<string> = new Set<string>()
    const emptyKeywords: string[] = []
    const emptyNotes: Record<string, string> = {}
    try {
      const result: ThreadResult = await withTimeout<ThreadResult>(
        getThread(token, tid, '', '', String(page), emptyBlacklist, emptyKeywords, emptyNotes),
        TREE_PAGE_TIMEOUT_MS
      )
      return result
    } catch (e) {
      const failed: ThreadResult = new ThreadResult()
      failed.ok = false
      failed.error = '第 ' + String(page) + ' 页请求超时或异常：' + formatError(e)
      return failed
    }
  }

  /**
   * 把一页楼层并入合并结果：按 pid 去重、逐条记录服务端页码。
   *
   * @param posts - 该页楼层
   * @param page - 该页页码
   * @param seenPids - 已合并 pid 集合
   * @param collected - 合并后的楼层数组
   * @param pageByPid - pid → 页码映射
   */
  private mergePosts(posts: PostInfo[], page: number, seenPids: Set<number>,
    collected: PostInfo[], pageByPid: Map<number, number>): void {
    for (let i: number = 0; i < posts.length; i++) {
      const post: PostInfo = posts[i]
      if (seenPids.has(post.pid)) {
        continue
      }
      seenPids.add(post.pid)
      collected.push(post)
      pageByPid.set(post.pid, page)
    }
  }

  /**
   * 发布一次抓取进度；回调异常被隔离，不影响抓取流程。
   *
   * @param done - 已完成页数
   * @param total - 总页数
   * @param onProgress - 进度回调（可为 undefined）
   */
  private notifyProgress(done: number, total: number,
    onProgress?: (done: number, total: number) => void): void {
    if (onProgress === undefined) {
      return
    }
    try {
      onProgress(done, total)
    } catch (e) {
      logger.warn('tree-fetch progress callback failed: %{public}s', formatError(e))
    }
  }

  /**
   * 预热首屏楼层的 BBCode 解析缓存（最多 {@link TREE_WARMUP_POST_LIMIT} 条）。
   *
   * @param posts - 合并后的全帖楼层（按 lou 升序）
   */
  private async warmUp(posts: PostInfo[]): Promise<void> {
    const count: number = Math.min(TREE_WARMUP_POST_LIMIT, posts.length)
    if (count <= 0) {
      return
    }
    const warmupPosts: PostInfo[] = []
    for (let i: number = 0; i < count; i++) {
      warmupPosts.push(posts[i])
    }
    try {
      await preWarmPosts(warmupPosts, false, taskpool.Priority.HIGH)
    } catch (e) {
      logger.warn('tree-fetch preWarmPosts failed: %{public}s', formatError(e))
    }
  }

  /**
   * 生成单页失败的用户可读文案（风控命中时给统一提示）。
   *
   * @param page - 失败页码
   * @param result - 该页结果
   * @returns 失败文案
   */
  private pageFailureMessage(page: number, result: ThreadResult): string {
    if (looksLikeThrottle(result.error)) {
      return TREE_THROTTLE_HINT
    }
    if (result.error.length > 0) {
      return '第 ' + String(page) + ' 页加载失败：' + result.error
    }
    return '第 ' + String(page) + ' 页加载失败'
  }

  /**
   * 简单延时。
   *
   * @param ms - 毫秒
   */
  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve()
      }, ms)
    })
  }
}

/** 全局递进树全帖抓取服务单例。 */
export const threadTreeFetchService: ThreadTreeFetchService = new ThreadTreeFetchService()
