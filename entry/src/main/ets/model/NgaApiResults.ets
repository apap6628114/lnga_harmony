/**
 * NGA API 业务层各接口的返回结果模型集合。
 * 集中承载登录、版块、帖子列表、通知、私信、用户资料、收藏、上传、签到等接口的 Result 类型。
 */
import type { Category } from './Forum';
import type { TopicListInfo } from './Topic';
import type { NgaNotification } from './Notification';
import type { ProfileData } from './User';
import type { UserInfo } from './UserInfo';
import type { FavoriteTopicFolder } from './Favorite';

/**
 * API 调用的通用结果基类。
 */
export class ApiResult {
  ok: boolean = false;
  error: string = '';
}

/**
 * 投票（推荐帖子）结果。
 */
export class VoteResult extends ApiResult {
  message: string = '';
}

/**
 * 投票帖提交投票结果。
 */
export class VoteSubmitResult extends ApiResult {
  /** 服务端提示文本（如"投票成功"） */
  message: string = '';
}

/**
 * 验证码获取结果。
 */
export class CaptchaResult extends ApiResult {
  image: string = '';
}

/**
 * 登录第一步（发起登录、获取验证码）结果。
 */
export class LoginStep1Result extends ApiResult {
  needCaptcha: boolean = false;
  loginToken: string = '';
  captchaId: string = '';
  captchaImage: string = '';
}

/**
 * 登录第二步（提交验证码完成登录）结果。
 */
export class LoginStep2Result extends ApiResult {
  needCaptcha: boolean = false;
  loginToken: string = '';
  captchaId: string = '';
  captchaImage: string = '';
  token: string = '';
  user: UserInfo | null = null;
}

/**
 * 版块分类列表结果。
 */
export class CategoriesResult extends ApiResult {
  data: Category[] = [];
}

/**
 * 主题列表查询结果。
 */
export class TopicListResult extends ApiResult {
  data: TopicListInfo | null = null;
}

/**
 * 通知列表结果。
 */
export class NotificationsResult extends ApiResult {
  /** 成功解析的通知。 */
  data: NgaNotification[] = [];
  /** 结构损坏的通知记录数量。 */
  malformedCount: number = 0;
  /** 暂不支持的通知类型数量。 */
  unsupportedCount: number = 0;
  /** 服务端未读提示，仅用于诊断。 */
  serverUnreadHint: number = 0;
}

/**
 * 用户资料查询结果。
 */
export class UserProfileResult extends ApiResult {
  data: ProfileData | null = null;
}

/**
 * 域名切换结果。
 */
export class DomainResult extends ApiResult {
  domain: string = '';
}

/**
 * 当前用户信息结果。
 */
export class CurrentUserResult extends ApiResult {
  user: UserInfo | null = null;
}

/**
 * 签到结果（data 为服务端原始对象，结构不固定）。
 */
export class CheckinResult extends ApiResult {
  data: object | null = null;
}

/**
 * 版块搜索结果（data 为服务端原始对象，结构不固定）。
 */
export class SearchForumResult extends ApiResult {
  data: object | null = null;
}

/**
 * 凭据注入登录结果。
 */
export class InjectResult extends ApiResult {
  token: string = '';
  user: UserInfo | null = null;
}

/**
 * 附件上传结果。
 */
export class UploadAttachmentResult extends ApiResult {
  url: string = '';
  attachments: string = '';
  attachmentsCheck: string = '';
}

/**
 * 收藏板块条目。
 */
export interface FavBoardItem {
  fid: number;
  stid: number;
  name: string;
}

/**
 * 收藏板块列表结果。
 */
export class ForumFavoritesResult extends ApiResult {
  data: FavBoardItem[] = [];
}

/**
 * 主题收藏夹列表结果。
 */
export class FavoriteFolderListResult extends ApiResult {
  /**
   * 当前账号的服务端收藏夹列表。
   */
  data: FavoriteTopicFolder[] = [];
}

/**
 * 新建主题收藏夹结果。
 */
export class FavoriteFolderCreateResult extends ApiResult {
  /**
   * 新收藏夹的服务端 ID。
   */
  folderId: string = '';
}

/**
 * 主题收藏关系变更结果。
 */
export class TopicFavoriteResult extends ApiResult {
  /**
   * 被操作的收藏夹 ID。
   */
  folderId: string = '';
  /**
   * 操作完成后主题是否位于该收藏夹。
   */
  favored: boolean = false;
}

/**
 * 单个版块的用户活跃度统计。
 */
export class ForumStat {
  name: string = '';
  topicCount: number = 0;
  replyCount: number = 0;
}

/**
 * 用户活跃度分析结果（按版块/小时分布等聚合）。
 */
export class UserActivityAnalysis {
  forumList: ForumStat[] = [];
  hourDistribution: number[] = [];
  topicCount: number = 0;
  replyCount: number = 0;
  topicSubjects: string[] = [];
  replySnippets: string[] = [];
}
