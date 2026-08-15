/**
 * NGA 帖子写入 API - 发帖、回帖、贴条、附件上传
 *
 * 与 ThreadApi（读取域：帖子详情、pid 定位、主题分类）分离，
 * 本文件只包含 post.php 写入链与附件上传。
 */

import { ngaClient } from '../NgaClient';
import { ngaUploadFile } from './NgaUploader';
import { appStore } from '../../store/AppStore';
import { parseNgaError } from '../../parser/ErrorParser';
import { PostAuthResult, PostReplyResult } from '../../model/ThreadResult';
import { UploadAttachmentResult } from '../../model/NgaApiResults';
import { Logger, DOMAIN_SERVICE } from '../../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'ThreadWriteApi')

/**
 * 发帖/回复/评论前的鉴权预检。
 *
 * 对应官方客户端 TopicPostModel.getPostInfo：请求 post.php 并解析
 * window.script_muti_get_var_store 前缀的 JSON，返回 auth（附件上传校验码）、
 * 附件上传地址与版主标记。
 *
 * @param token - 会话令牌
 * @param fid - 版块 ID
 * @param action - 操作类型（new/reply/modify 等）
 * @param tid - 主题 ID（回复/编辑场景）
 * @param pid - 楼层 ID（回复/编辑场景）
 * @param comment - 是否贴条（1 表示贴条）
 * @param stid - 子版块 ID（发新主题到子版块时传，0 表示父版块）
 * @returns 鉴权结果；服务端返回错误时 ok 为 false
 */
export async function getPostAuth(token: string, fid: number, action: string,
  tid: number, pid: number, comment: number, stid: number = 0): Promise<PostAuthResult> {
  const result = new PostAuthResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    const authParams: Record<string, string> = {
      'fid': String(fid),
      'lite': 'js',
    };
    if (action) authParams['action'] = action;
    if (pid) authParams['pid'] = String(pid);
    if (tid) authParams['tid'] = String(tid);
    if (comment) authParams['comment'] = String(comment);
    if (stid) authParams['stid'] = String(stid);

    const raw = await ngaClient.postWithQuery('/post.php', authParams, { uid: session.uid, cid: session.cid }) as Record<string, Object>;
    const err = parseNgaError(raw);
    if (err) {
      result.error = err;
      return result;
    }
    const dataObj = raw?.['data'] as Record<string, Object> | undefined;
    result.auth = String(dataObj?.['auth'] ?? '');
    result.attachUrl = String(dataObj?.['attach_url'] ?? '');
    result.if_moderator = Number(dataObj?.['if_moderator'] ?? 0);
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '获取auth失败';
  }
  return result;
}

export async function postReply(token: string, tid: number, fid: number,
  content: string, anony: number, attachments: string, attachmentsCheck: string,
  stid: number, action: string, pid: number, postSubject: string): Promise<PostReplyResult> {
  const result = new PostReplyResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    const fields: Record<string, string> = {
      'step': '2',
      'action': action || 'reply',
      'fid': String(fid),
      'post_content': content,
      'anony': String(anony),
      '__output': '8',
    };
    // 与官方协议一致：无附件时不携带 attachments 字段，否则服务端会进入附件确认校验并报错
    if (attachments) {
      fields['attachments'] = attachments;
      fields['attachments_check'] = attachmentsCheck;
    }
    if (tid) fields['tid'] = String(tid);
    if (pid) fields['pid'] = String(pid);
    if (postSubject) fields['post_subject'] = postSubject;
    if (stid) fields['stid'] = String(stid);

    const raw = await ngaClient.post('/post.php', fields,
      { uid: session.uid, cid: session.cid }, ['post_content', 'post_subject']) as Record<string, Object>;
    const error = parseNgaError(raw);
    if (error) {
      result.error = error;
      return result;
    }
    const dataObj = raw?.['data'] as Record<string, Object> | undefined;
    result.tid = Number(dataObj?.['tid'] ?? tid ?? 0);
    result.pid = String(dataObj?.['pid'] ?? '');
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '回复失败';
  }
  return result;
}

/**
 * 发布新主题。
 *
 * 对应官方客户端 TopicPostTask + PostParam.toString()：POST post.php，
 * action=new、step=2；post_subject 与 post_content 走 GBK 百分号编码。
 * 响应带 __output=8 时为 JSON，data.tid 为新主题 ID。
 *
 * @param token - 会话令牌
 * @param fid - 版块 ID
 * @param stid - 子版块 ID（0 表示发在父版块）
 * @param subject - 标题
 * @param content - 正文（BBCode）
 * @param anony - 是否匿名（1 表示匿名）
 * @param attachments - 附件参数（tab 分隔）
 * @param attachmentsCheck - 附件校验参数（tab 分隔）
 * @returns 提交结果；成功时 tid 为新主题 ID
 */
export async function postNewTopic(token: string, fid: number, stid: number,
  subject: string, content: string, anony: number, attachments: string,
  attachmentsCheck: string): Promise<PostReplyResult> {
  const result = new PostReplyResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    const fields: Record<string, string> = {
      'step': '2',
      'action': 'new',
      'fid': String(fid),
      'post_subject': subject,
      'post_content': content,
      'anony': String(anony),
      '__output': '8',
    };
    // 与官方协议一致：无附件时不携带 attachments 字段，否则服务端会进入附件确认校验并报错
    if (attachments) {
      fields['attachments'] = attachments;
      fields['attachments_check'] = attachmentsCheck;
    }
    if (stid) fields['stid'] = String(stid);

    const raw = await ngaClient.post('/post.php', fields,
      { uid: session.uid, cid: session.cid }, ['post_content', 'post_subject']) as Record<string, Object>;
    const error = parseNgaError(raw);
    if (error) {
      result.error = error;
      return result;
    }
    const dataObj = raw?.['data'] as Record<string, Object> | undefined;
    result.tid = Number(dataObj?.['tid'] ?? 0);
    result.pid = String(dataObj?.['pid'] ?? '');
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '发帖失败';
  }
  return result;
}

export async function postComment(token: string, tid: number, pid: number,
  fid: number, content: string, anony: number): Promise<PostReplyResult> {
  const result = new PostReplyResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    const fields: Record<string, string> = {
      'step': '2',
      'action': 'reply',
      'comment': '1',
      'lite': 'htmljs',
      'nojump': '1',
      'fid': String(fid),
      'tid': String(tid),
      'pid': String(pid),
      'post_content': content,
      'anony': String(anony),
      '__output': '8',
    };

    const raw = await ngaClient.post('/post.php', fields,
      { uid: session.uid, cid: session.cid }, ['post_content']) as Record<string, Object>;
    const error = parseNgaError(raw);
    if (error) {
      result.error = error;
      return result;
    }
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '评论失败';
  }
  return result;
}

// ============== 附件上传 ==============

export async function uploadAttachment(token: string, auth: string,
  fid: number, imageData: ArrayBuffer, fileName: string): Promise<UploadAttachmentResult> {
  const result = new UploadAttachmentResult()
  const session = appStore.getSession(token)
  if (!session) {
    result.error = '未登录'
    return result
  }

  try {
    const rawText: string = await ngaUploadFile(imageData, fileName, auth, fid, {
      uid: session.uid,
      cid: session.cid,
    })
    const cleaned: string = rawText.replace('window.script_muti_get_var_store=', '').trim()
    logger.verbose('[NGA][UPLOAD] raw: %{public}s', rawText.slice(0, 300))
    logger.verbose('[NGA][UPLOAD] cleaned: %{public}s', cleaned.slice(0, 300))
    // NGA 上传接口返回 JS 对象字面量（单引号+无引号属性名），转成严格 JSON
    const jsonStr: string = cleaned
      .replace(/'/g, '"')
      .replace(/([{,]\s*)([a-zA-Z_$][\w$]*)(\s*:)/g, '$1"$2"$3')
    let parsed: Record<string, Object>
    try {
      parsed = JSON.parse(jsonStr) as Record<string, Object>
    } catch (parseErr) {
      result.error = '上传响应解析失败: ' + (parseErr as Error).message
      return result
    }
    // 检查服务端错误码（对应 Java error_code == 9 附件过大）
    const errorCode: number = Number(parsed['error_code'] ?? 0)
    if (errorCode !== 0) {
      result.error = '上传被拒绝 (错误码 ' + String(errorCode) + ')。若图片过大请压缩后再试'
      return result
    }
    const dataObj = parsed['data'] as Record<string, Object> | undefined
    if (!dataObj) {
      result.error = '上传响应缺少 data'
      return result
    }
    const attachUrl: string = String(dataObj['attach_url'] ?? '')
    const attachment: string = String(dataObj['attachment'] ?? '')
    result.url = String(dataObj['url'] ?? attachUrl + attachment)
    result.attachments = String(dataObj['attachments'] ?? '')
    result.attachmentsCheck = String(dataObj['attachments_check'] ?? '')
    result.ok = true
  } catch (e) {
    result.error = (e as Error).message ?? '上传失败'
  }
  return result
}
