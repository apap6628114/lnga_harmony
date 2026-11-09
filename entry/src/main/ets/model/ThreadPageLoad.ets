/**
 * 帖子页（自然列表）的加载与编辑流程类型。
 *
 * 从 `ThreadPanel.ets` 顶部迁出：这些类型不带任何 UI 依赖（只引用 `ThreadResult`），
 * 放在 model 层后可以被单元测试与其它阅读样式复用；页面只保留与界面相关的常量与状态。
 */

import { ThreadResult } from './ThreadResult'

/**
 * 一次替换加载的取数结果。
 *
 * `floorMissing` 表示"本次是目标楼层已删除后的整页回退视图"，必须随本次调用返回，
 * 不能落成组件字段：回退请求在途时用户可能切页 / 切帖，字段会被新一轮加载的清零与
 * 旧调用的写入交错，导致新加载误弹「该楼层不存在或已删除」。
 */
export class ThreadPageFetch {
  /** 帖子请求结果。 */
  result: ThreadResult

  /** 是否因目标楼层已删除而回退为整页视图。 */
  floorMissing: boolean

  /**
   * @param result - 帖子请求结果
   * @param floorMissing - 是否因目标楼层已删除而回退为整页视图
   */
  constructor(result: ThreadResult, floorMissing: boolean) {
    this.result = result
    this.floorMissing = floorMissing
  }
}

/** 帖子页面结果写入连续窗口的方式。 */
export enum ThreadLoadMode {
  /** 用目标页重建窗口。 */
  REPLACE = 0,
  /** 将下一相邻页追加到窗口末尾。 */
  APPEND = 1,
  /** 将上一相邻页插入窗口开头。 */
  PREPEND = 2
}

/** 用户通过底部分页控件发起跳页的来源。 */
export enum PageNavigationSource {
  /** 点击相邻页码按钮。 */
  PAGER_BUTTON = 0,
  /** 从页码选择器中选择页面。 */
  PAGE_PICKER = 1
}

/** 带请求页码的预取结果。 */
export class FetchPageResult {
  /** 请求页码。 */
  page: number = 0

  /** 页面接口结果。 */
  result: ThreadResult | null = null
}

/**
 * 编辑提交快照：记录编辑前后正文，供静默刷新区分「服务端确认的新内容」与
 * 「read.php/CDN 未失效的旧缓存」——旧缓存返回时跳过覆盖，防止乐观更新的
 * 新正文被回退成旧内容。
 */
export class EditSnapshot {
  /** 被编辑楼层 pid。 */
  pid: number = 0

  /** 编辑前正文（服务端旧内容，用于识别未失效的缓存）。 */
  oldContent: string = ''

  /** 编辑后提交的正文（乐观更新写入的内容）。 */
  newContent: string = ''
}
