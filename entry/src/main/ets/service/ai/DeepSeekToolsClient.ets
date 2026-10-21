/**
 * DeepSeek 官方网页搜索 / 抓取 HTTP 客户端。
 *
 * 只负责请求 `POST /v1/tools/search` 与 `POST /v1/tools/fetch` 并原样解析，
 * 供 DeepSeekSearchProvider 适配器调用。工具层不直接依赖本文件。
 */

import { http } from '@kit.NetworkKit'
import { AiSearchProfile } from '../../model/AiSearchConfig'
import { buildToolsUrl, extractServerError } from './AiEndpoint'
import { WebFetchResponse, WebSearchItem, WebSearchResponse } from './search/AiSearchTypes'
import { Logger, DOMAIN_SERVICE } from '../../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'DeepSeekToolsClient')

/** 工具请求读超时（毫秒）。 */
const TOOLS_READ_TIMEOUT: number = 30000
/** 工具请求连接超时（毫秒）。 */
const TOOLS_CONNECT_TIMEOUT: number = 10000
/** 网页正文回传给模型的最大字符数（超出截断并标注）。 */
const MAX_FETCH_CONTENT_CHARS: number = 12000

/**
 * 调用 DeepSeek 网页搜索接口。
 *
 * @param profile - 搜索配置（提供端点与密钥）
 * @param query - 搜索词
 * @param count - 返回条数
 * @param oriQuestion - 触发搜索的原始问题（帮助理解意图，可为空）
 * @returns 搜索结果
 */
export async function searchWeb(
  profile: AiSearchProfile,
  query: string,
  count: number,
  oriQuestion: string
): Promise<WebSearchResponse> {
  const response: WebSearchResponse = new WebSearchResponse()
  const apiKey: string = profile.apiKey.trim()
  if (apiKey.length === 0) {
    response.errorMessage = '未配置搜索服务 API 密钥'
    return response
  }
  const trimmedQuery: string = query.trim()
  if (trimmedQuery.length === 0) {
    response.errorMessage = '搜索词为空'
    return response
  }

  const bodyObj: Record<string, Object> = {}
  bodyObj['query'] = trimmedQuery
  bodyObj['count'] = count
  bodyObj['need_content'] = false
  const question: string = oriQuestion.trim()
  if (question.length > 0) {
    // 官方限制 ori_question 为 1~128 个字符
    bodyObj['ori_question'] = question.length > 128 ? question.substring(0, 128) : question
  }

  const url: string = buildToolsUrl(profile.endpoint, 'search')
  const httpRequest: http.HttpRequest = http.createHttp()
  try {
    const httpResponse: http.HttpResponse = await httpRequest.request(url, {
      method: http.RequestMethod.POST,
      header: buildHeaders(apiKey),
      extraData: JSON.stringify(bodyObj),
      expectDataType: http.HttpDataType.STRING,
      readTimeout: TOOLS_READ_TIMEOUT,
      connectTimeout: TOOLS_CONNECT_TIMEOUT
    })
    const statusCode: number = httpResponse.responseCode
    const responseText: string = (httpResponse.result as string) ?? ''
    if (statusCode !== 200) {
      response.errorMessage = translateToolsError(statusCode, responseText, '搜索')
      logger.warn('searchWeb failed: HTTP %{public}d', statusCode)
      return response
    }
    response.results = parseSearchResults(responseText)
    response.success = true
    return response
  } catch (err) {
    const e: Error = err as Error
    response.errorMessage = '搜索请求失败：' + (e.message.length > 0 ? e.message : '网络异常')
    logger.warn('searchWeb error: %{public}s', e.message ?? '')
    return response
  } finally {
    httpRequest.destroy()
  }
}

/**
 * 调用 DeepSeek 网页抓取接口。
 *
 * @param profile - 搜索配置（提供端点与密钥）
 * @param url - 目标网页地址
 * @returns 抓取结果（Markdown 正文）
 */
export async function fetchWebPage(profile: AiSearchProfile, url: string): Promise<WebFetchResponse> {
  const response: WebFetchResponse = new WebFetchResponse()
  const apiKey: string = profile.apiKey.trim()
  if (apiKey.length === 0) {
    response.errorMessage = '未配置搜索服务 API 密钥'
    return response
  }
  const targetUrl: string = url.trim()
  if (targetUrl.length === 0) {
    response.errorMessage = '网页地址为空'
    return response
  }
  if (!targetUrl.startsWith('http://') && !targetUrl.startsWith('https://')) {
    response.errorMessage = '仅支持 http/https 网页地址'
    return response
  }

  const bodyObj: Record<string, string> = {}
  bodyObj['url'] = targetUrl
  const requestUrl: string = buildToolsUrl(profile.endpoint, 'fetch')
  const httpRequest: http.HttpRequest = http.createHttp()
  try {
    const httpResponse: http.HttpResponse = await httpRequest.request(requestUrl, {
      method: http.RequestMethod.POST,
      header: buildHeaders(apiKey),
      extraData: JSON.stringify(bodyObj),
      expectDataType: http.HttpDataType.STRING,
      readTimeout: TOOLS_READ_TIMEOUT,
      connectTimeout: TOOLS_CONNECT_TIMEOUT
    })
    const statusCode: number = httpResponse.responseCode
    const responseText: string = (httpResponse.result as string) ?? ''
    if (statusCode !== 200) {
      response.errorMessage = translateToolsError(statusCode, responseText, '抓取')
      logger.warn('fetchWebPage failed: HTTP %{public}d', statusCode)
      return response
    }
    let json: Record<string, Object> = {}
    try {
      json = JSON.parse(responseText) as Record<string, Object>
    } catch (e) {
      response.errorMessage = '抓取响应解析失败'
      return response
    }
    response.title = readString(json, 'title')
    response.content = readString(json, 'content')
    if (response.content.trim().length === 0) {
      response.errorMessage = '页面没有可提取的正文'
      return response
    }
    response.success = true
    return response
  } catch (err) {
    const e: Error = err as Error
    response.errorMessage = '抓取请求失败：' + (e.message.length > 0 ? e.message : '网络异常')
    logger.warn('fetchWebPage error: %{public}s', e.message ?? '')
    return response
  } finally {
    httpRequest.destroy()
  }
}

/**
 * 将抓取到的正文裁剪到上下文预算内。
 *
 * @param content - 原始 Markdown 正文
 * @returns 裁剪后的正文（超限时追加截断标记）
 */
export function truncateFetchedContent(content: string): string {
  if (content.length <= MAX_FETCH_CONTENT_CHARS) {
    return content
  }
  return content.substring(0, MAX_FETCH_CONTENT_CHARS) + '\n\n……（网页正文过长，后续内容已截断）'
}

/**
 * 构造请求头。
 *
 * @param apiKey - 工具 API 密钥
 * @returns 请求头
 */
function buildHeaders(apiKey: string): Record<string, string> {
  const headers: Record<string, string> = {}
  headers['Content-Type'] = 'application/json'
  headers['Accept'] = 'application/json'
  headers['Authorization'] = 'Bearer ' + apiKey
  return headers
}

/**
 * 解析搜索结果 JSON。
 *
 * @param responseText - 响应文本
 * @returns 搜索结果列表
 */
function parseSearchResults(responseText: string): WebSearchItem[] {
  const result: WebSearchItem[] = []
  let json: Record<string, Object> = {}
  try {
    json = JSON.parse(responseText) as Record<string, Object>
  } catch (e) {
    return result
  }
  const resultsRaw: Object | undefined = json['results']
  if (resultsRaw === undefined || resultsRaw === null || !Array.isArray(resultsRaw)) {
    return result
  }
  const items: Object[] = resultsRaw as Object[]
  for (let i: number = 0; i < items.length; i++) {
    const raw: Record<string, Object> = items[i] as Record<string, Object>
    const item: WebSearchItem = new WebSearchItem()
    item.title = readString(raw, 'title')
    item.url = readString(raw, 'url')
    item.snippet = readString(raw, 'snippet')
    item.summary = readString(raw, 'summary')
    item.siteName = readString(raw, 'site_name')
    item.date = readString(raw, 'date')
    item.score = readNumber(raw, 'rerank_score')
    item.authority = readNumber(raw, 'authority')
    if (item.url.length > 0) {
      result.push(item)
    }
  }
  return result
}

/**
 * 翻译工具接口错误。
 *
 * @param statusCode - HTTP 状态码
 * @param responseText - 响应体
 * @param action - 动作名（搜索 / 抓取）
 * @returns 用户可读错误
 */
function translateToolsError(statusCode: number, responseText: string, action: string): string {
  const detail: string = extractServerError(responseText)
  if (statusCode === 401) {
    return 'DeepSeek 工具密钥无效或已过期'
  }
  if (statusCode === 402) {
    return 'DeepSeek 账户余额不足，无法' + action
  }
  if (statusCode === 403) {
    return action + '请求被安全策略拒绝'
  }
  if (statusCode === 404) {
    return action + '未获取到可用的网页内容'
  }
  if (statusCode === 429) {
    return action + '请求过于频繁，请稍后重试'
  }
  if (statusCode >= 500) {
    return action + '服务暂时不可用（' + statusCode.toString() + '）'
  }
  return action + '失败（' + statusCode.toString() + '）' + (detail.length > 0 ? '：' + detail : '')
}

/**
 * 安全读取字符串字段。
 *
 * @param record - 记录
 * @param key - 字段名
 * @returns 字符串值
 */
function readString(record: Record<string, Object>, key: string): string {
  const value: Object | undefined = record[key]
  return typeof value === 'string' ? value as string : ''
}

/**
 * 安全读取数字字段。
 *
 * @param record - 记录
 * @param key - 字段名
 * @returns 数字值，缺失时为 0
 */
function readNumber(record: Record<string, Object>, key: string): number {
  const value: Object | undefined = record[key]
  return typeof value === 'number' ? value as number : 0
}
