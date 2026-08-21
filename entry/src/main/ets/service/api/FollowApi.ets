/**
 * NGA 关注系统 API - 关注/取消关注用户、我关注的用户、关注动态
 *
 * 协议见 docs/FOLLOW_DESIGN.md（bbs.nga.cn 实测）：
 * - follow：POST /nuke.php，body 含 __lib=follow_v2&__act=follow&id={uid}&type={1|8}&raw=3
 * - get_follow / get_follow_by：必须 POST，__lib/__act/page 在 query，__output=3 在 body
 * - get_push_list（关注动态）：仅走官方 APP 签名接口（POST form + sign，
 *   __output=12，不分页），见 fetchFollowedActivity
 *
 * 缓存分工约定：本层只负责请求与解析，不修改 ProfileStore；调用方在写操作
 * （followUser）成功后自行做乐观更新 + 失败回滚 + appStore.invalidateProfile(uid)。
 */

import { ngaClient, Cookies } from '../NgaClient';
import { sessionRegistry } from '../../store/SessionRegistry';
import { parseNgaError } from '../../parser/ErrorParser';
import { ApiResult } from '../../model/NgaApiResults';
import {
  FollowedUserListResult,
  FollowedActivityListResult,
} from '../../model/Follow';
import {
  parseFollowedUsers,
  parseAppFollowedActivity,
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
 * 获取关注动态列表。
 *
 * 仅走官方 APP 签名接口（nuke.php?__lib=follow_v2&__act=get_push_list，
 * POST form + sign，__output=12，signParams 为空）；网页版通道（__output=3 的
 * postWithQueryAndBody 形态）已随本次迁移移除，不再降级。
 *
 * 官方接口不分页：page 参数被服务端忽略、恒返回同一批动态（实测 page=2/3 与
 * page=1 相同），解析结果 pages 固定为 1，调用方（FollowActivityStore）不再翻页。
 *
 * @param token - 当前应用会话令牌
 * @param page - 页码（1 基；官方忽略，保留参数以兼容调用方）
 * @returns 关注动态列表及服务端总页数（恒 1）
 */
export async function fetchFollowedActivity(token: string, page: number): Promise<FollowedActivityListResult> {
  const result = new FollowedActivityListResult()
  const session = sessionRegistry.getSession(token)
  if (!session) {
    result.error = '未登录'
    return result
  }
  try {
    const cookies: Cookies = { uid: session.uid, cid: session.cid }
    const params: Record<string, string> = { 'page': String(page) }
    const raw: Record<string, Object> = await ngaClient.postSigned(
      '/nuke.php', 'follow_v2', 'get_push_list', params, cookies, '', '12'
    ) as Record<string, Object>
    const code: number = Number(raw['code'] ?? 0)
    if (code !== 0) {
      result.error = String(raw['msg'] ?? '获取关注动态失败')
      return result
    }
    // 形状严格校验（与 MessageApi 的「数据格式异常」语义对齐）：
    // code=0 但 result 缺失/非数组视为失败而非「空数据」，防止调用方
    // （FollowActivityStore）把异常形状当成功、翻页保护失效后无限加载
    const res: Object | undefined = raw['result']
    if (res === undefined || res === null || !Array.isArray(res)) {
      result.error = '关注动态数据格式异常'
      return result
    }
    const parsed = parseAppFollowedActivity(raw)
    result.data = parsed.activities
    result.pages = parsed.pages
    result.ok = true
  } catch (e) {
    logger.warn('获取关注动态失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '获取关注动态失败'
  }
  return result
}
