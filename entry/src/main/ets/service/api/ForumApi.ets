/**
 * NGA 版块 API - 版块分类、版块搜索、主题列表
 */

import { ngaClient } from '../NgaClient';
import { appStore } from '../../store/AppStore';
import { parseForumCategories } from '../../parser/ForumParser';
import { parseTopicList } from '../../parser/TopicParser';
import { parseNgaError } from '../../parser/ErrorParser';
import { ApiResult, CategoriesResult, TopicListResult, SearchForumResult } from '../../model/NgaApiResults';

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
    result.data = await ngaClient.getWithBaseUrl('/forum.php', params, 'http://bbs.nga.cn', { uid: session.uid, cid: session.cid });
    result.ok = true;
  } catch (e) {
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
  twentyfour: string;
  searchpost: string;
  content: string;
  fidgroup: string;
}

export function createTopicListParams(): TopicListParams {
  return {
    fid: '', stid: '', page: '1', key: '', author: '', authorid: '',
    favor: '', recommend: '', twentyfour: '', searchpost: '', content: '', fidgroup: '',
  };
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

  try {
    const ngaParams: Record<string, string> = {
      'page': params.page || '1',
      'lite': 'js',
      'noprefix': '',
    };

    if (params.authorid) ngaParams['authorid'] = params.authorid;
    if (params.searchpost) ngaParams['searchpost'] = params.searchpost;
    if (params.favor) ngaParams['favor'] = params.favor;
    if (params.content) ngaParams['content'] = params.content;

    if (params.author) {
      ngaParams['author'] = params.author;
    } else {
      if (params.stid) ngaParams['stid'] = params.stid;
      else if (params.fid && params.fid !== '-1') ngaParams['fid'] = params.fid;
      if (params.key) ngaParams['key'] = params.key;
      if (params.fidgroup) ngaParams['fidgroup'] = params.fidgroup;
    }

    if (params.recommend) {
      ngaParams['recommend'] = params.recommend;
      ngaParams['order_by'] = 'postdatedesc';
      ngaParams['user'] = '1';
    }

    const raw = await ngaClient.get('/thread.php', ngaParams, { uid: session.uid, cid: session.cid }) as Record<string, Object>;
    const error = parseNgaError(raw);
    if (error) {
      result.error = error;
      return result;
    }

    const dataObj = raw?.['data'] as Record<string, Object> | undefined;
    const page = Number(dataObj?.['__PAGE'] ?? params.page ?? 1);
    result.data = parseTopicList(raw, blacklist, keywords, page);
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '获取主题列表失败';
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
    result.error = (e as Error).message ?? '修改子版块屏蔽设置失败';
  }
  return result;
}
