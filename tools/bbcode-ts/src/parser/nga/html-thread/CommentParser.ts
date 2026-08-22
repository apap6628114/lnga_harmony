/**
 * 楼中楼贴条解析 — 从 APP `__output=17` HTML 的 comment_for_<pid> 容器恢复
 * 与网页 JSON `comment` 字段兼容的嵌套楼层数据。
 */

import { scanBalanced } from './ScanState';
import { splitTopLevelArgs } from './PostArgScanner';
import { unescapeHtml } from '../../_shared/HtmlEntityCodec';

/** 贴条容器起点。 */
const COMMENT_CONTAINER_PREFIX: string = "id='comment_for_";

/** 所属普通楼层的签名容器起点。 */
const POSTSIGN_MARKER_PREFIX: string = "id='postsign";

/** 贴条作者 DOM 标记。 */
const POSTER_ID_MARKER: string = "id='commentposterinfo_";

/** 贴条正文 DOM 标记。 */
const CONTENT_MARKER_PREFIX: string = "id='postcomment_";

/** 贴条时间 DOM 标记。 */
const INFO_MARKER_PREFIX: string = "id='commentInfo_";

/** 贴条元数据调用标记。 */
const PROC_MARKER: string = "commonui.postArg.proc( '";

/** 时间文本标记。 */
const REPLY_TIME_MARKER: string = "title='reply time'>";

/** 普通楼层 pid 锚点。 */
const PID_ANCHOR_MARKER_PREFIX: string = "<a id='pid";

/** 普通楼层楼号锚点。 */
const LOU_ANCHOR_RE: RegExp = /<a name='l(\d+)'>/;

/** DOM 标记后的 pid。 */
const PID_AFTER_MARKER_RE: RegExp = /^(\d+)/;

/** 空附件映射。 */
const EMPTY_ATTACHS: Record<string, Object> = {};

/**
 * 贴条 postArg 元数据。
 */
class CommentMeta {
  pid: number = 0;
  type: number = 0;
  authorid: string = '';
  postdatetimestamp: number = 0;
  recommend: number = 0;
  score: number = 0;
  score2: number = 0;
}

/**
 * 从 APP HTML 恢复指定普通楼层的楼中楼贴条。
 *
 * @param html APP 帖子 HTML
 * @param lou 所属普通楼层的页面楼号
 * @param parentPid 所属普通楼层 pid
 * @param fid 版块 id
 * @param tid 主题 id
 * @param rows 已装配的普通楼层表，用于补齐贴条对应原楼层的字段
 * @returns 与网页 JSON `comment` 字段同形状的映射；无贴条时返回 null
 */
function extractComments(html: string, lou: number, parentPid: number, fid: number, tid: number,
  rows: Record<string, Object>): Record<string, Object> | null {
  const startIdx: number = html.indexOf(COMMENT_CONTAINER_PREFIX + parentPid + "'");
  if (startIdx < 0) {
    return null;
  }
  const endIdx: number = html.indexOf(POSTSIGN_MARKER_PREFIX + lou + "'", startIdx);
  const container: string = endIdx > startIdx
    ? html.substring(startIdx, endIdx)
    : html.substring(startIdx);
  const result: Record<string, Object> = {};
  let searchFrom: number = 0;
  let itemIndex: number = 0;
  while (true) {
    const posterIdx: number = container.indexOf(POSTER_ID_MARKER, searchFrom);
    if (posterIdx < 0) {
      break;
    }
    const pidStart: number = posterIdx + POSTER_ID_MARKER.length;
    const pidMatch: RegExpExecArray | null = PID_AFTER_MARKER_RE.exec(container.substring(pidStart));
    if (!pidMatch) {
      searchFrom = posterIdx + 1;
      continue;
    }
    const pid: string = pidMatch[1];
    searchFrom = pidStart + pid.length;
    const meta: CommentMeta = extractCommentMeta(html, pid);
    const source: Record<string, Object> | null = findRowByPid(rows, meta.pid);
    if (source) {
      source['comment_to_id'] = parentPid as Object;
      source['reply_to'] = parentPid as Object;
      if (String(source['subject'] ?? '').length === 0) {
        source['subject'] = (`对回复(${parentPid})发表了一条评论`) as Object;
      }
    }
    const replyLou: number = source ? Number(source['lou'] ?? 0) : extractReplyLou(html, pid);
    const attachs: Object = source?.['attachs'] ?? EMPTY_ATTACHS;
    const row: Record<string, Object> = {
      'pid': (source?.['pid'] ?? meta.pid) as Object,
      'fid': fid as Object,
      'tid': tid as Object,
      'authorid': (source?.['authorid'] ?? meta.authorid) as Object,
      'type': (source?.['type'] ?? meta.type) as Object,
      'score': (source?.['score'] ?? meta.score) as Object,
      'score_2': (source?.['score_2'] ?? meta.score2) as Object,
      'recommend': (source?.['recommend'] ?? meta.recommend) as Object,
      'postdate': extractCommentDate(container, pid) as Object,
      'subject': (`对回复(${parentPid})发表了一条评论`) as Object,
      'alterinfo': '' as Object,
      'content': extractCommentContent(container, pid) as Object,
      'lou': replyLou as Object,
      'content_length': (source?.['content_length'] ?? 0) as Object,
      'attachs': attachs,
      'from_client': (source?.['from_client'] ?? '') as Object,
      'from_client_model': (source?.['from_client_model'] ?? '') as Object,
      'postdatetimestamp': (source?.['postdatetimestamp'] ?? meta.postdatetimestamp) as Object,
      'comment_to_id': parentPid as Object,
      'reply_to': parentPid as Object,
    };
    result[String(itemIndex)] = row;
    itemIndex++;
  }
  return itemIndex > 0 ? result : null;
}

/**
 * 按 pid 查找已装配的普通楼层。
 *
 * @param rows 普通楼层表
 * @param pid 目标 pid
 * @returns 匹配楼层；未找到返回 null
 */
function findRowByPid(rows: Record<string, Object>, pid: number): Record<string, Object> | null {
  const keys: string[] = Object.keys(rows);
  for (let i: number = 0; i < keys.length; i++) {
    const row: Record<string, Object> | undefined = rows[keys[i]] as Record<string, Object> | undefined;
    if (row && Number(row['pid'] ?? -1) === pid) {
      return row;
    }
  }
  return null;
}

/**
 * 提取 `_pid` 贴条 postArg 元数据。
 *
 * @param html APP 帖子 HTML
 * @param pid 贴条 pid
 * @returns 贴条元数据
 */
function extractCommentMeta(html: string, pid: string): CommentMeta {
  const meta: CommentMeta = new CommentMeta();
  const startIdx: number = html.indexOf(PROC_MARKER + '_' + pid + "'");
  if (startIdx < 0) {
    return meta;
  }
  const openPos: number = startIdx + PROC_MARKER.indexOf('(');
  const matched = scanBalanced(html, openPos, '(', ')');
  if (!matched.value) {
    return meta;
  }
  const args: string[] = splitTopLevelArgs(matched.value.substring(1, matched.value.length - 1));
  if (args.length < 17 || args[0].indexOf('_' + pid) < 0) {
    return meta;
  }
  meta.pid = parseInt(args[10], 10) || 0;
  meta.type = parseInt(args[11], 10) || 0;
  meta.authorid = args[13].replace(/'/g, '');
  meta.postdatetimestamp = parseInt(args[14], 10) || 0;
  const scoreParts: string[] = args[15].replace(/'/g, '').split(',');
  meta.recommend = parseInt(scoreParts[0], 10) || 0;
  meta.score = parseInt(scoreParts[1], 10) || 0;
  meta.score2 = parseInt(scoreParts[2], 10) || 0;
  return meta;
}

/**
 * 提取贴条正文。
 *
 * @param container 贴条容器
 * @param pid 贴条 pid
 * @returns 正文
 */
function extractCommentContent(container: string, pid: string): string {
  const marker: string = CONTENT_MARKER_PREFIX + pid + "'";
  const startIdx: number = container.indexOf(marker);
  if (startIdx < 0) {
    return '';
  }
  const tagEnd: number = container.indexOf('>', startIdx);
  const contentStart: number = tagEnd + 1;
  const endIdx: number = container.indexOf('</span>', contentStart);
  if (tagEnd < 0 || endIdx < 0) {
    return '';
  }
  return unescapeHtml(container.substring(contentStart, endIdx));
}

/**
 * 提取贴条时间。
 *
 * @param container 贴条容器
 * @param pid 贴条 pid
 * @returns 时间字符串
 */
function extractCommentDate(container: string, pid: string): string {
  const startIdx: number = container.indexOf(INFO_MARKER_PREFIX + pid + "'");
  if (startIdx < 0) {
    return '';
  }
  const timeStart: number = container.indexOf(REPLY_TIME_MARKER, startIdx);
  if (timeStart < 0) {
    return '';
  }
  const contentStart: number = timeStart + REPLY_TIME_MARKER.length;
  const endIdx: number = container.indexOf('</span>', contentStart);
  return endIdx < 0 ? '' : container.substring(contentStart, endIdx).trim();
}

/**
 * 反查贴条作为普通回复时的原楼层号。
 *
 * @param html APP 帖子 HTML
 * @param pid 贴条 pid
 * @returns 原楼层号
 */
function extractReplyLou(html: string, pid: string): number {
  const anchorIdx: number = html.indexOf(PID_ANCHOR_MARKER_PREFIX + pid + "Anchor'");
  if (anchorIdx < 0) {
    return 0;
  }
  const match: RegExpExecArray | null = LOU_ANCHOR_RE.exec(html.substring(anchorIdx));
  return match ? parseInt(match[1], 10) : 0;
}

export { extractComments };
