/**
 * NGA 帖子写入 API。
 *
 * 发帖编辑器的鉴权与提交全部对齐官方 APP 的 app_api.php post 接口，
 * 附件上传使用 post/check 返回的 attach_url 和官方 multipart 字段。
 */

import { ngaClient } from '../NgaClient';
import { ngaUploadFile } from './NgaUploader';
import { appStore } from '../../store/AppStore';
import { parseNgaError } from '../../parser/ErrorParser';
import { PostAuthResult, PostReplyResult } from '../../model/ThreadResult';
import { UploadAttachmentResult } from '../../model/NgaApiResults';
import { Logger, DOMAIN_SERVICE } from '../../common/utils/Logger';
import { emojiToHtmlEntity } from '../../common/utils/CodecUtils';

const logger = new Logger(DOMAIN_SERVICE, 'ThreadWriteApi');

/**
 * 将未知协议载荷收窄为对象映射。
 * @param value - 待收窄值
 * @returns 对象映射或未定义
 */
function asRecord(value: Object | undefined): Record<string, Object> | undefined {
  if (value !== undefined && typeof value === 'object') {
    return value as Record<string, Object>;
  }
  return undefined;
}

/**
 * 提取官方帖子接口的 result/data 载荷。
 * @param raw - 官方接口原始对象
 * @returns 业务载荷
 */
function readPostPayload(raw: Record<string, Object>): Record<string, Object> {
  const resultPayload: Record<string, Object> | undefined = asRecord(raw['result']);
  if (resultPayload) {
    return resultPayload;
  }
  const dataPayload: Record<string, Object> | undefined = asRecord(raw['data']);
  if (dataPayload) {
    return dataPayload;
  }
  return raw;
}

/**
 * 解析官方 APP 与旧网页接口共用的错误结构。
 * @param raw - 接口原始对象
 * @param fallback - 无消息时的兜底文案
 * @returns 错误消息或空值
 */
function readAppError(raw: Record<string, Object>, fallback: string): string | null {
  const codeValue: Object | undefined = raw['code'];
  if (codeValue !== undefined) {
    const code: number = Number(codeValue);
    if (code !== 0) {
      const message: string = String(raw['msg'] ?? raw['message'] ?? '');
      return message.length > 0 ? message : fallback + '（错误码 ' + String(code) + '）';
    }
    return null;
  }
  return parseNgaError(raw) ?? (raw['__parseError'] ? fallback : null);
}

/**
 * 提取异步请求异常的用户可读消息。
 * @param error - 请求异常
 * @param fallback - 兜底文案
 * @returns 错误消息
 */
function readThrownError(error: Error, fallback: string): string {
  if (error.message.length > 0) {
    return error.message;
  }
  return fallback;
}

/**
 * 还原官方发帖器对本次新输入执行的正文格式化。
 *
 * 官方 APK 对新输入只把 `&nbsp;` 转为空格，并把 Unicode 表情转为数字实体；
 * 旧正文的 HTML 实体解码由编辑器载入阶段完成，不能在这里重复反解用户输入。
 * @param content - 编辑器正文
 * @returns 官方提交格式正文
 */
function normalizePostContent(content: string): string {
  const normalized: string = content.replace(/&nbsp;/g, ' ');
  return emojiToHtmlEntity(normalized);
}

/**
 * 提取官方发帖器使用的 @ 提及字段。
 * @param content - 用户本次提交的正文
 * @returns 以制表符分隔的提及用户名
 */
function extractMentionField(content: string): string {
  const matcher: RegExp = /\[@(.*?)\]/gi;
  const mentions: string[] = [];
  let matched: RegExpExecArray | null = matcher.exec(content);
  while (matched !== null) {
    if (matched.length > 1) {
      mentions.push(matched[1]);
    }
    matched = matcher.exec(content);
  }
  return mentions.length > 0 ? mentions.join('\t') + '\t' : '';
}

/**
 * 格式化官方发帖协议中的可选 ID。
 * @param value - 数值 ID
 * @returns 正数 ID 或空串
 */
function formatOptionalId(value: number): string {
  return value > 0 ? String(value) : '';
}

/**
 * 从官方上传 JS 对象中提取字符串字段。
 * @param text - JS 对象文本
 * @param field - 字段名
 * @returns 字段值
 */
function extractJsField(text: string, field: string): string {
  const markers: string[] = [field + ":'", field + ':"'];
  for (let i = 0; i < markers.length; i++) {
    const marker: string = markers[i];
    const start: number = text.indexOf(marker);
    if (start < 0) {
      continue;
    }
    const valueStart: number = start + marker.length;
    const quote: string = marker.charAt(marker.length - 1);
    const valueEnd: number = text.indexOf(quote, valueStart);
    if (valueEnd >= 0) {
      return text.substring(valueStart, valueEnd);
    }
  }
  return '';
}

/**
 * 从官方上传 JS 对象中提取数字字段。
 * @param text - JS 对象文本
 * @param field - 字段名
 * @returns 字段值
 */
function extractJsNumber(text: string, field: string): number {
  const pattern: RegExp = new RegExp(field + '\\s*:\\s*(-?\\d+)');
  const matched: RegExpMatchArray | null = text.match(pattern);
  if (matched && matched.length > 1) {
    return Number(matched[1]);
  }
  return Number(extractJsField(text, field));
}

/**
 * 尝试解析 JSON 形式的上传响应。
 * @param text - 响应文本
 * @returns JSON 对象或未定义
 */
function parseUploadJson(text: string): Record<string, Object> | undefined {
  try {
    const parsed: Object = JSON.parse(text) as Object;
    return asRecord(parsed);
  } catch (error) {
    return undefined;
  }
}

/**
 * 兼容官方上传接口的 JSON 与 JS 对象字面量响应。
 * @param text - 响应文本
 * @returns 上传载荷
 */
function readUploadPayload(text: string): Record<string, Object> {
  const jsonPayload: Record<string, Object> | undefined = parseUploadJson(text);
  if (jsonPayload) {
    const dataPayload: Record<string, Object> | undefined = asRecord(jsonPayload['data']);
    return dataPayload ?? jsonPayload;
  }
  const result: Record<string, Object> = {};
  result['error_code'] = extractJsNumber(text, 'error_code') as Object;
  result['error'] = extractJsField(text, 'error') as Object;
  result['attachments'] = extractJsField(text, 'attachments') as Object;
  result['attachments_check'] = extractJsField(text, 'attachments_check') as Object;
  result['url'] = extractJsField(text, 'url') as Object;
  result['attachment'] = extractJsField(text, 'attachment') as Object;
  result['attach_url'] = extractJsField(text, 'attach_url') as Object;
  return result;
}

/**
 * 构造官方帖子提交字段。
 * @param fid - 版块 ID
 * @param tid - 主题 ID
 * @param pid - 目标楼层 ID
 * @param stid - 子版块 ID
 * @param action - 官方提交 action
 * @param content - 正文
 * @param subject - 标题
 * @param anony - 是否匿名
 * @param attachments - 附件参数
 * @param attachmentsCheck - 附件校验参数
 * @returns 提交字段
 */
function buildPostFields(fid: number, tid: number, pid: number, stid: number,
  action: string, content: string, subject: string, anony: number,
  attachments: string, attachmentsCheck: string): Record<string, string> {
  const fields: Record<string, string> = {
    'fid': String(fid),
    'tid': formatOptionalId(tid),
    'pid': formatOptionalId(pid),
    'stid': formatOptionalId(stid),
    'action': action,
    'content': content,
    'anony': String(anony),
    'live': '0',
    'mention': extractMentionField(content),
    'attachments': attachments,
    'attachments_check': attachmentsCheck,
  };
  if (action !== 'tietiao') {
    fields['subject'] = subject;
    fields['address'] = '';
  }
  return fields;
}

/**
 * 发送官方帖子提交请求并解析通用结果。
 * @param token - 会话令牌
 * @param action - 官方提交 action
 * @param fields - 提交字段
 * @param signParams - 签名参数串
 * @param fallbackTid - 未返回主题 ID 时的兜底值
 * @param fallbackError - 失败兜底文案
 * @returns 提交结果
 */
async function submitPost(token: string, action: string, fields: Record<string, string>,
  signParams: string, fallbackTid: number, fallbackError: string): Promise<PostReplyResult> {
  const result = new PostReplyResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    // 官方 post 提交（发帖/回复/贴条/修改）使用 __output="" + __inchst="" 通道：
    // 服务端对 __output=14 的提交按非 UTF-8（GBK 系）解析 content，UTF-8 中文会被
    // 判为「内容过短或过长(6~65530 byte)」（code 153，实测）；__output 为空时按
    // UTF-8 解析，中文正文正确落库（与官方 ArticleRepository.comment 通道一致）。
    // __ngaClientChecksum 为官方发帖提交必带（缺失时服务端返回 code 15 找不到帖子）。
    const raw: Record<string, Object> = await ngaClient.postSigned(
      '/app_api.php', 'post', action, fields,
      { uid: session.uid, cid: session.cid }, signParams, '', true, ''
    ) as Record<string, Object>;
    const error: string | null = readAppError(raw, fallbackError);
    if (error) {
      result.error = error;
      return result;
    }
    const payload: Record<string, Object> = readPostPayload(raw);
    result.tid = Number(payload['tid'] ?? payload['topic_id'] ?? fallbackTid);
    result.pid = String(payload['pid'] ?? payload['post_id'] ?? '');
    result.ok = true;
  } catch (error) {
    result.error = readThrownError(error, fallbackError);
  }
  return result;
}

/**
 * 发送官方新版主题级回复接口。
 *
 * `ArticleRepository.comment` 只提交 tid、content、action，并显式保留空的
 * `__output/__inchst`；该路径用于没有目标楼层且没有附件的普通回复。
 * @param token - 会话令牌
 * @param tid - 主题 ID
 * @param content - 已按官方规则格式化的正文
 * @returns 提交结果
 */
async function submitSimpleReply(token: string, tid: number,
  content: string): Promise<PostReplyResult> {
  const result = new PostReplyResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    const params: Record<string, string> = {
      'tid': String(tid),
      'content': content,
      'action': 'reply',
    };
    const raw: Record<string, Object> = await ngaClient.postSigned(
      '/app_api.php', 'post', 'reply', params,
      { uid: session.uid, cid: session.cid }, String(tid) + content, '', false, ''
    ) as Record<string, Object>;
    const error: string | null = readAppError(raw, '回复失败');
    if (error) {
      result.error = error;
      return result;
    }
    const payload: Record<string, Object> = readPostPayload(raw);
    result.tid = Number(payload['tid'] ?? payload['topic_id'] ?? tid);
    result.pid = String(payload['pid'] ?? payload['post_id'] ?? '');
    result.ok = true;
  } catch (error) {
    result.error = readThrownError(error, '回复失败');
  }
  return result;
}

/**
 * 解析 post/check 返回的附件数组字段（attachArray/attachCheckArray）。
 *
 * 官方 ActionCheck 中该字段为 JSON 数组串（如 `"[\"a1\",\"a2\"]"`），个别响应
 * 也可能直接是数组；元素即附件提交参数值（与上传响应 attachments 字段同格式）。
 * 返回串按官方 L0 拼接语义带尾 `\t`（"a1\ta2\t"），供编辑提交/后续累积直接使用。
 *
 * @param value - 原始字段值
 * @returns tab 拼接的附件参数（无附件时为空串）
 */
function parseAttachArrayValue(value: Object | undefined): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (Array.isArray(value)) {
    const joined: string = (value as Object[]).join('\t');
    return joined.length > 0 ? joined + '\t' : '';
  }
  if (typeof value === 'string') {
    const text: string = value as string;
    if (text.length === 0) {
      return '';
    }
    try {
      const parsed: Object = JSON.parse(text) as Object;
      if (Array.isArray(parsed)) {
        const joined: string = (parsed as Object[]).join('\t');
        return joined.length > 0 ? joined + '\t' : '';
      }
    } catch (error) {
      // 非 JSON 串（服务端形态差异）：按单值透传
      return text;
    }
  }
  return '';
}

/**
 * 获取发帖、回帖、贴条或编辑前的官方 APP 鉴权信息。
 *
 * @param token - 会话令牌
 * @param fid - 版块 ID
 * @param action - `new`、`reply`、`quote`、`modify` 或 `tietiao`
 * @param tid - 主题 ID
 * @param pid - 目标楼层 ID
 * @param comment - 保留兼容参数，官方 action 由调用方直接传入
 * @param stid - 子版块 ID
 * @returns 鉴权结果
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
    const normalizedAction: string = action.length > 0 ? action : (comment === 1 ? 'tietiao' : 'reply');
    // 参数形态对齐官方 post/check：fid/stid/tid/pid/action 恒传（空值传空串，
    // 对应 kt.c.F0 的 b("stid").b("tid").b("pid") 与 ArticleRepository.getPost 五参数）。
    const params: Record<string, string> = {
      'fid': String(fid),
      'stid': formatOptionalId(stid),
      'tid': formatOptionalId(tid),
      'pid': formatOptionalId(pid),
      'action': normalizedAction,
    };
    // __output 跟随官方两条 check 链路：
    // - new（发新帖编辑器）：官方 PublishActivity → kt.c.F0 → NetRequest.build() = 14
    // - reply/quote/tietiao/modify（详情页回复/贴条/引用/修改）：
    //   官方新版详情页 ArticleDetailViewModel.onReplay → ArticleRepository.getPost
    //   （requestJava → buildNew()）= 12
    // check 无 content 提交，不受 __output=14 的 GBK 解析影响（153 仅针对 content）。
    const output: string = normalizedAction === 'new' ? '14' : '12';
    const raw: Record<string, Object> = await ngaClient.postSigned(
      '/app_api.php', 'post', 'check', params,
      { uid: session.uid, cid: session.cid }, normalizedAction, output
    ) as Record<string, Object>;
    const error: string | null = readAppError(raw, '获取发帖权限失败');
    if (error) {
      result.error = error;
      return result;
    }
    const payload: Record<string, Object> = readPostPayload(raw);
    result.auth = String(payload['auth'] ?? '');
    result.attachUrl = String(payload['attach_url'] ?? '');
    result.if_moderator = Number(payload['if_moderator'] ?? 0);
    // 引用（quote）场景：服务端按 pid 预生成引用块返回在 content 字段，提交 quote
    // 时必须随 content 带回（官方 K0 的 d1.r(d1.w(actionCheck.getContent())) 拼接）；
    // modify 场景为编辑回显正文。其余 action 通常为空串。
    result.content = String(payload['content'] ?? '');
    // 编辑（modify）场景：服务端回传已存在附件的提交参数，供提交时保留旧附件
    result.attachments = parseAttachArrayValue(payload['attachArray']);
    result.attachmentsCheck = parseAttachArrayValue(payload['attachCheckArray']);
    result.ok = true;
  } catch (error) {
    result.error = readThrownError(error, '获取发帖权限失败');
  }
  return result;
}

/**
 * 发布回复、楼层引用、贴条或编辑后的帖子。
 *
 * @param token - 会话令牌
 * @param tid - 主题 ID
 * @param fid - 版块 ID
 * @param content - BBCode 正文
 * @param anony - 是否匿名
 * @param attachments - 附件参数
 * @param attachmentsCheck - 附件校验参数
 * @param stid - 子版块 ID
 * @param action - `reply`、`quote`、`modify` 或 `tietiao`
 * @param pid - 目标楼层 ID
 * @param postSubject - 标题，回复场景为空
 * @returns 提交结果
 */
export async function postReply(token: string, tid: number, fid: number,
  content: string, anony: number, attachments: string, attachmentsCheck: string,
  stid: number, action: string, pid: number, postSubject: string): Promise<PostReplyResult> {
  const normalizedAction: string = action.length > 0 ? action : 'reply';
  const normalizedContent: string = normalizePostContent(content);
  if (normalizedAction === 'reply' && pid <= 0 && anony === 0 &&
    attachments.length === 0 && attachmentsCheck.length === 0) {
    return submitSimpleReply(token, tid, normalizedContent);
  }
  const fields: Record<string, string> = buildPostFields(
    fid, tid, pid, stid, normalizedAction, normalizedContent, postSubject, anony,
    attachments, attachmentsCheck
  );
  return submitPost(token, normalizedAction, fields,
    String(tid) + normalizedContent, tid, '回复失败');
}

/**
 * 发布新主题。
 *
 * @param token - 会话令牌
 * @param fid - 版块 ID
 * @param stid - 子版块 ID
 * @param subject - 标题
 * @param content - BBCode 正文
 * @param anony - 是否匿名
 * @param attachments - 附件参数
 * @param attachmentsCheck - 附件校验参数
 * @returns 提交结果
 */
export async function postNewTopic(token: string, fid: number, stid: number,
  subject: string, content: string, anony: number, attachments: string,
  attachmentsCheck: string): Promise<PostReplyResult> {
  const normalizedContent: string = normalizePostContent(content);
  const fields: Record<string, string> = buildPostFields(
    fid, 0, 0, stid, 'new', normalizedContent, subject, anony,
    attachments, attachmentsCheck
  );
  // 注：output='' 通道成功响应 result 为字符串（"发贴完毕 ..."），不含新帖 tid；
  // fallbackTid=0 → 调用方（TopicListPanel）不跳转新帖、仅刷新列表——与官方行为一致
  // （官方发帖成功同样不携带 tid、不跳转，仅 toast 后返回列表）。
  return submitPost(token, 'new', fields,
    String(fid) + subject + normalizedContent, 0, '发帖失败');
}

/**
 * 发布贴条评论。
 *
 * 官方发帖编辑器把贴条作为 `post/tietiao` action 提交，签名串仍为 tid+content，
 * 目标楼层通过 pid 传递。
 *
 * @param token - 会话令牌
 * @param tid - 主题 ID
 * @param pid - 目标楼层 ID
 * @param fid - 版块 ID
 * @param content - 评论内容
 * @param anony - 是否匿名
 * @returns 提交结果
 */
export async function postComment(token: string, tid: number, pid: number,
  fid: number, content: string, anony: number): Promise<PostReplyResult> {
  const normalizedContent: string = normalizePostContent(content);
  const fields: Record<string, string> = buildPostFields(
    fid, tid, pid, 0, 'tietiao', normalizedContent, '', anony, '', ''
  );
  return submitPost(token, 'tietiao', fields,
    String(tid) + normalizedContent, tid, '评论失败');
}

/**
 * 上传帖子图片附件。
 *
 * @param token - 会话令牌
 * @param auth - post/check 返回的上传鉴权码
 * @param fid - 版块 ID
 * @param attachUrl - post/check 返回的上传地址
 * @param imageData - 图片二进制数据
 * @param fileName - 文件名
 * @returns 附件参数与图片 URL
 */
export async function uploadAttachment(token: string, auth: string, fid: number,
  attachUrl: string, imageData: ArrayBuffer, fileName: string): Promise<UploadAttachmentResult> {
  const result = new UploadAttachmentResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    const rawText: string = await ngaUploadFile(
      imageData, fileName, auth, fid, attachUrl,
      { uid: session.uid, cid: session.cid }
    );
    logger.verbose('[NGA][UPLOAD] raw: %{public}s', rawText.slice(0, 300));
    const cleaned: string = rawText
      .replace('window.script_muti_get_var_store=', '')
      .trim();
    const payload: Record<string, Object> = readUploadPayload(cleaned);
    const errorCode: number = Number(payload['error_code'] ?? 0);
    if (errorCode !== 0) {
      const message: string = String(payload['error'] ?? '');
      result.error = message.length > 0 ? message : '上传被拒绝（错误码 ' + String(errorCode) + '）';
      return result;
    }
    result.attachments = String(payload['attachments'] ?? '');
    result.attachmentsCheck = String(payload['attachments_check'] ?? '');
    const attachment: string = String(payload['attachment'] ?? '');
    const returnedUrl: string = String(payload['url'] ?? '');
    const returnedBase: string = String(payload['attach_url'] ?? attachUrl);
    result.url = returnedUrl.length > 0 ? returnedUrl : returnedBase + attachment;
    if (result.attachments.length === 0 && result.attachmentsCheck.length === 0 && result.url.length === 0) {
      result.error = '上传响应缺少附件字段';
      return result;
    }
    result.ok = true;
  } catch (error) {
    result.error = readThrownError(error, '上传失败');
  }
  return result;
}
