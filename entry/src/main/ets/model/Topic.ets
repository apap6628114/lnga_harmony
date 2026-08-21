import type { SubBoard } from './Forum';

/**
 * 主题列表及其所属版块元数据。
 */
export interface TopicListInfo {
  /** 当前版块名称。 */
  name: string;
  /** 当前页主题列表。 */
  threadPageList: ThreadPageInfo[];
  /** 当前版块下可浏览或屏蔽的子版块列表。 */
  subBoardList: SubBoard[];
  /** NGA 服务端当前时间。 */
  curTime: number;
  /** 主题列表分页信息。 */
  pagination: Pagination;
}

export interface ThreadPageInfo {
  tid: number;
  fid: number;
  author: string;
  authorId: number;
  /** 主题作者是否在当前用户的黑名单中。 */
  isInBlackList: boolean;
  lastPoster: string;
  replies: number;
  subject: string;
  titleFont: string;
  type: number;
  topicMisc: string;
  page: number;
  pid: number;
  position: number;
  isAnonymity: boolean;
  postDate: number;
  replyInfo: ReplyInfo;
  board: string;
  mirrorBoard: boolean;
  /** 帖子列表摘要所对应回复的作者 UID。 */
  previewAuthorId?: string;
  previewSnippet?: string;
  previewImages?: string[];
  /** 官方接口受限/占位条目的附件标记（如「帖子发布或回复时间超过限制」时为空串）。 */
  attachs?: string;
  /** 官方接口受限/占位条目的受限原因（如「帖子发布或回复时间超过限制」）。 */
  error?: string;
}

export interface ReplyInfo {
  pidStr: string;
  content: string;
  subject: string;
  postDate: string;
  authorId: string;
  tidStr: string;
}

export interface TopicRaw {
  tid: number;
  fid: number;
  quote_from: number;
  quote_to: string;
  topic_misc: string;
  author: string;
  authorid: string;
  subject: string;
  type: number;
  postdate: number;
  lastpost: number;
  lastposter: string;
  replies: number;
  lastmodify: number;
  recommend: number;
  titlefont: string;
  admin_ui: number;
  tpcurl: string;
  parent: Record<string, string>;
  topic_misc_var: Record<string, number>;
  __P?: TopicQuoteInfo;
}

export interface TopicQuoteInfo {
  tid: number;
  pid: number;
  authorid: string;
  type: number;
  postdate: number;
  subject: string;
  content: string;
}

export interface Pagination {
  page: number;
  totalPages: number;
  totalRows: number;
}
