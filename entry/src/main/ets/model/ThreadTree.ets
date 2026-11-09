import { PostInfo } from './PostInfo'

/**
 * 帖子两层递进树的数据模型（只放数据结构与常量，不含业务算法）。
 *
 * 设计契约见 `docs/THREAD_TREE_DESIGN.md`：树只有两层——第一层是顶层发言
 * （无有效引用目标 / 只回复主楼的楼层），第二层是该根的全部后代（任意深度）平铺；
 * 后代总数 > 3 时默认只显示前 2 条，其余折叠为一行「共 N 条回复，点击查看」。
 *
 * 本文件先于实现冻结接口：`common/utils/ThreadTreeBuilder.ets`（算法）、
 * `service/ThreadTreeFetchService.ets`（全帖抓取）、`common/datasource/ThreadTreeDataSource.ets`
 * （列表数据源）、`common/components/thread-tree/*`（UI）都按这里的类字段编写。
 */

/** 树行类型常量。 */
export class ThreadTreeRowKind {
  /** 第一层根节点行。 */
  static readonly ROOT: number = 0

  /** 第二层子节点行。 */
  static readonly CHILD: number = 1

  /** 折叠行（「共 N 条回复，点击查看」）。 */
  static readonly MORE: number = 2
}

/**
 * 一条引用关系：本楼层回复了哪一层。
 *
 * 由 `extractPrimaryQuoteRef` 从楼层 `content` 的 BBCode 头解析得到：
 * - 引用块头 `[quote][pid=A,B,C]Reply[/pid] [b]Post by [uid=U]name[/uid] (date):[/b]`
 * - 回复头 `[b]Reply to [pid=A,B,C]Reply[/pid] Post by [uid=U]name[/uid] (date)[/b]`
 * - 主楼引用头 `[quote][tid=T]Topic[/tid] [b]Post by …[/b]`
 */
export class ThreadTreeQuoteRef {
  /** 被引用楼层 pid（主楼引用时为 0）。 */
  targetPid: number = 0

  /** 被引用楼层页码（头里 C 段，未知/不可信时为 -1，不用于定位）。 */
  targetPage: number = -1

  /** 被引用作者 uid 原文：数字 uid 字符串，或匿名帖的 `#anony_<32hex>`。 */
  targetUid: string = ''

  /** 被引用作者名字原文（可能为空，UI 用目标楼层数据补齐）。 */
  targetAuthor: string = ''

  /** 引用头原文（诊断用，截断保存）。 */
  rawHeader: string = ''

  /** 是否为主楼引用（`[tid=T]Topic[/tid]` 形式）。 */
  isTopicRef: boolean = false

  /** 是否跨帖引用（pid 头 B 段主题 id 与当前帖不同）：建树时按根处理。 */
  external: boolean = false
}

/** 第二层子节点：平铺在所属根之下。 */
export class ThreadTreeChild {
  /** 楼层数据。 */
  post: PostInfo = new PostInfo()

  /**
   * 树模式正文（已剥离引用区：`[quote]…[/quote]` 块与 `[b]Reply to …[/b]` 头）。
   *
   * 树的两层父子关系 + 「回复 @作者」已经表达引用关系，正文里再显示一遍引用区
   * 既冗余又占空间；由 `flattenThreadTree` 复制到行上供 UI 渲染。
   */
  displayContent: string = ''

  /** 直接父楼层 pid（可能是根，也可能是更深层的祖先）。 */
  parentPid: number = 0

  /** 本楼层对直接父楼层的引用关系。 */
  ref: ThreadTreeQuoteRef = new ThreadTreeQuoteRef()

  /** 当前行是否高亮（跳转定位命中后短暂为 true）。 */
  highlighted: boolean = false
}

/** 第一层根节点。 */
export class ThreadTreeRoot {
  /** 楼层数据（主楼根的 `post.pid` 在 HTML 通道可能为 0，靠 `lou === 0` 识别）。 */
  post: PostInfo = new PostInfo()

  /** 树模式正文（已剥离引用区，语义同 `ThreadTreeChild.displayContent`）。 */
  displayContent: string = ''

  /** 全部后代（任意深度），已按楼层号升序排列。 */
  children: ThreadTreeChild[] = []

  /** 根自身对主楼/外部的引用（可为 null；UI 一般不展示）。 */
  ref: ThreadTreeQuoteRef | null = null

  /** 是否已展开全部子节点。 */
  expanded: boolean = false

  /** 展开代际（展开时递增；行键用它给整组行换键，内容变化另由行 `uiRev` 表达）。 */
  rev: number = 0
}

/** 扁平化后的可见行：树 List 的每一项。 */
export class ThreadTreeRow {
  /** 行类型，见 {@link ThreadTreeRowKind}。 */
  kind: number = ThreadTreeRowKind.ROOT

  /** 楼层数据；`MORE` 行为 null。 */
  post: PostInfo | null = null

  /**
   * 树模式正文（已剥离引用区；`MORE` 行为空串）。
   *
   * 渲染方（根行 PostItem / 子行 ThreadTreeChildItem）用它替代 `post.content`；
   * 空串表示「该楼层正文只有引用区」，不再渲染正文块。
   */
  displayContent: string = ''

  /** 所属根节点 pid（`ROOT` 行即自身 pid；主楼根的 pid 可能为 0）。 */
  rootPid: number = 0

  /** 根内子节点序号（0 基）；`ROOT` / `MORE` 为 -1。 */
  childIndex: number = -1

  /** 子节点的引用关系；`ROOT` / `MORE` 为 null。 */
  ref: ThreadTreeQuoteRef | null = null

  /**
   * 是否显示「回复 @被回复者 #楼层」关系行。
   *
   * 直接回复所属根的楼层不显示：缩进本身已经表达「它是这条根的一级回复」，
   * 再写一遍「回复楼主 / 回复根作者」是冗余噪音。只有**跳过中间楼层、回复更深祖先**
   * 的楼层才显示，用来表达它回复的不是根（`#4 回复 #3` 时 #4 显示，#3 不显示）。
   *
   * `ROOT` / `MORE` 行恒为 false（根行用完整楼层卡片渲染，没有这行）。
   */
  showReplyTo: boolean = false

  /** `MORE` 行：被折叠的后代数量（= `totalCount` - 已显示数）。 */
  hiddenCount: number = 0

  /** `MORE` 行：该根后代总数（文案「共 N 条回复，点击查看」）。 */
  totalCount: number = 0

  /** 当前行是否高亮。 */
  highlighted: boolean = false

  /** 行版本号（所属根展开/折叠时递增，用于整组换键与诊断；内容变化走 `uiRev`）。 */
  rev: number = 0

  /**
   * 行**内容版本号**：可见内容（正文、折叠计数、回复关系、高亮）变化时递增。
   *
   * `rev` 表达的是「所属根的展开代际」，加载过程中恒定；而增量合并会改变同一行的
   * 正文或折叠计数，此时必须让 LazyForEach 的键跟着变，否则框架按「键没变」复用
   * 旧组件，`CHANGE` 通知等于没发（折叠行「共 N 条回复」停在旧值）。
   * 由页面在每次重建行序列时与上一版比较后继承/递增，见 `ThreadTreePanel.stampRowContentRev`。
   */
  uiRev: number = 0
}

/** 两层树模型（一次全帖抓取 + 建树后的完整结果）。 */
export class ThreadTreeModel {
  /** 当前可见的扁平行（按 `expanded` 状态生成）。 */
  rows: ThreadTreeRow[] = []

  /** 全部根节点（首项为主楼）。 */
  roots: ThreadTreeRoot[] = []

  /** pid → 楼层数据。 */
  postByPid: Map<number, PostInfo> = new Map<number, PostInfo>()

  /** pid → 服务端页码（切回列表模式定位用）。 */
  pageByPid: Map<number, number> = new Map<number, number>()

  /** pid → 所属根 pid（子节点被折叠时定位需先展开其根）。 */
  rootPidOfPid: Map<number, number> = new Map<number, number>()

  /** 主楼 pid（HTML 通道可能为 0）。 */
  mainPid: number = 0

  /** 楼层总数。 */
  totalPosts: number = 0

  /** 服务端总页数。 */
  totalPages: number = 0

  /** 解析出的引用关系总数（诊断/统计展示）。 */
  quoteCount: number = 0
}
