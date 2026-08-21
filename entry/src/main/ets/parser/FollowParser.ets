/**
 * NGA 关注系统响应解析器 - follow_v2.get_follow / get_push_list（官方 APP 签名通道）
 *
 * 本模块只处理官方 APP 签名通道（__output=12，POST form + sign）的响应形状；
 * 网页版通道（__output=3 的 raw.data 序号字典）已随迁移移除，不再降级。
 *
 * - get_follow / get_follow_by（我关注的用户 / 我的粉丝）：响应
 *   {"code":0,"result":[{uid,username,groupid,bit_data,avatar}]}（实测 ngabbs.com），
 *   result 直接为用户数组（uid 为数字），parseFollowedUsers 处理；
 *   业务失败（code!=0）或 result 缺失/非数组时返回空列表。
 * - get_push_list（关注动态）：raw.result 直接为活动数组（元素为数字键对象 + summary，
 *   无用户表/主题表/分页字段），parseAppFollowedActivity 处理。
 *
 * 协议情报来源：nga-hack nga-client/docs/cards（3-nuke-user.md 卡片 9/10 与
 * METHODS_UNDECOMPILED_SOLVED.md 实测样本）+ 本仓库实测（2026-08）。
 */
import {
  FollowedUser,
  FollowedActivity,
  FollowedActivityType,
  FollowedActivityParseResult,
} from '../model/Follow'

/**
 * summary 回填结果的字段容器。
 */
interface SummaryNames {
  /** summary 中提取的行为者用户名。 */
  actorName: string;
  /** summary 中提取的主题标题。 */
  subject: string;
}

/**
 * 从服务端生成的动态摘要文本中提取行为者名与主题标题。
 *
 * 官方签名通道（get_push_list __output=12）不返回用户表/主题表，行为者名与主题
 * 标题的唯一来源是 summary（实测格式）：
 *   "你关注的 [uid=67071786]发发新闻罢了[/uid] 发布了主题
 *    [tid=47407086]PNAS:X 算法向民主党用户推送更多激发愤怒的内容[/tid]"
 *
 * @param summary - 服务端摘要文本（可为空）
 * @returns 提取结果（缺失时为空串）
 */
function extractSummaryNames(summary: string): SummaryNames {
  const names: SummaryNames = { actorName: '', subject: '' }
  if (summary.length === 0) {
    return names
  }
  const uidMatch: RegExpMatchArray | null = summary.match(/\[uid=(\d+)\]([\s\S]*?)\[\/uid\]/)
  if (uidMatch !== null) {
    names.actorName = uidMatch[2]
  }
  const tidMatch: RegExpMatchArray | null = summary.match(/\[tid=(\d+)\]([\s\S]*?)\[\/tid\]/)
  if (tidMatch !== null) {
    names.subject = tidMatch[2]
  }
  return names
}

/**
 * 由下标值数组构造关注动态条目。
 *
 * 下标语义：
 * v[0] 动态 id，v[1] 类型，v[2] 行为者 uid，v[3] tid，v[4] pid，v[5] 回复目标/收藏帖作者，
 * v[6] 时间戳，v[7] 收藏表 id。
 *
 * actorName/subject 从 summary 提取回填（官方签名通道无用户表/主题表，
 * summary 是行为者名与主题标题的唯一来源）。
 *
 * @param values - 下标值数组
 * @param summary - 服务端摘要文本
 * @returns 动态条目；id 缺失时返回 null
 */
function buildActivityFromValues(values: Object[], summary: string): FollowedActivity | null {
  const activity: FollowedActivity = new FollowedActivity()
  activity.id = String(values[0] ?? '')
  if (activity.id.length === 0) {
    return null
  }
  const typeRaw: number = Number(values[1] ?? 0)
  activity.type = typeRaw === 1 ? FollowedActivityType.POST_TOPIC :
    (typeRaw === 2 ? FollowedActivityType.POST_REPLY :
      (typeRaw === 3 ? FollowedActivityType.FAVOR : FollowedActivityType.UNKNOWN))
  activity.actorUid = String(values[2] ?? '')
  activity.tid = String(values[3] ?? '')
  // pid 缺失（values 恒 8 元素、缺键已填空串）得到 ''，UI 以
  // `pid.length>0 && pid!=='0'` 判断楼层，空串与 '0' 语义等价（主题本身）
  activity.pid = String(values[4] ?? '')
  activity.replyTarget = String(values[5] ?? '')
  const timestampRaw: number = Number(values[6] ?? 0)
  activity.timestamp = Number.isFinite(timestampRaw) && timestampRaw > 0 ? timestampRaw : 0
  activity.favorTableId = String(values[7] ?? '')
  activity.summary = summary
  const names: SummaryNames = extractSummaryNames(summary)
  activity.actorName = names.actorName
  activity.subject = names.subject
  return activity
}

/**
 * 提取 follow_v2 系列接口（follow/get_follow/get_follow_by）的业务错误文案。
 *
 * 官方 APP 签名通道响应为 `{code, msg, result}`（实测：成功 `{code:0,
 * result:["操作成功"]}`，重复操作幂等返回成功；业务失败形态为 code!=0 + msg，
 * 与 get_push_list 等官方接口一致）。另兼容旧网页版 `{"error":{"0":"..."}}`
 * 形态与 ngaRequest 的 `__parseError` 响应（JSON 解析失败）作防御。
 *
 * @param raw - 官方接口响应
 * @returns 错误文案；成功（code=0）或形状缺失时返回 null
 */
export function extractFollowError(raw: object): string | null {
  const rec: Record<string, Object> = raw as Record<string, Object>
  // ngaRequest 在 JSON 解析失败时返回 {__parseError:true, __rawLength:N, error:Error 实例}
  // （NgaClient.ets），Error 实例不是可遍历的错误对象，必须先于 error/code 分支识别；
  // 否则 error['0'] 取不到、code 缺失回落 0，会把「响应解析失败」误判为成功
  // （旧 parseNgaError 对 Error 实例返回「未知错误」，此处修复该行为回归）。
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
 * 解析我关注的用户 / 我的粉丝列表（官方 APP 签名通道 get_follow/get_follow_by
 * __output=12）。
 *
 * 响应形状（实测）：`{"code":0,"result":[{uid,username,groupid,bit_data,avatar}]}`，
 * result 直接为用户数组，元素 uid 为数字（解析统一转字符串）；
 * 空数据形态为 result:[]，返回空列表；code!=0（业务失败）或 result 缺失/非数组
 * （形状异常）同样返回空列表，由调用方以失败态呈现（不把异常形状当空数据）。
 *
 * @param raw - 官方接口响应
 * @returns 用户列表
 */
export function parseFollowedUsers(raw: object): FollowedUser[] {
  const rec: Record<string, Object> = raw as Record<string, Object>
  const code: number = Number(rec['code'] ?? 0)
  if (code !== 0) {
    return []
  }
  const res: Object | undefined = rec['result']
  if (res === undefined || res === null || !Array.isArray(res)) {
    return []
  }
  const arr: Object[] = res as Object[]
  const users: FollowedUser[] = []
  for (let i = 0; i < arr.length; i++) {
    const entry: Object | undefined = arr[i]
    if (entry === undefined || entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
      continue
    }
    const item: Record<string, Object> = entry as Record<string, Object>
    const user: FollowedUser = new FollowedUser()
    user.uid = String(item['uid'] ?? '')
    if (user.uid.length === 0) {
      continue
    }
    user.userName = String(item['username'] ?? '')
    user.avatarUrl = String(item['avatar'] ?? '')
    user.groupId = Number(item['groupid'] ?? 0)
    user.bitData = Number(item['bit_data'] ?? 0)
    users.push(user)
  }
  return users
}

/**
 * 解析关注动态列表（官方 APP 签名通道 follow_v2.get_push_list __output=12）。
 *
 * 与网页版四段结构不同，官方通道响应（实测 ngabbs.com）：
 *   {"code":0,"result":[{"0":13402751,"1":1,"2":67071786,"3":47407086,"4":0,
 *    "5":0,"6":1787217026,"7":0,"8":0,"summary":"你关注的 [uid=...]...[/uid] ..."}]}
 * - result 直接为活动数组（无 data 包裹），元素为数字键对象 + summary
 * - 无用户表/主题表：行为者名与主题标题从 summary 提取（extractSummaryNames）
 * - 无分页字段，且 page 参数被服务端忽略（实测 page=2/3 返回与 page=1 相同的
 *   同一批动态）→ pages 固定为 1，调用方不再翻页
 *
 * @param raw - 官方接口响应
 * @returns 解析结果（动态列表 + 固定 pages=1；业务失败或形状不可识别时为空）
 */
export function parseAppFollowedActivity(raw: object): FollowedActivityParseResult {
  const result: FollowedActivityParseResult = new FollowedActivityParseResult()
  const rec: Record<string, Object> = raw as Record<string, Object>
  const code: number = Number(rec['code'] ?? 0)
  if (code !== 0) {
    return result
  }
  const res: Object | undefined = rec['result']
  if (res === undefined || res === null || !Array.isArray(res)) {
    return result
  }
  const arr: Object[] = res as Object[]
  const summaryKeys: string[] = ['0', '1', '2', '3', '4', '5', '6', '7']
  for (let i = 0; i < arr.length; i++) {
    const entry: Object | undefined = arr[i]
    if (entry === undefined || entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
      continue
    }
    const item: Record<string, Object> = entry as Record<string, Object>
    const values: Object[] = []
    for (let j = 0; j < summaryKeys.length; j++) {
      values.push(item[summaryKeys[j]] ?? '')
    }
    const activity: FollowedActivity | null =
      buildActivityFromValues(values, String(item['summary'] ?? ''))
    if (activity !== null) {
      result.activities.push(activity)
    }
  }
  result.pages = 1
  return result
}
