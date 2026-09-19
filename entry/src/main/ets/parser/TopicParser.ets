import type { TopicRaw, ThreadPageInfo, TopicListInfo, Pagination } from '../model/Topic';
import type { ImageSize } from '../common/media/ImageSizeUtil';
import { decodeAnonymousName } from './AnonymousParser';
import { parsePreviewImages, parsePreviewSize, isPreviewImage } from '../common/utils/TopicPreviewUtils';

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
  /* 附件前缀：官方 subject 系响应由 AppSubjectListParser 透传进 fakeRaw；
     缺失（thread.php 形状 / 置顶/搜索/收藏/用户列表）时为空串，
     parsePreviewImages 会回退 NGA_CDN_BASE——那些入口本就没有 attachs。 */
  const attachPrefix = String(rawObj?.['attachPrefix'] ?? '');

  const keys = Object.keys(tMap);
  for (const key of keys) {
    const t = tMap[key] as Record<string, Object>;
    if (!t || !t['tid']) continue;
    if (hasKeywordMatch(String(t['subject'] ?? ''), keywords)) continue;
    topics.push(mapTopicRaw(t, blacklist.has(String(t['authorid'])), attachPrefix));
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
 * @param attachPrefix - 附件图片前缀（响应 attachPrefix，可为空串）
 * @returns 页面主题模型
 */
function mapTopicRaw(raw: Record<string, Object>, isInBlackList: boolean,
  attachPrefix: string): ThreadPageInfo {
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

  // 首帖附件 → 预览图（拼接前缀、过滤非图片；无附件时为空数组）
  const previewImages: string[] = parsePreviewImages(raw['attachs'], attachPrefix);
  // 首图真实尺寸：在**解析期**算定，卡片高度因此是静态值（见 model/Topic.ets 的字段说明）。
  // 这里回到**原始 attachurl** 上解码尺寸段而不是在预览 URL 上解：后者虽同为绝对 URL
  // （正则匹配文件名，与路径无关），但原始值永远没有 query/fragment 干扰，少一层守卫。
  // 空值统一取 `undefined`（字段可选类型是 `ImageSize | undefined`，UI 侧对两者都判）。
  const firstAttach: string = firstAttachUrl(raw['attachs']);
  const parsedSize: ImageSize | null = parsePreviewSize(firstAttach);
  const previewSize: ImageSize | undefined = parsedSize === null ? undefined : parsedSize;

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
    previewImages: previewImages,
    previewSize: previewSize,
    // 官方接口受限/占位条目的受限原因透传（普通 thread.php 列表无此字段，为空串）
    error: String(raw['error'] ?? ''),
  };
}

/**
 * 取 `attachs` 数组中**第一张图片附件**的原始 `attachurl`。
 *
 * 与 `parsePreviewImages` 的过滤口径保持一致（同一个 `isPreviewImage` 白名单），否则会出现
 * "卡片显示了 A 图的 URL、却拿 B 图的尺寸"这种错位。这里只回答"首图是谁"，不做前缀拼接。
 *
 * @param rawAttachs - 原始 attachs 值
 * @returns 首图 attachurl；无可用图片时为空串
 */
function firstAttachUrl(rawAttachs: Object | null | undefined): string {
  if (rawAttachs === undefined || rawAttachs === null || !Array.isArray(rawAttachs)) {
    return '';
  }
  const arr: Object[] = rawAttachs as Object[];
  for (let i = 0; i < arr.length; i++) {
    const item: Object = arr[i];
    if (item === undefined || item === null || typeof item !== 'object' || Array.isArray(item)) {
      continue;
    }
    const attachurl: string = String((item as Record<string, Object>)['attachurl'] ?? '');
    if (isPreviewImage(attachurl)) {
      return attachurl;
    }
  }
  return '';
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
