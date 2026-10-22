/**
 * 客户端工具注册表。
 *
 * 新增工具只需：在 `AI_TOOL_CATALOG` 登记元数据、实现 `AiToolAdapter`、
 * 在 createAiToolRegistry 注册一行。UI 与 Agent 循环都从注册表取，
 * 不再有任何按工具名写死的分支。
 */

import { AiToolDefinition } from '../AiProtocolTypes'
import { presetAllowsTool } from '../../../model/AiAgentPreset'
import { AiToolAdapter, AiToolContext, AiToolResult } from './AiToolAdapter'
import { WebSearchTool } from './WebSearchTool'
import { WebFetchTool } from './WebFetchTool'
import { NgaReadThreadTool } from './nga/NgaThreadTools'
import { NgaListTopicsTool, NgaSearchTopicsTool } from './nga/NgaTopicTools'
import { NgaListForumsTool, NgaSearchForumTool } from './nga/NgaForumTools'
import { NgaGetMeTool, NgaGetUserTool, NgaSearchUserTool, NgaUserActivityTool } from './nga/NgaUserTools'
import { NgaListFavoritesTool } from './nga/NgaFavoriteTools'

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
   * 判定顺序：任务白名单 → 工具自身可用性（全局开关 + 依赖就绪）。
   *
   * @param context - 工具执行上下文
   * @returns 可用适配器列表
   */
  getAvailableAdapters(context: AiToolContext): AiToolAdapter[] {
    const available: AiToolAdapter[] = []
    for (let i: number = 0; i < this.adapters.length; i++) {
      const adapter: AiToolAdapter = this.adapters[i]
      if (!presetAllowsTool(context.preset, adapter.getName())) {
        continue
      }
      if (adapter.isAvailable(context)) {
        available.push(adapter)
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
   * 获取当前上下文下可用的工具名（供 UI 展示"哪些工具已就绪"）。
   *
   * @param context - 工具执行上下文
   * @returns 可用工具名列表
   */
  getAvailableNames(context: AiToolContext): string[] {
    const names: string[] = []
    const available: AiToolAdapter[] = this.getAvailableAdapters(context)
    for (let i: number = 0; i < available.length; i++) {
      names.push(available[i].getName())
    }
    return names
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
      if (this.adapters[i].getName() === name && presetAllowsTool(context.preset, name) &&
        this.adapters[i].isAvailable(context)) {
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
      result.content = '工具「' + name + '」当前不可用（未启用、未登录或不在本任务的工具范围内）。' +
        '请换用其它工具或直接基于已有信息回答。'
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
  // NGA 站内只读工具（登录后即可用）
  registry.register(new NgaGetMeTool())
  registry.register(new NgaReadThreadTool())
  registry.register(new NgaListTopicsTool())
  registry.register(new NgaSearchTopicsTool())
  registry.register(new NgaListForumsTool())
  registry.register(new NgaSearchForumTool())
  registry.register(new NgaGetUserTool())
  registry.register(new NgaSearchUserTool())
  registry.register(new NgaUserActivityTool())
  registry.register(new NgaListFavoritesTool())
  // 联网工具（需要搜索服务）
  registry.register(new WebSearchTool())
  registry.register(new WebFetchTool())
  return registry
}

/** 全局工具注册表。 */
export const aiToolRegistry: AiToolRegistry = createAiToolRegistry()
