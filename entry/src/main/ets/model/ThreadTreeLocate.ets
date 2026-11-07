/**
 * 递进树「定位目标」的数据结构与状态常量（只放数据，不含算法）。
 *
 * 设计契约见 `docs/THREAD_TREE_INCREMENTAL_LOAD_DESIGN.md` §3.6：
 * 递进树必须先有数据才能定位，因此「跳转」不是一个瞬时动作，而是
 * 「登记目标 → 等目标进入已提交的树 → 就绪后由用户决定是否前往」。
 *
 * 三种来源共用同一套状态机（`LocateSource`），只有文案不同。
 */

/** 定位目标来源。 */
export class LocateSource {
  /** 上次阅读进度（本地 `tree_reading_progress`）。 */
  static readonly RESUME: string = 'resume'
  /** 路由携带的 pid（引用 `→` / 同帖链接 / 深链）。 */
  static readonly ROUTE: string = 'route'
  /** 加载中用户点了尚未加载的楼层链接。 */
  static readonly USER: string = 'user'
}

/** 定位目标状态。 */
export class LocateState {
  /** 没有目标。 */
  static readonly NONE: number = 0
  /** 已登记，目标尚未进入已提交的树。 */
  static readonly WAITING: number = 1
  /** 目标在树模型里，可前往。 */
  static readonly READY: number = 2
  /** 目标在帖子里、但被「只看楼主」过滤掉了。 */
  static readonly FILTERED: number = 3
  /** 目标确实不存在（目标页已提交仍找不到 / 全帖到齐仍找不到 / 所在页未加载）。 */
  static readonly MISSING: number = 4
  /** 用户忽略或超时自动收起。 */
  static readonly DISMISSED: number = 5
}

/**
 * 一条待定位目标。
 *
 * 同一时刻页面只持有一个：后登记的覆盖先登记的（优先级由
 * `ThreadTreeLocatePolicy.preferSource` 决定）。
 */
export class LocateTarget {
  /** 目标楼层 pid（`0` 是主楼的合法值，`-1` 才是"无目标"）。 */
  pid: number = -1

  /** 目标楼层所属服务端页码（只用于文案与进度条刻度；未知为 `-1`）。 */
  page: number = -1

  /** 记录时所属根 pid（恢复进度时有；其余为 `-1`，就绪时再查）。 */
  rootPid: number = -1

  /** 来源，见 {@link LocateSource}。 */
  source: string = LocateSource.RESUME

  /**
   * 展示用标签（「上次阅读位置」/「第 812 楼」）。
   *
   * 由调用方在登记时生成，避免策略层依赖楼层号解析。
   */
  label: string = ''
}

/** 页面加载阶段（与胶囊状态正交）。 */
export class TreePagePhase {
  /** 第 1 页尚未提交：只有加载态，没有内容。 */
  static readonly ENTERING: number = 0
  /** 第 1 页已提交，水位推进中。 */
  static readonly STREAMING: number = 1
  /** 全部页覆盖。 */
  static readonly COMPLETE: number = 2
  /** 用户主动停止。 */
  static readonly STOPPED: number = 3
  /** 加载失败（可能已有内容）。 */
  static readonly FAILED: number = 4
}

/**
 * 底部进度胶囊的状态。
 *
 * 胶囊只做「加载进度 + 停止 + 失败重试」；定位目标的「前往查看 / 查看全部」由 Toast 承担，
 * 因此这里没有「已就绪 / 被过滤 / 未加载」等目标态。**加载结束（完成/停止）后胶囊常驻为
 * `LOADED`**（只显示 `29/29` / `12/29`，无图标、无动作）。
 * 视觉与列表页页码指示器同款：HDS 材质块、只给数字与动作，没有进度条与刻度。
 */
export class TreeBannerMode {
  /** 不显示（只有 `ENTERING`：树还没上屏，底部栏本身不存在）。 */
  static readonly HIDDEN: number = 0
  /** 仅加载：`⟳ 12/29` + 停止图标。 */
  static readonly LOADING: number = 1
  /** 加载 + 等待目标：`⟳ 12/40` + 停止图标（文案仍只有数字；「在等什么」只进读屏描述）。 */
  static readonly LOADING_WAIT: number = 2
  /** 正在停止：`⟳ 正在停止…`。 */
  static readonly STOPPING: number = 3
  /** 加载失败：`! 加载失败` + 重试。 */
  static readonly ERROR: number = 4
  /** 加载已结束（完成或用户停止）：只显示 `29/29` / `12/29`，无图标、无动作。 */
  static readonly LOADED: number = 5
}
