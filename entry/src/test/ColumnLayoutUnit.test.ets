import { describe, it, expect } from '@ohos/hypium'
import {
  BOARD_RATIO_DEFAULT,
  ColumnLayoutMath,
  ColumnMetrics,
  CONTENT_COL_MIN_VP,
  SIDEBAR_DEFAULT_VP,
  SIDEBAR_MAX_VP,
  SIDEBAR_MIN_VP
} from '../main/ets/common/utils/ColumnLayoutMath'

/**
 * 注册「三列堆栈列占比」几何计算的回归测试。
 *
 * 保护的核心契约（见 ColumnLayoutMath 文件头）：
 * 1. **默认值必须复刻改造前的几何**（侧边栏 180vp + 内容区 40 : 60）——占比模式是新增能力，
 *    不该顺手改掉既有观感。整数窗口宽度下板块列宽与改造前的小数宽度相差 ≤ 0.5vp；
 * 2. 隐藏列的份额让给相邻可见列，而不是三列重新按比例瓜分（否则侧边栏会莫名变宽）；
 * 3. md 断点不做板块/活动划分，`boardRatio` 不参与运算；
 * 4. 钳制规则在极窄窗口 / 脏数据下不产生空区间、NaN，也不把"无基准"翻译成"最大占比"；
 * 5. 可见列的百分比读数**相加恰为 100**（读数条要被读成"整窗切成的三份"）。
 *
 * 数值断言尽量钉到**精确值**而不是 `> 0`：本模块的失配表现是"某列被挤没 / 占比被放大"，
 * 宽松断言挡不住这类回归。区间扫描类用例把违规宽度累积后只断言一次 —— 既快，
 * 失败时也能直接报出第一个越界的窗口宽度。
 */
export default function columnLayoutUnitTest(): void {
  describe('columnLayoutMath', (): void => {
    it('reproducesLegacyGeometryAtLgWithDefaults', 0, (): void => {
      const m: ColumnMetrics = ColumnLayoutMath.resolve(840, 'lg', SIDEBAR_DEFAULT_VP, BOARD_RATIO_DEFAULT, true, true)

      /** 改造前：侧边栏固定 180，内容区 660 按 40 : 60 切分 */
      expect(m.sidebarVp).assertEqual(180)
      expect(m.boardVp).assertEqual(264)
      expect(m.activityVp).assertEqual(396)
      /** 百分比由最后一个可见列吸收取整余数，三项相加恰为 100（此处 47.14% 显示为 48%） */
      expect(m.sidebarPercent).assertEqual(21)
      expect(m.boardPercent).assertEqual(31)
      expect(m.activityPercent).assertEqual(48)
    })

    it('keepsLegacyBoardWidthWithinHalfVpForIntegerWindowWidths', 0, (): void => {
      /** 改造前由布局引擎按 0.4 × 内容区 产出小数 vp；本模块取整，故只承诺 ≤ 0.5vp 偏差 */
      let maxDelta: number = 0
      for (let w: number = 840; w <= 3000; w++) {
        const m: ColumnMetrics = ColumnLayoutMath.resolve(w, 'lg', 180, BOARD_RATIO_DEFAULT, true, true)
        const delta: number = Math.abs(m.boardVp - (w - 180) * BOARD_RATIO_DEFAULT)
        if (delta > maxDelta) {
          maxDelta = delta
        }
      }

      expect(maxDelta <= 0.5).assertTrue()
    })

    it('sumsColumnWidthsToRoundedWindowWidthEvenForFractionalWidths', 0, (): void => {
      /**
       * 三列宽度恒等于 round(W)：页面实测宽度可能是小数（真机 onAreaChange 给的就是），
       * 此时三列相加与 W 差 ≤ 0.5vp 属取整必然，但绝不能与 round(W) 不等（那才是漏算）。
       */
      const widths: number[] = [840.4, 840.5, 841.2, 900.75]
      let firstViolation: number = 0
      for (let i: number = 0; i < widths.length; i++) {
        const w: number = widths[i]
        const m: ColumnMetrics = ColumnLayoutMath.resolve(w, 'lg', 180, BOARD_RATIO_DEFAULT, true, true)
        if (m.sidebarVp + m.boardVp + m.activityVp !== Math.round(w) && firstViolation === 0) {
          firstViolation = w
        }
      }

      expect(firstViolation).assertEqual(0)
    })

    it('givesBoardColumnTheWholeContentAreaWhenActivityHidden', 0, (): void => {
      const m: ColumnMetrics = ColumnLayoutMath.resolve(840, 'lg', 180, BOARD_RATIO_DEFAULT, true, false)

      expect(m.sidebarVp).assertEqual(180)
      expect(m.boardVp).assertEqual(660)
      expect(m.activityVp).assertEqual(0)
    })

    it('givesActivityColumnTheWholeContentAreaWhenBoardHidden', 0, (): void => {
      const m: ColumnMetrics = ColumnLayoutMath.resolve(840, 'lg', 180, BOARD_RATIO_DEFAULT, false, true)

      /** 侧边栏不得因为板块列隐藏而变宽：隐藏列的份额归属邻居，不参与全局重分配 */
      expect(m.sidebarVp).assertEqual(180)
      expect(m.boardVp).assertEqual(0)
      expect(m.activityVp).assertEqual(660)
    })

    it('ignoresBoardRatioAtMdAndLeavesSingleContentColumn', 0, (): void => {
      const board: ColumnMetrics = ColumnLayoutMath.resolve(700, 'md', 180, 0.75, true, false)
      expect(board.sidebarVp).assertEqual(180)
      expect(board.boardVp).assertEqual(520)
      expect(board.activityVp).assertEqual(0)

      const activity: ColumnMetrics = ColumnLayoutMath.resolve(700, 'md', 180, 0.75, false, true)
      expect(activity.sidebarVp).assertEqual(180)
      expect(activity.boardVp).assertEqual(0)
      expect(activity.activityVp).assertEqual(520)
    })

    it('dropsSidebarAndGivesWholeWindowToBoardAtSm', 0, (): void => {
      const m: ColumnMetrics = ColumnLayoutMath.resolve(400, 'sm', 180, BOARD_RATIO_DEFAULT, true, false)

      expect(m.sidebarVp).assertEqual(0)
      expect(m.boardVp).assertEqual(400)
      expect(m.activityVp).assertEqual(0)
      expect(m.boardPercent).assertEqual(100)
    })

    it('dropsSidebarAndGivesWholeWindowToActivityAtSm', 0, (): void => {
      /** sm 下活动列同样接管整窗（板块列隐藏） */
      const m: ColumnMetrics = ColumnLayoutMath.resolve(400, 'sm', 180, BOARD_RATIO_DEFAULT, false, true)

      expect(m.sidebarVp).assertEqual(0)
      expect(m.boardVp).assertEqual(0)
      expect(m.activityVp).assertEqual(400)
      expect(m.activityPercent).assertEqual(100)
    })

    it('clampsSidebarIntoWindowRelativeRange', 0, (): void => {
      /** 600vp 窗口：窗口比例上限 0.35 × 600 = 210，低于绝对上限 320，故 210 生效 */
      expect(ColumnLayoutMath.clampSidebar(600, 500)).assertEqual(210)
      /** 超宽窗口：绝对上限 320 生效 */
      expect(ColumnLayoutMath.clampSidebar(3000, 500)).assertEqual(SIDEBAR_MAX_VP)
      /** 下限 */
      expect(ColumnLayoutMath.clampSidebar(600, 20)).assertEqual(SIDEBAR_MIN_VP)
    })

    it('bindsWindowRatioAtExactlyItsBoundary', 0, (): void => {
      /**
       * 0.35 × 800 = 280（精确整数），此时窗口比例上限（280）低于绝对上限（320），应取 280。
       * 这里刻意写死 280 而不是断言 `=== SIDEBAR_MAX_WINDOW_RATIO * 800`：后者是浮点乘法，
       * 换个窗口宽度（如 801 → 280.34999999999997）而函数返回取整值 280 就会假失败。
       */
      expect(ColumnLayoutMath.clampSidebar(800, 1000)).assertEqual(280)
    })

    it('neverRewritesDefaultSidebarAcrossWindowWidths', 0, (): void => {
      /** 默认值必须在整个可达窗口区间内都不被钳制改写，否则"默认观感不变"不成立 */
      let firstViolation: number = 0
      for (let w: number = 600; w <= 3000; w++) {
        if (ColumnLayoutMath.clampSidebar(w, SIDEBAR_DEFAULT_VP) !== SIDEBAR_DEFAULT_VP && firstViolation === 0) {
          firstViolation = w
        }
      }

      expect(firstViolation).assertEqual(0)
    })

    it('neverRewritesDefaultBoardRatioAtLgAcrossWindowWidths', 0, (): void => {
      /**
       * lg 下无论侧边栏取遍可达区间，默认占比 0.4 都不会被最小列宽钳制改写 ——
       * 前提是内容区 ≥ 500vp（= 200 / 0.4 与 200 / 0.6 的临界），lg 的可达最小内容区
       * 是 840 − 294 = 546，故恒成立。这条不变量一旦破，"默认几何等价"整条论证就塌了。
       */
      const sidebars: number[] = [SIDEBAR_MIN_VP, SIDEBAR_DEFAULT_VP, 294, SIDEBAR_MAX_VP]
      let firstViolation: number = 0
      for (let w: number = 840; w <= 3000; w++) {
        for (let i: number = 0; i < sidebars.length; i++) {
          const sidebar: number = ColumnLayoutMath.clampSidebar(w, sidebars[i])
          if (ColumnLayoutMath.clampBoardRatio(w, sidebar, BOARD_RATIO_DEFAULT) !== BOARD_RATIO_DEFAULT &&
            firstViolation === 0) {
            firstViolation = w
          }
        }
      }

      expect(firstViolation).assertEqual(0)
    })

    it('fallsBackToDefaultSidebarOnDirtyValue', 0, (): void => {
      /** 脏数据（0 / 负数 / NaN）回落默认值，而不是被钳到下限 */
      expect(ColumnLayoutMath.clampSidebar(840, 0)).assertEqual(SIDEBAR_DEFAULT_VP)
      expect(ColumnLayoutMath.clampSidebar(840, -100)).assertEqual(SIDEBAR_DEFAULT_VP)
      expect(ColumnLayoutMath.clampSidebar(840, NaN)).assertEqual(SIDEBAR_DEFAULT_VP)
    })

    it('normalizesMissingWindowWidthToFallback', 0, (): void => {
      const m: ColumnMetrics = ColumnLayoutMath.resolve(0, 'md', SIDEBAR_DEFAULT_VP, BOARD_RATIO_DEFAULT, true, false)

      /** 兜底窗口宽度 600：侧边栏 180、内容区 420 */
      expect(m.sidebarVp).assertEqual(SIDEBAR_DEFAULT_VP)
      expect(m.boardVp).assertEqual(420)
      expect(m.sidebarPercent + m.boardPercent).assertEqual(100)
    })

    it('keepsBothContentColumnsAboveMinimumWidthWhenThereIsRoom', 0, (): void => {
      const m: ColumnMetrics = ColumnLayoutMath.resolve(840, 'lg', 180, 0.05, true, true)

      /** 内容区 660 放得下两条 200vp：0.05 被抬到精确下限 200 / 660，板块列恰好 200vp */
      expect(m.boardVp).assertEqual(CONTENT_COL_MIN_VP)
      expect(m.activityVp).assertEqual(460)
    })

    it('keepsClampWindowValidWhenContentCannotFitTwoMinimumColumns', 0, (): void => {
      /**
       * 防御分支：内容区 ≤ 2 × CONTENT_COL_MIN_VP 时退化为固定 [0.2, 0.8]，避免区间翻转成空集。
       * 注：该状态在 lg 下**当前不可达**（lg ⟹ 窗口 ≥ 840 ⟹ 内容区 ≥ 546 > 400），
       * 本用例只锁住这个纯函数的退化行为，不代表真实布局会走到这里。
       */
      const m: ColumnMetrics = ColumnLayoutMath.resolve(600, 'lg', 210, 1.5, true, true)

      expect(m.sidebarVp).assertEqual(210)
      expect(m.boardVp).assertEqual(312)
      expect(m.activityVp).assertEqual(78)
      expect(m.sidebarVp + m.boardVp + m.activityVp).assertEqual(600)
    })

    it('derivesBoardRatioFromDraggedBoardWidth', 0, (): void => {
      const half: number = ColumnLayoutMath.ratioFromBoardWidth(840, 180, 330)

      expect(Math.abs(half - 0.5) < 0.000001).assertTrue()
      /** 拖过头：被上限截住（1 − 200/660），不会算出 > 1 的占比 */
      const upper: number = ColumnLayoutMath.ratioFromBoardWidth(840, 180, 5000)
      expect(Math.abs(upper - (1 - CONTENT_COL_MIN_VP / 660)) < 0.000001).assertTrue()
      /** 拖到负值：按脏数据回落默认占比，而不是钳到下限 */
      expect(ColumnLayoutMath.ratioFromBoardWidth(840, 180, -5000)).assertEqual(BOARD_RATIO_DEFAULT)
    })

    it('fallsBackToDefaultRatioWhenSidebarLeavesNoContentArea', 0, (): void => {
      /**
       * 侧边栏不窄于窗口（只可能来自历史脏数据）时内容区不存在，没有可换算的基准：
       * 必须回落默认占比。早期实现用 Math.max(1, ...) 防除零，会把这种输入翻译成
       * **最大占比 0.8**，拖动一下板块列就跳到 80%。
       */
      expect(ColumnLayoutMath.ratioFromBoardWidth(840, 5000, 218)).assertEqual(BOARD_RATIO_DEFAULT)
      expect(ColumnLayoutMath.ratioFromBoardWidth(840, 840, 218)).assertEqual(BOARD_RATIO_DEFAULT)
    })

    it('derivesRatioFromRenderedSidebarNotStoredValue', 0, (): void => {
      /**
       * 换算基准必须是**已钳制的渲染宽度**：窗口 900 下持久化值 320 会被钳到 315，
       * 用原值算会把内容区算小（580 而非 585）、占比算大，拖动系统性放大且不跟手。
       */
      const fromRendered: number = ColumnLayoutMath.ratioFromBoardWidth(900, 315, 200)
      const fromStored: number = ColumnLayoutMath.ratioFromBoardWidth(900, 320, 200)

      expect(Math.abs(fromRendered - 200 / 585) < 0.000001).assertTrue()
      expect(fromStored > fromRendered).assertTrue()
    })

    it('keepsVisibleColumnPercentagesSummingToExactlyOneHundred', 0, (): void => {
      /**
       * 三列各自四舍五入会得到 99 / 101（[840,1600] 内 761 个整数窗口宽度里有 186 个如此），
       * 读数条是"整窗切成的三份"，相加不等于 100 会被读成布局算错。末个可见列吸收余数。
       */
      let firstViolation: number = 0
      for (let w: number = 600; w <= 2000; w++) {
        const lg: ColumnMetrics = ColumnLayoutMath.resolve(w, 'lg', 180, BOARD_RATIO_DEFAULT, true, true)
        const mdBoard: ColumnMetrics = ColumnLayoutMath.resolve(w, 'md', 180, BOARD_RATIO_DEFAULT, true, false)
        const mdActivity: ColumnMetrics = ColumnLayoutMath.resolve(w, 'md', 180, BOARD_RATIO_DEFAULT, false, true)
        const sums: number[] = [
          lg.sidebarPercent + lg.boardPercent + lg.activityPercent,
          mdBoard.sidebarPercent + mdBoard.boardPercent,
          mdActivity.sidebarPercent + mdActivity.activityPercent
        ]
        for (let i: number = 0; i < sums.length; i++) {
          if (sums[i] !== 100 && firstViolation === 0) {
            firstViolation = w
          }
        }
      }

      expect(firstViolation).assertEqual(0)
    })

    it('reportsZeroPercentForHiddenColumns', 0, (): void => {
      const m: ColumnMetrics = ColumnLayoutMath.resolve(840, 'lg', 180, BOARD_RATIO_DEFAULT, true, false)

      expect(m.activityPercent).assertEqual(0)
      expect(m.boardPercent).assertEqual(79)
    })

    it('formatsReadoutAsPercentThenVp', 0, (): void => {
      expect(ColumnLayoutMath.formatReadout(180, 21)).assertEqual('21% · 180vp')
      expect(ColumnLayoutMath.formatReadout(0, 0)).assertEqual('0% · 0vp')
    })
  })
}
