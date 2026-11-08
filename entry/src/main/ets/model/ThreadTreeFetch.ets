/**
 * 递进树全帖数据的**结果形状**（在线抓取与离线存档共用）。
 *
 * 单独放在 model 层的原因：`ThreadTreeFetchService`（在线抓取）与
 * `SavedThreadService`（离线数据源）都产出这一形状，二者不该为了一个类型互相依赖。
 * 本文件只放数据结构与注释，无运行时依赖。
 */

import type { PostInfo } from './PostInfo'
import type { ThreadInfo } from './Thread'

/**
 * 全帖抓取结果。
 *
 * 调用方（ThreadTreePanel）用它提交结果：`ok` 为 true 时
 * `posts` / `pageByPid` / `totalPages` / `threadInfo` / `forumName` 可用；
 * `partial` 区分「完整」与「只抓到了部分页」（取消/失败仍保留已抓楼层）；
 * 没有楼层时 `ok = false`，`error` 给出原因。
 */
export class ThreadTreeFetchResult {
  /** 本次抓取的任务代际（服务内部递增，调用方可用于诊断；提交校验以调用方自身代际为准）。 */
  generation: number = 0

  /**
   * 是否有可提交的楼层（完整或部分）。
   *
   * `skippedPages` 非空时仍为 true：跳过页只是「那一页没有可见楼层」，
   * 其余页内容完整可用（见 {@link ThreadTreeFetchResult.skippedPages}）。
   * `partial` 为 true 时同样为 true：取消/失败前抓到的楼层仍是可用数据。
   */
  ok: boolean = false

  /**
   * 本次抓取是否被取消（人工中断 / 页面销毁 / 被新任务抢占）。
   *
   * 与失败区分：取消是**用户或生命周期**发起的，`error` 为空；取消时若已抓到楼层，
   * 结果仍是 `ok = true` 的部分结果（见 {@link ThreadTreeFetchResult.partial}）。
   */
  cancelled: boolean = false

  /** 失败文案（完整成功或纯取消时为空串；部分结果里可能是中断前的失败原因）。 */
  error: string = ''

  /** 合并后的楼层（按 pid 去重、按 `lou` 升序）；无数据时为空数组。 */
  posts: PostInfo[] = []

  /** 服务端页码映射：楼层 pid → 抓取时所在页（含主楼 pid=0 → 1）。 */
  pageByPid: Map<number, number> = new Map<number, number>()

  /** 服务端总页数（至少为 1）。 */
  totalPages: number = 0

  /**
   * 被跳过的异常页（页码升序）。
   *
   * 这些页服务端返回了合法帖子页、但整页没有任何可见楼层（`ThreadResult.emptyPage`），
   * 已跳过、不参与合并。`ok = true` 时若本字段非空，表示结果是**部分完整**的：
   * 页面可以照常阅读，但缺少这几页的楼层（树里表现为内容偏少、引用目标可能悬空，
   * `buildThreadTree` 会把目标不在树内的楼层提升为根，不会丢行）。
   *
   * 跳过页数过半时不会提交部分结果（`isSkippedPagesOverwhelming` 改判整体失败），
   * 因此 `ok = true` 时这里最多是少数页。
   */
  skippedPages: number[] = []

  /** 主题元数据（取自第 1 页响应）。 */
  threadInfo: ThreadInfo | null = null

  /** 版块名（取自第 1 页响应）。 */
  forumName: string = ''

  /**
   * 服务端总楼层数（取自第 1 页 `pagination.totalRows`）。
   *
   * 增量加载时页面第一次提交只有 20 楼左右，写浏览历史不能拿已加载楼层数当总数，
   * 否则这个帖子在历史里会被记成"20 楼"。
   */
  totalRows: number = 0

  /**
   * 是否只覆盖**部分页**（人工中断，或某页失败但已有楼层可读）。
   *
   * `ok = true && partial = true` 时 `posts` 仍是**可直接建树的可用数据**，只是不完整：
   * 调用方必须向用户明示「已加载 loadedPages / totalPages 页」。页面不提供断点续传，
   * 补齐内容走重新进入帖子（或错误态重试）的整帖重抓。
   *
   * 三个出口的区别：
   * - `ok = false`：没有可提交的楼层（第 1 页失败、取消发生在第 1 页返回前）；
   * - `ok = true && partial = false`：全部页覆盖（跳过页仍算覆盖）；
   * - `ok = true && partial = true`：`loadedPages < totalPages`。
   */
  partial: boolean = false

  /**
   * 已**提交**页数（连续前缀；含跳过的空页，不含仍在乱序缓冲里的页）。
   *
   * 增量模型下它就是「页面能展示的内容边界」：进度文案、尾部文案、部分数据
   * 提示都以此为准；已抓但尚未提交的页不计入，保证 `n/N` 与用户看到的内容一致。
   */
  loadedPages: number = 0
}

/**
 * 一次「水位提交」的载荷：页面据此增量建树。
 *
 * 与最终结果 {@link ThreadTreeFetchResult} 的区别：这是**过程回调**，每推进一段
 * 连续页就发一次，`posts` 是按页序连续的前缀（可直接建树），`committedPages`
 * 是已提交页数（= 页面能展示的页数）。
 */
export class ThreadTreeCommit {
  /** 已提交的连续前缀楼层（按 lou 升序；与结果对象共享同一数组引用）。 */
  posts: PostInfo[] = []

  /** 已提交页数（连续前缀）。 */
  committedPages: number = 0

  /** 服务端总页数（至少为 1）。 */
  totalPages: number = 0

  /** 主题元数据（第 1 页提交起可用）。 */
  threadInfo: ThreadInfo | null = null

  /** 服务端总楼层数（写浏览历史用，不能用已加载楼层数代替）。 */
  totalRows: number = 0

  /** 版块名（第 1 页响应）。 */
  forumName: string = ''

  /** 楼层 pid → 服务端页码（与结果对象共享同一映射）。 */
  pageByPid: Map<number, number> = new Map<number, number>()
}
