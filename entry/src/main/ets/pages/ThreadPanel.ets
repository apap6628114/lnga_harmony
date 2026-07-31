import { display } from '@kit.ArkUI'
import { common, Context } from '@kit.AbilityKit'
import { motion } from '@kit.MultimodalAwarenessKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { taskpool } from '@kit.ArkTS'

import { appStore } from '../store/AppStore'
import { routerStore, Screen } from '../store/RouterStore'
import { getThread } from '../service/api/ThreadApi'
import { addFavorite, removeFavorite, votePost } from '../service/api/FavoriteApi'
import { getActiveDomain } from '../service/api/MiscApi'
import type { ThreadResult, PostReplyResult } from '../model/ThreadResult'
import type { PostInfo } from '../model/PostInfo'
import type { VoteResult } from '../model/NgaApiResults'
import { getCachedBBNodes } from '../parser/bbcode/BBCodeCache'
import { preWarmPosts } from '../common/utils/PostWarmup'
import { AppColors, ThreadNavMode } from '../common/constants/Constants'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { PostItem } from '../common/components/PostItem'
import { PostInfoDataSource } from '../common/datasource/LazyDataSource'
import { LoadingStateView, ErrorStateView } from '../common/components/PageStateView'
import { floatingLayerStore, FloatingPage } from '../store/FloatingLayerStore'
import { replyManager, ReplyType } from '../common/managers/ReplyManager'
import { withTimeout } from '../common/utils/TimeoutUtils'
import { bbNodesToPlainText } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { TtsMediaMetadata } from '../common/media/TtsAvSessionController'
import { TtsPlayer } from '../common/media/TtsPlayer'
import { shareThread, sharePost } from '../common/utils/ShareUtils'
import { openImageViewer as sharedOpenImageViewer, handleForumLink } from '../common/utils/LinkUtils'
import { ThreadPaginationManager } from '../common/managers/ThreadPaginationManager'
import type { ThreadInfo } from '../model/Thread'
import { Logger, DOMAIN_UI } from '../common/utils/Logger'
import { getActiveAiValidationMessage } from '../service/ai/ActiveAiService'
import { applyBlacklistStateToPosts } from '../common/utils/BlacklistUtils'

const logger = new Logger(DOMAIN_UI, 'ThreadPanel')

enum HoldingHandStatus {
  NOT_HELD = 0,
  LEFT_HAND_HELD = 1,
  RIGHT_HAND_HELD = 2,
  BOTH_HANDS_HELD = 3,
  UNKNOWN_STATUS = 16
}

const LOAD_REPLACE: string = 'replace'
const LOAD_APPEND: string = 'append'
const LOAD_PREPEND: string = 'prepend'
const NAV_BAR_H: number = 44

class FetchPageResult {
  page: number = 0
  result: ThreadResult | null = null
}

@Component
export struct ThreadPanel {
  @State holdingStatus: HoldingHandStatus = appStore.settings.holdingHand as HoldingHandStatus
  @State holdingDetected: boolean = false

  @Prop @Watch('onThreadChanged') threadTid: string = ''
  /** 路由请求的初始页码。 */
  @Prop threadPage: number = 1
  @Prop threadPid: string = ''
  @Prop @Watch('onScrollToPid') navEntryId: number = 0
  @State isLoading: boolean = true
  @State hasError: boolean = false
  @State errorMsg: string = ''
  private postsDataSource: PostInfoDataSource = new PostInfoDataSource()
  @State displayPage: number = 1
  @State isLoadingMore: boolean = false
  @State isLoadingPrevious: boolean = false
  @State authorOnly: boolean = false
  @State favDone: boolean = false
  @State threadSubject: string = '帖子'
  @State threadFid: number = 0
  @State threadAuthorId: string = ''
  @State votedUpPids: Set<string> = new Set()
  @State votedDownPids: Set<string> = new Set()
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @StorageProp('navBarHeight') navBarHeight: number = 0
  /** 黑名单变更版本号。 */
  @StorageProp('blacklistVersion') @Watch('onBlacklistVersionChange') blacklistVersion: number = 0
  @State showMoreMenu: boolean = false
  @State showPagePicker: boolean = false
  private pagePickerTotalPages: number = 0
  private pagePickerCurrentPage: number = 0
  private pagePickerOnSelect: ((page: number) => void) | null = null
  private scroller: Scroller = new Scroller()
  private pageSwitchPending: boolean = false
  /** 尚未交给帖子接口定位的路由目标楼层。 */
  private pendingTargetPid: string = ''
  @State mgr: ThreadPaginationManager = new ThreadPaginationManager()
  private prefetchNextInProgress: boolean = false
  private prefetchPrevInProgress: boolean = false
  @State loadingContentOpacity: number = 0
  private loadingDelayTimer: number = -1

  private holdingCallback: Callback<HoldingHandStatus> = (data: HoldingHandStatus): void => {
    if (this.holdingDetected) {
      this.getUIContext()?.animateTo({ duration: 300, curve: Curve.EaseInOut }, (): void => {
        this.holdingStatus = data
      })
    } else {
      this.holdingStatus = data
      this.holdingDetected = true
    }
    if (appStore.settings.holdingHand !== data) {
      appStore.settingsStore.setHoldingHand(data)
    }
  }

  private startHoldingHandMonitoring(): void {
    if (!appStore.settings.smartGrip) return
    try {
      motion.on('holdingHandChanged', this.holdingCallback)
    } catch (err) {
      logger.error('startHolding fail: %{public}d', (err as BusinessError).code)
    }
  }

  private stopHoldingHandMonitoring(): void {
    try {
      motion.off('holdingHandChanged', this.holdingCallback)
    } catch (err) {
      logger.error('stopHolding fail: %{public}d', (err as BusinessError).code)
    }
  }

  private showProfileCard(uid: string, screenX: number, screenY: number): void {
    const cardW: number = 280
    const cardH: number = 400
    const pad: number = 8
    let posX: number = screenX
    let posY: number = screenY
    try {
      const context = this.getUIContext()
      const displayInfo = display.getDefaultDisplaySync()
      const screenW = context.px2vp(displayInfo.width)
      const screenH = context.px2vp(displayInfo.height)
      posX = Math.max(pad, Math.min(screenX - cardW / 2, screenW - cardW - pad))
      posY = Math.max(pad, Math.min(screenY + pad, screenH - cardH - pad))
    } catch (e) {
      posX = screenX - cardW / 2
      posY = screenY + pad
    }
    floatingLayerStore.profileCardUid = uid
    floatingLayerStore.profileCardX = posX
    floatingLayerStore.profileCardY = posY
    floatingLayerStore.push(FloatingPage.PROFILE_CARD)
  }

  private hasInitiallyLoaded: boolean = false

  aboutToAppear(): void {
    this.hasInitiallyLoaded = true
    const initialPage: number = Math.max(this.threadPage, 1)
    this.pendingTargetPid = this.threadPid
    this.displayPage = initialPage
    if (this.threadTid) {
      this.loadPosts(initialPage, LOAD_REPLACE)
    }
    this.loadPersistedVotes()
    this.startHoldingHandMonitoring()
  }

  aboutToDisappear(): void {
    this.stopHoldingHandMonitoring()
    // 推进分页代际，使未完成的分页/预取异步回调失效，避免回写已销毁页面
    this.mgr.reset()
  }

  private onThreadChanged(): void {
    if (!this.hasInitiallyLoaded) {
      this.hasInitiallyLoaded = true
      return
    }
    this.mgr.reset()
    this.postsDataSource.clear()
    const initialPage: number = Math.max(this.threadPage, 1)
    this.pendingTargetPid = this.threadPid
    this.displayPage = initialPage
    this.isLoading = true
    this.isLoadingMore = false
    this.isLoadingPrevious = false
    this.hasError = false
    this.authorOnly = false
    this.favDone = false
    this.votedUpPids = new Set()
    this.votedDownPids = new Set()
    this.pageSwitchPending = false
    this.loadPosts(initialPage, LOAD_REPLACE)
    this.loadPersistedVotes()
  }

  /**
   * 响应黑名单变化，保留楼层结构并即时刷新内容遮蔽状态。
   */
  private onBlacklistVersionChange(): void {
    applyBlacklistStateToPosts(this.mgr.posts, appStore.settingsStore.getBlacklistIds())
  }

  /**
   * 获取当前可显示的主题标题。
   *
   * @returns 屏蔽作者时返回占位文案，否则返回原主题标题
   */
  private getVisibleThreadSubject(): string {
    if (this.blacklistVersion >= 0 &&
      appStore.settingsStore.isBlacklisted(this.threadAuthorId)) {
      return '该用户已被屏蔽'
    }
    return this.threadSubject
  }

  private async loadPersistedVotes(): Promise<void> {
    if (!appStore.auth.isAuthenticated) return
    const result = await appStore.loadVoteRecord(appStore.auth.uid, this.threadTid)
    this.votedUpPids = result[0]
    this.votedDownPids = result[1]
  }

  private onScrollToPid(): void {
    if (this.threadPid.length > 0 && this.mgr.posts.length > 0) {
      const pidNum: number = parseInt(this.threadPid, 10)
      const idx: number = this.mgr.findPostIndex(pidNum)
      if (idx >= 0) {
        this.scroller.scrollToIndex(idx + 1, true, ScrollAlign.CENTER)
      }
    }
  }

  private buildPageArray(): number[] {
    const arr: number[] = []
    for (let i: number = 1; i <= this.pagePickerTotalPages; i++) {
      arr.push(i)
    }
    return arr
  }

  private async loadPosts(targetPage: number, mode: string): Promise<void> {
    // 在 reset 前保存已有帖子，供跨页引用查找使用
    const prevPosts: PostInfo[] = [...this.mgr.posts]
    if (mode === LOAD_REPLACE) {
      this.mgr.reset()
      this.postsDataSource.clear()
      this.isLoading = true
      this.loadingContentOpacity = 0
      clearTimeout(this.loadingDelayTimer)
      this.loadingDelayTimer = setTimeout((): void => {
        if (this.isLoading) {
          this.getUIContext()?.animateTo({ duration: 150, curve: Curve.EaseInOut }, (): void => {
            this.loadingContentOpacity = 1
          })
        }
      }, 400)
      this.isLoadingMore = false
      this.isLoadingPrevious = false
      this.hasError = false
      this.mgr.loadedPageStart = targetPage
      if (targetPage > 1) {
        this.pageSwitchPending = true
      }
    } else if (mode === LOAD_APPEND) {
      this.isLoadingMore = true
    } else {
      this.isLoadingPrevious = true
    }

    const gen: number = this.mgr.nextGeneration()
    const requestPid: string = mode === LOAD_REPLACE ? this.pendingTargetPid : ''

    try {
      const noteMap: Record<string, string> = appStore.settingsStore.getNoteMap()
      const isNegativeAuthor: boolean = this.authorOnly && this.threadAuthorId !== '' && Number(this.threadAuthorId) <= 0
      const result: ThreadResult = await withTimeout<ThreadResult>(getThread(
        appStore.auth.token, this.threadTid, requestPid,
        this.authorOnly && !isNegativeAuthor ? this.threadAuthorId : '', String(targetPage),
        appStore.settingsStore.getBlacklistIds(), appStore.settingsStore.getEnabledKeywords(),
        noteMap
      ), 15000)

      if (gen !== this.mgr.getGeneration()) return

      if (result.ok) {
        const resolvedPage: number = result.pagination.page > 0 ? result.pagination.page : targetPage
        applyBlacklistStateToPosts(result.posts, appStore.settingsStore.getBlacklistIds())
        if (isNegativeAuthor) {
          result.posts = result.posts.filter((p: PostInfo): boolean => String(p.authorid) === this.threadAuthorId)
        }

        await preWarmPosts(result.posts, false, taskpool.Priority.HIGH)

        this.processPostsQuoteInjection(result.posts, prevPosts)

        if (result.pagination) {
          this.mgr.totalPages = result.pagination.totalPages
        }
        if (result.threadInfo) {
          const info: ThreadInfo = result.threadInfo
          this.threadSubject = unescapeHtml(info.subject) || '帖子'
          this.threadFid = info.fid
          if (info.authorid > 0 || this.threadAuthorId === '') {
            this.threadAuthorId = String(info.authorid)
          }
        }

        if (mode === LOAD_REPLACE) {
          this.mgr.replaceWith(result.posts, resolvedPage, this.mgr.totalPages)
          this.postsDataSource.replaceAll(result.posts)
          this.displayPage = resolvedPage
          this.pageSwitchPending = false
          if (appStore.auth.isAuthenticated) {
            appStore.addBrowseHistoryFromThread(appStore.auth.uid, result, this.threadTid)
          }
          if (requestPid.length > 0) {
            this.pendingTargetPid = ''
            setTimeout((): void => {
              this.onScrollToPid()
            }, 0)
          } else {
            this.scroller.scrollToIndex(1)
          }
        } else if (mode === LOAD_APPEND) {
          const added: PostInfo[] = this.mgr.appendPosts(result.posts, targetPage, this.mgr.totalPages)
          if (added.length > 0) {
            this.postsDataSource.appendAll(added)
          }
        } else {
          const added: PostInfo[] = this.mgr.prependPosts(result.posts, targetPage)
          if (added.length > 0) {
            this.postsDataSource.prependAll(added)
            this.scroller.scrollToIndex(added.length + 1)
          }
        }
        this.triggerPrefetches()
      } else if (mode === LOAD_REPLACE) {
        this.hasError = true
        this.errorMsg = result.error || '加载失败'
        this.mgr.posts = []
        this.postsDataSource.clear()
        this.pageSwitchPending = false
      }
    } catch (e) {
      if (gen !== this.mgr.getGeneration()) return
      if (mode === LOAD_REPLACE) {
        this.hasError = true
        this.errorMsg = (e as Error).message || '加载失败'
        this.mgr.posts = []
        this.postsDataSource.clear()
        this.pageSwitchPending = false
      } else {
        logger.error('loadPosts failed: %{public}s', (e as Error).message)
      }
    }

    clearTimeout(this.loadingDelayTimer)
    this.loadingDelayTimer = -1
    this.loadingContentOpacity = 0
    this.isLoading = false
    this.isLoadingMore = false
    this.isLoadingPrevious = false

  }

  private processPostsQuoteInjection(posts: PostInfo[], prevPosts?: PostInfo[]): void {
    // posts: 需要处理的楼层数组
    // prevPosts: 跳页前已有的帖子（跨页引用用）
    // ── 引用原文注入：为 [b]Reply to [pid][/b] 快速回复格式补充被引用内容
    // Step 1: 备份所有楼层原始内容，防止链式修改后查找错乱
    // 同时包含新加载的 posts 和 mgr 中已有的帖子（跨页引用需要）
    const origByPid: Map<number, string> = new Map()
    const collectToMap = (arr: PostInfo[]): void => {
      for (const p of arr) {
        origByPid.set(p.pid, p.content)            // p.content: 主楼层的正文
        if (p.comments) {
          for (const c of p.comments) {
            origByPid.set(c.pid, c.content)        // c.content: 贴条的正文
          }
        }
      }
    }
    collectToMap(posts)
    collectToMap(this.mgr.posts)
    if (prevPosts) {
      collectToMap(prevPosts)
    }
    // Step 2: 遍历楼层和贴条，对快速回复格式注入引用原文
    const injectReplyQuote = (target: PostInfo): void => {
      if (target.content.startsWith('[quote]')) return
      const headerRegex: RegExp = /\[b\]Reply to \[pid=(\d+),(\d+),(\d+)\]Reply\[\/pid\] Post by \[uid=(\d+)\](.*?)\[\/uid\] \(([^)]+)\)/i
      const headerMatch: RegExpMatchArray | null = target.content.match(headerRegex)
      if (!headerMatch) return
      const refPid: number = parseInt(headerMatch[1], 10)
      const rawContent: string | undefined = origByPid.get(refPid)
      if (!rawContent) return
      let cleaned: string = rawContent
        .replace(/\[b\]Reply to \[pid=.*?\[\/pid\]\s*\[\/b\]/s, '')
        .replace(/\[pid=.*?Reply\[\/pid\]\s*\[b\]Post by.*?\(.*?\):\[\/b\]/s, '')
        .replace(/\[quote\]/g, '')
        .replace(/\[\/quote\]/g, '')
        .replace(/<br\s*\/?>/gi, '')
        .trim()
      if (cleaned.length === 0) return
      const closeBIdx: number = target.content.indexOf('[/b]')
      const replyText: string = closeBIdx >= 0 ? target.content.substring(closeBIdx + 4) : ''
      target.content = `[quote][pid=${headerMatch[1]},${headerMatch[2]},${headerMatch[3]}]Reply[/pid] [b]Post by [uid=${headerMatch[4]}]${headerMatch[5]}[/uid] (${headerMatch[6]}):[/b]\n${cleaned}[/quote]\n<br/><br/>${replyText}`
    }
    // Step 3: 修复 [quote] 格式中被 NGA 截断的引用内容
    const fixTruncatedQuote = (target: PostInfo): void => {
      if (!target.content.startsWith('[quote]')) return
      const pidInQuote: RegExpMatchArray | null = target.content.match(/\[pid=(\d+),(\d+),(\d+)\]/)
      if (!pidInQuote) return
      const refPid: number = parseInt(pidInQuote[1], 10)
      const fullContent: string | undefined = origByPid.get(refPid)
      if (!fullContent) return
      const afterQuote: number = target.content.indexOf('[quote]') + 7
      const headerEnd: number = target.content.indexOf('[/b]', afterQuote)
      const quoteEnd: number = target.content.indexOf('[/quote]', afterQuote)
      if (headerEnd < 0 || quoteEnd < 0) return
      const existingBody: string = target.content.substring(headerEnd + 4, quoteEnd)
        .replace(/<br\s*\/?>/gi, '').trim()
      let cleanedFull: string = fullContent
        .replace(/\[b\]Reply to \[pid=.*?\[\/pid\]\s*\[\/b\]/s, '')
        .replace(/\[pid=.*?Reply\[\/pid\]\s*\[b\]Post by.*?\(.*?\):\[\/b\]/s, '')
        .replace(/\[quote\]/g, '').replace(/\[\/quote\]/g, '')
        .replace(/<br\s*\/?>/gi, '')
        .trim()
      if (cleanedFull.length === 0) return
      if (existingBody === cleanedFull) return
      if (!cleanedFull.startsWith(existingBody)) return
      target.content = target.content.substring(0, headerEnd + 4) + '\n' + cleanedFull + target.content.substring(quoteEnd)
    }
    for (const p of posts) {
      injectReplyQuote(p)
      fixTruncatedQuote(p)
      if (p.comments) {
        for (const c of p.comments) {
          injectReplyQuote(c)
          fixTruncatedQuote(c)
        }
      }
    }
  }

  private triggerPrefetches(): void {
    if (appStore.settings.threadNavMode === ThreadNavMode.PAGE) return
    if (appStore.settings.prefetchPageCount <= 0) return
    this.prefetchNext()
    this.prefetchPrev()
  }

  private lastPrefetchTime: number = 0
  private lastPrefetchPrevTime: number = 0
  private readonly PREFETCH_COOLDOWN_MS: number = 400

  private async prefetchNext(): Promise<void> {
    const now: number = Date.now()
    if (now - this.lastPrefetchTime < this.PREFETCH_COOLDOWN_MS) return
    if (!this.mgr.hasMore) return
    if (this.prefetchNextInProgress) return
    const pagesToFetch: number[] = []
    const maxPrefetchPage: number = Math.min(this.mgr.currentPage + appStore.settings.prefetchPageCount, this.mgr.totalPages)
    this.lastPrefetchTime = now
    for (let p: number = this.mgr.currentPage + 1; p <= maxPrefetchPage; p++) {
      if (!this.mgr.hasPrefetchedPage(p)) {
        pagesToFetch.push(p)
      }
    }
    if (pagesToFetch.length === 0) return

    this.prefetchNextInProgress = true
    const gen: number = this.mgr.getGeneration()
    try {
      const isNegativeAuthor: boolean = this.authorOnly && this.threadAuthorId !== '' && Number(this.threadAuthorId) <= 0
      const noteMap: Record<string, string> = appStore.settingsStore.getNoteMap()
      const promises: Promise<FetchPageResult | null>[] = []
      for (let i = 0; i < pagesToFetch.length; i++) {
        const page: number = pagesToFetch[i]
        promises.push(
          withTimeout<ThreadResult>(getThread(
            appStore.auth.token, this.threadTid, '',
            isNegativeAuthor ? '' : (this.authorOnly ? this.threadAuthorId : ''), String(page),
            appStore.settingsStore.getBlacklistIds(), appStore.settingsStore.getEnabledKeywords(),
            noteMap
          ), 10000).then((r: ThreadResult) => {
            const fpr: FetchPageResult = new FetchPageResult()
            fpr.page = page
            fpr.result = r
            return fpr
          }).catch(() => null)
        )
      }
      const results: (FetchPageResult | null)[] = await Promise.all(promises)
      if (gen !== this.mgr.getGeneration()) return
      for (let i = 0; i < results.length; i++) {
        const item: FetchPageResult | null = results[i]
        if (item === null || item.result === null) continue
        if (item.result.ok) {
          applyBlacklistStateToPosts(item.result.posts, appStore.settingsStore.getBlacklistIds())
          if (isNegativeAuthor) {
            item.result.posts = item.result.posts.filter((p: PostInfo): boolean => String(p.authorid) === this.threadAuthorId)
          }
          this.processPostsQuoteInjection(item.result.posts)
          this.mgr.setPrefetchedPage(item.page, item.result.posts, item.result.pagination.totalPages)
          preWarmPosts(item.result.posts, false, taskpool.Priority.MEDIUM).catch(() => {})
        }
      }
    } catch (e) {
      // silently fall back to on-demand load
    } finally {
      this.prefetchNextInProgress = false
    }
  }

  private async prefetchPrev(): Promise<void> {
    if (appStore.settings.prefetchPageCount <= 0) return
    const now: number = Date.now()
    if (now - this.lastPrefetchPrevTime < this.PREFETCH_COOLDOWN_MS) return
    const defaultPage: number = this.mgr.loadedPageStart - 1
    if (defaultPage < 1) return
    if (this.prefetchPrevInProgress) return

    let targetPage: number = defaultPage
    if (this.mgr.prefetchedPrevPage === targetPage) {
      targetPage--
    }
    if (targetPage < 1) return

    this.lastPrefetchPrevTime = now
    this.prefetchPrevInProgress = true
    const gen: number = this.mgr.getGeneration()
    let ok: boolean = false
    const isNegativeAuthorPrev: boolean = this.authorOnly && this.threadAuthorId !== '' && Number(this.threadAuthorId) <= 0
    try {
      const noteMap: Record<string, string> = appStore.settingsStore.getNoteMap()
      const result: ThreadResult = await withTimeout<ThreadResult>(getThread(
        appStore.auth.token, this.threadTid, '',
        isNegativeAuthorPrev ? '' : (this.authorOnly ? this.threadAuthorId : ''), String(targetPage),
        appStore.settingsStore.getBlacklistIds(), appStore.settingsStore.getEnabledKeywords(),
        noteMap
      ), 10000)
      if (gen !== this.mgr.getGeneration()) return
      if (result.ok) {
        applyBlacklistStateToPosts(result.posts, appStore.settingsStore.getBlacklistIds())
        if (isNegativeAuthorPrev) {
          result.posts = result.posts.filter((p: PostInfo): boolean => String(p.authorid) === this.threadAuthorId)
        }
        ok = true
        try {
            await preWarmPosts(result.posts, false, taskpool.Priority.MEDIUM)
        } catch (e) {
          // 预热失败不影响 posts 存储
        }
        this.processPostsQuoteInjection(result.posts)
        this.mgr.prefetchedPrevPosts = result.posts
        this.mgr.prefetchedPrevPage = targetPage
      }
    } catch (e) {
      // silently fall back to on-demand load
    } finally {
      this.prefetchPrevInProgress = false
    }

    if (ok) {
      // pipeline 由 tryLoadPrev 提交后触发，无需在此串联
    }
  }

  private tryLoadNext(): void {
    if (appStore.settings.threadNavMode === ThreadNavMode.PAGE) return
    if (this.isLoadingMore || !this.mgr.hasMore) return
    const nextPage: number = this.mgr.currentPage + 1
    if (this.mgr.hasPrefetchedPage(nextPage)) {
      const added: PostInfo[] = this.mgr.commitPrefetchedPage(nextPage)
      if (added.length > 0) {
        this.postsDataSource.appendAll(added)
      }
      this.prefetchNext()
    } else {
      this.loadPosts(nextPage, LOAD_APPEND)
    }
  }

  private tryLoadPrev(): void {
    if (appStore.settings.threadNavMode === ThreadNavMode.PAGE) return
    if (this.isLoadingPrevious || this.pageSwitchPending) return
    if (this.mgr.loadedPageStart <= 1) return
    const prevPage: number = this.mgr.loadedPageStart - 1
    if (this.mgr.isPrefetchedPrevReady()) {
      const added: PostInfo[] = this.mgr.commitPrefetchedPrev()
      if (added.length > 0) {
        this.postsDataSource.prependAll(added)
        this.scroller.scrollToIndex(added.length + 1)
      }
      this.prefetchPrev()
    } else {
      this.loadPosts(prevPage, LOAD_PREPEND)
    }
  }

  private async handleReplySend(text: string, isAnony: boolean): Promise<void> {
    try {
      const result: PostReplyResult = await replyManager.send(text, isAnony)
      if (result.ok) {
        const isComment: boolean = replyManager.type === ReplyType.COMMENT
        appStore.showToast(isComment ? '贴条成功' : '回复成功')
        if (this.mgr.currentPage >= this.mgr.totalPages) {
          await this.loadPosts(1, LOAD_REPLACE)
        }
      } else {
        appStore.showToast(result.error || '操作失败')
      }
    } catch (e) {
      appStore.showToast((e as Error).message || '操作失败')
    }
  }

  private async handleEditSend(text: string, isAnony: boolean): Promise<void> {
    try {
      const result: PostReplyResult = await replyManager.send(text, isAnony)
      if (result.ok) {
        appStore.showToast('编辑成功')
        await this.loadPosts(1, LOAD_REPLACE)
      } else {
        appStore.showToast(result.error || '编辑失败')
      }
    } catch (e) {
      appStore.showToast((e as Error).message || '编辑失败')
    }
  }

  private async handleFavorite(): Promise<void> {
    if (this.favDone || !this.threadTid) return
    try {
      const result = await addFavorite(appStore.auth.token, Number(this.threadTid), 0)
      if (result.ok) {
        this.favDone = true
        appStore.showToast('收藏成功')
      } else {
        appStore.showToast(result.error || '收藏失败')
      }
    } catch (e) {
      appStore.showToast('收藏失败')
    }
  }

  private async handleUnfavorite(): Promise<void> {
    if (!this.favDone || !this.threadTid) return
    try {
      const result = await removeFavorite(appStore.auth.token, Number(this.threadTid), 0, 1)
      if (result.ok) {
        this.favDone = false
        appStore.showToast('已取消收藏')
      } else {
        appStore.showToast(result.error || '取消收藏失败')
      }
    } catch (e) {
      appStore.showToast('取消收藏失败')
    }
  }

  private async handleVote(post: PostInfo, value: number): Promise<void> {
    if (!appStore.auth.isAuthenticated) {
      appStore.showToast('请先登录')
      return
    }
    const pidKey: string = String(post.pid)
    const wasUp: boolean = this.votedUpPids.has(pidKey)
    const wasDown: boolean = this.votedDownPids.has(pidKey)
    const result: VoteResult = await votePost(appStore.auth.token, Number(this.threadTid), post.pid, value)
    if (result.ok) {
      const upPids = new Set(this.votedUpPids)
      const downPids = new Set(this.votedDownPids)
      if (result.message.indexOf('取消了对这个帖子的支持') >= 0) {
        upPids.delete(pidKey)
      } else if (result.message.indexOf('取消了对这个帖子的反对') >= 0) {
        downPids.delete(pidKey)
      } else if (result.message.indexOf('表示支持') >= 0) {
        upPids.add(pidKey)
        downPids.delete(pidKey)
      } else if (result.message.indexOf('表示反对') >= 0) {
        downPids.add(pidKey)
        upPids.delete(pidKey)
      }
      this.votedUpPids = upPids
      this.votedDownPids = downPids
      appStore.saveVoteRecord(appStore.auth.uid, this.threadTid, upPids, downPids)
      const isUp: boolean = upPids.has(pidKey)
      const isDown: boolean = downPids.has(pidKey)
      const scoreDelta: number = (isUp ? 1 : 0) - (wasUp ? 1 : 0)
      const score2Delta: number = (isDown ? 1 : 0) - (wasDown ? 1 : 0)
      const voteIdx: number = this.mgr.updateVoteScore(post.pid, scoreDelta, score2Delta)
      if (voteIdx >= 0) {
        this.postsDataSource.updateAt(voteIdx, this.mgr.posts[voteIdx])
      }
      if (result.message.length > 0) {
        appStore.showToast(result.message)
      }
    } else {
      appStore.showToast(result.error || '操作失败')
    }
  }

  private openImageViewer(urls: string[], index: number): void {
    sharedOpenImageViewer(urls, index)
  }

  private handleLinkClick(href: string): void {
    handleForumLink(href, this.getUIContext().getHostContext() as common.UIAbilityContext, (uid: string) => {
      this.showProfileCard(uid, 200, 200)
    })
  }

  build() {
    Stack() {
      Column() {

      if (this.isLoading) {
        Column() {
          Column() {
            LoadingStateView()
          }.opacity(this.loadingContentOpacity)
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .padding({ top: NAV_BAR_H + this.statusBarHeight })
        .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
      } else if (this.hasError) {
        Column() {
          ErrorStateView({ msg: this.errorMsg, onRetry: () => this.loadPosts(1, LOAD_REPLACE) })
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .padding({ top: NAV_BAR_H + this.statusBarHeight })
        .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
      } else {
        List({ scroller: this.scroller }) {
          ListItem() {
            Row().width('100%').height(NAV_BAR_H + this.statusBarHeight)
          }
          LazyForEach(this.postsDataSource, (post: PostInfo) => {
            ListItem() {
              PostItem({
                post: post,
                isVotedUp: this.votedUpPids.has(String(post.pid)),
                isVotedDown: this.votedDownPids.has(String(post.pid)),
                holdingHand: this.holdingStatus,
                onImageClick: (urls: string[], index: number): void => {
                  this.openImageViewer(urls, index)
                },
                onLinkClick: (href: string): void => {
                  this.handleLinkClick(href)
                },
                onVideoClick: (url: string): void => {
                  this.handleLinkClick(url)
                },
                onProfileClick: (uid: string, screenX: number, screenY: number): void => {
                  this.showProfileCard(uid, screenX, screenY)
                },
                onVote: (p: PostInfo, value: number): void => {
                  this.handleVote(p, value)
                },
                onReply: (p: PostInfo): void => {
                  replyManager.startFloorReply(p, Number(this.threadTid), this.threadFid, this.mgr.currentPage)
                  floatingLayerStore.replyDialogTitle = replyManager.dialogTitle
                  floatingLayerStore.replyOnSend = (text: string, isAnony: boolean): Promise<void> => {
                    return this.handleReplySend(text, isAnony)
                  }
                  floatingLayerStore.editMode = false
                  floatingLayerStore.push(FloatingPage.REPLY_DIALOG)
                },
                onEdit: (p: PostInfo): void => {
                  replyManager.startEdit(p, Number(this.threadTid), this.threadFid)
                  floatingLayerStore.replyDialogTitle = replyManager.dialogTitle
                  floatingLayerStore.editMode = true
                  floatingLayerStore.editInitialContent = unescapeHtml(p.content).replace(/<br\s*\/?>/gi, '\n')
                  floatingLayerStore.replyOnSend = (_text: string, _isAnony: boolean): Promise<void> => {
                    return this.handleEditSend(_text, _isAnony)
                  }
                  floatingLayerStore.push(FloatingPage.REPLY_DIALOG)
                },
                onShare: (p: PostInfo): void => {
                  let hostCtx: Context | undefined = this.getUIContext().getHostContext()
                  if (hostCtx !== undefined) {
                    let ctx: Context = hostCtx
                    sharePost(ctx, p, this.threadSubject)
                  }
                },
                onSummarize: (p: PostInfo): void => {
                  const aiValidationMessage: string = getActiveAiValidationMessage()
                  if (aiValidationMessage.length > 0) {
                    appStore.showToast(aiValidationMessage)
                    return
                  }
                  const plainText: string = bbNodesToPlainText(getCachedBBNodes(p.content))
                  if (plainText.trim().length === 0) {
                    appStore.showToast('该楼层没有可总结的内容')
                    return
                  }
                  let prompt: string = ''
                  prompt += '【帖子信息】\n'
                  prompt += '标题：' + this.threadSubject + '\n'
                  prompt += '楼层：#' + p.lou.toString() + '  作者：' + p.author + '\n\n'
                  prompt += '【正文内容】\n'
                  prompt += plainText
                  TtsPlayer.stop()
                  this.getUIContext().getRouter().pushUrl({
                    url: 'pages/ai/AiChatPage',
                    params: {
                      initialPrompt: prompt,
                      title: 'AI 帖子总结',
                      scenario: 'post_summary'
                    }
                  })
                },
                onReadAloud: (p: PostInfo): void => {
                  const plainText: string = bbNodesToPlainText(getCachedBBNodes(p.content))
                  if (plainText.trim().length === 0) {
                    appStore.showToast('该楼层没有可朗读的内容')
                    return
                  }
                  const floorName: string = p.lou === 0 ? '楼主' : '第' + p.lou.toString() + '楼'
                  const metadata: TtsMediaMetadata = {
                    assetId: 'thread-' + this.threadTid + '-post-' + p.pid.toString(),
                    title: this.threadSubject.trim().length > 0 ? this.threadSubject : '帖子朗读',
                    artist: p.author,
                    album: floorName
                  }
                  TtsPlayer.speak(plainText, p.pid, true, metadata)
                },
                isTopicAuthor: String(post.authorid) === this.threadAuthorId,
                isOwnPost: appStore.auth.isAuthenticated && String(post.authorid) === appStore.auth.uid,
              })
            }
          }, (post: PostInfo) => String(post.pid))
          ListItem() {
            Column() {
              Row() {
                if (this.isLoadingMore) {
                  LoadingProgress().width(16).height(16).color(AppColors.textTertiary)
                  Text('加载更多...').fontSize(13).fontColor(AppColors.textTertiary).margin({ left: 8 })
                } else if (this.mgr.currentPage >= this.mgr.totalPages && this.mgr.posts.length > 0) {
                  Text('已加载全部回复').fontSize(13).fontColor(AppColors.textTertiary)
                }
              }.width('100%').justifyContent(FlexAlign.Center)
            }.width('100%').height(NAV_BAR_H).justifyContent(FlexAlign.Center)
          }
        }
        .width('100%').layoutWeight(1)
        .scrollBar(BarState.Off)
        .divider({ strokeWidth: 0.5, color: AppColors.separator })
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(6)
        .maintainVisibleContentPosition(true)
        .onScrollIndex((start: number, end: number, center: number): void => {
          this.displayPage = this.mgr.getDisplayPage(center - 1)
          const total: number = this.postsDataSource.totalCount()
          if (end >= total - 3 && total > 0) {
            this.tryLoadNext()
          }
          if (start <= 3 && total > 0) {
            this.tryLoadPrev()
          }
        })
        .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
      }
    }
    .width('100%').height('100%')

      PanelNavBar({
        title: this.getVisibleThreadSubject(),
        rightIcon: $r('app.media.icon_more'),
        onRightClick: (): void => {
          this.showMoreMenu = !this.showMoreMenu
        }
      })
        .width('100%').position({ x: 0, y: 0 })

      Row() {
        if (this.mgr.totalPages > 1) {
          Row() {
            if (this.mgr.totalPages === 2) {
              Stack() {
                Text('1').fontSize(14).fontColor(this.displayPage === 1 ? AppColors.primary : AppColors.textSecondary)
                  .fontWeight(this.displayPage === 1 ? FontWeight.Bold : FontWeight.Regular)
                if (this.displayPage === 1) {
                  Text('•').fontSize(10).fontColor(AppColors.primary)
                    .position({ x: '50%', y: 22 }).translate({ x: '-50%' })
                }
              }.width(24).height(28).onClick(() => this.loadPosts(1, LOAD_REPLACE))
              Divider().vertical(true).height(16).color(AppColors.dividerStrong)
              Stack() {
                Text('2').fontSize(14).fontColor(this.displayPage === 2 ? AppColors.primary : AppColors.textSecondary)
                  .fontWeight(this.displayPage === 2 ? FontWeight.Bold : FontWeight.Regular)
                if (this.displayPage === 2) {
                  Text('•').fontSize(10).fontColor(AppColors.primary)
                    .position({ x: '50%', y: 22 }).translate({ x: '-50%' })
                }
              }.width(24).height(28).onClick(() => this.loadPosts(2, LOAD_REPLACE))
            } else if (this.displayPage === 1) {
              Stack() {
                Text('1').fontSize(14).fontColor(AppColors.primary).fontWeight(FontWeight.Bold)
                Text('•').fontSize(10).fontColor(AppColors.primary)
                  .position({ x: '50%', y: 22 }).translate({ x: '-50%' })
              }.width(24).height(28).onClick(() => this.loadPosts(1, LOAD_REPLACE))
              Divider().vertical(true).height(16).color(AppColors.dividerStrong)
              Stack() {
                Text('2').fontSize(14).fontColor(AppColors.textSecondary).fontWeight(FontWeight.Regular)
              }.width(24).height(28).onClick(() => this.loadPosts(2, LOAD_REPLACE))
            } else if (this.displayPage === this.mgr.totalPages) {
              Stack() {
                Text(String(this.mgr.totalPages - 1)).fontSize(14).fontColor(AppColors.textSecondary)
                  .fontWeight(FontWeight.Regular)
              }.width(24).height(28).onClick(() => this.loadPosts(this.mgr.totalPages - 1, LOAD_REPLACE))
              Divider().vertical(true).height(16).color(AppColors.dividerStrong)
              Stack() {
                Text(String(this.mgr.totalPages)).fontSize(14).fontColor(AppColors.primary)
                  .fontWeight(FontWeight.Bold)
                Text('•').fontSize(10).fontColor(AppColors.primary)
                  .position({ x: '50%', y: 22 }).translate({ x: '-50%' })
              }.width(24).height(28).onClick(() => this.loadPosts(this.mgr.totalPages, LOAD_REPLACE))
            } else {
              Stack() {
                Text(String(this.displayPage - 1)).fontSize(14).fontColor(AppColors.textSecondary)
                  .fontWeight(FontWeight.Regular)
              }.width(24).height(28).onClick(() => this.loadPosts(this.displayPage - 1, LOAD_REPLACE))
              Divider().vertical(true).height(16).color(AppColors.dividerStrong)
              Stack() {
                Text(String(this.displayPage)).fontSize(14).fontColor(AppColors.primary)
                  .fontWeight(FontWeight.Bold)
                Text('•').fontSize(10).fontColor(AppColors.primary)
                  .position({ x: '50%', y: 22 }).translate({ x: '-50%' })
              }.width(24).height(28).onClick(() => this.loadPosts(this.displayPage, LOAD_REPLACE))
              Divider().vertical(true).height(16).color(AppColors.dividerStrong)
              Stack() {
                Text(String(this.displayPage + 1)).fontSize(14).fontColor(AppColors.textSecondary)
                  .fontWeight(FontWeight.Regular)
              }.width(24).height(28).onClick(() => this.loadPosts(this.displayPage + 1, LOAD_REPLACE))
            }
            if (this.mgr.totalPages > 2) {
              Divider().vertical(true).height(16).color(AppColors.dividerStrong)
              Text('到').fontSize(13).fontColor(AppColors.primary).padding({ left: 4, right: 2 })
                .onClick(() => {
                  this.pagePickerCurrentPage = this.displayPage
                  this.pagePickerTotalPages = this.mgr.totalPages
                  this.pagePickerOnSelect = (page: number): void => {
                    if (page !== this.displayPage) {
                      this.loadPosts(page, LOAD_REPLACE)
                    }
                  }
                  this.showPagePicker = true
                })
            }
          }
          .padding({ left: 8, right: 8, top: 0, bottom: 0 })
          .height(40).alignItems(VerticalAlign.Center)
          .backgroundColor(Color.Transparent).borderRadius(20)
          .shadow({ radius: 16, color: AppColors.shadow, offsetY: 4 })
          .backgroundEffect({
            radius: 10,
            saturation: 1.15,
            brightness: 1.08,
            color: AppColors.frostGlass
          })
          .margin({ right: 8 })
        }

        Stack() {
          Image($r('app.media.icon_reply'))
            .width(20).height(20).fillColor(AppColors.primary)
        }
        .width(40).height(40).borderRadius(20)
        .backgroundColor(Color.Transparent)
        .shadow({ radius: 16, color: AppColors.shadow, offsetY: 4 })
        .backgroundEffect({
          radius: 10,
          saturation: 1.15,
          brightness: 1.08,
          color: AppColors.frostGlass
        })
        .onClick(() => {
          replyManager.startThreadReply(Number(this.threadTid), this.threadFid)
          floatingLayerStore.replyDialogTitle = replyManager.dialogTitle
          floatingLayerStore.editMode = false
          floatingLayerStore.replyOnSend = (text: string, isAnony: boolean): Promise<void> => {
            return this.handleReplySend(text, isAnony)
          }
          floatingLayerStore.push(FloatingPage.REPLY_DIALOG)
        })
      }
      .width('100%').padding({ left: 16, right: 16, bottom: 16 + this.navBarHeight }).alignItems(VerticalAlign.Center)
      .justifyContent(this.holdingStatus === HoldingHandStatus.LEFT_HAND_HELD ? FlexAlign.Start : FlexAlign.End)

      if (this.showMoreMenu) {
        Stack() {
          Column() {}.width('100%').height('100%').onClick(() => { this.showMoreMenu = false })

          Column() {
            Column() {
              Text(this.favDone ? '取消收藏' : '收藏帖子').fontSize(15)
                .fontColor(AppColors.textPrimary)
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .width('100%')
                .onClick(() => {
                  if (this.favDone) {
                    this.handleUnfavorite()
                  } else {
                    this.handleFavorite()
                  }
                  this.showMoreMenu = false
                })
            }
            .width('100%')

            Divider().width('100%').color(AppColors.separator)

            Column() {
              Text('只看楼主').fontSize(15)
                .fontColor(this.authorOnly ? AppColors.primary : AppColors.textPrimary)
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .width('100%')
                .onClick(() => {
                  this.authorOnly = !this.authorOnly
                  this.showMoreMenu = false
                  this.loadPosts(1, LOAD_REPLACE)
                })
            }
            .width('100%')

            Divider().width('100%').color(AppColors.separator)

            Column() {
              Text('从网页打开').fontSize(15)
                .fontColor(AppColors.textPrimary)
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .width('100%')
                .onClick(() => {
                  this.showMoreMenu = false
                  const baseUrl: string = getActiveDomain()
                  const threadUrl: string = baseUrl + '/read.php?tid=' + this.threadTid
                  routerStore.navigateActivity(Screen.webview(threadUrl))
                })
            }
            .width('100%')

            Divider().width('100%').color(AppColors.separator)

            Column() {
              Text('分享帖子').fontSize(15)
                .fontColor(AppColors.textPrimary)
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .width('100%')
                .onClick(() => {
                  this.showMoreMenu = false
                  let hostCtx: Context | undefined = this.getUIContext().getHostContext()
                  if (hostCtx !== undefined) {
                    let ctx: Context = hostCtx
                    shareThread(ctx, Number(this.threadTid), this.threadSubject)
                  }
                })
            }
            .width('100%')
          }
          .width(150)
          .backgroundColor(AppColors.bgTertiary)
          .borderRadius(10)
          .shadow({ radius: 16, color: AppColors.shadowLight, offsetY: 4 })
          .position({ top: this.statusBarHeight + NAV_BAR_H + 6, right: 16 })
        }
        .width('100%').height('100%')
        .transition(TransitionEffect.OPACITY.animation({ duration: 150 }))
      }

      if (this.showPagePicker) {
        Stack() {
          Column().width('100%').height('100%').onClick(() => { this.showPagePicker = false })
          Column() {
            Text('选择页面').fontSize(14).fontColor(AppColors.textPrimary).fontWeight(FontWeight.Bold)
              .padding({ top: 12, bottom: 8 }).width('100%').textAlign(TextAlign.Center)
            Divider().color(AppColors.separator)
            Scroll() {
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Start }) {
                ForEach(this.buildPageArray(), (p: number) => {
                  Text(String(p)).fontSize(15)
                    .fontColor(p === this.pagePickerCurrentPage ? AppColors.primary : AppColors.textPrimary)
                    .fontWeight(p === this.pagePickerCurrentPage ? FontWeight.Bold : FontWeight.Regular)
                    .width(40).height(40).textAlign(TextAlign.Center).borderRadius(8)
                    .backgroundColor(p === this.pagePickerCurrentPage ? AppColors.primaryLight : Color.Transparent)
                    .onClick(() => {
                      if (this.pagePickerOnSelect) {
                        this.pagePickerOnSelect(p)
                      }
                      this.showPagePicker = false
                    })
                }, (p: number) => String(p))
              }.width('100%')
            }.width('100%').height(120).align(Alignment.TopStart)
          }
          .width(220).height(180).padding({ left: 10, right: 10 })
          .backgroundColor(AppColors.bgTertiary).borderRadius(12)
          .shadow({ radius: 16, color: AppColors.shadow, offsetY: 4 })
          .position(
            this.holdingStatus === HoldingHandStatus.LEFT_HAND_HELD
              ? { bottom: 64 + this.navBarHeight, left: 16 }
              : { bottom: 64 + this.navBarHeight, right: 16 }
          )
        }
        .width('100%').height('100%')
        .transition(TransitionEffect.OPACITY.animation({ duration: 150 }))
      }

    }
    .width('100%').height('100%').backgroundColor(AppColors.bg).alignContent(Alignment.BottomEnd)
    .id('threadPanelRoot')
  }
}
