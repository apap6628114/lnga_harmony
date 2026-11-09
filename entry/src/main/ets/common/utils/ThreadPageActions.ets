/**
 * 帖子页的**提交动作**（自然列表 `ThreadPanel` 与递进树 `ThreadTreePanel` 共用）。
 *
 * 这里收纳的是「一次用户动作 → 服务层调用 → Toast 回执」这种**带副作用**的流程，
 * 与 `ThreadPostUtils.ets`（纯语义判断）分工：
 * - 纯判断、文案规则 → `ThreadPostUtils`
 * - 需要 appStore / 服务层、会产生 Toast 的流程 → 本文件
 *
 * ## 哪些内容进了这里、哪些没有
 *
 * 进：`保存帖子` 与 `跟踪帖子更新` 的提交段——两页逐字相同（只有占位标题的判据不同，
 * 那属于页面自己的观察项，仍留在页面，不在这里修）。
 *
 * 没进：
 * - 打开对话框（`openSaveThreadDialog` / `openTrackDialog`）：要 `new CustomDialogController`，
 *   而 `contentBuilder` 必须是页面自己的 `@Builder`（工程已有踩坑记录），无法搬到普通函数。
 * - 保存页范围的回写状态（`saveRangeValid` / `saveStartPage` / `saveEndPage`）：是页面 `@State`，
 *   由 `SaveThreadContent` 的 `onRangeChange` 回调驱动刷新。
 */

import { savedThreadService, SaveThreadOutcome } from '../../service/SavedThreadService'
import { appStore } from '../../store/AppStore'
import { TrackRequest, TrackResult } from '../../store/TrackedThreadStore'
import { TRACK_MAX_COUNT } from '../../model/TrackedThread'

/**
 * 启动后台保存任务；结果以 Toast 提示（进度由全局指示组件展示）。
 *
 * @param tid - 主题 ID
 * @param startPage - 起始页
 * @param endPage - 结束页
 */
export function saveThreadWithToast(tid: string, startPage: number, endPage: number): void {
  savedThreadService.saveThread(tid, startPage, endPage).then((outcome: SaveThreadOutcome): void => {
    if (outcome.ok) {
      appStore.showToast('已保存：' + outcome.message)
    } else if (outcome.cancelled) {
      appStore.showToast('已取消保存')
    } else {
      appStore.showToast('保存失败：' + outcome.message)
    }
  })
}

/**
 * 提交跟踪设置：未跟踪则新建，已跟踪则只更新跟踪天数（不动已读基准）。
 *
 * @param tid - 主题 ID
 * @param subject - 主题标题（**已由调用方处理过占位值**；空串表示交给检查回填）
 * @param authorName - 楼主昵称（未知传空串，由检查响应回填）
 * @param authorId - 楼主 uid 字符串（非正数按 0 处理）
 * @param fid - 所属版面 ID
 * @param keepDays - 跟踪时长（天）
 */
export function submitThreadTrack(tid: string, subject: string, authorName: string,
  authorId: string, fid: number, keepDays: number): void {
  if (!appStore.canTrackMoreThreads() && !appStore.isThreadTracked(tid)) {
    appStore.showToast('最多同时跟踪 ' + String(TRACK_MAX_COUNT) + ' 个帖子')
    return
  }
  const request: TrackRequest = new TrackRequest()
  request.tid = tid
  request.subject = subject
  request.author = authorName
  request.authorid = Number(authorId) > 0 ? Number(authorId) : 0
  request.fid = fid
  request.forumName = ''
  request.keepDays = keepDays
  appStore.trackThread(request).then((result: TrackResult): void => {
    if (result.ok) {
      appStore.showToast(result.created ? '已开始跟踪' : '跟踪设置已更新')
    } else {
      appStore.showToast(result.error || '跟踪失败')
    }
  })
}
