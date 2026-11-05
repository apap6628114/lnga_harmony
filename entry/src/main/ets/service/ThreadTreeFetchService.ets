import { taskpool } from '@kit.ArkTS'

import { appStore } from '../store/AppStore'
import { getThread } from './api/ThreadApi'
import { looksLikeThrottle } from './api/NgaThrottleSignals'
import { Throttler } from '../common/concurrency/Throttler'
import { PostInfo } from '../model/PostInfo'
import type { ThreadInfo } from '../model/Thread'
import { ThreadResult } from '../model/ThreadResult'
import { collectPostContents } from '../common/utils/PostWarmup'
import { preWarmBatch } from '../parser/bbcode/BBCodeCache'
import { withTimeout } from '../common/utils/TimeoutUtils'
import { Logger, DOMAIN_SERVICE, formatError } from '../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'ThreadTreeFetchService')

/** 相邻两页请求之间的最小派发间隔（毫秒）：由批量读取限流器统一控制。 */
const TREE_PAGE_INTERVAL_MS: number = 250

/** 并发抓取的页数上限：4 页在途，请求节奏由批量读取限流器统一控制。 */
const TREE_PAGE_CONCURRENCY: number = 4

/** 单页请求超时（毫秒）。 */
const TREE_PAGE_TIMEOUT_MS: number = 15000

/** 单页失败后重试前的退避间隔（毫秒）。 */
const TREE_RETRY_BACKOFF_MS: number = 400

/**
 * 批量读取允许的滑动窗口请求数（60 秒内）。
 *
 * 180 次/分钟 = 3 次/秒（平均），是「长帖一次性抓全」与「不触发风控」的折中点：
 * 100 页约 33~40 秒完成；而网页版打开一页论坛本身就会产生几十个静态资源与接口请求，
 * 3 次/秒的持续读取量仍在正常浏览的形态内。
 *
 * 全站默认限流器（`ngaThrottler`）是 60 次/分钟，适合日常浏览，但会把长帖抓取
 * 压到 100 秒以上；树页是**用户显式触发的一次性批量读取**，因此单独给一档窗口。
 * 风控命中时全局冷却仍然生效（见 {@link treeBatchThrottler} 注释）。
 */
const TREE_BATCH_MAX_IN_WINDOW: number = 180

/** 抓取完成后做首屏正文预热的楼层数上限（只预热首屏，不预热全量）。 */
const TREE_WARMUP_POST_LIMIT: number = 60

/** 命中风控时的统一提示文案（不自动重试，避免加深限流）。 */
const TREE_THROTTLE_HINT: string = '访问过于频繁，请稍后再试'

/** 全帖结果内存缓存的有效期（毫秒）：短时返回再进入免去重抓全帖。 */
const TREE_CACHE_TTL_MS: number = 90000

/** 全帖结果内存缓存最多保留的帖子数（按写入时间淘汰最旧）。 */
const TREE_CACHE_MAX_ENTRIES: number = 2

/** 单帖楼层数超过该值时不写缓存：超大帖（数千楼）全量常驻内存会显著抬高峰值。 */
const TREE_CACHE_MAX_POSTS: number = 3000

/**
 * 树页批量读取专用限流器。
 *
 * 三重约束与全站默认配置同形（并发 4 / 最小派发间隔 250ms），只把**滑动窗口**
 * 放宽到 {@link TREE_BATCH_MAX_IN_WINDOW} 次/分钟。它不绕开任何风控信号：
 * - 网络层命中 429 或「过于频繁」文案时，`ngaThrottler.enterCooldown` 会全局拉闸；
 * - 之后所有请求（包括本实例）都会在 `NgaClient.ngaRequest` 的冷却前置检查处被拒绝，
 *   不会因为换了限流桶而继续打服务端。
 */
const treeBatchThrottler: Throttler = new Throttler(
  TREE_PAGE_CONCURRENCY, TREE_PAGE_INTERVAL_MS, TREE_BATCH_MAX_IN_WINDOW, 60000)

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

  /**
   * 是否抓取成功（完整抓完全部页并按 pid 合并）。
   *
   * `skippedPages` 非空时仍为 true：跳过页只是「那一页没有可见楼层」，
   * 其余页内容完整可用（见 {@link ThreadTreeFetchResult.skippedPages}）。
   */
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

  /**
   * 被跳过的异常页（页码升序）。
   *
   * 这些页服务端返回了合法帖子页、但整页没有任何可见楼层（`ThreadResult.emptyPage`），
   * 已跳过、不参与合并。`ok = true` 时若本字段非空，表示结果是**部分完整**的：
   * 页面可以照常阅读，但缺少这几页的楼层（树里表现为内容偏少、引用目标可能悬空，
   * `buildThreadTree` 会把目标不在树内的楼层提升为根，不会丢行）。
   *
   * 跳过页数过半时不会提交部分结果（`isSkippedPagesOverwhelming` 改判整体失败），
   * 因此 `ok = true` 时这里最多是少数页。
   */
  skippedPages: number[] = []

  /** 主题元数据（取自第 1 页响应）。 */
  threadInfo: ThreadInfo | null = null

  /** 版块名（取自第 1 页响应）。 */
  forumName: string = ''
}

/**
 * 单页失败是否可以从「整帖致命」降级为「跳过该页」。
 *
 * 只放过「页面本身没有可见楼层」这一类（{@link ThreadResult.emptyPage}）：服务端
 * 返回了合法帖子页（`template=read`），只是整页楼位全部不可见——被批量删除、
 * 审核中、被屏蔽，或 HTML 里根本没有楼层行。它**不是请求链故障**，跳过一页仍能
 * 读到其余全部楼层，一页全空不该让整帖不可读。
 *
 * 其余失败一律不可跳过，整体失败并停止派发：
 * - 网络错误 / 超时：可能是本机弱网，继续抓会连续超时；
 * - 风控文案：继续抓会加深限流。当前 `emptyPage` 的 error 恒为 `THREAD_NO_FLOOR_ERROR`，
 *   这条检查在生产上不会命中；保留它是防止将来 `emptyPage` 语义扩展到携带原始错误时，
 *   风控页被静默当成空页跳过；
 * - 服务端错误页（帖子被锁定 / 待审核 / 权限不足）：整帖不可读，逐页跳过没有意义。
 *
 * @param result - 该页的请求结果
 * @returns 只跳过该页、继续抓其余页时为 true
 */
export function isSkippablePageFailure(result: ThreadResult): boolean {
  if (result.ok || !result.emptyPage) {
    return false
  }
  return !looksLikeThrottle(result.error)
}

/**
 * 被跳过的空页数量是否已多到不能算「局部异常」。
 *
 * 少数页整页不可见是正常的页面状态（某段回复被批量删除 / 审核中），跳过即可；
 * 但**半页以上都空**说明不是局部问题（帖子被拆 / 合并、账号态异常、解析器大面积
 * 回归），这时继续展示残缺的树会误导用户，应整体失败让用户重试或换列表阅读。
 *
 * 阈值 = max(2, ⌈总页数 / 2⌉)：小帖至少允许缺 1 页（2 页帖缺 1 页仍可读），
 * 3 页帖缺 2 页则只剩 1 页，判为整体失败。
 *
 * @param skippedCount - 被跳过的页数
 * @param totalPages - 服务端总页数
 * @returns 应整体失败时为 true
 */
export function isSkippedPagesOverwhelming(skippedCount: number, totalPages: number): boolean {
  if (skippedCount <= 0) {
    return false
  }
  const limit: number = Math.max(2, Math.ceil(totalPages / 2))
  return skippedCount >= limit
}

/**
 * 生成单页失败的用户可读文案（风控命中时给统一提示）。
 *
 * 纯函数（不读实例状态），便于单测覆盖「第 1 页空页」这类无法在本地构造的文案。
 *
 * @param page - 失败页码
 * @param result - 该页结果
 * @returns 用户可读文案
 */
export function formatPageFailureMessage(page: number, result: ThreadResult): string {
  if (looksLikeThrottle(result.error)) {
    return TREE_THROTTLE_HINT
  }
  if (result.emptyPage) {
    // 只会在第 1 页出现（其余页的空页已按「跳过」处理）：没有主楼可渲染，整帖无法阅读
    return '第 ' + String(page) + ' 页没有可显示的楼层（整页楼层可能已被删除或屏蔽）'
  }
  if (result.error.length > 0) {
    return '第 ' + String(page) + ' 页加载失败：' + result.error
  }
  return '第 ' + String(page) + ' 页加载失败'
}

/** 并发抓页调度状态（单任务内共享，避免闭包修改外部变量）。 */
class FetchPageScheduler {
  /** 下一个待派发页码（从 2 开始）。 */
  nextPage: number = 2

  /** 服务端总页数。 */
  totalPages: number = 1

  /** 是否已停止派发（某页致命失败或命中风控）。 */
  stopped: boolean = false

  /** 停止原因（用户可读文案）。 */
  error: string = ''

  /** 已完成页数（含第 1 页与被跳过的空页）。 */
  done: number = 0

  /** 被跳过的空页页码（worker 完成顺序入列，提交前统一排序）。 */
  skippedPages: number[] = []
}

/** 全帖结果缓存条目。 */
class TreeFetchCacheEntry {
  /** 写入时间戳（毫秒）。 */
  savedAt: number = 0

  /** 已成功抓取的全帖结果（posts 数组与页面映射跨页面实例共享）。 */
  result: ThreadTreeFetchResult = new ThreadTreeFetchResult()
}

/**
 * 递进树全帖抓取服务。
 *
 * 流程（参照 `SavedThreadService.saveThread` 的逐页/节流/取消范式，但**不落盘**）：
 * 1. 取第 1 页（整页请求不带 pid、空黑名单/关键词/备注，保证引用图完整）→ 拿
 *    `totalPages`、主楼、主题信息；
 * 2. 第 2..N 页**并发抓取**（{@link TREE_PAGE_CONCURRENCY} 路，请求间隔与窗口由
 *    {@link treeBatchThrottler} 控制）；单页 {@link TREE_PAGE_TIMEOUT_MS} 超时，
 *    失败重试 1 次（退避 {@link TREE_RETRY_BACKOFF_MS}），仍失败则整体失败；
 *    命中风控（`looksLikeThrottle`）直接失败、不再重试，其余在途页停止派发；
 * 2.1 **例外：单页空页跳过**。服务端返回合法帖子页但整页没有任何可见楼层时
 *    （`ThreadResult.emptyPage`，典型成因是整页楼位被批量删除 / 审核 / 屏蔽），
 *    不重试、不整体失败，只记入 `skippedPages` 继续抓其余页——一页楼位全空不该
 *    让整帖不可读。其余失败类型（网络、超时、风控、锁定/审核中等错误页）仍是
 *    整体失败：它们说明请求链或帖子状态有问题，继续抓只会打更多无效请求；
 * 3. 合并按 pid 去重、按 `lou` 升序，逐页记录 `pageByPid`（每页抓到时就记）；
 * 3.1 有跳过页时结果仍是 `ok = true`，但 `skippedPages` 非空、**不写短时缓存**
 *    （下次进入或刷新会重抓，有机会补齐；否则 90 秒内重进仍是缺页）；
 * 4. `cancel(owner)` 在当前批次请求完成后终止（在途页结果丢弃）；每次启动递增内部
 *    `generation`；
 * 5. 完成后**后台**预热首屏楼层的 BBCode 解析缓存（不阻塞结果提交）。
 *
 * ## 缓存
 *
 * 成功结果按「账号 uid + tid」缓存 {@link TREE_CACHE_TTL_MS}，最多
 * {@link TREE_CACHE_MAX_ENTRIES} 个帖子：列表→树→返回→再进树在缓存期内秒开，
 * 不重复打服务端。刷新（菜单「刷新递进树」/回复后刷新）传 `forceRefresh = true`
 * 跳过缓存。
 *
 * ## 并发与取消语义（页面级隔离的关键）
 *
 * 树阅读页是独立栈页面，快速切帖 / 返回再进入时会出现「新页面已开始加载、旧页面
 * 尚未销毁」的时序。服务因此必须做到：
 *
 * - **新任务等待旧任务退场**：`fetchAll` 若发现上一个任务的 Promise 仍在途，先置取消
 *   并 await 它结束（旧任务最多再等当前批次请求），再启动新任务——不会出现
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

  /** 取消标记：置位后当前批次请求完成即终止。 */
  private cancelled: boolean = false

  /** 当前任务所属页面实例标识（`cancel` 精确匹配用）。 */
  private activeOwner: string = ''

  /** 当前任务所属主题（诊断用）。 */
  private activeTid: string = ''

  /** 当前在途任务的 Promise（新任务启动前先等待它退场）。 */
  private activeTask: Promise<ThreadTreeFetchResult> | null = null

  /** 成功结果缓存（账号 + 帖子 → 全帖数据）。 */
  private cache: Map<string, TreeFetchCacheEntry> = new Map<string, TreeFetchCacheEntry>()

  /** 是否有抓取任务在途。 */
  get isFetching(): boolean {
    return this.fetching
  }

  /** 当前任务代际（诊断用）。 */
  get currentGeneration(): number {
    return this.generation
  }

  /**
   * 请求取消当前抓取任务（当前批次请求完成后终止；无任务时为空操作）。
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
   * 丢弃指定帖子的缓存（诊断/测试用；正常刷新走 `forceRefresh`）。
   *
   * @param tid - 主题 ID
   */
  invalidateCache(tid: string): void {
    const keysToDelete: string[] = []
    this.cache.forEach((entry: TreeFetchCacheEntry, key: string): void => {
      if (key.endsWith(':' + tid)) {
        keysToDelete.push(key)
      }
    })
    for (let i: number = 0; i < keysToDelete.length; i++) {
      this.cache.delete(keysToDelete[i])
    }
  }

  /**
   * 抓取全帖并合并。
   *
   * @param owner - 调用页面实例标识（用于精确取消/串行化，不能用 tid 代替：
   *   同一帖子返回再进入会出现两个页面实例）
   * @param tid - 主题 ID
   * @param onProgress - 每页完成回调（done 已完成页数，total 总页数）
   * @param forceRefresh - 为 true 时跳过短时缓存，强制重新抓取（刷新/回复后刷新）
   * @returns 抓取结果；调用方提交前应校验自身代际/帖子是否已变化
   */
  async fetchAll(owner: string, tid: string,
    onProgress?: (done: number, total: number) => void,
    forceRefresh: boolean = false): Promise<ThreadTreeFetchResult> {
    if (tid.length === 0) {
      const invalid: ThreadTreeFetchResult = new ThreadTreeFetchResult()
      invalid.error = '帖子参数无效'
      return invalid
    }
    const token: string = appStore.auth.token
    const session = appStore.getSession(token)
    if (!session) {
      const denied: ThreadTreeFetchResult = new ThreadTreeFetchResult()
      denied.error = '请先登录'
      return denied
    }
    // 上一个树页面可能尚未退场（快速切帖 / 返回再进入）：先请求它取消并等它结束，
    // 否则会以「已有任务进行中」把新页面直接拒掉（旧任务最多再等当前批次请求返回）
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

    if (!forceRefresh) {
      const cached: ThreadTreeFetchResult | null = this.readCache(session.uid, tid)
      if (cached !== null) {
        this.generation++
        cached.generation = this.generation
        logger.info('tree-fetch cache hit tid=%{public}s posts=%{public}d pages=%{public}d',
          tid, cached.posts.length, cached.totalPages)
        return cached
      }
    }

    this.fetching = true
    this.cancelled = false
    this.generation++
    const generation: number = this.generation
    this.activeOwner = owner
    this.activeTid = tid
    const task: Promise<ThreadTreeFetchResult> = this.runFetch(token, tid, generation,
      session.uid, onProgress, forceRefresh)
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
   * @param uid - 当前登录用户 ID（缓存键组成部分）
   * @param onProgress - 每页完成回调
   * @param forceRefresh - 是否强制刷新（成功后才写缓存）
   * @returns 抓取结果
   */
  private async runFetch(token: string, tid: string, generation: number, uid: string,
    onProgress?: (done: number, total: number) => void,
    forceRefresh: boolean = false): Promise<ThreadTreeFetchResult> {
    const result: ThreadTreeFetchResult = new ThreadTreeFetchResult()
    result.generation = generation
    const seenPids: Set<number> = new Set<number>()
    const collected: PostInfo[] = []
    const pageByPid: Map<number, number> = new Map<number, number>()
    const scheduler: FetchPageScheduler = new FetchPageScheduler()
    let totalPages: number = 1

    logger.info('tree-fetch begin tid=%{public}s gen=%{public}d refresh=%{public}s concurrency=%{public}d',
      tid, generation, String(forceRefresh), TREE_PAGE_CONCURRENCY)
    try {
      const first: ThreadResult = await this.fetchPage(token, tid, 1)
      if (!first.ok) {
        result.error = formatPageFailureMessage(1, first)
        // 第 1 页失败是整帖唯一的「无内容可渲染」入口：必须留日志（技术原因在
        // first.error 里，UI 文案只给用户可读表述），否则空页降级路径不可诊断
        logger.warn('tree-fetch page1 failed tid=%{public}s gen=%{public}d empty=%{public}s: %{public}s',
          tid, generation, String(first.emptyPage), first.error)
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
      scheduler.totalPages = totalPages
      scheduler.done = 1
      this.notifyProgress(scheduler.done, totalPages, onProgress)
      if (this.cancelled || generation !== this.generation) {
        result.cancelled = true
        return result
      }

      if (totalPages > 1) {
        const workers: Promise<void>[] = []
        const workerCount: number = Math.min(TREE_PAGE_CONCURRENCY, totalPages - 1)
        for (let i: number = 0; i < workerCount; i++) {
          workers.push(this.fetchWorker(token, tid, generation, scheduler,
            seenPids, collected, pageByPid, onProgress))
        }
        await Promise.all(workers)
      }

      if (this.cancelled || generation !== this.generation) {
        result.cancelled = true
        return result
      }
      if (scheduler.error.length > 0) {
        result.error = scheduler.error
        logger.warn('tree-fetch page failed tid=%{public}s: %{public}s', tid, scheduler.error)
        return result
      }
      collected.sort((a: PostInfo, b: PostInfo): number => a.lou - b.lou)
      result.posts = collected
      result.pageByPid = pageByPid
      result.totalPages = totalPages
      // worker 完成顺序不确定：跳过页统一按页码升序提交，UI 提示才不会乱序
      result.skippedPages = scheduler.skippedPages.slice()
      result.skippedPages.sort((a: number, b: number): number => a - b)
      if (isSkippedPagesOverwhelming(result.skippedPages.length, totalPages)) {
        // 过半页都空：不是「局部整页被删」，而是帖子状态或抓取链整体异常。
        // 此时展示残缺的树会误导用户，按整体失败处理（UI 给错误态与重试）
        result.ok = false
        result.posts = []
        result.pageByPid = new Map<number, number>()
        result.error = '有 ' + String(result.skippedPages.length) + ' 页没有可显示的楼层，帖子可能已被删除或屏蔽'
        logger.warn('tree-fetch overwhelmingly empty tid=%{public}s gen=%{public}d skipped=%{public}d pages=%{public}d',
          tid, generation, result.skippedPages.length, totalPages)
        return result
      }
      result.ok = true
      /** 预热不阻塞结果提交：页面先渲染首屏，解析在 taskpool 里并行补齐缓存 */
      this.warmUp(collected)
      if (result.skippedPages.length === 0) {
        this.writeCache(uid, tid, result)
      }
      // 一条完成日志带出全部关键量：帖子/页数/跳过页（缺页结果不写缓存，见上方闸门）
      logger.info('tree-fetch done tid=%{public}s gen=%{public}d posts=%{public}d pages=%{public}d ' +
        'skipped=%{public}s cache=%{public}s',
        tid, generation, collected.length, totalPages,
        result.skippedPages.length > 0 ? result.skippedPages.join(',') : '-',
        result.skippedPages.length === 0 ? 'on' : 'off')
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
   * 一个并发抓页 worker：循环领取下一页直到取完、失败或取消。
   *
   * 页码分配通过 {@link FetchPageScheduler.nextPage} 同步自增完成（单线程语义），
   * 每个 worker 独立请求、独立合并；结果合并顺序与完成顺序一致，最终再按楼号排序。
   *
   * @param token - 会话令牌
   * @param tid - 主题 ID
   * @param generation - 任务代际
   * @param scheduler - 调度状态（页码游标/停止标记/进度）
   * @param seenPids - 已合并 pid 集合（跨 worker 共享）
   * @param collected - 已合并楼层（跨 worker 共享）
   * @param pageByPid - pid → 页码映射（跨 worker 共享）
   * @param onProgress - 进度回调
   */
  private async fetchWorker(token: string, tid: string, generation: number,
    scheduler: FetchPageScheduler, seenPids: Set<number>, collected: PostInfo[],
    pageByPid: Map<number, number>,
    onProgress?: (done: number, total: number) => void): Promise<void> {
    while (true) {
      if (scheduler.stopped || this.cancelled || generation !== this.generation) {
        return
      }
      if (scheduler.nextPage > scheduler.totalPages) {
        return
      }
      const page: number = scheduler.nextPage
      scheduler.nextPage++
      const pageResult: ThreadResult = await this.fetchPage(token, tid, page)
      if (!pageResult.ok) {
        if (isSkippablePageFailure(pageResult)) {
          // 该页是「合法空页」（整页楼位全部不可见）：跳过继续抓其余页。
          // 一页楼位全空不该让整帖不可读；跳过页会在结果里如实上报给 UI。
          // 另一个 worker 已判定致命失败或任务已取消时不再记进度（结果随即被丢弃）
          if (!scheduler.stopped && !this.cancelled && generation === this.generation) {
            scheduler.skippedPages.push(page)
            scheduler.done++
            this.notifyProgress(scheduler.done, scheduler.totalPages, onProgress)
            logger.warn('tree-fetch page skipped tid=%{public}s page=%{public}d: %{public}s',
              tid, page, pageResult.error)
          }
          continue
        }
        if (!scheduler.stopped) {
          scheduler.stopped = true
          scheduler.error = formatPageFailureMessage(page, pageResult)
        }
        return
      }
      if (this.cancelled || generation !== this.generation) {
        return
      }
      this.mergePosts(pageResult.posts, page, seenPids, collected, pageByPid)
      scheduler.done++
      this.notifyProgress(scheduler.done, scheduler.totalPages, onProgress)
    }
  }

  /**
   * 抓取一页，失败重试 1 次（命中风控或整页空页时不重试）。
   *
   * 空页不重试只对第 2 页起成立：那一页的退路是「跳过该页」，重试没有收益；
   * 第 1 页没有退路（没有主楼就没有可渲染内容），瞬时空响应必须再给一次机会，
   * 不能让一次偶发异常直接锁死整帖。
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
    // 空页是服务端的稳定页面状态（整页楼层被删除/审核/屏蔽），重试不会有不同结果：
    // 直接交给调用方按「跳过该页」处理，省下一次无效请求
    if (result.emptyPage && page > 1) {
      return result
    }
    if (looksLikeThrottle(result.error)) {
      return result
    }
    logger.warn('tree-fetch page retry tid=%{public}s page=%{public}d: %{public}s',
      tid, page, result.error)
    await this.sleep(TREE_RETRY_BACKOFF_MS)
    if (this.cancelled) {
      return result
    }
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
        getThread(token, tid, '', '', String(page), emptyBlacklist, emptyKeywords, emptyNotes,
          treeBatchThrottler),
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
   * **不等待完成**：预热只影响首屏正文解析耗时，不应把已经抓完的数据继续扣在
   * 「加载中」。缓存未命中时渲染层会同步解析，预热失败也只退化为该路径。
   *
   * @param posts - 合并后的全帖楼层（按 lou 升序）
   */
  private warmUp(posts: PostInfo[]): void {
    const count: number = Math.min(TREE_WARMUP_POST_LIMIT, posts.length)
    if (count <= 0) {
      return
    }
    const warmupPosts: PostInfo[] = []
    for (let i: number = 0; i < count; i++) {
      warmupPosts.push(posts[i])
    }
    const contents: string[] = collectPostContents(warmupPosts, false)
    if (contents.length === 0) {
      return
    }
    preWarmBatch(contents, taskpool.Priority.HIGH)
  }

  /**
   * 读取缓存（同账号、同帖子、未过期）。
   *
   * 缓存里**永远没有跳过页**：含跳过页的结果不写缓存（见 `runFetch` 的写侧闸门），
   * 因此这里返回的结果 `skippedPages` 恒为空，无需复制。若将来放宽写侧闸门，
   * 必须同时在这里复制 `skippedPages`，否则 UI 会静默丢掉缺页提示。
   *
   * @param uid - 当前登录用户 ID
   * @param tid - 主题 ID
   * @returns 缓存结果（共享 posts 数组）；未命中或过期返回 null
   */
  private readCache(uid: string, tid: string): ThreadTreeFetchResult | null {
    const key: string = uid + ':' + tid
    const entry: TreeFetchCacheEntry | undefined = this.cache.get(key)
    if (entry === undefined) {
      return null
    }
    if (Date.now() - entry.savedAt > TREE_CACHE_TTL_MS) {
      this.cache.delete(key)
      return null
    }
    const result: ThreadTreeFetchResult = new ThreadTreeFetchResult()
    result.ok = true
    result.posts = entry.result.posts
    result.pageByPid = entry.result.pageByPid
    result.totalPages = entry.result.totalPages
    result.threadInfo = entry.result.threadInfo
    result.forumName = entry.result.forumName
    return result
  }

  /**
   * 写入成功结果缓存（按写入时间淘汰最旧条目）。
   *
   * @param uid - 当前登录用户 ID
   * @param tid - 主题 ID
   * @param result - 成功抓取结果
   */
  private writeCache(uid: string, tid: string, result: ThreadTreeFetchResult): void {
    if (!result.ok || result.cancelled) {
      return
    }
    if (result.posts.length > TREE_CACHE_MAX_POSTS) {
      /** 超大帖不常驻内存：缓存收益（返回再进入）不足以抵消内存峰值 */
      return
    }
    const entry: TreeFetchCacheEntry = new TreeFetchCacheEntry()
    entry.savedAt = Date.now()
    entry.result = result
    this.cache.set(uid + ':' + tid, entry)
    while (this.cache.size > TREE_CACHE_MAX_ENTRIES) {
      let oldestKey: string = ''
      let oldestAt: number = Number.MAX_SAFE_INTEGER
      this.cache.forEach((value: TreeFetchCacheEntry, key: string): void => {
        if (value.savedAt < oldestAt) {
          oldestAt = value.savedAt
          oldestKey = key
        }
      })
      if (oldestKey.length === 0) {
        break
      }
      this.cache.delete(oldestKey)
    }
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
