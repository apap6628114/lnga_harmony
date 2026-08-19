/**
 * 保存帖子服务 - 逐页拉取同形状原始 JSON 并写入存档。
 *
 * 保存：按用户选择的页范围逐页调用 fetchThreadRaw（JSON 主通道优先、
 * 失败自动降级 HTML，双通道产物同形状），页间节流（最小间隔），每页经
 * fillThreadResult 校验有效性与统计楼层；任一页拉取失败、返回业务错误或
 * 楼层为空（帖子无效/已删除）时立即终止，不写入不完整数据。进度经
 * savedThreadProgress 发布，由全局指示组件轮询展示。
 *
 * 打开（离线）：getSavedThreadResult 从存档读取指定页的同形状 JSON，交给
 * 当前版本的 fillThreadResult 解释——与在线 getThread 走同一条渲染管线，
 * 表现一致；只看楼主改为客户端过滤，总页数限定为实际保存页数。
 */

import { appStore } from '../store/AppStore'
import { fetchThreadRaw, fillThreadResult } from './api/ThreadApi'
import { savedThreadProgress } from '../common/media/SavedThreadProgress'
import { PostInfo } from '../model/PostInfo'
import { ThreadResult } from '../model/ThreadResult'
import { SavedThread } from '../model/SavedThread'
import { Logger, DOMAIN_SERVICE, formatError } from '../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'SavedThreadService')

/** 相邻两页请求之间的最小间隔（毫秒），对 NGA 服务器保持节流礼貌。 */
const SAVE_PAGE_INTERVAL_MS: number = 300

/**
 * 保存结果。
 */
export class SaveThreadOutcome {
  /** 是否保存成功。 */
  ok: boolean = false
  /** 是否被用户取消（与失败区分，供 UI 特判文案）。 */
  cancelled: boolean = false
  /** 结果/错误文案。 */
  message: string = ''
  /** 成功时保存的页数。 */
  savedPages: number = 0
}

export class SavedThreadService {
  /** 是否正在保存。 */
  private saving: boolean = false
  /** 取消标记：置位后当前页完成后立即终止。 */
  private cancelled: boolean = false

  /**
   * 是否正在执行保存任务。
   */
  get isSaving(): boolean {
    return this.saving
  }

  /**
   * 请求取消当前保存任务。
   */
  cancel(): void {
    this.cancelled = true
  }

  /**
   * 保存帖子的指定页范围。
   *
   * @param tid - NGA 主题 ID
   * @param startPage - 起始页（>=1）
   * @param endPage - 结束页（>= startPage）
   * @returns 保存结果；ok=false 时 message 为终止原因
   */
  async saveThread(tid: string, startPage: number, endPage: number): Promise<SaveThreadOutcome> {
    const outcome: SaveThreadOutcome = new SaveThreadOutcome()
    if (this.saving) {
      outcome.message = '已有保存任务进行中'
      return outcome
    }
    if (!tid || tid.length === 0 || startPage < 1 || endPage < startPage) {
      outcome.message = '保存参数无效'
      return outcome
    }
    const token: string = appStore.auth.token
    if (!appStore.getSession(token)) {
      outcome.message = '请先登录'
      return outcome
    }

    this.saving = true
    this.cancelled = false
    const rawPages: Record<string, Object>[] = []
    const totalPages: number = endPage - startPage + 1
    let done: number = 0
    /** 最后保存楼层的楼号（lou）：每页最后一个楼层（楼号单调递增，最后一页即最大）。 */
    let lastLou: number = 0
    let firstResult: ThreadResult | null = null
    const emptyBlacklist: Set<string> = new Set<string>()
    const emptyKeywords: string[] = []
    const emptyNotes: Record<string, string> = {}
    try {
      savedThreadProgress.show(0, '第 0/' + String(totalPages) + ' 页')
      for (let page: number = startPage; page <= endPage; page++) {
        if (this.cancelled) {
          outcome.cancelled = true
          outcome.message = '保存已取消'
          return outcome
        }
        // 节流：相邻两页之间至少间隔 SAVE_PAGE_INTERVAL_MS
        if (page > startPage) {
          await this.sleep(SAVE_PAGE_INTERVAL_MS)
        }
        savedThreadProgress.show(
          Math.round(done / totalPages * 100),
          '第 ' + String(page) + '/' + String(endPage) + ' 页'
        )
        const fetched = await fetchThreadRaw(token, tid, '', '', String(page))
        if (!fetched.raw) {
          outcome.message = '第 ' + String(page) + ' 页拉取失败：' + (fetched.jsonError || '无法加载该帖子')
          return outcome
        }
        // 用当前解析器校验有效性并统计楼层（保存全量，不应用黑名单/关键词）
        const pageResult: ThreadResult = new ThreadResult()
        fillThreadResult(fetched.raw, pageResult, emptyBlacklist, emptyKeywords, emptyNotes)
        if (!pageResult.ok || pageResult.posts.length === 0) {
          outcome.message = '第 ' + String(page) + ' 页没有楼层，帖子可能已失效'
          return outcome
        }
        if (page === startPage) {
          firstResult = pageResult
        }
        rawPages.push(fetched.raw)
        lastLou = pageResult.posts[pageResult.posts.length - 1].lou
        done++
      }
      if (lastLou <= 0) {
        outcome.message = '帖子无效或已被删除'
        return outcome
      }

      // 最后一页完成：补齐 100% 进度再落盘（此前循环内进度最多到 (total-1)/total）
      savedThreadProgress.show(100, '第 ' + String(endPage) + '/' + String(endPage) + ' 页')

      // 取消复查：最后一页拉取挂起/刚返回期间点击取消，循环已退出不会再检查
      // cancelled，此处落盘前拦截，避免"点了取消却保存成功"
      if (this.cancelled) {
        outcome.cancelled = true
        outcome.message = '保存已取消'
        return outcome
      }

      const thread: SavedThread = new SavedThread()
      thread.tid = tid
      thread.savedAt = Date.now()
      thread.savedPages = totalPages
      thread.rawPages = rawPages
      thread.lastLou = lastLou
      if (firstResult !== null) {
        this.fillMetadata(thread, firstResult)
      }
      await appStore.savedThreadStore.save(thread)

      outcome.ok = true
      outcome.savedPages = totalPages
      outcome.message = String(totalPages) + ' 页 / ' + String(lastLou) + ' 楼'
      return outcome
    } catch (e) {
      outcome.message = '保存失败：' + formatError(e)
      logger.error('saveThread failed tid=%{public}s: %{public}s', tid, formatError(e))
      return outcome
    } finally {
      savedThreadProgress.hide()
      this.saving = false
    }
  }

  /**
   * 从成功结果填充存档元数据（标题/作者/版块/总页数）。
   */
  private fillMetadata(thread: SavedThread, result: ThreadResult): void {
    thread.forumName = result.forumName
    if (result.threadInfo) {
      const info = result.threadInfo
      thread.fid = info.fid
      thread.subject = info.subject
      thread.author = info.author
      thread.authorid = info.authorid
    }
    if (thread.subject.length === 0 && result.posts.length > 0) {
      thread.subject = result.posts[0].subject
      thread.author = result.posts[0].author
      thread.authorid = result.posts[0].authorid
    }
    if (result.pagination.totalPages > 0) {
      thread.totalPages = result.pagination.totalPages
    } else {
      thread.totalPages = Math.max(thread.savedPages, 1)
    }
  }

  /**
   * 简单延时。
   */
  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve()
      }, ms)
    })
  }
}

/** 全局保存帖子服务单例。 */
export const savedThreadService: SavedThreadService = new SavedThreadService()

/**
 * 离线模式取数：从存档读取指定页的同形状 JSON 并按当前解析器解释。
 *
 * 与在线 getThread 的返回形状一致（ThreadResult），ThreadPanel 无需感知
 * 数据来源即可渲染；「只看楼主」在离线模式下由服务端过滤改为客户端过滤；
 * 总页数限定为实际保存页数（超出即视为无更多页）。
 *
 * @param tid - NGA 主题 ID
 * @param page - 页码（从 1 开始）
 * @param blacklist - 黑名单 UID
 * @param keywords - 标题屏蔽关键词
 * @param noteMap - 用户备注表
 * @param authorid - 只看楼主用户 ID（可空）
 * @returns 解释后的帖子详情结果
 */
export async function getSavedThreadResult(tid: string, page: number,
  blacklist: Set<string>, keywords: string[] = [],
  noteMap: Record<string, string> = {},
  authorid: string = ''): Promise<ThreadResult> {
  const result: ThreadResult = new ThreadResult()
  const archive: SavedThread | null = appStore.savedThreadStore.getByTid(tid)
  if (archive === null) {
    result.error = '存档不存在或已被删除'
    return result
  }
  // 只看楼主：离线模式做短路处理——一次性从整个存档筛选楼主楼层并合并为
  // 单页返回（totalPages=1）。与在线服务端过滤相比：不出现"某存档页无楼主
  // 楼层"的空页，楼层跨原存档页连续；嵌套 comments/hotReplies 不过滤。
  if (authorid.length > 0) {
    const allPosts: PostInfo[] = []
    for (let p: number = 1; p <= archive.rawPages.length; p++) {
      const rawPage: Record<string, Object> | null = appStore.savedThreadStore.getRawPage(tid, p)
      if (rawPage === null) {
        continue
      }
      try {
        const pageResult: ThreadResult = new ThreadResult()
        fillThreadResult(rawPage, pageResult, blacklist, keywords, noteMap)
        for (let i = 0; i < pageResult.posts.length; i++) {
          if (String(pageResult.posts[i].authorid) === authorid) {
            allPosts.push(pageResult.posts[i])
          }
        }
        // 用首个成功解析页填充主题元数据（标题/版块/楼主信息）
        if (result.threadInfo === null) {
          result.threadInfo = pageResult.threadInfo
          result.forumName = pageResult.forumName
        }
      } catch (e) {
        logger.warn('saved author-only page parse failed tid=%{public}s page=%{public}d: %{public}s',
          tid, p, formatError(e))
      }
    }
    result.posts = allPosts
    result.pagination.totalPages = 1
    result.pagination.page = 1
    // 空结果不报错：可能确实是存档无该作者楼层，也可能全部被用户关键词/
    // 黑名单过滤——两种情况下在线模式都返回 ok=true 空列表（空页推进），
    // 离线保持同一行为，避免误报"存档中没有该作者的楼层"
    result.ok = true
    return result
  }
  if (page < 1 || page > archive.savedPages) {
    result.error = '超出存档页数'
    return result
  }
  const raw: Record<string, Object> | null = appStore.savedThreadStore.getRawPage(tid, page)
  if (raw === null) {
    result.error = '存档数据缺失'
    return result
  }
  try {
    fillThreadResult(raw, result, blacklist, keywords, noteMap)
    // 注意：不把空 posts 判为「存档数据异常」——用户开启关键词屏蔽时，
    // 匹配楼层被过滤后空页属正常场景（与在线一致）；保存侧已用空关键词
    // 校验过原始页有楼层，页内数据损坏的概率极低且由下方 catch 兜底。
    result.pagination.totalPages = archive.savedPages
    result.pagination.page = page
  } catch (e) {
    logger.warn('getSavedThreadResult failed tid=%{public}s page=%{public}d: %{public}s',
      tid, page, formatError(e))
    result.error = '存档数据无法解析'
  }
  return result
}
