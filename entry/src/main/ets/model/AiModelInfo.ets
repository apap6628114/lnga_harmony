/**
 * AI 模型元数据。
 *
 * 来自服务商 `GET /models` 返回的 data 数组，用于模型选择器展示。
 */

/** 模型元数据。 */
export class AiModelInfo {
  /** 模型标识（请求里使用） */
  id: string = ''
  /** 展示名称（缺失时回退到 id） */
  displayName: string = ''
  /** 上下文窗口（token 数，0 表示未知） */
  contextWindow: number = 0
  /** 单次输出上限（token 数，0 表示未知） */
  maxOutputTokens: number = 0
  /** 是否支持图片输入 */
  supportsImage: boolean = false
}
