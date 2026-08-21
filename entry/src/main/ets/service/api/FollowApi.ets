/**
 * NGA 关注系统 API - 关注/取消关注用户、我关注的用户、我的粉丝、关注动态
 *
 * 全部走官方 APP 签名接口（POST form + sign，__lib/__act 放 URL query）：
 * - follow（关注/取关）：nuke.php?__lib=follow_v2&__act=follow，
 *   body 含 id={uid}&type={1|8}，__output=14（实测响应 {code:0,result:["操作成功"]}，
 *   重复操作服务端幂等）
 * - get_follow（我关注的用户）：nuke.php?__lib=follow_v2&__act=get_follow，
 *   body 含 page，__output=12（实测 {code:0,result:[{uid,username,groupid,bit_data,avatar}]}）
 * - get_follow_by（我的粉丝）：nuke.php?__lib=follow_v2&__act=get_follow_by，
 *   body 含 page + uid，__output=12（响应与 get_follow 同构；官方客户端 MY_FANS_LIST
 *   恒带 uid，uid 缺省时以当前会话 uid 填充）
 * - get_push_list（关注动态）：nuke.php?__lib=follow_v2&__act=get_push_list，
 *   __output=12，signParams 为空，见 fetchFollowedActivity
 *
 * 协议情报来源：nga-hack nga-client/docs/cards（3-nuke-user.md 卡片 9/10、
 * METHODS_UNDECOMPILED_SOLVED.md）与 bbs/ngabbs 实测；网页版通道（__output=3 的
 * postWithQueryAndBody 形态）已随本次迁移移除，不再降级——官方接口是唯一通道。
 *
 * 缓存分工约定：本层只负责请求与解析，不修改 ProfileStore；调用方在写操作
 * （followUser）成功后自行做乐观更新 + 失败回滚 + appStore.invalidateProfile(uid)。
 */

import { ngaClient, Cookies } from '../NgaClient';
import { sessionRegistry } from '../../store/SessionRegistry';
import { ApiResult } from '../../model/NgaApiResults';
import {
  FollowedUserListResult,
  FollowedActivityListResult,
} from '../../model/Follow';
import {
  parseFollowedUsers,
  parseAppFollowedActivity,
  extractFollowError,
} from '../../parser/FollowParser';
import { Logger, DOMAIN_SERVICE, formatError } from '../../common/utils/Logger';

const logger = new Logger(DOMAIN_SERVICE, 'FollowApi')

/**
 * 关注或取消关注用户（官方 APP 签名接口 follow_v2.follow）。
 *
 * 仅走官方签名通道（POST form + sign，__output=14，signParams 为空）：
 * type=1 关注、type=8 取消关注（实测服务端对重复操作幂等返回"操作成功"，
 * 不会返回"你已经关注这个用户了"之类拒绝；业务失败以 code!=0 + msg 透出）。
 *
 * @param token - 当前应用会话令牌
 * @param uid - 目标用户 ID
 * @param follow - true 关注（type=1），false 取消关注（type=8）
 * @returns 通用操作结果；服务端错误（如 code!=0 的 msg）直接透出
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
    const cookies: Cookies = { uid: session.uid, cid: session.cid }
    const params: Record<string, string> = {
      'id': uid,
      'type': follow ? '1' : '8',
    }
    const raw: Record<string, Object> = await ngaClient.postSigned(
      '/nuke.php', 'follow_v2', 'follow', params, cookies, '', '14'
    ) as Record<string, Object>
    const error: string | null = extractFollowError(raw)
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
 * 获取我关注的用户列表（官方 APP 签名接口 follow_v2.get_follow，分页）。
 *
 * 仅走官方签名通道（POST form + sign，__output=12，signParams 为空），响应
 * result 直接为用户数组；官方接口无总页数字段，调用方沿用「上一页非空即翻页」。
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
    const cookies: Cookies = { uid: session.uid, cid: session.cid }
    const params: Record<string, string> = { 'page': String(page) }
    const raw: Record<string, Object> = await ngaClient.postSigned(
      '/nuke.php', 'follow_v2', 'get_follow', params, cookies, '', '12'
    ) as Record<string, Object>
    const error: string | null = extractFollowError(raw)
    if (error !== null) {
      result.error = error
      return result
    }
    // 形状严格校验（与 MessageApi「数据格式异常」语义对齐）：code=0 但 result
    // 缺失/非数组视为失败而非「空数据」，防止调用方把异常形状当空列表
    const res: Object | undefined = raw['result']
    if (res === undefined || res === null || !Array.isArray(res)) {
      result.error = '关注列表数据格式异常'
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
 * 获取用户的粉丝列表（官方 APP 签名接口 follow_v2.get_follow_by，分页）。
 *
 * 仅走官方签名通道（POST form + sign，__output=12，signParams 为空）。
 * 官方客户端 MY_FANS_LIST（NetRequestWrapper.l0(page, uid)）恒带 uid 参数；
 * uid 为空时以当前登录账号 uid 填充（查自己的粉丝）。响应与 get_follow 同构
 * （实测），解析复用 parseFollowedUsers。
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
    const cookies: Cookies = { uid: session.uid, cid: session.cid }
    const params: Record<string, string> = { 'page': String(page) }
    params['uid'] = uid.length > 0 ? uid : session.uid
    const raw: Record<string, Object> = await ngaClient.postSigned(
      '/nuke.php', 'follow_v2', 'get_follow_by', params, cookies, '', '12'
    ) as Record<string, Object>
    const error: string | null = extractFollowError(raw)
    if (error !== null) {
      result.error = error
      return result
    }
    const res: Object | undefined = raw['result']
    if (res === undefined || res === null || !Array.isArray(res)) {
      result.error = '粉丝列表数据格式异常'
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
