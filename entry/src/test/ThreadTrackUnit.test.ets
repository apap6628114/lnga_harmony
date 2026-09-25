import { describe, it, expect } from '@ohos/hypium'
import { parseThreadTrackStatus } from '../main/ets/parser/ThreadStatusParser'
import {
  applyStatus,
  countUnreadTracked,
  describeTrackedThread,
  formatTrackStopNotice,
  hasTrackedUnread,
  isTrackExpired,
  isValidCachedTrackedThread,
  remainingTrackDays,
  resolveLastActiveMs,
  sortTrackedThreads,
  trackedSubjectLabel,
  unreadReplyCount
} from '../main/ets/common/utils/ThreadTrackPolicy'
import {
  TrackedThread,
  ThreadTrackStatus,
  TrackStopNotice,
  TrackStopReason,
  TRACK_DEFAULT_KEEP_DAYS
} from '../main/ets/model/TrackedThread'

/** 一天的毫秒数（与策略实现同口径）。 */
const DAY_MS: number = 24 * 60 * 60 * 1000

/** 样本主题的最后回复时间戳（秒，取自实测响应）。 */
const SAMPLE_LAST_POST_TS: number = 1790330724

/**
 * 构造跟踪任务样本。
 *
 * @param tid - 主题 ID
 * @param totalReplies - 服务端总回复数
 * @param seenReplies - 已读基准
 * @returns 跟踪任务
 */
function createTracked(tid: string, totalReplies: number, seenReplies: number): TrackedThread {
  const item: TrackedThread = new TrackedThread()
  item.tid = tid
  item.subject = '样本标题'
  item.author = '样本作者'
  item.createdAt = 1000
  item.keepDays = TRACK_DEFAULT_KEEP_DAYS
  item.totalReplies = totalReplies
  item.seenReplies = seenReplies
  item.lastPostTs = SAMPLE_LAST_POST_TS
  return item
}

/**
 * 构造状态结果样本。
 *
 * @param totalReplies - 服务端总回复数
 * @returns 状态结果
 */
function createOkStatus(totalReplies: number): ThreadTrackStatus {
  const status: ThreadTrackStatus = new ThreadTrackStatus()
  status.ok = true
  status.totalReplies = totalReplies
  status.lastPostTs = SAMPLE_LAST_POST_TS
  status.subject = '样本标题'
  status.fid = -7
  return status
}

/**
 * 构造 __output=8 正常响应（__T 为直接对象，实测形状）。
 *
 * @returns 响应对象
 */
function createNormalResponse(): object {
  return JSON.parse(
    '{"data":{' +
      '"__CU":{"uid":42023922,"rvrc":10},' +
      '"__R":{"0":{"pid":0,"lou":0},"1":{"pid":824920438,"lou":1}},' +
      '"__T":{"fid":-7,"tid":44191387,"subject":"iOS客户端闪退问题",' +
        '"locked":0,"replies":554,"authorid":205511,"author":"gerraerd",' +
        '"lastpost":' + String(SAMPLE_LAST_POST_TS) + '},' +
      '"__ROWS":555,"__R__ROWS_PAGE":20,"__PAGE":1},' +
      '"encode":"GBK","time":1790355474}')
}

/**
 * 注册跟踪帖子单元测试。
 */
export default function threadTrackUnitTest(): void {
  describe('threadTrackParser', (): void => {
    it('parsesNormalResponse', 0, (): void => {
      const status: ThreadTrackStatus = parseThreadTrackStatus(createNormalResponse())

      expect(status.ok).assertTrue()
      expect(status.invalid).assertFalse()
      expect(status.totalReplies).assertEqual(554)
      expect(status.lastPostTs).assertEqual(SAMPLE_LAST_POST_TS)
      expect(status.subject).assertEqual('iOS客户端闪退问题')
      expect(status.author).assertEqual('gerraerd')
      expect(status.authorid).assertEqual(205511)
      expect(status.fid).assertEqual(-7)
      expect(status.locked).assertFalse()
    })

    it('parsesDictionaryTopicShape', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"__T":{"44191387":{"tid":44191387,"replies":12,"lastpost":100,' +
          '"subject":"字典形状","fid":7,"locked":0}},"__ROWS":13}}')
      const status: ThreadTrackStatus = parseThreadTrackStatus(raw)

      expect(status.ok).assertTrue()
      expect(status.totalReplies).assertEqual(12)
      expect(status.subject).assertEqual('字典形状')
      expect(status.fid).assertEqual(7)
    })

    it('fallsBackToRowsWhenRepliesMissing', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"__T":{"tid":44191387,"subject":"无 replies 字段"},"__ROWS":21}}')
      const status: ThreadTrackStatus = parseThreadTrackStatus(raw)

      expect(status.ok).assertTrue()
      expect(status.totalReplies).assertEqual(20)
    })

    it('marksMissingThreadInvalid', 0, (): void => {
      const raw: object = JSON.parse(
        '{"error":{"0":"2048:找不到主题","1":"","2":""},' +
          '"data":{"__MESSAGE":{"0":2048,"1":"找不到主题","3":200}},"encode":"gbk"}')
      const status: ThreadTrackStatus = parseThreadTrackStatus(raw)

      expect(status.ok).assertFalse()
      expect(status.invalid).assertTrue()
      expect(status.reason).assertEqual('找不到主题')
    })

    it('treatsTopLevelErrorWithoutBusinessMessageAsRetryable', 0, (): void => {
      /* data 在、但没有业务错误体 __MESSAGE：只给诊断文案，不判失效（保守口径，
         避免把服务端异常误当成"帖子被删/被锁"而清掉跟踪任务） */
      const raw: object = JSON.parse(
        '{"error":{"0":"此帖子被锁定","1":"","2":""},"data":{"__ROWS":0}}')
      const status: ThreadTrackStatus = parseThreadTrackStatus(raw)

      expect(status.ok).assertFalse()
      expect(status.invalid).assertFalse()
      expect(status.reason).assertEqual('此帖子被锁定')
    })

    it('treatsParseFailureAsRetryable', 0, (): void => {
      const raw: object = JSON.parse('{"__parseError":true,"__rawLength":137}')
      const status: ThreadTrackStatus = parseThreadTrackStatus(raw)

      expect(status.ok).assertFalse()
      expect(status.invalid).assertFalse()
      expect(status.reason).assertEqual('响应解析失败')
    })

    it('treatsHtmlErrorPageAsRetryable', 0, (): void => {
      /* NgaClient 把任何 HTML 页面归一化为 {error:{0:…}}（无 data）：
         频率限制页/维护页/登录跳转页都走这条，绝不能判成「帖子失效」 */
      const raw: object = JSON.parse(
        '{"error":{"0":"<!DOCTYPE html><title>频率限制</title>"},"error_code":15}')
      const status: ThreadTrackStatus = parseThreadTrackStatus(raw)

      expect(status.ok).assertFalse()
      expect(status.invalid).assertFalse()
      expect(status.reason.length > 0).assertTrue()
    })

    it('treatsTopicWithoutBusinessMessageAsRetryable', 0, (): void => {
      /* data 存在但没有 __T、没有 __MESSAGE、也没有行数：可重试失败，不是失效 */
      const status: ThreadTrackStatus = parseThreadTrackStatus(JSON.parse('{"data":{}}'))

      expect(status.ok).assertFalse()
      expect(status.invalid).assertFalse()
      expect(status.reason).assertEqual('帖子数据异常')
    })

    it('fallsBackWhenRepliesNotNumeric', 0, (): void => {
      const emptyReplies: object = JSON.parse(
        '{"data":{"__T":{"tid":1,"replies":"","subject":"空串回复数"},"__ROWS":21}}')
      const textReplies: object = JSON.parse(
        '{"data":{"__T":{"tid":1,"replies":"abc","subject":"非数字回复数"},"__ROWS":21}}')

      expect(parseThreadTrackStatus(emptyReplies).totalReplies).assertEqual(20)
      expect(parseThreadTrackStatus(textReplies).totalReplies).assertEqual(20)
    })

    it('treatsEmptyResponseAsRetryable', 0, (): void => {
      const status: ThreadTrackStatus = parseThreadTrackStatus(JSON.parse('{}'))

      expect(status.ok).assertFalse()
      expect(status.invalid).assertFalse()
    })

    it('reportsLockedFlag', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"__T":{"tid":1,"replies":3,"lastpost":100,"locked":1},"__ROWS":4}}')
      const status: ThreadTrackStatus = parseThreadTrackStatus(raw)

      expect(status.ok).assertTrue()
      expect(status.locked).assertTrue()
    })
  })

  describe('threadTrackPolicy', (): void => {
    it('computesUnreadReplies', 0, (): void => {
      const item: TrackedThread = createTracked('1', 12, 10)

      expect(unreadReplyCount(item)).assertEqual(2)
      expect(hasTrackedUnread(item)).assertTrue()
      expect(unreadReplyCount(createTracked('2', 10, 10))).assertEqual(0)
      expect(hasTrackedUnread(createTracked('3', 8, 10))).assertFalse()
    })

    it('countsUnreadTracked', 0, (): void => {
      const items: TrackedThread[] = [
        createTracked('1', 12, 10),
        createTracked('2', 10, 10),
        createTracked('3', 9, 3)
      ]

      expect(countUnreadTracked(items)).assertEqual(2)
      expect(countUnreadTracked([])).assertEqual(0)
    })

    it('resolvesLastActiveAsLaterOfServerAndCreated', 0, (): void => {
      const item: TrackedThread = createTracked('1', 1, 1)

      expect(resolveLastActiveMs(item)).assertEqual(SAMPLE_LAST_POST_TS * 1000)
      item.lastPostTs = 0
      expect(resolveLastActiveMs(item)).assertEqual(1000)
      /* 开始跟踪时刻晚于服务端最后回复（停更帖）：以开始跟踪时刻为基准 */
      item.lastPostTs = SAMPLE_LAST_POST_TS
      item.createdAt = SAMPLE_LAST_POST_TS * 1000 + 5 * DAY_MS
      expect(resolveLastActiveMs(item)).assertEqual(SAMPLE_LAST_POST_TS * 1000 + 5 * DAY_MS)
    })

    it('keepsGracePeriodForFreshTask', 0, (): void => {
      /* 对一个三天前就停更的帖子点「开始跟踪」：不应在添加瞬间被判超期 */
      const item: TrackedThread = new TrackedThread()
      const now: number = SAMPLE_LAST_POST_TS * 1000 + 3 * DAY_MS
      item.createdAt = now
      item.lastPostTs = SAMPLE_LAST_POST_TS
      item.keepDays = 2

      expect(isTrackExpired(item, now)).assertFalse()
      expect(remainingTrackDays(item, now)).assertEqual(2)
      expect(isTrackExpired(item, now + 2 * DAY_MS)).assertTrue()
    })

    it('detectsExpiredByInactivity', 0, (): void => {
      const item: TrackedThread = createTracked('1', 10, 10)
      const now: number = SAMPLE_LAST_POST_TS * 1000 + 3 * DAY_MS

      /* keepDays=2 且最后回复在 3 天前 → 超期；1 天前 → 未超期；档位放宽到 7 天 → 未超期 */
      expect(isTrackExpired(item, now)).assertTrue()
      expect(isTrackExpired(item, SAMPLE_LAST_POST_TS * 1000 + DAY_MS)).assertFalse()
      item.keepDays = 7
      expect(isTrackExpired(item, now)).assertFalse()
    })

    it('detectsExpiredByCreatedAtFallback', 0, (): void => {
      const item: TrackedThread = createTracked('1', 0, 0)
      item.lastPostTs = 0
      item.createdAt = 1000
      item.keepDays = 1

      expect(isTrackExpired(item, 1000 + 2 * DAY_MS)).assertTrue()
      expect(isTrackExpired(item, 1000 + DAY_MS / 2)).assertFalse()
    })

    it('computesRemainingDays', 0, (): void => {
      const item: TrackedThread = createTracked('1', 10, 10)
      item.keepDays = 7
      const base: number = SAMPLE_LAST_POST_TS * 1000

      expect(remainingTrackDays(item, base)).assertEqual(7)
      expect(remainingTrackDays(item, base + 2 * DAY_MS)).assertEqual(5)
      expect(remainingTrackDays(item, base + 30 * DAY_MS)).assertEqual(0)
    })

    it('appliesSuccessfulStatus', 0, (): void => {
      const item: TrackedThread = createTracked('1', 10, 8)
      item.lastCheckAt = 0
      const now: number = SAMPLE_LAST_POST_TS * 1000 + 1000
      const outcome = applyStatus(item, createOkStatus(12), now)

      expect(outcome.hasNewReplies).assertTrue()
      expect(outcome.shouldStop).assertFalse()
      expect(outcome.changed).assertTrue()
      expect(item.totalReplies).assertEqual(12)
      expect(item.seenReplies).assertEqual(8)
      expect(item.lastCheckAt).assertEqual(now)
      expect(item.failCount).assertEqual(0)
      expect(unreadReplyCount(item)).assertEqual(4)
    })

    it('advancesSeenForContentAlreadyRead', 0, (): void => {
      /* 用户上次已读时的服务端最后回复 == 本次检查到的最后回复：这批内容已看过 */
      const item: TrackedThread = createTracked('1', 10, 10)
      item.seenLastPostTs = SAMPLE_LAST_POST_TS
      const outcome = applyStatus(item, createOkStatus(12), SAMPLE_LAST_POST_TS * 1000 + 2000)

      expect(outcome.hasNewReplies).assertTrue()
      expect(item.totalReplies).assertEqual(12)
      expect(item.seenReplies).assertEqual(12)
      expect(unreadReplyCount(item)).assertEqual(0)
    })

    it('keepsUnreadWhenReplyIsNewerThanLastRead', 0, (): void => {
      /* 反例：本次检查到的最后回复晚于用户上次已读时的最后回复 → 确实是未读 */
      const item: TrackedThread = createTracked('2', 10, 10)
      item.seenLastPostTs = SAMPLE_LAST_POST_TS - 5
      const outcome = applyStatus(item, createOkStatus(12), SAMPLE_LAST_POST_TS * 1000)

      expect(outcome.hasNewReplies).assertTrue()
      expect(item.totalReplies).assertEqual(12)
      expect(item.seenReplies).assertEqual(10)
      expect(unreadReplyCount(item)).assertEqual(2)
    })

    it('backfillsAuthorAndFidFromStatus', 0, (): void => {
      const item: TrackedThread = createTracked('1', 10, 10)
      item.author = ''
      item.authorid = 0
      item.fid = 0
      const status: ThreadTrackStatus = createOkStatus(10)
      status.author = 'gerraerd'
      status.authorid = 205511
      applyStatus(item, status, SAMPLE_LAST_POST_TS * 1000)

      expect(item.author).assertEqual('gerraerd')
      expect(item.authorid).assertEqual(205511)
      /* 已有作者不被覆盖（楼主不会变，本地先填的先赢） */
      const kept: TrackedThread = createTracked('2', 10, 10)
      applyStatus(kept, status, SAMPLE_LAST_POST_TS * 1000)
      expect(kept.author).assertEqual('样本作者')
    })

    it('keepsTrackingOnNetworkFailure', 0, (): void => {
      const item: TrackedThread = createTracked('1', 10, 10)
      const failed: ThreadTrackStatus = new ThreadTrackStatus()
      failed.reason = '网络请求失败'
      const outcome = applyStatus(item, failed, 2000)

      expect(outcome.shouldStop).assertFalse()
      expect(outcome.changed).assertTrue()
      expect(item.failCount).assertEqual(1)
      expect(item.lastError).assertEqual('网络请求失败')
      expect(item.lastCheckAt).assertEqual(0)
    })

    it('stopsTrackingOnInvalidThread', 0, (): void => {
      const item: TrackedThread = createTracked('1', 10, 10)
      const invalid: ThreadTrackStatus = new ThreadTrackStatus()
      invalid.invalid = true
      invalid.reason = '找不到主题'
      const outcome = applyStatus(item, invalid, 2000)

      expect(outcome.shouldStop).assertTrue()
      expect(outcome.stopReason).assertEqual(TrackStopReason.INVALID)
      expect(outcome.detail).assertEqual('找不到主题')
    })

    it('stopsTrackingOnLockedThread', 0, (): void => {
      const item: TrackedThread = createTracked('1', 10, 10)
      const locked: ThreadTrackStatus = createOkStatus(10)
      locked.locked = true
      const outcome = applyStatus(item, locked, SAMPLE_LAST_POST_TS * 1000)

      expect(outcome.shouldStop).assertTrue()
      expect(outcome.stopReason).assertEqual(TrackStopReason.INVALID)
      expect(outcome.detail).assertEqual('帖子已被锁定')
    })

    it('stopsTrackingWhenExpired', 0, (): void => {
      const item: TrackedThread = createTracked('1', 10, 10)
      const now: number = SAMPLE_LAST_POST_TS * 1000 + 3 * DAY_MS
      const outcome = applyStatus(item, createOkStatus(10), now)

      expect(outcome.shouldStop).assertTrue()
      expect(outcome.stopReason).assertEqual(TrackStopReason.EXPIRED)
    })

    it('handlesReplyCountDecrease', 0, (): void => {
      const item: TrackedThread = createTracked('1', 10, 10)
      const outcome = applyStatus(item, createOkStatus(8), SAMPLE_LAST_POST_TS * 1000)

      expect(outcome.hasNewReplies).assertFalse()
      expect(item.totalReplies).assertEqual(8)
      expect(unreadReplyCount(item)).assertEqual(0)
    })

    it('backfillsSubjectWithoutUnread', 0, (): void => {
      const item: TrackedThread = createTracked('1', 10, 10)
      const renamed: ThreadTrackStatus = createOkStatus(10)
      renamed.subject = '楼主改过的标题'
      const outcome = applyStatus(item, renamed, SAMPLE_LAST_POST_TS * 1000)

      expect(item.subject).assertEqual('楼主改过的标题')
      expect(outcome.hasNewReplies).assertFalse()
      expect(hasTrackedUnread(item)).assertFalse()
    })

    it('sortsUnreadFirst', 0, (): void => {
      const read: TrackedThread = createTracked('read', 10, 10)
      read.lastPostTs = SAMPLE_LAST_POST_TS + 100
      const unread: TrackedThread = createTracked('unread', 12, 10)
      unread.lastPostTs = SAMPLE_LAST_POST_TS
      const sorted: TrackedThread[] = sortTrackedThreads([read, unread])

      /* 有未读的排前，其次按最后活动时间倒序；入参数组顺序不被修改（元素同引用） */
      expect(sorted[0].tid).assertEqual('unread')
      expect(sorted[1].tid).assertEqual('read')
      expect(sorted.length).assertEqual(2)
    })

    it('validatesCachedItems', 0, (): void => {
      const item: TrackedThread = createTracked('44191387', 10, 10)
      const emptyTid: Object = JSON.parse('{"tid":""}')
      const wrongType: Object = JSON.parse('{"tid":"1","subject":1}')
      const notObject: Object = JSON.parse('[]')

      expect(isValidCachedTrackedThread(item)).assertTrue()
      expect(isValidCachedTrackedThread(emptyTid)).assertFalse()
      expect(isValidCachedTrackedThread(wrongType)).assertFalse()
      expect(isValidCachedTrackedThread(notObject)).assertFalse()
    })

    it('formatsStopNotices', 0, (): void => {
      const expired: TrackStopNotice =
        new TrackStopNotice('1', '样本标题', TrackStopReason.EXPIRED, '')
      const invalid: TrackStopNotice =
        new TrackStopNotice('2', '样本标题', TrackStopReason.INVALID, '找不到主题')
      const manual: TrackStopNotice =
        new TrackStopNotice('3', '样本标题', TrackStopReason.MANUAL, '')
      const noSubject: TrackStopNotice =
        new TrackStopNotice('44191387', '', TrackStopReason.INVALID, '')

      expect(formatTrackStopNotice(expired)).assertEqual('《样本标题》已多日无新回复，已停止跟踪')
      expect(formatTrackStopNotice(invalid)).assertEqual('《样本标题》已失效，已停止跟踪（找不到主题）')
      expect(formatTrackStopNotice(manual)).assertEqual('')
      expect(formatTrackStopNotice(noSubject)).assertEqual('《帖子 44191387》已失效，已停止跟踪')
    })

    it('labelsTrackedItem', 0, (): void => {
      const item: TrackedThread = createTracked('44191387', 554, 550)
      const base: number = SAMPLE_LAST_POST_TS * 1000

      expect(trackedSubjectLabel(item)).assertEqual('样本标题')
      expect(describeTrackedThread(item, base)).assertEqual('样本作者 · 554 条回复 · 剩余 2 天')
      item.subject = ''
      expect(trackedSubjectLabel(item)).assertEqual('帖子 44191387')
      item.author = ''
      expect(describeTrackedThread(item, base)).assertEqual('未知作者 · 554 条回复 · 剩余 2 天')
    })
  })
}
