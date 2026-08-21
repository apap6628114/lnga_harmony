/**
 * NGA 关注系统响应解析器 - follow_v2.get_follow / get_push_list
 *
 * - get_follow（我关注的用户）：网页版通道（__output=3），raw.data 序号字典结构，
 *   parseFollowedUsers 处理
 * - get_push_list（关注动态）：仅官方 APP 签名通道（__output=12，POST+sign），
 *   raw.result 直接为活动数组（元素为数字键对象 + summary，无用户表/主题表/分页字段），
 *   parseAppFollowedActivity 处理
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
 * 从 NGA JSON 响应中读取 data 对象。
 *
 * @param raw - NGA 客户端返回的完整响应
 * @returns data 对象；缺失或非对象时返回空对象
 */
function getFollowResponseData(raw: object): Record<string, Object> {
  const response: Record<string, Object> = raw as Record<string, Object>
  const data: Object | undefined = response['data']
  if (data !== undefined && data !== null && typeof data === 'object' && !Array.isArray(data)) {
    return data as Record<string, Object>
  }
  return {}
}

/**
 * 判断值是否为可遍历的普通对象（非 null、非数组）。
 *
 * @param value - 待判断值
 * @returns 是普通对象返回 true
 */
function isPlainObject(value: Object | undefined): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value)
}

/**
 * 解析我关注的用户列表（follow_v2.get_follow 的 data[0]）。
 *
 * data[0] 是「序号 → 用户对象」的映射，用户对象至少含 uid/username/avatar。
 * 空数据形态为 {} 或缺失，均返回空列表。
 *
 * @param raw - NGA 客户端返回的完整响应
 * @returns 关注的用户列表
 */
export function parseFollowedUsers(raw: object): FollowedUser[] {
  const data: Record<string, Object> = getFollowResponseData(raw)
  const container: Object | undefined = data['0']
  if (!isPlainObject(container)) {
    return []
  }

  const record: Record<string, Object> = container as Record<string, Object>
  const keys: string[] = Object.keys(record)
  const users: FollowedUser[] = []
  for (let i = 0; i < keys.length; i++) {
    const entry: Object = record[keys[i]]
    if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
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
