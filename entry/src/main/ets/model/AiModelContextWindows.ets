/**
 * 已知模型的上下文窗口（官方文档依据）。
 *
 * ## 为什么可以预埋
 *
 * 之前 `AiProviderProfile.contextWindow` 刻意不内置厂商表，理由是「客户端不猜测厂商私有约定」。
 * 那条原则针对的是**猜**（按模型名瞎推断窗口）。而这里收录的是**官方价目表写明的数值**——
 * 是事实，不是猜测。两者区别很大：前者错了会把请求推过窗口，后者错了用户手填一行就能覆盖。
 *
 * ## 为什么必须预埋
 *
 * 兜底预算只有 24000 token。而当前 DeepSeek 官方模型（`deepseek-flash` / `deepseek-v4-pro`）
 * 的上下文是 **1M**——两者差 40 倍。不预埋的后果是：用户明明买了 1M 窗口，
 * 客户端却按 24K 裁剪，"聊十几轮就失忆"，而且没有任何提示。
 *
 * ## 维护约定
 *
 * - 只收录**官方文档明确列出**的模型名与窗口值，不收录第三方托管商的自定义值；
 * - `SOURCE_URL` / `SNAPSHOT_DATE` / `SNAPSHOT_SUMMARY` 必须随表更新，便于判断是否过期；
 * - 查不到的模型返回 0（未知），由 `resolveHistoryBudget` 回落保守预算——
 *   **宁可保守，不可猜大**（猜大会直接 400）。
 */

/**
 * 一条已知模型窗口记录。
 */
export class ModelContextEntry {
  /** 模型标识（精确匹配，大小写不敏感） */
  modelId: string = ''
  /** 上下文窗口（token） */
  contextWindow: number = 0

  /**
   * 构造一条记录。
   *
   * @param modelId - 模型标识
   * @param contextWindow - 上下文窗口
   */
  constructor(modelId: string, contextWindow: number) {
    this.modelId = modelId
    this.contextWindow = contextWindow
  }
}

/** 数据来源（DeepSeek 官方「模型 & 价格」页）。 */
export const SOURCE_URL: string = 'https://api-docs.deepseek.com/zh-cn/quick_start/pricing'

/** 数据快照日期（更新表时必须同步）。 */
export const SNAPSHOT_DATE: string = '2026-10-23'

/**
 * 快照说明。
 *
 * 官方页面当时列出的模型：`deepseek-flash`（DeepSeek-V4.1-Flash-1017）、
 * `deepseek-v4-pro`（DeepSeek-V4-Pro-0813），上下文长度均为 1M、输出长度均为 384K。
 * 旧名 `deepseek-v4-flash`、`deepseek-v4-flash-vision-exp` 仍可调用，
 * 由 V4.1-Flash 提供服务，同样按 1M 记。
 */
export const SNAPSHOT_SUMMARY: string = 'deepseek-flash / deepseek-v4-pro：上下文 1M，输出 384K'

/** 1M 上下文（官方价目表标注值）。 */
const CONTEXT_1M: number = 1000000

/** 已知模型窗口表（按官方价目表，精确匹配）。 */
export const KNOWN_MODEL_CONTEXT_WINDOWS: ModelContextEntry[] = [
  new ModelContextEntry('deepseek-flash', CONTEXT_1M),
  new ModelContextEntry('deepseek-v4-pro', CONTEXT_1M),
  new ModelContextEntry('deepseek-v4-flash', CONTEXT_1M),
  new ModelContextEntry('deepseek-v4-flash-vision-exp', CONTEXT_1M)
]

/**
 * 按模型名查已知窗口。
 *
 * 精确匹配（大小写不敏感），查不到返回 0（未知）。刻意**不做前缀模糊匹配**：
 * 前缀匹配会把一个没见过的变体错配到旧窗口上，属于"猜"。
 *
 * @param modelName - 模型名称
 * @returns 上下文窗口；未知返回 0
 */
export function resolveModelContextWindow(modelName: string): number {
  const name: string = modelName.trim().toLowerCase()
  if (name.length === 0) {
    return 0
  }
  for (let i: number = 0; i < KNOWN_MODEL_CONTEXT_WINDOWS.length; i++) {
    if (KNOWN_MODEL_CONTEXT_WINDOWS[i].modelId === name) {
      return KNOWN_MODEL_CONTEXT_WINDOWS[i].contextWindow
    }
  }
  return 0
}
