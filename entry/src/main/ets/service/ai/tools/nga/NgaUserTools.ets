/**
 * NGA 用户工具。
 *
 * 四个工具覆盖「查一个人」的完整链路：读当前登录账号 → 搜名字拿 uid →
 * 读资料 → 读活跃样本。
 *
 * 参数回退规则（与 MCP 工具的"省略参数 = 用当前上下文"一致）：
 * 不传 uid / username 时，优先用当前页面用户，其次用**当前登录账号**，
 * 因此「看看我最近在哪些版块活跃」在任何入口都能直接工作。
 */

import { AiToolDefinition } from '../../AiProtocolTypes'
import {
  AiToolAdapter,
  AiToolCard,
  AiToolContext,
  AiToolResult,
  TOOL_ERROR_BAD_ARGS,
  TOOL_ERROR_EMPTY,
  TOOL_ERROR_LOGIN_REQUIRED,
  TOOL_ERROR_NOT_FOUND
} from '../AiToolAdapter'
import { isAiToolEnabled } from '../../../../model/AiToolConfig'
import { appStore } from '../../../../store/AppStore'
import {
  getUserActivityAnalysis,
  getUserProfile,
  resolveUidByUsername,
  searchUser
} from '../../../api/UserApi'
import type {
  SearchUserResult,
  UserActivityAnalysis,
  UserProfileResult
} from '../../../../model/NgaApiResults'
import type { ForumStat } from '../../../../model/NgaApiResults'
import type { ProfileData, SearchUserItem } from '../../../../model/User'
import {
  buildToolParameters,
  failedResult,
  boolProperty,
  isNgaReady,
  loginRequiredResult,
  missingUserResult,
  parseToolArguments,
  readBoolArg,
  readStringArg,
  resolveTargetUid,
  stringProperty,
  userCard
} from './NgaToolSupport'

/** 读当前登录用户工具名。 */
const TOOL_ME: string = 'nga_get_me'
/** 用户资料工具名。 */
const TOOL_USER: string = 'nga_get_user'
/** 用户搜索工具名。 */
const TOOL_SEARCH: string = 'nga_search_user'
/** 用户活跃工具名。 */
const TOOL_ACTIVITY: string = 'nga_user_activity'

/**
 * 读取当前登录账号的资料（nga_get_me）。
 *
 * 「我是谁」是最高频的上下文缺失来源：从全局 AI 助手进入时没有页面用户，
 * 而绝大多数"我的"类问题都从这一步开始，因此单独提供一个零参数工具。
 */
export class NgaGetMeTool implements AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_ME
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_ME
    definition.description =
      '读取当前登录的 NGA 账号资料（用户名、UID、用户组、等级、威望、发帖数、注册时间等）。' +
        '不需要任何参数。当用户说"我""我的账号""我自己"时先用它拿到 UID，' +
        '再配合 nga_user_activity 看活跃数据。'
    const required: string[] = []
    const properties: Record<string, Object> = {}
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
    return isAiToolEnabled(context.tools, TOOL_ME) && isNgaReady(context)
  }

  /**
   * 执行资料读取。
   *
   * @param argumentsText - 模型生成的参数 JSON（本工具无参数）
   * @param context - 工具执行上下文
   * @param fallbackQuery - 兜底查询（不使用）
   * @returns 工具结果
   */
  async execute(argumentsText: string, context: AiToolContext,
    fallbackQuery: string): Promise<AiToolResult> {
    if (!isNgaReady(context)) {
      return loginRequiredResult()
    }
    if (context.selfUid.length === 0) {
      return failedResult('拿不到当前登录账号的 UID，请提示用户重新登录后再试', TOOL_ERROR_LOGIN_REQUIRED)
    }
    return fetchProfileResult(context.token, context.selfUid, true)
  }
}

/**
 * 用户资料工具（nga_get_user）。
 */
export class NgaGetUserTool implements AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_USER
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_USER
    definition.description =
      '读取 NGA 用户资料：用户名、用户组、等级、威望、发帖数、注册时间、签名、所在地等。' +
        '参数可省略：不传 uid / username 时，依次使用当前页面用户、当前登录账号。'

    const properties: Record<string, Object> = {}
    properties['uid'] = stringProperty('用户 UID；省略时使用当前页面用户或当前登录账号')
    properties['username'] = stringProperty('完整用户名（精确匹配，片段不会命中）；与 uid 二选一，' +
      '同时传时 username 优先')

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
    return isAiToolEnabled(context.tools, TOOL_USER) && isNgaReady(context)
  }

  /**
   * 执行资料读取。
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
    const username: string = readStringArg(args, 'username')
    if (username.length > 0 && readStringArg(args, 'uid').length === 0) {
      const resolved: string = await resolveUidByUsername(context.token, username)
      if (resolved.length === 0) {
        return failedResult('没有找到用户「' + username + '」，可以先用 nga_search_user 搜索',
          TOOL_ERROR_NOT_FOUND)
      }
      return fetchProfileResult(context.token, resolved, false)
    }
    const uid: string = resolveTargetUid(context, args)
    if (uid.length === 0) {
      return missingUserResult()
    }
    return fetchProfileResult(context.token, uid, uid === context.selfUid)
  }
}

/**
 * 用户搜索工具。
 */
export class NgaSearchUserTool implements AiToolAdapter {
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
    definition.description = '按完整用户名或数字 UID 精确查找 NGA 用户，返回 uid 与用户名。' +
      '注意是精确匹配而非模糊搜索：只知道昵称片段不会命中，需先向用户确认完整用户名。' +
      '接口一次只返回一个匹配用户（没有分页、没有数量参数）。'

    const properties: Record<string, Object> = {}
    properties['key'] = stringProperty('完整用户名（精确匹配）或数字 UID；昵称片段不会命中')

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
   * 执行用户搜索。
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
      return failedResult('缺少用户名关键词', TOOL_ERROR_BAD_ARGS)
    }
    const fetched: SearchUserResult = await searchUser(context.token, key)
    const items: SearchUserItem[] = fetched.data
    if (items.length === 0) {
      return failedResult((fetched.error.length > 0 ? fetched.error : '没有找到匹配的用户') +
        '（该接口按完整用户名或 UID 精确匹配，昵称片段不会命中）', TOOL_ERROR_NOT_FOUND)
    }
    const count: number = items.length
    let content: string = '用户搜索「' + key + '」共 ' + items.length.toString() + ' 个结果：\n'
    const cards: AiToolCard[] = []
    for (let i: number = 0; i < count; i++) {
      const item: SearchUserItem = items[i]
      content += '\n' + (i + 1).toString() + '. ' + item.userName + '（uid=' + item.uid + '）'
      cards.push(userCard(item.uid, item.userName, '搜索「' + key + '」'))
    }
    content += '\n\n需要资料时调用 nga_get_user 并传入 uid；需要活跃数据时调用 nga_user_activity。'
    const result: AiToolResult = new AiToolResult()
    result.success = true
    result.summary = key
    result.count = count
    result.content = content
    result.cards = cards
    return result
  }
}

/**
 * 用户活跃分析工具。
 */
export class NgaUserActivityTool implements AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_ACTIVITY
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_ACTIVITY
    definition.description =
      '读取 NGA 用户的活跃度分析：发帖/回复总数、版块分布、时段分布与近期帖子标题、回复片段。' +
        '参数可省略：不传 uid 时，依次使用当前页面用户、当前登录账号。' +
        '用户说"我最近在哪些版块活跃"时直接调用本工具即可。' +
        'include_samples=false 可省略样本（样本较多时能显著减少上下文占用）。'

    const properties: Record<string, Object> = {}
    properties['uid'] = stringProperty('用户 UID；省略时使用当前页面用户或当前登录账号')
    properties['include_samples'] = boolProperty('是否返回帖子标题与回复片段样本，默认 true；' +
      '样本可能较多，只要统计数字时传 false')

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
    return isAiToolEnabled(context.tools, TOOL_ACTIVITY) && isNgaReady(context)
  }

  /**
   * 执行活跃分析读取。
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
    const uid: string = resolveTargetUid(context, args)
    if (uid.length === 0) {
      return missingUserResult()
    }
    const includeSamples: boolean = readBoolArg(args, 'include_samples', true)

    const analysis: UserActivityAnalysis | null = await getUserActivityAnalysis(context.token, uid)
    if (analysis === null || (analysis.topicCount === 0 && analysis.replyCount === 0)) {
      // 接口失败时底层会返回"空统计"而不是 null，直接说"0 帖"会误导，
      // 这里统一按"没读到记录"处理，并给出可重试/换目标的方向。
      return failedResult('没有读到该用户的活跃记录：可能是官方接口返回为空、该账号没有公开记录，或数据量太少。' +
        '可以稍后重试，或确认 UID 是否正确。', TOOL_ERROR_EMPTY)
    }

    let content: string = '用户 uid=' + uid
    if (uid === context.selfUid && context.selfUserName.length > 0) {
      content += '（当前登录账号「' + context.selfUserName + '」）'
    }
    content += ' 的活跃分析：\n'
    content += '\n- 主题数：' + analysis.topicCount.toString()
    content += '\n- 回复数：' + analysis.replyCount.toString()

    if (analysis.forumList.length > 0) {
      content += '\n\n版块分布（Top ' + analysis.forumList.length.toString() + '）：'
      for (let i: number = 0; i < analysis.forumList.length; i++) {
        const stat: ForumStat = analysis.forumList[i]
        content += '\n- ' + stat.name + '：主题 ' + stat.topicCount.toString() +
          ' / 回复 ' + stat.replyCount.toString()
      }
    }

    if (analysis.hourDistribution.length > 0) {
      let dawn: number = 0
      let morning: number = 0
      let afternoon: number = 0
      let night: number = 0
      for (let h: number = 0; h < analysis.hourDistribution.length; h++) {
        const value: number = analysis.hourDistribution[h]
        if (h <= 5) {
          dawn += value
        } else if (h <= 11) {
          morning += value
        } else if (h <= 17) {
          afternoon += value
        } else {
          night += value
        }
      }
      content += '\n\n时段分布：凌晨 ' + dawn.toString() + ' / 上午 ' + morning.toString() +
        ' / 下午 ' + afternoon.toString() + ' / 晚上 ' + night.toString()
    }

    if (includeSamples && analysis.topicSubjects.length > 0) {
      content += '\n\n近期主题标题：'
      for (let i: number = 0; i < analysis.topicSubjects.length; i++) {
        content += '\n' + (i + 1).toString() + '. ' + analysis.topicSubjects[i]
      }
    }
    if (includeSamples && analysis.replySnippets.length > 0) {
      content += '\n\n近期回复片段：'
      for (let i: number = 0; i < analysis.replySnippets.length; i++) {
        content += '\n' + (i + 1).toString() + '. ' + analysis.replySnippets[i]
      }
    }
    content += '\n\n如需具体帖子内容，调用 nga_read_thread。'

    const result: AiToolResult = new AiToolResult()
    result.success = true
    result.summary = '活跃分析 uid=' + uid
    result.count = analysis.forumList.length
    result.content = content
    const cards: AiToolCard[] = []
    cards.push(userCard(uid, 'uid=' + uid,
      '主题 ' + analysis.topicCount.toString() + ' · 回复 ' + analysis.replyCount.toString()))
    result.cards = cards
    return result
  }
}

/**
 * 拉取用户资料并整理为工具结果。
 *
 * 优先走 `ProfileStore` 的 5 分钟 LRU（UI 侧资料卡用的是同一份缓存）：
 * 用户刚看过的资料不会再向 NGA 请求一次，既省流量也降低风控压力。
 * 缓存层取不到时（未登录 / 刷新失败）再回退到直连接口。
 *
 * @param token - 会话令牌
 * @param uid - 用户 UID
 * @param isSelf - 是否当前登录账号
 * @returns 工具结果
 */
async function fetchProfileResult(token: string, uid: string, isSelf: boolean): Promise<AiToolResult> {
  let profile: ProfileData | null = null
  try {
    profile = await appStore.profileStore.loadProfileForTool(uid)
  } catch (e) {
    profile = null
  }
  if (profile === null) {
    const fetched: UserProfileResult = await getUserProfile(token, uid)
    profile = fetched.data
    if (profile === null) {
      return failedResult(fetched.error.length > 0 ? fetched.error : '没有取到用户资料')
    }
  }

  let content: string = '用户「' + profile.userName + '」（uid=' + profile.uid + '）'
  if (isSelf) {
    content += ' · 当前登录账号'
  }
  content += '\n'
  content = appendLine(content, '用户组', profile.group)
  let levelLine: string = ''
  if (profile.yz > 0) {
    levelLine = profile.yz.toString() + ' 级'
  }
  if (profile.title.length > 0) {
    levelLine += (levelLine.length > 0 ? ' · ' : '') + '头衔：' + profile.title
  }
  if (levelLine.length > 0) {
    content += '\n- 等级/头衔：' + levelLine
  }
  content = appendLine(content, '威望', profile.rvrc)
  content = appendLine(content, '发帖数', profile.posts)
  content = appendLine(content, '获赞', profile.likeCount)
  content = appendLine(content, 'N 币', profile.money)
  content = appendLine(content, '所在地', profile.ipLoc)
  content = appendLine(content, '注册时间', profile.regdate)
  content = appendLine(content, '关注', profile.followNum)
  content = appendLine(content, '粉丝', profile.followByNum)
  if (profile.medal.length > 0) {
    content += '\n- 勋章：' + profile.medal
  }
  if (profile.muteTime.length > 0) {
    content += '\n- 禁言到期：' + profile.muteTime
  }
  if (profile.sign.length > 0) {
    content += '\n- 签名：' + profile.sign
  }
  if (profile.adminForums.length > 0) {
    let forums: string = ''
    for (let i: number = 0; i < profile.adminForums.length; i++) {
      forums += (i > 0 ? '、' : '') + profile.adminForums[i].forumName
    }
    content += '\n- 管理版块：' + forums
  }
  content += '\n\n需要活跃数据时调用 nga_user_activity（省略 uid 即查该用户）。'

  const result: AiToolResult = new AiToolResult()
  result.success = true
  result.summary = profile.userName
  result.count = 1
  result.content = content
  const cards: AiToolCard[] = []
  cards.push(userCard(profile.uid, profile.userName,
    (isSelf ? '当前登录 · ' : '') +
      (profile.yz > 0 ? profile.yz.toString() + ' 级' : '') +
      (profile.posts.length > 0 ? ' · 发帖 ' + profile.posts : '')))
  result.cards = cards
  return result
}

/**
 * 往结果文本追加一行非空字段。
 *
 * ArkTS 字符串不可变，这里通过返回值拼接到调用方变量。
 *
 * @param target - 目标文本
 * @param label - 字段名
 * @param value - 字段值
 * @returns 拼接后的文本
 */
function appendLine(target: string, label: string, value: string): string {
  return value.length > 0 ? target + '\n- ' + label + '：' + value : target
}
