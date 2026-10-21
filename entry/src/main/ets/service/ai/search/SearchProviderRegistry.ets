/**
 * 搜索服务商注册表。
 *
 * 新增服务商只需实现 AiSearchProvider 并在这里注册一行；
 * 工具定义与 Agent 循环不需要任何改动。
 */

import { AiSearchProvider } from './AiSearchProvider'
import { DeepSeekSearchProvider } from './DeepSeekSearchProvider'

/**
 * 搜索服务商注册表。
 */
export class AiSearchProviderRegistry {
  /** 已注册的服务商。 */
  private providers: AiSearchProvider[] = []

  /**
   * 注册服务商。
   *
   * @param provider - 适配器实例
   */
  register(provider: AiSearchProvider): void {
    this.providers.push(provider)
  }

  /**
   * 获取全部服务商。
   *
   * @returns 服务商列表（按注册顺序）
   */
  list(): AiSearchProvider[] {
    return this.providers
  }

  /**
   * 按标识获取服务商。
   *
   * 未注册的标识回退到第一个服务商，避免脏配置让工具直接失效。
   *
   * @param kind - 服务商标识
   * @returns 服务商适配器
   */
  get(kind: string): AiSearchProvider {
    for (let i: number = 0; i < this.providers.length; i++) {
      if (this.providers[i].getKind() === kind) {
        return this.providers[i]
      }
    }
    return this.providers[0]
  }

  /**
   * 判断指定标识是否为已注册服务商。
   *
   * @param kind - 服务商标识
   * @returns true 表示已注册
   */
  isRegistered(kind: string): boolean {
    for (let i: number = 0; i < this.providers.length; i++) {
      if (this.providers[i].getKind() === kind) {
        return true
      }
    }
    return false
  }
}

/**
 * 创建并初始化注册表。
 *
 * @returns 已注册全部搜索服务商的注册表
 */
function createRegistry(): AiSearchProviderRegistry {
  const registry: AiSearchProviderRegistry = new AiSearchProviderRegistry()
  registry.register(new DeepSeekSearchProvider())
  return registry
}

/** 全局搜索服务商注册表。 */
export const aiSearchProviderRegistry: AiSearchProviderRegistry = createRegistry()
