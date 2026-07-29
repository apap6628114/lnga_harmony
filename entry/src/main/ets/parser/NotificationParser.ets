import type {
  NgaNotification,
  NotificationParseResult,
  ReplyNotification,
  MessageNotification,
  UpvoteNotification
} from '../model/Notification';

/**
 * 判断通知类型是否属于私信。
 *
 * @param type - NGA 通知类型
 * @returns 是否为私信通知
 */
function isMessageType(type: number): boolean {
  return type === 10 || type === 11;
}

/**
 * 判断通知类型是否属于帖子互动。
 *
 * @param type - NGA 通知类型
 * @returns 是否为帖子互动通知
 */
function isReplyType(type: number): boolean {
  return type === 1 || type === 2 || type === 7 || type === 8;
}

/**
 * 判断通知时间戳是否可作为稳定记录时间。
 *
 * @param value - 服务端时间戳字符串
 * @returns 是否为正数 UNIX 秒时间戳
 */
function isValidNotificationTimestamp(value: string): boolean {
  const timestamp: number = Number(value);
  return value.length > 0 && Number.isFinite(timestamp) && timestamp > 0;
}

/**
 * 判断帖子互动类型是否必须包含新产生的楼层 ID。
 *
 * @param type - NGA 通知类型
 * @returns 是否必须包含字段 7
 */
function requiresReplyPid(type: number): boolean {
  return isReplyType(type);
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
  return `message|${type}|${mid}|${timeStamp}|${userId}`;
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
  return `upvote|${type}|${tid}|${pid}|${timeStamp}|${toUid}`;
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
  return `reply|${type}|${tid}|${replyPid}|${repliedPid}|${timeStamp}|${userId}`;
}

/**
 * 解析 NGA 通知响应，并保留结构有效性信息。
 *
 * NGA 通知接口使用非稳定的遗留数据结构，空通知可能表现为缺失值、空字符串或非数组容器。
 * 这里遵循 MNGA 的固定路径投影策略，仅读取 `data/0/0`、`data/0/1`、`data/0/2`：
 * 已知批次缺失或不是数组时按无数据处理，避免服务端新增元数据导致整个通知列表失败；
 * 进入已知数组后仍严格校验每条记录，损坏记录计入异常数量且不会进入业务模型。
 *
 * @param raw - NGA 原始响应
 * @returns 通知解析结果
 */
export function parseNotifications(raw: object | null): NotificationParseResult {
  const result: NotificationParseResult = {
    valid: false,
    items: [],
    malformedCount: 0,
    unsupportedCount: 0,
    serverUnreadHint: 0
  };
  if (!raw || typeof raw !== 'object') {
    return result;
  }
  if (Array.isArray(raw)) {
    result.valid = raw.length === 0;
    return result;
  }

  const rawObj: Record<string, Object> = raw as Record<string, Object>;
  const rawData: Object | undefined = rawObj['data'];
  if (rawData === undefined || rawData === null) {
    result.valid = true;
    return result;
  }
  if (typeof rawData !== 'object') {
    return result;
  }

  result.valid = true;
  const data: Record<string, Object> = rawData as Record<string, Object>;
  const groupValue: Object | undefined = data['0'];
  if (!groupValue || typeof groupValue !== 'object' || Array.isArray(groupValue)) {
    return result;
  }

  const group: Record<string, Object> = groupValue as Record<string, Object>;
  const serverUnreadHint: number = Number(group['unread'] ?? 0);
  if (Number.isFinite(serverUnreadHint) && serverUnreadHint > 0) {
    result.serverUnreadHint = serverUnreadHint;
  }

  const batchKeys: string[] = ['0', '1', '2'];
  for (let batchIndex: number = 0; batchIndex < batchKeys.length; batchIndex++) {
    const batchValue: Object | undefined = group[batchKeys[batchIndex]];
    if (!Array.isArray(batchValue)) {
      continue;
    }

    const batch: Record<string, Object>[] = batchValue as Record<string, Object>[];
    for (let itemIndex: number = 0; itemIndex < batch.length; itemIndex++) {
      const entry: Record<string, Object> = batch[itemIndex];
      if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
        result.malformedCount++;
        continue;
      }

      const type: number = Number(entry['0'] ?? 0);
      const userId: string = String(entry['1'] ?? '');
      const userName: string = String(entry['2'] ?? '');
      const timeStamp: string = String(entry['9'] ?? '');
      if (!Number.isFinite(type) || !Number.isInteger(type) ||
        !isValidNotificationTimestamp(timeStamp)) {
        result.malformedCount++;
        continue;
      }

      if (isMessageType(type)) {
        const mid: string = String(entry['6'] ?? '');
        if (mid.length === 0) {
          result.malformedCount++;
          continue;
        }
        const notification: MessageNotification = {
          notificationId: messageNotificationId(type, mid, timeStamp, userId),
          type: type,
          userId: userId,
          userName: userName,
          title: '',
          mid: mid,
          timeStamp: timeStamp,
          seen: false,
          serverUnreadHint: serverUnreadHint
        };
        result.items.push(notification);
        continue;
      }

      if (type === 17) {
        const toUid: string = String(entry['3'] ?? '');
        const tid: string = String(entry['6'] ?? '');
        const pid: string = String(entry['7'] ?? '');
        const page: string = String(entry['10'] ?? '');
        if (tid.length === 0 || pid.length === 0) {
          result.malformedCount++;
          continue;
        }
        const notification: UpvoteNotification = {
          notificationId: upvoteNotificationId(type, tid, pid, timeStamp, toUid),
          type: type,
          userId: '',
          userName: '',
          toUid: toUid,
          title: String(entry['5'] ?? ''),
          tid: tid,
          pid: pid,
          page: page,
          timeStamp: timeStamp,
          seen: false,
          serverUnreadHint: serverUnreadHint
        };
        result.items.push(notification);
        continue;
      }

      if (isReplyType(type)) {
        const tid: string = String(entry['6'] ?? '');
        const replyPid: string = String(entry['7'] ?? '');
        const repliedPid: string = String(entry['8'] ?? '');
        const missingReplyPid: boolean = requiresReplyPid(type) && replyPid.length === 0;
        if (tid.length === 0 || missingReplyPid) {
          result.malformedCount++;
          continue;
        }
        const notification: ReplyNotification = {
          notificationId: replyNotificationId(type, tid, replyPid, repliedPid, timeStamp, userId),
          type: type,
          userId: userId,
          userName: userName,
          repliedId: String(entry['3'] ?? ''),
          repliedName: String(entry['4'] ?? ''),
          title: String(entry['5'] ?? ''),
          tid: tid,
          replyPid: replyPid,
          repliedPid: repliedPid,
          timeStamp: timeStamp,
          page: String(entry['10'] ?? ''),
          seen: false,
          serverUnreadHint: serverUnreadHint
        };
        result.items.push(notification);
        continue;
      }

      result.unsupportedCount++;
    }
  }

  return result;
}
