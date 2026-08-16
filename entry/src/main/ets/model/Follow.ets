/**
 * NGA 关注系统模型 - 关注的用户与关注动态
 */
import { ApiResult } from './NgaApiResults'

/**
 * 我关注的用户条目（follow_v2.get_follow 返回）。
 */
export class FollowedUser {
  /** 用户 ID。 */
  uid: string = ''
  /** 用户名。 */
  userName: string = ''
  /** 头像地址（可为空，由 Avatar 组件兜底）。 */
  avatarUrl: string = ''
  /** 用户组 ID。 */
  groupId: number = 0
  /** 用户属性位。 */
  bitData: number = 0
}

/**
 * 关注动态的活动类型（follow_v2.get_push_list 的 v[1]）。
 */
export enum FollowedActivityType {
  /** 未知或无法识别的类型。 */
  UNKNOWN = 0,
  /** 关注的用户发布了新主题。 */
  POST_TOPIC = 1,
  /** 关注的用户发布了新回复。 */
  POST_REPLY = 2,
  /** 关注的用户收藏了主题或回复。 */
  FAVOR = 3,
}

/**
 * 关注动态条目（follow_v2.get_push_list 的 data[0] 元素）。
 */
export class FollowedActivity {
  /** 动态 ID。 */
  id: string = ''
  /** 活动类型。 */
  type: FollowedActivityType = FollowedActivityType.UNKNOWN
  /** 行为者 uid。 */
  actorUid: string = ''
  /** 行为者用户名（由 data[1] 回填）。 */
  actorName: string = ''
  /** 涉及主题 tid。 */
  tid: string = ''
  /** 涉及回复 pid（'0' 表示主题本身）。 */
  pid: string = ''
  /** 主题所属版块 fid（由 data[4] 回填）。 */
  fid: string = ''
  /** 主题标题（由 data[4] 回填）。 */
  subject: string = ''
  /** 行为时间戳（unix 秒）。 */
  timestamp: number = 0
  /** v[5]：类型 2 为被回复的 pid；类型 3 为被收藏帖的作者 uid。 */
  replyTarget: string = ''
  /** v[7]：收藏表 ID（仅类型 3 有意义）。 */
  favorTableId: string = ''
  /** 服务端生成的摘要文本（对象形态条目才可能携带）。 */
  summary: string = ''
  /** 本地已读状态（服务端无未读概念，点开对应帖子即标记已读）。 */
  seen: boolean = false
}

/**
 * 关注/粉丝列表页的初始 Tab。
 */
export enum FollowListTab {
  /** 我关注的用户（get_follow）。 */
  FOLLOWED = 0,
  /** 我的粉丝（get_follow_by）。 */
  FOLLOWERS = 1,
}

/**
 * 关注动态列表解析结果。
 */
export class FollowedActivityParseResult {
  /** 解析出的动态列表。 */
  activities: FollowedActivity[] = []
  /** 服务端总页数（空数据或缺失时为 0）。 */
  pages: number = 0
}

/**
 * 我关注的用户列表结果。
 */
export class FollowedUserListResult extends ApiResult {
  data: FollowedUser[] = []
}

/**
 * 关注动态列表结果。
 */
export class FollowedActivityListResult extends ApiResult {
  data: FollowedActivity[] = []
  /** 服务端总页数（空数据时可能为 0）。 */
  pages: number = 0
}
