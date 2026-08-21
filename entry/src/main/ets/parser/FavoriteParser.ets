import { FavoriteTopicFolder } from '../model/Favorite'
import { FavBoardItem } from '../model/NgaApiResults'

/**
 * NGA 主题收藏夹响应解析器 - topic_favor_v2（官方 APP 签名通道）
 *
 * 本模块只处理官方 APP 签名通道（POST form + sign，__output=12/14）的响应形状；
 * 网页版通道（__output=8 的 postWithQueryAndBody 形态）已随迁移移除，不再降级。
 *
 * 实测（2026-08，ngabbs.com）：
 * - list_folder（__output=12）：`{"code":"0","result":[{id,type,name,bytes,length,default}]}`，
 *   result 直接为收藏夹数组（id/type/name/length/default 等字段均为字符串），
 *   元素不含 uid；default 缺失 = 非默认夹。
 * - list_folder（__output=14，官方老封装）：`{"code":"0","result":[[{...}],"0"]}`，
 *   result 为数组套数组（第二元素为页码串），解析器防御性兼容 result[0] 内嵌数组。
 * - new_folder（__output=14）：`{"code":"0","result":["操作成功",<新夹ID>]}`，
 *   新夹 ID 为 number（服务端可能返回 string），extractFavoriteFolderId 处理。
 * - forum_favor2/get（收藏版面，__output=12）：`{"code":0,"result":[{id,fid,name,info}]}`，
 *   result 直接为版面数组（id==fid）；__output=14 时为数组套数组（分组），
 *   parseForumFavoriteBoards 兼容两种形状。
 * - 业务失败统一为 code!=0 + msg（实测 {"code":1,"msg":"参数错误"} 形态），
 *   extractFavoriteError 提取。
 *
 * 协议情报来源：nga-hack nga-client/docs/cards（3-nuke-user.md 卡片 6/7/8 与
 * ct/d$a.smali pswitch 映射、kt.c 老封装）+ nga-hack nga-client 实测（2026-08）。
 */

/**
 * 从 list_folder 响应中提取收藏夹原始条目数组。
 *
 * 兼容两种官方形状：
 * - result 直接为收藏夹数组（官方 __output=12，实测）
 * - result 数组套数组（官方 __output=14，实测 result=[[...],"0"]）
 *
 * @param raw - 官方接口响应
 * @returns 收藏夹条目数组；形状不可识别时返回空数组
 */
function extractFolderEntries(raw: object): Record<string, Object>[] {
  const rec: Record<string, Object> = raw as Record<string, Object>
  const res: Object | undefined = rec['result']
  if (res === undefined || res === null) {
    return []
  }
  if (Array.isArray(res)) {
    const arr: Object[] = res as Object[]
    if (arr.length > 0 && Array.isArray(arr[0])) {
      // 官方 __output=14：result 数组套数组
      return collectFolderObjects(arr[0] as Object[])
    }
    return collectFolderObjects(arr)
  }
  return []
}

/**
 * 从数组中收集对象元素（跳过 null/原始值/嵌套数组）。
 *
 * @param arr - 原始数组
 * @returns 对象元素列表
 */
function collectFolderObjects(arr: Object[]): Record<string, Object>[] {
  const items: Record<string, Object>[] = []
  for (let i = 0; i < arr.length; i++) {
    const v: Object | undefined = arr[i]
    if (v !== undefined && v !== null && typeof v === 'object' && !Array.isArray(v)) {
      items.push(v as Record<string, Object>)
    }
  }
  return items
}

/**
 * 将 NGA `topic_favor_v2/list_folder` 响应转换为收藏夹列表。
 *
 * 官方 __output=12 实测元素字段：id/type/name/bytes/length/default（均为字符串）。
 * - id 缺失的条目跳过（官方必有 id）
 * - length 非数字/负值归 0
 * - default 按值判定（非 0 即默认，官方 isDefault() = defaultStatus != 0）
 *
 * @param raw - 官方接口响应
 * @returns 默认收藏夹优先排列的收藏夹列表
 */
export function parseFavoriteTopicFolders(raw: object): FavoriteTopicFolder[] {
  const entries: Record<string, Object>[] = extractFolderEntries(raw)
  const folders: FavoriteTopicFolder[] = []
  for (let i = 0; i < entries.length; i++) {
    const item: Record<string, Object> = entries[i]
    const folder: FavoriteTopicFolder = new FavoriteTopicFolder()
    folder.id = String(item['id'] ?? '')
    if (folder.id.length === 0) {
      continue
    }
    folder.name = String(item['name'] ?? '')
    const parsedTopicCount: number = Number(item['length'] ?? 0)
    folder.topicCount = Number.isFinite(parsedTopicCount) ? Math.max(0, parsedTopicCount) : 0
    const defaultRaw: Object | undefined = item['default']
    if (defaultRaw !== undefined && defaultRaw !== null) {
      const parsedDefault: number = Number(defaultRaw)
      folder.isDefault = Number.isFinite(parsedDefault) && parsedDefault !== 0
    } else {
      folder.isDefault = false
    }
    folders.push(folder)
  }
  folders.sort((left: FavoriteTopicFolder, right: FavoriteTopicFolder): number => {
    if (left.isDefault === right.isDefault) {
      return 0
    }
    return left.isDefault ? -1 : 1
  })
  return folders
}

/**
 * 从 new_folder 响应中提取新收藏夹的服务端 ID。
 *
 * 实测（__output=14）：`{"code":"0","result":["操作成功",<新夹ID>]}`，ID 为 number；
 * 防御兼容 result 直接为数字/数字串、result 对象含 id/数字键（数字键回退仅接受
 * 纯数字值，避免把"操作成功"等文案当 ID）。
 *
 * @param raw - 官方接口响应
 * @returns 收藏夹 ID；无法识别时返回空串
 */
export function extractFavoriteFolderId(raw: object): string {
  const rec: Record<string, Object> = raw as Record<string, Object>
  const res: Object | undefined = rec['result']
  if (Array.isArray(res)) {
    const arr: Object[] = res as Object[]
    for (let i = 0; i < arr.length; i++) {
      const v: Object | undefined = arr[i]
      if (v === undefined || v === null) {
        continue
      }
      if (typeof v === 'object' && !Array.isArray(v)) {
        const item: Record<string, Object> = v as Record<string, Object>
        const id: Object | undefined = item['id']
        if (id !== undefined && id !== null && String(id).length > 0) {
          return String(id)
        }
        continue
      }
      // new_folder 实测形状：["操作成功", <ID>]，ID 为 number 或数字串
      const text: string = String(v)
      if (/^\d+$/.test(text)) {
        return text
      }
    }
    return ''
  }
  if (res !== undefined && res !== null) {
    if (typeof res !== 'object') {
      // 防御：result 直接为裸 ID（number/数字串）
      const text: string = String(res)
      if (/^\d+$/.test(text)) {
        return text
      }
      return ''
    }
    const resRec: Record<string, Object> = res as Record<string, Object>
    const id: Object | undefined = resRec['id']
    if (id !== undefined && id !== null && String(id).length > 0) {
      return String(id)
    }
    for (const key of ['0', '1']) {
      const v: Object | undefined = resRec[key]
      if (v !== undefined && v !== null && /^\d+$/.test(String(v))) {
        return String(v)
      }
    }
    return ''
  }
  return ''
}

/**
 * 提取 topic_favor_v2 系列接口（list_folder/new_folder/modify_folder/del_folder/
 * add/del）的业务错误文案。
 *
 * 官方 APP 签名通道响应为 `{code, msg, result}`（实测成功 `{code:"0",...}`，
 * code 为字符串；业务失败形态为 code!=0 + msg）。另兼容旧网页版
 * `{"error":{"0":"..."}}` 形态与 ngaRequest 的 `__parseError` 响应（JSON 解析失败）
 * 作防御。
 *
 * @param raw - 官方接口响应
 * @returns 错误文案；成功（code=0）或形状缺失时返回 null
 */
export function extractFavoriteError(raw: object): string | null {
  const rec: Record<string, Object> = raw as Record<string, Object>
  // ngaRequest 在 JSON 解析失败时返回 {__parseError:true, __rawLength:N, error:Error 实例}
  // （NgaClient.ets），Error 实例不是可遍历的错误对象，必须先于 error/code 分支识别，
  // 否则 error['0'] 取不到、code 缺失回落 0，会把「响应解析失败」误判为成功。
  if (rec['__parseError'] === true) {
    return '响应解析失败'
  }
  const err: Object | undefined = rec['error']
  if (err !== undefined && err !== null) {
    if (typeof err === 'string') {
      return String(err)
    }
    const err0: Object | undefined = (err as Record<string, Object>)['0']
    if (err0 !== undefined && err0 !== null) {
      return String(err0)
    }
  }
  const code: number = Number(rec['code'] ?? 0)
  if (code === 0) {
    return null
  }
  const msg: Object | undefined = rec['msg']
  return msg !== undefined && msg !== null ? String(msg) : `错误码: ${code}`
}

/**
 * 将 NGA `forum_favor2/get` 响应转换为收藏版面列表。
 *
 * 官方 APP 签名通道实测（ngabbs.com）：
 * - `__output=12`：`{"code":0,"result":[{id,fid,name,info}]}`，result 直接为版面数组
 * - `__output=14`：`{"code":0,"result":[[{id,fid,name,info}]]}`，数组套数组（分组）；
 *   本实现取第一组（调用方固定 __output=12 不触发该分支，防御路径仅保证不崩溃）
 *
 * 元素字段：id（==fid）、fid、name、info（可为 null）；实测无 stid 字段。
 *
 * @param raw - 官方接口响应
 * @returns 收藏版面列表
 */
export function parseForumFavoriteBoards(raw: object): FavBoardItem[] {
  const rec: Record<string, Object> = raw as Record<string, Object>
  const res: Object | undefined = rec['result']
  let entries: Object[] = []
  if (Array.isArray(res)) {
    const arr: Object[] = res as Object[]
    if (arr.length > 0 && Array.isArray(arr[0])) {
      entries = arr[0] as Object[]
    } else {
      entries = arr
    }
  }
  const boards: FavBoardItem[] = []
  for (let i = 0; i < entries.length; i++) {
    const v: Object | undefined = entries[i]
    if (v === undefined || v === null || typeof v !== 'object' || Array.isArray(v)) {
      continue
    }
    const item: Record<string, Object> = v as Record<string, Object>
    const rawFid: number = Number(item['fid'] ?? item['id'] ?? 0)
    if (!Number.isFinite(rawFid) || rawFid === 0) {
      continue
    }
    const board: FavBoardItem = {
      fid: rawFid,
      stid: Number(item['stid'] ?? 0) || 0,
      name: String(item['name'] ?? ''),
    }
    boards.push(board)
  }
  return boards
}
