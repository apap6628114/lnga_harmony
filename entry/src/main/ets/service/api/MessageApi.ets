/**
 * NGA 通知/私信 API
 */

import { ngaClient } from '../NgaClient';
import { appStore } from '../../store/AppStore';
import { parseNotifications } from '../../parser/NotificationParser';
import { parseMessageList, parseMessageDetail } from '../../parser/MessageParser';
import { parseNgaError } from '../../parser/ErrorParser';
import { ApiResult, NotificationsResult } from '../../model/NgaApiResults';
import { MessageListResult, MessageDetailResult, MessageSendResult } from '../../model/MessageResult';
import type { NotificationParseResult } from '../../model/Notification';

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

export async function clearNotifications(token: string): Promise<ApiResult> {
  const result = new ApiResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }
  try {
    const fields: Record<string, string> = { '__lib': 'noti', 'raw': '3', '__act': 'del' };
    await ngaClient.post('/nuke.php', fields, { uid: session.uid, cid: session.cid });
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '清除通知失败';
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
