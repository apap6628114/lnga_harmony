/**
 * NGA 版块工具。
 *
 * `nga_list_forums` 解决「模型知道版块名但不知道 fid」的起点问题：
 * 先列收藏版面（用户最常用）或全部分类，再翻主题列表。
 */

import { AiToolDefinition } from '../../AiProtocolTypes'
import {
  AiToolAdapter,
  AiToolCard,
  AiToolContext,
  AiToolResult,
  TOOL_ERROR_BAD_ARGS,
  TOOL_ERROR_EMPTY,
  TOOL_ERROR_NOT_FOUND
} from '../AiToolAdapter'
import { isAiToolEnabled } from '../../../../model/AiToolConfig'
import { getForumCategories, searchForum } from '../../../api/ForumApi'
import { fetchForumFavorites } from '../../../api/FavoriteApi'
import type {
  CategoriesResult,
  FavBoardItem,
  ForumFavoritesResult,
  SearchForumResult
} from '../../../../model/NgaApiResults'
import type { BoardContent, Category, CategorySub, ForumSearchItem } from '../../../../model/Forum'
import {
  buildToolParameters,
  enumProperty,
  failedResult,
  forumCard,
  intProperty,
  isNgaReady,
  loginRequiredResult,
  parseToolArguments,
  readIntArg,
  readStringArg,
  stringProperty
} from './NgaToolSupport'
import { containsNonAscii } from '../ToolInputLimits'

/** 我的版块工具名。 */
const TOOL_LIST: string = 'nga_list_forums'
/** 版块搜索工具名。 */
const TOOL_SEARCH: string = 'nga_search_forum'
/** 全部分类默认最多展示的版块数。 */
const DEFAULT_ALL_LIMIT: number = 60
/** 单次最多展示的版块数。 */
const MAX_ALL_LIMIT: number = 200
/** 单次最多附带的卡片数（卡片是 UI 元素，过多会拖慢列表渲染）。 */
const MAX_CARDS: number = 20

/**
 * 我的版块 / 全部版块工具。
 */
export class NgaListForumsTool implements AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_LIST
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_LIST
    definition.description =
      '列出 NGA 版块及其 fid。默认列出用户收藏的版面（最常用）；' +
        'scope=all 时列出全部分类的版块（数量多，可用 limit 限制）。'

    const properties: Record<string, Object> = {}
    properties['scope'] = enumProperty(
      '范围：favorites=用户收藏的版面（默认），all=全部分类的版块',
      ['favorites', 'all'])
    properties['limit'] = intProperty('最多返回多少个版块，1-' + MAX_ALL_LIMIT.toString() +
      '，默认 40（scope=all 时默认 ' + DEFAULT_ALL_LIMIT.toString() + '）')

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
    return isAiToolEnabled(context.tools, TOOL_LIST) && isNgaReady(context)
  }

  /**
   * 执行版块列表读取。
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
    const scope: string = readStringArg(args, 'scope')
    const limit: number = readIntArg(args, 'limit', scope === 'all' ? DEFAULT_ALL_LIMIT : 40, 1, MAX_ALL_LIMIT)
    if (scope === 'all') {
      return this.fetchAll(context.token, limit)
    }
    return this.fetchFavorites(context.token, limit)
  }

  /**
   * 读取收藏版面。
   *
   * @param token - 会话令牌
   * @param limit - 展示条数
   * @returns 工具结果
   */
  private async fetchFavorites(token: string, limit: number): Promise<AiToolResult> {
    const fetched: ForumFavoritesResult = await fetchForumFavorites(token)
    const boards: FavBoardItem[] = fetched.data
    if (boards.length === 0) {
      return failedResult(fetched.error.length > 0 ? fetched.error :
        '用户没有收藏任何版面。可以改用 nga_search_forum（英文版块名）或 nga_list_forums scope=all 查找版块', TOOL_ERROR_EMPTY)
    }
    const count: number = Math.min(limit, boards.length)
    let content: string = '收藏版面（共 ' + boards.length.toString() + ' 个）：\n'
    const cards: AiToolCard[] = []
    for (let i: number = 0; i < count; i++) {
      const board: FavBoardItem = boards[i]
      content += '\n- ' + board.name + '（fid=' + board.fid.toString() + '）'
      if (cards.length < MAX_CARDS) {
        cards.push(forumCard(board.fid.toString(), board.name, '收藏版面'))
      }
    }
    if (boards.length > count) {
      content += '\n\n（还有 ' + (boards.length - count).toString() +
        ' 个收藏版面未展示，可增大 limit 后重试）'
    }
    content += '\n\n需要看某个版块的主题时调用 nga_list_topics 并传入 fid。'
    const result: AiToolResult = new AiToolResult()
    result.success = true
    result.summary = '收藏版面'
    result.count = count
    result.content = content
    result.cards = cards
    return result
  }

  /**
   * 读取全部分类版块。
   *
   * @param token - 会话令牌
   * @param limit - 展示条数
   * @returns 工具结果
   */
  private async fetchAll(token: string, limit: number): Promise<AiToolResult> {
    const fetched: CategoriesResult = await getForumCategories(token)
    const categories: Category[] = fetched.data
    if (categories.length === 0) {
      return failedResult(fetched.error.length > 0 ? fetched.error : '没有取到版块分类',
        TOOL_ERROR_EMPTY)
    }
    let content: string = '版块分类：\n'
    const cards: AiToolCard[] = []
    let shown: number = 0
    let total: number = 0
    for (let i: number = 0; i < categories.length; i++) {
      const category: Category = categories[i]
      let categoryText: string = ''
      for (let j: number = 0; j < category.sub.length; j++) {
        const sub: CategorySub = category.sub[j]
        for (let k: number = 0; k < sub.content.length; k++) {
          const board: BoardContent = sub.content[k]
          total++;
          if (shown >= limit) {
            continue
          }
          categoryText += '\n  - ' + board.name + '（fid=' + board.fid.toString() + '）'
          if (cards.length < MAX_CARDS) {
            cards.push(forumCard(board.fid.toString(), board.name, category.name + ' / ' + sub.name))
          }
          shown++;
        }
      }
      if (categoryText.length > 0) {
        content += '\n【' + category.name + '】' + categoryText + '\n'
      }
    }
    if (total > shown) {
      content += '\n（共 ' + total.toString() + ' 个版块，已展示前 ' + shown.toString() +
        ' 个；可增大 limit（上限 ' + MAX_ALL_LIMIT.toString() +
        '），或改用 nga_search_forum 按英文版块名查找）\n'
    }
    const result: AiToolResult = new AiToolResult()
    result.success = true
    result.summary = '版块分类'
    result.count = shown
    result.content = content
    result.cards = cards
    return result
  }
}

/**
 * 版块搜索工具。
 */
export class NgaSearchForumTool implements AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_SEARCH
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_SEARCH
    definition.description =
      '按版块名搜索 NGA 版块，返回版块名与 fid。' +
        '注意：NGA 该接口只接受英文版块名（如 warcraft），中文关键词会被服务端拒绝；' +
        '中文版块名请改用 nga_list_forums（scope=all）在版块目录中查找。'

    const properties: Record<string, Object> = {}
    properties['key'] = stringProperty('版块英文名关键词（如 warcraft）；' +
      '中文关键词会被服务端拒绝，中文版块请改用 nga_list_forums')

    const required: string[] = []
    required.push('key')
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
    return isAiToolEnabled(context.tools, TOOL_SEARCH) && isNgaReady(context)
  }

  /**
   * 执行版块搜索。
   *
   * @param argumentsText - 模型生成的参数 JSON
   * @param context - 工具执行上下文
   * @param fallbackQuery - 兜底查询（缺参时使用）
   * @returns 工具结果
   */
  async execute(argumentsText: string, context: AiToolContext,
    fallbackQuery: string): Promise<AiToolResult> {
    if (!isNgaReady(context)) {
      return loginRequiredResult()
    }
    const args: Record<string, Object> = parseToolArguments(argumentsText)
    let key: string = readStringArg(args, 'key')
    if (key.length === 0) {
      key = fallbackQuery.trim()
    }
    if (key.length === 0) {
      return failedResult('缺少版块关键词', TOOL_ERROR_BAD_ARGS)
    }
    // NGA 版块搜索接口只认英文版块名：实测中文关键词（2~11 字）全部返回
    // 2048「关键字过短/长」。提前拦下，避免发一次必然失败的请求（还会消耗风控预算），
    // 直接给模型可执行的替代路径。
    if (containsNonAscii(key)) {
      return failedResult('NGA 版块搜索接口只接受英文版块名（如 warcraft），中文关键词「' + key +
        '」会被服务端拒绝。请改用 nga_list_forums 并传 scope=all 在版块目录中查找。',
        TOOL_ERROR_BAD_ARGS)
    }
    const fetched: SearchForumResult = await searchForum(context.token, key)
    const items: ForumSearchItem[] = fetched.data
    if (items.length === 0) {
      const message: string = fetched.error.length > 0 ? fetched.error : '没有找到匹配的版块'
      if (message.indexOf('关键字过短') >= 0) {
        return failedResult('NGA 版块搜索要求英文版块名且长度合适（实测 8 个字符左右可用），' +
          '当前关键词「' + key + '」被服务端拒绝。可改用 nga_list_forums 并传 scope=all 浏览版块目录。',
          TOOL_ERROR_NOT_FOUND)
      }
      return failedResult(message, TOOL_ERROR_NOT_FOUND)
    }
    let content: string = '版块搜索「' + key + '」共 ' + items.length.toString() + ' 个结果：\n'
    const cards: AiToolCard[] = []
    for (let i: number = 0; i < items.length; i++) {
      const item: ForumSearchItem = items[i]
      content += '\n' + (i + 1).toString() + '. ' + item.name + '（fid=' + item.fid + '）'
      if (item.info.length > 0) {
        content += '\n   ' + item.info
      }
      cards.push(forumCard(item.fid, item.name, item.info))
    }
    content += '\n\n需要看该版块的主题时调用 nga_list_topics 并传入 fid。'
    const result: AiToolResult = new AiToolResult()
    result.success = true
    result.summary = key
    result.count = items.length
    result.content = content
    result.cards = cards
    return result
  }
}
