import type { TopicRaw, ThreadPageInfo, TopicListInfo, Pagination } from '../model/Topic';
import { decodeAnonymousName } from './AnonymousParser';

/**
 * 判断内容是否命中关键词屏蔽规则。
 *
 * @param content - 待检查文本
 * @param keywords - 屏蔽关键词
 * @returns 是否命中
 */
function hasKeywordMatch(content: string, keywords: string[]): boolean {
  for (let i = 0; i < keywords.length; i++) {
    if (content.includes(keywords[i])) {
      return true
    }
  }
  return false
}

/**
 * 从 NGA 主题列表响应解析主题、子版块和分页信息。
 *
 * 子版块列表（subBoardList）由官方 subject/list 解析器
 * （AppSubjectListParser.parseSubjectSubBoards，subForum.checked 账号级真实
 * 订阅状态）填充；本通用解析器的输入（thread.php __T 形状）不含 subForum，
 * 恒返回空列表。
 *
 * @param raw - NGA 原始响应
 * @param blacklist - 用户黑名单 UID
 * @param keywords - 标题屏蔽关键词
 * @param currentPage - 当前页码
 * @returns 主题列表信息
 */
export function parseTopicList(raw: object | null, blacklist: Set<string> = new Set(),
  keywords: string[] = [], currentPage: number = 1): TopicListInfo {
  const topics: ThreadPageInfo[] = [];
  const rawObj = raw as Record<string, Object>;
  const dataObj = rawObj?.['data'] as Record<string, Object> | undefined;
  const tMap = dataObj?.['__T'] as Record<string, Object> ?? {};
  const totalRows = Number(dataObj?.['__ROWS'] ?? 0);
  const rowsPerPage = Number(dataObj?.['__T__ROWS_PAGE'] ?? 35);

  const keys = Object.keys(tMap);
  for (const key of keys) {
    const t = tMap[key] as Record<string, Object>;
    if (!t || !t['tid']) continue;
    if (hasKeywordMatch(String(t['subject'] ?? ''), keywords)) continue;
    topics.push(mapTopicRaw(t, blacklist.has(String(t['authorid']))));
  }

  const forumInfo = dataObj?.['__F'] as Record<string, Object>;

  return {
    name: String(forumInfo?.['name'] ?? ''),
    threadPageList: topics,
    subBoardList: [],
    curTime: Number(rawObj?.['time'] ?? 0),
    pagination: calcPagination(totalRows, rowsPerPage, currentPage),
  };
}

/**
 * 去除主题摘要中的基础标记。
 *
 * @param text - 原始摘要
 * @returns 纯文本摘要
 */
function stripBasic(text: string): string {
  let s = text;
  s = s.replace(/\[quote\][\s\S]*?\[\/quote\]/gi, '');
  s = s.replace(/\[\/?(?:pid|uid|tid|b|i|u|del|h|url|color|size|font|collapse|code|img)\d*[^\]]*\]/gi, '');
  s = s.replace(/\[s:\w+:\w+\]/g, '');
  s = s.replace(/<[^>]+>/g, '');
  s = s.replace(/https?:\/\/\S+/g, '');
  s = s.replace(/\s+/g, ' ').trim();
  return s;
}

/**
 * 将 NGA 原始主题映射为页面模型。
 *
 * @param raw - 原始主题
 * @param isInBlackList - 作者是否在黑名单中
 * @returns 页面主题模型
 */
function mapTopicRaw(raw: Record<string, Object>, isInBlackList: boolean): ThreadPageInfo {
  const __P = raw['__P'] as Record<string, Object> | undefined;
  const rawAuthor: string = String(raw['author'] ?? '');
  const isAnonymity: boolean = rawAuthor.startsWith('#anony_');
  const author: string = isAnonymity ? decodeAnonymousName(rawAuthor) : rawAuthor;

  let replyContent: string = '';
  let snippet: string = '';
  if (__P) {
    replyContent = String(__P['content'] ?? '');
    snippet = stripBasic(replyContent).slice(0, 150);
  }

  const parent = raw['parent'] as Record<string, Object> | undefined;
  const board: string = parent?.['2'] ? String(parent['2']) : '';

  return {
    tid: Number(raw['tid']),
    fid: Number(raw['fid']),
    author: author,
    authorId: Number(raw['authorid']),
    isInBlackList: isInBlackList,
    lastPoster: String(raw['lastposter'] ?? ''),
    replies: Number(raw['replies'] ?? 0),
    subject: String(raw['subject'] ?? ''),
    titleFont: String(raw['titlefont'] ?? ''),
    type: Number(raw['type'] ?? 0),
    topicMisc: String(raw['topic_misc'] ?? ''),
    page: 0,
    pid: Number(__P?.['pid'] ?? 0),
    position: 0,
    isAnonymity: isAnonymity,
    postDate: Number(raw['postdate'] ?? 0),
    replyInfo: __P ? {
      pidStr: String(__P['pid'] ?? ''),
      content: replyContent,
      subject: String(__P['subject'] ?? ''),
      postDate: String(__P['postdate'] ?? ''),
      authorId: String(__P['authorid'] ?? ''),
      tidStr: String(__P['tid'] ?? ''),
    } : {
      pidStr: '',
      content: '',
      subject: '',
      postDate: '',
      authorId: '',
      tidStr: '',
    },
    board: board,
    mirrorBoard: board === '版面镜像',
    previewAuthorId: String(__P?.['authorid'] ?? ''),
    previewSnippet: snippet,
    previewImages: [],
    // 官方接口受限/占位条目的受限原因透传（普通 thread.php 列表无此字段，为空串）
    attachs: String(raw['attachs'] ?? ''),
    error: String(raw['error'] ?? ''),
  };
}

/**
 * 计算主题列表分页信息。
 *
 * @param totalRows - 总主题数
 * @param rowsPerPage - 每页主题数
 * @param currentPage - 当前页码
 * @returns 分页信息
 */
export function calcPagination(totalRows: number, rowsPerPage: number, currentPage: number): Pagination {
  // rowsPerPage 缺失/异常时按 1 页兜底，避免除零产生 Infinity 页数
  const safeRowsPerPage: number = rowsPerPage > 0 ? rowsPerPage : Math.max(1, totalRows)
  return {
    page: currentPage,
    totalPages: Math.ceil(totalRows / safeRowsPerPage),
    totalRows,
  };
}
