import { display, CustomContentDialog } from '@kit.ArkUI'
import { common, Context } from '@kit.AbilityKit'

import { appStore } from '../store/AppStore'
import { AiAgentPreset, PRESET_ENTRY_THREAD } from '../model/AiAgentPreset'
import { routerStore, Screen } from '../store/RouterStore'
import { votePost } from '../service/api/FavoriteApi'
import { getActiveDomain } from '../service/api/MiscApi'
import type { PostReplyResult } from '../model/ThreadResult'
import type { PostInfo } from '../model/PostInfo'
import { VoteResult } from '../model/NgaApiResults'
import { getCachedBBNodes } from '../parser/bbcode/BBCodeCache'
import { AppColors, NAV_BAR_H } from '../common/constants/Constants'
import { PanelNavBar, NavBarMenuItem } from '../common/components/PanelNavBar'
import { PostItem } from '../common/components/PostItem'
import { LoadingStateView, ErrorStateView } from '../common/components/PageStateView'
import { HdsMaterialHost } from '../common/components/HdsMaterialHost'
import { ThreadTreeChildItem } from '../common/components/thread-tree/ThreadTreeChildItem'
import { ThreadTreeMoreItem } from '../common/components/thread-tree/ThreadTreeMoreItem'
import { floatingLayerStore, FloatingPage } from '../store/FloatingLayerStore'
import { replyManager } from '../common/managers/ReplyManager'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { TtsMediaMetadata } from '../common/media/TtsAvSessionController'
import { TtsPlayer } from '../common/media/TtsPlayer'
import { sharePost, shareThread } from '../common/utils/ShareUtils'
import { openImageViewer as sharedOpenImageViewer, handleForumLink } from '../common/utils/LinkUtils'
import { Logger, DOMAIN_UI, formatError } from '../common/utils/Logger'
import { getActiveAiValidationMessage } from '../service/ai/ActiveAiService'
import { bbNodesToPlainText } from '../common/utils/Utils'
import { UIMaterialManager } from '../common/managers/UIMaterialManager'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'
import {
  ThreadTreeModel,
  ThreadTreeRow,
  ThreadTreeRowKind,
  ThreadTreeChild,
  ThreadTreeQuoteRef
} from '../model/ThreadTree'
import {
  buildThreadTree,
  flattenThreadTree,
  expandRoot,
  findRootPidByPid
} from '../common/utils/ThreadTreeBuilder'
import { threadTreeFetchService, ThreadTreeFetchResult } from '../service/ThreadTreeFetchService'
import { ThreadTreeDataSource } from '../common/datasource/ThreadTreeDataSource'

const logger = new Logger(DOMAIN_UI, 'ThreadTreePanel')

/**
 * 帖子「两层递进树」阅读页面（独立栈页面）。
 *
 * 与自然列表页（ThreadPanel）**完全隔离**：本页面自己抓取全帖、自己展示加载进度、
 * 自己持有树模型与数据源，不读写 ThreadPanel 的分页窗口，也不与其共享渲染状态。
 *
 * 进入方式：
 * - 列表页更多菜单「递进树阅读」：push 本页（`fromListEntry = true`），返回即回列表页；
 * - 设置「帖子默认样式 = 递进树」：打开帖子时直接挂载本页（`fromListEntry = false`），
 *   「列表阅读」菜单项替换当前页为列表页。
 */
@Component
export struct ThreadTreePanel {
  /** 主题 ID。 */
  @Prop threadTid: string = ''
  /** 初始定位楼层 pid（空串表示定位顶部；主楼哨兵 '0' 已由路由层归一为空串）。 */
  @Prop threadPid: string = ''
  /** 是否由列表页 push 进入（决定「列表阅读」是返回还是替换当前页）。 */
  @Prop fromListEntry: boolean = false

  /** 全帖抓取中。 */
  @State isLoading: boolean = true
  /** 抓取失败。 */
  @State hasError: boolean = false
  /** 抓取失败原因。 */
  @State errorMsg: string = ''
  /** 抓取进度：已完成页数。 */
  @State progressDone: number = 0
  /** 抓取进度：总页数（第 1 页返回后确定）。 */
  @State progressTotal: number = 0
  /** 页面标题（加载完成后取主题标题）。 */
  @State threadSubject: string = '递进树'
  /** 树模型是否可渲染。 */
  @State treeReady: boolean = false
  /** 已点赞楼层 pid 集合。 */
  @State votedUpPids: Set<string> = new Set()
  /** 已点踩楼层 pid 集合。 */
  @State votedDownPids: Set<string> = new Set()
  /** 标题栏渐变模糊进度。 */
  @State titleScrollEffectProgress: number = 0
  /** List 视口高度（标题模糊映射用）。 */
  @State listViewportHeight: number = 1
  /** AI 任务候选（多任务时的选择弹窗）。 */
  @State aiTasks: AiAgentPreset[] = []

  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @StorageProp('navBarHeight') navBarHeight: number = 0

  /** 树模型（独立于任何分页窗口）。 */
  private treeModel: ThreadTreeModel | null = null
  /** 树 List 数据源（扁平可见行）。 */
  private treeDataSource: ThreadTreeDataSource = new ThreadTreeDataSource()
  /** 树 List 滚动控制器。 */
  private scroller: Scroller = new Scroller()
  /** 树 List 是否已挂载（挂载前 scrollToIndex 静默无效）。 */
  private listMounted: boolean = false
  /** 待定位楼层 pid（0 表示顶部）。 */
  private navigationPid: number = 0
  /** 是否等待 List 挂载后定位。 */
  private navigationPending: boolean = false
  /** 是否已为定位安排下一帧任务。 */
  private navigationScheduled: boolean = false
  /** 高亮清除计时器。 */
  private highlightTimer: number = -1
  /** 当前高亮楼层 pid。 */
  private highlightPid: number = 0
  /** 抓取代际：刷新/销毁时递增，使旧结果失效。 */
  private fetchGeneration: number = 0
  /**
   * 本页面实例标识（抓取服务的 owner）。
   *
   * 用于精确取消与串行化：同一帖子「返回再进入」会出现新旧两个页面实例，
   * 旧实例的销毁回调晚于新实例启动时不能误杀新任务（见 ThreadTreeFetchService 注释）。
   */
  private treeOwner: string = ''
  /** 主题 fid（回复/编辑协议用）。 */
  private threadFid: number = 0
  /** 楼主稳定作者标识（`authorKey` 语义，见 PostInfo）。 */
  private threadAuthorKey: string = ''
  /** 是否已取得可用楼主标识。 */
  private hasThreadAuthorKey: boolean = false
  /** AI 任务选择弹窗控制器。 */
  private aiTaskDialogController?: CustomDialogController
  /** 待处理 AI 任务的楼层。 */
  private aiTaskPost: PostInfo | null = null

  aboutToAppear(): void {
    this.treeOwner = 'tree-' + String(Date.now()) + '-' + String(Math.floor(Math.random() * 1000000))
    this.loadTree(false)
    this.loadPersistedVotes()
  }

  aboutToDisappear(): void {
    this.cancelWork()
    this.aiTaskDialogController = undefined
  }

  /**
   * 取消在途抓取并清空所有延迟任务。
   */
  private cancelWork(): void {
    this.fetchGeneration++
    threadTreeFetchService.cancel(this.treeOwner)
    this.navigationPending = false
    this.navigationScheduled = false
    if (this.highlightTimer >= 0) {
      clearTimeout(this.highlightTimer)
      this.highlightTimer = -1
    }
    this.highlightPid = 0
    this.listMounted = false
  }

  /**
   * 加载全帖并重建树（页面进入与「刷新递进树」共用）。
   *
   * @param keepSubject - 是否保留当前标题（刷新时避免标题短暂回退）
   */
  private loadTree(keepSubject: boolean): void {
    if (this.threadTid.length === 0) {
      this.isLoading = false
      this.hasError = true
      this.errorMsg = '缺少帖子 ID'
      return
    }
    this.fetchGeneration++
    const generation: number = this.fetchGeneration
    const fetchTid: string = this.threadTid
    this.isLoading = true
    this.hasError = false
    this.errorMsg = ''
    this.progressDone = 0
    this.progressTotal = 0
    this.treeReady = false
    this.treeDataSource.clear()
    logger.info('tree-panel load start tid=%{public}s gen=%{public}d', fetchTid, generation)
    threadTreeFetchService.fetchAll(this.treeOwner, fetchTid, (done: number, total: number): void => {
      if (generation !== this.fetchGeneration) {
        return
      }
      this.progressDone = done
      this.progressTotal = total
    }).then((result: ThreadTreeFetchResult): void => {
      if (generation !== this.fetchGeneration) {
        logger.warn('tree-panel load stale tid=%{public}s gen=%{public}d', fetchTid, generation)
        return
      }
      if (result.cancelled) {
        this.isLoading = false
        appStore.showToast('已取消加载递进树')
        if (this.fromListEntry) {
          routerStore.back()
        } else {
          this.hasError = true
          this.errorMsg = '已取消加载递进树'
        }
        return
      }
      if (!result.ok) {
        this.isLoading = false
        this.hasError = true
        this.errorMsg = result.error.length > 0 ? result.error : '加载失败'
        return
      }
      this.applyThreadInfo(keepSubject, result)
      const model: ThreadTreeModel = buildThreadTree(result.posts, result.totalPages)
      result.pageByPid.forEach((page: number, postPid: number): void => {
        model.pageByPid.set(postPid, page)
      })
      this.treeModel = model
      flattenThreadTree(model)
      this.treeDataSource.replaceAll(model.rows)
      this.treeReady = true
      this.isLoading = false
      this.navigationPid = this.threadPid.length > 0 ? parseInt(this.threadPid, 10) : 0
      this.navigationPending = true
      this.navigationScheduled = false
      this.scheduleNavigation()
      logger.info(
        'tree-panel load done tid=%{public}s posts=%{public}d roots=%{public}d rows=%{public}d quotes=%{public}d',
        fetchTid, model.totalPosts, model.roots.length, model.rows.length, model.quoteCount
      )
    }).catch((error: Object): void => {
      if (generation !== this.fetchGeneration) {
        return
      }
      this.isLoading = false
      this.hasError = true
      this.errorMsg = formatError(error)
      logger.error('tree-panel load failed tid=%{public}s: %{public}s', fetchTid, formatError(error))
    })
  }

  /**
   * 应用全帖抓取结果里的主题元数据（标题 / fid / 楼主标识）。
   *
   * @param keepSubject - 是否保留当前标题
   * @param result - 抓取结果
   */
  private applyThreadInfo(keepSubject: boolean, result: ThreadTreeFetchResult): void {
    if (result.threadInfo === null) {
      return
    }
    this.threadFid = result.threadInfo.fid
    this.threadAuthorKey = result.threadInfo.authorKey
    this.hasThreadAuthorKey = this.isAuthorKeyUsable(result.threadInfo.authorKey)
    if (keepSubject && this.threadSubject.length > 0 && this.threadSubject !== '递进树') {
      return
    }
    const subject: string = unescapeHtml(result.threadInfo.subject)
    this.threadSubject = subject.length > 0 ? subject : '递进树'
  }

  /**
   * 楼主标识是否可用于身份比较。
   *
   * @param authorKey - 稳定作者标识
   * @returns 可用于比较时为 true
   */
  private isAuthorKeyUsable(authorKey: string): boolean {
    if (authorKey.length === 0) {
      return false
    }
    const numeric: number = Number(authorKey)
    return isNaN(numeric) || numeric > 0
  }

  /**
   * 当前楼层是否楼主所发（匿名帖用稳定 authorKey 判定）。
   *
   * @param post - 楼层
   * @returns 是楼主所发时为 true
   */
  private isTopicAuthorPost(post: PostInfo): boolean {
    return this.hasThreadAuthorKey && post.authorKey === this.threadAuthorKey
  }

  // ==================== 树定位 ====================

  /**
   * 在树 List 挂载后安排下一帧定位。
   */
  private scheduleNavigation(): void {
    if (!this.navigationPending || this.navigationScheduled || !this.listMounted) {
      return
    }
    this.navigationScheduled = true
    setTimeout((): void => {
      this.navigationScheduled = false
      this.applyNavigation()
    }, 0)
  }

  /**
   * 执行树定位：目标行不可见时先展开其所属根，再居中滚动。
   */
  private applyNavigation(): void {
    if (!this.navigationPending || !this.listMounted) {
      return
    }
    this.navigationPending = false
    const pid: number = this.navigationPid
    if (pid <= 0) {
      this.scroller.scrollToIndex(0, false, ScrollAlign.START)
      return
    }
    let index: number = this.treeDataSource.findIndexByPid(pid)
    if (index < 0 && this.ensureRowVisible(pid)) {
      index = this.treeDataSource.findIndexByPid(pid)
    }
    if (index >= 0) {
      this.scroller.scrollToIndex(index, false, ScrollAlign.CENTER)
    } else {
      this.scroller.scrollToIndex(0, false, ScrollAlign.START)
    }
  }

  /**
   * 确保指定楼层行在树中可见（被折叠时展开其所属根）。
   *
   * @param pid - 目标楼层 pid
   * @returns 树模型中有该楼层时为 true
   */
  private ensureRowVisible(pid: number): boolean {
    const model: ThreadTreeModel | null = this.treeModel
    if (model === null || pid <= 0) {
      return false
    }
    if (this.treeDataSource.findIndexByPid(pid) >= 0) {
      return true
    }
    const rootPid: number = findRootPidByPid(model, pid)
    if (rootPid < 0) {
      return false
    }
    if (rootPid === pid) {
      return true
    }
    expandRoot(model, rootPid)
    flattenThreadTree(model)
    this.treeDataSource.replaceAll(model.rows)
    return this.treeDataSource.findIndexByPid(pid) >= 0
  }

  /**
   * 展开某根全部子节点（折叠行点击）。
   *
   * @param rootPid - 根节点 pid
   */
  private expandTreeRoot(rootPid: number): void {
    const model: ThreadTreeModel | null = this.treeModel
    if (model === null || !expandRoot(model, rootPid)) {
      return
    }
    flattenThreadTree(model)
    this.treeDataSource.replaceAll(model.rows)
  }

  /**
   * 树内跳转到指定楼层（子节点头部「→」/ 同帖链接）。
   *
   * @param pid - 目标楼层 pid
   */
  private treeJumpToPid(pid: number): void {
    const model: ThreadTreeModel | null = this.treeModel
    if (model === null) {
      return
    }
    if (pid <= 0) {
      this.scroller.scrollToIndex(0, false, ScrollAlign.START)
      return
    }
    if (!this.ensureRowVisible(pid)) {
      appStore.showToast('该楼层不存在或已删除')
      return
    }
    const index: number = this.treeDataSource.findIndexByPid(pid)
    if (index < 0) {
      return
    }
    this.scroller.scrollToIndex(index, false, ScrollAlign.CENTER)
    this.highlightRow(pid)
  }

  /**
   * 高亮命中的子节点行，2 秒后清除。
   *
   * @param pid - 命中楼层 pid
   */
  private highlightRow(pid: number): void {
    const row: ThreadTreeRow | null = this.treeDataSource.findRowByPid(pid)
    if (row === null || row.kind !== ThreadTreeRowKind.CHILD) {
      return
    }
    const index: number = this.treeDataSource.findIndexByPid(pid)
    if (index < 0) {
      return
    }
    if (this.highlightTimer >= 0) {
      clearTimeout(this.highlightTimer)
      this.highlightTimer = -1
    }
    row.highlighted = true
    row.rev++
    this.highlightPid = pid
    this.treeDataSource.updateAt(index, row)
    this.highlightTimer = setTimeout((): void => {
      this.highlightTimer = -1
      const targetPid: number = this.highlightPid
      this.highlightPid = 0
      if (targetPid <= 0) {
        return
      }
      const current: ThreadTreeRow | null = this.treeDataSource.findRowByPid(targetPid)
      if (current === null) {
        return
      }
      const currentIndex: number = this.treeDataSource.findIndexByPid(targetPid)
      if (currentIndex < 0) {
        return
      }
      current.highlighted = false
      current.rev++
      this.treeDataSource.updateAt(currentIndex, current)
    }, 2000)
  }

  /**
   * 由树行构造子节点组件入参（引用头缺作者名时用目标楼层补齐）。
   *
   * @param row - 树行（`kind === CHILD`）
   * @returns 子节点数据
   */
  private buildTreeChild(row: ThreadTreeRow): ThreadTreeChild {
    const child: ThreadTreeChild = new ThreadTreeChild()
    if (row.post !== null) {
      child.post = row.post
    }
    if (row.ref !== null) {
      child.ref = row.ref
      const model: ThreadTreeModel | null = this.treeModel
      if (child.ref.targetAuthor.length === 0 && child.ref.targetPid > 0 && model !== null) {
        const target: PostInfo | undefined = model.postByPid.get(child.ref.targetPid)
        if (target !== undefined) {
          const filled: ThreadTreeQuoteRef = new ThreadTreeQuoteRef()
          filled.targetPid = child.ref.targetPid
          filled.targetPage = child.ref.targetPage
          filled.targetUid = child.ref.targetUid.length > 0 ? child.ref.targetUid : String(target.authorid)
          filled.targetAuthor = target.author
          filled.rawHeader = child.ref.rawHeader
          filled.isTopicRef = child.ref.isTopicRef
          filled.external = child.ref.external
          child.ref = filled
        }
      }
    }
    child.highlighted = row.highlighted
    return child
  }

  /**
   * 取子节点对应的被回复楼层号。
   *
   * @param ref - 引用关系
   * @returns 楼层号（0=楼主；-1=未知）
   */
  private targetLou(ref: ThreadTreeQuoteRef | null): number {
    if (ref === null || ref.targetPid <= 0 || this.treeModel === null) {
      return -1
    }
    const target: PostInfo | undefined = this.treeModel.postByPid.get(ref.targetPid)
    return target !== undefined ? target.lou : -1
  }

  /**
   * 树行 LazyForEach 键值。
   *
   * @param row - 树行
   * @returns 稳定键值
   */
  private rowKey(row: ThreadTreeRow): string {
    const pid: number = row.post !== null ? row.post.pid : row.rootPid
    const highlight: string = row.highlighted ? '_h' : ''
    return String(row.kind) + '_' + String(pid) + '_' + String(row.rev) + highlight
  }

  // ==================== 交互 ====================

  /**
   * 回复/编辑发送成功后刷新全帖树。
   *
   * @param successText - 成功提示
   */
  private refreshAfterSubmit(successText: string): void {
    appStore.showToast(successText)
    this.loadTree(true)
  }

  /**
   * 发送楼层回复 / 主题回复（编辑器在全局浮层中）。
   *
   * @param text - 回复正文
   * @param isAnony - 是否匿名
   */
  private async handleReplySend(text: string, isAnony: boolean): Promise<void> {
    let result: PostReplyResult
    try {
      result = await replyManager.send(text, isAnony)
    } catch (e) {
      appStore.showToast((e as Error).message || '操作失败')
      throw new Error((e as Error).message || '操作失败')
    }
    if (!result.ok) {
      appStore.showToast(result.error || '操作失败')
      throw new Error(result.error || '操作失败')
    }
    this.refreshAfterSubmit('回复成功')
  }

  /**
   * 发送编辑修改。
   *
   * @param text - 新正文
   * @param isAnony - 是否匿名
   */
  private async handleEditSend(text: string, isAnony: boolean): Promise<void> {
    let result: PostReplyResult
    try {
      result = await replyManager.send(text, isAnony)
    } catch (e) {
      appStore.showToast((e as Error).message || '编辑失败')
      throw new Error((e as Error).message || '编辑失败')
    }
    if (!result.ok) {
      appStore.showToast(result.error || '编辑失败')
      throw new Error(result.error || '编辑失败')
    }
    this.refreshAfterSubmit('编辑成功')
  }

  /**
   * 打开楼层回复编辑器。
   *
   * @param post - 目标楼层
   */
  private openFloorReply(post: PostInfo): void {
    let page: number = 1
    if (this.treeModel !== null) {
      const mapped: number | undefined = this.treeModel.pageByPid.get(post.pid)
      if (mapped !== undefined && mapped > 0) {
        page = mapped
      }
    }
    replyManager.startFloorReply(post, Number(this.threadTid), this.threadFid, page)
    floatingLayerStore.replyDialogTitle = replyManager.dialogTitle
    floatingLayerStore.replyOnSend = (text: string, isAnony: boolean): Promise<void> => {
      return this.handleReplySend(text, isAnony)
    }
    floatingLayerStore.editMode = false
    floatingLayerStore.push(FloatingPage.REPLY_DIALOG)
  }

  /**
   * 打开编辑编辑器。
   *
   * @param post - 目标楼层
   */
  private openEdit(post: PostInfo): void {
    replyManager.startEdit(post, Number(this.threadTid), this.threadFid)
    floatingLayerStore.replyDialogTitle = replyManager.dialogTitle
    floatingLayerStore.editMode = true
    floatingLayerStore.editInitialContent = unescapeHtml(post.content).replace(/<br\s*\/?>/gi, '\n')
    floatingLayerStore.replyOnSend = (_text: string, _isAnony: boolean): Promise<void> => {
      return this.handleEditSend(_text, _isAnony)
    }
    floatingLayerStore.push(FloatingPage.REPLY_DIALOG)
  }

  /**
   * 打开主题回复编辑器。
   */
  private openThreadReply(): void {
    replyManager.startThreadReply(Number(this.threadTid), this.threadFid)
    floatingLayerStore.replyDialogTitle = replyManager.dialogTitle
    floatingLayerStore.editMode = false
    floatingLayerStore.replyOnSend = (text: string, isAnony: boolean): Promise<void> => {
      return this.handleReplySend(text, isAnony)
    }
    floatingLayerStore.push(FloatingPage.REPLY_DIALOG)
  }

  /**
   * 点赞 / 点踩。
   *
   * @param post - 楼层
   * @param value - 1=赞，-1=踩
   * @returns 投票结果
   */
  private async handleVote(post: PostInfo, value: number): Promise<VoteResult> {
    if (!appStore.auth.isAuthenticated) {
      appStore.showToast('请先登录')
      const denied: VoteResult = new VoteResult()
      denied.error = '请先登录'
      return denied
    }
    const pidKey: string = String(post.pid)
    const wasUp: boolean = this.votedUpPids.has(pidKey)
    const wasDown: boolean = this.votedDownPids.has(pidKey)
    const result: VoteResult = await votePost(appStore.auth.token, Number(this.threadTid), post.pid, value)
    if (!result.ok) {
      appStore.showToast(result.error || '操作失败')
      return result
    }
    const expectedState: number = value === 1 ? (wasUp ? 0 : 1) : (wasDown ? 0 : -1)
    const effectiveState: number = result.ok ? expectedState : result.state
    const upPids: Set<string> = new Set(this.votedUpPids)
    const downPids: Set<string> = new Set(this.votedDownPids)
    if (effectiveState === 1) {
      upPids.add(pidKey)
      downPids.delete(pidKey)
    } else if (effectiveState === -1) {
      downPids.add(pidKey)
      upPids.delete(pidKey)
    } else {
      upPids.delete(pidKey)
      downPids.delete(pidKey)
    }
    this.votedUpPids = upPids
    this.votedDownPids = downPids
    appStore.saveVoteRecord(appStore.auth.uid, this.threadTid, upPids, downPids)
    if (result.message.length > 0) {
      appStore.showToast(result.message)
    }
    return result
  }

  /**
   * 读取本账号在当前帖子的历史投票记录。
   */
  private async loadPersistedVotes(): Promise<void> {
    if (!appStore.auth.isAuthenticated) {
      return
    }
    const result = await appStore.loadVoteRecord(appStore.auth.uid, this.threadTid)
    this.votedUpPids = result[0]
    this.votedDownPids = result[1]
  }

  /**
   * 打开用户资料卡（屏幕内收敛位置）。
   *
   * @param uid - 用户 uid
   * @param screenX - 点击点 x
   * @param screenY - 点击点 y
   */
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
    floatingLayerStore.openProfileCard(uid, posX, posY)
  }

  /**
   * 打开图片查看器。
   *
   * @param urls - 图片地址集
   * @param index - 起始下标
   */
  private openImageViewer(urls: string[], index: number): void {
    sharedOpenImageViewer(urls, index)
  }

  /**
   * 正文链接：同帖楼层链接在树内定位，其余交给全局链接处理器。
   *
   * @param href - 链接
   */
  private handleLinkClick(href: string): void {
    if (href.startsWith('#/thread?')) {
      const query: string = href.substring(href.indexOf('?') + 1)
      let linkTid: string = ''
      let linkPid: string = ''
      const parts: string[] = query.split('&')
      for (let i: number = 0; i < parts.length; i++) {
        const kv: string[] = parts[i].split('=')
        if (kv.length === 2) {
          if (kv[0] === 'tid') linkTid = kv[1]
          if (kv[0] === 'pid') linkPid = kv[1]
        }
      }
      if (linkTid === this.threadTid && linkPid.length > 0) {
        const linkPidNumber: number = parseInt(linkPid, 10)
        if (this.treeModel !== null && this.treeModel.postByPid.has(linkPidNumber)) {
          this.treeJumpToPid(linkPidNumber)
          return
        }
        appStore.showToast('该楼层不在递进树中')
        return
      }
    }
    handleForumLink(href, this.getUIContext().getHostContext() as common.UIAbilityContext, (uid: string) => {
      this.showProfileCard(uid, 200, 200)
    })
  }

  /**
   * 朗读楼层正文。
   *
   * @param p - 楼层
   */
  private readAloud(p: PostInfo): void {
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
  }

  /**
   * 打开 AI 任务选择（帖子入口）。
   *
   * @param p - 楼层
   */
  private beginAiSummarize(p: PostInfo): void {
    const aiValidationMessage: string = getActiveAiValidationMessage()
    if (aiValidationMessage.length > 0) {
      appStore.showToast(aiValidationMessage)
      return
    }
    const plainText: string = bbNodesToPlainText(getCachedBBNodes(p.content))
    if (plainText.trim().length === 0) {
      appStore.showToast('该楼层没有可处理的内容')
      return
    }
    const tasks: AiAgentPreset[] = appStore.settingsStore.listAiPresetsByEntry(PRESET_ENTRY_THREAD)
    this.aiTaskPost = p
    if (tasks.length === 0) {
      this.launchAiTask(null, p, 'AI 助手')
      return
    }
    if (tasks.length === 1) {
      this.launchAiTask(tasks[0], p, tasks[0].name)
      return
    }
    const next: AiAgentPreset[] = []
    for (let i: number = 0; i < tasks.length; i++) {
      next.push(tasks[i])
    }
    this.aiTasks = next
    this.aiTaskDialogController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: CustomContentDialog({
        primaryTitle: '选择 AI 任务',
        contentBuilder: (): void => { this.aiTaskContent() },
        buttons: [{ value: '取消' }]
      }),
      autoCancel: true
    })
    this.aiTaskDialogController.open()
  }

  /**
   * 启动 AI 任务（跳转 AI 对话页，由任务读取楼层内容）。
   *
   * @param preset - 任务（null 表示自由对话）
   * @param p - 楼层
   * @param title - 页面标题
   */
  private launchAiTask(preset: AiAgentPreset | null, p: PostInfo, title: string): void {
    TtsPlayer.stop()
    const presetId: string = preset !== null ? preset.id : ''
    const floorText: string = '当前帖子第 ' + p.lou.toString() + ' 楼（作者 ' + p.author + '）'
    const prompt: string = preset === null
      ? '请读取' + floorText + '的内容并总结；需要正文或其它楼层时，调用读帖工具读取。'
      : '请读取' + floorText + '的内容，按任务要求完成；需要正文或其它楼层时，调用读帖工具读取。'
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ai/AiChatPage',
      params: {
        presetId: presetId,
        title: title,
        tid: this.threadTid,
        pid: p.pid.toString(),
        threadTitle: this.threadSubject,
        initialPrompt: prompt
      }
    })
  }

  /** AI 任务选择弹窗内容。 */
  @Builder
  aiTaskContent() {
    Column() {
      ForEach(this.aiTasks, (task: AiAgentPreset) => {
        Row() {
          Column() {
            Text(task.name).fontSize(15).fontColor(AppColors.textPrimary)
            if (task.description.length > 0) {
              Text(task.description)
                .fontSize(11).fontColor(AppColors.textTertiary).lineHeight(16)
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 2 })
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text('›').fontSize(18).fontColor(AppColors.chevron)
        }
        .width('100%')
        .padding({ top: 10, bottom: 10 })
        .alignItems(VerticalAlign.Center)
        .onClick((): void => {
          this.aiTaskDialogController?.close()
          const post: PostInfo | null = this.aiTaskPost
          if (post !== null) {
            this.launchAiTask(task, post, task.name)
          }
        })
      }, (task: AiAgentPreset): string => task.id)
    }
    .width('100%')
  }

  // ==================== 标题滚动效果 ====================

  /**
   * 按 List 滚动偏移同步标题栏渐变进度。
   */
  private syncTitleScrollEffect(): void {
    const progress: number = TitleScrollEffect.getProgress(
      this.scroller.currentOffset().yOffset,
      this.statusBarHeight
    )
    if (TitleScrollEffect.shouldUpdateProgress(this.titleScrollEffectProgress, progress)) {
      this.titleScrollEffectProgress = progress
    }
  }

  /**
   * 标题区渐变模糊的停靠点。
   *
   * @returns 停靠点数组
   */
  private getTitleBlurStops(): FractionStop[] {
    return TitleScrollEffect.getBlurStops(this.listViewportHeight, this.statusBarHeight)
  }

  // ==================== 菜单 ====================

  /**
   * 更多菜单项。
   *
   * @returns 菜单项
   */
  private moreMenuItems(): NavBarMenuItem[] {
    const items: NavBarMenuItem[] = []
    items.push({
      label: '刷新递进树',
      action: (): void => {
        this.loadTree(true)
      }
    })
    items.push({
      label: '列表阅读',
      action: (): void => {
        if (this.fromListEntry) {
          routerStore.back()
        } else {
          // 默认树样式直接打开时：替换当前页为**强制列表**的帖子页，避免再次被分流回树页
          routerStore.navigateActivity(Screen.threadList(this.threadTid), true)
        }
      }
    })
    items.push({
      label: '从网页打开',
      action: (): void => {
        const threadUrl: string = getActiveDomain() + '/read.php?tid=' + this.threadTid
        routerStore.navigateActivity(Screen.webview(threadUrl))
      }
    })
    items.push({
      label: '分享帖子',
      action: (): void => {
        let hostCtx: Context | undefined = this.getUIContext().getHostContext()
        if (hostCtx !== undefined) {
          let ctx: Context = hostCtx
          shareThread(ctx, Number(this.threadTid), this.threadSubject)
        }
      }
    })
    return items
  }

  // ==================== UI ====================

  build() {
    Stack() {
      Column() {
        if (this.isLoading) {
          this.LoadingState()
        } else if (this.hasError) {
          this.ErrorState()
        } else if (this.treeReady) {
          this.TreeList()
        }
      }
      .width('100%').height('100%')

      PanelNavBar({
        title: this.threadSubject,
        rightIcon: $r('app.media.icon_more'),
        scrollEffectProgress: this.titleScrollEffectProgress,
        hasMenu: true,
        menuItemsProvider: (): NavBarMenuItem[] => this.moreMenuItems()
      })
        .width('100%').position({ x: 0, y: 0 })

      if (this.treeReady && !this.isLoading) {
        this.BottomBar()
      }
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg).alignContent(Alignment.BottomEnd)
  }

  /**
   * 全帖抓取中的加载态：进度（页数 / 百分比）+ 取消。
   *
   * 取消按钮在总页数未知（第 1 页尚未返回）时同样可用：首屏请求也可能卡满超时，
   * 不能只在拿到 totalPages 之后才允许退出。
   */
  @Builder
  LoadingState() {
    Column() {
      LoadingStateView()
      Column({ space: 8 }) {
        if (this.progressTotal > 0) {
          Text('正在加载全部楼层 ' + String(this.progressDone) + '/' + String(this.progressTotal) + ' 页')
            .fontSize(14).fontColor(AppColors.textSecondary)
          Progress({
            value: this.progressDone,
            total: this.progressTotal,
            type: ProgressType.Linear
          })
            .width(180).height(4)
            .color(AppColors.primary)
            .borderRadius(2)
        } else {
          Text('正在加载帖子…')
            .fontSize(14).fontColor(AppColors.textSecondary)
        }
        Text('取消')
          .fontSize(14).fontColor(AppColors.destructive)
          .padding({ top: 6, bottom: 6, left: 12, right: 12 })
          .onClick((): void => {
            threadTreeFetchService.cancel(this.treeOwner)
          })
      }
      .margin({ top: 20 })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%').layoutWeight(1)
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .padding({ top: NAV_BAR_H + this.statusBarHeight })
  }

  /**
   * 加载失败态：原因 + 重试。
   */
  @Builder
  ErrorState() {
    Column() {
      ErrorStateView({
        msg: this.errorMsg,
        onRetry: (): Promise<void> => {
          this.loadTree(true)
          return Promise.resolve()
        }
      })
    }
    .width('100%').layoutWeight(1)
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .padding({ top: NAV_BAR_H + this.statusBarHeight })
  }

  /**
   * 根节点行：完整楼层卡片（与自然列表同一套 PostItem）。
   *
   * @param post - 楼层
   * @param displayContent - 树模式正文（已剥离引用区）
   */
  @Builder
  postCell(post: PostInfo, displayContent: string) {
    PostItem({
      post: post,
      displayContent: displayContent,
      showContent: displayContent.length > 0,
      isVotedUp: this.votedUpPids.has(String(post.pid)),
      isVotedDown: this.votedDownPids.has(String(post.pid)),
      holdingHand: 0,
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
      onVote: (p: PostInfo, value: number): Promise<VoteResult> => {
        return this.handleVote(p, value)
      },
      onReply: (p: PostInfo): void => {
        this.openFloorReply(p)
      },
      onEdit: (p: PostInfo): void => {
        this.openEdit(p)
      },
      onShare: (p: PostInfo): void => {
        let hostCtx: Context | undefined = this.getUIContext().getHostContext()
        if (hostCtx !== undefined) {
          let ctx: Context = hostCtx
          sharePost(ctx, p, this.threadSubject)
        }
      },
      onSummarize: (p: PostInfo): void => {
        this.beginAiSummarize(p)
      },
      onReadAloud: (p: PostInfo): void => {
        this.readAloud(p)
      },
      isTopicAuthor: this.isTopicAuthorPost(post),
      isOwnPost: appStore.auth.isAuthenticated && String(post.authorid) === appStore.auth.uid,
    })
  }

  /**
   * 两层树列表（独立 List / 数据源，不参与任何分页窗口）。
   */
  @Builder
  TreeList() {
    List({ scroller: this.scroller }) {
      LazyForEach(this.treeDataSource, (row: ThreadTreeRow) => {
        ListItem() {
          if (row.kind === ThreadTreeRowKind.ROOT && row.post !== null) {
            this.postCell(row.post, row.displayContent)
          } else if (row.kind === ThreadTreeRowKind.CHILD && row.post !== null) {
            ThreadTreeChildItem({
              child: this.buildTreeChild(row),
              targetLou: this.targetLou(row.ref),
              displayContent: row.displayContent,
              showContent: row.displayContent.length > 0,
              isVotedUp: this.votedUpPids.has(String(row.post.pid)),
              isVotedDown: this.votedDownPids.has(String(row.post.pid)),
              holdingHand: 0,
              isTopicAuthor: this.isTopicAuthorPost(row.post),
              isOwnPost: appStore.auth.isAuthenticated && String(row.post.authorid) === appStore.auth.uid,
              highlight: row.highlighted,
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
              onJumpToPid: (pid: number): void => {
                this.treeJumpToPid(pid)
              },
              onVote: (p: PostInfo, value: number): Promise<VoteResult> => {
                return this.handleVote(p, value)
              },
              onReply: (p: PostInfo): void => {
                this.openFloorReply(p)
              },
              onEdit: (p: PostInfo): void => {
                this.openEdit(p)
              },
              onShare: (p: PostInfo): void => {
                let hostCtx: Context | undefined = this.getUIContext().getHostContext()
                if (hostCtx !== undefined) {
                  let ctx: Context = hostCtx
                  sharePost(ctx, p, this.threadSubject)
                }
              },
              onSummarize: (p: PostInfo): void => {
                this.beginAiSummarize(p)
              },
              onReadAloud: (p: PostInfo): void => {
                this.readAloud(p)
              },
            })
          } else {
            ThreadTreeMoreItem({
              totalCount: row.totalCount,
              onExpand: (): void => {
                this.expandTreeRoot(row.rootPid)
              }
            })
          }
        }
      }, (row: ThreadTreeRow) => this.rowKey(row))
    }
    .width('100%').layoutWeight(1)
    .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .cachedCount(6)
    // 折叠行展开（整体 replaceAll）时保持可见内容位置，避免插入子行后视口跳动
    .maintainVisibleContentPosition(true)
    .linearGradientBlur(
      TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),
      {
        fractionStops: this.getTitleBlurStops(),
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
      this.listMounted = true
      this.syncTitleScrollEffect()
      this.scheduleNavigation()
    })
    .onDisAppear((): void => {
      this.listMounted = false
    })
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
  }

  /**
   * 底部悬浮回复按钮（回复主题）。
   */
  @Builder
  BottomBar() {
    Row({ space: 8 }) {
      HdsMaterialHost({
        barWidth: 40,
        barHeight: 40,
        onTap: (): void => {
          this.openThreadReply()
        }
      }) {
        Stack() {
          Image($r('app.media.icon_reply'))
            .width(20).height(20).fillColor(UIMaterialManager.adaptiveForeground)
            .draggable(false)
        }
        .width('100%').height('100%').alignContent(Alignment.Center)
      }
    }
    .width('100%').padding({ left: 16, right: 16, bottom: 16 + this.navBarHeight })
    .justifyContent(FlexAlign.End)
  }
}
