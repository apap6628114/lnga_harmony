/**
 * NGA 关注系统响应解析器 - follow_v2.get_follow / get_push_list
 */
import {
  FollowedUser,
  FollowedActivity,
  FollowedActivityType,
  FollowedActivityParseResult,
} from '../model/Follow'

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
 * 解析关注动态列表（follow_v2.get_push_list 的 data）。
 *
 * 响应四段结构：
 * - data[0]：活动列表，「序号 → 活动条目」，活动条目为下标数组
 *   v[0] 动态 id，v[1] 类型，v[2] 行为者 uid，v[3] tid，v[4] pid，v[5] 回复目标/收藏帖作者，
 *   v[6] 时间戳，v[7] 收藏表 id；对象形态条目额外可能携带 summary。
 * - data[1]：用户表（uid → 用户对象），用于回填行为者用户名。
 * - data[2]：最大页数；data[3]：当前页数。
 * - data[4]：主题表（tid → 主题对象），用于回填标题与版块。
 *
 * 空数据形态：data[0] 为 {}，data[1]/data[4] 为空字符串 ""，data[2] 为 ""，
 * 全部按空处理，任何形态不抛异常。
 *
 * @param raw - NGA 客户端返回的完整响应
 * @returns 解析结果（动态列表 + 总页数）
 */
export function parseFollowedActivity(raw: object): FollowedActivityParseResult {
  const result: FollowedActivityParseResult = new FollowedActivityParseResult()
  const data: Record<string, Object> = getFollowResponseData(raw)

  const usersMap: Record<string, Record<string, Object>> = {}
  const usersRaw: Object | undefined = data['1']
  if (isPlainObject(usersRaw)) {
    const userRecord: Record<string, Object> = usersRaw as Record<string, Object>
    const userKeys: string[] = Object.keys(userRecord)
    for (let i = 0; i < userKeys.length; i++) {
      const entry: Object = userRecord[userKeys[i]]
      if (entry !== null && typeof entry === 'object' && !Array.isArray(entry)) {
        usersMap[userKeys[i]] = entry as Record<string, Object>
      }
    }
  }

  const topicsMap: Record<string, Record<string, Object>> = {}
  const topicsRaw: Object | undefined = data['4']
  if (isPlainObject(topicsRaw)) {
    const topicRecord: Record<string, Object> = topicsRaw as Record<string, Object>
    const topicKeys: string[] = Object.keys(topicRecord)
    for (let i = 0; i < topicKeys.length; i++) {
      const entry: Object = topicRecord[topicKeys[i]]
      if (entry !== null && typeof entry === 'object' && !Array.isArray(entry)) {
        topicsMap[topicKeys[i]] = entry as Record<string, Object>
      }
    }
  }

  const pagesRaw: Object | undefined = data['2']
  const parsedPages: number = Number(pagesRaw ?? 0)
  result.pages = Number.isFinite(parsedPages) && parsedPages > 0 ? Math.floor(parsedPages) : 0

  const activityContainer: Object | undefined = data['0']
  if (!isPlainObject(activityContainer)) {
    return result
  }

  const record: Record<string, Object> = activityContainer as Record<string, Object>
  const keys: string[] = Object.keys(record)
  for (let i = 0; i < keys.length; i++) {
    const entry: Object = record[keys[i]]
    if (entry === null || typeof entry !== 'object') {
      continue
    }

    const activity: FollowedActivity = new FollowedActivity()
    let values: Object[] = []
    let summary: string = ''
    if (Array.isArray(entry)) {
      values = entry as Object[]
    } else {
      const item: Record<string, Object> = entry as Record<string, Object>
      summary = String(item['summary'] ?? '')
      const summaryKeys: string[] = ['0', '1', '2', '3', '4', '5', '6', '7']
      for (let j = 0; j < summaryKeys.length; j++) {
        values.push(item[summaryKeys[j]] ?? '')
      }
    }

    activity.id = String(values[0] ?? '')
    if (activity.id.length === 0) {
      continue
    }
    const typeRaw: number = Number(values[1] ?? 0)
    activity.type = typeRaw === 1 ? FollowedActivityType.POST_TOPIC :
      (typeRaw === 2 ? FollowedActivityType.POST_REPLY :
        (typeRaw === 3 ? FollowedActivityType.FAVOR : FollowedActivityType.UNKNOWN))
    activity.actorUid = String(values[2] ?? '')
    activity.tid = String(values[3] ?? '')
    activity.pid = String(values[4] ?? '0')
    activity.replyTarget = String(values[5] ?? '')
    const timestampRaw: number = Number(values[6] ?? 0)
    activity.timestamp = Number.isFinite(timestampRaw) && timestampRaw > 0 ? timestampRaw : 0
    activity.favorTableId = String(values[7] ?? '')
    activity.summary = summary

    const actor: Record<string, Object> | undefined = usersMap[activity.actorUid]
    if (actor !== undefined) {
      activity.actorName = String(actor['username'] ?? '')
    }
    const topic: Record<string, Object> | undefined = topicsMap[activity.tid]
    if (topic !== undefined) {
      activity.subject = String(topic['subject'] ?? '')
      activity.fid = String(topic['fid'] ?? '')
    }

    result.activities.push(activity)
  }
  return result
}
