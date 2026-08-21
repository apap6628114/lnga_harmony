/**
 * NGA 版块 API - 版块分类、版块搜索、主题列表
 */

import { ngaClient, Cookies } from '../NgaClient';
import { appStore } from '../../store/AppStore';
import { parseForumCategories, parseForumSearch } from '../../parser/ForumParser';
import { parseTopicList } from '../../parser/TopicParser';
import { parseNgaError } from '../../parser/ErrorParser';
import { parseTopicListHtmlTask } from '../../parser/task/TopicListHtmlParseTask';
import { taskpool } from '@kit.ArkTS';
import { ApiResult, CategoriesResult, TopicListResult, SearchForumResult } from '../../model/NgaApiResults';
import type { TopicListInfo } from '../../model/Topic';
import { appUserListEndpoints, parseAppUserTopicList } from '../../parser/AppUserTopicParser';
import type { AppUserListEndpoint } from '../../parser/AppUserTopicParser';
import { Logger, DOMAIN_SERVICE, formatError } from '../../common/utils/Logger';

const logger = new Logger(DOMAIN_SERVICE, 'ForumApi')

// ============== 版块分类 ==============

export async function getForumCategories(token: string): Promise<CategoriesResult> {
  const result = new CategoriesResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    const params: Record<string, string> = { '__lib': 'home', '__act': 'category' };
    const raw = await ngaClient.get('/app_api.php', params, { uid: session.uid, cid: session.cid });
    result.data = parseForumCategories(raw as object);
    result.ok = true;
  } catch (e) {
    logger.warn('获取板块分类失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '获取板块分类失败';
  }
  return result;
}

export async function searchForum(token: string, key: string): Promise<SearchForumResult> {
  const result = new SearchForumResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    const params: Record<string, string> = { '__output': '8', 'key': key };
    // 走默认通道（https + 失败时按 DOMAINS 轮换备用域），与 getTopicList 一致
    const raw = await ngaClient.get('/forum.php', params, { uid: session.uid, cid: session.cid });
    result.data = parseForumSearch(raw as object);
    result.ok = true;
  } catch (e) {
    logger.warn('搜索失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '搜索失败';
  }
  return result;
}

// ============== 帖子列表 ==============

export interface TopicListParams {
  fid: string;
  stid: string;
  page: string;
  key: string;
  author: string;
  authorid: string;
  favor: string;
  recommend: string;
  orderBy: string;
  searchpost: string;
  content: string;
  fidgroup: string;
}

export function createTopicListParams(): TopicListParams {
  return {
    fid: '', stid: '', page: '1', key: '', author: '', authorid: '',
    favor: '', recommend: '', orderBy: '', searchpost: '', content: '', fidgroup: '',
  };
}

/**
 * 构建 thread.php 主题列表查询参数（JSON 主通道与 HTML 降级通道共用同一语义）。
 *
 * 仅服务普通版面/搜索列表；用户发帖/回帖历史（authorid/searchpost）与收藏夹内
 * 主题列表（favor）已由官方 APP 签名接口承载（见 getAppUserTopicList 与
 * getAppFavoriteTopicList），不再进入 thread.php 通道。
 *
 * 差异仅在通道标志：JSON 通道需 `lite=js&noprefix`（script store 包裹），
 * HTML 降级走静态页（topicArg.add 元数据），其余筛选/排序参数完全一致。
 *
 * @param params 页面层主题列表参数
 * @param forJson true=JSON 通道（lite=js+noprefix），false=HTML 降级（静态页）
 * @returns thread.php 查询参数
 */
function buildThreadQuery(params: TopicListParams, forJson: boolean): Record<string, string> {
  const query: Record<string, string> = {
    'page': params.page || '1',
  };
  if (forJson) {
    query['lite'] = 'js';
    query['noprefix'] = '';
  }

  if (params.content) query['content'] = params.content;

  if (params.author) {
    query['author'] = params.author;
  } else {
    if (params.stid) query['stid'] = params.stid;
    else if (params.fid && params.fid !== '-1') query['fid'] = params.fid;
    if (params.key) query['key'] = params.key;
    if (params.fidgroup) query['fidgroup'] = params.fidgroup;
  }

  if (params.recommend) {
    query['recommend'] = params.recommend;
    query['order_by'] = 'postdatedesc';
    query['user'] = '1';
  } else if (params.orderBy) {
    // 与 recommend 互斥（TopicListPanel 侧不会同时设置），避免 order_by 被覆盖后残留 user 参数
    query['order_by'] = params.orderBy;
  }
  return query;
}

/**
 * 使用官方 APP 签名接口抓取用户发帖/回帖主题列表（用户主页「TA 的主题/回帖」）。
 *
 * 候选接口与响应解析（result 三种形状兼容、字段归一化、分页「乐观页数」编码）
 * 见 parser/AppUserTopicParser（纯函数模块）。失败（全部候选接口均失败）返回 null，
 * 由调用方以错误态呈现（不再回落 thread.php）。
 */
async function getAppUserTopicList(token: string, params: TopicListParams,
  blacklist: Set<string>, keywords: string[]): Promise<TopicListInfo | null> {
  const session = appStore.getSession(token);
  if (!session) {
    return null;
  }
  const cookies: Cookies = { uid: session.uid, cid: session.cid };
  const authorid: string = params.authorid;
  const page: number = Number(params.page || '1') || 1;
  const endpoints: AppUserListEndpoint[] = appUserListEndpoints(params.searchpost.length > 0);
  for (let i = 0; i < endpoints.length; i++) {
    const ep: AppUserListEndpoint = endpoints[i];
    if (ep.maxPage > 0 && page > ep.maxPage) {
      continue;
    }
    try {
      const appParams: Record<string, string> = { 'uid': authorid, 'page': String(page) };
      const raw: Record<string, Object> = await ngaClient.postSigned(ep.path, ep.lib, ep.act,
        appParams, cookies, authorid, '12') as Record<string, Object>;
      // maxPage 透传：不分页接口（load_topic_by_uid）第 1 页即到底，不诱导翻页
      const info: TopicListInfo | null = parseAppUserTopicList(raw, blacklist, keywords, page, ep.maxPage);
      if (info !== null) {
        return info;
      }
      logger.warn('[NGA][REQ] 用户列表官方接口无数据(%{public}s/%{public}s page=%{public}d)',
        ep.lib, ep.act, page);
    } catch (e) {
      logger.warn('[NGA][REQ] 用户列表官方接口异常(%{public}s/%{public}s): %{public}s',
        ep.lib, ep.act, formatError(e));
    }
  }
  return null;
}

/**
 * 使用官方 APP 签名接口抓取收藏夹内主题列表（app_api.php favor/all）。
 *
 * 官方接口（POST form + sign，__output=12，signParams 为空）与 thread.php 网页版
 * 不同，实测响应（ngabbs.com）：
 *   {"code":"0","msg":"操作成功",
 *    "result":{"data":[{tid,fid,author,authorid,subject,postdate,lastpost,
 *      lastposter,replies,type,forumname,...}]},
 *    "totalPage":"1","total":"9","currentPage":"1","perPage":"35"}
 * - result.data 直接为主题数组（与 app_api.php user/subjects 同构），分页字段
 *   totalPage/total/currentPage/perPage 在响应顶层（值可能为 string）
 * - 搜索时追加 favkey（官方老封装 kt.c.P0 的 keyword 参数；thread.php 网页版
 *   用 key，参数名不同，勿混）
 * - 解析复用 parseAppUserTopicList（已兼容 result.data + 顶层 totalPage 形状）
 *
 * 网页版通道（thread.php?favor=）已随本次迁移移除，不再降级——官方接口是唯一
 * 通道，失败即返回 null 由调用方以错误态呈现。
 *
 * @param token - 当前应用会话令牌
 * @param params - 页面层主题列表参数（favor 为收藏夹 ID，key 为搜索词）
 * @param blacklist - 用户黑名单 UID
 * @param keywords - 标题屏蔽关键词
 * @returns 主题列表信息；失败时返回 null
 */
async function getAppFavoriteTopicList(token: string, params: TopicListParams,
  blacklist: Set<string>, keywords: string[]): Promise<TopicListInfo | null> {
  const session = appStore.getSession(token);
  if (!session) {
    return null;
  }
  const cookies: Cookies = { uid: session.uid, cid: session.cid };
  const page: number = Number(params.page || '1') || 1;
  const appParams: Record<string, string> = {
    'folder': params.favor,
    'uid': session.uid,
    'page': String(page),
  };
  if (params.key) {
    appParams['favkey'] = params.key;
  }
  try {
    const raw: Record<string, Object> = await ngaClient.postSigned(
      '/app_api.php', 'favor', 'all', appParams, cookies, '', '12') as Record<string, Object>;
    // 业务失败（code!=0）时记录服务端 code/msg 便于诊断（UI 统一呈现「收藏列表加载失败」）
    const code: number = Number(raw['code'] ?? 0)
    if (code !== 0) {
      logger.warn('[NGA][REQ] 收藏夹列表官方接口业务失败(folder=%{public}s page=%{public}d code=%{public}d msg=%{public}s)',
        params.favor, page, code, String(raw['msg'] ?? ''));
      return null;
    }
    const info: TopicListInfo | null = parseAppUserTopicList(raw, blacklist, keywords, page);
    if (info !== null) {
      return info;
    }
    logger.warn('[NGA][REQ] 收藏夹列表官方接口无数据(folder=%{public}s page=%{public}d)',
      params.favor, page);
  } catch (e) {
    logger.warn('[NGA][REQ] 收藏夹列表官方接口异常(folder=%{public}s): %{public}s',
      params.favor, formatError(e));
  }
  return null;
}

export async function getTopicList(token: string, params: TopicListParams,
  blacklist: Set<string> = new Set(),
  keywords: string[] = []): Promise<TopicListResult> {
  const result = new TopicListResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  // 用户主页「TA 的主题/回帖」仅走官方 APP 签名接口（thread.php 网页版通道已移除，
  // 不再降级——官方接口是唯一通道，失败即返回错误）。
  if (params.authorid) {
    const appInfo: TopicListInfo | null = await getAppUserTopicList(token, params, blacklist, keywords);
    if (appInfo) {
      result.data = appInfo;
      result.ok = true;
      return result;
    }
    logger.warn('[NGA][REQ] 用户列表官方接口全部失败(authorid=%{public}s searchpost=%{public}s)',
      params.authorid, params.searchpost);
    result.error = '用户列表加载失败';
    return result;
  }

  // 收藏夹内主题列表仅走官方 APP 签名接口（app_api.php favor/all，thread.php
  // 网页版通道已移除，不再降级——官方接口是唯一通道，失败即返回错误）。
  if (params.favor) {
    const appInfo: TopicListInfo | null = await getAppFavoriteTopicList(token, params, blacklist, keywords);
    if (appInfo) {
      result.data = appInfo;
      result.ok = true;
      return result;
    }
    logger.warn('[NGA][REQ] 收藏夹列表官方接口失败(favor=%{public}s page=%{public}s)',
      params.favor, params.page);
    result.error = '收藏列表加载失败';
    return result;
  }

  let jsonError: string = '';
  try {
    const ngaParams: Record<string, string> = buildThreadQuery(params, true);
    const raw = await ngaClient.get('/thread.php', ngaParams, { uid: session.uid, cid: session.cid }) as Record<string, Object>;
    const error = parseNgaError(raw);
    if (error) {
      jsonError = error;
    } else {
      const dataObj = raw?.['data'] as Record<string, Object> | undefined;
      const page = Number(dataObj?.['__PAGE'] ?? params.page ?? 1);
      result.data = parseTopicList(raw, blacklist, keywords, page);
      result.ok = true;
      return result;
    }
  } catch (e) {
    jsonError = (e as Error).message ?? '获取主题列表失败';
    logger.warn('[NGA][REQ] 主题列表 JSON 请求失败，尝试 HTML 降级: %{public}s', jsonError);
  }

  // HTML 降级：thread.php 静态页（topicArg.add 元数据）→ 与 JSON 同形状 → 复用 parseTopicList
  try {
    const htmlParams: Record<string, string> = buildThreadQuery(params, false);
    const html: string = await ngaClient.getHtmlText('/thread.php', htmlParams,
      { uid: session.uid, cid: session.cid });
    const rawObj: Object = await taskpool.execute(parseTopicListHtmlTask, html);
    const dataObj = (rawObj as Record<string, Object>)?.['data'] as Record<string, Object> | undefined;
    const page = Number(dataObj?.['__PAGE'] ?? params.page ?? 1);
    result.data = parseTopicList(rawObj, blacklist, keywords, page);
    result.ok = true;
    result.viaHtml = true;
    result.jsonError = jsonError;
    // 调试模式：JSON 主通道失败降级为 HTML 解析时弹出提示，便于观察请求通道
    if (result.viaHtml && result.jsonError.length > 0 && appStore.settings.debugMode) {
      appStore.showToast('JSON 接口失败，已降级为 HTML 模式：' + result.jsonError)
    }
    // 降级通道解析不到任何条目时判定失败（JSON 主通道保持原语义）
    if (result.data?.threadPageList.length === 0) {
      result.ok = false;
      result.error = jsonError || '无法加载主题列表';
      if (appStore.settings.debugMode) {
        appStore.showToast('主题列表加载失败（JSON 与 HTML 均失败）：' + result.error)
      }
    }
  } catch (e) {
    logger.warn('[NGA][REQ] 主题列表 HTML 降级失败: %{public}s', formatError(e));
    result.error = jsonError || ((e as Error).message ?? '获取主题列表失败');
    if (appStore.settings.debugMode) {
      appStore.showToast('主题列表加载失败（JSON 与 HTML 均失败）：' + result.error)
    }
  }
  return result;
}

/**
 * 修改父版块中某个子版块的服务器端显示状态。
 *
 * 与 MNGA 保持一致：屏蔽时把 filterId 加入 add_to_block_tids，
 * 恢复显示时从该列表删除，然后由调用方重新加载父版块。
 *
 * @param token - 当前账号令牌
 * @param parentFid - 父版块 fid
 * @param filterId - NGA 子版块筛选标识
 * @param show - 是否在父版块中显示
 * @returns 操作结果
 */
export async function setSubforumFilter(token: string, parentFid: number,
  filterId: string, show: boolean): Promise<ApiResult> {
  const result = new ApiResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }
  if (parentFid === 0 || filterId.length === 0) {
    result.error = '子版块筛选参数无效';
    return result;
  }

  try {
    const operation: string = show ? 'del' : 'add';
    const query: Record<string, string> = {
      '__lib': 'user_option',
      '__act': 'set',
      '__output': '8',
    };
    query[operation] = filterId;
    const fields: Record<string, string> = {
      'fid': String(parentFid),
      'type': '1',
      'info': 'add_to_block_tids',
    };
    const raw: object = await ngaClient.postWithQueryAndBody(
      '/nuke.php', query, fields, { uid: session.uid, cid: session.cid });
    const error: string | null = parseNgaError(raw);
    if (error !== null) {
      result.error = error;
      return result;
    }
    result.ok = true;
  } catch (e) {
    logger.warn('修改子版块显示设置失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '修改子版块显示设置失败';
  }
  return result;
}
