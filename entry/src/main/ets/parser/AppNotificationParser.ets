/**
 * 官方 APP 通知解析（app_api.php?__lib=notify&__act=list，通知中心「消息」列表）。
 *
 * 官方接口（POST form + __ngaClientChecksum，__output=14，实测 ngabbs.com）与
 * nuke.php 网页版（__lib=noti&__act=get_all）响应形状不同：
 *
 *   {"code":0,"msg":"操作成功","result":{
 *     "reply":[{"time":"1787302659","type":"2","from_uid":"61165627",
 *       "to_uid":"42023922","about_id3":"879163948","about_id":"47412557",
 *       "about_id2":"879167934","about_id4":"2","":"0",
 *       "from_uname":"洛夜熙","to_uname":"llllllIl","text":"..."}],
 *     "msg":[],"sys":[],"unread":0,"lasttime":"...",
 *     "unread_cnt":{"reply":0,"msg":0,"sys":0,"follow":0,"unread":0},
 *     "checked_in":false}}
 *
 * - result.reply / result.msg / result.sys 为三个平铺数组（实测为 NotificationObj
 *   数组，非卡片 18 中 Gson 类型声明推断的 dt.b 嵌套）
 * - 条目字段与网页版数字键数组的映射：
 *   type→type、from_uid→发起人、from_uname→发起人名、time→时间戳、
 *   about_id→tid（私信为 mid）、about_id2→pid/replyPid、about_id3→repliedPid、
 *   about_id4→page、text→标题/摘要、to_uid→被评价用户（点赞）
 * - 页码实测：仅帖子互动类（回复/评论，type 1/2/7/8）携带 about_id4（=新回复
 *   pid 所在页）；支持或反对（type 17）恒为 0，无页码线索——打开帖子需先
 *   pid→页码预查找（见 NotificationPanel.openThreadAfterPidLookup）
 * - 未读提示：result.unread（int）优先，回退 unread_cnt.unread
 *
 * 本地稳定 ID 的构造格式固定（见各构造函数），不随接口通道变化，
 * 保证接口迁移后本地已读/去重状态不丢失。
 *
 * 纯函数模块，不依赖 AppStore / 网络，可直接被 Hypium Local Test 覆盖。
 */

import type {
  NgaNotification,
  NotificationParseResult,
  ReplyNotification,
  MessageNotification,
  UpvoteNotification,
} from '../model/Notification'

/**
 * 判断通知类型是否属于私信。
 *
 * @param type - NGA 通知类型
 * @returns 是否为私信通知
 */
function isMessageType(type: number): boolean {
  return type === 10 || type === 11
}

/**
 * 判断通知类型是否属于帖子互动。
 *
 * @param type - NGA 通知类型
 * @returns 是否为帖子互动通知
 */
function isReplyType(type: number): boolean {
  return type === 1 || type === 2 || type === 7 || type === 8
}

/**
 * 判断通知时间戳是否可作为稳定记录时间。
 *
 * @param value - 服务端时间戳字符串
 * @returns 是否为正数 UNIX 秒时间戳
 */
function isValidNotificationTimestamp(value: string): boolean {
  const timestamp: number = Number(value)
  return value.length > 0 && Number.isFinite(timestamp) && timestamp > 0
}

/**
 * 判断帖子互动类型是否必须包含新产生的楼层 ID。
 *
 * @param type - NGA 通知类型
 * @returns 是否必须包含 about_id2
 */
function requiresReplyPid(type: number): boolean {
  return isReplyType(type)
}

/**
 * 构造私信通知的稳定标识。
 *
 * @param type - NGA 通知类型
 * @param mid - 私信会话 ID
 * @param timeStamp - 通知时间戳
 * @param userId - 发起用户 ID
 * @returns 稳定通知标识
 */
function messageNotificationId(type: number, mid: string, timeStamp: string, userId: string): string {
  return `message|${type}|${mid}|${timeStamp}|${userId}`
}

/**
 * 构造支持或反对通知的稳定标识。
 *
 * @param type - NGA 通知类型
 * @param tid - 主题 ID
 * @param pid - 楼层 ID
 * @param timeStamp - 通知时间戳
 * @param toUid - 被评价用户 ID
 * @returns 稳定通知标识
 */
function upvoteNotificationId(type: number, tid: string, pid: string, timeStamp: string, toUid: string): string {
  return `upvote|${type}|${tid}|${pid}|${timeStamp}|${toUid}`
}

/**
 * 构造帖子互动通知的稳定标识。
 *
 * @param type - NGA 通知类型
 * @param tid - 主题 ID
 * @param replyPid - 回复楼层 ID
 * @param repliedPid - 被回复楼层 ID
 * @param timeStamp - 通知时间戳
 * @param userId - 发起用户 ID
 * @returns 稳定通知标识
 */
function replyNotificationId(
  type: number,
  tid: string,
  replyPid: string,
  repliedPid: string,
  timeStamp: string,
  userId: string
): string {
  return `reply|${type}|${tid}|${replyPid}|${repliedPid}|${timeStamp}|${userId}`
}

/**
 * 解析官方 notify/list 响应为与网页版同形状的通知列表。
 *
 * 字段映射（实测确认）：about_id=tid（私信为 mid）、about_id2=pid/replyPid、
 * about_id3=repliedPid、about_id4=page、text 作为标题（官方无独立标题字段）、
 * to_uid=被评价用户（点赞）。官方无「被回复用户」字段，repliedId/repliedName 置空
 * （UI 不消费，仅用于诊断）。
 *
 * @param raw - NGA 原始响应
 * @returns 通知解析结果（valid=false 表示业务失败/形状不可识别）
 */
export function parseAppNotifications(raw: object | null): NotificationParseResult {
  const result: NotificationParseResult = {
    valid: false,
    items: [],
    malformedCount: 0,
    unsupportedCount: 0,
    serverUnreadHint: 0,
  }
  if (!raw || typeof raw !== 'object') {
    return result
  }
  if (Array.isArray(raw)) {
    result.valid = raw.length === 0
    return result
  }

  const rawObj: Record<string, Object> = raw as Record<string, Object>
  const code: number = Number(rawObj['code'] ?? 0)
  if (code !== 0) {
    return result
  }
  const res: Object | undefined = rawObj['result']
  if (res === undefined || res === null || typeof res !== 'object' || Array.isArray(res)) {
    // code=0 但 result 缺失：按有效空数据处理（与网页版 data 缺失语义对齐）
    result.valid = true
    return result
  }

  result.valid = true
  const body: Record<string, Object> = res as Record<string, Object>

  // 未读提示：顶层 unread 优先，回退 unread_cnt.unread
  const unreadRaw: number = Number(body['unread'] ?? 0)
  if (Number.isFinite(unreadRaw) && unreadRaw > 0) {
    result.serverUnreadHint = unreadRaw
  } else {
    const unreadCnt: Object | undefined = body['unread_cnt']
    if (unreadCnt !== undefined && unreadCnt !== null &&
      typeof unreadCnt === 'object' && !Array.isArray(unreadCnt)) {
      const innerUnread: number = Number((unreadCnt as Record<string, Object>)['unread'] ?? 0)
      if (Number.isFinite(innerUnread) && innerUnread > 0) {
        result.serverUnreadHint = innerUnread
      }
    }
  }

  const batchKeys: string[] = ['reply', 'msg', 'sys']
  for (let batchIndex: number = 0; batchIndex < batchKeys.length; batchIndex++) {
    const batchValue: Object | undefined = body[batchKeys[batchIndex]]
    if (batchValue === undefined || batchValue === null || !Array.isArray(batchValue)) {
      continue
    }
    const batch: Record<string, Object>[] = batchValue as Record<string, Object>[]
    for (let itemIndex: number = 0; itemIndex < batch.length; itemIndex++) {
      const entry: Record<string, Object> = batch[itemIndex]
      if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
        result.malformedCount++
        continue
      }

      const type: number = Number(entry['type'] ?? 0)
      const timeStamp: string = String(entry['time'] ?? '')
      if (!Number.isFinite(type) || !Number.isInteger(type) ||
        !isValidNotificationTimestamp(timeStamp)) {
        result.malformedCount++
        continue
      }
      const fromUid: string = String(entry['from_uid'] ?? '')
      const fromName: string = String(entry['from_uname'] ?? '')
      const aboutId: string = String(entry['about_id'] ?? '')
      const aboutId2: string = String(entry['about_id2'] ?? '')
      const aboutId3: string = String(entry['about_id3'] ?? '')
      const aboutId4: string = String(entry['about_id4'] ?? '')
      const text: string = String(entry['text'] ?? '')
      const toUid: string = String(entry['to_uid'] ?? '')

      if (isMessageType(type)) {
        if (aboutId.length === 0) {
          result.malformedCount++
          continue
        }
        const notification: MessageNotification = {
          notificationId: messageNotificationId(type, aboutId, timeStamp, fromUid),
          type: type,
          userId: fromUid,
          userName: fromName,
          title: text,
          mid: aboutId,
          timeStamp: timeStamp,
          seen: false,
          serverUnreadHint: result.serverUnreadHint
        }
        result.items.push(notification)
        continue
      }

      if (type === 17) {
        if (aboutId.length === 0 || aboutId2.length === 0) {
          result.malformedCount++
          continue
        }
        const notification: UpvoteNotification = {
          notificationId: upvoteNotificationId(type, aboutId, aboutId2, timeStamp, toUid),
          type: type,
          userId: '',
          userName: '',
          toUid: toUid,
          title: text,
          tid: aboutId,
          pid: aboutId2,
          page: aboutId4,
          timeStamp: timeStamp,
          seen: false,
          serverUnreadHint: result.serverUnreadHint
        }
        result.items.push(notification)
        continue
      }

      if (isReplyType(type)) {
        const missingReplyPid: boolean = requiresReplyPid(type) && aboutId2.length === 0
        if (aboutId.length === 0 || missingReplyPid) {
          result.malformedCount++
          continue
        }
        const notification: ReplyNotification = {
          notificationId: replyNotificationId(type, aboutId, aboutId2, aboutId3, timeStamp, fromUid),
          type: type,
          userId: fromUid,
          userName: fromName,
          repliedId: '',
          repliedName: '',
          title: text,
          tid: aboutId,
          replyPid: aboutId2,
          repliedPid: aboutId3,
          timeStamp: timeStamp,
          page: aboutId4,
          seen: false,
          serverUnreadHint: result.serverUnreadHint
        }
        result.items.push(notification)
        continue
      }

      result.unsupportedCount++
    }
  }

  return result
}
