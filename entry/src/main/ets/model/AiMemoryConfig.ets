/**
 * 对话记忆档位（上下文策略）。
 *
 * ## 设计立场（本次重构的核心）
 *
 * 上下文不是"成本"，是**效果**。在 1M 窗口、缓存命中 0.02–0.04 元/百万 token 的价格结构下，
 * 为了省 token 而激进压缩是净亏损：省下的钱微不足道，丢掉的信息很贵。
 *
 * 所以档位不再是"压缩得多狠"，而是两个更本质的参数：
 *
 * | 档位 | 触发阈值 | 压缩后保留 | 含义 |
 * | --- | --- | --- | --- |
 * | 精简 | 窗口预算的 80% | 45% | 更早压缩、裁得更狠（仅小窗口 / 流量受限） |
 * | 平衡 | 90% | 60% | 折中 |
 * | 长记忆（默认） | 95% | 80% | **先把窗口用满**，压缩更晚、留得更多 |
 *
 * 关键差别：触发阈值决定"什么时候才愿意动刀"。95% 意味着绝大多数会话根本不会被压缩——
 * 这是对的，因为现代模型的窗口本来就足够装下几十轮完整对话。
 *
 * ## 为什么不提供"关闭压缩"
 *
 * 窗口总会被用满（工具结果、长帖正文）。没有兜底压缩 = 某一天直接 400，整轮对话丢失。
 * 但压缩应该是**低频、彻底、高保真**的，而不是高频、小幅、抽句式。
 */

/** 档位：精简。 */
export const AI_MEMORY_MODE_COMPACT: string = 'compact'

/** 档位：平衡。 */
export const AI_MEMORY_MODE_BALANCED: string = 'balanced'

/** 档位：长记忆（默认）。 */
export const AI_MEMORY_MODE_LONG: string = 'long'

/** 默认档位：长记忆。 */
export const DEFAULT_AI_MEMORY_MODE: string = AI_MEMORY_MODE_LONG

/** 精简档：达到预算 80% 即压缩。 */
const TRIGGER_COMPACT: number = 0.8

/** 平衡档：达到预算 90% 即压缩。 */
const TRIGGER_BALANCED: number = 0.9

/** 长记忆档：达到预算 95% 才压缩（先把窗口用满）。 */
const TRIGGER_LONG: number = 0.95

/** 精简档：压缩后保留 45%。 */
const KEEP_COMPACT: number = 0.45

/** 平衡档：压缩后保留 60%。 */
const KEEP_BALANCED: number = 0.6

/**
 * 长记忆档：压缩后保留 80%。
 *
 * 从 70% 提到 80%：压缩是低频事件，一次多留一成，下一轮就不必那么快再压；
 * "压到 70%" 在 1M 窗口上省下的 token 不值钱，而被切掉的那 10% 信息很贵。
 */
const KEEP_LONG: number = 0.8

/**
 * 对话记忆设置。
 *
 * 与 `AiToolSettings` 分开：那个管"允许用什么工具、跑几轮"，
 * 这个管"什么时候压缩、压缩后留多少"。
 */
export class AiMemorySettings {
  /** 记忆档位（AI_MEMORY_MODE_*），未知值按默认档处理。 */
  mode: string = DEFAULT_AI_MEMORY_MODE
  /**
   * token 估算的校准系数（默认 1）。
   *
   * 由每次请求的真实 `usage.promptTokens / 本地估算` 用 EMA 收敛而来。
   * 中文在主流 BPE 下约 0.6–0.9 token/字，所以跑一段时间后通常会落到 0.6–0.9；
   * 预算按 `预算 / 系数` 放大，让"上下文 N%"接近真实。
   */
  tokenCalibration: number = DEFAULT_TOKEN_CALIBRATION
}

/** 校准系数默认值（未观测到真实样本前不调整）。 */
export const DEFAULT_TOKEN_CALIBRATION: number = 1

/**
 * 校准系数下限（真实 token 至少是估算的一半）。
 *
 * 再低就说明估算模型本身失效，继续放大预算只会撞窗口。
 */
export const TOKEN_CALIBRATION_MIN: number = 0.5

/** 校准系数上限（真实最多是估算的两倍）。 */
export const TOKEN_CALIBRATION_MAX: number = 2

/**
 * 把校准系数夹到合法区间。
 *
 * @param value - 原始系数
 * @returns 合法系数（非法输入回落 1）
 */
export function clampTokenCalibration(value: number): number {
  if (!isFinite(value) || value <= 0) {
    return DEFAULT_TOKEN_CALIBRATION
  }
  return Math.min(TOKEN_CALIBRATION_MAX, Math.max(TOKEN_CALIBRATION_MIN, value))
}

/**
 * 取档位对应的触发比例（占用达到预算的这个比例才压缩）。
 *
 * @param mode - 档位标识
 * @returns 触发比例（0..1）
 */
export function memoryTriggerRatio(mode: string): number {
  if (mode === AI_MEMORY_MODE_COMPACT) {
    return TRIGGER_COMPACT
  }
  if (mode === AI_MEMORY_MODE_BALANCED) {
    return TRIGGER_BALANCED
  }
  return TRIGGER_LONG
}

/**
 * 取档位对应的保留比例（压缩后保留多少）。
 *
 * @param mode - 档位标识
 * @returns 保留比例（0..1）
 */
export function memoryKeepRatio(mode: string): number {
  if (mode === AI_MEMORY_MODE_COMPACT) {
    return KEEP_COMPACT
  }
  if (mode === AI_MEMORY_MODE_BALANCED) {
    return KEEP_BALANCED
  }
  return KEEP_LONG
}

/**
 * 档位展示名。
 *
 * @param mode - 档位标识
 * @returns 展示名
 */
export function memoryModeTitle(mode: string): string {
  if (mode === AI_MEMORY_MODE_COMPACT) {
    return '精简'
  }
  if (mode === AI_MEMORY_MODE_BALANCED) {
    return '平衡'
  }
  return '长记忆'
}

/**
 * 档位一句话说明（设置页副标题）。
 *
 * @param mode - 档位标识
 * @returns 说明文案
 */
export function memoryModeDescription(mode: string): string {
  if (mode === AI_MEMORY_MODE_COMPACT) {
    return '用到 80% 就压缩，压缩后留 45%；仅在窗口很小、或流量受限时选它'
  }
  if (mode === AI_MEMORY_MODE_BALANCED) {
    return '用到 90% 才压缩，压缩后留 60%'
  }
  return '先把窗口用满（95%），压缩后仍保留八成；最不容易失忆'
}

/**
 * 归一化记忆设置（老版本没有该字段时返回默认档）。
 *
 * @param raw - 持久化的原始设置
 * @returns 归一化后的设置
 */
export function normalizeAiMemorySettings(raw: AiMemorySettings): AiMemorySettings {
  const settings: AiMemorySettings = new AiMemorySettings()
  if (raw === null || raw === undefined) {
    return settings
  }
  const mode: string = typeof raw.mode === 'string' ? raw.mode : ''
  if (mode === AI_MEMORY_MODE_COMPACT || mode === AI_MEMORY_MODE_BALANCED ||
    mode === AI_MEMORY_MODE_LONG) {
    settings.mode = mode
  } else {
    settings.mode = DEFAULT_AI_MEMORY_MODE
  }
  /* 校准系数：缺失/非法/越界一律回到 1，避免脏值把预算放大到撞窗口 */
  const factor: number = typeof raw.tokenCalibration === 'number' ? raw.tokenCalibration : 1
  settings.tokenCalibration = clampTokenCalibration(factor)
  return settings
}
