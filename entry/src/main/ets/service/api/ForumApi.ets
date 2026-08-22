/**
 * NGA 版块 API - 版块分类、版块搜索、主题列表
 */

import { ngaClient, Cookies } from '../NgaClient';
import { appStore } from '../../store/AppStore';
import { parseForumCategories, parseForumSearch } from '../../parser/ForumParser';
import { parseAppTopicList, extractAppTopicListError } from '../../parser/AppTopicListParser';
import { parseNgaError } from '../../parser/ErrorParser';
import { buildAppThreadQuery, buildAppSignParams } from '../../common/utils/AppTopicListQuery';
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
    // 官方 APP 签名通道（app_api.php home/category）：POST form + sign，
    // 业务参数仅 _v=2，signParams 为空，__output=14（卡片 2-app-business 卡片 1 实测）。
    // 响应 {code, msg, result: Category[], forum_icon_list, forum_recommend, ...}。
    const appParams: Record<string, string> = { '_v': '2' };
    const raw = await ngaClient.postSigned('/app_api.php', 'home', 'category', appParams,
      { uid: session.uid, cid: session.cid }, '', '14') as Record<string, Object>;
    const code: number = Number(raw['code'] ?? 0);
    if (code !== 0) {
      // 业务失败（签名错误/频率限制等）：置错误而非静默空列表
      result.error = String(raw['msg'] ?? `错误码: ${code}`);
      logger.warn('[NGA][REQ] 板块分类官方接口业务失败(code=%{public}d msg=%{public}s)',
        code, result.error);
      return result;
    }
    result.data = parseForumCategories(raw as object);
    result.ok = true;
  } catch (e) {
    logger.warn('获取板块分类失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '获取板块分类失败';
  }
  return result;
}

/**
 * 使用官方 APP 签名接口搜索版块。
 *
 * 官方接口会校验关键字长度；业务失败或请求异常时直接返回错误，遵守官方 APP
 * 的搜索约束，不再调用网页接口降级。
 *
 * @param token - 当前应用会话令牌
 * @param key - 版块搜索关键字
 * @returns 版块搜索结果
 */
export async function searchForum(token: string, key: string): Promise<SearchForumResult> {
  const result = new SearchForumResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    const appParams: Record<string, string> = { 'key': key, 'page': '1' };
    const raw = await ngaClient.postSigned('/app_api.php', 'forum', 'search', appParams,
      { uid: session.uid, cid: session.cid }, key, '14') as Record<string, Object>;
    const code: number = Number(raw['code'] ?? 0);
    if (code === 0) {
      result.data = parseForumSearch(raw as object);
      result.ok = true;
      return result;
    }
    const appError: string = String(raw['msg'] ?? `错误码: ${code}`);
    result.error = appError;
    logger.warn('[NGA][REQ] 版块搜索官方接口业务失败(key=%{public}s code=%{public}d msg=%{public}s)',
      key, code, appError);
  } catch (e) {
    const appError: string = formatError(e);
    logger.warn('[NGA][REQ] 版块搜索官方接口异常: %{public}s', appError);
    result.error = appError || '版块搜索失败';
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

  // 普通版面/搜索列表：官方 APP 签名接口是唯一通道（thread.php POST form + sign，
  // 无 __lib/__act，__output=14，signParams=fid|key）。网页版通道（GET
  // thread.php?lite=js 与 HTML 静态页降级）已随本次迁移彻底移除——
  // 官方接口失败即返回错误，不再降级（与关注/收藏/用户列表迁移模式一致）。
  let channelError: string = '';
  try {
    if (params.author) {
      // 官方 thread.php 无 author（按作者名过滤）参数；该场景无 UI 入口，
      // 防御性直接返回错误，不静默忽略 author 导致列表语义错误
      throw new Error('官方接口不支持作者名过滤');
    }
    const appParams: Record<string, string> = buildAppThreadQuery(params);
    const signParams: string = buildAppSignParams(params);
    const raw = await ngaClient.postSignedPath('/thread.php', appParams,
      { uid: session.uid, cid: session.cid }, signParams, '14') as Record<string, Object>;
    const error: string | null = extractAppTopicListError(raw);
    if (error) {
      channelError = error;
      logger.warn('[NGA][REQ] 主题列表官方签名通道业务失败(fid=%{public}s key=%{public}s page=%{public}s code-msg=%{public}s)',
        params.fid, params.key, params.page, error);
    } else {
      const page: number = Number(params.page || '1') || 1;
      const appInfo: TopicListInfo | null = parseAppTopicList(raw, blacklist, keywords, page);
      if (appInfo !== null) {
        result.data = appInfo;
        result.ok = true;
        return result;
      }
      channelError = '主题列表解析失败';
    }
  } catch (e) {
    channelError = (e as Error).message ?? '获取主题列表失败';
    logger.warn('[NGA][REQ] 主题列表官方签名通道失败: %{public}s', channelError);
  }
  result.error = channelError || '获取主题列表失败';
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
