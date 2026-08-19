/**
 * HTML 响应体转 NGA 原始 JSON 结构 — thread.php 主题列表（含用户发帖/回帖记录）。
 *
 * 输入：NGA thread.php 返回的 HTML 页面（GBK->UTF-8 解码后），
 *       包括 thread.php?authorid=<uid>（发帖记录）与 &searchpost=1（回帖记录）。
 * 输出：与 JSON API（lite=js / __output=3）相同形状的 { data: { __T, __F, __ROWS,
 *       __T__ROWS_PAGE, __PAGE } }，可直接喂给 parseTopicList() 使用。
 *
 * 本文件仅承担装配职责：调用 TopicArgScanner / DomMarkerExtractor 完成各字段提取，
 * 组装为 __T 结构。JSON 与 HTML 同源于服务端 topicArg 数据，字段逐一对应。
 *
 * 已知缺口（HTML 页面客观不提供，保持空值不伪造）：
 * - entry.lastmodify / recommend / jdata：页面无数据
 * - __P.postdate（回复发布时间）：静态页面无回复时间（官方网页版亦不显示）
 * - 占位条目（subject 含「超过限制/帐号权限不足」）的 tid/fid/__P.tid/__P.pid：
 *   服务端在 HTML 与 JSON 各给一套占位值，不可恢复
 * - __ROWS 总记录数：页面无总数，按 __PAGE[1]（总页数）* 每页行数估计，
 *   无法估计时降级为本页行数（与 read.php 降级「取不到时按当前页行数」一致）
 */

import { TopicArgData, parseAllTopicArgs } from './TopicArgScanner';
import {
  extractTopicSubject, extractTopicAuthor, extractTopicAuthorUid, extractTopicPostDate,
  extractTopicReplier, extractTopicReplies, extractTopicBoard,
  extractReplyContent, extractReplySubject, extractReplyPostMeta,
  BoardMark, ReplyPostMeta,
} from './DomMarkerExtractor';

/**
 * 页面分页变量（var __PAGE = {0:base, 1:totalPages, 2:current, 3:rowsPerPage}）。
 */
class PageInfo {
  baseUrl: string = '';
  /** 总页数；<=0 表示服务端未知（官方以 -5 标记未知） */
  totalPages: number = 0;
  currentPage: number = 1;
  rowsPerPage: number = 35;
}

/**
 * 提取页面分页变量 __PAGE。
 *
 * 官方 js_forum.js::loadReadHidden 语义：pos1 为总页数（>0 真实；-5 未知），
 * pos2 为当前页，pos3 为每页行数。
 *
 * @param html 源 HTML
 * @returns 分页信息；未找到时使用默认值
 */
function extractPageInfo(html: string): PageInfo {
  const result: PageInfo = new PageInfo();
  const match: RegExpMatchArray | null =
    html.match(/var\s+__PAGE\s*=\s*\{\s*0:'([^']*)',\s*1:(-?\d+),\s*2:(\d+),\s*3:(\d+)\s*\}/);
  if (!match) {
    return result;
  }
  result.baseUrl = match[1];
  result.totalPages = parseInt(match[2], 10);
  result.currentPage = parseInt(match[3], 10) || 1;
  result.rowsPerPage = parseInt(match[4], 10) || 35;
  return result;
}

/**
 * 组装单个主题条目为 JSON __T 同形状对象。
 *
 * @param arg topicArg.add 元数据
 * @param rowIndex 行号（作为 __T 索引键）
 * @param html 源 HTML
 * @returns JSON 同形状条目
 */
function buildTopicEntry(arg: TopicArgData, rowIndex: number, html: string): Record<string, Object> {
  const subject: string = extractTopicSubject(html, rowIndex);
  const author: string = extractTopicAuthor(html, rowIndex);
  const authorId: string = extractTopicAuthorUid(html, rowIndex);
  const postdate: number = extractTopicPostDate(html, rowIndex);
  const replier: string = extractTopicReplier(html, rowIndex);
  const replies: number = extractTopicReplies(html, rowIndex);
  const board: BoardMark = extractTopicBoard(html, rowIndex);
  const tid: number = arg.tid;
  const pid: number = arg.pid;

  // parent 语义：{'0': fid, '1': stid, '2': 版块名}；无 stid 时省略 '1'（与 JSON 形状一致）；
  // 无版块标记（如「超过限制」条目）时与 JSON 一致输出空串
  let parent: Object;
  if (board.name.length > 0) {
    const parentObj: Record<string, Object> = {
      '0': arg.fid as Object,
      '2': board.name as Object,
    };
    if (board.stid > 0) {
      parentObj['1'] = board.stid as Object;
    }
    parent = parentObj as Object;
  } else {
    parent = '' as Object;
  }

  const entry: Record<string, Object> = {
    'tid': tid as Object,
    'fid': arg.fid as Object,
    'quote_from': arg.quoteFrom as Object,
    'topic_misc': arg.topicMisc as Object,
    'author': author as Object,
    'authorid': authorId as Object,
    'subject': subject as Object,
    'type': arg.type as Object,
    'postdate': (postdate || arg.postdate) as Object,
    'lastpost': arg.lastpost as Object,
    'lastposter': replier as Object,
    'replies': (replies || arg.replies) as Object,
    'lastmodify': '' as Object,
    'recommend': 0 as Object,
    'jdata': '' as Object,
    'tpcurl': `/read.php?tid=${tid}` as Object,
    'parent': parent,
  };

  // topic_misc_var：仅 stid 有效时输出 {'2': stid}（JSON 无 stid 的条目不携带该字段）
  if (board.stid > 0) {
    const miscVar: Record<string, Object> = {
      '2': board.stid as Object,
    };
    entry['topic_misc_var'] = miscVar as Object;
  }

  // 回帖模式：pid 有效时组装 __P（正文/主题来自 postcontent/postsubject span）
  if (pid > 0) {
    const replyContent: string = extractReplyContent(html, tid, pid);
    const replySubject: string = extractReplySubject(html, tid, pid);
    const replyMeta: ReplyPostMeta = extractReplyPostMeta(html, tid, pid);
    const __P: Record<string, Object> = {
      'tid': tid as Object,
      'pid': pid as Object,
      'authorid': replyMeta.authorid as Object,
      'type': replyMeta.type as Object,
      'postdate': '' as Object,
      'subject': replySubject as Object,
      'content': replyContent as Object,
    };
    entry['__P'] = __P as Object;
  }

  return entry;
}

/**
 * 将 NGA thread.php 主题列表 HTML 解析为与 JSON API 相同形状的对象。
 *
 * @param html NGA thread.php 页面 HTML
 * @returns 形如 { data: { __T, __F, __ROWS, __T__ROWS_PAGE, __PAGE } } 的对象，
 *   可直接传入 parseTopicList()
 */
export function parseHtmlTopicListToRawJson(html: string): object {
  const topicArgs: Map<number, TopicArgData> = parseAllTopicArgs(html);
  const pageInfo: PageInfo = extractPageInfo(html);

  const __T: Record<string, Object> = {};
  const keys: number[] = [];
  topicArgs.forEach((_value: TopicArgData, key: number): void => {
    keys.push(key);
  });
  keys.sort((a: number, b: number): number => a - b);

  for (let i: number = 0; i < keys.length; i++) {
    const rowIndex: number = keys[i];
    const arg: TopicArgData | undefined = topicArgs.get(rowIndex);
    if (!arg || arg.tid === 0) {
      continue;
    }
    __T[String(rowIndex)] = buildTopicEntry(arg, rowIndex, html) as Object;
  }

  // __ROWS 降级：总页数已知时按 总页数 × 每页行数 估计；否则用本页行数
  const pageRows: number = keys.length;
  const totalRows: number = pageInfo.totalPages > 0
    ? pageInfo.totalPages * pageInfo.rowsPerPage
    : pageRows;

  const __F: Record<string, Object> = {};

  const data: Record<string, Object> = {
    '__T': __T as Object,
    '__F': __F as Object,
    '__ROWS': totalRows as Object,
    '__T__ROWS_PAGE': pageInfo.rowsPerPage as Object,
    '__PAGE': pageInfo.currentPage as Object,
  };

  const result: Record<string, Object> = {
    'data': data as Object,
  };

  return result as Object;
}
