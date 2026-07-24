/**
 * 主题列表面板 - 统一版, 所有断点共用
 * 第二列(板块堆栈) 或 第三列(活动栈) 均可使用
 * 点击主题通过 routerStore 导航
 */

import { motion } from '@kit.MultimodalAwarenessKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { appStore } from '../store/AppStore'
import { routerStore, Screen } from '../store/RouterStore'
import { withTimeout } from '../common/utils/TimeoutUtils'
import { getTopicList, createTopicListParams } from '../service/api/ForumApi'
import { removeFavorite } from '../service/api/FavoriteApi'
import type { TopicListParams } from '../service/api/ForumApi'
import type { TopicListResult } from '../model/NgaApiResults'
import { AppColors, FONT_COLORS, SORT_MODES, SortMode, BreakpointType } from '../common/constants/Constants'
import { formatTime } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { ThreadDataSource } from '../common/datasource/LazyDataSource'
import { LoadingStateView, ErrorStateView, EmptyStateView } from '../common/components/PageStateView'
import { AnonymousName } from '../common/components/AnonymousName'
import { TopicPaginationManager } from '../common/managers/TopicPaginationManager'
import { Logger, DOMAIN_UI } from '../common/utils/Logger'

const logger = new Logger(DOMAIN_UI, 'TopicListPanel')

enum HoldingHandStatus {
  NOT_HELD = 0,
  LEFT_HAND_HELD = 1,
  RIGHT_HAND_HELD = 2,
  BOTH_HANDS_HELD = 3,
  UNKNOWN_STATUS = 16
}

/** 预加载页面临时结果 — startPrefetch 内部收集用 */
class PrefetchPageResult {
  page: number = 0
  threads: object[] = []
  totalPages: number = 0
}

@Component
export struct TopicListPanel {
  @Prop @Watch('onBoardChanged') boardFid: number = 0
  @Prop boardName: string = ''
  @Prop boardStid: string = ''
  @Prop isFavorites: boolean = false
  @Prop authorid: string = ''
  @Prop favor: string = ''
  @Prop searchKey: string = ''
  @Prop author: string = ''
  @Prop searchpost: string = ''
  @Prop showBack: boolean = true
  @State holdingStatus: HoldingHandStatus = appStore.settings.holdingHand as HoldingHandStatus
  @State holdingDetected: boolean = false
  @State isLoading: boolean = true
  @State isLoadingMore: boolean = false
  @State hasError: boolean = false
  @State errorMsg: string = ''
  @State mgr: TopicPaginationManager = new TopicPaginationManager()
  private threadsDataSource: ThreadDataSource = new ThreadDataSource()

  @State sortMode: string = 'latest'
  @State showSort: boolean = true
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @StorageProp('unreadNotiCount') unreadNotiCount: number = 0
  @StorageProp('navBarHeight') navBarHeight: number = 0
  @State loadingContentOpacity: number = 0
  private loadingDelayTimer: number = -1

  private scroller: Scroller = new Scroller()

  private twentyFourCache: object[] = []

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

  aboutToAppear(): void {
    this.showSort = !this.authorid && !this.favor
    this.loadTopics(1)
    appStore.refreshUnreadCount()
    this.startHoldingHandMonitoring()
  }

  aboutToDisappear(): void {
    this.stopHoldingHandMonitoring()
  }

  private onBoardChanged(): void {
    this.mgr.reset()
    this.threadsDataSource.clear()
    this.hasError = false
    this.sortMode = 'latest'
    this.showSort = !this.authorid && !this.favor
    this.loadTopics(1)
    appStore.refreshUnreadCount()
  }

  private buildTopicParams(page: number): TopicListParams {
    const params: TopicListParams = createTopicListParams()
    params.page = String(page)
    if (this.isFavorites || this.favor) {
      params.favor = '1'
    } else {
      if (this.boardFid) params.fid = String(this.boardFid)
      if (this.boardStid) params.stid = this.boardStid
    }
    if (this.authorid) params.authorid = this.authorid
    if (this.searchKey) params.key = this.searchKey
    if (this.author) params.author = this.author
    if (this.searchpost) params.searchpost = this.searchpost
    if (this.showSort) {
      if (this.sortMode === 'recommend') {
        params.recommend = '1'
      } else if (this.sortMode === 'hot') {
        params.twentyfour = '1'
      }
    }
    return params
  }


  private async loadTwentyFourTopics(): Promise<void> {
    this.hasError = false
    this.mgr.clearPrefetchedPages()
    const gen: number = this.mgr.getGeneration()

    try {
      const pages: number[] = [1, 2, 3, 4, 5]
      const promises: Promise<TopicListResult>[] = []
      for (let i = 0; i < pages.length; i++) {
        const p: number = pages[i]
        const params: TopicListParams = this.buildTopicParams(p)
        promises.push(withTimeout<TopicListResult>(getTopicList(appStore.auth.token, params, appStore.settingsStore.getBlacklistIds(), appStore.settingsStore.getEnabledKeywords()), 15000))
      }
      const results: TopicListResult[] = await Promise.all(promises)

      if (gen !== this.mgr.getGeneration()) return

      let curTime: number = 0
      const allThreads: object[] = []

      for (let i = 0; i < results.length; i++) {
        const result: TopicListResult = results[i]
        if (result.ok && result.data) {
          if (curTime === 0) {
            curTime = result.data.curTime
          }
          const list: object[] = result.data.threadPageList
          for (let j = 0; j < list.length; j++) {
            allThreads.push(list[j])
          }
        }
      }

      const filtered: object[] = []
      for (let i = 0; i < allThreads.length; i++) {
        const t: object = allThreads[i]
        const postDate: number = Number((t as Record<string, Object>)['postDate'] ?? 0)
        if (curTime - postDate <= 24 * 60 * 60) {
          filtered.push(t)
        }
      }

      filtered.sort((a: object, b: object): number => {
        return Number((b as Record<string, Object>)['replies'] ?? 0) - Number((a as Record<string, Object>)['replies'] ?? 0)
      })

      const capped: object[] = []
      const capLen: number = filtered.length > 50 ? 50 : filtered.length
      for (let i = 0; i < capLen; i++) {
        capped.push(filtered[i])
      }

      this.twentyFourCache = capped

      const firstPageLen: number = capped.length > 20 ? 20 : capped.length
      const firstPage: object[] = []
      for (let i = 0; i < firstPageLen; i++) {
        firstPage.push(capped[i])
      }
      this.mgr.replaceWith(firstPage, 1, capped.length > 0 ? Math.ceil(capped.length / 20) : 0)
      this.threadsDataSource.replaceAll(firstPage)
    } catch (e) {
      this.hasError = true
      this.errorMsg = (e as Error).message || '加载失败'
    } finally {
      clearTimeout(this.loadingDelayTimer)
      this.loadingDelayTimer = -1
      this.loadingContentOpacity = 0
      this.isLoading = false
      this.isLoadingMore = false
    }
  }

  private loadMoreTwentyFourTopics(page: number): void {
    this.isLoadingMore = true

    const end: number = page * 20
    const count: number = end > this.twentyFourCache.length ? this.twentyFourCache.length : end

    const existingTids: Set<number> = new Set()
    for (let i = 0; i < this.mgr.threads.length; i++) {
      const tid: number = Number((this.mgr.threads[i] as Record<string, Object>)['tid'] ?? 0)
      if (tid) existingTids.add(tid)
    }

    const newItems: object[] = []
    for (let i = 0; i < count; i++) {
      const t: object = this.twentyFourCache[i]
      const tid: number = Number((t as Record<string, Object>)['tid'] ?? 0)
      if (!existingTids.has(tid)) {
        newItems.push(t)
        existingTids.add(tid)
      }
    }

    if (newItems.length > 0) {
      const arr: object[] = []
      for (let i = 0; i < this.mgr.threads.length; i++) arr.push(this.mgr.threads[i])
      for (let i = 0; i < newItems.length; i++) arr.push(newItems[i])
      this.mgr.threads = arr
      this.threadsDataSource.appendAll(newItems)
    }

    this.mgr.currentPage = page
    this.isLoadingMore = false
  }

  private async loadTopics(page: number): Promise<void> {
    const gen: number = this.mgr.nextGeneration()
    if (page === 1) {
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
      this.hasError = false
      this.mgr.clearPrefetchedPages()
      if (this.sortMode === 'hot') {
        await this.loadTwentyFourTopics()
        return
      }
    } else {
      this.isLoadingMore = true
      if (this.sortMode === 'hot') {
        this.loadMoreTwentyFourTopics(page)
        return
      }
    }

    const params: TopicListParams = this.buildTopicParams(page)

    try {
      const result: TopicListResult = await withTimeout<TopicListResult>(getTopicList(appStore.auth.token, params, appStore.settingsStore.getBlacklistIds(), appStore.settingsStore.getEnabledKeywords()), 15000)
      if (gen !== this.mgr.getGeneration()) return
      if (result.ok && result.data) {
        const list: object[] = result.data.threadPageList
        if (page === 1) {
          this.mgr.replaceWith(list, page, result.data.pagination.totalPages)
          this.threadsDataSource.replaceAll(list)
        } else {
          const added: object[] = this.mgr.appendWith(list, page, result.data.pagination.totalPages)
          if (added.length > 0) {
            this.threadsDataSource.appendAll(added)
          }
        }
        this.triggerPrefetch()
      } else if (page === 1) {
        this.hasError = true
        this.errorMsg = result.error || '加载失败'
      }
    } catch (e) {
      if (page === 1) {
        this.hasError = true
        this.errorMsg = (e as Error).message || '加载失败'
      }
    }
    clearTimeout(this.loadingDelayTimer)
    this.loadingDelayTimer = -1
    this.loadingContentOpacity = 0
    this.isLoading = false
    this.isLoadingMore = false
  }

  /**
   * 尝试加载下一页（从 onScrollIndex 触发，靠近底部时调用）
   * 避免触及列表边界触发系统回弹动画
   */
  private tryLoadNext(): void {
    if (this.isLoadingMore || this.mgr.currentPage >= this.mgr.totalPages) return
    const nextPage: number = this.mgr.currentPage + 1
    if (this.mgr.hasPrefetchedPage(nextPage)) {
      const added: object[] = this.mgr.commitPrefetchedPage(nextPage)
      if (added.length > 0) {
        this.threadsDataSource.appendAll(added)
      }
      this.triggerPrefetch()
    } else {
      this.loadTopics(nextPage)
    }
  }

  private lastPrefetchTime: number = 0
  private readonly PREFETCH_COOLDOWN_MS: number = 400

  private triggerPrefetch(): void {
    const lookahead: number = appStore.settings.prefetchPageCount
    if (lookahead <= 0) return
    const now: number = Date.now()
    if (now - this.lastPrefetchTime < this.PREFETCH_COOLDOWN_MS) return
    if (this.mgr.prefetchInProgress) return
    const pagesToFetch: number[] = []
    const maxPage: number = Math.min(this.mgr.currentPage + lookahead, this.mgr.totalPages)
    for (let p: number = this.mgr.currentPage + 1; p <= maxPage; p++) {
      if (!this.mgr.hasPrefetchedPage(p)) {
        pagesToFetch.push(p)
      }
    }
    if (pagesToFetch.length === 0) return
    this.lastPrefetchTime = now
    this.startPrefetch(pagesToFetch)
  }

  private async startPrefetch(pages: number[]): Promise<void> {
    this.mgr.prefetchInProgress = true
    const gen: number = this.mgr.getGeneration()
    try {
      const fetchResults: PrefetchPageResult[] = []
      const promises: Promise<void>[] = []
      for (let i = 0; i < pages.length; i++) {
        const page: number = pages[i]
        promises.push(
          (async (): Promise<void> => {
            try {
              const params: TopicListParams = this.buildTopicParams(page)
              const result: TopicListResult = await withTimeout<TopicListResult>(
                getTopicList(appStore.auth.token, params, appStore.settingsStore.getBlacklistIds(), appStore.settingsStore.getEnabledKeywords()), 10000
              )
              if (result.ok && result.data) {
                const pr: PrefetchPageResult = new PrefetchPageResult()
                pr.page = page
                pr.threads = result.data.threadPageList
                pr.totalPages = result.data.pagination.totalPages
                fetchResults.push(pr)
              }
            } catch (e) {
              // silently skip this page
            }
          })()
        )
      }
      await Promise.all(promises)
      if (gen !== this.mgr.getGeneration()) return
      for (let i = 0; i < fetchResults.length; i++) {
        const r: PrefetchPageResult = fetchResults[i]
        this.mgr.setPrefetchedPage(r.page, r.threads, r.totalPages)
      }
    } catch (e) {
      // silently fall back
    } finally {
      this.mgr.prefetchInProgress = false
    }
  }

  private async handleRemoveFav(tid: number): Promise<void> {
    try {
      const result = await removeFavorite(appStore.auth.token, tid, 0, 1)
      if (result.ok) {
        const filtered = this.mgr.threads.filter((t: object) => Number((t as Record<string, Object>)['tid']) !== tid)
        this.mgr.threads = filtered
        this.threadsDataSource.replaceAll(filtered)
        appStore.showToast('已取消收藏')
      } else {
        appStore.showToast(result.error || '取消收藏失败')
      }
    } catch (e) {
      appStore.showToast('取消收藏失败')
    }
  }

  build() {
    Stack() {
      Column() {
        if (this.isLoading) {
          Row().width('100%').height(44 + this.statusBarHeight)
          Column() {
            LoadingStateView()
          }.opacity(this.loadingContentOpacity).width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
        } else if (this.hasError) {
          Row().width('100%').height(44 + this.statusBarHeight)
          Column() {
            ErrorStateView({ msg: this.errorMsg || '加载失败', onRetry: () => this.loadTopics(1) })
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
        } else if (this.mgr.threads.length === 0) {
          Row().width('100%').height(44 + this.statusBarHeight)
          Column() {
            EmptyStateView({ msg: '暂无主题', icon: $r('app.media.icon_chat_bubble') })
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
        } else {
          List({ scroller: this.scroller }) {
            ListItem() {
              if (this.showSort) {
                Column() {
                  Row().width('100%').height(44 + this.statusBarHeight)
                  Row() {
                    ForEach(SORT_MODES, (mode: SortMode) => {
                      Text(mode.label)
                        .fontSize(13)
                        .fontColor(this.sortMode === mode.key ? AppColors.textPrimary : AppColors.textTertiary)
                        .fontWeight(this.sortMode === mode.key ? FontWeight.Bold : FontWeight.Normal)
                        .backgroundColor(this.sortMode === mode.key ? AppColors.bg : Color.Transparent)
                        .borderRadius(7)
                        .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                        .layoutWeight(1)
                        .textAlign(TextAlign.Center)
                        .onClick(() => {
                          if (this.sortMode !== mode.key) {
                            this.sortMode = mode.key
                            this.loadTopics(1)
                          }
                        })
                    })
                  }
                  .width('92%').margin({ top: 8, bottom: 4 }).padding(3)
                  .backgroundColor(AppColors.bgSecondary).borderRadius(10)
                }
              } else {
                Row().width('100%').height(44 + this.statusBarHeight)
              }
            }
            LazyForEach(this.threadsDataSource, (thread: object) => {
              ListItem() {
                TopicCardComponent({
                  thread: thread as Record<string, Object>,
                  isFavorites: this.isFavorites,
                  onRemoveFav: (tid: number): void => { this.handleRemoveFav(tid) },
                  onCardClick: (tid: string): void => {
                    if (tid) {
                      routerStore.navigateActivity(Screen.thread(tid))
                    }
                  }
                })
              }
            }, (thread: object) => {
              const t = thread as Record<string, Object>
              return String(t['tid'] ?? '')
            })
            ListItem() {
              Row() {
                if (this.isLoadingMore) {
                  LoadingProgress().width(16).height(16).color(AppColors.textTertiary)
                  Text('加载更多...').fontSize(13).fontColor(AppColors.textTertiary).margin({ left: 8 })
                } else if (this.mgr.currentPage >= this.mgr.totalPages) {
                  Text('— 已到底 —').fontSize(12).fontColor(AppColors.textTertiary)
                }
              }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 16, bottom: 16 })
            }
          }
          .width('100%').layoutWeight(1)
          .scrollBar(BarState.Off)
          .divider({ strokeWidth: 0.5, color: AppColors.separator })
          .lanes(new BreakpointType(1, 1, 1).getValue(this.currentBreakpoint), 12)
          .edgeEffect(EdgeEffect.Spring)
          .cachedCount(3)
          .onScrollIndex((start: number, end: number): void => {
            const total: number = this.threadsDataSource.totalCount()
            if (end >= total - 3 && total > 0) {
              this.tryLoadNext()
            }
          })
          .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
        }
      }
      .width('100%').height('100%')

      PanelNavBar({
        title: this.boardName,
        showBack: this.showBack,
        rightIcon: $r('app.media.icon_bell'),
        rightIconBadge: this.unreadNotiCount,
        onRightClick: (): void => {
          routerStore.navigateActivity(Screen.notifications())
        }
      })
        .width('100%').position({ x: 0, y: 0 })

      Row() {
        Stack() {
          Image($r('app.media.icon_refresh'))
            .width(20).height(20)
            .fillColor(AppColors.primary)
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
        .onClick(() => this.loadTopics(1))
      }.width('100%').justifyContent(this.holdingStatus === HoldingHandStatus.LEFT_HAND_HELD ? FlexAlign.Start : FlexAlign.End)
      .padding({ left: this.holdingStatus === HoldingHandStatus.LEFT_HAND_HELD ? 16 : 0, right: this.holdingStatus === HoldingHandStatus.LEFT_HAND_HELD ? 0 : 16, bottom: 16 + this.navBarHeight })
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg).alignContent(Alignment.BottomEnd)
  }
}

@Component
struct TopicCardComponent {
  @Prop thread: Record<string, Object> = {}
  @Prop isFavorites: boolean = false
  onRemoveFav: (tid: number) => void = (_tid: number) => {}
  onCardClick: (tid: string) => void = (_tid: string) => {}

  build() {
    Column() {
      Row() {
        Text(getTypeTags(Number(this.thread['type'] ?? 0)))
          .fontSize(15).lineHeight(22).fontColor(AppColors.textTertiary)
        Text(unescapeHtml(String(this.thread['subject'] ?? '')))
          .fontSize(15).lineHeight(22)
          .fontColor(getSubjectFontColor(String(this.thread['titleFont'] ?? '')))
          .fontWeight(isSubjectBold(String(this.thread['titleFont'] ?? '')) ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(isSubjectItalic(String(this.thread['titleFont'] ?? '')) ? FontStyle.Italic : FontStyle.Normal)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (this.isFavorites) {
          Text('✕').fontSize(16).fontColor(AppColors.textTertiary)
            .padding({ left: 8, right: 4 })
            .onClick(() => { this.onRemoveFav(Number(this.thread['tid'] ?? 0)) })
        }
      }.width('100%').alignItems(VerticalAlign.Top)

      if (this.thread['previewSnippet']) {
        Text(unescapeHtml(String(this.thread['previewSnippet'] ?? '')))
          .fontSize(13).fontColor(AppColors.textSecondary).maxLines(2).lineHeight(19)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 10 }).width('100%')
      }

      Row() {
        Row() {
          AnonymousName({ author: String(this.thread['author'] ?? ''), isAnonymous: this.thread['isAnonymity'] as boolean, fontSize: 12 })
          if (appStore.settingsStore.getNote(String(this.thread['authorId'] ?? '')).length > 0) {
            Text('(' + appStore.settingsStore.getNote(String(this.thread['authorId'] ?? '')) + ')')
              .fontSize(11).fontColor(AppColors.warning).margin({ left: 3 })
          }
          Text(` · ${formatTime(Number(this.thread['postDate'] ?? 0))}`)
            .fontSize(12).fontColor(AppColors.textTertiary)
          if (this.thread['board']) {
            Text(` · ${unescapeHtml(String(this.thread['board']))}`)
              .fontSize(12).fontColor(AppColors.textTertiary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.layoutWeight(1)
        Row() { Image($r('app.media.icon_chat_bubble')).width(12).height(12).fillColor(AppColors.textTertiary); Text(` ${this.thread['replies'] ?? 0}`).fontSize(12).fontColor(AppColors.textTertiary) }
      }.width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ top: 12 })
    }
    .width('100%').padding({ left: 16, right: 16, top: 16, bottom: 16 }).alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onCardClick(String(this.thread['tid'] ?? ''))
    })
  }
}

function getSubjectFontColor(titleFont: string): ResourceColor {
  const num = Number(titleFont) || 0
  const color = num & 0x1f
  if (FONT_COLORS[color]) return FONT_COLORS[color]
  return AppColors.textPrimary
}

function isSubjectBold(titleFont: string): boolean {
  return (Number(titleFont) & 32) !== 0
}

function isSubjectItalic(titleFont: string): boolean {
  return (Number(titleFont) & 64) !== 0
}

function getTypeTags(type: number): string {
  if (type & 1024) return '[锁定]'
  return ''
}
