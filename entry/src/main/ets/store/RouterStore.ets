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
  | 'profile'
  | 'notifications'
  | 'messages'
  | 'messageDetail'
  | 'blacklist'
  | 'notes'
  | 'filterKeywords'
  | 'settings'
  | 'browseHistory'
  | 'followedActivity'
  | 'followList'
  | 'topicList'
  | 'webview'
  | 'ttsSettings'
  | 'aiSettings'
  | 'fontSizeSettings'
  | 'favoriteFolders'

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
}

export class Screen {
  type: ScreenType = 'thread'
  tid: string = ''
  threadPage: number = 1
  pid: string = ''
  /** 打开帖子的路由来源（ThreadSource）。 */
  threadSource: string = ''
  uid: string = ''
  mid: string = ''
  messagePage: number = 1
  composeTo: string = ''
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

  static notifications(): Screen {
    const s = new Screen()
    s.type = 'notifications'
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

  static followedActivity(): Screen {
    const s = new Screen()
    s.type = 'followedActivity'
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
      case 'profile': return '个人主页'
      case 'notifications': return '通知'
      case 'messages': return '私信'
      case 'messageDetail': return '私信'
      case 'blacklist': return '黑名单管理'
      case 'notes': return '用户备注'
      case 'filterKeywords': return '关键词屏蔽'
      case 'settings': return '设置'
      case 'browseHistory': return '浏览历史'
      case 'followedActivity': return '关注动态'
      case 'followList': return '我的关注'
      case 'topicList': return this.topicListName || '主题列表'
      case 'webview': return 'NGA网页版'
      case 'ttsSettings': return '语音朗读'
      case 'aiSettings': return 'AI 配置'
      case 'fontSizeSettings': return '字体大小'
      case 'favoriteFolders': return this.favoriteTopicId.length > 0 ? '收藏到…' : '收藏主题'
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
