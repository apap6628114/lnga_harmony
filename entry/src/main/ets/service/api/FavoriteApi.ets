/**
 * NGA 收藏/投票/签到 API
 */

import { ngaClient } from '../NgaClient';
import { appStore } from '../../store/AppStore';
import { parseNgaError } from '../../parser/ErrorParser';
import {
  ApiResult, VoteResult, CheckinResult, FavBoardItem, ForumFavoritesResult,
  FavoriteFolderListResult, FavoriteFolderCreateResult, TopicFavoriteResult,
} from '../../model/NgaApiResults';
import { TopicFavoriteOperation } from '../../model/Favorite';
import { getFavoriteResponseData, parseFavoriteTopicFolders } from '../../parser/FavoriteParser';

// ============== 版块收藏 ==============

export async function fetchForumFavorites(token: string): Promise<ForumFavoritesResult> {
  const result = new ForumFavoritesResult()
  const session = appStore.getSession(token)
  if (!session) {
    result.error = '未登录'
    return result
  }
  try {
    const fields: Record<string, string> = {
      '__lib': 'forum_favor2',
      '__act': 'forum_favor',
      '__output': '8',
      'action': 'sync',
    }
    const raw = await ngaClient.post('/nuke.php', fields, { uid: session.uid, cid: session.cid }) as Record<string, Object>
    const data = raw?.['data'] as Record<string, Object> | undefined
    const items = data?.['0'] as Record<string, Object> | undefined
    if (items && typeof items === 'object') {
      const keys = Object.keys(items)
      const forums: FavBoardItem[] = []
      for (const key of keys) {
        const item = items[key] as Record<string, Object>
        forums.push({
          fid: Number(item['fid']) || 0,
          stid: Number(item['id']) || 0,
          name: String(item['name'] ?? ''),
        })
      }
      result.data = forums
    }
    result.ok = true
  } catch (e) {
    result.error = (e as Error).message ?? '获取收藏板块失败'
  }
  return result
}

// ============== 投票 ==============

export async function votePost(token: string, tid: number, pid: number, value: number): Promise<VoteResult> {
  const result = new VoteResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }
  try {
    const fields: Record<string, string> = {
      '__lib': 'topic_recommend',
      '__act': 'add',
      'raw': '3',
      '__output': '8',
      'value': String(value),
      'tid': String(tid),
      'pid': String(pid),
    };
    const raw = await ngaClient.post('/nuke.php', fields, { uid: session.uid, cid: session.cid });
    const err = parseNgaError(raw);
    if (err) {
      result.error = err;
      return result;
    }
    const rawObj = raw as Record<string, Object>;
    const dataObj = rawObj['data'] as Record<string, Object>;
    if (dataObj) {
      result.message = String(dataObj['0'] ?? '');
    }
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '操作失败';
  }
  return result;
}

// ============== 主题收藏 ==============

/**
 * 获取当前账号的主题收藏夹。
 *
 * @param token - 当前应用会话令牌
 * @returns 收藏夹列表结果
 */
export async function fetchFavoriteTopicFolders(token: string): Promise<FavoriteFolderListResult> {
  const result: FavoriteFolderListResult = new FavoriteFolderListResult()
  const session = appStore.getSession(token)
  if (!session) {
    result.error = '未登录'
    return result
  }
  try {
    const query: Record<string, string> = {
      '__lib': 'topic_favor_v2',
      '__act': 'list_folder',
      '__output': '8',
      'page': '1'
    }
    const raw: object = await ngaClient.postWithQueryAndBody(
      '/nuke.php', query, {}, { uid: session.uid, cid: session.cid })
    const error: string | null = parseNgaError(raw)
    if (error !== null) {
      result.error = error
      return result
    }
    result.data = parseFavoriteTopicFolders(raw)
    result.ok = true
  } catch (error) {
    result.error = (error as Error).message ?? '获取收藏夹失败'
  }
  return result
}

/**
 * 新建服务端主题收藏夹。
 *
 * @param token - 当前应用会话令牌
 * @param name - 收藏夹名称
 * @param setDefault - 是否同时设为默认收藏夹
 * @returns 新建结果及服务端收藏夹 ID
 */
export async function createFavoriteTopicFolder(token: string, name: string,
  setDefault: boolean = false): Promise<FavoriteFolderCreateResult> {
  const result: FavoriteFolderCreateResult = new FavoriteFolderCreateResult()
  const session = appStore.getSession(token)
  const normalizedName: string = name.trim()
  if (!session) {
    result.error = '未登录'
    return result
  }
  if (normalizedName.length === 0) {
    result.error = '收藏夹名称不能为空'
    return result
  }
  try {
    const query: Record<string, string> = {
      '__lib': 'topic_favor_v2',
      '__act': 'new_folder',
      '__output': '8',
      'raw': '3'
    }
    const fields: Record<string, string> = {
      'name': normalizedName,
      'opt': setDefault ? '2' : '0'
    }
    const raw: object = await ngaClient.postWithQueryAndBody(
      '/nuke.php', query, fields, { uid: session.uid, cid: session.cid })
    const error: string | null = parseNgaError(raw)
    if (error !== null) {
      result.error = error
      return result
    }
    const data: Record<string, Object> = getFavoriteResponseData(raw)
    result.folderId = String(data['1'] ?? data['0'] ?? '')
    if (result.folderId.length === 0) {
      result.error = '服务器未返回收藏夹 ID'
      return result
    }
    result.ok = true
  } catch (error) {
    result.error = (error as Error).message ?? '新建收藏夹失败'
  }
  return result
}

/**
 * 执行收藏夹重命名、设为默认或删除操作。
 *
 * @param token - 当前应用会话令牌
 * @param folderId - 收藏夹服务端 ID
 * @param action - NGA `topic_favor_v2` 动作
 * @param fields - 额外表单字段
 * @returns 通用操作结果
 */
async function mutateFavoriteTopicFolder(token: string, folderId: string,
  action: string, fields: Record<string, string>): Promise<ApiResult> {
  const result: ApiResult = new ApiResult()
  const session = appStore.getSession(token)
  if (!session) {
    result.error = '未登录'
    return result
  }
  if (folderId.length === 0) {
    result.error = '收藏夹 ID 无效'
    return result
  }
  try {
    const query: Record<string, string> = {
      '__lib': 'topic_favor_v2',
      '__act': action,
      '__output': '8',
      'raw': '3'
    }
    const body: Record<string, string> = { 'folder': folderId }
    const keys: string[] = Object.keys(fields)
    for (let i = 0; i < keys.length; i++) {
      body[keys[i]] = fields[keys[i]]
    }
    const raw: object = await ngaClient.postWithQueryAndBody(
      '/nuke.php', query, body, { uid: session.uid, cid: session.cid })
    const error: string | null = parseNgaError(raw)
    if (error !== null) {
      result.error = error
      return result
    }
    result.ok = true
  } catch (error) {
    result.error = (error as Error).message ?? '修改收藏夹失败'
  }
  return result
}

/**
 * 重命名服务端主题收藏夹。
 *
 * @param token - 当前应用会话令牌
 * @param folderId - 收藏夹服务端 ID
 * @param name - 新名称
 * @returns 操作结果
 */
export async function renameFavoriteTopicFolder(token: string, folderId: string,
  name: string): Promise<ApiResult> {
  const normalizedName: string = name.trim()
  if (normalizedName.length === 0) {
    const result: ApiResult = new ApiResult()
    result.error = '收藏夹名称不能为空'
    return result
  }
  return mutateFavoriteTopicFolder(token, folderId, 'modify_folder', { 'name': normalizedName })
}

/**
 * 将指定主题收藏夹设为账号默认收藏夹。
 *
 * @param token - 当前应用会话令牌
 * @param folderId - 收藏夹服务端 ID
 * @returns 操作结果
 */
export async function setDefaultFavoriteTopicFolder(token: string,
  folderId: string): Promise<ApiResult> {
  return mutateFavoriteTopicFolder(token, folderId, 'modify_folder', { 'opt': '2' })
}

/**
 * 删除指定服务端主题收藏夹及其中的收藏关系。
 *
 * @param token - 当前应用会话令牌
 * @param folderId - 收藏夹服务端 ID
 * @returns 操作结果
 */
export async function deleteFavoriteTopicFolder(token: string,
  folderId: string): Promise<ApiResult> {
  return mutateFavoriteTopicFolder(token, folderId, 'del_folder', {})
}

/**
 * 增加或删除主题与指定收藏夹的服务端关系。
 *
 * @param token - 当前应用会话令牌
 * @param topicId - NGA 主题 ID
 * @param folderId - 收藏夹服务端 ID
 * @param operation - 增加或删除操作
 * @returns 收藏关系变更结果
 */
export async function mutateTopicFavorite(token: string, topicId: string, folderId: string,
  operation: TopicFavoriteOperation): Promise<TopicFavoriteResult> {
  const result: TopicFavoriteResult = new TopicFavoriteResult()
  result.folderId = folderId
  result.favored = operation === TopicFavoriteOperation.ADD
  const session = appStore.getSession(token)
  if (!session) {
    result.error = '未登录'
    return result
  }
  if (topicId.length === 0 || folderId.length === 0) {
    result.error = '收藏参数无效'
    return result
  }
  try {
    const query: Record<string, string> = {
      '__lib': 'topic_favor_v2',
      '__act': operation,
      '__output': '8'
    }
    const topicKey: string = operation === TopicFavoriteOperation.ADD ? 'tid' : 'tidarray'
    const fields: Record<string, string> = {
      'folder': folderId
    }
    fields[topicKey] = topicId
    const raw: object = await ngaClient.postWithQueryAndBody(
      '/nuke.php', query, fields, { uid: session.uid, cid: session.cid })
    const error: string | null = parseNgaError(raw)
    if (error !== null) {
      result.error = error
      return result
    }
    result.ok = true
  } catch (error) {
    result.error = (error as Error).message ?? '修改收藏失败'
  }
  return result
}

// ============== 签到 ==============

export async function checkin(token: string): Promise<CheckinResult> {
  const result = new CheckinResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }
  try {
    const fields: Record<string, string> = { '__lib': 'check_in', '__act': 'check_in', 'lite': 'js' };
    const raw = await ngaClient.post('/nuke.php', fields, { uid: session.uid, cid: session.cid }) as Record<string, Object>;
    const error = parseNgaError(raw);
    if (error) {
      result.error = error;
      return result;
    }
    result.data = raw?.['data'] ?? null;
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '签到失败';
  }
  return result;
}
