/**
 * NGA 版块 API - 版块分类、版块搜索、主题列表
 */

import { ngaClient } from '../NgaClient';
import { appStore } from '../../store/AppStore';
import { parseForumCategories, parseForumSearch } from '../../parser/ForumParser';
import { parseTopicList } from '../../parser/TopicParser';
import { parseNgaError } from '../../parser/ErrorParser';
import { parseTopicListHtmlTask } from '../../parser/task/TopicListHtmlParseTask';
import { taskpool } from '@kit.ArkTS';
import { ApiResult, CategoriesResult, TopicListResult, SearchForumResult } from '../../model/NgaApiResults';
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

  if (params.authorid) query['authorid'] = params.authorid;
  if (params.searchpost) query['searchpost'] = params.searchpost;
  if (params.favor) query['favor'] = params.favor;
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

export async function getTopicList(token: string, params: TopicListParams,
  blacklist: Set<string> = new Set(),
  keywords: string[] = []): Promise<TopicListResult> {
  const result = new TopicListResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
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
