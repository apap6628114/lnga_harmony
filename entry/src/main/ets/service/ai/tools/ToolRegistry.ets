/**
 * 客户端工具注册表。
 *
 * 新增工具只需在 createAiToolRegistry 中注册一行；
 * Agent 循环通过注册表获取可用工具定义并分发执行。
 */

import { AiToolDefinition } from '../AiProtocolTypes'
import { AiToolAdapter, AiToolContext, AiToolResult } from './AiToolAdapter'
import { WebSearchTool } from './WebSearchTool'
import { WebFetchTool } from './WebFetchTool'

/**
 * 工具注册表。
 */
export class AiToolRegistry {
  /** 已注册的工具适配器。 */
  private adapters: AiToolAdapter[] = []

  /**
   * 注册工具。
   *
   * @param adapter - 工具适配器
   */
  register(adapter: AiToolAdapter): void {
    this.adapters.push(adapter)
  }

  /**
   * 获取当前上下文下可用的工具适配器。
   *
   * @param context - 工具执行上下文
   * @returns 可用适配器列表
   */
  getAvailableAdapters(context: AiToolContext): AiToolAdapter[] {
    const available: AiToolAdapter[] = []
    for (let i: number = 0; i < this.adapters.length; i++) {
      if (this.adapters[i].isAvailable(context)) {
        available.push(this.adapters[i])
      }
    }
    return available
  }

  /**
   * 获取当前上下文下可用的工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义列表
   */
  getDefinitions(context: AiToolContext): AiToolDefinition[] {
    const definitions: AiToolDefinition[] = []
    const available: AiToolAdapter[] = this.getAvailableAdapters(context)
    for (let i: number = 0; i < available.length; i++) {
      definitions.push(available[i].getDefinition(context))
    }
    return definitions
  }

  /**
   * 按名称查找工具适配器。
   *
   * @param name - 工具名称
   * @param context - 工具执行上下文
   * @returns 适配器，未注册或当前不可用时返回 null
   */
  getAdapter(name: string, context: AiToolContext): AiToolAdapter | null {
    for (let i: number = 0; i < this.adapters.length; i++) {
      if (this.adapters[i].getName() === name && this.adapters[i].isAvailable(context)) {
        return this.adapters[i]
      }
    }
    return null
  }

  /**
   * 执行一次工具调用。
   *
   * @param name - 工具名称
   * @param argumentsText - 参数 JSON
   * @param context - 工具执行上下文
   * @param fallbackQuery - 兜底查询
   * @returns 工具结果（未找到工具时返回失败结果）
   */
  async execute(
    name: string,
    argumentsText: string,
    context: AiToolContext,
    fallbackQuery: string
  ): Promise<AiToolResult> {
    const adapter: AiToolAdapter | null = this.getAdapter(name, context)
    if (adapter === null) {
      const result: AiToolResult = new AiToolResult()
      result.success = false
      result.errorMessage = '工具不可用：' + name
      result.content = '工具「' + name + '」当前不可用（未启用或未配置搜索服务）。请直接基于已有信息回答。'
      return result
    }
    return adapter.execute(argumentsText, context, fallbackQuery)
  }
}

/**
 * 创建并初始化工具注册表。
 *
 * @returns 已注册全部内置工具的注册表
 */
function createAiToolRegistry(): AiToolRegistry {
  const registry: AiToolRegistry = new AiToolRegistry()
  registry.register(new WebSearchTool())
  registry.register(new WebFetchTool())
  return registry
}

/** 全局工具注册表。 */
export const aiToolRegistry: AiToolRegistry = createAiToolRegistry()
