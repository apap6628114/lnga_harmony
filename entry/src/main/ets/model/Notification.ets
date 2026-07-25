/**
 * 通知公共字段。
 */
export interface NotificationInfo {
  /** 本地稳定通知标识。 */
  notificationId: string;
  /** NGA 通知类型。 */
  type: number;
  /** 发起用户 ID。 */
  userId: string;
  /** 发起用户名。 */
  userName: string;
  /** 通知关联标题。 */
  title: string;
  /** 服务端通知时间戳。 */
  timeStamp: string;
  /** 用户是否已经在本地查看。 */
  seen: boolean;
  /** 服务端分组未读提示，仅用于诊断。 */
  serverUnreadHint: number;
}

/**
 * 回复、评论与提及类通知。
 */
export interface ReplyNotification extends NotificationInfo {
  /** 被回复用户 ID。 */
  repliedId: string;
  /** 被回复用户名。 */
  repliedName: string;
  /** 主题 ID。 */
  tid: string;
  /** 回复楼层 ID。 */
  replyPid: string;
  /** 被回复楼层 ID。 */
  repliedPid: string;
  /** 服务端页码提示。 */
  page: string;
}

/**
 * 私信类通知。
 */
export interface MessageNotification extends NotificationInfo {
  /** 私信会话 ID。 */
  mid: string;
}

/**
 * 评价类通知。
 */
export interface VoteNotification extends NotificationInfo {
  /** 主题 ID。 */
  tid: string;
  /** 楼层 ID。 */
  pid: string;
}

/**
 * 支持或反对类通知。
 */
export interface UpvoteNotification extends NotificationInfo {
  /** 被评价用户 ID。 */
  toUid: string;
  /** 主题 ID。 */
  tid: string;
  /** 楼层 ID。 */
  pid: string;
}

/**
 * 应用支持的标准化通知联合类型。
 */
export type NgaNotification = ReplyNotification | MessageNotification | VoteNotification | UpvoteNotification;

/**
 * 通知解析结果。
 */
export interface NotificationParseResult {
  /** 根数据结构是否有效。 */
  valid: boolean;
  /** 成功解析的通知。 */
  items: NgaNotification[];
  /** 结构损坏的记录数量。 */
  malformedCount: number;
  /** 暂不支持的通知类型数量。 */
  unsupportedCount: number;
  /** 服务端各分组未读提示之和。 */
  serverUnreadHint: number;
}
