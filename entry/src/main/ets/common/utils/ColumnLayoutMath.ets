/**
 * 三列堆栈占比布局 —— 纯计算模块。
 *
 * 本模块只做算术，不碰任何 UI / 状态：输入「窗口宽度 + 用户占比设定 + 各列可见性」，
 * 输出三列各自的宽度（vp）与占整窗的百分比。放在这里而不是写在 `MainPage.build()` 里，
 * 是为了让钳制规则（最小列宽、脏数据回落）可以被单测直接覆盖 —— 布局算错的表现是
 * "某一列被挤没"，在真机上很难复现定位。
 *
 * ## 布局模型（为什么不是三段纯百分比）
 *
 * 改造前的几何是「侧边栏固定 180vp + 内容区按 40 : 60 切板块列 / 活动列」：侧边栏
 * **不随窗口宽度伸缩**。若改成"三列各占窗口的百分之多少"，默认值在 840vp 窗口下会把
 * 侧边栏撑到 235vp 左右，等于顺手改掉了既有观感。所以本模块沿用原来的参数化方式：
 *
 * - **侧边栏**：以 vp 为真值（默认 `SIDEBAR_DEFAULT_VP = 180`，与改造前一致）；
 * - **板块列 : 活动列**：以**内容区**（窗口 − 侧边栏）内的比例 `boardRatio` 为真值
 *   （默认 `0.4`，即改造前的 40 : 60）。
 *
 * 拖动把手改的就是这两个量本身。因此默认参数下的几何与改造前一致 —— 精确地说，
 * `lg` 双列时改造前由布局引擎按 `0.4 × 内容区` 算出**小数**宽度，本模块取整到 vp，
 * 于是只有「内容区是 5 的倍数」时逐像素相等，其余情形差 **≤ 0.5vp**（最大实测 0.4vp）；
 * 其余六种断点 × 可见性组合在任意整数窗口宽度下都逐像素相等。
 *
 * ## 隐藏列的份额归属
 *
 * `md` 断点下内容区是「板块列 或 活动列」二选一的单列；`lg` 断点下活动列为空时只剩板块列。
 * 规则与改造前 `.visibility()` + `layoutWeight(1)` 的既有行为对齐：**被隐藏的那一列把自己的
 * 份额让给它右侧最近的可见列**（右侧没有则让给左侧），而不是让三列重新按比例瓜分 ——
 * 后者会让侧边栏在活动列为空时突然变宽。副作用是 `md` 断点下内容区恒由可见的那一列独占，
 * `boardRatio` 不参与运算（`md` 没有板块/活动划分）。
 *
 * ## 百分比读数的口径
 *
 * 三列百分比都是**占整窗**的份额（因此可见列的百分比相加恰为 100），不是"占内容区"——
 * 后者会让板块列显示 40% 而侧边栏显示 21%，两个数字不在同一把尺子上。
 */

/**
 * 首帧兜底窗口宽度（vp）。
 *
 * 正常路径下窗口宽度由 `EntryAbility` 写入 AppStorage、页面再用根容器实测宽度校正，
 * 这个常量只在两者都还没就绪的那一帧生效。
 */
export const COLUMN_WINDOW_FALLBACK_VP: number = 600

/** 侧边栏宽度默认值（vp）—— 与改造前的固定 180 一致。 */
export const SIDEBAR_DEFAULT_VP: number = 180

/**
 * 侧边栏宽度下限（vp）：再窄就放不下头像 + 板块名 + 收藏星标。
 *
 * 底部工具条的固有宽度给出了这个数的下界：左右内边距 20 + 两枚 32vp 按钮 + 三处 4vp 间距
 * + 「重置」约 34vp = 130vp，取 136 留一点余量，避免拖到最窄时「重置」被挤出可视区。
 */
export const SIDEBAR_MIN_VP: number = 136

/** 侧边栏宽度上限（vp）：绝对上限，避免超宽窗口下侧边栏无限拉长。 */
export const SIDEBAR_MAX_VP: number = 320

/** 侧边栏宽度占窗口宽度的上限比例：窄窗口下防止侧边栏吃掉内容区。 */
export const SIDEBAR_MAX_WINDOW_RATIO: number = 0.35

/** 板块列占内容区的比例下限。 */
export const BOARD_RATIO_MIN: number = 0.2

/** 板块列占内容区的比例上限。 */
export const BOARD_RATIO_MAX: number = 0.8

/** 板块列占内容区的比例默认值 —— 与改造前的「板块 40% / 活动 60%」一致。 */
export const BOARD_RATIO_DEFAULT: number = 0.4

/** 板块列 / 活动列各自的最小可用宽度（vp）：仅当内容区放得下两条时才参与钳制。 */
export const CONTENT_COL_MIN_VP: number = 200

/**
 * 一列最终解析出的几何：宽度（vp）与占整窗百分比。
 *
 * 三个百分比**保证可见列相加恰为 100**（取整余数由最右可见列吸收，见
 * `closePercentGap`），可以直接横着读成"整窗被切成哪三份"。
 */
export class ColumnMetrics {
  /** 侧边栏宽度（vp），`sm` 断点下为 0。 */
  sidebarVp: number = 0
  /** 板块列宽度（vp），隐藏时为 0。 */
  boardVp: number = 0
  /** 活动列宽度（vp），隐藏时为 0。 */
  activityVp: number = 0
  /** 侧边栏占整窗百分比（整数）。 */
  sidebarPercent: number = 0
  /** 板块列占整窗百分比（整数）。 */
  boardPercent: number = 0
  /** 活动列占整窗百分比（整数）。 */
  activityPercent: number = 0
}

export class ColumnLayoutMath {
  /** 把任意窗口宽度收敛成可用值（非正数回落兜底常量）。 */
  static normalizeWindowWidth(windowWidth: number): number {
    return windowWidth > 0 ? windowWidth : COLUMN_WINDOW_FALLBACK_VP
  }

  /**
   * 侧边栏宽度钳制。
   *
   * 上限取「绝对上限」与「窗口宽度的 `SIDEBAR_MAX_WINDOW_RATIO`」的较小者；极窄窗口下
   * 该上限可能低于下限，此时以下限让位（宁可侧边栏偏宽，也不产生 min > max 的死区）。
   * 退化到 `min === max` 时（窗口窄于 `SIDEBAR_MIN_VP / SIDEBAR_MAX_WINDOW_RATIO`，
   * 实际调用路径不可达 —— `md` 断点保证窗口 ≥ 600vp）宽度被钉死，连"脏数据回落默认值"
   * 也不再生效：那是无解区间的正确表现，不是缺陷。
   */
  static clampSidebar(windowWidth: number, widthVp: number): number {
    const w: number = ColumnLayoutMath.normalizeWindowWidth(windowWidth)
    const maxByWindow: number = w * SIDEBAR_MAX_WINDOW_RATIO
    const max: number = Math.min(SIDEBAR_MAX_VP, maxByWindow)
    const min: number = Math.min(SIDEBAR_MIN_VP, max)
    /** 脏数据（NaN / 0 / 负数）直接回落默认值，而不是被钳到下限。 */
    if (!(widthVp > 0)) {
      return Math.round(Math.min(max, Math.max(min, SIDEBAR_DEFAULT_VP)))
    }
    return Math.round(Math.min(max, Math.max(min, widthVp)))
  }

  /**
   * 板块列占比钳制。
   *
   * 先按「板块列 / 活动列都不得窄于 `CONTENT_COL_MIN_VP`」收窄区间，但仅在内容区确实
   * 放得下两条时生效（`content > 2 × CONTENT_COL_MIN_VP`）——否则区间会翻转成空集。
   */
  static clampBoardRatio(windowWidth: number, sidebarVp: number, ratio: number): number {
    const w: number = ColumnLayoutMath.normalizeWindowWidth(windowWidth)
    const content: number = Math.max(0, w - sidebarVp)
    let min: number = BOARD_RATIO_MIN
    let max: number = BOARD_RATIO_MAX
    if (content > CONTENT_COL_MIN_VP * 2) {
      const need: number = CONTENT_COL_MIN_VP / content
      if (need > min) {
        min = need
      }
      if (1 - need < max) {
        max = 1 - need
      }
    }
    if (!(ratio > 0)) {
      return BOARD_RATIO_DEFAULT
    }
    return Math.min(max, Math.max(min, ratio))
  }

  /**
   * 由板块列实宽反算占比（把手拖动用：先算宽度再回落到比例真值）。
   *
   * @param windowWidth - 窗口宽度（vp）
   * @param sidebarVp - 侧边栏的**实际渲染宽度**（即 `resolve()` 输出的 `sidebarVp`，已钳制）。
   *   传持久化原值会算错：窗口收窄后原值可能大于当前上限，`content` 被算小、占比被算大，
   *   拖动会系统性放大且把手不再跟手。
   * @param boardVp - 把手落点对应的板块列宽度（vp）
   * @returns 钳制后的占比；内容区不存在时回落默认占比
   */
  static ratioFromBoardWidth(windowWidth: number, sidebarVp: number, boardVp: number): number {
    const w: number = ColumnLayoutMath.normalizeWindowWidth(windowWidth)
    const content: number = w - sidebarVp
    /** 内容区不存在（只可能来自脏数据）：没有可换算的基准，回落默认值。 */
    if (!(content > 0)) {
      return BOARD_RATIO_DEFAULT
    }
    return ColumnLayoutMath.clampBoardRatio(w, sidebarVp, boardVp / content)
  }

  /**
   * 解析三列最终几何。
   *
   * @param windowWidth - 窗口宽度（vp）
   * @param breakpoint - 当前断点 sm/md/lg
   * @param sidebarVp - 用户设定的侧边栏宽度（vp）
   * @param boardRatio - 用户设定的板块列占内容区比例
   * @param boardVisible - 板块列是否可见
   * @param activityVisible - 活动列是否可见
   * @returns 三列宽度与百分比
   */
  static resolve(
    windowWidth: number,
    breakpoint: string,
    sidebarVp: number,
    boardRatio: number,
    boardVisible: boolean,
    activityVisible: boolean
  ): ColumnMetrics {
    const metrics: ColumnMetrics = new ColumnMetrics()
    const w: number = ColumnLayoutMath.normalizeWindowWidth(windowWidth)
    const sidebar: number = breakpoint === 'sm' ? 0 : ColumnLayoutMath.clampSidebar(w, sidebarVp)
    const content: number = Math.max(0, w - sidebar)
    metrics.sidebarVp = sidebar

    if (breakpoint === 'lg') {
      if (boardVisible && activityVisible) {
        const ratio: number = ColumnLayoutMath.clampBoardRatio(w, sidebar, boardRatio)
        metrics.boardVp = Math.round(content * ratio)
        metrics.activityVp = Math.round(content - metrics.boardVp)
      } else if (boardVisible) {
        metrics.boardVp = content
      } else if (activityVisible) {
        metrics.activityVp = content
      }
    } else {
      /** md：内容区是「板块列 或 活动列」的单列形态，不参与板块/活动划分。 */
      if (boardVisible) {
        metrics.boardVp = content
      } else if (activityVisible) {
        metrics.activityVp = content
      }
    }

    metrics.sidebarPercent = ColumnLayoutMath.toPercent(metrics.sidebarVp, w)
    metrics.boardPercent = ColumnLayoutMath.toPercent(metrics.boardVp, w)
    metrics.activityPercent = ColumnLayoutMath.toPercent(metrics.activityVp, w)
    ColumnLayoutMath.closePercentGap(metrics)
    return metrics
  }

  /**
   * 让可见列的百分比相加**恰好等于 100**。
   *
   * 三列各自四舍五入会得到 99 或 101（[840, 1600] 区间内 761 个整数窗口宽度里有 186 个如此）。
   * 读数条是"整窗被切成的三份"，加起来不是 100 会被读成"布局算错了"，所以把取整余数
   * 交给**最右侧的可见列**吸收 —— 与"隐藏列的份额归右侧邻居"同向，规则唯一、可预期。
   *
   * 代价是最右列可能偏离真值近 1 个百分点（如 47.14% 显示为 48%），其余两列仍在 ±0.5 内。
   */
  private static closePercentGap(metrics: ColumnMetrics): void {
    const sidebarVisible: boolean = metrics.sidebarVp > 0
    const boardShown: boolean = metrics.boardVp > 0
    const activityShown: boolean = metrics.activityVp > 0
    let assigned: number = 0
    if (sidebarVisible) {
      assigned += metrics.sidebarPercent
    }
    if (boardShown) {
      assigned += metrics.boardPercent
    }
    if (activityShown) {
      assigned += metrics.activityPercent
      metrics.activityPercent += 100 - assigned
      return
    }
    if (boardShown) {
      metrics.boardPercent += 100 - assigned
      return
    }
    if (sidebarVisible) {
      metrics.sidebarPercent += 100 - assigned
    }
  }

  /** 宽度 → 占整窗百分比（四舍五入整数；宽度为 0 时为 0）。 */
  static toPercent(widthVp: number, windowWidth: number): number {
    const w: number = ColumnLayoutMath.normalizeWindowWidth(windowWidth)
    if (!(widthVp > 0)) {
      return 0
    }
    return Math.round(widthVp / w * 100)
  }

  /** 列读数文案：`21% · 180vp`（百分比在前，与「占比模式」的语义一致）。 */
  static formatReadout(widthVp: number, percent: number): string {
    return `${percent}% · ${Math.round(widthVp)}vp`
  }
}
