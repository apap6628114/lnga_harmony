/**
 * 热点回复（hotreply）数据解析 — 从 NGA 帖子页 hightlight_for_<lou> 容器提取热门回复。
 *
 * 网页版把"热点回复"渲染在楼主楼层容器 `<span id='hightlight_for_<lou>'>` 内：
 * - 每条回复一个 `commentposterinfo__<pid>` 作者信息锚点（<lou> 容器内可有多条）
 * - 正文在 `<span id='postcomment__<pid>'>`（BBCode 源文，与 JSON hotreply.content 一致）
 * - 时间在 `commentInfo__<pid>` 内 `<span title='reply time'>`
 * - 作者名在 `commentauthor__<pid>` 锚点文本
 * - 元数据在独立的 `commonui.postArg.proc( '__<pid>', ... )` 调用（与主楼行同布局：
 *   [10]=pid, [11]=type, [13]=authorid, [14]=postdatetimestamp, [15]=score, [16]=content_length）
 * - 原楼层号可由页面 `pid<pid>Anchor` 后紧跟的 `<a name='l<lou>'>` 锚点反查
 *
 * 输出：与 JSON API 行 `hotreply` 字段相同形状的映射
 * （pid/fid/tid/authorid/type/score/score_2/recommend/postdate/subject/alterinfo/
 * content/lou/content_length/attachs/from_client/postdatetimestamp），可直接被
 * parseThreadData 的 mapRow 消费为热门回复列表。
 */

import { scanBalanced } from './ScanState';
import { splitTopLevelArgs } from './PostArgScanner';
import { unescapeHtml } from '../../_shared/HtmlEntityCodec';

/** 热点回复容器起点标记（`<lou>` 为所属页面行号）。 */
const HIGHLIGHT_MARKER_PREFIX: string = "id='hightlight_for_";
/** 容器终点：所在行的签名占位容器（热点回复渲染在 postsign 之前）。 */
const POSTSIGN_MARKER_PREFIX: string = "id='postsign";
/** 单条热点回复的标识：作者信息锚点（后跟 pid 数字）。 */
const COMMENT_POSTER_MARKER: string = 'commentposterinfo__';
/** 作者信息锚点的 DOM id 标记（排除 proc 参数中的 `$('commentposterinfo__...')` 引用）。 */
const POSTER_ID_MARKER: string = "id='commentposterinfo__";
/** 正文容器标记。 */
const COMMENT_CONTENT_MARKER_PREFIX: string = "id='postcomment__";
/** 时间容器标记。 */
const COMMENT_INFO_MARKER_PREFIX: string = "id='commentInfo__";
/** 作者名锚点标记。 */
const COMMENT_AUTHOR_MARKER_PREFIX: string = "id='commentauthor__";
/** 热点回复元数据 postArg.proc 调用标记（含 `(`，openPos 取 length-1 指向开括号）。 */
const PROC_MARKER: string = "commonui.postArg.proc( '";
/** 时间文本前缀（`<span title='reply time'>` 内）。 */
const REPLY_TIME_MARKER: string = "title='reply time'>";
/** 原楼层号反查：pid 锚点（`<a id='pid<pid>Anchor'>`）后紧跟的 lou 锚点。 */
const PID_ANCHOR_MARKER_PREFIX: string = "<a id='pid";
/** lou 锚点匹配（`<a name='l<lou>'>`）。 */
const LOU_ANCHOR_RE: RegExp = /<a name='l(\d+)'>/;
/** 容器内 pid 提取（commentposterinfo__ 后紧跟数字）。 */
const PID_AFTER_MARKER_RE: RegExp = /^(\d+)/;

/**
 * 从 HTML 中提取指定楼层的热点回复列表。
 *
 * @param html NGA 帖子页 HTML
 * @param lou 所属页面行号（hightlight_for_<lou> 容器）
 * @param fid 版块 id（页面级变量，填入条目）
 * @param tid 帖子 id（页面级变量，填入条目）
 * @returns 热点回复映射（key 为索引字符串）；容器不存在或为空时返回 null
 */
function extractHotReplies(html: string, lou: number, fid: number, tid: number): Record<string, Object> | null {
  const startIdx: number = html.indexOf(HIGHLIGHT_MARKER_PREFIX + lou + "'");
  if (startIdx < 0) {
    return null;
  }
  const endIdx: number = html.indexOf(POSTSIGN_MARKER_PREFIX + lou + "'", startIdx);
  const container: string = endIdx > startIdx
    ? html.substring(startIdx, endIdx)
    : html.substring(startIdx);

  const result: Record<string, Object> = {};
  let searchFrom: number = 0;
  let itemIdx: number = 0;
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
    const pidStr: string = pidMatch[1];
    searchFrom = posterIdx + POSTER_ID_MARKER.length;

    const content: string = extractCommentContent(container, pidStr);
    const postDate: string = extractCommentDate(container, pidStr);
    const author: string = extractCommentAuthor(html, pidStr);
    const meta: CommentMeta = extractCommentMeta(html, pidStr);
    const replyLou: number = extractReplyLou(html, pidStr);

    const row: Record<string, Object> = {
      'pid': meta.pid as Object,
      'fid': fid as Object,
      'tid': tid as Object,
      'authorid': meta.authorid as Object,
      'type': meta.type as Object,
      'score': meta.score as Object,
      'score_2': meta.score2 as Object,
      'recommend': 0 as Object,
      'postdate': postDate as Object,
      'subject': '' as Object,
      'alterinfo': '' as Object,
      'content': content as Object,
      'lou': replyLou as Object,
      'content_length': 0 as Object,
      'attachs': {} as Object,
      'from_client': '' as Object,
      'postdatetimestamp': meta.postdatetimestamp as Object,
    };
    void author;
    result[String(itemIdx)] = row;
    itemIdx++;
  }
  return itemIdx > 0 ? result : null;
}

/**
 * 热点回复元数据（postArg.proc 调用解析结果）。
 */
class CommentMeta {
  pid: number = 0;
  type: number = 0;
  authorid: string = '';
  postdatetimestamp: number = 0;
  score: number = 0;
  score2: number = 0;
}

/**
 * 从 `commonui.postArg.proc( '__<pid>', ... )` 调用提取热点回复元数据。
 *
 * 参数布局与主楼行一致：[10]=pid, [11]=type, [13]=authorid, [14]=postdatetimestamp,
 * [15]=score（score_2,score 逗号分隔）, [16]=content_length（此处恒 null，不取）。
 * 参数 [0] 须为 `'__<pid>'`（评论标识），据此排除主楼行的 proc 调用。
 *
 * @param html 源 HTML
 * @param pid 热点回复 pid
 * @returns 解析后的元数据；调用不存在或参数不符时返回默认值
 */
function extractCommentMeta(html: string, pid: string): CommentMeta {
  const meta: CommentMeta = new CommentMeta();
  const startIdx: number = html.indexOf(PROC_MARKER);
  if (startIdx < 0) {
    return meta;
  }
  const openPos: number = startIdx + PROC_MARKER.indexOf('(');
  const matched = scanBalanced(html, openPos, '(', ')');
  if (!matched.value) {
    return meta;
  }
  const args: string[] = splitTopLevelArgs(matched.value.substring(1, matched.value.length - 1));
  if (args.length < 17) {
    return meta;
  }
  // 参数 [0] 校验：热点回复调用的首个参数为 `'__<pid>'`
  if (args[0].indexOf('__' + pid) < 0) {
    return meta;
  }
  meta.pid = parseInt(args[10], 10) || 0;
  meta.type = parseInt(args[11], 10) || 0;
  meta.authorid = args[13].replace(/'/g, '');
  meta.postdatetimestamp = parseInt(args[14], 10) || 0;
  const scoreParts: string[] = args[15].replace(/'/g, '').split(',');
  meta.score2 = parseInt(scoreParts[0], 10) || 0;
  meta.score = parseInt(scoreParts[1], 10) || 0;
  return meta;
}

/**
 * 提取热点回复正文（postcomment__<pid> 容器文本，已反转 HTML 实体）。
 *
 * @param container hightlight_for 容器子串
 * @param pid 热点回复 pid
 * @returns 正文；未找到时返回空串
 */
function extractCommentContent(container: string, pid: string): string {
  const marker: string = COMMENT_CONTENT_MARKER_PREFIX + pid + "'";
  const startIdx: number = container.indexOf(marker);
  if (startIdx < 0) {
    return '';
  }
  const tagEnd: number = container.indexOf('>', startIdx);
  if (tagEnd < 0) {
    return '';
  }
  const contentStart: number = tagEnd + 1;
  const endIdx: number = container.indexOf('</span>', contentStart);
  if (endIdx < 0) {
    return '';
  }
  return unescapeHtml(container.substring(contentStart, endIdx));
}

/**
 * 提取热点回复发帖时间（commentInfo__<pid> 内 `title='reply time'` 后的文本）。
 *
 * @param container hightlight_for 容器子串
 * @param pid 热点回复 pid
 * @returns 时间字符串（已 trim）；未找到时返回空串
 */
function extractCommentDate(container: string, pid: string): string {
  const marker: string = COMMENT_INFO_MARKER_PREFIX + pid + "'";
  const startIdx: number = container.indexOf(marker);
  if (startIdx < 0) {
    return '';
  }
  const timeStart: number = container.indexOf(REPLY_TIME_MARKER, startIdx);
  if (timeStart < 0) {
    return '';
  }
  const contentStart: number = timeStart + REPLY_TIME_MARKER.length;
  const endIdx: number = container.indexOf('</span>', contentStart);
  if (endIdx < 0) {
    return '';
  }
  return container.substring(contentStart, endIdx).trim();
}

/**
 * 提取热点回复作者名（commentauthor__<pid> 锚点文本，已反转 HTML 实体）。
 *
 * @param html 源 HTML
 * @param pid 热点回复 pid
 * @returns 作者名；未找到时返回空串
 */
function extractCommentAuthor(html: string, pid: string): string {
  const marker: string = COMMENT_AUTHOR_MARKER_PREFIX + pid + "'";
  const startIdx: number = html.indexOf(marker);
  if (startIdx < 0) {
    return '';
  }
  const tagEnd: number = html.indexOf('>', startIdx);
  if (tagEnd < 0) {
    return '';
  }
  const contentStart: number = tagEnd + 1;
  const endIdx: number = html.indexOf('</a>', contentStart);
  if (endIdx < 0) {
    return '';
  }
  return unescapeHtml(html.substring(contentStart, endIdx).trim());
}

/**
 * 反查热点回复的原楼层号（页面 `pid<pid>Anchor` 后紧跟 `<a name='l<lou>'>`）。
 *
 * @param html 源 HTML
 * @param pid 热点回复 pid
 * @returns 原楼层号；未找到时返回 0
 */
function extractReplyLou(html: string, pid: string): number {
  const anchorIdx: number = html.indexOf(PID_ANCHOR_MARKER_PREFIX + pid + "Anchor'");
  if (anchorIdx < 0) {
    return 0;
  }
  const louMatch: RegExpExecArray | null = LOU_ANCHOR_RE.exec(html.substring(anchorIdx));
  if (louMatch) {
    return parseInt(louMatch[1], 10);
  }
  return 0;
}

export { extractHotReplies };
