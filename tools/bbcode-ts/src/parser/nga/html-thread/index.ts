/**
 * HTML 响应体转 NGA 原始 JSON 结构 — 顶层装配入口。
 *
 * 输入：NGA read.php 返回的 HTML 页面（GBK->UTF-8 解码后）
 * 输出：与 __output=8 JSON API 相同形状的 { data: { __R, __U, __T, __F, __ROWS } }
 * 可直接喂给 parseThreadData() 使用。
 *
 * 本文件仅承担装配职责：调用 DomMarkerExtractor / PostArgScanner / AttachParser 完成各字段提取，
 * 组装为 __R/__U/__T/__F/__ROWS/__R__ROWS_PAGE/__PAGE 结构。
 */

import { PostArgData, parseAllPostArgs, extractUserInfo, extractTotalReplies, extractLastPostTs, extractSetDefaultVote } from './PostArgScanner';
import {
  extractPostContent, extractPostSubject, extractPostDate,
  extractForumName, extractThreadSubject, extractPostAuthorName,
} from './DomMarkerExtractor';
import { tryParseAttachLoad } from './AttachParser';
import { extractHotReplies } from './HotReplyParser';

/**
 * 从 HTML 中提取 `varName = <数字>` 形式的整型变量。
 *
 * 支持负数（如子版 fid=-40063163）；页面同时存在
 * `varName=-40063163,` 与 `varName=parseInt('-40063163')` 两种写法时取首次命中。
 *
 * @param html 源 HTML
 * @param varName 变量名
 * @param defaultValue 未找到时的默认值
 * @returns 变量值；未找到时返回 defaultValue
 */
function extractIntVar(html: string, varName: string, defaultValue: number): number {
  const regex: RegExp = new RegExp(varName + '\\s*=\\s*(-?\\d+)');
  const match: RegExpExecArray | null = regex.exec(html);
  if (match) {
    return parseInt(match[1], 10);
  }
  return defaultValue;
}

/**
 * 将 NGA HTML 帖子页面解析为与 __output=8 JSON API 相同形状的对象。
 *
 * @param html NGA 帖子页 HTML
 * @returns 形如 { data: { __R, __U, __T, __F, __ROWS, __R__ROWS_PAGE, __PAGE } } 的对象，可直接传入 parseThreadData()
 */
export function parseHtmlToRawJson(html: string): object {
  const __U: Record<string, Object> = extractUserInfo(html);
  const postArgs: Map<number, PostArgData> = parseAllPostArgs(html);
  const tid: number = extractIntVar(html, '__CURRENT_TID', 0);
  const fid: number = extractIntVar(html, '__CURRENT_FID', 0);
  const page: number = extractIntVar(html, '__CURRENT_PAGE', 1);
  const pagePosts: number = extractIntVar(html, '__CURRENT_PAGE_POSTS', 20);

  const __R: Record<string, Object> = {};
  let maxLou: number = -1;
  const defaultPostdate: string = '';
  // 主题级投票（setDefault 第 9 参）：JSON API 语义下仅主楼行携带 vote 字段，
  // 页面只提供主题级数据，填入 lou=0 行与 JSON 形状保持一致
  const topicVote: string = extractSetDefaultVote(html);

  const procKeys: number[] = [];
  postArgs.forEach((_value: PostArgData, key: number): void => {
    procKeys.push(key);
  });
  procKeys.sort((a: number, b: number): number => a - b);

  for (let i: number = 0; i < procKeys.length; i++) {
    const lou: number = procKeys[i];
    const arg: PostArgData | undefined = postArgs.get(lou);
    if (!arg) {
      continue;
    }
    const content: string = extractPostContent(html, lou);
    const subject: string = extractPostSubject(html, lou);
    const dateStr: string = extractPostDate(html, lou);
    const postDate: string = dateStr || defaultPostdate;
    if (lou > maxLou) {
      maxLou = lou;
    }

    let attachs: Record<string, Object>[] = tryParseAttachLoad(html, lou) ?? [];
    const hotReplies: Record<string, Object> | null = extractHotReplies(html, lou, fid, tid);
    const noHotReplies: Record<string, Object> = {};

    const row: Record<string, Object> = {
      'pid': arg.pid as Object,
      'fid': fid as Object,
      'tid': tid as Object,
      'lou': lou as Object,
      'authorid': arg.authorid as Object,
      'author': extractPostAuthorName(__U, parseInt(arg.authorid, 10) || 0) as Object,
      'subject': subject as Object,
      'content': content as Object,
      'postdate': postDate as Object,
      'postdatetimestamp': arg.postdatetimestamp as Object,
      'type': arg.type as Object,
      'score': arg.score as Object,
      'score_2': arg.score_2 as Object,
      'content_length': arg.contentLength as Object,
      'from_client': arg.fromClient as Object,
      'from_client_model': arg.fromClientModel as Object,
      'vote': (lou === 0 ? topicVote : '') as Object,
      'alterinfo': '' as Object,
      'isanonymous': false as Object,
      'attachs': attachs as Object,
      'hotreply': (hotReplies ?? noHotReplies) as Object,
    };

    __R[String(lou)] = row;
  }

  // 热点回复附件复用：条目记录的原楼层行若有附件，直接引用（JSON API 中两者相同）
  const hotRowKeys: string[] = Object.keys(__R);
  for (let hi: number = 0; hi < hotRowKeys.length; hi++) {
    const hotRow: Record<string, Object> = __R[hotRowKeys[hi]] as Record<string, Object>;
    const hotMap: Record<string, Object> = (hotRow['hotreply'] ?? {}) as Record<string, Object>;
    const hotKeys: string[] = Object.keys(hotMap);
    for (let hj: number = 0; hj < hotKeys.length; hj++) {
      const entry: Record<string, Object> = hotMap[hotKeys[hj]] as Record<string, Object>;
      const replyLou: number = Number(entry['lou'] ?? 0);
      const replyRow: Record<string, Object> | undefined = __R[String(replyLou)] as Record<string, Object> | undefined;
      if (replyRow && replyRow['attachs']) {
        entry['attachs'] = replyRow['attachs'];
      }
    }
  }

  const currentPageRows: number = maxLou + 1;
  const totalReplies: number = extractTotalReplies(html);
  const totalRows: number = totalReplies >= 0 ? totalReplies + 1 : currentPageRows;

  let firstPostDate: string = '';
  let lastPostDate: string = '';
  let firstPostTs: number = 0;
  let lastPostTs: number = 0;
  let firstAuthorId: number = 0;
  let lastAuthorId: number = 0;

  if (procKeys.length > 0) {
    const firstLou: number = procKeys[0];
    const firstArg: PostArgData | undefined = postArgs.get(firstLou);
    if (firstArg) {
      firstPostDate = extractPostDate(html, firstLou);
      firstPostTs = firstArg.postdatetimestamp;
      firstAuthorId = parseInt(firstArg.authorid, 10) || 0;
    }
    const lastLou: number = procKeys[procKeys.length - 1];
    const lastArg: PostArgData | undefined = postArgs.get(lastLou);
    if (lastArg) {
      lastPostDate = extractPostDate(html, lastLou);
      lastPostTs = lastArg.postdatetimestamp;
      lastAuthorId = parseInt(lastArg.authorid, 10) || 0;
    }
  }

  const postMiscVar: Record<string, Object> = { 'vote': topicVote as Object };

  const __T: Record<string, Object> = {
    'tid': tid as Object,
    'fid': fid as Object,
    'subject': extractThreadSubject(html) as Object,
    'replies': Math.max(0, totalRows - 1) as Object,
    'this_visit_rows': currentPageRows as Object,
    'authorid': firstAuthorId as Object,
    'author': extractPostAuthorName(__U, firstAuthorId) as Object,
    'postdate': (firstPostTs || 0) as Object,
    'lastpost': (extractLastPostTs(html) || lastPostTs || 0) as Object,
    'lastposter': extractPostAuthorName(__U, lastAuthorId) as Object,
    'post_misc_var': postMiscVar as Object,
    'type': 0 as Object,
    'locked': 0 as Object,
    'recommend': 0 as Object,
    'digest': 0 as Object,
  };

  const __F: Record<string, string> = {
    'name': extractForumName(html),
  };

  const data: Record<string, Object> = {
    '__R': __R as Object,
    '__U': __U as Object,
    '__T': __T as Object,
    '__F': __F as Object,
    '__ROWS': totalRows as Object,
    '__R__ROWS': currentPageRows as Object,
    '__R__ROWS_PAGE': pagePosts as Object,
    '__PAGE': page as Object,
  };

  const result: Record<string, Object> = {
    'data': data as Object,
  };

  return result as Object;
}
