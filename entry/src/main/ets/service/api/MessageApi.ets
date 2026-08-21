/**
 * NGA 通知/私信 API
 */

import { ngaClient, Cookies } from '../NgaClient';
import { appStore } from '../../store/AppStore';
import { parseAppNotifications } from '../../parser/AppNotificationParser';
import {
  parseAppMessageList,
  parseAppMessageDetail,
  extractAppMessageError,
} from '../../parser/AppMessageParser';
import { makeClientChecksum } from '../../common/security/NgaSigner';
import { NotificationsResult } from '../../model/NgaApiResults';
import { MessageListResult, MessageDetailResult, MessageSendResult } from '../../model/MessageResult';
import type { NotificationParseResult } from '../../model/Notification';
import { Logger, DOMAIN_SERVICE, formatError } from '../../common/utils/Logger';

const logger = new Logger(DOMAIN_SERVICE, 'MessageApi')

/**
 * 计算字符串的 UTF-8 字节长度（官方私信标题校验单位）。
 *
 * @param text - 输入文本
 * @returns UTF-8 字节数
 */
function utf8ByteLength(text: string): number {
  let bytes: number = 0
  for (let i = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i)
    if (code <= 0x7f) {
      bytes += 1
    } else if (code <= 0x7ff) {
      bytes += 2
    } else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
      const low: number = text.charCodeAt(i + 1)
      if (low >= 0xdc00 && low <= 0xdfff) {
        bytes += 4
        i++
      } else {
        bytes += 3
      }
    } else {
      bytes += 3
    }
  }
  return bytes
}

// ============== 通知 ==============

/**
 * 获取通知列表（通知中心「消息」列表）。
 *
 * 仅走官方 APP 签名接口（app_api.php?__lib=notify&__act=list，POST form，
 * 带 __ngaClientChecksum，__output=14）；nuke.php 网页版通道（__lib=noti&
 * __act=get_all）已随本次迁移移除，不再降级。
 *
 * time_limit=0：全量拉取（通知中心为本地全量去重模型，与网页版语义一致；
 * 官方 App 的增量时间范围语义不适配鸿蒙端轮询模型）。
 *
 * @param token - 当前应用会话令牌
 * @returns 通知列表
 */
export async function getNotifications(token: string): Promise<NotificationsResult> {
  const result = new NotificationsResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }
  try {
    const ts: string = String(Math.floor(Date.now() / 1000));
    const cookies: Cookies = { uid: session.uid, cid: session.cid };
    const params: Record<string, string> = {
      '__ngaClientChecksum': makeClientChecksum({ uid: session.uid, ts: ts }),
      'time_limit': '0',
      'get': '111',
    };
    const raw = await ngaClient.postSigned('/app_api.php', 'notify', 'list',
      params, cookies, '', '14') as Record<string, Object>;
    const error: string | null = extractAppMessageError(raw);
    if (error) {
      result.error = error;
      return result;
    }
    const parsed: NotificationParseResult = parseAppNotifications(raw as object);
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
    logger.warn('获取通知失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '获取通知失败';
  }
  return result;
}

// ============== 私信 ==============

/**
 * 获取私信会话列表（消息页）。
 *
 * 仅走官方 APP 签名接口（app_api.php?__lib=message&__act=list，POST form + sign，
 * __output=12，signParams 为空）；nuke.php 网页版通道（message/message&act=list）
 * 已随本次迁移移除，不再降级——官方接口是唯一通道，失败即返回错误。
 *
 * @param token - 当前应用会话令牌
 * @param page - 页码（1 基）
 * @returns 私信会话列表
 */
export async function getMessageList(token: string, page: string): Promise<MessageListResult> {
  const result = new MessageListResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }
  try {
    const cookies: Cookies = { uid: session.uid, cid: session.cid };
    const params: Record<string, string> = { 'page': page || '1' };
    const raw = await ngaClient.postSigned('/app_api.php', 'message', 'list',
      params, cookies, '', '12') as Record<string, Object>;
    const error: string | null = extractAppMessageError(raw);
    if (error) {
      result.error = error;
      return result;
    }
    const info = parseAppMessageList(raw, Number(page || '1') || 1);
    if (info === null) {
      result.error = '私信列表数据格式异常';
      return result;
    }
    result.data = info;
    result.ok = true;
  } catch (e) {
    logger.warn('获取私信列表失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '获取私信列表失败';
  }
  return result;
}

/**
 * 获取会话内消息列表（私信详情）。
 *
 * 仅走官方 APP 签名接口（app_api.php?__lib=message&__act=detail，POST form + sign，
 * __output=12，signParams=did）；网页版通道（message/message&act=read）已移除。
 *
 * @param token - 当前应用会话令牌
 * @param mid - 会话 ID（did）
 * @param page - 页码（1 基）
 * @returns 会话内消息列表
 */
export async function getMessageDetail(token: string, mid: string, page: string): Promise<MessageDetailResult> {
  const result = new MessageDetailResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }
  try {
    const cookies: Cookies = { uid: session.uid, cid: session.cid };
    const params: Record<string, string> = { 'did': mid, 'page': page || '1' };
    const raw = await ngaClient.postSigned('/app_api.php', 'message', 'detail',
      params, cookies, mid, '12') as Record<string, Object>;
    const error: string | null = extractAppMessageError(raw);
    if (error) {
      result.error = error;
      return result;
    }
    const info = parseAppMessageDetail(raw, Number(page || '1') || 1);
    if (info === null) {
      result.error = '私信详情数据格式异常';
      return result;
    }
    result.data = info;
    result.ok = true;
  } catch (e) {
    logger.warn('获取私信详情失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '获取私信详情失败';
  }
  return result;
}

/**
 * 发送新私信或回复会话。
 *
 * 仅走官方 APP 签名接口（app_api.php?__lib=message&__act=send|reply，POST form +
 * sign）；网页版通道（nuke.php message/message&act=new|reply）已随本次迁移移除。
 *
 * 官方协议（nga-hack 卡片 7/8，已实测接口入口与签名有效性）：
 * - 新私信 send：subject/content/to + __inchst 空串，__output=12，
 *   signParams 按序 = subject + content + to
 * - 回复 reply：subject/content/did + __inchst 空串，__output=14，
 *   signParams 按序 = subject + content + did
 * 注意：官方接口对标题有长度校验（10~200 byte），过短/过长由服务端返回错误透出。
 *
 * @param token - 当前应用会话令牌
 * @param to - 收件人用户名（新私信必填；回复时忽略）
 * @param mid - 会话 ID（回复时必填；为空表示新私信）
 * @param subject - 标题
 * @param content - 正文
 * @returns 发送结果（成功时尝试回填会话 ID）
 */
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
    const isReply: boolean = mid.length > 0;
    const cookies: Cookies = { uid: session.uid, cid: session.cid };
    const params: Record<string, string> = {
      '__inchst': '',
      'subject': subject,
      'content': content,
    };
    let signParams: string;
    let output: string;
    if (isReply) {
      params['did'] = mid;
      signParams = subject + content + mid;
      output = '14';
    } else {
      if (!to) {
        result.error = '收件人不能为空';
        return result;
      }
      // 官方 send 对标题有 10~200 byte（UTF-8）服务端校验，这里前置预检
      // 即时提示，避免无效请求往返（回复分支标题来自会话标题，不做预检、
      // 由服务端校验结果透出）
      const subjectBytes: number = utf8ByteLength(subject)
      if (subjectBytes < 10 || subjectBytes > 200) {
        result.error = '标题长度需在 10~200 字节之间';
        return result;
      }
      params['to'] = to;
      signParams = subject + content + to;
      output = '12';
    }

    const raw = await ngaClient.postSigned('/app_api.php', 'message',
      isReply ? 'reply' : 'send', params, cookies, signParams, output) as Record<string, Object>;
    const error = extractAppMessageError(raw);
    if (error) {
      result.error = error;
      return result;
    }
    // 成功：尝试从响应 result 回填会话 ID（服务端可能返回 did/mid；取不到保持调用方传入值）
    const res: Object | undefined = raw['result'];
    if (res !== undefined && res !== null && typeof res === 'object' && !Array.isArray(res)) {
      const resRec: Record<string, Object> = res as Record<string, Object>;
      result.mid = String(resRec['did'] ?? resRec['mid'] ?? mid ?? '');
    } else {
      result.mid = mid ?? '';
    }
    result.ok = true;
  } catch (e) {
    logger.warn('发送私信失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '发送私信失败';
  }
  return result;
}
