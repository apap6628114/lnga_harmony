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
import { getTopicList, createTopicListParams, setSubforumFilter } from '../service/api/ForumApi'
import type { TopicListParams } from '../service/api/ForumApi'
import type { TopicListResult } from '../model/NgaApiResults'
import type { SubBoard } from '../model/Forum'
import { FavBoard } from '../model/SocialEntries'
import { AppColors, FONT_COLORS, SORT_MODES, SortMode, BreakpointType } from '../common/constants/Constants'
import { formatTime } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { ThreadDataSource } from '../common/datasource/LazyDataSource'
import { LoadingStateView, ErrorStateView, EmptyStateView } from '../common/components/PageStateView'
import { AnonymousName } from '../common/components/AnonymousName'
import { TopicPaginationManager } from '../common/managers/TopicPaginationManager'
import { Logger, DOMAIN_UI } from '../common/utils/Logger'
import {
  ReadingFontRole,
  ReadingLineHeightRole,
  ReadingTypography
} from '../common/typography/ReadingTypography'
import { AuthScope } from '../store/AuthScope'
import { UIMaterialManager } from '../common/managers/UIMaterialManager'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'

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
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 列表当前视口高度。 */
  @State listViewportHeight: number = 1
  @State loadingContentOpacity: number = 0
  private loadingDelayTimer: number = -1
  /** 是否显示标题栏更多菜单。 */
  @State showMoreMenu: boolean = false
  /** 是否显示子版块屏蔽面板。 */
  @State showSubBoardFilterPanel: boolean = false
  /** 当前父版块返回的子版块。 */
  @State subBoards: SubBoard[] = []
  /** 当前正在提交的子版块筛选标识。 */
  @State updatingSubBoardFilterId: string = ''
  /** 收藏板块版本号，用于响应现有收藏功能的变更。 */
  @StorageProp('favVersion') favVersion: number = 0
  /** 主题收藏关系版本号。 */
  @StorageProp('favoriteTopicVersion') @Watch('onFavoriteTopicVersionChange')
  favoriteTopicVersion: number = 0
  /** 当前收藏夹已经处理的服务端 mutation 版本。 */
  private handledFavoriteMutationVersion: number = 0

  private scroller: Scroller = new Scroller()

  /** 按列表绝对滚动偏移同步标题栏视觉效果。 */
  private syncTitleScrollEffect(): void {
    const progress: number = TitleScrollEffect.getProgress(
      this.scroller.currentOffset().yOffset,
      this.statusBarHeight
    )
    if (TitleScrollEffect.shouldUpdateProgress(this.titleScrollEffectProgress, progress)) {
      this.titleScrollEffectProgress = progress
    }
  }

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
    if (this.favor.length > 0) {
      this.handledFavoriteMutationVersion = appStore.favoriteStore.getFolderMutationVersion(this.favor)
      appStore.favoriteStore.ensureFolders()
    }
    this.loadTopics(1)
    appStore.refreshUnreadCount()
    appStore.settingsStore.ensureFavorites()
    this.startHoldingHandMonitoring()
  }

  aboutToDisappear(): void {
    this.stopHoldingHandMonitoring()
    // 推进分页代际，使未完成的分页/预取异步回调失效，避免回写已销毁页面
    this.mgr.reset()
  }

  private onBoardChanged(): void {
    this.mgr.reset()
    this.threadsDataSource.clear()
    this.hasError = false
    this.sortMode = 'latest'
    this.showMoreMenu = false
    this.showSubBoardFilterPanel = false
    this.subBoards = []
    this.updatingSubBoardFilterId = ''
    this.showSort = !this.authorid && !this.favor
    this.loadTopics(1)
  }

  /**
   * 响应其他页面完成的服务端主题收藏关系变更。
   */
  private onFavoriteTopicVersionChange(): void {
    if (this.favor.length === 0) {
      return
    }
    const mutationVersion: number = appStore.favoriteStore.getFolderMutationVersion(this.favor)
    if (mutationVersion <= this.handledFavoriteMutationVersion) {
      return
    }
    this.handledFavoriteMutationVersion = mutationVersion
    this.loadTopics(1)
  }

  /**
   * 从当前收藏列表及其 LazyForEach 数据源中立即移除主题。
   *
   * @param topicId - NGA 主题 ID
   */
  private removeTopicFromCurrentList(topicId: string): void {
    this.mgr.clearPrefetchedPages()
    const filtered: object[] = this.mgr.threads.filter((topic: object): boolean =>
      String((topic as Record<string, Object>)['tid'] ?? '') !== topicId)
    if (filtered.length === this.mgr.threads.length) {
      return
    }
    this.mgr.threads = filtered
    this.threadsDataSource.replaceAll(filtered)
  }

  /**
   * 判断当前页面是否对应一个可管理的普通版块。
   *
   * @returns 是否允许管理当前版块
   */
  private canManageCurrentBoard(): boolean {
    return this.boardFid !== 0 && !this.isFavorites && !this.favor
      && !this.authorid && !this.searchKey && !this.author && !this.searchpost
  }

  /**
   * 判断当前版块是否已存在于本地收藏板块列表。
   *
   * @returns 是否已收藏
   */
  private isCurrentBoardFavorite(): boolean {
    if (!this.canManageCurrentBoard()) return false
    const favorites: FavBoard[] = appStore.settings.favorites
    for (let i = 0; i < favorites.length; i++) {
      if (favorites[i].fid === this.boardFid) return true
    }
    return false
  }

  /**
   * 接入现有收藏板块功能，切换当前版块的收藏状态。
   */
  private toggleCurrentBoardFavorite(): void {
    if (!this.canManageCurrentBoard()) {
      appStore.showToast('当前页面不是可收藏的板块')
      return
    }
    if (this.isCurrentBoardFavorite()) {
      appStore.settingsStore.removeFavorite(this.boardFid)
      appStore.showToast('已取消收藏板块')
      return
    }

    const parsedStid: number = Number(this.boardStid)
    const favorite: FavBoard = new FavBoard()
    favorite.fid = this.boardFid
    favorite.stid = Number.isFinite(parsedStid) && parsedStid !== 0 ? parsedStid : this.boardFid
    favorite.name = this.boardName
    appStore.settingsStore.addFavorite(favorite)
    appStore.showToast('已收藏板块')
  }

  /**
   * 打开子版块屏蔽面板。
   */
  private openSubBoardFilterPanel(): void {
    this.showMoreMenu = false
    if (!this.canManageCurrentBoard()) {
      appStore.showToast('当前页面不支持子版块屏蔽')
      return
    }
    if (this.subBoards.length === 0) {
      appStore.showToast('当前板块没有可管理的子版块')
      return
    }
    this.showSubBoardFilterPanel = true
  }

  /**
   * 在本地替换指定子版块的显示状态。
   *
   * @param filterId - 子版块筛选标识
   * @param selected - 新显示状态
   */
  private replaceSubBoardSelection(filterId: string, selected: boolean): void {
    const next: SubBoard[] = []
    for (let i = 0; i < this.subBoards.length; i++) {
      const item: SubBoard = this.subBoards[i]
      next.push({
        fid: item.fid,
        stid: item.stid,
        name: item.name,
        boardHead: item.boardHead,
        tidStr: item.tidStr,
        type: item.type,
        checked: item.filterId === filterId ? selected : item.checked,
        description: item.description,
        parentFidStr: item.parentFidStr,
        filterId: item.filterId,
        attributes: item.attributes,
        filterable: item.filterable,
      })
    }
    this.subBoards = next
  }

  /**
   * 修改子版块的 NGA 账号级显示状态并刷新父版块。
   *
   * @param subBoard - 待修改子版块
   * @param show - 是否在父版块中显示
   */
  private async handleSubBoardFilterChange(subBoard: SubBoard, show: boolean): Promise<void> {
    if (!subBoard.filterable || subBoard.filterId.length === 0
      || this.updatingSubBoardFilterId.length > 0) {
      return
    }

    const previous: boolean = subBoard.checked
    this.updatingSubBoardFilterId = subBoard.filterId
    this.replaceSubBoardSelection(subBoard.filterId, show)
    try {
      const result = await setSubforumFilter(
        appStore.auth.token, this.boardFid, subBoard.filterId, show)
      if (!result.ok) {
        this.replaceSubBoardSelection(subBoard.filterId, previous)
        appStore.showToast(result.error || '修改子版块屏蔽设置失败')
        return
      }
      appStore.showToast(show ? `已显示“${subBoard.name}”` : `已屏蔽“${subBoard.name}”`)
      await this.loadTopics(1)
    } catch (e) {
      this.replaceSubBoardSelection(subBoard.filterId, previous)
      appStore.showToast((e as Error).message || '修改子版块屏蔽设置失败')
    } finally {
      this.updatingSubBoardFilterId = ''
    }
  }

  private buildTopicParams(page: number): TopicListParams {
    const params: TopicListParams = createTopicListParams()
    params.page = String(page)
    if (this.isFavorites || this.favor) {
      params.favor = this.favor || '1'
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

  /**
   * 将收藏夹列表响应中的主题登记到运行期成员关系缓存。
   *
   * @param topics - 当前收藏夹响应中的主题列表
   * @param folderId - 该响应所属的收藏夹 ID
   */
  private recordFavoriteTopics(topics: object[], folderId: string = this.favor): void {
    if (folderId.length === 0) {
      return
    }
    const topicIds: string[] = []
    for (let i = 0; i < topics.length; i++) {
      const topic: Record<string, Object> = topics[i] as Record<string, Object>
      const topicId: string = String(topic['tid'] ?? '')
      if (topicId.length > 0) {
        topicIds.push(topicId)
      }
    }
    appStore.favoriteStore.recordTopicMemberships(topicIds, folderId, true)
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
      let loadedSubBoards: SubBoard[] = []

      for (let i = 0; i < results.length; i++) {
        const result: TopicListResult = results[i]
        if (result.ok && result.data) {
          if (curTime === 0) {
            curTime = result.data.curTime
          }
          if (loadedSubBoards.length === 0 && result.data.subBoardList.length > 0) {
            loadedSubBoards = result.data.subBoardList
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
      if (this.canManageCurrentBoard()) {
        this.subBoards = loadedSubBoards
      }

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
    const authScope: AuthScope = AuthScope.capture(appStore.auth, 0)
    const favoriteFolderId: string = this.favor
    if (page === 1) {
      this.titleScrollEffectProgress = 0
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

    try {
      const params: TopicListParams = this.buildTopicParams(page)
      const result: TopicListResult = await withTimeout<TopicListResult>(
        getTopicList(appStore.auth.token, params, appStore.settingsStore.getBlacklistIds(),
          appStore.settingsStore.getEnabledKeywords()), 15000)
      if (gen !== this.mgr.getGeneration() || this.favor !== favoriteFolderId ||
        !authScope.isCurrent(appStore.auth, 0)) return
      if (result.ok && result.data) {
        const list: object[] = result.data.threadPageList
        this.recordFavoriteTopics(list, favoriteFolderId)
        if (page === 1) {
          this.subBoards = this.canManageCurrentBoard() ? result.data.subBoardList : []
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
      } else if (this.mgr.currentPage < this.mgr.totalPages) {
        this.tryLoadNext()
        return
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
    const favoriteFolderId: string = this.favor
    const authScope: AuthScope = AuthScope.capture(appStore.auth, 0)
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
      if (gen !== this.mgr.getGeneration() || this.favor !== favoriteFolderId ||
        !authScope.isCurrent(appStore.auth, 0)) return
      for (let i = 0; i < fetchResults.length; i++) {
        const r: PrefetchPageResult = fetchResults[i]
        this.recordFavoriteTopics(r.threads, favoriteFolderId)
        this.mgr.setPrefetchedPage(r.page, r.threads, r.totalPages)
      }
    } catch (e) {
      // silently fall back
    } finally {
      this.mgr.prefetchInProgress = false
    }
  }

  private async handleRemoveFav(tid: number): Promise<void> {
    const generation: number = this.mgr.getGeneration()
    const favorSnapshot: string = this.favor
    const authScope: AuthScope = AuthScope.capture(appStore.auth, 0)
    try {
      const folderId: string = favorSnapshot || '1'
      appStore.favoriteStore.recordTopicMembership(String(tid), folderId, true)
      const result = await appStore.favoriteStore.setTopicFavorite(String(tid), folderId, false)
      if (generation !== this.mgr.getGeneration() || this.favor !== favorSnapshot ||
        !authScope.isCurrent(appStore.auth, 0)) {
        return
      }
      if (result.ok) {
        this.removeTopicFromCurrentList(String(tid))
        appStore.showToast('已取消收藏')
      } else {
        appStore.showToast(result.error || '取消收藏失败')
      }
    } catch (e) {
      if (generation === this.mgr.getGeneration() && this.favor === favorSnapshot &&
        authScope.isCurrent(appStore.auth, 0)) {
        appStore.showToast('取消收藏失败')
      }
    }
  }

  build() {
    Stack() {
      Column() {
        if (this.isLoading) {
          Row().width('100%').height(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          Column() {
            LoadingStateView()
          }.opacity(this.loadingContentOpacity).width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
        } else if (this.hasError) {
          Row().width('100%').height(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          Column() {
            ErrorStateView({ msg: this.errorMsg || '加载失败', onRetry: () => this.loadTopics(1) })
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
        } else if (this.mgr.threads.length === 0) {
          Row().width('100%').height(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          Column() {
            EmptyStateView({ msg: '暂无主题', icon: $r('app.media.icon_chat_bubble') })
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
        } else {
          List({ scroller: this.scroller }) {
            if (this.showSort) {
              ListItem() {
                Column() {
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
                .width('100%')
              }
            }
            LazyForEach(this.threadsDataSource, (thread: object) => {
              ListItem() {
                TopicCardComponent({
                  thread: thread as Record<string, Object>,
                  isFavorites: this.isFavorites || this.favor.length > 0,
                  onRemoveFav: (tid: number): void => { this.handleRemoveFav(tid) },
                  onCardClick: (tid: string): void => {
                    if (tid) {
                      if (this.favor.length > 0) {
                        appStore.favoriteStore.recordTopicMembership(tid, this.favor, true)
                      }
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
          .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          .linearGradientBlur(
            TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),
            {
              fractionStops: TitleScrollEffect.getBlurStops(this.listViewportHeight, this.statusBarHeight),
              direction: GradientDirection.Bottom
            }
          )
          .onAreaChange((_oldValue: Area, newValue: Area): void => {
            if (typeof newValue.height === 'number' && newValue.height > 0 &&
              newValue.height !== this.listViewportHeight) {
              this.listViewportHeight = newValue.height
            }
          })
          .onDidScroll((): void => {
            this.syncTitleScrollEffect()
          })
          .onAppear((): void => {
            this.syncTitleScrollEffect()
          })
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
        scrollEffectProgress: this.titleScrollEffectProgress,
        showBack: this.showBack,
        rightIcon: this.canManageCurrentBoard() ? $r('app.media.icon_bell') : '',
        rightIconBadge: this.canManageCurrentBoard() ? this.unreadNotiCount : 0,
        onRightClick: (): void => {
          this.showMoreMenu = false
          routerStore.navigateActivity(Screen.notifications())
        },
        secondaryRightIcon: this.canManageCurrentBoard() ? $r('app.media.icon_more') : '',
        onSecondaryRightClick: (): void => {
          this.showMoreMenu = !this.showMoreMenu
        }
      })
        .width('100%').position({ x: 0, y: 0 })

      Row() {
        Stack() {
          Image($r('app.media.icon_refresh'))
            .width(22).height(22)
            .fillColor(UIMaterialManager.adaptiveForeground)
        }
        .width(44).height(44).borderRadius(22)
        .backgroundColor(Color.Transparent)
        .shadow({ radius: 16, color: AppColors.shadow, offsetY: 4 })
        .systemMaterial(UIMaterialManager.fabMaterial)
        .onClick(() => this.loadTopics(1))
      }.width('100%').justifyContent(this.holdingStatus === HoldingHandStatus.LEFT_HAND_HELD ? FlexAlign.Start : FlexAlign.End)
      .padding({ left: this.holdingStatus === HoldingHandStatus.LEFT_HAND_HELD ? 16 : 0, right: this.holdingStatus === HoldingHandStatus.LEFT_HAND_HELD ? 0 : 16, bottom: 16 + this.navBarHeight })

      if (this.showMoreMenu && this.canManageCurrentBoard()) {
        Stack() {
          Column() {
          }
          .width('100%').height('100%')
          .onClick(() => {
            this.showMoreMenu = false
          })

          Column() {
            Column() {
              Text('子版块屏蔽')
                .fontSize(15)
                .fontColor(AppColors.textPrimary)
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .width('100%')
                .onClick(() => {
                  this.openSubBoardFilterPanel()
                })
            }
            .width('100%')

            Divider().width('100%').color(AppColors.separator)

            Column() {
              Text(this.isCurrentBoardFavorite() ? '取消收藏板块' : '收藏板块')
                .fontSize(15)
                .fontColor(AppColors.textPrimary)
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .width('100%')
                .onClick(() => {
                  this.toggleCurrentBoardFavorite()
                  this.showMoreMenu = false
                })
            }
            .width('100%')
          }
          .width(170)
          .backgroundColor(Color.Transparent)
          .borderRadius(10)
          .shadow({ radius: 16, color: AppColors.shadowLight, offsetY: 4 })
          .systemMaterial(UIMaterialManager.surfaceMaterial)
          .position({ top: this.statusBarHeight + 50, right: 12 })
        }
        .width('100%').height('100%')
        .transition(TransitionEffect.OPACITY.animation({ duration: 150 }))
      }

      if (this.showSubBoardFilterPanel && this.canManageCurrentBoard()) {
        Stack({ alignContent: Alignment.Center }) {
          Column() {
          }
          .width('100%').height('100%')
          .backgroundColor(AppColors.overlay)
          .onClick(() => {
            if (this.updatingSubBoardFilterId.length === 0) {
              this.showSubBoardFilterPanel = false
            }
          })

          Column() {
            Row() {
              Column() {
                Text('子版块屏蔽')
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColors.textPrimary)
                  .width('100%')
                Text('开关会同步到 NGA 账号，并刷新当前父版块的帖子列表')
                  .fontSize(12)
                  .fontColor(AppColors.textTertiary)
                  .width('100%')
                  .margin({ top: 3 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Text('关闭')
                .fontSize(14)
                .fontColor(AppColors.primary)
                .padding({ left: 12, top: 8, bottom: 8 })
                .onClick(() => {
                  if (this.updatingSubBoardFilterId.length === 0) {
                    this.showSubBoardFilterPanel = false
                  }
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 14, bottom: 10 })
            .alignItems(VerticalAlign.Center)

            Divider().width('100%').color(AppColors.separator)

            List() {
              ForEach(this.subBoards, (subBoard: SubBoard) => {
                ListItem() {
                  Row() {
                    Image(subBoard.boardHead)
                      .width(36).height(36)
                      .borderRadius(8)
                      .objectFit(ImageFit.Cover)
                      .onError(() => {})

                    Column() {
                      Text(unescapeHtml(subBoard.name))
                        .fontSize(15)
                        .fontColor(AppColors.textPrimary)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                      if (subBoard.description.length > 0) {
                        Text(unescapeHtml(subBoard.description))
                          .fontSize(12)
                          .fontColor(AppColors.textTertiary)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                          .margin({ top: 2 })
                      }
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    .margin({ left: 10, right: 10 })

                    if (this.updatingSubBoardFilterId === subBoard.filterId) {
                      LoadingProgress().width(22).height(22).color(AppColors.primary)
                    } else {
                      Toggle({
                        type: ToggleType.Switch,
                        isOn: subBoard.filterable ? subBoard.checked : true
                      })
                        .enabled(subBoard.filterable && subBoard.filterId.length > 0
                          && this.updatingSubBoardFilterId.length === 0)
                        .onChange((show: boolean): void => {
                          this.handleSubBoardFilterChange(subBoard, show)
                        })
                    }
                  }
                  .width('100%')
                  .height(58)
                  .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                  .alignItems(VerticalAlign.Center)
                }
              }, (subBoard: SubBoard) => {
                const stableId: string = subBoard.filterId.length > 0
                  ? subBoard.filterId : `${subBoard.fid}:${subBoard.stid}:${subBoard.name}`
                return `${stableId}:${subBoard.checked ? 'shown' : 'blocked'}`
              })
            }
            .width('100%')
            .layoutWeight(1)
            .divider({ strokeWidth: 0.5, color: AppColors.separator, startMargin: 60 })
            .scrollBar(BarState.Auto)
          }
          .width('88%')
          .height('70%')
          .backgroundColor(Color.Transparent)
          .borderRadius(16)
          .shadow({ radius: 24, color: AppColors.shadow, offsetY: 6 })
          .systemMaterial(UIMaterialManager.surfaceMaterial)
        }
        .width('100%').height('100%')
        .transition(TransitionEffect.OPACITY.animation({ duration: 180 }))
      }
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg).alignContent(Alignment.BottomEnd)
  }
}

@Component
struct TopicCardComponent {
  @Prop thread: Record<string, Object> = {}
  @Prop isFavorites: boolean = false
  @StorageProp('topicFontSize') topicFontSize: number = 15
  /** 黑名单变更版本号。 */
  @StorageProp('blacklistVersion') blacklistVersion: number = 0
  onRemoveFav: (tid: number) => void = (_tid: number) => {}
  onCardClick: (tid: string) => void = (_tid: string) => {}

  /**
   * 判断当前主题作者是否已被屏蔽。
   *
   * @returns 作者是否在实时黑名单中
   */
  private isAuthorBlacklisted(): boolean {
    return this.blacklistVersion >= 0 &&
      appStore.settingsStore.isBlacklisted(String(this.thread['authorId'] ?? ''))
  }

  /**
   * 判断当前摘要对应的回复作者是否已被屏蔽。
   *
   * @returns 摘要作者是否在实时黑名单中
   */
  private isPreviewAuthorBlacklisted(): boolean {
    const authorId: string = String(this.thread['previewAuthorId'] ?? '')
    return this.blacklistVersion >= 0 &&
      authorId.length > 0 &&
      appStore.settingsStore.isBlacklisted(authorId)
  }

  build() {
    Column() {
      Row() {
        if (this.isAuthorBlacklisted()) {
          Text('该用户已被屏蔽')
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_TITLE, this.topicFontSize))
            .fontColor(AppColors.textTertiary)
            .layoutWeight(1)
        } else {
          Text(getTypeTags(Number(this.thread['type'] ?? 0)))
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_TITLE, this.topicFontSize))
            .fontColor(AppColors.textTertiary)
          Text(unescapeHtml(String(this.thread['subject'] ?? '')))
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_TITLE, this.topicFontSize))
            .fontColor(getSubjectFontColor(String(this.thread['titleFont'] ?? '')))
            .fontWeight(isSubjectBold(String(this.thread['titleFont'] ?? '')) ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(isSubjectItalic(String(this.thread['titleFont'] ?? '')) ? FontStyle.Italic : FontStyle.Normal)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        }
        if (this.isFavorites) {
          Image($r('app.media.icon_close')).width(16).height(16).fillColor(AppColors.textTertiary)
            .padding({ left: 8, right: 4 })
            .onClick(() => { this.onRemoveFav(Number(this.thread['tid'] ?? 0)) })
        }
      }.width('100%').alignItems(VerticalAlign.Top)

      if (this.thread['previewSnippet']) {
        if (this.isPreviewAuthorBlacklisted()) {
          Text('该用户已被屏蔽')
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_SUMMARY, this.topicFontSize))
            .fontColor(AppColors.textTertiary)
            .margin({ top: 10 })
            .width('100%')
        } else {
          Text(unescapeHtml(String(this.thread['previewSnippet'] ?? '')))
            .fontSize(ReadingTypography.fontSize(ReadingFontRole.TOPIC_SUMMARY, this.topicFontSize))
            .fontColor(AppColors.textSecondary)
            .maxLines(2)
            .lineHeight(ReadingTypography.lineHeight(
              ReadingLineHeightRole.TOPIC_SUMMARY,
              ReadingTypography.fontSize(ReadingFontRole.TOPIC_SUMMARY, this.topicFontSize)
            ))
            .textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 10 }).width('100%')
        }
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
