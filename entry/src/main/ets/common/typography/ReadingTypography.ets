/**
 * 阅读字号的语义角色。
 *
 * 枚举值与字号规则表的数组索引一一对应。
 */
export enum ReadingFontRole {
  /** 帖子正文。 */
  CONTENT = 0,
  /** 帖子引用正文。 */
  QUOTE = 1,
  /** 无法按原样渲染时使用的辅助文本。 */
  FALLBACK = 2,
  /** 上标和下标。 */
  SUB_SUP = 3,
  /** 帖子列表标题和类型标签。 */
  TOPIC_TITLE = 4,
  /** 帖子列表摘要。 */
  TOPIC_SUMMARY = 5,
  /** 代码块正文。 */
  CODE = 6
}

/**
 * 阅读行高的语义角色。
 *
 * 枚举值与行高规则表的数组索引一一对应。
 */
export enum ReadingLineHeightRole {
  /** 帖子正文行高。 */
  CONTENT = 0,
  /** 帖子引用正文行高。 */
  QUOTE = 1,
  /** 帖子列表摘要行高。 */
  TOPIC_SUMMARY = 2,
  /** 代码块正文行高。 */
  CODE = 3
}

/**
 * 单个字号或行高的缩放规则。
 */
class ReadingScaleRule {
  /** 相对输入值的缩放系数。 */
  scale: number
  /** 缩放后的定值偏移。 */
  offset: number
  /** 允许的最小结果。 */
  min: number
  /** 允许的最大结果。 */
  max: number

  /**
   * 创建缩放规则。
   *
   * @param scale 相对输入值的缩放系数
   * @param offset 缩放后的定值偏移
   * @param min 允许的最小结果
   * @param max 允许的最大结果
   */
  constructor(scale: number, offset: number, min: number, max: number) {
    this.scale = scale
    this.offset = offset
    this.min = min
    this.max = max
  }
}

/**
 * 可按 ReadingFontRole 索引的字号规则表。
 */
const READING_FONT_RULES: ReadingScaleRule[] = [
  new ReadingScaleRule(1, 0, 12, 24),
  new ReadingScaleRule(0.94, 0, 12, 23),
  new ReadingScaleRule(0.88, 0, 11, 21),
  new ReadingScaleRule(0.72, 0, 10, 18),
  new ReadingScaleRule(1, 0, 12, 24),
  new ReadingScaleRule(0.88, 0, 12, 21),
  new ReadingScaleRule(0.88, 0, 12, 18)
]

/**
 * 可按 ReadingLineHeightRole 索引的行高规则表。
 */
const READING_LINE_HEIGHT_RULES: ReadingScaleRule[] = [
  new ReadingScaleRule(1.6, 0, 20, 38),
  new ReadingScaleRule(1.55, 0, 20, 36),
  new ReadingScaleRule(1.45, 0, 18, 30),
  new ReadingScaleRule(1.5, 0, 18, 28)
]

/**
 * BBCode 自定义字号允许的最小值。
 */
const BBCODE_FONT_SIZE_MIN: number = 10

/**
 * BBCode 自定义字号允许的最大值。
 */
const BBCODE_FONT_SIZE_MAX: number = 36

/**
 * 下标相对基础字号的基线偏移比例。
 */
const SUBSCRIPT_OFFSET_RATIO: number = 0.3

/**
 * 上标相对基础字号的基线偏移比例。
 */
const SUPERSCRIPT_OFFSET_RATIO: number = 0.35

/**
 * 阅读排版计算入口。
 *
 * 所有受阅读字号设置影响的文本均通过语义角色索引规则表，避免页面散落定值偏移。
 */
export class ReadingTypography {
  /**
   * 根据语义角色计算字号。
   *
   * @param role 字号语义角色
   * @param baseFontSize 用户设置的基础字号
   * @returns 经过缩放和边界保护的字号
   */
  static fontSize(role: ReadingFontRole, baseFontSize: number): number {
    return ReadingTypography.resolve(READING_FONT_RULES[role], baseFontSize)
  }

  /**
   * 根据语义角色和实际字号计算行高。
   *
   * @param role 行高语义角色
   * @param fontSize 已计算的实际字号
   * @returns 经过缩放和边界保护的行高
   */
  static lineHeight(role: ReadingLineHeightRole, fontSize: number): number {
    return ReadingTypography.resolve(READING_LINE_HEIGHT_RULES[role], fontSize)
  }

  /**
   * 计算 BBCode size 标签的实际字号。
   *
   * @param percentage BBCode 百分比字号
   * @param inQuote 是否位于引用块内
   * @param baseFontSize 用户设置的正文基础字号
   * @returns 限制在安全显示范围内的实际字号
   */
  static bbcodeFontSize(percentage: number, inQuote: boolean, baseFontSize: number): number {
    const contextRole: ReadingFontRole = inQuote ? ReadingFontRole.QUOTE : ReadingFontRole.CONTENT
    const contextFontSize: number = ReadingTypography.fontSize(contextRole, baseFontSize)
    const scaledSize: number = Math.round(contextFontSize * percentage / 100)
    return ReadingTypography.clamp(scaledSize, BBCODE_FONT_SIZE_MIN, BBCODE_FONT_SIZE_MAX)
  }

  /**
   * 计算下标相对基础字号的基线偏移。
   *
   * @param baseFontSize 上下标所依附的基础字号
   * @returns 向下偏移的负值
   */
  static subscriptOffset(baseFontSize: number): number {
    return -(baseFontSize * SUBSCRIPT_OFFSET_RATIO)
  }

  /**
   * 计算上标相对基础字号的基线偏移。
   *
   * @param baseFontSize 上下标所依附的基础字号
   * @returns 向上偏移的正值
   */
  static superscriptOffset(baseFontSize: number): number {
    return baseFontSize * SUPERSCRIPT_OFFSET_RATIO
  }

  /**
   * 应用一条缩放规则。
   *
   * @param rule 缩放规则
   * @param value 输入值
   * @returns 经过四舍五入和边界保护的结果
   */
  private static resolve(rule: ReadingScaleRule, value: number): number {
    return ReadingTypography.clamp(Math.round(value * rule.scale + rule.offset), rule.min, rule.max)
  }

  /**
   * 将数值限制在闭区间内。
   *
   * @param value 输入值
   * @param min 最小值
   * @param max 最大值
   * @returns 限制后的数值
   */
  private static clamp(value: number, min: number, max: number): number {
    return Math.min(max, Math.max(min, value))
  }
}
