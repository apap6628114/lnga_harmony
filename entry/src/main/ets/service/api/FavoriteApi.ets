/**
 * NGA 收藏/推荐/签到 API
 *
 * 主题收藏夹全链路（收藏夹列表/新建/重命名/设默认/删除、主题入夹/出夹、收藏夹内
 * 主题列表）已迁移至官方 APP 签名接口（POST form + sign，__lib/__act 放 URL query），
 * 网页版通道（__output=8 的 postWithQueryAndBody 形态）已移除，不再降级：
 * - list_folder（收藏夹列表）：nuke.php topic_favor_v2/list_folder，body 含
 *   uid+page，__output=12，signParams 为空，实测响应
 *   {code:"0",result:[{id,type,name,bytes,length,default}]}
 * - new_folder（新建收藏夹）：nuke.php topic_favor_v2/new_folder，body 含
 *   name+opt（实测 opt：0=设默认/1=不设，与官方反编译字面相反），__output=14，
 *   实测响应 {code:"0",result:["操作成功",<ID>]}
 * - modify_folder（重命名/设默认）：nuke.php topic_favor_v2/modify_folder，
 *   body 含 folder+name+opt（必填：缺省 opt=设默认、opt=1=取消默认、缺 name 行为
 *   异常），__output=14
 * - del_folder（删除收藏夹）：nuke.php topic_favor_v2/del_folder，body 含 folder，
 *   __output=14
 * - add（主题入夹）：nuke.php topic_favor_v2/add，body 含 folder+tid+pid（主楼 0），
 *   __output=12，实测响应 {code:"0",result:"操作成功"}
 * - del（主题出夹）：nuke.php topic_favor_v2/del，body 含 folder+del（tid 逗号串），
 *   __output=14
 * - 收藏夹内主题列表：app_api.php favor/all（见 ForumApi.getTopicList favor 分支）
 * - 收藏版面列表：nuke.php forum_favor2/get，__output=12（实测 result 直接为
 *   版面数组 {id,fid,name,info}；14 时为数组套数组分组）
 * - 收藏版面全量同步：app_api.php favorforum/sync，body fidlist（收藏 fid
 *   逗号拼接）+ __output=14，signParams=fidlist 完整串（卡片 19；响应仅
 *   code/msg，官方模型 = 本地整表 → 全量同步）
 *
 * 协议情报来源：nga-hack nga-client/docs/cards（3-nuke-user.md 卡片 6/7/8、
 * 2-app-business.md 卡片 19、AppUrls GET_FAVORITES/ADD_FAVORITE、
 * ct/d$a.smali pswitch 映射、kt.c 老封装 CREATE/EDIT/DELETE_FAVORITE 与
 * DELETE_POST_COMMENT）+ nga-hack nga-client 实测（2026-08）。
 *
 * 缓存分工约定：本层只负责请求与解析，不修改 FavoriteStore；调用方在写操作
 * （createFolder/renameFolder 等）成功后自行做乐观更新 + 失败回滚 + 刷新列表。
 */

import { ngaClient, Cookies } from '../NgaClient';
import { sessionRegistry } from '../../store/SessionRegistry';
import {
  ApiResult, VoteResult, CheckinResult, ForumFavoritesResult,
  FavoriteFolderListResult, FavoriteFolderCreateResult, TopicFavoriteResult,
} from '../../model/NgaApiResults';
import { TopicFavoriteOperation } from '../../model/Favorite';
import { makeClientChecksum } from '../../common/security/NgaSigner';
import {
  extractFavoriteError,
  extractFavoriteFolderId,
  parseFavoriteTopicFolders,
  parseForumFavoriteBoards,
} from '../../parser/FavoriteParser';
import { Logger, DOMAIN_SERVICE, formatError } from '../../common/utils/Logger';

const logger = new Logger(DOMAIN_SERVICE, 'FavoriteApi')

// ============== 版块收藏 ==============

/**
 * 获取当前账号收藏的版面（官方 APP 签名接口 forum_favor2.get）。
 *
 * 仅走官方签名通道（POST form + sign，__output=12，signParams 为空），实测响应
 * {"code":0,"result":[{id,fid,name,info}]}，result 直接为版面数组（id==fid）；
 * __output=14 时 result 为数组套数组（分组），解析器兼容两种形状。
 *
 * @param token - 当前应用会话令牌
 * @returns 收藏版面列表结果
 */
export async function fetchForumFavorites(token: string): Promise<ForumFavoritesResult> {
  const result = new ForumFavoritesResult()
  const session = sessionRegistry.getSession(token)
  if (!session) {
    result.error = '未登录'
    return result
  }
  try {
    const cookies: Cookies = { uid: session.uid, cid: session.cid }
    const raw: Record<string, Object> = await ngaClient.postSigned(
      '/nuke.php', 'forum_favor2', 'get', {}, cookies, '', '12'
    ) as Record<string, Object>
    const error: string | null = extractFavoriteError(raw)
    if (error !== null) {
      result.error = error
      return result
    }
    const res: Object | undefined = raw['result']
    if (res === undefined || res === null) {
      result.error = '收藏版面数据格式异常'
      return result
    }
    result.data = parseForumFavoriteBoards(raw)
    result.ok = true
  } catch (e) {
    logger.warn('获取收藏板块失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '获取收藏板块失败'
  }
  return result
}

/**
 * 全量同步收藏版面到服务端（官方 APP 签名接口 favorforum.sync）。
 *
 * 官方模型为「本地整表 → 全量同步」（kt.c.b1 → AppUrls.SYNC_COLLECT_LIST，
 * 卡片 19）：调用方把本地收藏版面的 fid 逗号拼接后整表上传，服务端以该
 * 列表覆盖账号收藏。仅走官方签名通道（POST form + sign，__output=14，
 * **signParams=fidlist 完整串**）。实测响应（2026-08，ngabbs.com）：
 * `{"code":0,"result":"操作成功"}`（result 为字符串，无 msg 字段）；
 * 成功回调语义 = 清空本地收藏并写入新列表（官方 kt.c$a）。
 *
 * 幂等安全：对同一 fidlist 重复上传不改变服务端状态（实测同步前后
 * forum_favor2/get 列表一致），可用于启动/变更后的全量校正。
 *
 * @param token - 当前应用会话令牌
 * @param fidlist - 收藏版面 fid 逗号拼接串（空串 = 清空收藏，服务端行为待实测）
 * @returns 同步结果
 */
export async function syncForumFavorites(token: string, fidlist: string): Promise<ApiResult> {
  const result = new ApiResult()
  const session = sessionRegistry.getSession(token)
  if (!session) {
    result.error = '未登录'
    return result
  }
  try {
    const cookies: Cookies = { uid: session.uid, cid: session.cid }
    const params: Record<string, string> = { 'fidlist': fidlist }
    const raw: Record<string, Object> = await ngaClient.postSigned(
      '/app_api.php', 'favorforum', 'sync', params, cookies, fidlist, '14'
    ) as Record<string, Object>
    const error: string | null = extractFavoriteError(raw)
    if (error !== null) {
      result.error = error
      return result
    }
    result.ok = true
  } catch (e) {
    logger.warn('同步收藏板块失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '同步收藏板块失败'
  }
  return result
}

// ============== 推荐 ==============

/**
 * 对指定楼层进行推荐或反对操作。
 *
 * 官方 APP 接口为 `app_api.php?__lib=post&__act=recommend`，请求使用
 * `tid + pid + value` 作为签名业务参数，返回 `result.last_state` 表示服务端
 * 最终状态：1 为推荐、-1 为反对、0 为取消。
 *
 * @param token - 当前应用会话令牌
 * @param tid - 主题 ID
 * @param pid - 楼层 ID
 * @param value - 1 表示推荐，-1 表示反对
 * @returns 推荐状态变更结果
 */
export async function votePost(token: string, tid: number, pid: number, value: number): Promise<VoteResult> {
  const result = new VoteResult();
  const session = sessionRegistry.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }
  if (value !== 1 && value !== -1) {
    result.error = '推荐值无效';
    return result;
  }
  try {
    const params: Record<string, string> = {
      'value': String(value),
      'tid': String(tid),
      'pid': String(pid),
    };
    const cookies: Cookies = { uid: session.uid, cid: session.cid };
    const raw: Record<string, Object> = await ngaClient.postSigned(
      '/app_api.php', 'post', 'recommend', params, cookies,
      `${tid}${pid}${value}`, '12'
    ) as Record<string, Object>;
    const error: string | null = extractFavoriteError(raw)
    if (error !== null) {
      result.error = error
      return result
    }
    const rawCode: Object | undefined = raw['code']
    if (rawCode === undefined || rawCode === null) {
      result.error = '推荐响应格式异常'
      return result
    }
    const code: number = Number(rawCode)
    if (!Number.isFinite(code)) {
      result.error = '推荐响应格式异常'
      return result
    }
    if (code !== 0) {
      result.error = String(raw['msg'] ?? `错误码: ${code}`);
      return result;
    }
    result.message = String(raw['msg'] ?? '操作成功');
    const rawResult: Object | undefined = raw['result'];
    if (rawResult !== undefined && rawResult !== null) {
      const resultObject: Record<string, Object> | null = getRecommendResultObject(rawResult);
      if (resultObject !== null) {
        const rawState: Object | undefined = resultObject['last_state'] ??
          resultObject['last'] ?? resultObject['state']
        const parsedState: number = Number(rawState ?? 99)
        result.state = parsedState === 1 || parsedState === -1 || parsedState === 0
          ? parsedState : 99
      }
    }
    result.ok = true;
  } catch (e) {
    logger.warn('推荐失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '操作失败';
  }
  return result;
}

/**
 * 从推荐接口的 result 字段中提取状态对象，兼容对象和单元素数组外壳。
 *
 * @param rawResult - 官方接口返回的 result 字段
 * @returns 状态对象；无法识别时返回 null
 */
function getRecommendResultObject(rawResult: Object): Record<string, Object> | null {
  if (Array.isArray(rawResult)) {
    const values: Object[] = rawResult as Object[];
    if (values.length === 0 || values[0] === null || typeof values[0] !== 'object') {
      return null;
    }
    return values[0] as Record<string, Object>;
  }
  if (typeof rawResult !== 'object') {
    return null;
  }
  return rawResult as Record<string, Object>;
}

// ============== 主题收藏 ==============

/**
 * 获取当前账号的主题收藏夹（官方 APP 签名接口 topic_favor_v2.list_folder）。
 *
 * 仅走官方签名通道（POST form + sign，__output=12，signParams 为空），实测响应
 * {code:"0",result:[{id,type,name,bytes,length,default}]}，result 直接为收藏夹数组。
 *
 * @param token - 当前应用会话令牌
 * @returns 收藏夹列表结果
 */
export async function fetchFavoriteTopicFolders(token: string): Promise<FavoriteFolderListResult> {
  const result: FavoriteFolderListResult = new FavoriteFolderListResult()
  const session = sessionRegistry.getSession(token)
  if (!session) {
    result.error = '未登录'
    return result
  }
  try {
    const cookies: Cookies = { uid: session.uid, cid: session.cid }
    const params: Record<string, string> = {
      'uid': session.uid,
      'page': '1'
    }
    const raw: Record<string, Object> = await ngaClient.postSigned(
      '/nuke.php', 'topic_favor_v2', 'list_folder', params, cookies, '', '12'
    ) as Record<string, Object>
    const error: string | null = extractFavoriteError(raw)
    if (error !== null) {
      result.error = error
      return result
    }
    // 形状严格校验（与 MessageApi「数据格式异常」语义对齐）：code=0 但 result
    // 缺失/非数组（官方 12 与 14 形状均为数组）视为失败而非「空列表」，防止
    // 调用方把异常形状当空收藏夹
    const res: Object | undefined = raw['result']
    if (res === undefined || res === null || typeof res !== 'object' || !Array.isArray(res)) {
      result.error = '收藏夹数据格式异常'
      return result
    }
    result.data = parseFavoriteTopicFolders(raw)
    result.ok = true
  } catch (error) {
    logger.warn('获取收藏夹失败: %{public}s', formatError(error));
    result.error = (error as Error).message ?? '获取收藏夹失败'
  }
  return result
}

/**
 * 新建服务端主题收藏夹（官方 APP 签名接口 topic_favor_v2.new_folder）。
 *
 * 仅走官方签名通道（POST form + sign，__output=14，signParams 为空），body 含
 * name+opt。实测响应 {code:"0",result:["操作成功",<ID>]}，新夹 ID 由
 * extractFavoriteFolderId 提取。
 *
 * opt 取值（2026-08 双夹对照实测，与官方反编译字面相反）：`"0"`=设为默认，
 * `"1"`=不设默认。故 setDefault=true → opt="0"，false → opt="1"。
 *
 * @param token - 当前应用会话令牌
 * @param name - 收藏夹名称
 * @param setDefault - 是否同时设为默认收藏夹
 * @returns 新建结果及服务端收藏夹 ID
 */
export async function createFavoriteTopicFolder(token: string, name: string,
  setDefault: boolean = false): Promise<FavoriteFolderCreateResult> {
  const result: FavoriteFolderCreateResult = new FavoriteFolderCreateResult()
  const session = sessionRegistry.getSession(token)
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
    const cookies: Cookies = { uid: session.uid, cid: session.cid }
    const params: Record<string, string> = {
      'name': normalizedName,
      'opt': setDefault ? '0' : '1'
    }
    const raw: Record<string, Object> = await ngaClient.postSigned(
      '/nuke.php', 'topic_favor_v2', 'new_folder', params, cookies, '', '14'
    ) as Record<string, Object>
    const error: string | null = extractFavoriteError(raw)
    if (error !== null) {
      result.error = error
      return result
    }
    result.folderId = extractFavoriteFolderId(raw)
    if (result.folderId.length === 0) {
      result.error = '服务器未返回收藏夹 ID'
      return result
    }
    result.ok = true
  } catch (error) {
    logger.warn('新建收藏夹失败: %{public}s', formatError(error));
    result.error = (error as Error).message ?? '新建收藏夹失败'
  }
  return result
}

/**
 * 执行收藏夹重命名、设为默认或删除操作（官方 APP 签名接口 topic_favor_v2）。
 *
 * @param token - 当前应用会话令牌
 * @param folderId - 收藏夹服务端 ID
 * @param action - NGA `topic_favor_v2` 动作
 * @param params - 额外表单字段
 * @returns 通用操作结果
 */
async function mutateFavoriteTopicFolder(token: string, folderId: string,
  action: string, params: Record<string, string>): Promise<ApiResult> {
  const result: ApiResult = new ApiResult()
  const session = sessionRegistry.getSession(token)
  if (!session) {
    result.error = '未登录'
    return result
  }
  if (folderId.length === 0) {
    result.error = '收藏夹 ID 无效'
    return result
  }
  try {
    const cookies: Cookies = { uid: session.uid, cid: session.cid }
    const body: Record<string, string> = { 'folder': folderId }
    const keys: string[] = Object.keys(params)
    for (let i = 0; i < keys.length; i++) {
      body[keys[i]] = params[keys[i]]
    }
    const raw: Record<string, Object> = await ngaClient.postSigned(
      '/nuke.php', 'topic_favor_v2', action, body, cookies, '', '14'
    ) as Record<string, Object>
    const error: string | null = extractFavoriteError(raw)
    if (error !== null) {
      result.error = error
      return result
    }
    result.ok = true
  } catch (error) {
    logger.warn('修改收藏夹失败: %{public}s', formatError(error));
    result.error = (error as Error).message ?? '修改收藏夹失败'
  }
  return result
}

/**
 * 重命名服务端主题收藏夹（官方 APP 签名接口 topic_favor_v2.modify_folder）。
 *
 * 仅走官方签名通道（POST form + sign，__output=14，signParams 为空），body 含
 * folder+name+opt。opt 取值（2026-08 双夹对照实测，与官方反编译字面相反）：
 * `"0"`=设为默认，`"1"`=取消默认。**缺省 opt 会被服务端解释为"设为默认"**，
 * 因此重命名必须显式携带 opt 以保持调用方的默认状态意图：keepDefault=true
 * （目标夹当前为默认）传 "0"，否则传 "1"。
 *
 * @param token - 当前应用会话令牌
 * @param folderId - 收藏夹服务端 ID
 * @param name - 新名称
 * @param keepDefault - 是否保持该夹的默认收藏夹状态（调用方按当前快照传入）
 * @returns 操作结果
 */
export async function renameFavoriteTopicFolder(token: string, folderId: string,
  name: string, keepDefault: boolean = false): Promise<ApiResult> {
  const normalizedName: string = name.trim()
  if (normalizedName.length === 0) {
    const result: ApiResult = new ApiResult()
    result.error = '收藏夹名称不能为空'
    return result
  }
  return mutateFavoriteTopicFolder(token, folderId, 'modify_folder',
    { 'name': normalizedName, 'opt': keepDefault ? '0' : '1' })
}

/**
 * 将指定主题收藏夹设为账号默认收藏夹（官方 APP 签名接口 topic_favor_v2.modify_folder）。
 *
 * 仅走官方签名通道（POST form + sign，__output=14），body 含 folder+name+opt。
 * 实测约束（2026-08）：
 * - opt 取值与官方反编译字面相反：`"0"`=设为默认、`"1"`=取消默认、缺省=设为默认；
 *   设为默认必须显式传 opt="0"
 * - **name 必须携带**：缺 name（仅 folder+opt）时服务端返回"操作成功"但行为异常
 *   （实测会把目标夹的默认状态清空），故由调用方（FavoriteStore）传入当前夹名
 *
 * @param token - 当前应用会话令牌
 * @param folderId - 收藏夹服务端 ID
 * @param name - 该收藏夹当前名称（服务端必填，缺失会导致默认状态异常）
 * @returns 操作结果
 */
export async function setDefaultFavoriteTopicFolder(token: string,
  folderId: string, name: string): Promise<ApiResult> {
  return mutateFavoriteTopicFolder(token, folderId, 'modify_folder',
    { 'name': name, 'opt': '0' })
}

/**
 * 删除指定服务端主题收藏夹及其中的收藏关系（官方 APP 签名接口
 * topic_favor_v2.del_folder）。
 *
 * 仅走官方签名通道（POST form + sign，__output=14），body 含 folder。
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
 * 增加或删除主题与指定收藏夹的服务端关系（官方 APP 签名接口 topic_favor_v2.add/del）。
 *
 * 仅走官方签名通道（POST form + sign，signParams 为空）：
 * - ADD：add（__output=12），body 含 folder+tid+pid（主楼 pid=0，实测响应
 *   {code:"0",result:"操作成功"}）
 * - DELETE：del（__output=14），body 含 folder+del（tid 逗号分隔串，可批量移除；
 *   实测响应 {code:"0",result:["操作成功"]}）
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
  const session = sessionRegistry.getSession(token)
  if (!session) {
    result.error = '未登录'
    return result
  }
  if (topicId.length === 0 || folderId.length === 0) {
    result.error = '收藏参数无效'
    return result
  }
  try {
    const cookies: Cookies = { uid: session.uid, cid: session.cid }
    const params: Record<string, string> = { 'folder': folderId }
    if (operation === TopicFavoriteOperation.ADD) {
      params['tid'] = topicId
      params['pid'] = '0'
    } else {
      params['del'] = topicId
    }
    const output: string = operation === TopicFavoriteOperation.ADD ? '12' : '14'
    const act: string = operation === TopicFavoriteOperation.ADD ? 'add' : 'del'
    const raw: Record<string, Object> = await ngaClient.postSigned(
      '/nuke.php', 'topic_favor_v2', act, params, cookies, '', output
    ) as Record<string, Object>
    const error: string | null = extractFavoriteError(raw)
    if (error !== null) {
      result.error = error
      return result
    }
    result.ok = true
  } catch (error) {
    logger.warn('修改收藏失败: %{public}s', formatError(error));
    result.error = (error as Error).message ?? '修改收藏失败'
  }
  return result
}

// ============== 签到 ==============

export async function checkin(token: string): Promise<CheckinResult> {
  const result = new CheckinResult();
  const session = sessionRegistry.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }
  try {
    const ts: string = String(Math.floor(Date.now() / 1000));
    const params: Record<string, string> = {
      '_auto': '1',
      '__ngaClientChecksum': makeClientChecksum({ uid: session.uid, ts: ts }),
    };
    const raw: Record<string, Object> = await ngaClient.postSigned(
      '/nuke.php', 'check_in', 'check_in', params,
      { uid: session.uid, cid: session.cid }, '', '12'
    ) as Record<string, Object>;
    const code: number = Number(raw['code'] ?? 0);
    if (code !== 0) {
      result.error = String(raw['msg'] ?? `错误码: ${code}`);
      return result;
    }
    result.data = (raw['data'] ?? raw['result'] ?? null) as object | null;
    result.ok = true;
  } catch (e) {
    logger.warn('签到失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '签到失败';
  }
  return result;
}
