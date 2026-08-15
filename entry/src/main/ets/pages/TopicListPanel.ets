/**
 * 主题列表面板 - 统一版, 所有断点共用
 * 第二列(板块堆栈) 或 第三列(活动栈) 均可使用
 * 点击主题通过 routerStore 导航
 */

import { SegmentButton, SegmentButtonOptions, SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI'
import { motion } from '@kit.MultimodalAwarenessKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { appStore } from '../store/AppStore'
import { routerStore, Screen, ThreadSource } from '../store/RouterStore'
import { floatingLayerStore, FloatingPage } from '../store/FloatingLayerStore'
import { withTimeout } from '../common/utils/TimeoutUtils'
import { getTopicList, createTopicListParams, setSubforumFilter } from '../service/api/ForumApi'
import { locatePidPage } from '../service/api/ThreadApi'
import type { TopicListParams } from '../service/api/ForumApi'
import type { TopicListResult } from '../model/NgaApiResults'
import { newTopicManager } from '../common/managers/NewTopicManager'
import type { PostReplyResult } from '../model/ThreadResult'
import type { SubBoard } from '../model/Forum'
import { FavBoard } from '../model/SocialEntries'
import { AppColors, FONT_COLORS, SORT_MODES, HOT_RANGES, SortMode, BreakpointType } from '../common/constants/Constants'
import { formatTime } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { ThreadDataSource } from '../common/datasource/LazyDataSource'
import { LoadingStateView, ErrorStateView, EmptyStateView } from '../common/components/PageStateView'
import { AnonymousName } from '../common/components/AnonymousName'
import { BoardIcon } from '../common/components/BoardIcon'
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

/**
 * 排序模式的分页状态快照（模仿 MNGA 每种 order 独立数据源的会话级缓存）。
 * 切换排序/时间窗时保存，切回时恢复，避免整页重拉。
 */
class TopicModeState {
  /** 已加载的主题列表快照。 */
  threads: object[] = []
  /** 当前页码（1 基）。 */
  currentPage: number = 1
  /** 服务端返回的总页数。 */
  totalPages: number = 0
  /** 是否还有更多页可加载。 */
  hasMore: boolean = true
  /** 热门模式聚合缓存（对应具体时间窗）。 */
  hotCache: object[] = []
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

  /**
   * pid→页码预查找的代际计数：每次发起查找自增，完成后校验未变化才跳转；
   * 面板离开（aboutToDisappear）时也自增，使在途查找失效，防止过期跳转。
   */
  private pidLookupGeneration: number = 0

  @State sortMode: string = 'latest'
  /** 热门模式的时间窗档位（day/week/month），模仿 MNGA 的 DAY/WEEK/MONTH。 */
  @State hotRange: string = 'day'
  /** 各排序模式的分页状态缓存，键为模式键（hot 时含时间窗）。 */
  private modeStates: Map<string, TopicModeState> = new Map()
  /** 排序条分段按钮选项（原生 SegmentButton，胶囊单选），文案由 SORT_MODES 生成避免双份维护。 */
  @State sortOptions: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: SORT_MODES.map((mode: SortMode): SegmentButtonTextItem => {
      const item: SegmentButtonTextItem = { text: mode.key === 'hot' ? `${mode.label} ▾` : mode.label }
      return item
    }) as SegmentButtonItemTuple,
    multiply: false,
    fontColor: AppColors.textSecondary,
    selectedFontColor: AppColors.primary,
    fontSize: 13,
    selectedFontSize: 13,
    fontWeight: FontWeight.Normal,
    selectedFontWeight: FontWeight.Bold,
    backgroundColor: AppColors.bgSecondary,
    selectedBackgroundColor: AppColors.primaryLight,
  })
  /** 排序条分段按钮选中项（SegmentButton 双向绑定，单选取 [index]）。 */
  @State sortSelected: number[] = [0]
  /** 是否显示热门时间窗气泡菜单。 */
  @State showHotRangeMenu: boolean = false
  /** 排序条在窗口中的底部纵坐标（onAreaChange 实时采集，供时间窗气泡锚定与状态视图撑满）。 */
  private sortBarBottomY: number = 0
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
  /** 是否显示子版块显示面板。 */
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
    // 使在途的 pid→页码预查找失效，避免面板离开后过期跳转
    this.pidLookupGeneration++
    // 排序模式缓存随面板生命周期释放（板块数据可能已变化）
    this.modeStates.clear()
  }

  private onBoardChanged(): void {
    this.mgr.reset()
    this.threadsDataSource.clear()
    this.hasError = false
    this.sortMode = 'latest'
    this.hotRange = 'day'
    this.sortSelected = [0]
    this.showHotRangeMenu = false
    this.modeStates.clear()
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
    // 同步模式缓存，避免切走再切回时已删除主题“复活”
    this.saveCurrentModeState()
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
   * 回帖列表条目点击：先完成 pid→页码数据查找，再打开帖子。
   *
   * 仅在 searchpost 列表携带真实楼层 pid 时走此路径（普通列表 pid 已归一为空，
   * 见 TopicCardComponent.onClick）。查找失败（楼层已删除/请求异常）时退化为
   * 不带定位意图地打开第 1 页。带代际防重入：连点多个帖子时只执行最新一次，
   * 面板离开后在途查找作废，避免过期跳转。
   *
   * @param tid - 主题 ID
   * @param pid - 目标楼层 pid（已归一，非 '0'）
   */
  private async openThreadAfterPidLookup(tid: string, pid: string): Promise<void> {
    const generation: number = ++this.pidLookupGeneration
    const page: number = await locatePidPage(appStore.auth.token, tid, parseInt(pid, 10))
    if (generation !== this.pidLookupGeneration) {
      // 已有更新的点击或面板已离开：丢弃过期结果
      return
    }
    if (page > 0) {
      routerStore.navigateActivity(Screen.thread(tid, page, pid, ThreadSource.TOPIC_LIST))
    } else {
      routerStore.navigateActivity(Screen.thread(tid, 1, '', ThreadSource.TOPIC_LIST))
    }
  }

  /**
   * 打开发新主题编辑器。
   *
   * 仅真实版块（canManageCurrentBoard）提供入口；未登录时提示登录。
   */
  private openNewTopic(): void {
    if (!appStore.auth.isAuthenticated) {
      appStore.showToast('请先登录后发帖')
      return
    }
    const parsedStid: number = Number(this.boardStid)
    const stid: number = Number.isFinite(parsedStid) && parsedStid !== 0 ? parsedStid : 0
    newTopicManager.start(this.boardFid, stid, this.boardName)
    floatingLayerStore.newTopicOnSend = (subject: string, content: string, isAnony: boolean): Promise<void> => {
      return this.handleNewTopicSend(subject, content, isAnony)
    }
    floatingLayerStore.push(FloatingPage.NEW_TOPIC_DIALOG)
  }

  /**
   * 发布新主题。
   *
   * 成功后刷新版面列表并跳转到新主题详情；失败时抛出错误，
   * 使编辑器保留内容与草稿（错误提示在此完成 Toast）。
   */
  private async handleNewTopicSend(subject: string, content: string, isAnony: boolean): Promise<void> {
    let result: PostReplyResult
    try {
      result = await newTopicManager.send(subject, content, isAnony)
    } catch (e) {
      appStore.showToast((e as Error).message || '发帖失败')
      throw new Error((e as Error).message || '发帖失败')
    }
    if (!result.ok) {
      appStore.showToast(result.error || '发帖失败')
      throw new Error(result.error || '发帖失败')
    }
    appStore.showToast('发帖成功')
    this.loadTopics(1)
    if (result.tid > 0) {
      routerStore.navigateActivity(Screen.thread(String(result.tid)))
    }
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
   * 打开子版块显示面板。
   */
  private openSubBoardFilterPanel(): void {
    this.showMoreMenu = false
    if (!this.canManageCurrentBoard()) {
      appStore.showToast('当前页面不支持子版块显示')
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
        appStore.showToast(result.error || '修改子版块显示设置失败')
        return
      }
      appStore.showToast(show ? `已显示“${subBoard.name}”` : `已屏蔽“${subBoard.name}”`)
      // 子版块显示设置改变了服务端列表，其余排序模式缓存随之过期，统一失效重建
      this.modeStates.clear()
      await this.loadTopics(1)
    } catch (e) {
      this.replaceSubBoardSelection(subBoard.filterId, previous)
      appStore.showToast((e as Error).message || '修改子版块显示设置失败')
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
      if (this.sortMode === 'postdate') {
        params.orderBy = 'postdatedesc'
      } else if (this.sortMode === 'recommend') {
        params.recommend = '1'
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
      const fetchPages: number = this.getHotFetchPages()
      const pages: number[] = []
      for (let i = 1; i <= fetchPages; i++) {
        pages.push(i)
      }
      const promises: Promise<TopicListResult>[] = []
      for (let i = 0; i < pages.length; i++) {
        const p: number = pages[i]
        const params: TopicListParams = this.buildTopicParams(p)
        promises.push(withTimeout<TopicListResult>(getTopicList(appStore.auth.token, params, appStore.settingsStore.getBlacklistIds(), appStore.settingsStore.getEnabledKeywords()), 15000))
      }
      // 逐页容错：单页失败/超时不拖垮整批聚合（并发页数随时间窗放大后尤为重要）
      const settled: Promise<TopicListResult | undefined>[] = []
      for (let i = 0; i < promises.length; i++) {
        const p: Promise<TopicListResult> = promises[i]
        settled.push((async (): Promise<TopicListResult | undefined> => {
          try {
            return await p
          } catch (e) {
            return undefined
          }
        })())
      }
      const results: (TopicListResult | undefined)[] = await Promise.all(settled)

      if (gen !== this.mgr.getGeneration()) return

      let curTime: number = 0
      let okCount: number = 0
      const allThreads: object[] = []
      const seenTids: Set<number> = new Set()
      let loadedSubBoards: SubBoard[] = []

      for (let i = 0; i < results.length; i++) {
        const result: TopicListResult | undefined = results[i]
        if (result !== undefined && result.ok && result.data) {
          okCount++
          if (curTime === 0) {
            curTime = result.data.curTime
          }
          if (loadedSubBoards.length === 0 && result.data.subBoardList.length > 0) {
            loadedSubBoards = result.data.subBoardList
          }
          const list: object[] = result.data.threadPageList
          for (let j = 0; j < list.length; j++) {
            const t: object = list[j]
            const tid: number = Number((t as Record<string, Object>)['tid'] ?? 0)
            // 跨页按 tid 去重，避免超页返回重复内容导致列表重复
            if (tid > 0 && seenTids.has(tid)) {
              continue
            }
            if (tid > 0) {
              seenTids.add(tid)
            }
            allThreads.push(t)
          }
        }
      }

      // 全部页都失败时按错误态处理，而非误显空列表
      if (okCount === 0) {
        this.hasError = true
        this.errorMsg = '加载失败'
        return
      }

      const windowSeconds: number = this.getHotWindowSeconds()
      const filtered: object[] = []
      for (let i = 0; i < allThreads.length; i++) {
        const t: object = allThreads[i]
        const postDate: number = Number((t as Record<string, Object>)['postDate'] ?? 0)
        if (curTime - postDate <= windowSeconds) {
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
      this.saveCurrentModeState()
    } catch (e) {
      if (gen === this.mgr.getGeneration()) {
        this.hasError = true
        this.errorMsg = (e as Error).message || '加载失败'
      }
    } finally {
      // 代际校验：模式切换后的过期会话不得复位新会话的加载态
      if (gen === this.mgr.getGeneration()) {
        clearTimeout(this.loadingDelayTimer)
        this.loadingDelayTimer = -1
        this.loadingContentOpacity = 0
        this.isLoading = false
        this.isLoadingMore = false
      }
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
      // 清空残留数据：避免加载中切走时把上一模式的 threads 以当前模式 key 存入缓存，
      // 也防止过期会话期间残留列表被渲染/翻页混排
      this.mgr.threads = []
      this.threadsDataSource.clear()
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
          this.saveCurrentModeState()
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
      // 代际校验：过期会话的失败不得污染新模式/新板块的 UI 状态
      if (page === 1 && gen === this.mgr.getGeneration()) {
        this.hasError = true
        this.errorMsg = (e as Error).message || '加载失败'
      }
    }
    if (gen === this.mgr.getGeneration()) {
      clearTimeout(this.loadingDelayTimer)
      this.loadingDelayTimer = -1
      this.loadingContentOpacity = 0
      this.isLoading = false
      this.isLoadingMore = false
    }
  }

  /**
   * 当前排序模式的状态缓存键（热门模式按时间窗细分，模仿 MNGA 的独立数据源隔离）。
   *
   * @returns 模式键
   */
  private currentModeKey(): string {
    if (this.sortMode === 'hot') {
      return `hot:${this.hotRange}`
    }
    return this.sortMode
  }

  /**
   * 将当前排序模式的分页状态快照存入缓存（切换走之前调用）。
   * 首屏数据提交后也会调用，保证刷新后缓存同步。
   */
  private saveCurrentModeState(): void {
    const key: string = this.currentModeKey()
    const state: TopicModeState = new TopicModeState()
    state.threads = this.mgr.threads.slice()
    state.currentPage = this.mgr.currentPage
    state.totalPages = this.mgr.totalPages
    state.hasMore = this.mgr.hasMore
    if (this.sortMode === 'hot') {
      state.hotCache = this.twentyFourCache.slice()
    }
    this.modeStates.set(key, state)
  }

  /**
   * 从缓存恢复排序模式的分页状态（切回时秒开，不重新请求）。
   *
   * @param state - 目标模式的快照
   */
  private restoreModeState(state: TopicModeState): void {
    this.mgr.threads = state.threads
    this.mgr.currentPage = state.currentPage
    this.mgr.totalPages = state.totalPages
    this.mgr.hasMore = state.hasMore
    this.mgr.clearPrefetchedPages()
    if (this.sortMode === 'hot') {
      this.twentyFourCache = state.hotCache.slice()
    } else {
      this.twentyFourCache = []
    }
    this.threadsDataSource.replaceAll(state.threads)
    this.hasError = false
    this.isLoading = false
    this.isLoadingMore = false
    clearTimeout(this.loadingDelayTimer)
    this.loadingDelayTimer = -1
    this.loadingContentOpacity = 0
    // 恢复后重新建立预取链（restore 前 clearPrefetchedPages 已清空缓存）
    this.triggerPrefetch()
  }

  /**
   * 切换排序模式：保存当前模式状态，恢复目标模式缓存或首次加载。
   *
   * @param mode - 目标排序模式键
   */
  private switchSortMode(mode: string): void {
    if (mode === this.sortMode) {
      return
    }
    this.saveCurrentModeState()
    this.sortMode = mode
    this.switchToMode()
  }

  /**
   * 切换热门时间窗（24小时/7天/30天），不同窗口使用独立缓存。
   *
   * @param range - 目标时间窗键
   */
  private switchHotRange(range: string): void {
    if (range === this.hotRange) {
      return
    }
    this.saveCurrentModeState()
    this.hotRange = range
    this.switchToMode()
  }

  /**
   * 排序条分段按钮点击：热门未选中时进入热门模式，已选中时弹出时间窗气泡。
   *
   * @param index - 被点击的选项下标
   */
  private handleSortClicked(index: number): void {
    if (index < 0 || index >= SORT_MODES.length) {
      return
    }
    const mode: string = SORT_MODES[index].key
    if (mode === 'hot') {
      if (this.sortMode === 'hot') {
        this.showMoreMenu = false
        this.showHotRangeMenu = true
        return
      }
      this.sortSelected = [index]
      this.switchSortMode('hot')
      return
    }
    this.sortSelected = [index]
    this.switchSortMode(mode)
  }

  /**
   * 时间窗气泡选项点击：关闭气泡并切换热门时间窗（同窗仅关闭）。
   *
   * @param range - 目标时间窗键
   */
  private handleHotRangeSelect(range: string): void {
    this.showHotRangeMenu = false
    this.switchHotRange(range)
  }

  /**
   * 切换到当前 sortMode/hotRange 指向的模式：有非空缓存则恢复，否则首次加载。
   */
  private switchToMode(): void {
    // 废弃在途请求（预取/翻页），防止旧模式响应回写当前模式
    this.mgr.nextGeneration()
    const cached: TopicModeState | undefined = this.modeStates.get(this.currentModeKey())
    if (cached !== undefined && cached.threads.length > 0) {
      this.restoreModeState(cached)
    } else {
      this.loadTopics(1)
    }
  }

  /**
   * 热门模式的并发拉取页数（按时间窗调整，模仿 MNGA 的大窗口下限保护）。
   *
   * @returns 并发页数
   */
  private getHotFetchPages(): number {
    if (this.hotRange === 'week') {
      return 8
    }
    if (this.hotRange === 'month') {
      return 10
    }
    return 5
  }

  /**
   * 热门模式的过滤时间窗（秒），以服务端 curTime 为基准。
   *
   * @returns 时间窗秒数
   */
  private getHotWindowSeconds(): number {
    if (this.hotRange === 'week') {
      return 7 * 24 * 60 * 60
    }
    if (this.hotRange === 'month') {
      return 30 * 24 * 60 * 60
    }
    return 24 * 60 * 60
  }

  /**
   * 计算列表状态视图（加载/错误/空态）的撑满高度。
   *
   * 减去排序条占据的顶部区域，使状态内容居中于列表可视区；
   * 排序条坐标尚未实测（首帧）时用标题区高度 + 排序条占位估算兜底，避免高度跳变。
   *
   * @returns 状态视图高度
   */
  private getStateViewHeight(): number {
    let topOffset: number = 0
    if (this.showSort) {
      topOffset = this.sortBarBottomY > 0
        ? this.sortBarBottomY
        : TitleScrollEffect.getContentStartOffset(this.statusBarHeight) + 50
    }
    return Math.max(this.listViewportHeight - topOffset, 400)
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
      // 代际校验：旧模式的过期预取会话不得误复位新模式的 prefetchInProgress
      if (gen === this.mgr.getGeneration()) {
        this.mgr.prefetchInProgress = false
      }
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
        List({ scroller: this.scroller }) {
          if (this.showSort) {
            ListItem() {
              Row() {
                SegmentButton({
                  options: this.sortOptions,
                  selectedIndexes: $sortSelected,
                  onItemClicked: (index: number): void => {
                    this.handleSortClicked(index)
                  }
                })
              }
              .width('100%')
              .padding({ left: '4%', right: '4%' })
              .margin({ top: 8, bottom: 6 })
              .onAreaChange((_oldValue: Area, newValue: Area): void => {
                // 采集排序条底部纵坐标：供时间窗气泡锚定、状态视图撑满排序条下方的列表可视区
                if (typeof newValue.globalPosition.y === 'number' && typeof newValue.height === 'number') {
                  this.sortBarBottomY = newValue.globalPosition.y + newValue.height
                }
              })
            }
          }
          if (this.isLoading) {
            ListItem() {
              Column() {
                LoadingStateView()
              }
              .opacity(this.loadingContentOpacity)
              .width('100%').height(this.getStateViewHeight())
              .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
              .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
            }
          } else if (this.hasError) {
            ListItem() {
              Column() {
                ErrorStateView({ msg: this.errorMsg || '加载失败', onRetry: () => this.loadTopics(1) })
              }
              .width('100%').height(this.getStateViewHeight())
              .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
              .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
            }
          } else if (this.mgr.threads.length === 0) {
            ListItem() {
              Column() {
                EmptyStateView({ msg: '暂无主题', icon: $r('app.media.icon_chat_bubble') })
              }
              .width('100%').height(this.getStateViewHeight())
              .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
              .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
            }
          } else {
            LazyForEach(this.threadsDataSource, (thread: object) => {
              ListItem() {
                TopicCardComponent({
                  thread: thread as Record<string, Object>,
                  isFavorites: this.isFavorites || this.favor.length > 0,
                  onRemoveFav: (tid: number): void => { this.handleRemoveFav(tid) },
                  onCardClick: (tid: string, pid: string): void => {
                    if (tid) {
                      if (this.favor.length > 0) {
                        appStore.favoriteStore.recordTopicMembership(tid, this.favor, true)
                      }
                      if (pid.length > 0) {
                        // 回帖列表进入：先完成 pid→页码数据查找，再以正确页码打开帖子
                        this.openThreadAfterPidLookup(tid, pid)
                      } else {
                        routerStore.navigateActivity(Screen.thread(tid, 1, '', ThreadSource.TOPIC_LIST))
                      }
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
          // 列表滚动时收起时间窗气泡（其锚定的排序条已随内容移动）
          this.showHotRangeMenu = false
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

      Row({ space: 12 }) {
        if (this.canManageCurrentBoard()) {
          Stack() {
            Image($r('app.media.icon_compose'))
              .width(22).height(22)
              .fillColor(UIMaterialManager.adaptiveForeground)
          }
          .width(44).height(44).borderRadius(22)
          .backgroundColor(Color.Transparent)
          .shadow({ radius: 16, color: AppColors.shadow, offsetY: 4 })
          .systemMaterial(UIMaterialManager.fabMaterial)
          .onClick(() => this.openNewTopic())
        }
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
              Text('子版块显示')
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

      if (this.showHotRangeMenu) {
        Stack() {
          Column() {
          }
          .width('100%').height('100%')
          .onClick(() => {
            this.showHotRangeMenu = false
          })

          Column() {
            ForEach(HOT_RANGES, (range: SortMode, index: number) => {
              Column() {
                Row() {
                  Text(range.label)
                    .fontSize(15)
                    .fontColor(AppColors.textPrimary)
                    .layoutWeight(1)
                  if (this.hotRange === range.key) {
                    Image($r('app.media.icon_check'))
                      .width(16).height(16)
                      .fillColor(AppColors.primary)
                  }
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .onClick(() => {
                  this.handleHotRangeSelect(range.key)
                })

                if (index < HOT_RANGES.length - 1) {
                  Divider().width('100%').color(AppColors.separator)
                }
              }
              .width('100%')
            }, (range: SortMode) => {
              return range.key
            })
          }
          .width(150)
          .backgroundColor(Color.Transparent)
          .borderRadius(10)
          .shadow({ radius: 16, color: AppColors.shadowLight, offsetY: 4 })
          .systemMaterial(UIMaterialManager.surfaceMaterial)
          .position({ top: this.sortBarBottomY + 6, right: '4%' })
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
                Text('子版块显示')
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColors.textPrimary)
                  .width('100%')
                Text() {
                  Span('关闭即屏蔽，开关会同步到 ')
                  Span('NGA 账号').fontWeight(FontWeight.Medium)
                  Span('，并刷新当前父版块的帖子列表')
                }
                .fontSize(12)
                .fontColor(AppColors.textSecondary)
                .lineHeight(16)
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
                    BoardIcon({ url: subBoard.boardHead, iconSize: 36, iconRadius: 8 })
                      .opacity(subBoard.checked ? 1 : 0.45)

                    Column() {
                      Text(unescapeHtml(subBoard.name))
                        .fontSize(15)
                        .fontColor(subBoard.checked ? AppColors.textPrimary : AppColors.textTertiary)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                      if (subBoard.checked && subBoard.description.length > 0) {
                        Text(unescapeHtml(subBoard.description))
                          .fontSize(12)
                          .fontColor(AppColors.textTertiary)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                          .margin({ top: 2 })
                      }
                      if (!subBoard.checked) {
                        Text('已屏蔽')
                          .fontSize(12)
                          .fontColor(AppColors.textSecondary)
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
  onCardClick: (tid: string, pid: string) => void = (_tid: string, _pid: string) => {}

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
      // 普通列表 pid 为 0（NGA 的"主楼/无楼层"哨兵值），在入口判断前就归一为空串，
      // 避免误入 pid→页码预查找；searchpost 回帖列表携带真实楼层 pid
      const rawPid: number = Number(this.thread['pid'] ?? 0)
      this.onCardClick(String(this.thread['tid'] ?? ''), rawPid > 0 ? String(rawPid) : '')
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
