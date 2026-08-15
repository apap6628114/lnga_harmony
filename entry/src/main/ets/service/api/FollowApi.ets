/**
 * NGA 关注系统 API - 关注/取消关注用户、我关注的用户、关注动态
 *
 * 协议见 docs/FOLLOW_DESIGN.md（bbs.nga.cn 实测）：
 * - follow：POST /nuke.php，body 含 __lib=follow_v2&__act=follow&id={uid}&type={1|8}&raw=3
 * - get_follow / get_push_list / get_follow_by：必须 POST，__lib/__act/page 在 query，__output=3 在 body
 *
 * 缓存分工约定：本层只负责请求与解析，不修改 ProfileStore；调用方在写操作
 * （followUser）成功后自行做乐观更新 + 失败回滚 + appStore.invalidateProfile(uid)。
 */

import { ngaClient } from '../NgaClient';
import { sessionRegistry } from '../../store/SessionRegistry';
import { parseNgaError } from '../../parser/ErrorParser';
import { ApiResult } from '../../model/NgaApiResults';
import {
  FollowedUserListResult,
  FollowedActivityListResult,
} from '../../model/Follow';
import {
  parseFollowedUsers,
  parseFollowedActivity,
} from '../../parser/FollowParser';
import { Logger, DOMAIN_SERVICE, formatError } from '../../common/utils/Logger';

const logger = new Logger(DOMAIN_SERVICE, 'FollowApi')

/**
 * 关注或取消关注用户。
 *
 * @param token - 当前应用会话令牌
 * @param uid - 目标用户 ID
 * @param follow - true 关注（type=1），false 取消关注（type=8）
 * @returns 通用操作结果；服务端错误（如"你已经关注这个用户了"）直接透出
 */
export async function followUser(token: string, uid: string, follow: boolean): Promise<ApiResult> {
  const result = new ApiResult()
  const session = sessionRegistry.getSession(token)
  if (!session) {
    result.error = '未登录'
    return result
  }
  if (uid.length === 0) {
    result.error = '用户 ID 无效'
    return result
  }
  try {
    const fields: Record<string, string> = {
      '__lib': 'follow_v2',
      '__act': 'follow',
      'id': uid,
      'type': follow ? '1' : '8',
      'raw': '3',
    }
    const raw: object = await ngaClient.post('/nuke.php', fields, { uid: session.uid, cid: session.cid })
    const error: string | null = parseNgaError(raw)
    if (error !== null) {
      result.error = error
      return result
    }
    result.ok = true
  } catch (e) {
    logger.warn('关注操作失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '关注操作失败'
  }
  return result
}

/**
 * 获取我关注的用户列表（分页）。
 *
 * @param token - 当前应用会话令牌
 * @param page - 页码（1 基）
 * @returns 关注的用户列表
 */
export async function fetchFollowedUsers(token: string, page: number): Promise<FollowedUserListResult> {
  const result = new FollowedUserListResult()
  const session = sessionRegistry.getSession(token)
  if (!session) {
    result.error = '未登录'
    return result
  }
  try {
    const query: Record<string, string> = {
      '__lib': 'follow_v2',
      '__act': 'get_follow',
      'page': String(page),
    }
    const body: Record<string, string> = { '__output': '3' }
    const raw: object = await ngaClient.postWithQueryAndBody(
      '/nuke.php', query, body, { uid: session.uid, cid: session.cid })
    const error: string | null = parseNgaError(raw)
    if (error !== null) {
      result.error = error
      return result
    }
    result.data = parseFollowedUsers(raw)
    result.ok = true
  } catch (e) {
    logger.warn('获取关注列表失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '获取关注列表失败'
  }
  return result
}

/**
 * 获取用户的粉丝列表（分页）。
 *
 * @param token - 当前应用会话令牌
 * @param page - 页码（1 基）
 * @param uid - 目标用户 ID；为空时查询当前登录账号自己的粉丝
 * @returns 粉丝列表
 */
export async function fetchFollowers(token: string, page: number, uid: string = ''): Promise<FollowedUserListResult> {
  const result = new FollowedUserListResult()
  const session = sessionRegistry.getSession(token)
  if (!session) {
    result.error = '未登录'
    return result
  }
  try {
    const query: Record<string, string> = {
      '__lib': 'follow_v2',
      '__act': 'get_follow_by',
      'page': String(page),
    }
    if (uid.length > 0) {
      query['uid'] = uid
    }
    const body: Record<string, string> = { '__output': '3' }
    const raw: object = await ngaClient.postWithQueryAndBody(
      '/nuke.php', query, body, { uid: session.uid, cid: session.cid })
    const error: string | null = parseNgaError(raw)
    if (error !== null) {
      result.error = error
      return result
    }
    result.data = parseFollowedUsers(raw)
    result.ok = true
  } catch (e) {
    logger.warn('获取粉丝列表失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '获取粉丝列表失败'
  }
  return result
}

/**
 * 获取关注动态列表（分页）。
 *
 * @param token - 当前应用会话令牌
 * @param page - 页码（1 基）
 * @returns 关注动态列表及服务端总页数
 */
export async function fetchFollowedActivity(token: string, page: number): Promise<FollowedActivityListResult> {
  const result = new FollowedActivityListResult()
  const session = sessionRegistry.getSession(token)
  if (!session) {
    result.error = '未登录'
    return result
  }
  try {
    const query: Record<string, string> = {
      '__lib': 'follow_v2',
      '__act': 'get_push_list',
      'page': String(page),
    }
    const body: Record<string, string> = { '__output': '3' }
    const raw: object = await ngaClient.postWithQueryAndBody(
      '/nuke.php', query, body, { uid: session.uid, cid: session.cid })
    const error: string | null = parseNgaError(raw)
    if (error !== null) {
      result.error = error
      return result
    }
    const parsed = parseFollowedActivity(raw)
    result.data = parsed.activities
    result.pages = parsed.pages
    result.ok = true
  } catch (e) {
    logger.warn('获取关注动态失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '获取关注动态失败'
  }
  return result
}
