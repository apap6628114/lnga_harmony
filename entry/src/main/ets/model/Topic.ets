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
  /**
   * 附件图片前缀（官方 subject 系响应 `attachPrefix`，如 https://img.nga.cn/attachments/）。
   *
   * 仅版面列表 / 热门榜下发（置顶、搜索、收藏、用户列表均无）；缺失时预览图解析
   * 回退 `NgaDomains.NGA_IMG_BASE` 拼出的 `NGA_CDN_BASE`。
   */
  attachPrefix: string;
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
  /**
   * 首帖附件中可作为预览图的绝对 URL 列表（已过滤非图片；无附件时为空数组）。
   *
   * 数据来自列表接口条目的 `attachs`（对象数组，元素形如 `{attachurl}`），
   * 由 `TopicPreviewUtils.parsePreviewImages` 拼接前缀后产出，详见
   * docs/TOPIC_PREVIEW_DESIGN.md。原 `attachs?: string` 已删除：该字段实测是数组，
   * 旧代码 `String()` 强转只会得到 "[object Object]"。
   */
  previewImages: string[];
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
