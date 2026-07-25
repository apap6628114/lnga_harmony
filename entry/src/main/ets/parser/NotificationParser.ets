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
  return type === 10 || type === 11 || type === 12;
}

/**
 * 判断通知类型是否属于帖子互动。
 *
 * @param type - NGA 通知类型
 * @returns 是否为帖子互动通知
 */
function isReplyType(type: number): boolean {
  return type === 1 || type === 2 || type === 3 || type === 4 ||
    type === 7 || type === 8 || type === 15;
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
  const categoryKeys: string[] = Object.keys(data);
  for (let categoryIndex: number = 0; categoryIndex < categoryKeys.length; categoryIndex++) {
    const groupValue: Object = data[categoryKeys[categoryIndex]];
    if (!groupValue || typeof groupValue !== 'object' || Array.isArray(groupValue)) {
      result.malformedCount++;
      continue;
    }

    const group: Record<string, Object> = groupValue as Record<string, Object>;
    const serverUnreadHint: number = Number(group['unread'] ?? 0);
    if (Number.isFinite(serverUnreadHint) && serverUnreadHint > 0) {
      result.serverUnreadHint += serverUnreadHint;
    }

    const batchKeys: string[] = Object.keys(group);
    for (let batchIndex: number = 0; batchIndex < batchKeys.length; batchIndex++) {
      const batchKey: string = batchKeys[batchIndex];
      if (batchKey === 'unread' || batchKey === 'lasttime') {
        continue;
      }

      const batchValue: Object = group[batchKey];
      if (!Array.isArray(batchValue)) {
        result.malformedCount++;
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

        if (isMessageType(type)) {
          const mid: string = String(entry['6'] ?? '');
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
          const notification: UpvoteNotification = {
            notificationId: upvoteNotificationId(type, tid, pid, timeStamp, toUid),
            type: type,
            userId: '',
            userName: '',
            toUid: toUid,
            title: String(entry['5'] ?? ''),
            tid: tid,
            pid: pid,
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
  }

  return result;
}
