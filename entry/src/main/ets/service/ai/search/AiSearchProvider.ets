/**
 * 搜索服务商适配器契约。
 *
 * 模型侧永远只看到 `web_search` / `web_fetch` 两个工具；
 * 具体由哪家搜索服务执行、请求什么端点、如何解析返回，
 * 全部收敛在适配器实现里。
 *
 * 当前只注册 DeepSeek 官方；新增服务商时实现本接口并在
 * SearchProviderRegistry 注册一行即可，无需改动工具与 Agent。
 */

import { AiSearchProfile } from '../../../model/AiSearchConfig'
import { WebFetchResponse, WebSearchResponse } from './AiSearchTypes'

/**
 * 搜索服务商适配器。
 */
export interface AiSearchProvider {
  /**
   * 服务商标识（持久化到 AiSearchProfile.providerKind）。
   *
   * @returns 稳定标识
   */
  getKind(): string

  /**
   * 服务商展示名。
   *
   * @returns 展示名
   */
  getName(): string

  /**
   * 服务商一句话说明。
   *
   * @returns 说明文案
   */
  getDescription(): string

  /**
   * 判断当前配置下该服务商是否可用（通常是密钥是否齐全）。
   *
   * @param profile - 搜索配置
   * @returns true 表示可以执行搜索 / 抓取
   */
  isAvailable(profile: AiSearchProfile): boolean

  /**
   * 不可用时的用户提示。
   *
   * @returns 提示文案
   */
  getUnavailableHint(): string

  /**
   * 执行网页搜索。
   *
   * @param profile - 搜索配置（提供端点与密钥）
   * @param query - 搜索词
   * @param count - 返回条数
   * @param oriQuestion - 触发搜索的原始问题（可为空）
   * @returns 归一化后的搜索结果
   */
  search(
    profile: AiSearchProfile,
    query: string,
    count: number,
    oriQuestion: string
  ): Promise<WebSearchResponse>

  /**
   * 抓取网页正文。
   *
   * @param profile - 搜索配置（提供端点与密钥）
   * @param url - 目标网页地址
   * @returns 归一化后的抓取结果
   */
  fetchPage(profile: AiSearchProfile, url: string): Promise<WebFetchResponse>
}
