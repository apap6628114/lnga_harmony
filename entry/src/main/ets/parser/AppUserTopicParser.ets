/**
 * 官方 APP 用户主题列表解析（用户主页「TA 的主题/回帖」）。
 *
 * 官方接口（POST+sign，signParams=uid，__output=12）与 thread.php 网页版不同，
 * 本模块负责：
 *  - 候选接口清单（发帖 subjects 主 + load_topic_by_uid 兜底；回帖 replys）
 *  - result 三种形状兼容（数组 / {data:[...]} / 数字键字典）
 *  - 条目字段归一化（forumname→parent、post→__P，与 thread.php 的 __T 元素同形状）
 *  - 分页信息解析（服务端可选返回 totalPage/total/currentPage/perPage；
 *    缺失时按「乐观页数」编码：非空页 totalPages=page+1，真空页 totalPages=page）
 *
 * 数据完整原则：本层只做形状归一化与结构解析，**不过滤任何条目**——
 * 占位/受限条目（authorid=0、「帖子发布或回复时间超过限制」等）是官方接口返回的
 * 有效数据，原样保留并携带 attachs/error 等原始字段，是否展示/如何处理由 UI 层决策。
 *
 * 纯函数模块，不依赖 AppStore / 网络，可直接被 Hypium Local Test 覆盖。
 */

import { parseTopicList } from './TopicParser'
import type { TopicListInfo } from '../model/Topic'

/**
 * 官方 APP 用户主题列表接口候选。
 */
export interface AppUserListEndpoint {
  /** 接口路径（/nuke.php 或 /app_api.php）。 */
  path: string;
  /** __lib 值。 */
  lib: string;
  /** __act 值。 */
  act: string;
  /** 支持的最大页码：0=支持任意页；>0=不支持分页（仅第 1 页）。 */
  maxPage: number;
}

/**
 * 按查询类型返回官方用户主题列表接口候选（回帖 / 发帖主通道+兜底）。
 *
 * 发帖主通道 app_api.php user/subjects（支持分页 35/页，字段含 author/forumname/
 * replies/lastposter，与回帖 replys 同源同构；官方老封装 kt.c.q0 亦走此入口）；
 * 兜底 nuke.php load_topic/load_topic_by_uid（实测不支持分页——page 参数被忽略、
 * 恒返回同一批主题，故仅第 1 页使用，且 result 为数字键字典而非数组）。
 *
 * @param searchpost - true=回帖记录，false=发帖记录
 * @returns 候选接口列表（按优先级排序）
 */
export function appUserListEndpoints(searchpost: boolean): AppUserListEndpoint[] {
  if (searchpost) {
    const ep: AppUserListEndpoint = { path: '/app_api.php', lib: 'user', act: 'replys', maxPage: 0 };
    return [ep];
  }
  const primary: AppUserListEndpoint = { path: '/app_api.php', lib: 'user', act: 'subjects', maxPage: 0 };
  const fallback: AppUserListEndpoint = { path: '/nuke.php', lib: 'load_topic', act: 'load_topic_by_uid', maxPage: 1 };
  return [primary, fallback];
}

/**
 * 把官方接口返回的单个主题条目归一化为 parseTopicList 兼容形状。
 *
 * 官方接口字段与 thread.php 的 __T 元素存在差异，此处补齐：
 *  - 版面名：thread.php 在 parent['2']，官方接口在 forumname → 构造 parent
 *  - 回帖楼层：thread.php 在 __P，官方 replys 在 post → 构造 __P（含 pid/content/
 *    postdate，供回帖列表 pid 定位与摘要预览）
 *  - author/lastposter/replies 官方接口已有同名键，直接透传
 *  - attachs/error 等原始字段透传保留，供 UI 层识别受限/占位条目
 *
 * 不做业务过滤：authorid=0、受限占位文案等条目原样归一化返回。
 *
 * @param item - 官方接口条目
 * @returns 归一化条目（与输入条目一一对应）
 */
export function normalizeAppUserTopicItem(item: Record<string, Object>): Record<string, Object> {
  const out: Record<string, Object> = {};
  out['tid'] = item['tid'] ?? '';
  out['fid'] = item['fid'] ?? 0;
  out['subject'] = String(item['subject'] ?? '');
  out['type'] = item['type'] ?? 0;
  out['postdate'] = normalizeTimestamp(item['postdate']);
  out['author'] = item['author'] ?? '';
  out['authorid'] = item['authorid'] ?? 0;
  out['lastposter'] = item['lastposter'] ?? '';
  out['replies'] = item['replies'] ?? 0;
  out['attachs'] = item['attachs'] ?? '';
  out['error'] = item['error'] ?? '';
  const forumName: string = String(item['forumname'] ?? '');
  if (forumName.length > 0) {
    const parent: Record<string, Object> = {};
    parent['2'] = forumName;
    out['parent'] = parent;
  }
  const post: Object | undefined = item['post'];
  if (post !== undefined && post !== null && typeof post === 'object' && !Array.isArray(post)) {
    const postRec: Record<string, Object> = post as Record<string, Object>;
    const p: Record<string, Object> = {};
    p['pid'] = postRec['pid'] ?? 0;
    p['content'] = postRec['content'] ?? '';
    p['postdate'] = normalizeTimestamp(postRec['postdate']);
    p['subject'] = postRec['subject'] ?? '';
    p['authorid'] = postRec['authorid'] ?? 0;
    p['tid'] = postRec['tid'] ?? 0;
    out['__P'] = p;
  }
  return out;
}

/**
 * 归一化时间戳：数字透传；空串/缺失/非法值归 0。
 *
 * 实测 replys 的 post.postdate 可能为字符串空串，直接 `?? 0` 不会替换空串。
 *
 * @param value - 原始时间戳值
 * @returns 数字时间戳（非法为 0）
 */
function normalizeTimestamp(value: Object | undefined): number {
  const num: number = Number(value ?? 0);
  return Number.isFinite(num) && num > 0 ? num : 0;
}

/**
 * 从官方接口响应中提取原始主题条目数组（未归一化）。
 *
 * 兼容三种 result 形状（实测确认）：
 *  - 数组（部分接口直接返回数组）
 *  - `{data: [...]}`（app_api.php user/subjects、user/replys；data 为空数组 =
 *    真空页，与「满页占位」区分）
 *  - 数字键字典 `{"0": {...}, "1": {...}}`（nuke.php load_topic/load_topic_by_uid，
 *    键为列表位置索引，含被删条目占位空隙）
 *
 * @param raw - 官方接口响应
 * @returns 原始条目数组；接口业务失败（code!=0）或形状不可识别时返回 null。
 *   空数组表示接口成功但本页无任何条目。
 */
export function extractAppUserRawItems(raw: object): Object[] | null {
  const rec: Record<string, Object> = raw as Record<string, Object>;
  const code: number = Number(rec['code'] ?? 0);
  if (code !== 0) {
    return null;
  }
  const res: Object | undefined = rec['result'];
  if (res === undefined || res === null) {
    return null;
  }
  if (Array.isArray(res)) {
    return collectAppUserItemObjects(res as Object[]);
  }
  if (typeof res !== 'object') {
    return null;
  }
  const resRec: Record<string, Object> = res as Record<string, Object>;
  const data: Object | undefined = resRec['data'];
  if (Array.isArray(data)) {
    return collectAppUserItemObjects(data as Object[]);
  }
  const keys: string[] = Object.keys(resRec);
  if (keys.length === 0) {
    return [];
  }
  const dictItems: Object[] = [];
  for (let i = 0; i < keys.length; i++) {
    const v: Object | undefined = resRec[keys[i]];
    if (v !== undefined && v !== null && typeof v === 'object' && !Array.isArray(v)) {
      dictItems.push(v);
    }
  }
  return dictItems;
}

/**
 * 从数组中收集可解析为主题条目的对象元素（跳过 null/原始值/嵌套数组）。
 *
 * 仅做结构收窄，不做业务过滤：占位/受限条目照常保留。
 *
 * @param arr - 原始数组
 * @returns 对象元素列表
 */
function collectAppUserItemObjects(arr: Object[]): Object[] {
  const items: Object[] = [];
  for (let i = 0; i < arr.length; i++) {
    const v: Object | undefined = arr[i];
    if (v !== undefined && v !== null && typeof v === 'object' && !Array.isArray(v)) {
      items.push(v);
    }
  }
  return items;
}

/**
 * 从官方接口响应中提取主题条目列表（归一化后）。
 *
 * 不做业务过滤：占位/受限条目原样保留，与接口返回一一对应。
 *
 * @param raw - 官方接口响应
 * @returns 归一化后的条目数组；接口业务失败（code!=0）或形状不可识别时返回 null。
 *   空数组表示接口成功但本页无任何条目。
 */
export function extractAppUserTopicItems(raw: object): Record<string, Object>[] | null {
  const arr: Object[] | null = extractAppUserRawItems(raw);
  if (arr === null) {
    return null;
  }
  const items: Record<string, Object>[] = [];
  for (let i = 0; i < arr.length; i++) {
    items.push(normalizeAppUserTopicItem(arr[i] as Record<string, Object>));
  }
  return items;
}

/**
 * 把官方用户主题接口响应解析为与 thread.php 同形状的 TopicListInfo。
 *
 * 分页信息解析（实测服务端**两种位置都可能返回**分页字段，且值可能为 string）：
 *  - 响应顶层 raw.totalPage（如 subjects 对大户用户：顶层 totalPage=23/total=776/
 *    currentPage/perPage，result 仅 data）与 result.totalPage（鸿蒙端实测形态：
 *    result 内含 data+totalPage）——两层都读，取非零者
 *  - totalPage>0 → 直接作为总页数（权威值）
 *  - 缺失 totalPage 时：
 *    - maxPage>0（调用方声明接口不分页，如 load_topic_by_uid）→ totalPages=page
 *    - 本页条目数组为空（真空页）→ totalPages=page（已到底）
 *    - 本页条目数组非空（含满页占位）→ totalPages=page+1（乐观，继续翻页直到真空页）
 *  - 业务失败（code!=0）→ 返回 null（任何页均走错误态，不伪装成"到底"）
 *  - 形状不可识别（code==0 但 result 无法解析）：第 1 页返回 null（调用方尝试兜底
 *    接口）；翻页请求视为已到底（服务端越界形态，totalPages=page）
 *
 * @param raw - 官方接口响应
 * @param blacklist - 用户黑名单 UID
 * @param keywords - 标题屏蔽关键词
 * @param page - 当前页码
 * @param maxPage - 调用方接口候选的最大页码（0=支持任意页；>0=不分页接口）
 * @returns 主题列表信息；业务失败或第 1 页形状不可识别时返回 null
 */
export function parseAppUserTopicList(raw: object, blacklist: Set<string>, keywords: string[],
  page: number, maxPage: number = 0): TopicListInfo | null {
  const rec: Record<string, Object> = raw as Record<string, Object>;
  // 业务失败（code!=0）在任何页码都返回 null，由调用方呈现错误/回落，不得伪装"到底"
  const code: number = Number(rec['code'] ?? 0);
  if (code !== 0) {
    return null;
  }
  const rawArr: Object[] | null = extractAppUserRawItems(raw);
  if (rawArr === null) {
    if (page > 1) {
      return buildAppTopicListInfo([], page, blacklist, keywords, page);
    }
    return null;
  }
  // totalPage 两层兼容：响应顶层优先（实测 subjects 大户形态），result 内回退
  let totalPage: number = Number(rec['totalPage'] ?? 0) || 0;
  if (totalPage <= 0) {
    const resRec: Record<string, Object> | undefined =
      rec['result'] as Record<string, Object> | undefined;
    if (resRec !== undefined && resRec !== null && typeof resRec === 'object' && !Array.isArray(resRec)) {
      totalPage = Number(resRec['totalPage'] ?? 0) || 0;
    }
  }
  const items: Record<string, Object>[] = [];
  for (let i = 0; i < rawArr.length; i++) {
    items.push(normalizeAppUserTopicItem(rawArr[i] as Record<string, Object>));
  }
  if (totalPage > 0) {
    return buildAppTopicListInfo(items, totalPage, blacklist, keywords, page);
  }
  if (maxPage > 0) {
    // 调用方声明接口不分页（如 load_topic_by_uid）：第 1 页即到底
    return buildAppTopicListInfo(items, page, blacklist, keywords, page);
  }
  if (rawArr.length === 0) {
    return buildAppTopicListInfo(items, page, blacklist, keywords, page);
  }
  return buildAppTopicListInfo(items, page + 1, blacklist, keywords, page);
}

/**
 * 以指定总页数构造与 parseTopicList 兼容的 TopicListInfo。
 *
 * @param items - 归一化条目（数字键入 __T）
 * @param totalPages - 总页数（编码进 __ROWS/__T__ROWS_PAGE）
 * @param blacklist - 用户黑名单 UID
 * @param keywords - 标题屏蔽关键词
 * @param page - 当前页码
 * @returns 主题列表信息
 */
function buildAppTopicListInfo(items: Record<string, Object>[], totalPages: number,
  blacklist: Set<string>, keywords: string[], page: number): TopicListInfo {
  const t: Record<string, Object> = {};
  for (let i = 0; i < items.length; i++) {
    t[String(i)] = items[i];
  }
  const dataObj: Record<string, Object> = {};
  dataObj['__T'] = t;
  /**
   * rowsPerPage=1：calcPagination 得 totalPages = ceil(totalPages/1) = totalPages。
   */
  dataObj['__ROWS'] = totalPages;
  dataObj['__T__ROWS_PAGE'] = 1;
  const fakeRaw: Record<string, Object> = {};
  fakeRaw['data'] = dataObj;
  fakeRaw['time'] = 0;
  return parseTopicList(fakeRaw, blacklist, keywords, page);
}
