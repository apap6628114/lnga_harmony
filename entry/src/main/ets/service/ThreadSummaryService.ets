/**
 * 全帖 AI 总结的楼层取数与提示词组装。
 *
 * 与单楼层总结（`ThreadPanel` 动作栏 AI 图标，只带本层正文）不同，全帖总结要跨页取数：
 * 按服务端总页数逐页走官方 APP HTML 通道（`fetchThreadRaw`），沿用
 * `SavedThreadService` 的顺序请求 + 页间节流约定，并复用调用方已加载的楼层窗口，
 * 避免重复请求用户正在看的页。
 *
 * ## 页数与长度都有硬上限
 *
 * - 总页数超过 {@link SUMMARY_MAX_PAGES} 时只取头部 {@link SUMMARY_HEAD_PAGES} 页与末页，
 *   中间页整段跳过（末页必须保留：长帖的结论、资源、后续进展通常落在末页）。
 * - 正文总字符数受 {@link TOTAL_TEXT_BUDGET} 约束，其中 {@link TAIL_TEXT_RESERVE} 专留给
 *   末页，避免头部楼层吃光额度后末页被整体丢弃；头部未用完的额度会顺延给末页。
 * - 单楼层正文另有上限：普通楼层 {@link FLOOR_TEXT_LIMIT}，主楼 {@link OP_FLOOR_TEXT_LIMIT}
 *   （主楼是整帖的纲领，允许更长）。
 *
 * 三种截断都会写进提示词的「本次覆盖」与「说明」两行，让模型与用户都知道看到的不是全帖。
 *
 * ## 职责边界
 *
 * 本服务只负责「取数 + 组装提示词」，不调用模型。模型调用仍由 `AiChatPage` →
 * `ActiveAiService` 承担，与单楼层总结共用同一条流式通道（场景 `thread_summary`）。
 * 黑名单用户的楼层不纳入正文，仅在说明里计数——与正文渲染遮蔽其内容的口径一致。
 *
 * ## 单页失败不中断
 *
 * 任一页取数失败只跳过该页并记 warn：全帖总结的价值来自覆盖面，一页失败就让
 * 整个流程失败反而更差。失败页会在「本次覆盖」的层数里自然体现（层数偏少）。
 */

import { appStore } from '../store/AppStore'
import { fetchThreadRaw, fillThreadResult } from './api/ThreadApi'
import type { ThreadRawResult } from './api/ThreadApi'
import { PostInfo } from '../model/PostInfo'
import { ThreadResult } from '../model/ThreadResult'
import { getCachedBBNodes, preWarmBatchAwait } from '../parser/bbcode/BBCodeCache'
import { bbNodesToPlainText } from '../common/utils/Utils'
import { applyBlacklistStateToPosts } from '../common/utils/BlacklistUtils'
import { Logger, DOMAIN_SERVICE, formatError } from '../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'ThreadSummaryService')

/** 全帖总结最多抓取的页数；超过时改为「头部若干页 + 末页」。 */
const SUMMARY_MAX_PAGES: number = 20

/** 页数超上限时保留的头部页数。 */
const SUMMARY_HEAD_PAGES: number = 10

/** 普通楼层正文纳入总结的字符上限。 */
const FLOOR_TEXT_LIMIT: number = 600

/** 主楼正文纳入总结的字符上限（主楼承载整帖纲领，放宽一档）。 */
const OP_FLOOR_TEXT_LIMIT: number = 2000

/** 提示词正文总字符预算。 */
const TOTAL_TEXT_BUDGET: number = 40000

/** 总预算中预留给末页的字符额度。 */
const TAIL_TEXT_RESERVE: number = 8000

/** 相邻两页请求之间的最小间隔（毫秒），对 NGA 服务器保持节流礼貌。 */
const PAGE_FETCH_INTERVAL_MS: number = 300

/** 单楼层被截断时追加的提示文案。 */
const FLOOR_CLIP_SUFFIX: string = '……（本层正文已截断）'

/**
 * 取数计划：本次要读哪些页，以及因页数上限跳过了哪些页。
 */
class SummaryPagePlan {
  /** 前置页，按页码升序（从第 1 页起）。 */
  headPages: number[] = []

  /** 单独取出的末页；未分离时为 0（末页已在 headPages 内）。 */
  tailPage: number = 0

  /** 是否因页数上限跳过了中间页。 */
  skippedByPageLimit: boolean = false

  /** 被跳过的页区间文案；未跳过时为空串。 */
  skippedPageRange: string = ''
}

/**
 * 提示词正文预算账本：按页顺序消耗，额度不足时停止纳入后续楼层并计数。
 */
class FloorBudget {
  /** 剩余可用字符数。 */
  remaining: number = 0

  /** 因额度不足未纳入正文的楼层数。 */
  overflowFloors: number = 0

  /** 因作者在黑名单而跳过正文的楼层数。 */
  blockedFloors: number = 0
}

/**
 * 已纳入提示词的一个楼层。
 */
class SummaryFloor {
  /** 楼层号（0 = 楼主）。 */
  lou: number = 0

  /** 作者名。 */
  author: string = ''

  /** 楼层纯文本正文（可能已被截断）。 */
  text: string = ''

  /** 是否为主楼。 */
  isOp: boolean = false
}

/**
 * 全帖总结的组装结果。
 */
export class ThreadSummaryOutcome {
  /** 是否成功组装出提示词。 */
  ok: boolean = false

  /** 是否被用户取消（与失败区分，取消不弹错误提示）。 */
  cancelled: boolean = false

  /** ok=false 时为用户可读的终止原因。 */
  message: string = ''

  /** ok=true 时可直接交给 `AiChatPage` 的初始提示词。 */
  prompt: string = ''

  /** 纳入正文的楼层数。 */
  includedFloors: number = 0

  /** 本次取数实际返回楼层的页数。 */
  coveredPages: number = 0

  /** 是否只覆盖了部分楼层（页数上限或字符额度上限）。 */
  truncated: boolean = false
}

/**
 * 把帖子总页数换算成取数计划。
 *
 * @param totalPages - 服务端总页数
 * @returns 取数计划
 */
function planSummaryPages(totalPages: number): SummaryPagePlan {
  const plan: SummaryPagePlan = new SummaryPagePlan()
  if (totalPages <= SUMMARY_MAX_PAGES) {
    for (let page: number = 1; page <= totalPages; page++) {
      plan.headPages.push(page)
    }
    return plan
  }
  for (let page: number = 1; page <= SUMMARY_HEAD_PAGES; page++) {
    plan.headPages.push(page)
  }
  plan.tailPage = totalPages
  plan.skippedByPageLimit = true
  plan.skippedPageRange = '第 ' + String(SUMMARY_HEAD_PAGES + 1) + '~' + String(totalPages - 1) + ' 页'
  return plan
}

/**
 * 把调用方已加载的窗口按页码索引，供取数时复用（命中即不发请求）。
 *
 * @param posts - 窗口内帖子
 * @param pages - 与 posts 一一对应的所属页码
 * @returns 页码 → 楼层数组
 */
function indexWindowByPage(posts: PostInfo[], pages: number[]): Map<number, PostInfo[]> {
  const index: Map<number, PostInfo[]> = new Map<number, PostInfo[]>()
  const count: number = Math.min(posts.length, pages.length)
  for (let i: number = 0; i < count; i++) {
    const page: number = pages[i]
    const bucket: PostInfo[] | undefined = index.get(page)
    if (bucket === undefined) {
      index.set(page, [posts[i]])
    } else {
      bucket.push(posts[i])
    }
  }
  return index
}

/**
 * 收敛空白并按上限截断楼层正文。
 *
 * @param text - 楼层纯文本
 * @param limit - 字符上限
 * @returns 规整后的正文
 */
function clipFloorText(text: string, limit: number): string {
  const normalized: string = text.replace(/\n{3,}/g, '\n\n').trim()
  if (normalized.length <= limit) {
    return normalized
  }
  return normalized.substring(0, limit) + FLOOR_CLIP_SUFFIX
}

/**
 * 把一页楼层按预算纳入目标数组。
 *
 * 顺序即楼号顺序：额度耗尽的后续楼层直接跳过并计数——保留的是靠前的楼层，
 * 与「头部优先」的取数计划一致。
 *
 * @param posts - 该页楼层
 * @param target - 输出数组（原地追加）
 * @param budget - 预算账本（原地扣减与计数）
 */
function appendPageFloors(posts: PostInfo[], target: SummaryFloor[], budget: FloorBudget): void {
  for (let i: number = 0; i < posts.length; i++) {
    const post: PostInfo = posts[i]
    if (post.isInBlackList) {
      budget.blockedFloors++
      continue
    }
    const plainText: string = bbNodesToPlainText(getCachedBBNodes(post.content))
    if (plainText.length === 0) {
      continue
    }
    const limit: number = post.lou === 0 ? OP_FLOOR_TEXT_LIMIT : FLOOR_TEXT_LIMIT
    const clipped: string = clipFloorText(plainText, limit)
    if (clipped.length > budget.remaining) {
      budget.overflowFloors++
      continue
    }
    budget.remaining -= clipped.length
    const floor: SummaryFloor = new SummaryFloor()
    floor.lou = post.lou
    floor.author = post.author
    floor.text = clipped
    floor.isOp = post.lou === 0
    target.push(floor)
  }
}

/**
 * 拼装提示词正文部分（楼层段落，按楼号顺序）。
 *
 * @param floors - 楼层数组
 * @returns 正文文本
 */
function composeFloorSection(floors: SummaryFloor[]): string {
  const parts: string[] = []
  for (let i: number = 0; i < floors.length; i++) {
    const floor: SummaryFloor = floors[i]
    const label: string = floor.isOp ? '楼主' : '#' + String(floor.lou)
    parts.push(label + ' ' + floor.author + '：\n' + floor.text)
  }
  return parts.join('\n\n')
}

/**
 * 拼装「本次覆盖」与「说明」两行。
 *
 * @param plan - 取数计划
 * @param totalPages - 服务端总页数
 * @param coveredPages - 实际返回楼层的页数
 * @param includedFloors - 纳入正文的楼层数
 * @param budget - 合并后的预算账本
 * @returns 覆盖范围与说明文本
 */
function composeCoverage(plan: SummaryPagePlan, totalPages: number, coveredPages: number,
  includedFloors: number, budget: FloorBudget): string {
  const pagePart: string = plan.skippedByPageLimit
    ? '第 1~' + String(SUMMARY_HEAD_PAGES) + ' 页、第 ' + String(totalPages) + ' 页（共 ' +
      String(coveredPages) + ' 页）'
    : '全帖 ' + String(totalPages) + ' 页（共 ' + String(coveredPages) + ' 页）'
  let text: string = '本次覆盖：' + pagePart + '，' + String(includedFloors) + ' 层'
  if (!plan.skippedByPageLimit && budget.overflowFloors === 0 && budget.blockedFloors === 0) {
    return text
  }
  const reasons: string[] = []
  if (plan.skippedByPageLimit) {
    reasons.push('中间 ' + plan.skippedPageRange + ' 因页数上限未纳入')
  }
  if (budget.overflowFloors > 0) {
    reasons.push('另有 ' + String(budget.overflowFloors) + ' 层因长度上限未纳入')
  }
  if (budget.blockedFloors > 0) {
    reasons.push(String(budget.blockedFloors) + ' 层来自黑名单用户，已按设置跳过')
  }
  text += '\n说明：' + reasons.join('；') + '。以下内容不覆盖全帖，请勿据此推断未纳入部分。'
  return text
}

/**
 * 全帖总结的取数与组装服务。
 *
 * 与 `savedThreadService` 同模式：模块级单例 + 任务内 `building` 门禁 + 取消标记。
 * 单例是必要的——ThreadPanel 在折叠屏多列路由下可能同时存在多个实例，
 * 而抓取任务与取消语义必须全局唯一。
 */
export class ThreadSummaryService {
  /** 是否正在执行组装任务。 */
  private building: boolean = false

  /** 取消标记：置位后当前页返回即终止。 */
  private cancelled: boolean = false

  /**
   * 是否正在执行组装任务。
   */
  get isBuilding(): boolean {
    return this.building
  }

  /**
   * 请求取消当前组装任务。
   */
  cancel(): void {
    this.cancelled = true
  }

  /**
   * 抓取全帖楼层并组装 AI 总结提示词。
   *
   * @param tid - 主题 ID
   * @param subject - 主题标题
   * @param totalPages - 服务端总页数
   * @param windowPosts - 调用方已加载窗口内的楼层；**只看楼主模式下必须传空数组**，
   *   该模式窗口内只有楼主楼层，复用会与整帖楼层口径不一致
   * @param windowPages - 与 windowPosts 一一对应的所属页码
   * @param onProgress - 进度回调（done 已开始处理的页数，total 计划页数，label 展示文案）
   * @returns 组装结果
   */
  async buildSummaryPrompt(tid: string, subject: string, totalPages: number,
    windowPosts: PostInfo[], windowPages: number[],
    onProgress?: (done: number, total: number, label: string) => void): Promise<ThreadSummaryOutcome> {
    const outcome: ThreadSummaryOutcome = new ThreadSummaryOutcome()
    if (this.building) {
      outcome.message = '已有全帖总结任务进行中'
      return outcome
    }
    if (!tid || tid.length === 0 || totalPages < 1) {
      outcome.message = '帖子页数未知，无法总结'
      return outcome
    }
    const token: string = appStore.auth.token
    if (!appStore.getSession(token)) {
      outcome.message = '请先登录'
      return outcome
    }

    this.building = true
    this.cancelled = false
    try {
      const plan: SummaryPagePlan = planSummaryPages(totalPages)
      const cachedPages: Map<number, PostInfo[]> = indexWindowByPage(windowPosts, windowPages)
      const stepTotal: number = plan.headPages.length + (plan.tailPage > 0 ? 1 : 0)
      const headBudget: FloorBudget = new FloorBudget()
      headBudget.remaining = plan.tailPage > 0 ? TOTAL_TEXT_BUDGET - TAIL_TEXT_RESERVE : TOTAL_TEXT_BUDGET
      const tailBudget: FloorBudget = new FloorBudget()

      const headFloors: SummaryFloor[] = []
      const tailFloors: SummaryFloor[] = []
      let donePages: number = 0
      let coveredPages: number = 0

      for (let i: number = 0; i < plan.headPages.length; i++) {
        const page: number = plan.headPages[i]
        if (this.cancelled) {
          outcome.cancelled = true
          outcome.message = '已取消全帖总结'
          return outcome
        }
        if (onProgress) {
          onProgress(donePages, stepTotal,
            '正在汇总全帖楼层… ' + String(donePages + 1) + '/' + String(stepTotal) + ' 页')
        }
        if (donePages > 0) {
          await this.sleep(PAGE_FETCH_INTERVAL_MS)
        }
        const posts: PostInfo[] = await this.loadPageFloors(token, tid, page, cachedPages)
        donePages++
        if (posts.length > 0) {
          coveredPages++
        }
        await this.prewarmContents(posts)
        appendPageFloors(posts, headFloors, headBudget)
      }

      if (plan.tailPage > 0) {
        if (this.cancelled) {
          outcome.cancelled = true
          outcome.message = '已取消全帖总结'
          return outcome
        }
        if (onProgress) {
          onProgress(donePages, stepTotal,
            '正在汇总全帖楼层… ' + String(donePages + 1) + '/' + String(stepTotal) + ' 页')
        }
        await this.sleep(PAGE_FETCH_INTERVAL_MS)
        // 头部未用完的额度顺延给末页，保证末页拿到的预算不低于预留值
        tailBudget.remaining = Math.max(TAIL_TEXT_RESERVE, TOTAL_TEXT_BUDGET - headBudget.remaining)
        const posts: PostInfo[] = await this.loadPageFloors(token, tid, plan.tailPage, cachedPages)
        donePages++
        if (posts.length > 0) {
          coveredPages++
        }
        await this.prewarmContents(posts)
        appendPageFloors(posts, tailFloors, tailBudget)
      }

      if (this.cancelled) {
        outcome.cancelled = true
        outcome.message = '已取消全帖总结'
        return outcome
      }

      const allFloors: SummaryFloor[] = headFloors.concat(tailFloors)
      const blockedTotal: number = headBudget.blockedFloors + tailBudget.blockedFloors
      if (allFloors.length === 0) {
        outcome.message = blockedTotal > 0
          ? '该帖楼层均来自黑名单用户，无内容可总结'
          : '该帖没有可总结的楼层内容'
        return outcome
      }

      const mergedBudget: FloorBudget = new FloorBudget()
      mergedBudget.remaining = headBudget.remaining + tailBudget.remaining
      mergedBudget.overflowFloors = headBudget.overflowFloors + tailBudget.overflowFloors
      mergedBudget.blockedFloors = blockedTotal
      outcome.includedFloors = allFloors.length
      outcome.coveredPages = coveredPages
      outcome.truncated = plan.skippedByPageLimit || mergedBudget.overflowFloors > 0
      outcome.prompt = this.composePrompt(subject, plan, totalPages, coveredPages, allFloors, mergedBudget)
      outcome.ok = true
      logger.info('thread-summary built tid=%{public}s pages=%{public}d/%{public}d floors=%{public}d truncated=%{public}s',
        tid, coveredPages, totalPages, allFloors.length, String(outcome.truncated))
      return outcome
    } catch (e) {
      outcome.message = '全帖总结取数失败：' + ((e as Error).message ?? '未知错误')
      logger.warn('thread-summary failed tid=%{public}s error=%{public}s', tid, formatError(e))
      return outcome
    } finally {
      this.building = false
    }
  }

  /**
   * 拼装完整提示词（信息头 + 楼层正文）。
   *
   * @param subject - 主题标题
   * @param plan - 取数计划
   * @param totalPages - 服务端总页数
   * @param coveredPages - 实际返回楼层的页数
   * @param floors - 按楼号顺序的楼层
   * @param budget - 合并后的预算账本
   * @returns 提示词
   */
  private composePrompt(subject: string, plan: SummaryPagePlan, totalPages: number,
    coveredPages: number, floors: SummaryFloor[], budget: FloorBudget): string {
    const lines: string[] = []
    lines.push('【帖子信息】')
    lines.push('标题：' + subject)
    lines.push('总页数：' + String(totalPages))
    lines.push(composeCoverage(plan, totalPages, coveredPages, floors.length, budget))
    lines.push('')
    lines.push('【楼层内容】')
    lines.push(composeFloorSection(floors))
    return lines.join('\n')
  }

  /**
   * 读取一页楼层：已加载窗口命中即复用，否则走官方 APP HTML 通道。
   *
   * @param token - 会话令牌
   * @param tid - 主题 ID
   * @param page - 页码
   * @param cachedPages - 已加载窗口的页码索引
   * @returns 该页楼层；请求或解析失败时返回空数组（单页失败不中断整帖取数）
   */
  private async loadPageFloors(token: string, tid: string, page: number,
    cachedPages: Map<number, PostInfo[]>): Promise<PostInfo[]> {
    const reused: PostInfo[] | undefined = cachedPages.get(page)
    if (reused !== undefined) {
      return reused
    }
    const fetched: ThreadRawResult = await fetchThreadRaw(token, tid, '', '', String(page))
    if (!fetched.raw) {
      logger.warn('thread-summary page fetch failed tid=%{public}s page=%{public}d error=%{public}s',
        tid, page, fetched.error)
      return []
    }
    const blacklist: Set<string> = appStore.settingsStore.getBlacklistIds()
    const result: ThreadResult = new ThreadResult()
    fillThreadResult(fetched.raw, result, blacklist,
      appStore.settingsStore.getEnabledKeywords(), appStore.settingsStore.getNoteMap())
    applyBlacklistStateToPosts(result.posts, blacklist)
    return result.posts
  }

  /**
   * 预热一页楼层的 BBCode 解析缓存，使后续转纯文本命中缓存、不在主线程解析。
   *
   * 页粒度（约 20 层）刚好让解析缓存的占用可控；失败时静默降级——
   * `getCachedBBNodes` 会在缓存未命中时同步解析。
   *
   * @param posts - 该页楼层
   */
  private async prewarmContents(posts: PostInfo[]): Promise<void> {
    if (posts.length === 0) {
      return
    }
    const contents: string[] = []
    for (let i: number = 0; i < posts.length; i++) {
      if (!posts[i].isInBlackList && posts[i].content.length > 0) {
        contents.push(posts[i].content)
      }
    }
    if (contents.length === 0) {
      return
    }
    try {
      await preWarmBatchAwait(contents)
    } catch (e) {
      logger.warn('thread-summary prewarm failed: %{public}s', formatError(e))
    }
  }

  /**
   * 页间节流等待。
   *
   * @param ms - 等待毫秒数
   */
  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve()
      }, ms)
    })
  }
}

/** 全帖总结取数与组装服务单例。 */
export const threadSummaryService: ThreadSummaryService = new ThreadSummaryService()
