/**
 * NGA 通知/私信 API
 */

import { ngaClient } from '../NgaClient';
import { appStore } from '../../store/AppStore';
import { parseNotifications } from '../../parser/NotificationParser';
import { parseMessageList, parseMessageDetail } from '../../parser/MessageParser';
import { parseNgaError } from '../../parser/ErrorParser';
import { NotificationsResult } from '../../model/NgaApiResults';
import { MessageListResult, MessageDetailResult, MessageSendResult } from '../../model/MessageResult';
import type { NotificationParseResult } from '../../model/Notification';

/**
 * 判断私信接口响应是否包含解析器要求的数据容器。
 *
 * @param raw - NGA 私信接口原始响应
 * @returns 是否具备 data.data 对象
 */
function hasMessagePayload(raw: object): boolean {
  const record: Record<string, Object> = raw as Record<string, Object>;
  const dataValue: Object | undefined = record['data'];
  if (!dataValue || typeof dataValue !== 'object' || Array.isArray(dataValue)) {
    return false;
  }
  const dataRecord: Record<string, Object> = dataValue as Record<string, Object>;
  const rowsValue: Object | undefined = dataRecord['data'];
  return !!rowsValue && typeof rowsValue === 'object' && !Array.isArray(rowsValue);
}

// ============== 通知 ==============

export async function getNotifications(token: string): Promise<NotificationsResult> {
  const result = new NotificationsResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }
  try {
    const params: Record<string, string> = {
      '__lib': 'noti', '__output': '8', '__act': 'get_all',
    };
    const raw = await ngaClient.get('/nuke.php', params, { uid: session.uid, cid: session.cid });
    const error: string | null = parseNgaError(raw);
    if (error) {
      result.error = error;
      return result;
    }
    const parsed: NotificationParseResult = parseNotifications(raw as object);
    if (!parsed.valid) {
      result.error = '通知数据格式异常';
      return result;
    }
    result.data = parsed.items;
    result.malformedCount = parsed.malformedCount;
    result.unsupportedCount = parsed.unsupportedCount;
    result.serverUnreadHint = parsed.serverUnreadHint;
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '获取通知失败';
  }
  return result;
}

// ============== 私信 ==============

export async function getMessageList(token: string, page: string): Promise<MessageListResult> {
  const result = new MessageListResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }
  try {
    const params: Record<string, string> = {
      '__lib': 'message', '__act': 'message', 'act': 'list', 'page': page || '1', 'lite': 'js',
    };
    const raw = await ngaClient.get('/nuke.php', params, { uid: session.uid, cid: session.cid });
    const error: string | null = parseNgaError(raw);
    if (error) {
      result.error = error;
      return result;
    }
    if (!hasMessagePayload(raw)) {
      result.error = '私信列表数据格式异常';
      return result;
    }
    result.data = parseMessageList(raw as object);
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '获取私信列表失败';
  }
  return result;
}

export async function getMessageDetail(token: string, mid: string, page: string): Promise<MessageDetailResult> {
  const result = new MessageDetailResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }
  try {
    const params: Record<string, string> = {
      '__lib': 'message', '__act': 'message', 'act': 'read', 'page': page || '1', 'mid': mid, 'lite': 'js',
    };
    const raw = await ngaClient.get('/nuke.php', params, { uid: session.uid, cid: session.cid });
    const error: string | null = parseNgaError(raw);
    if (error) {
      result.error = error;
      return result;
    }
    if (!hasMessagePayload(raw)) {
      result.error = '私信详情数据格式异常';
      return result;
    }
    result.data = parseMessageDetail(raw as object);
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '获取私信详情失败';
  }
  return result;
}

export async function sendMessage(token: string, to: string, mid: string,
  subject: string, content: string): Promise<MessageSendResult> {
  const result = new MessageSendResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }
  try {
    if (!content) {
      result.error = '内容不能为空';
      return result;
    }
    const fields: Record<string, string> = {
      '__lib': 'message',
      '__act': 'message',
      'lite': 'js',
      'act': mid ? 'reply' : 'new',
      'content': content,
    };
    if (to) fields['to'] = to;
    if (mid) fields['mid'] = mid;
    if (subject) fields['subject'] = subject;

    const raw = await ngaClient.post('/nuke.php', fields, { uid: session.uid, cid: session.cid }) as Record<string, Object>;
    const error = parseNgaError(raw);
    if (error) {
      result.error = error;
      return result;
    }
    const dataObj = raw?.['data'] as Record<string, Object> | undefined;
    result.mid = String(dataObj?.['mid'] ?? mid ?? '');
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '发送私信失败';
  }
  return result;
}
