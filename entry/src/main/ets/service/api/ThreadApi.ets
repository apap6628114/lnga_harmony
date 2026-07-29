/**
 * NGA 帖子 API - 帖子详情、回帖、评论、附件上传
 * 含 HTML 强制模式调试开关、JSON/HTML 双通道解析与图片预热。
 */

import { ngaClient, ngaUploadFile } from '../NgaClient';
import { appStore } from '../../store/AppStore';
import { parseThreadData } from '../../parser/ThreadParser';
import { parseNgaError } from '../../parser/ErrorParser';
import { parseFromClient } from '../../parser/ClientParser';
import { resolveAttachUrl } from '../../parser/_shared/AttachUrl';
import { parseHtmlTask } from '../../parser/task/HtmlParseTask';
import { taskpool } from '@kit.ArkTS';
import { ImageLoadStrategy } from '../../common/constants/Constants';
import { KEY_FORCE_HTML_MODE } from '../../common/constants/AppStorageKeys';
import { fetchImageSize } from '../../common/media/ImageSizeUtil';
import { isWifiConnected } from '../../common/utils/NetworkUtil';
import type { ThreadData, ThreadRowInfo, Attachment, ThreadInfo } from '../../model/Thread';
import { PostInfo, PostAttachInfo } from '../../model/PostInfo';
import { ThreadResult, ThreadPaging, PostAuthResult, PostReplyResult } from '../../model/ThreadResult';
import { UploadAttachmentResult } from '../../model/NgaApiResults';
import { Logger, DOMAIN_SERVICE } from '../../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'ThreadApi')

// ============== 调试开关 ==============

/** 调试开关：true 时 getThread 强制走 HTML 解析模式，跳过 JSON API */
function getForceHtmlMode(): boolean {
  const stored: boolean = AppStorage.get<boolean>(KEY_FORCE_HTML_MODE) ?? false
  return stored
}

export function setForceHtmlMode(v: boolean): void {
  AppStorage.setOrCreate<boolean>(KEY_FORCE_HTML_MODE, v)
}

// ============== 帖子详情 ==============

export async function getThread(token: string, tid: string, pid: string,
  authorid: string, page: string,
  blacklist: Set<string> = new Set(),
  keywords: string[] = [],
  noteMap: Record<string, string> = {}): Promise<ThreadResult> {
  const result = new ThreadResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  let jsonError: string = '';

  try {
    if (!tid && !pid) {
      result.error = '缺少 tid 或 pid';
      return result;
    }

    if (getForceHtmlMode() || !tid) {
      // 调试模式 / 强制走 HTML 解析
      const htmlParams: Record<string, string> = {
        'tid': tid || '',
        'page': page || '1',
      };
      if (pid) htmlParams['pid'] = pid;
      if (authorid) htmlParams['authorid'] = authorid;
      const html: string = await ngaClient.getHtmlText('/read.php', htmlParams, { uid: session.uid, cid: session.cid });
      const rawObj: Object = await taskpool.execute(parseHtmlTask, html)
      const rawHtml: Record<string, Object> = rawObj as Record<string, Object>
      fillThreadResult(rawHtml, result, blacklist, keywords, noteMap);
    } else {
      // 优先尝试 JSON API (__output=8)；失败时降级 HTML 解析
      const ngaParams: Record<string, string> = {
        'page': page || '1',
        '__output': '8',
        'noprefix': '',
        'v2': '',
      };
      if (tid) ngaParams['tid'] = tid;
      if (pid) ngaParams['pid'] = pid;
      if (authorid) ngaParams['authorid'] = authorid;

      let jsonOk: boolean = false;
      jsonError = '';
      try {
        const raw = await ngaClient.get('/read.php', ngaParams, { uid: session.uid, cid: session.cid }) as Record<string, Object>;
        const err = parseNgaError(raw);
        if (err) {
          jsonError = err;
        } else {
          fillThreadResult(raw as Record<string, Object>, result, blacklist, keywords, noteMap);
          jsonOk = true;
        }
      } catch (e) {
        jsonError = (e as Error).message ?? 'JSON 请求异常';
        logger.error('[NGA][REQ] JSON API 请求失败，降级 HTML: %{public}s', jsonError);
      }

      if (!jsonOk) {
        const fallbackParams: Record<string, string> = {
          'tid': tid || '',
          'page': page || '1',
        };
        if (pid) fallbackParams['pid'] = pid;
        if (authorid) fallbackParams['authorid'] = authorid;
        const html: string = await ngaClient.getHtmlText('/read.php', fallbackParams, { uid: session.uid, cid: session.cid });
        const rawObj: Object = await taskpool.execute(parseHtmlTask, html)
        const rawHtml: Record<string, Object> = rawObj as Record<string, Object>
        fillThreadResult(rawHtml, result, blacklist, keywords, noteMap);
        if (result.posts.length === 0) {
          result.ok = false;
          result.error = jsonError || result.error || '无法加载该帖子';
        }
      }
    }
  } catch (e) {
    const htmlErr: string = (e as Error).message ?? 'HTML 解析异常';
    result.error = jsonError ? `${htmlErr}（JSON 先失败: ${jsonError}）` : htmlErr;
  }
  return result;
}

/**
 * 在帖子数据就绪后，提前预热所有图片的尺寸头
 */
function prefetchPostImages(posts: PostInfo[]): void {
  if (!appStore.settings.enableImageSizePrefetch) {
    return
  }
  let strategy: string = appStore.settings.imageLoadStrategy
  if (strategy === ImageLoadStrategy.MANUAL) {
    return
  }
  if (strategy === ImageLoadStrategy.WIFI_ONLY && !isWifiConnected()) {
    return
  }
  for (let i = 0; i < posts.length; i++) {
    const post: PostInfo = posts[i]
    if (post.isInBlackList || appStore.settingsStore.isBlacklisted(String(post.authorid))) {
      continue
    }
    const attachs: PostAttachInfo[] = post.attachs
    for (let j = 0; j < attachs.length; j++) {
      const url: string = attachs[j].attachurl
      if (url && url.length > 0) {
        fetchImageSize(url)
      }
    }
  }
}

/**
 * 从 NGA 原始 JSON 填充 ThreadResult（JSON API 与 HTML 降级共享）
 */
function fillThreadResult(raw: Record<string, Object>, result: ThreadResult,
  blacklist: Set<string>, keywords: string[] = [],
  noteMap: Record<string, string> = {}): void {
  const data: ThreadData = parseThreadData(raw, blacklist, keywords, noteMap);
  const dataObj: Record<string, Object> | undefined = raw?.['data'] as Record<string, Object> | undefined;

  if (dataObj?.['__PAGE']) {
    data.pagination.page = Number(dataObj['__PAGE']);
  }

  const __U: Record<string, Object> = (dataObj?.['__U'] ?? {}) as Record<string, Object>;
  const forumInfo: Record<string, string> = data.__F as Record<string, string>;
  result.forumName = forumInfo?.['name'] ?? '';

  const groupMap: Map<number, string> = new Map();
  const uKeys: string[] = Object.keys(__U);
  for (let uk = 0; uk < uKeys.length; uk++) {
    const uEntry = __U[uKeys[uk]] as Record<string, Object> | undefined;
    if (uEntry && uEntry['__GROUPS'] && typeof uEntry['__GROUPS'] === 'object') {
      const groups = uEntry['__GROUPS'] as Record<string, Object>;
      const gKeys = Object.keys(groups);
      for (let gi = 0; gi < gKeys.length; gi++) {
        const gEntry = groups[gKeys[gi]] as Record<string, Object>;
        if (gEntry && gEntry['0'] && gEntry['2'] !== undefined) {
          groupMap.set(Number(gEntry['2']), String(gEntry['0']));
        }
      }
      break;
    }
  }

  const mapRowToPost = (row: ThreadRowInfo): PostInfo => {
    const userInfo: Record<string, Object> | undefined = __U[String(row.authorid)] as Record<string, Object> | undefined;
    const post: PostInfo = new PostInfo();
    post.tid = row.tid;
    post.pid = row.pid;
    post.lou = row.lou;
    post.authorid = row.authorid;
    const rawAuthor: string = String(userInfo?.['username'] ?? row.author ?? '');
    post.author = rawAuthor;
    post.isanonymous = row.isanonymous || (rawAuthor.startsWith('#anony_') && rawAuthor.length === 39);
    post.subject = row.subject;
    post.content = row.content;
    post.postdate = row.postdate;
    const memberid: number = Number(userInfo?.['memberid'] ?? 0);
    const rvrc: number = Number(userInfo?.['rvrc'] ?? 0);
    post.level = String(Math.max(0, rvrc));
    post.yz = String(userInfo?.['yz'] ?? row.yz ?? '');
    post.avatar = String(userInfo?.['avatar'] ?? row.js_escap_avatar ?? '');
    post.signature = String(userInfo?.['signature'] ?? row.signature ?? '');
    post.attachs = row.attachs.map((a: Attachment): PostAttachInfo => {
      const info: PostAttachInfo = new PostAttachInfo();
      info.aid = a.aid;
      info.attachurl = resolveAttachUrl(a.attachurl);
      info.url_utf8_org_name = a.url_utf8_org_name;
      info.name = a.name;
      info.ext = a.ext;
      info.type = a.type;
      info.size = a.size;
      info.thumb = a.thumb;
      info.thumbUrl = info.attachurl;
      info.dscp = a.dscp;
      info.subid = a.subid;
      return info;
    });
    post.comments = row.comments.map(mapRowToPost);
    post.hotReplies = row.hotReplies;
    post.fromClient = parseFromClient(row.from_client);
    post.from_client_model = row.from_client_model;
    post.alterinfo = row.alterinfo;
    post.score = row.score;
    post.score_2 = row.score_2;
    post.isInBlackList = row.isInBlackList;
    post.userNote = row.userNote;
    post.isMuted = row.isMuted;
    post.reputation = Number(userInfo?.['reputation'] ?? row.reputation ?? 0);
    post.memberGroup = groupMap.get(memberid) ?? String(row.memberGroup ?? '');
    post.postCount = String(userInfo?.['postnum'] ?? row.postCount ?? '');
    post.muteTime = String(userInfo?.['mute_time'] ?? row.muteTime ?? '');
    return post;
  };

  result.posts = data.rowList.map(mapRowToPost);

  if (dataObj?.['__T']) {
    const __T: Record<string, Object> = dataObj['__T'] as Record<string, Object>;
    let rawT: Record<string, Object> | null = null;
    if (__T['tid']) {
      rawT = __T;
    } else {
      const tKeys: string[] = Object.keys(__T);
      if (tKeys.length > 0) {
        const first: Record<string, Object> | undefined = __T[tKeys[0]] as Record<string, Object> | undefined;
        if (first && typeof first === 'object' && first['tid']) {
          rawT = first;
        }
      }
    }
    if (rawT) {
      const rawAuthorId: number = Number(rawT['authorid'] ?? 0);
      const firstPostAuthorId: number | undefined = data.rowList.find(r => r.lou === 0)?.authorid;
      const finalAuthorId: number = rawAuthorId > 0 ? rawAuthorId : (firstPostAuthorId ?? rawAuthorId);

      const info: ThreadInfo = {
        tid: Number(rawT['tid'] ?? 0),
        fid: Number(rawT['fid'] ?? 0),
        subject: String(rawT['subject'] ?? ''),
        replies: Number(rawT['replies'] ?? 0),
        authorid: finalAuthorId,
        author: String(rawT['author'] ?? ''),
        postdate: Number(rawT['postdate'] ?? 0),
        lastpost: Number(rawT['lastpost'] ?? 0),
        lastposter: String(rawT['lastposter'] ?? ''),
        locked: Number(rawT['locked'] ?? 0) !== 0,
        recommend: Number(rawT['recommend'] ?? 0),
        digest: Number(rawT['digest'] ?? 0),
        type: Number(rawT['type'] ?? 0),
        topic_misc: String(rawT['topic_misc'] ?? ''),
      };
      result.threadInfo = info;
    }
  }

  result.pagination = new ThreadPaging();
  result.pagination.page = data.pagination.page;
  result.pagination.totalPages = data.pagination.totalPages;
  result.pagination.totalRows = data.pagination.totalRows;

  prefetchPostImages(result.posts);

  result.ok = true;
}

/**
 * 通过 HTML 响应体获取帖子详情（JSON API 降级方案）
 * 当 __output=8 请求被 NGA 概率拒绝时使用
 */
export async function getThreadHtml(token: string, tid: string, page: string,
  blacklist: Set<string> = new Set(),
  keywords: string[] = [],
  noteMap: Record<string, string> = {}): Promise<ThreadResult> {
  const result: ThreadResult = new ThreadResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    if (!tid) {
      result.error = '缺少 tid';
      return result;
    }

    const params: Record<string, string> = {
      'tid': tid,
      'page': page || '1',
    };

    const html: string = await ngaClient.getHtmlText('/read.php', params, { uid: session.uid, cid: session.cid });
    const rawObj: Object = await taskpool.execute(parseHtmlTask, html)
    const raw: Record<string, Object> = rawObj as Record<string, Object>
    fillThreadResult(raw, result, blacklist, keywords, noteMap);
  } catch (e) {
    result.error = (e as Error).message ?? '获取帖子详情失败(HTML降级)';
  }
  return result;
}

// ============== 发帖/回帖 ==============

export async function getPostAuth(token: string, fid: number, action: string,
  tid: number, pid: number, comment: number): Promise<PostAuthResult> {
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

    const raw = await ngaClient.postWithQuery('/post.php', authParams, { uid: session.uid, cid: session.cid }) as Record<string, Object>;
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
      'attachments': attachments,
      'attachments_check': attachmentsCheck,
      '__output': '8',
    };
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
