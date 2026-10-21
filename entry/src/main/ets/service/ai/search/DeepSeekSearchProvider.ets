/**
 * DeepSeek 官方搜索服务适配器。
 *
 * 包装 `/v1/tools/search` 与 `/v1/tools/fetch`，把官方返回结构
 * 交给统一的 AiSearchTypes。
 */

import { AiSearchProfile } from '../../../model/AiSearchConfig'
import { SEARCH_PROVIDER_DEEPSEEK } from '../../../model/AiConfig'
import { AiSearchProvider } from './AiSearchProvider'
import { WebFetchResponse, WebSearchResponse } from './AiSearchTypes'
import { fetchWebPage, searchWeb } from '../DeepSeekToolsClient'

/**
 * DeepSeek 官方搜索服务。
 */
export class DeepSeekSearchProvider implements AiSearchProvider {
  /**
   * 获取服务商标识。
   *
   * @returns 服务商标识
   */
  getKind(): string {
    return SEARCH_PROVIDER_DEEPSEEK
  }

  /**
   * 获取服务商展示名。
   *
   * @returns 展示名
   */
  getName(): string {
    return 'DeepSeek 官方'
  }

  /**
   * 获取服务商说明。
   *
   * @returns 说明文案
   */
  getDescription(): string {
    return '官方 Search / Fetch 接口，使用 DeepSeek API Key'
  }

  /**
   * 判断是否可用（需要搜索配置里的 API Key）。
   *
   * @param profile - 搜索配置
   * @returns true 表示可用
   */
  isAvailable(profile: AiSearchProfile): boolean {
    return profile.apiKey.trim().length > 0
  }

  /**
   * 获取不可用提示。
   *
   * @returns 提示文案
   */
  getUnavailableHint(): string {
    return '请先在「搜索服务」中填写 DeepSeek API Key'
  }

  /**
   * 执行网页搜索。
   *
   * @param profile - 搜索配置
   * @param query - 搜索词
   * @param count - 返回条数
   * @param oriQuestion - 原始问题
   * @returns 搜索结果
   */
  async search(
    profile: AiSearchProfile,
    query: string,
    count: number,
    oriQuestion: string
  ): Promise<WebSearchResponse> {
    return searchWeb(profile, query, count, oriQuestion)
  }

  /**
   * 抓取网页正文。
   *
   * @param profile - 搜索配置
   * @param url - 网页地址
   * @returns 抓取结果
   */
  async fetchPage(profile: AiSearchProfile, url: string): Promise<WebFetchResponse> {
    return fetchWebPage(profile, url)
  }
}
