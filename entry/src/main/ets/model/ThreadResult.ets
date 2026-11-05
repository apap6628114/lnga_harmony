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
  /**
   * 本页请求是否拿到了**合法帖子页**、但页面里一个可见楼层都没有（空页）。
   *
   * 官方 read.php 对「整页楼位全部不可见」的页不报错：HTTP 200、`template=read`、
   * `__R` 为空对象。这类页不是请求故障，而是页面状态（楼层被删除 / 审核中 / 被屏蔽，
   * 或 HTML 里根本没有楼层行）。树页全帖抓取据此把它降级为「跳过该页」而不是让
   * 整帖不可读，见 `ThreadTreeFetchService.isSkippablePageFailure`。
   *
   * 只有整页视图（请求不带 pid）才可能为 true：单帖视图拿不到楼层是
   * 「目标楼层已不存在」，走 `THREAD_FLOOR_MISSING_ERROR`，语义不同。
   */
  emptyPage: boolean = false;
}

/**
 * 发帖/回复鉴权结果。
 */
export class PostAuthResult extends ApiResult {
  auth: string = '';
  attachUrl: string = '';
  if_moderator: number = 0;
  /** post/check 响应 content：楼层引用（quote）时为服务端预生成的引用块
   *  （`[quote][pid=..,..,1]Reply[/pid] <b>Post by ...</b>...[/quote]`，HTML 混合
   *  BBCode）；提交 quote 时必须随 content 带回（官方 K0/L0 拼接语义）；modify
   *  时为编辑回显正文。其余 action 通常为空串。 */
  content: string = '';
  /**
   * post/check 响应 subject：**帖子原标题**（modify 时服务端回传，实测两个本人主题
   * 均返回）。官方客户端编辑首帖时用它回填标题框，并在提交 modify 时原样带回
   * （官方 `NetRequestWrapper.L0/K0` 只在 tietiao 分支 `remove("subject")`，
   * modify 分支保留该字段）——服务端按它校验/保存主题标题，缺了就会被判
   * 「标题过短」或找不到目标帖。其余 action 通常为空串。
   */
  subject: string = '';
  /** 编辑场景已存在附件的提交参数（attachArray 解析后 tab 拼接，编辑提交时回填保留）。 */
  attachments: string = '';
  /** 编辑场景已存在附件的校验参数（attachCheckArray 解析后 tab 拼接）。 */
  attachmentsCheck: string = '';
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
