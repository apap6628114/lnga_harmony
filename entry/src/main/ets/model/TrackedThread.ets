/**
 * 跟踪帖子（本地跟踪任务）数据模型。
 *
 * 跟踪任务按账号隔离（与通知 / 关注动态缓存一致）：检查帖子更新需要该账号的
 * 会话 token，切账号后各自维护自己的跟踪列表。
 *
 * 更新口径：**只认服务端总回复数（totalReplies）增加**。帖子主楼被编辑、标题被
 * 修改都不会改变该字段，因此不产生红点（标题变化仍会在检查时静默回填）。
 * 删除楼层会让总回复数减少，此时只同步基准、不报更新。
 */

/** 跟踪时长档位（天）：自最后一次服务端回复起算，满 N 天无新回复即停止跟踪。 */
export const TRACK_KEEP_DAYS_OPTIONS: number[] = [1, 2, 3, 7, 15]

/** 默认跟踪时长（天）。 */
export const TRACK_DEFAULT_KEEP_DAYS: number = 2

/** 同时跟踪的帖子上限（超出时拒绝新增并提示）。 */
export const TRACK_MAX_COUNT: number = 50

/** 前台跟踪轮询间隔（10 分钟）。单帖一次检查约 20KB 响应，50 帖一轮约 1MB。 */
export const TRACK_POLL_INTERVAL: number = 10 * 60 * 1000

/**
 * 单帖最小检查间隔（点开帖子触发的即时检查按此节流）。
 *
 * 从「跟踪」Tab 点开一条更新时会对该帖做一次即时检查（保证已读基准取到最新值），
 * 连续点开同一帖子不应重复发请求。
 */
export const TRACK_MIN_CHECK_INTERVAL: number = 60 * 1000

/** 一轮全量检查中，相邻两个帖子之间的请求间隔（避免请求突发触发风控）。 */
export const TRACK_CHECK_GAP: number = 400

/** 跟踪任务的停止原因。 */
export enum TrackStopReason {
  /** 帖子失效：被删除 / 锁定 / 待审核 / 权限不足。 */
  INVALID = 0,
  /** 长期无新回复：自最后回复起满 keepDays 天。 */
  EXPIRED = 1,
  /** 用户主动移除（不提示）。 */
  MANUAL = 2
}

/** 单个跟踪任务。 */
export class TrackedThread {
  /** NGA 主题 ID。 */
  tid: string = ''
  /** 主题标题（添加时取自帖子页，检查时静默回填）。 */
  subject: string = ''
  /** 楼主昵称。 */
  author: string = ''
  /** 楼主用户 ID。 */
  authorid: number = 0
  /** 版块 ID。 */
  fid: number = 0
  /** 版块名。 */
  forumName: string = ''
  /** 添加跟踪的时间戳（毫秒）。 */
  createdAt: number = 0
  /** 跟踪时长（天）：满 N 天无新回复即停止跟踪。 */
  keepDays: number = TRACK_DEFAULT_KEEP_DAYS
  /** 上一次成功检查的时间戳（毫秒）；0 表示尚未检查。 */
  lastCheckAt: number = 0
  /** 服务端最新总回复数（检查基准）。 */
  totalReplies: number = 0
  /** 已读基准：用户最后一次「看到」的总回复数。 */
  seenReplies: number = 0
  /**
   * 用户最后一次标记已读时，该帖的服务端最后回复时间（秒）；0 表示尚未记录。
   *
   * 用于判断「检查到的新回复是否其实已经被用户看过」：检查成功后若服务端最后回复时间
   * 不晚于本字段，说明这段内容是用户上次阅读时就已经存在的，直接把已读基准推进到最新，
   * 不产生红点。这样即使点开帖子时因最小检查间隔节流而没重新查询，也不会在下一轮
   * 轮询里冒出「刚看过又有新回复」的假未读。
   *
   * 刻意用**服务端时间戳**而不是设备时钟做比较：设备时钟偏快会让晚到的新回复被误判成
   * 「已看过」而吞掉一次提醒（时钟无关判据才是可靠的）。
   */
  seenLastPostTs: number = 0
  /** 服务端最后回复时间戳（秒）；0 表示未知。 */
  lastPostTs: number = 0
  /** 服务端标记的锁定态。 */
  locked: boolean = false
  /** 连续检查失败次数（网络失败不清零、不影响跟踪）。 */
  failCount: number = 0
  /** 最近一次检查失败原因（空串表示无错误）。 */
  lastError: string = ''
}

/**
 * 单帖状态检查结果（网络层输出，解析后）。
 *
 * 三种结局互斥：
 * - `ok=true, invalid=false`：取到状态，字段有效；
 * - `ok=false, invalid=true`：服务端明确报告帖子不可读（失效），调用方应停止跟踪；
 * - `ok=false, invalid=false`：请求/解析失败（网络问题），保留跟踪、下轮重试。
 */
export class ThreadTrackStatus {
  /** 是否成功取到帖子状态。 */
  ok: boolean = false
  /** 帖子是否已失效（被删除 / 锁定 / 待审核 / 权限不足）。 */
  invalid: boolean = false
  /** 失效原因或失败原因（用于日志与停止提示）。 */
  reason: string = ''
  /** 服务端总回复数。 */
  totalReplies: number = 0
  /** 服务端最后回复时间戳（秒）。 */
  lastPostTs: number = 0
  /** 主题标题（检查时静默回填）。 */
  subject: string = ''
  /** 楼主昵称（检查响应 `__T.author` 回填）。 */
  author: string = ''
  /** 楼主用户 ID（检查响应 `__T.authorid` 回填）。 */
  authorid: number = 0
  /** 版块 ID。 */
  fid: number = 0
  /** 服务端锁定标记。 */
  locked: boolean = false
}

/** 停止跟踪的通知（由 AppStore 消费为 Toast 文案）。 */
export class TrackStopNotice {
  /** 主题 ID。 */
  tid: string = ''
  /** 主题标题（空串时以 tid 兜底展示）。 */
  subject: string = ''
  /** 停止原因。 */
  reason: number = TrackStopReason.MANUAL
  /** 失效原因等补充信息。 */
  detail: string = ''

  constructor(tid: string, subject: string, reason: number, detail: string = '') {
    this.tid = tid
    this.subject = subject
    this.reason = reason
    this.detail = detail
  }
}
