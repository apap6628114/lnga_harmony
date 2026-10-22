/**
 * NGA 收藏工具（nga_list_favorites）。
 *
 * 两种用法：不传 folderId 时列出收藏夹；传 folderId 时读取该收藏夹内的主题。
 */

import { AiToolDefinition } from '../../AiProtocolTypes'
import {
  AiToolAdapter,
  AiToolContext,
  AiToolResult,
  TOOL_ERROR_EMPTY
} from '../AiToolAdapter'
import { isAiToolEnabled } from '../../../../model/AiToolConfig'
import { createTopicListParams } from '../../../api/ForumApi'
import type { TopicListParams } from '../../../api/ForumApi'
import { fetchFavoriteTopicFolders } from '../../../api/FavoriteApi'
import type { FavoriteFolderListResult } from '../../../../model/NgaApiResults'
import type { FavoriteTopicFolder } from '../../../../model/Favorite'
import {
  DEFAULT_LIST_LIMIT,
  buildToolParameters,
  failedResult,
  intProperty,
  isNgaReady,
  loginRequiredResult,
  parseToolArguments,
  readIntArg,
  readStringArg,
  stringProperty
} from './NgaToolSupport'
import { fetchAndFormat } from './NgaTopicTools'

/** 工具名称。 */
const TOOL_NAME: string = 'nga_list_favorites'

/**
 * 收藏夹工具。
 */
export class NgaListFavoritesTool implements AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_NAME
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_NAME
    definition.description =
      '读取 NGA 收藏夹。不传 folder_id 时列出全部收藏夹；传 folder_id 时读取该收藏夹内的主题列表。'

    const properties: Record<string, Object> = {}
    properties['folder_id'] = stringProperty('收藏夹 ID；省略时列出收藏夹')
    properties['page'] = intProperty('收藏夹内主题的页码，默认 1')
    properties['limit'] = intProperty('返回条数 1-50，默认 20')

    const required: string[] = []
    definition.parameters = buildToolParameters(properties, required)
    return definition
  }

  /**
   * 判断工具是否可用。
   *
   * @param context - 工具执行上下文
   * @returns true 表示可用
   */
  isAvailable(context: AiToolContext): boolean {
    return isAiToolEnabled(context.tools, TOOL_NAME) && isNgaReady(context)
  }

  /**
   * 执行收藏夹读取。
   *
   * @param argumentsText - 模型生成的参数 JSON
   * @param context - 工具执行上下文
   * @param fallbackQuery - 兜底查询（不使用）
   * @returns 工具结果
   */
  async execute(argumentsText: string, context: AiToolContext,
    fallbackQuery: string): Promise<AiToolResult> {
    if (!isNgaReady(context)) {
      return loginRequiredResult()
    }
    const args: Record<string, Object> = parseToolArguments(argumentsText)
    const folderId: string = readStringArg(args, 'folder_id')
    const limit: number = readIntArg(args, 'limit', DEFAULT_LIST_LIMIT, 1, 50)
    const page: number = readIntArg(args, 'page', 1, 1, 1000)
    if (folderId.length === 0) {
      return this.listFolders(context.token)
    }
    const params: TopicListParams = createTopicListParams()
    params.favor = folderId
    params.page = page.toString()
    return fetchAndFormat(context.token, params, limit, '收藏夹')
  }

  /**
   * 列出全部收藏夹。
   *
   * @param token - 会话令牌
   * @returns 工具结果
   */
  private async listFolders(token: string): Promise<AiToolResult> {
    const fetched: FavoriteFolderListResult = await fetchFavoriteTopicFolders(token)
    const folders: FavoriteTopicFolder[] = fetched.data
    if (folders.length === 0) {
      return failedResult(fetched.error.length > 0 ? fetched.error : '没有收藏夹', TOOL_ERROR_EMPTY)
    }
    let content: string = '收藏夹（共 ' + folders.length.toString() + ' 个）：\n'
    for (let i: number = 0; i < folders.length; i++) {
      const folder: FavoriteTopicFolder = folders[i]
      content += '\n' + (i + 1).toString() + '. ' + folder.name +
        '（ID=' + folder.id + '，' + folder.topicCount.toString() + ' 个主题' +
        (folder.isDefault ? '，默认' : '') + '）'
    }
    content += '\n\n需要读某个收藏夹的主题时，调用本工具并传入 folder_id。'
    const result: AiToolResult = new AiToolResult()
    result.success = true
    result.summary = '收藏夹'
    result.count = folders.length
    result.content = content
    return result
  }
}
