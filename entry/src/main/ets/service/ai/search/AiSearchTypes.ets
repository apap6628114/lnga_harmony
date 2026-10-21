/**
 * 搜索服务商结果类型。
 *
 * 所有搜索适配器都把自家返回结构归一化成这里的类型，
 * 工具层与模型侧不感知具体服务商。
 */

/** 搜索结果条目。 */
export class WebSearchItem {
  /** 标题 */
  title: string = ''
  /** 链接 */
  url: string = ''
  /** 短摘要 */
  snippet: string = ''
  /** 长摘要（适合给模型阅读） */
  summary: string = ''
  /** 站点名称 */
  siteName: string = ''
  /** 发布时间（RFC 3339，可能为空） */
  date: string = ''
  /** 排序分数 0-3 */
  score: number = 0
  /** 权威性 0-4（-1 未知） */
  authority: number = -1
}

/** 搜索结果。 */
export class WebSearchResponse {
  /** 是否成功 */
  success: boolean = false
  /** 结果列表 */
  results: WebSearchItem[] = []
  /** 错误信息 */
  errorMessage: string = ''
}

/** 网页抓取结果。 */
export class WebFetchResponse {
  /** 是否成功 */
  success: boolean = false
  /** 页面标题 */
  title: string = ''
  /** Markdown 正文 */
  content: string = ''
  /** 错误信息 */
  errorMessage: string = ''
}
