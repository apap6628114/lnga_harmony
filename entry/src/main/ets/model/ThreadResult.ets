/**
 * 帖子详情（getThread/getThreadHtml）的返回结果模型。
 * 包含帖子分页信息、主题元数据与帖子列表，以及发帖鉴权与回复结果。
 */
import { ApiResult } from './NgaApiResults';
import type { ThreadInfo } from './Thread';
import type { PostInfo } from './PostInfo';

/**
 * 业务结果分页封装。
 *
 * 与 model/Thread.ets 中的 `ThreadPagination` interface 区分：后者为解析器构造的
 * 原始分页数据；与 model/Topic.ets 中的 `ThreadPageInfo` interface（主题列表项）
 * 区分；本类为 ThreadResult 业务结果上承载的实例化分页对象。
 */
export class ThreadPaging {
  page: number = 1;
  totalPages: number = 0;
  totalRows: number = 0;
}

/**
 * 帖子详情结果。
 */
export class ThreadResult extends ApiResult {
  threadInfo: ThreadInfo | null = null;
  forumName: string = '';
  pagination: ThreadPaging = new ThreadPaging();
  posts: PostInfo[] = [];
}

/**
 * 发帖/回复鉴权结果。
 */
export class PostAuthResult extends ApiResult {
  auth: string = '';
  attachUrl: string = '';
  if_moderator: number = 0;
}

/**
 * 发帖/回复/评论提交结果。
 */
export class PostReplyResult extends ApiResult {
  tid: number = 0;
  pid: string = '';
}

/**
 * 主题分类（发新主题时的标题分类标签）查询结果。
 */
export class TopicCategoriesResult extends ApiResult {
  /** 分类名列表。 */
  categories: string[] = [];
}
