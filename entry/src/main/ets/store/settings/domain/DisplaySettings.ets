import { SettingsContext } from '../SettingsContext'
import { SettingsState } from '../SettingsState'
import {
  KEY_SHOW_SIGNATURE,
  KEY_CONTENT_FONT_SIZE,
  KEY_TOPIC_FONT_SIZE,
  KEY_COLUMN_SIDEBAR_MD,
  KEY_COLUMN_SIDEBAR_LG,
  KEY_COLUMN_BOARD_RATIO_LG
} from '../../../common/constants/AppStorageKeys'
import { SIDEBAR_DEFAULT_VP, BOARD_RATIO_DEFAULT } from '../../../common/utils/ColumnLayoutMath'

/**
 * 显示设置域子 store。
 *
 * 承载 fontSize / topicFontSize / domainIndex / holdingHand / smartGrip / showSignature 字段及其 setter。
 */
export class DisplaySettings {
  private ctx: SettingsContext

  constructor(ctx: SettingsContext) {
    this.ctx = ctx
  }

  setFontSize(size: number): void {
    this.ctx.state.fontSize = size
    AppStorage.setOrCreate(KEY_CONTENT_FONT_SIZE, size)
    this.ctx.persist()
  }

  setTopicFontSize(size: number): void {
    this.ctx.state.topicFontSize = size
    AppStorage.setOrCreate(KEY_TOPIC_FONT_SIZE, size)
    this.ctx.persist()
  }

  setDomainIndex(index: number): void {
    this.ctx.state.domainIndex = index
    this.ctx.persist()
  }

  setHoldingHand(value: number): void {
    this.ctx.state.holdingHand = value
    this.ctx.persist()
  }

  setSmartGrip(enabled: boolean): void {
    this.ctx.state.smartGrip = enabled
    this.ctx.persist()
  }

  /** 设置是否显示签名（同步 AppStorage 供 UI 响应式读取，并持久化） */
  setShowSignature(enabled: boolean): void {
    this.ctx.state.showSignature = enabled
    AppStorage.setOrCreate(KEY_SHOW_SIGNATURE, enabled)
    this.ctx.persist()
  }

  // ---------- 列堆栈占比（三列堆栈布局） ----------

  /**
   * 设置指定断点的侧边栏宽度（vp）。
   *
   * md（两列）与 lg（三列）各自独立保存，互不干扰；sm 是单列、无侧边栏，直接忽略。
   * 出入参都按**用户意图**原样存取，越界值由 `ColumnLayoutMath` 在渲染期按当前窗口收敛 ——
   * 窗口宽度是变化的（分屏 / 自由窗口），在这里钳死会把"宽窗口下调窄的侧边栏"永久写坏。
   *
   * @param breakpoint - 当前断点 md / lg
   * @param widthVp - 侧边栏宽度（vp）
   */
  setColumnSidebarWidth(breakpoint: string, widthVp: number): void {
    if (!(widthVp > 0)) return
    if (breakpoint === 'lg') {
      this.ctx.state.columnSidebarLg = widthVp
      AppStorage.setOrCreate(KEY_COLUMN_SIDEBAR_LG, widthVp)
    } else if (breakpoint === 'md') {
      this.ctx.state.columnSidebarMd = widthVp
      AppStorage.setOrCreate(KEY_COLUMN_SIDEBAR_MD, widthVp)
    } else {
      return
    }
    this.ctx.persist()
  }

  /**
   * 设置 lg 断点下板块列占内容区（窗口 − 侧边栏）的比例。
   *
   * @param ratio - 占比（0~1），越界值由 `ColumnLayoutMath` 在渲染期收敛
   */
  setColumnBoardRatio(ratio: number): void {
    if (!(ratio > 0)) return
    this.ctx.state.columnBoardRatioLg = ratio
    AppStorage.setOrCreate(KEY_COLUMN_BOARD_RATIO_LG, ratio)
    this.ctx.persist()
  }

  /**
   * 把指定断点的列占比恢复为默认值（侧边栏 `SIDEBAR_DEFAULT_VP`；lg 板块列 `BOARD_RATIO_DEFAULT`）。
   *
   * 兜底入口：占比可以拖到很窄，没有一键还原的话用户可能把自己锁在一个难用的布局里。
   * 模式开关不在这里动（重置的是占比，不是模式）。
   *
   * @param breakpoint - 当前断点 md / lg
   */
  resetColumnLayout(breakpoint: string): void {
    if (breakpoint === 'lg') {
      this.setColumnSidebarWidth('lg', SIDEBAR_DEFAULT_VP)
      this.setColumnBoardRatio(BOARD_RATIO_DEFAULT)
    } else if (breakpoint === 'md') {
      this.setColumnSidebarWidth('md', SIDEBAR_DEFAULT_VP)
    }
  }

  /** 从持久化对象加载显示字段 */
  load(saved: SettingsState): void {
    if (saved.fontSize) this.ctx.state.fontSize = saved.fontSize
    if (saved.topicFontSize) this.ctx.state.topicFontSize = saved.topicFontSize
    if (saved.domainIndex) this.ctx.state.domainIndex = saved.domainIndex
    if (saved.holdingHand !== undefined) this.ctx.state.holdingHand = saved.holdingHand
    if (saved.smartGrip !== undefined) this.ctx.state.smartGrip = saved.smartGrip
    if (saved.showSignature !== undefined) {
      this.ctx.state.showSignature = saved.showSignature
    }
    // 列占比：只在取值可用时覆盖默认值，`0`/`undefined`（旧数据无此字段）一律保持默认
    if (saved.columnSidebarMd > 0) this.ctx.state.columnSidebarMd = saved.columnSidebarMd
    if (saved.columnSidebarLg > 0) this.ctx.state.columnSidebarLg = saved.columnSidebarLg
    if (saved.columnBoardRatioLg > 0) this.ctx.state.columnBoardRatioLg = saved.columnBoardRatioLg
  }
}
