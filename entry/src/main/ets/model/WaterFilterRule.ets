/**
 * 「智能去水」规则模型。
 *
 * 去水的判定是**本地规则**（不调用模型）：先按严格等级套用内置词表，
 * 再叠加用户自定义规则。等级与自定义规则都持久化在设置里（见
 * `store/settings/domain/WaterFilterSettings`），判定本体在
 * `service/WaterFilterEngine`。
 *
 * 判定的输入不是原始 BBCode，而是**剥掉标记后的纯文本**：`[img]`、`[quote]`
 * 一类「富内容标记」本身就让楼层免于被判水（见引擎的富内容豁免），
 * 剩下的标记（`[b]`/`[color]`/表情码等）在判定前被剥除。
 */

/**
 * 自定义规则类型。
 */
export enum WaterRuleType {
  /** 纯文本**包含**关键词即判为水。 */
  CONTAINS = 'contains',
  /** 纯文本**完全等于**关键词（忽略大小写与首尾空白）才判为水。 */
  EQUALS = 'equals',
  /** 纯文本长度不超过 `value` 个**字**、且该层没有任何附件时判为水。 */
  MAX_LENGTH = 'max-length'
}

/**
 * 去水严格等级。
 *
 * 等级只影响**内置词表**的取用范围；自定义规则在任何等级下都生效
 * （用户显式配置的意图优先于预设）。
 */
export enum WaterFilterLevel {
  /** 只清纯灌水：mark / 插眼 / 纯表情 / 纯标点等毫无信息量的短回复。 */
  BASIC = 1,
  /** 连简短闲聊也清：在基础档之上再清「感谢分享」「哈哈哈哈」「同求」一类。 */
  AGGRESSIVE = 2
}

/** 等级下限。 */
export const WATER_LEVEL_MIN: number = WaterFilterLevel.BASIC
/** 等级上限。 */
export const WATER_LEVEL_MAX: number = WaterFilterLevel.AGGRESSIVE

/**
 * 把任意输入夹取到合法等级区间。
 *
 * @param value - 待规整的等级
 * @returns 合法的等级值
 */
export function clampWaterLevel(value: number): number {
  if (!Number.isFinite(value)) {
    return WaterFilterLevel.BASIC
  }
  const rounded: number = Math.round(value)
  if (rounded < WATER_LEVEL_MIN) {
    return WATER_LEVEL_MIN
  }
  if (rounded > WATER_LEVEL_MAX) {
    return WATER_LEVEL_MAX
  }
  return rounded
}

/**
 * 等级显示名。
 *
 * @param level - 等级值
 * @returns 用户可读的等级名
 */
export function waterLevelLabel(level: number): string {
  if (clampWaterLevel(level) === WaterFilterLevel.AGGRESSIVE) {
    return '加强去水'
  }
  return '只清纯灌水'
}

/**
 * 等级一句话说明（设置页用）。
 *
 * @param level - 等级值
 * @returns 描述文案
 */
export function waterLevelDescription(level: number): string {
  if (clampWaterLevel(level) === WaterFilterLevel.AGGRESSIVE) {
    return '在基础档之上，再清掉「感谢分享」「哈哈哈哈」「同求」这类简短闲聊'
  }
  return '只清掉毫无信息量的短回复（mark、插眼、纯表情、纯标点）'
}

/**
 * 规则类型的短名称（用于类型选择条与规则列表的副标题）。
 *
 * 只用类型名、不带具体值：这里是「这是什么类型的规则」，值由旁边的正文展示，
 * 拼进值会让副标题随值长短跳动。
 *
 * 长度类的名字**必须带「字」**：不写单位，用户会以为单位是字节或字符
 * （汉字与 emoji 的计数完全不同）。
 *
 * @param type - 规则类型
 * @returns 用户可读的类型短名
 */
export function waterRuleTypeLabel(type: string): string {
  if (type === WaterRuleType.EQUALS) {
    return '内容完全等于'
  }
  if (type === WaterRuleType.MAX_LENGTH) {
    return '字数不超过'
  }
  return '内容包含'
}

/**
 * 规则的完整描述（含具体值，供规则列表与 AI 规则清单展示）。
 *
 * @param type - 规则类型
 * @param value - 规则值
 * @returns 完整描述文本
 */
export function waterRuleTypeDetail(type: string, value: string): string {
  if (type === WaterRuleType.EQUALS) {
    return '内容完全等于「' + value + '」'
  }
  if (type === WaterRuleType.MAX_LENGTH) {
    return '纯文本长度不超过 ' + value + ' 字'
  }
  return '内容包含「' + value + '」'
}

/**
 * 是否为合法的规则类型。
 *
 * @param type - 待校验的类型
 * @returns 是否合法
 */
export function isWaterRuleType(type: string): boolean {
  return type === WaterRuleType.CONTAINS || type === WaterRuleType.EQUALS ||
    type === WaterRuleType.MAX_LENGTH
}

/**
 * 一条自定义去水规则。
 */
export class WaterFilterRule {
  /** 规则标识（列表键与增删改的定位依据）。 */
  id: string = ''
  /** 是否启用。 */
  enabled: boolean = true
  /** 规则类型（{@link WaterRuleType}）。 */
  type: string = WaterRuleType.CONTAINS
  /**
   * 规则值。
   *
   * - `CONTAINS` / `EQUALS`：关键词
   * - `MAX_LENGTH`：长度上限（十进制数字字符串）
   */
  value: string = ''
}

/**
 * 校验一条规则是否可用（设置页保存前调用）。
 *
 * @param type - 规则类型
 * @param value - 规则值
 * @returns 校验失败的原因；空串表示通过
 */
export function validateWaterRule(type: string, value: string): string {
  if (!isWaterRuleType(type)) {
    return '规则类型无效'
  }
  const trimmed: string = value.trim()
  if (trimmed.length === 0) {
    return '请填写规则内容'
  }
  if (type === WaterRuleType.MAX_LENGTH) {
    for (let i = 0; i < trimmed.length; i++) {
      const c: string = trimmed.charAt(i)
      if (c < '0' || c > '9') {
        return '字数上限请填数字'
      }
    }
    const limit: number = Number(trimmed)
    if (limit < 1 || limit > 500) {
      return '字数上限需在 1~500 之间'
    }
  }
  return ''
}
