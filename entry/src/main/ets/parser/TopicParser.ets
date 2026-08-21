import type { TopicRaw, ThreadPageInfo, TopicListInfo, Pagination } from '../model/Topic';
import type { SubBoard } from '../model/Forum';
import { decodeAnonymousName } from './AnonymousParser';
import { NGA_IMG4_BASE } from '../common/constants/NgaDomains';

/**
 * 子版块 ID 的 NGA 表示形式。
 */
type SubBoardIdKind = 'fid' | 'stid';

/**
 * MNGA 根据 NGA 子版块 attributes 字段识别出的“当前显示”状态值。
 */
const SELECTED_SUB_BOARD_ATTRIBUTES: Set<number> = new Set<number>([7, 558, 542, 2606, 2590, 4654]);

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
    subBoardList: parseSubBoards(forumInfo),
    curTime: Number(rawObj?.['time'] ?? 0),
    pagination: calcPagination(totalRows, rowsPerPage, currentPage),
  };
}

/**
 * 解析父版块返回的子版块关系。
 *
 * NGA 的 lite JSON 在不同入口下可能把 sub_forums 表示为数组、数字键对象，
 * 或按 item/其他节点名再分组。这里按 MNGA 对 XML 节点的解释兼容这些表示。
 *
 * @param forumInfo - NGA 响应中的 __F 对象
 * @returns 去重后的子版块列表
 */
export function parseSubBoards(forumInfo: Record<string, Object> | undefined): SubBoard[] {
  const result: SubBoard[] = [];
  const seen: Set<string> = new Set<string>();
  const rawSubBoards: Object | undefined = forumInfo?.['sub_forums'] ?? forumInfo?.['subForums'];
  collectSubBoards(rawSubBoards, 'stid', result, seen);
  return result;
}

/**
 * 递归收集 NGA 多种 JSON 形态下的子版块条目。
 *
 * @param raw - 当前待解析节点
 * @param idKind - 当前节点推断出的 ID 类型
 * @param result - 解析结果
 * @param seen - 去重键集合
 */
function collectSubBoards(raw: Object | undefined, idKind: SubBoardIdKind,
  result: SubBoard[], seen: Set<string>): void {
  if (raw === undefined || raw === null) return;

  const parsed: SubBoard | null = parseSubBoardEntry(raw, idKind);
  if (parsed !== null) {
    const key: string = parsed.filterId.length > 0
      ? parsed.filterId
      : `${parsed.fid}:${parsed.stid}:${parsed.name}`;
    if (!seen.has(key)) {
      seen.add(key);
      result.push(parsed);
    }
    return;
  }

  if (Array.isArray(raw)) {
    const values: Object[] = raw as Object[];
    for (let i = 0; i < values.length; i++) {
      collectSubBoards(values[i], idKind, result, seen);
    }
    return;
  }

  if (typeof raw !== 'object') return;
  const record: Record<string, Object> = raw as Record<string, Object>;
  const keys: string[] = Object.keys(record);
  for (let i = 0; i < keys.length; i++) {
    const key: string = keys[i];
    // 子版块字典的数字键（如 "124"）与合集键（如 "t25124476"）的数组值
    // 第一个元素是 fid（官方 thread.php 实测/卡片 R2：{key: [fid, 名称, 简介,
    // tid, 类型位]}），按 fid 解析；item/fid 分组同 fid，stid 分组显式 stid。
    const isNumericKey: boolean = /^\d+$/.test(key);
    const isTopicKey: boolean = key.startsWith('t') && /^\d+$/.test(key.slice(1));
    const childKind: SubBoardIdKind = key === 'item' || key === 'fid'
      || isNumericKey || isTopicKey ? 'fid'
      : key === 'stid' ? 'stid' : idKind;
    collectSubBoards(record[key], childKind, result, seen);
  }
}

/**
 * 尝试把单个数组或数字键对象解析为子版块。
 *
 * @param raw - 候选条目
 * @param fallbackIdKind - 无显式 ID 字段时采用的类型
 * @returns 子版块；不是候选条目时返回 null
 */
function parseSubBoardEntry(raw: Object, fallbackIdKind: SubBoardIdKind): SubBoard | null {
  const record: Record<string, Object> | null = toRecord(raw);
  const values: Object[] | null = toPositionalValues(raw, record);
  if (values === null && record === null) return null;

  const explicitFid: Object | undefined = record?.['fid'];
  const explicitStid: Object | undefined = record?.['stid'];
  const idValue: Object | undefined = explicitFid ?? explicitStid
    ?? record?.['id'] ?? values?.[0];
  const nameValue: Object | undefined = record?.['name'] ?? values?.[1];
  const descriptionValue: Object | undefined = record?.['info']
    ?? record?.['description'] ?? values?.[2];
  const filterIdValue: Object | undefined = record?.['filter_id']
    ?? record?.['filterId'] ?? values?.[3];
  const attributesValue: Object | undefined = record?.['attributes']
    ?? record?.['attribute'] ?? record?.['bit'] ?? values?.[4];

  if (idValue === undefined || nameValue === undefined || filterIdValue === undefined
    || attributesValue === undefined) {
    return null;
  }

  const id: number = Number(idValue);
  const name: string = String(nameValue);
  const filterId: string = String(filterIdValue);
  const attributes: number = Number(attributesValue);
  if (!Number.isFinite(id) || name.length === 0 || !Number.isFinite(attributes)) return null;

  const idKind: SubBoardIdKind = explicitFid !== undefined ? 'fid'
    : explicitStid !== undefined ? 'stid' : fallbackIdKind;
  const fid: number = idKind === 'fid' ? id : 0;
  const stid: number = idKind === 'stid' ? id : 0;

  return {
    fid,
    stid,
    name,
    boardHead: `${NGA_IMG4_BASE}/ngabbs/nga_classic/f/app/${id}.png`,
    tidStr: filterId,
    type: attributes,
    checked: SELECTED_SUB_BOARD_ATTRIBUTES.has(attributes),
    description: descriptionValue === undefined ? '' : String(descriptionValue),
    parentFidStr: '',
    filterId,
    attributes,
    filterable: attributes > 40,
  };
}

/**
 * 将未知对象收窄为普通键值对象。
 *
 * @param raw - 待收窄值
 * @returns 普通键值对象；数组或原始值返回 null
 */
function toRecord(raw: Object): Record<string, Object> | null {
  if (Array.isArray(raw) || typeof raw !== 'object' || raw === null) return null;
  return raw as Record<string, Object>;
}

/**
 * 从数组或数字键对象读取 MNGA 使用的五个位置字段。
 *
 * @param raw - 候选条目
 * @param record - 已收窄的普通对象
 * @returns 五个位置字段；当前节点不是条目时返回 null
 */
function toPositionalValues(raw: Object, record: Record<string, Object> | null): Object[] | null {
  if (Array.isArray(raw)) {
    const values: Object[] = raw as Object[];
    if (values.length >= 5 && isScalar(values[0])) return values;
    return null;
  }
  if (record === null) return null;

  const values: Object[] = [];
  for (let i = 0; i < 5; i++) {
    const value: Object | undefined = record[String(i)] ?? record[`_${i}`];
    if (value === undefined) return null;
    values.push(value);
  }
  return values;
}

/**
 * 判断值能否作为子版块位置字段中的标量。
 *
 * @param value - 待检查值
 * @returns 是否为字符串或数字
 */
function isScalar(value: Object): boolean {
  return typeof value === 'string' || typeof value === 'number';
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
