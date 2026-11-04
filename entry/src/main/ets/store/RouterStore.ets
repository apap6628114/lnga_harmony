/**
 * 路由状态管理 - 复刻 React router.ts
 * 三列适配模式: boardSlot(中间列) + activityStack(右侧列)
 * 所有断点统一使用 RouterStore 导航, 不再使用 router.pushUrl
 */

export type LayoutMode = 'sm' | 'md' | 'lg'
export type SidebarTab = 'community' | 'me'

export type BoardType = 'forum' | 'search'

export class BoardSlot {
  type: BoardType = 'forum'
  fid: number = 0
  name: string = ''
  stid: string = ''
  authorid: string = ''
  favor: string = ''
  searchKey: string = ''
  author: string = ''
  searchpost: string = ''

  constructor(
    fid: number, name: string, stid: string = '',
    authorid: string = '', favor: string = '',
    searchKey: string = '', author: string = '',
    searchpost: string = ''
  ) {
    this.fid = fid
    this.name = name
    this.stid = stid
    this.authorid = authorid
    this.favor = favor
    this.searchKey = searchKey
    this.author = author
    this.searchpost = searchpost
  }

  /**
   * 创建搜索面板路由槽位。
   *
   * @param fid - 限定搜索的版块 fid；0 表示全局搜索
   * @param name - 限定搜索的版块名（用于 UI 提示）
   * @param stid - 限定搜索的专题版块 stid；为空时按 fid 搜索
   * @returns 搜索面板槽位
   */
  static search(fid: number = 0, name: string = '', stid: string = ''): BoardSlot {
    const b = new BoardSlot(fid, name, stid)
    b.type = 'search'
    return b
  }
}

export type ScreenType =
  | 'thread'
  | 'threadTree'
  | 'profile'
  | 'notifications'
  | 'messages'
  | 'messageDetail'
  | 'blacklist'
  | 'notes'
  | 'filterKeywords'
  | 'settings'
  | 'browseHistory'
  | 'followList'
  | 'topicList'
  | 'webview'
  | 'ttsSettings'
  | 'aiSettings'
  | 'fontSizeSettings'
  | 'favoriteFolders'
  | 'favoriteSaved'
  | 'dataManagement'

/**
 * 帖子路由来源。
 *
 * 显式标注打开帖子的入口，由入口在 Screen.thread 时写入并透传到 ThreadPanel，
 * 当前用于运行态诊断日志（thread open ... source=...）；同时保留按来源限定
 * 定位行为的扩展点（如仅对无页码来源启用 pid→页码预查找），比从路由参数
 * 推断更精准。
 *
 * 完整标注映射（全工程 Screen.thread 调用点，缺标即 DEFAULT）：
 * - TOPIC_LIST：主题列表面板（普通版块/收藏夹/用户主题/热门聚合/用户回帖
 *   searchpost，含发帖成功跳转）
 * - NOTIFICATION：消息中心（支持或反对 / 回复提醒）
 * - LINK：应用内/外部帖子链接（read.php / #/thread，带页码或仅 pid）
 * - SEARCH：搜索面板搜索结果
 * - BROWSE_HISTORY：浏览历史
 * - SAVED：保存的帖子离线存档（数据源分流为本地存档读取）
 * - TRACKED：跟踪帖子更新（消息面板「跟踪」Tab / 收藏保存面板跟踪 Tab）
 */
export enum ThreadSource {
  /** 未标注来源（无 pid 定位需求的默认入口）。 */
  DEFAULT = '',
  /** 主题列表面板（含用户回帖列表 searchpost）：可能仅 pid、页码未知。 */
  TOPIC_LIST = 'topic-list',
  /** 消息中心通知进入：携带服务端提示页码。 */
  NOTIFICATION = 'notification',
  /** 应用内/外部链接进入：可能携带页码或仅 pid。 */
  LINK = 'link',
  /** 搜索面板搜索结果进入。 */
  SEARCH = 'search',
  /** 浏览历史进入。 */
  BROWSE_HISTORY = 'browse-history',
  /** 保存的帖子离线存档进入：ThreadPanel 从本地存档读取数据而非请求服务器。 */
  SAVED = 'saved',
  /** 跟踪帖子更新进入（打开即推进该帖的跟踪已读基准）。 */
  TRACKED = 'tracked',
}

export class Screen {
  type: ScreenType = 'thread'
  tid: string = ''
  threadPage: number = 1
  pid: string = ''
  /** 打开帖子的路由来源（ThreadSource）。 */
  threadSource: string = ''
  /**
   * 帖子页强制使用自然列表样式（忽略设置里的默认阅读样式）。
   *
   * 由递进树页的「切换为列表阅读」/ 加载中的「以常规列表打开」生成：默认样式为递进树时，
   * 普通 `Screen.thread` 会被 ActivityRouter 再次分流回树页，必须显式声明要走列表页。
   */
  threadForceList: boolean = false
  /**
   * 帖子页初始「只看楼主」状态。
   *
   * 列表页与递进树页共用：切换阅读方式时沿用当前过滤状态；两种阅读样式的
   * 「只看楼主」语义一致（只看楼主楼层），列表页由服务端/本地过滤，树页按作者重建树。
   */
  threadAuthorOnly: boolean = false
  /**
   * 帖子页初始楼主 uid（`只看楼主` 首屏服务端过滤用）。
   *
   * 由递进树页切换过来时携带：列表页首屏请求前还没有主楼响应，缺了它「只看楼主」
   * 会先按无过滤请求一次、出现整帖楼层闪一下再被过滤。
   */
  threadAuthorId: string = ''
  /**
   * 帖子页初始楼主稳定作者标识（匿名帖本地过滤用，语义见 `PostInfo.authorKey`）。
   */
  threadAuthorKey: string = ''
  uid: string = ''
  mid: string = ''
  messagePage: number = 1
  composeTo: string = ''
  /** 通知页初始筛选 Tab（0=消息，1=私信，2=动态）。 */
  notificationsInitialTab: number = 0
  /** 直达写私信的初始收件人（随 notifications/messages 路由透传）。 */
  notificationsComposeTo: string = ''
  topicListName: string = ''
  topicListFid: number = 0
  topicListAuthorid: string = ''
  topicListFavor: string = ''
  topicListSearchpost: string = ''
  /** 进入收藏夹选择模式时对应的 NGA 主题 ID。 */
  favoriteTopicId: string = ''
  /** 关注/粉丝列表页的初始 Tab（FollowListTab）。 */
  followListMode: number = 0
  webviewUrl: string = ''

  static webview(url: string): Screen {
    const s = new Screen()
    s.type = 'webview'
    s.webviewUrl = url
    return s
  }

  static thread(tid: string, page: number = 1, pid: string = '', source: string = ''): Screen {
    const s = new Screen()
    s.type = 'thread'
    s.tid = tid
    s.threadPage = page
    // '0' 是 NGA 的"主楼/无楼层"哨兵值（主楼 pid 即为 0），统一归一为空串，
    // 表示无楼层定位意图——ThreadPanel 无需再区分哨兵与真实 pid
    s.pid = pid === '0' ? '' : pid
    s.threadSource = source
    return s
  }

  /**
   * 创建**强制自然列表样式**的帖子页路由。
   *
   * 用于递进树页的「切换为列表阅读」与加载中的「以常规列表打开」：默认阅读样式为
   * 递进树时，普通 `Screen.thread` 会被 ActivityRouter 再次分流到树页；本工厂显式声明走列表页。
   *
   * **两种阅读样式互斥**：切换由 `navigateActivity(screen, true)` 原地替换当前栈条目完成，
   * 被替换掉的递进树条目随即移除、页面实例销毁，栈里不会同时存在同一帖子的两个阅读样式。
   *
   * **不携带楼层位置**：列表页与树页各自维护独立的阅读进度（`reading_progress` /
   * `tree_reading_progress`），切换后由目标页恢复它自己的进度，避免一种样式的位置
   * 覆盖另一种样式的进度记录。只透传「只看楼主」、楼主身份与路由来源。
   *
   * @param tid - 主题 ID
   * @param authorOnly - 是否只看楼主
   * @param authorId - 楼主 uid（只看楼主首屏过滤用，未知传空串）
   * @param authorKey - 楼主稳定作者标识（匿名帖本地过滤用，未知传空串）
   * @param source - 打开帖子的来源（ThreadSource）；替换页面后来源只能随路由携带，
   *   否则阅读进度恢复白名单等来源语义会失准
   * @returns 帖子页路由（强制列表样式）
   */
  static threadList(tid: string, authorOnly: boolean = false, authorId: string = '',
    authorKey: string = '', source: string = ''): Screen {
    const s = Screen.thread(tid)
    s.threadForceList = true
    s.threadAuthorOnly = authorOnly
    s.threadAuthorId = authorId
    s.threadAuthorKey = authorKey
    s.threadSource = source
    return s
  }

  /**
   * 创建帖子「两层递进树」阅读页面路由。
   *
   * 递进树是**独立渲染的页面组件**：自己加载全帖、自己展示加载进度、自己渲染；
   * 与自然列表页互不共享状态。两种阅读样式**互斥**：切换一律用
   * `navigateActivity(screen, true)` 原地替换当前栈条目，被替换的列表页实例销毁，
   * 返回时不会再退回到另一种阅读样式。
   *
   * @param tid - 主题 ID
   * @param pid - 可选的初始定位楼层 pid（空串表示无定位意图：由树页按自己的阅读进度恢复；
   *   从列表页「切换阅读方式」进入时固定传空串，不把列表当前楼层带进树页）
   * @param authorOnly - 是否只看楼主（列表页切换阅读方式时沿用）
   * @param source - 打开帖子的来源（ThreadSource）；列表页切换过来时随路由携带
   * @param authorId - 楼主 uid（列表页切换过来时已知，抓取结果返回前用它维持只看楼主与标题屏蔽）
   * @param authorKey - 楼主稳定作者标识（匿名帖本地过滤用，同样在抓取结果前维持过滤）
   * @returns 递进树页面路由
   */
  static threadTree(tid: string, pid: string = '', authorOnly: boolean = false,
    source: string = '', authorId: string = '', authorKey: string = ''): Screen {
    const s = new Screen()
    s.type = 'threadTree'
    s.tid = tid
    s.pid = pid === '0' ? '' : pid
    s.threadAuthorOnly = authorOnly
    s.threadSource = source
    s.threadAuthorId = authorId
    s.threadAuthorKey = authorKey
    return s
  }

  static profile(uid: string): Screen {
    const s = new Screen()
    s.type = 'profile'
    s.uid = uid
    return s
  }

  static messageDetail(mid: string, page: number = 1): Screen {
    const s = new Screen()
    s.type = 'messageDetail'
    s.mid = mid
    s.messagePage = page
    return s
  }

  static messages(composeTo: string = ''): Screen {
    const s = new Screen()
    s.type = 'messages'
    s.composeTo = composeTo
    return s
  }

  static notifications(initialTab: number = 0, composeTo: string = ''): Screen {
    const s = new Screen()
    s.type = 'notifications'
    s.notificationsInitialTab = initialTab
    s.notificationsComposeTo = composeTo
    return s
  }

  static blacklist(): Screen {
    const s = new Screen()
    s.type = 'blacklist'
    return s
  }

  static notes(): Screen {
    const s = new Screen()
    s.type = 'notes'
    return s
  }

  static filterKeywords(): Screen {
    const s = new Screen()
    s.type = 'filterKeywords'
    return s
  }

  static settings(): Screen {
    const s = new Screen()
    s.type = 'settings'
    return s
  }

  static browseHistory(): Screen {
    const s = new Screen()
    s.type = 'browseHistory'
    return s
  }

  static followList(mode: number = 0): Screen {
    const s = new Screen()
    s.type = 'followList'
    s.followListMode = mode
    return s
  }

  static ttsSettings(): Screen {
    const s = new Screen()
    s.type = 'ttsSettings'
    return s
  }

  static aiSettings(): Screen {
    const s = new Screen()
    s.type = 'aiSettings'
    return s
  }

  static fontSizeSettings(): Screen {
    const s = new Screen()
    s.type = 'fontSizeSettings'
    return s
  }

  /**
   * 创建收藏夹管理或主题归档选择页面。
   *
   * @param topicId - 需要选择收藏夹的 NGA 主题 ID；为空时进入管理模式
   * @returns 收藏夹页面路由
   */
  static favoriteFolders(topicId: string = ''): Screen {
    const s = new Screen()
    s.type = 'favoriteFolders'
    s.favoriteTopicId = topicId
    return s
  }

  /**
   * 创建「收藏、保存与跟踪」融合面板路由（在线收藏 / 离线保存 / 跟踪 三 Tab）。
   *
   * @returns 收藏、保存与跟踪页面路由
   */
  static favoriteSaved(): Screen {
    const s = new Screen()
    s.type = 'favoriteSaved'
    return s
  }

  /**
   * 创建「数据管理」页面路由（导出/导入/迁移状态/存储统计）。
   *
   * @returns 数据管理页面路由
   */
  static dataManagement(): Screen {
    const s = new Screen()
    s.type = 'dataManagement'
    return s
  }

  static topicList(
    name: string, fid: number = 0,
    authorid: string = '', favor: string = '',
    searchpost: string = ''
  ): Screen {
    const s = new Screen()
    s.type = 'topicList'
    s.topicListName = name
    s.topicListFid = fid
    s.topicListAuthorid = authorid
    s.topicListFavor = favor
    s.topicListSearchpost = searchpost
    return s
  }

  getTitle(): string {
    switch (this.type) {
      case 'thread': return '帖子'
      case 'threadTree': return '递进树'
      case 'profile': return '个人主页'
      case 'notifications': return '通知'
      case 'messages': return '私信'
      case 'messageDetail': return '私信'
      case 'blacklist': return '黑名单管理'
      case 'notes': return '用户备注'
      case 'filterKeywords': return '关键词屏蔽'
      case 'settings': return '设置'
      case 'browseHistory': return '浏览历史'
      case 'followList': return '我的关注'
      case 'topicList': return this.topicListName || '帖子列表'
      case 'webview': return 'NGA网页版'
      case 'ttsSettings': return '语音朗读'
      case 'aiSettings': return 'AI 配置'
      case 'fontSizeSettings': return '字体大小'
      case 'favoriteFolders': return this.favoriteTopicId.length > 0 ? '收藏到…' : '收藏夹'
      case 'favoriteSaved': return '收藏、保存与跟踪'
      case 'dataManagement': return '数据管理'
      default: return ''
    }
  }
}

export class NavEntry {
  id: number = 0
  screen: Screen = new Screen()
  /**
   * 返回拦截回调。
   *
   * 当此条目位于活动栈顶且用户触发返回操作时调用。
   * 返回 true 表示已处理并阻止返回（例如弹出确认弹窗），
   * 返回 false / undefined 表示允许正常返回。
   */
  preBack?: () => boolean

  constructor(id: number, screen: Screen) {
    this.id = id
    this.screen = screen
  }
}

let nextNavId = 0

@Observed
export class RouterStoreClass {
  // 公开字段: 通过 @Observed 实现响应式
  // 请勿直接修改, 统一通过 navigateForum/navigateActivity/back 等方法操作
  boardSlot: BoardSlot | null = null
  activityStack: NavEntry[] = []
  sidebarTab: SidebarTab = 'community'

  get topActivity(): NavEntry | null {
    return this.activityStack.length > 0 ? this.activityStack[this.activityStack.length - 1] : null
  }

  setSidebarTab(tab: SidebarTab): void {
    if (this.sidebarTab === tab) return
    this.sidebarTab = tab
  }

  navigateForum(
    fid: number, name: string, stid: string = '',
    authorid: string = '', favor: string = '',
    searchKey: string = '', author: string = '',
    searchpost: string = ''
  ): void {
    this.boardSlot = new BoardSlot(fid, name, stid, authorid, favor, searchKey, author, searchpost)
    this.activityStack = []
  }

  /**
   * 导航到搜索面板。
   *
   * @param fid - 限定搜索的版块 fid；0（默认）为全局搜索
   * @param name - 限定搜索的版块名
   * @param stid - 限定搜索的专题版块 stid
   */
  navigateSearch(fid: number = 0, name: string = '', stid: string = ''): void {
    this.boardSlot = BoardSlot.search(fid, name, stid)
    this.activityStack = []
  }

  /**
   * 导航到指定页面。
   *
   * @param screen - 目标页面
   * @param replace - 是否**原地替换**当前栈顶条目（栈深度不变）。
   *   同一帖子的「自然列表 / 递进树」阅读样式切换必须传 true：两种样式互斥，
   *   被替换掉的页面条目移除后其组件实例随之销毁，返回时不会再退回另一种样式
   */
  navigateActivity(screen: Screen, replace: boolean = false): void {
    const entry = new NavEntry(++nextNavId, screen)

    if (replace && this.activityStack.length > 0) {
      const next = [...this.activityStack]
      next[next.length - 1] = entry
      this.activityStack = next
    } else if (screen.type === 'thread') {
      const top = this.topActivity
      if (top && top.screen.type === 'thread') {
        const next = [...this.activityStack]
        next[next.length - 1] = entry
        this.activityStack = next
      } else {
        this.activityStack = [...this.activityStack, entry]
      }
    } else {
      this.activityStack = [...this.activityStack, entry]
    }
  }

  /**
   * 返回上一页/上一级。
   *
   * 若栈顶条目标记了 preBack 拦截回调且返回 true，
   * 则阻止退出，由回调自行处理（例如弹出未保存确认弹窗）。
   */
  back(): void {
    if (this.activityStack.length > 0) {
      const top: NavEntry = this.activityStack[this.activityStack.length - 1]
      if (top.preBack && top.preBack()) {
        return
      }
      animateTo({ duration: 400, curve: Curve.FastOutSlowIn }, () => {
        this.activityStack = this.activityStack.slice(0, -1)
      })
      return
    }
    if (this.boardSlot) {
      animateTo({ duration: 400, curve: Curve.FastOutSlowIn }, () => {
        this.boardSlot = null
      })
    }
  }

  reset(tab: SidebarTab = 'community'): void {
    this.sidebarTab = tab
    this.boardSlot = null
    this.activityStack = []
  }
}

export const routerStore = new RouterStoreClass()
