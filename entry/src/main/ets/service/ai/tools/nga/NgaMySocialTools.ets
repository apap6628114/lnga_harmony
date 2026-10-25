/**
 * NGA「我的关注动态 / 我的通知」工具。
 *
 * 两者都是**社交向推送**，但数据来源与新鲜度语义不同：
 *  - `nga_my_following`：关注动态读 `FollowActivityStore` 的内存真源（含分页追加），
 *    默认**零请求**；`refresh=true` 才拉 `follow_v2/get_push_list`。轮询周期在 Store 内部，
 *    工具不得假设数据是"刚刚"的。
 *  - `nga_my_notifications`：通知读 `NotificationStore` 的非私信缓存，与消息中心
 *    「消息」Tab 完全同源（同一份已读状态）。缓存为空时（用户从未打开过通知页）
 *    自动拉取一次，避免"没缓存 = 没通知"的误判——**拉取失败必须与"确实没有通知"区分**。
 *
 * 消息中心 4 个 Tab 的工具分工：消息（通知）→ 本文件 + `nga_my_messages`（私信）、
 * 动态 → 本文件、跟踪 → `nga_my_tracked`。
 *
 * 类型注意：`NgaNotification` 是 `ReplyNotification | MessageNotification | UpvoteNotification`
 * 的联合，父接口 `NotificationInfo` 上的字段（type / userName / title / timeStamp / seen）
 * 在联合上可直接访问；`tid` / `pid` / `page` 的形态随成员不同，统一由 `targetOf` 收窄。
 */

import { AiToolDefinition } from '../../AiProtocolTypes'
import {
  AiToolAdapter,
  AiToolCard,
  AiToolContext,
  AiToolResult,
  TOOL_ERROR_EMPTY,
  TOOL_ERROR_UPSTREAM
} from '../AiToolAdapter'
import { isAiToolEnabled } from '../../../../model/AiToolConfig'
import { appStore } from '../../../../store/AppStore'
import { NOTI_TYPE_MAP } from '../../../../common/constants/Constants'
import type { NotiTypeInfo } from '../../../../common/constants/Constants'
import type { NgaNotification, ReplyNotification, UpvoteNotification } from '../../../../model/Notification'
import { FollowedActivityType } from '../../../../model/Follow'
import type { FollowedActivity } from '../../../../model/Follow'
import {
  boolProperty,
  buildToolParameters,
  failedResult,
  formatToolTime,
  intProperty,
  isNgaReady,
  loginRequiredResult,
  parseToolArguments,
  pickText,
  readBoolArg,
  readIntArg,
  topicCard
} from './NgaToolSupport'

/** 关注动态工具名。 */
const TOOL_FOLLOWING: string = 'nga_my_following'
/** 我的通知工具名。 */
const TOOL_NOTIFICATIONS: string = 'nga_my_notifications'

/** 默认返回条数。 */
const DEFAULT_LIMIT: number = 20
/** 单次返回条数上限。 */
const MAX_LIMIT: number = 50
/** 单次最多附带的卡片数。 */
const MAX_CARDS: number = 20

/**
 * 通知的跳转目标（帖子 + 楼层 + 页码）。
 *
 * 三种通知形态的字段名不同：回复类在 `replyPid`/`page`，支持反对类在 `pid`/`page`。
 * 统一成同一个对象后，卡片参数生成就只剩一个来源。
 */
class NotificationTarget {
  /** 主题 tid。 */
  tid: string = ''
  /** 目标楼层 pid（可能为空）。 */
  pid: string = ''
  /** 服务端页码提示（可能为空）。 */
  page: string = ''
}

/**
 * 关注动态的动作文案（与消息中心 `NotificationPanel.describeAction` 同一套判断）。
 *
 * 关键点是 `pid`：`POST_TOPIC` 携带 pid 时实际是"发布了回复"，
 * 只看 type 会把回复说成发主题。
 *
 * @param activity - 动态条目
 * @returns 中文动作短语
 */
function activityVerb(activity: FollowedActivity): string {
  const isReply: boolean = activity.pid.length > 0 && activity.pid !== '0'
  if (activity.type === FollowedActivityType.POST_TOPIC) {
    return isReply ? '发布了回复' : '发布了帖子'
  }
  if (activity.type === FollowedActivityType.POST_REPLY) {
    return '回复了帖子'
  }
  if (activity.type === FollowedActivityType.FAVOR) {
    return isReply ? '收藏了回复' : '收藏了帖子'
  }
  return '发布了动态'
}

/**
 * 通知类型文案（与消息中心同一份映射，避免两处漂移）。
 *
 * @param type - NGA 通知类型
 * @returns 动作短语
 */
function notificationVerb(type: number): string {
  const info: NotiTypeInfo | undefined = NOTI_TYPE_MAP[type]
  return info !== undefined ? info.label : '通知'
}

/**
 * 判断通知类型是否属于「消息」Tab（帖子维度）。
 *
 * 私信类（type 10/11）不在本工具范围：它们没有 tid、点开是会话而不是帖子。
 * 这里显式按目录再筛一遍，不依赖上游过滤是否完整。
 *
 * @param type - NGA 通知类型
 * @returns true 表示帖子维度通知
 */
function isThreadNotification(type: number): boolean {
  const info: NotiTypeInfo | undefined = NOTI_TYPE_MAP[type]
  return info !== undefined && info.category === 'thread'
}

/**
 * 取通知的跳转目标（帖子 / 楼层 / 页码）。
 *
 * 调用前提：`isThreadNotification(type)` 为真。回复类用 `replyPid`（我回复的楼层），
 * 支持反对类用 `pid`——与消息中心的点击逻辑一致。
 *
 * @param notification - 通知对象
 * @returns 跳转目标（字段可能为空串）
 */
function targetOf(notification: NgaNotification): NotificationTarget {
  const target: NotificationTarget = new NotificationTarget()
  if (notification.type === 17) {
    const upvote: UpvoteNotification = notification as UpvoteNotification
    target.tid = pickText(upvote.tid)
    target.pid = pickText(upvote.pid)
    target.page = pickText(upvote.page)
    return target
  }
  const reply: ReplyNotification = notification as ReplyNotification
  target.tid = pickText(reply.tid)
  target.pid = pickText(reply.replyPid)
  target.page = pickText(reply.page)
  return target
}

/**
 * 关注动态工具（nga_my_following）。
 */
export class NgaMyFollowingTool implements AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_FOLLOWING
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_FOLLOWING
    definition.description =
      '读取「关注动态」：我关注的用户最近发主题、回帖、收藏的行为，按时间倒序。' +
        '默认读客户端本地缓存（零网络请求）；传 refresh=true 才向服务端拉取最新一页。' +
        '每条带本地已读标记（seen），可用于回答「我关注的人有什么新动作」。' +
        '这不是通知：通知是别人对我的动作，关注动态是我关注的人的动作。'

    const properties: Record<string, Object> = {}
    properties['limit'] = intProperty('返回条数 1-50，默认 20')
    properties['refresh'] = boolProperty('是否先向服务端拉取最新一页再返回，默认 false（只读缓存）')

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
    return isAiToolEnabled(context.tools, TOOL_FOLLOWING) && isNgaReady(context)
  }

  /**
   * 执行关注动态读取。
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
    const limit: number = readIntArg(args, 'limit', DEFAULT_LIMIT, 1, MAX_LIMIT)
    const refresh: boolean = readBoolArg(args, 'refresh', false)
    let refreshed: boolean = false
    if (refresh) {
      refreshed = await appStore.refreshActivities(true)
    }

    const items: FollowedActivity[] = appStore.getDisplayActivities()
    if (items.length === 0) {
      return failedResult(refresh && !refreshed
        ? '拉取关注动态失败（网络或风控），本地也没有缓存。可以稍后重试。'
        : '本地还没有关注动态：先在客户端「消息 → 动态」Tab 刷新一次，或传 refresh=true 让我拉取。',
      TOOL_ERROR_EMPTY)
    }

    const unread: number = appStore.unreadActivityCount
    const shown: number = Math.min(limit, items.length)
    let content: string = '关注动态（共 ' + items.length.toString() + ' 条，' +
      unread.toString() + ' 条未读；显示前 ' + shown.toString() + ' 条）'
    if (refresh) {
      content += refreshed ? '（已刷新）' : '（刷新失败，以下为本地缓存，可能不是最新）'
    }
    content += '\n'

    const cards: AiToolCard[] = []
    for (let i: number = 0; i < shown; i++) {
      const item: FollowedActivity = items[i]
      const actor: string = item.actorName.length > 0 ? item.actorName : ('uid=' + item.actorUid)
      const verb: string = activityVerb(item)
      const time: string = formatToolTime(item.timestamp)
      content += '\n' + (i + 1).toString() + '. ' + item.subject
      content += '\n   ' + actor + ' ' + verb
      if (time.length > 0) {
        content += ' · ' + time
      }
      if (!item.seen) {
        content += ' · 未读'
      }
      if (item.tid.length > 0) {
        content += '\n   tid=' + item.tid
        if (cards.length < MAX_CARDS) {
          cards.push(topicCard(item.tid, item.subject, actor + ' ' + verb))
        }
      }
      content += '\n'
    }
    if (items.length > shown) {
      content += '\n（还有 ' + (items.length - shown).toString() + ' 条，可增大 limit）'
    }

    const result: AiToolResult = new AiToolResult()
    result.success = true
    result.summary = '关注动态'
    result.count = shown
    result.content = content
    result.cards = cards
    return result
  }
}

/**
 * 我的通知工具（nga_my_notifications）。
 */
export class NgaMyNotificationsTool implements AiToolAdapter {
  /**
   * 获取工具名称。
   *
   * @returns 工具名称
   */
  getName(): string {
    return TOOL_NOTIFICATIONS
  }

  /**
   * 获取工具定义。
   *
   * @param context - 工具执行上下文
   * @returns 工具定义
   */
  getDefinition(context: AiToolContext): AiToolDefinition {
    const definition: AiToolDefinition = new AiToolDefinition()
    definition.name = TOOL_NOTIFICATIONS
    definition.description =
      '读取我的通知（消息中心「消息」Tab）：谁回复了我、谁提到了我、我的帖子被支持或反对。' +
        '数据与客户端消息中心同一份缓存，包含本地已读状态。**不含私信**（私信用 nga_my_messages）。' +
        '本地缓存为空时会自动向服务端拉取一次。' +
        '每条带 tid，可配合 nga_read_thread 看上下文；用户问「有什么新消息」「谁回我了」时使用。'

    const properties: Record<string, Object> = {}
    properties['limit'] = intProperty('返回条数 1-50，默认 20')
    properties['only_unread'] = boolProperty('是否只返回未读通知，默认 false（全部）')

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
    return isAiToolEnabled(context.tools, TOOL_NOTIFICATIONS) && isNgaReady(context)
  }

  /**
   * 执行通知读取。
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
    const limit: number = readIntArg(args, 'limit', DEFAULT_LIMIT, 1, MAX_LIMIT)
    const onlyUnread: boolean = readBoolArg(args, 'only_unread', false)

    let items: NgaNotification[] = appStore.getCachedNonMessageNotifications()
    if (items.length === 0) {
      // 从未打开过通知页时缓存为空：拉一次，否则会把"没缓存"误报成"没通知"
      const refreshed: boolean = await appStore.notificationStore.refreshNotifications(true)
      items = appStore.getCachedNonMessageNotifications()
      if (items.length === 0 && !refreshed) {
        return failedResult('通知拉取失败（网络或风控），本地也没有缓存，可以稍后重试。',
          TOOL_ERROR_UPSTREAM)
      }
    }

    const filtered: NgaNotification[] = []
    let nonThread: number = 0
    for (let i: number = 0; i < items.length; i++) {
      const notification: NgaNotification = items[i]
      if (!isThreadNotification(notification.type)) {
        // 理论上上游已过滤私信；这里兜住将来新增的类别，避免把"私信"混进帖子通知
        nonThread++
        continue
      }
      if (onlyUnread && notification.seen) {
        continue
      }
      filtered.push(notification)
    }
    if (filtered.length === 0) {
      if (items.length === 0) {
        return failedResult('没有通知：服务端没有返回任何通知。', TOOL_ERROR_EMPTY)
      }
      if (onlyUnread) {
        return failedResult('所有通知都已读（共 ' + items.length.toString() +
          ' 条）。不传 only_unread 可以看全部。', TOOL_ERROR_EMPTY)
      }
      return failedResult('没有可读的帖子通知（' + nonThread.toString() +
        ' 条私信类通知不在本工具范围）。', TOOL_ERROR_EMPTY)
    }

    const shown: number = Math.min(limit, filtered.length)
    let content: string = '我的通知（共 ' + filtered.length.toString() + ' 条' +
      (onlyUnread ? '未读' : '') + '，显示前 ' + shown.toString() + ' 条）：\n'
    const cards: AiToolCard[] = []
    for (let i: number = 0; i < shown; i++) {
      const notification: NgaNotification = filtered[i]
      const verb: string = notificationVerb(notification.type)
      const actor: string = notification.userName
      const title: string = notification.title
      const target: NotificationTarget = targetOf(notification)
      const time: string = formatToolTime(Number(notification.timeStamp))

      content += '\n' + (i + 1).toString() + '. ' + (title.length > 0 ? title : verb)
      content += '\n   ' + (actor.length > 0 ? actor + ' ' : '') + verb
      if (time.length > 0) {
        content += ' · ' + time
      }
      if (!notification.seen) {
        content += ' · 未读'
      }
      if (target.tid.length > 0) {
        content += '\n   tid=' + target.tid
        if (cards.length < MAX_CARDS) {
          cards.push(this.buildCard(target, title.length > 0 ? title : verb,
            (actor.length > 0 ? actor + ' · ' : '') + verb))
        }
      }
      content += '\n'
    }
    if (filtered.length > shown) {
      content += '\n（还有 ' + (filtered.length - shown).toString() + ' 条，可增大 limit）'
    }
    content += '\n需要看通知对应的帖子时调用 nga_read_thread 并传入 tid。'

    const result: AiToolResult = new AiToolResult()
    result.success = true
    result.summary = '我的通知'
    result.count = shown
    result.content = content
    result.cards = cards
    return result
  }

  /**
   * 构造通知卡片（点击打开对应帖子并定位楼层）。
   *
   * 用独立的 `kind='notification'` 让聊天页显示铃铛图标而不是帖子图标；
   * `route` 复用既有的 `thread`，把 pid/page 一并带给 `openCard`，
   * 与消息中心点击通知的落点一致（否则会落在帖子第一页）。
   *
   * @param target - 跳转目标
   * @param title - 卡片标题
   * @param subtitle - 卡片副标题
   * @returns 卡片
   */
  private buildCard(target: NotificationTarget, title: string, subtitle: string): AiToolCard {
    const card: AiToolCard = new AiToolCard()
    card.kind = 'notification'
    card.title = title
    card.subtitle = subtitle
    card.route = 'thread'
    const params: Record<string, string> = {}
    params['tid'] = target.tid
    if (target.pid.length > 0) {
      params['pid'] = target.pid
    }
    if (target.page.length > 0) {
      params['page'] = target.page
    }
    card.params = JSON.stringify(params)
    return card
  }
}
