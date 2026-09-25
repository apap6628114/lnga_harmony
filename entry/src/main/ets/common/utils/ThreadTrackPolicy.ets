/**
 * 跟踪帖子策略 — 纯函数集合（未读判定、超期判定、状态应用、排序、缓存校验）。
 *
 * 与 Store / UI 解耦：不依赖 AppStore、网络与 ArkUI，可直接被 Hypium Local Test 覆盖。
 * 语义口径见 `model/TrackedThread.ets` 文件头。
 */

import {
  TrackedThread,
  ThreadTrackStatus,
  TrackStopNotice,
  TrackStopReason,
  TRACK_DEFAULT_KEEP_DAYS
} from '../../model/TrackedThread'

/** 一天的毫秒数。 */
const DAY_MS: number = 24 * 60 * 60 * 1000

/** 状态应用结果（一次检查对单个跟踪任务的影响）。 */
export class TrackApplyOutcome {
  /** 本次是否出现新回复（总回复数较上次增加）。 */
  hasNewReplies: boolean = false
  /** 是否应移除该跟踪任务。 */
  shouldStop: boolean = false
  /** 停止原因（shouldStop=true 时有效）。 */
  stopReason: number = TrackStopReason.MANUAL
  /** 停止补充信息（如服务端报告的失效原因）。 */
  detail: string = ''
  /** 任务字段是否发生变化（需要落盘）。 */
  changed: boolean = false
}

/**
 * 单个跟踪任务的未读回复数。
 *
 * @param item - 跟踪任务
 * @returns 未读新增回复数（服务端总数小于已读基准时为 0）
 */
export function unreadReplyCount(item: TrackedThread): number {
  const delta: number = item.totalReplies - item.seenReplies
  return delta > 0 ? delta : 0
}

/**
 * 跟踪任务是否有未读更新。
 *
 * @param item - 跟踪任务
 * @returns 是否存在未读新增回复
 */
export function hasTrackedUnread(item: TrackedThread): boolean {
  return unreadReplyCount(item) > 0
}

/**
 * 统计跟踪列表的未读任务数（「跟踪」Tab 角标与铃铛计数）。
 *
 * @param items - 跟踪任务列表
 * @returns 有未读更新的任务数量
 */
export function countUnreadTracked(items: TrackedThread[]): number {
  let count: number = 0
  for (let index: number = 0; index < items.length; index++) {
    if (hasTrackedUnread(items[index])) {
      count++
    }
  }
  return count
}

/**
 * 跟踪任务的「最后活动时间」（毫秒）：服务端最后回复时间与「开始跟踪时刻」取较晚者。
 *
 * 取**较晚者**而不是单纯优先服务端时间，是为了让「跟踪时长」符合用户直觉：
 * 对一个已经停更三天的帖子点「开始跟踪」，若只认服务端最后回复时间，任务会在
 * 添加后几秒内就被判超期删掉（用户视角是"刚点就开始跟踪就没了"）。以添加时刻兜底后，
 * 每个新任务至少有一个完整的 keepDays 观察期；此后一旦有新回复，服务端时间反超，
 * 计时自然切回真实活跃时间。
 *
 * @param item - 跟踪任务
 * @returns 毫秒时间戳；均不可用时返回 0
 */
export function resolveLastActiveMs(item: TrackedThread): number {
  const serverMs: number = item.lastPostTs > 0 ? item.lastPostTs * 1000 : 0
  if (serverMs > item.createdAt) {
    return serverMs
  }
  return item.createdAt > 0 ? item.createdAt : 0
}

/**
 * 跟踪任务是否已超期（自最后回复起满 keepDays 天无新回复）。
 *
 * 用**服务端最后回复时间**而非「上次检查时间」判定：网络失败或长期未打开应用
 * 都不会让活跃帖子被误判停更。最后回复时间未知时退回添加时间。
 *
 * @param item - 跟踪任务
 * @param nowMs - 当前时间戳（毫秒）
 * @returns 是否应停止跟踪
 */
export function isTrackExpired(item: TrackedThread, nowMs: number): boolean {
  const keepDays: number = item.keepDays > 0 ? item.keepDays : TRACK_DEFAULT_KEEP_DAYS
  const lastActiveMs: number = resolveLastActiveMs(item)
  if (lastActiveMs <= 0) {
    return false
  }
  return nowMs - lastActiveMs >= keepDays * DAY_MS
}

/**
 * 跟踪任务的剩余跟踪天数（用于列表副标题，向上取整并夹在 [0, keepDays]）。
 *
 * @param item - 跟踪任务
 * @param nowMs - 当前时间戳（毫秒）
 * @returns 剩余天数
 */
export function remainingTrackDays(item: TrackedThread, nowMs: number): number {
  const keepDays: number = item.keepDays > 0 ? item.keepDays : TRACK_DEFAULT_KEEP_DAYS
  const lastActiveMs: number = resolveLastActiveMs(item)
  if (lastActiveMs <= 0) {
    return keepDays
  }
  const elapsedDays: number = Math.floor((nowMs - lastActiveMs) / DAY_MS)
  const remaining: number = keepDays - elapsedDays
  if (remaining <= 0) {
    return 0
  }
  return remaining > keepDays ? keepDays : remaining
}

/**
 * 把一次状态检查结果应用到跟踪任务上（就地修改）。
 *
 * 失败（网络/解析）只累计失败次数并记录原因，不停止跟踪；服务端明确报告失效
 * 或任务已超期时置 `shouldStop`，由调用方移除并提示。
 *
 * @param item - 跟踪任务（就地修改）
 * @param status - 本次检查结果
 * @param nowMs - 当前时间戳（毫秒）
 * @returns 应用结果
 */
export function applyStatus(item: TrackedThread, status: ThreadTrackStatus, nowMs: number): TrackApplyOutcome {
  const outcome: TrackApplyOutcome = new TrackApplyOutcome()
  if (!status.ok) {
    item.failCount += 1
    item.lastError = status.reason
    outcome.changed = true
    if (status.invalid) {
      outcome.shouldStop = true
      outcome.stopReason = TrackStopReason.INVALID
      outcome.detail = status.reason
    }
    return outcome
  }

  const previousReplies: number = item.totalReplies
  item.failCount = 0
  item.lastError = ''
  item.lastCheckAt = nowMs
  item.totalReplies = status.totalReplies
  if (status.lastPostTs > 0) {
    item.lastPostTs = status.lastPostTs
  }
  if (status.fid !== 0) {
    item.fid = status.fid
  }
  // 标题变化不产生红点（更新口径只看回复数），仅静默回填展示字段
  if (status.subject.length > 0 && status.subject !== item.subject) {
    item.subject = status.subject
  }
  item.locked = status.locked
  // 作者只在本地为空时回填（楼主不会变；检查响应自带 __T.author）
  if (item.author.length === 0 && status.author.length > 0) {
    item.author = status.author
  }
  if (item.authorid === 0 && status.authorid > 0) {
    item.authorid = status.authorid
  }
  outcome.changed = true
  outcome.hasNewReplies = status.totalReplies > previousReplies
  // 服务端最后回复不晚于「用户上次已读时的服务端最后回复」：这段内容用户已经看过，
  // 直接推进基准。点开帖子时的即时检查受最小间隔节流（可能没重查），没有这一步就会在
  // 下一轮轮询里冒出"刚看过又红点"的假未读。
  const seenLastPostTs: number = item.seenLastPostTs
  if (seenLastPostTs > 0 && status.lastPostTs > 0 && status.lastPostTs <= seenLastPostTs) {
    item.seenReplies = item.totalReplies
  }

  if (status.locked) {
    outcome.shouldStop = true
    outcome.stopReason = TrackStopReason.INVALID
    outcome.detail = '帖子已被锁定'
    return outcome
  }
  if (isTrackExpired(item, nowMs)) {
    outcome.shouldStop = true
    outcome.stopReason = TrackStopReason.EXPIRED
  }
  return outcome
}

/**
 * 跟踪列表排序：有未读更新的排前面，其次按最后活动时间倒序，最后以添加时间倒序稳定。
 *
 * @param items - 跟踪任务列表
 * @returns 新数组（元素与原列表同引用）
 */
export function sortTrackedThreads(items: TrackedThread[]): TrackedThread[] {
  const copy: TrackedThread[] = items.slice()
  copy.sort((a: TrackedThread, b: TrackedThread): number => {
    const unreadA: number = hasTrackedUnread(a) ? 1 : 0
    const unreadB: number = hasTrackedUnread(b) ? 1 : 0
    if (unreadA !== unreadB) {
      return unreadB - unreadA
    }
    const activeA: number = resolveLastActiveMs(a)
    const activeB: number = resolveLastActiveMs(b)
    if (activeA !== activeB) {
      return activeB - activeA
    }
    return b.createdAt - a.createdAt
  })
  return copy
}

/**
 * 生成跟踪任务副标题：作者 · 回复数 · 剩余天数。
 *
 * @param item - 跟踪任务
 * @param nowMs - 当前时间戳（毫秒）
 * @returns 副标题文案
 */
export function describeTrackedThread(item: TrackedThread, nowMs: number): string {
  const author: string = item.author.length > 0 ? item.author : '未知作者'
  const remaining: number = remainingTrackDays(item, nowMs)
  return author + ' · ' + String(item.totalReplies) + ' 条回复 · 剩余 ' + String(remaining) + ' 天'
}

/**
 * 跟踪任务展示标题（标题缺失时以 tid 兜底）。
 *
 * @param item - 跟踪任务
 * @returns 展示标题
 */
export function trackedSubjectLabel(item: TrackedThread): string {
  return item.subject.length > 0 ? item.subject : '帖子 ' + item.tid
}

/**
 * 生成停止跟踪的提示文案（用户主动移除时返回空串，不打扰）。
 *
 * @param notice - 停止通知
 * @returns Toast 文案
 */
export function formatTrackStopNotice(notice: TrackStopNotice): string {
  if (notice.reason === TrackStopReason.MANUAL) {
    return ''
  }
  const subject: string = notice.subject.length > 0 ? notice.subject : '帖子 ' + notice.tid
  if (notice.reason === TrackStopReason.EXPIRED) {
    return '《' + subject + '》已多日无新回复，已停止跟踪'
  }
  const detail: string = notice.detail.length > 0 ? '（' + notice.detail + '）' : ''
  return '《' + subject + '》已失效，已停止跟踪' + detail
}

/**
 * 缓存条目校验：字段类型不符时整条丢弃（宁可丢缓存也不带病运行）。
 *
 * @param value - 待校验的缓存条目
 * @returns 是否为合法的跟踪任务缓存
 */
export function isValidCachedTrackedThread(value: Object): boolean {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return false
  }
  const record: Record<string, Object> = value as Record<string, Object>
  if (typeof record['tid'] !== 'string' || String(record['tid']).length === 0) {
    return false
  }
  return typeof record['subject'] === 'string' &&
    typeof record['author'] === 'string' &&
    typeof record['authorid'] === 'number' &&
    typeof record['fid'] === 'number' &&
    typeof record['forumName'] === 'string' &&
    typeof record['createdAt'] === 'number' &&
    typeof record['keepDays'] === 'number' &&
    typeof record['lastCheckAt'] === 'number' &&
    typeof record['totalReplies'] === 'number' &&
    typeof record['seenReplies'] === 'number' &&
    typeof record['seenLastPostTs'] === 'number' &&
    typeof record['lastPostTs'] === 'number' &&
    typeof record['locked'] === 'boolean' &&
    typeof record['failCount'] === 'number' &&
    typeof record['lastError'] === 'string'
}
