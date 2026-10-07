/**
 * 「智能去水」服务 —— 抓全帖楼层、按本地规则剔掉水楼层、重组成一份新的本地存档。
 *
 * ## 与离线保存的关系
 *
 * 产出物就是一份普通的 `SavedThread` 存档，只是**键不同**：
 * - 离线保存：`archiveId === tid`（原帖全量存档）
 * - 智能去水：`archiveId === tid + '-w'`（去水版，`derivedFrom === tid`）
 *
 * 两者共用同一个 `tid`，因此在「保存的帖子」列表里并列出现、都能离线阅读、
 * 都能「在线模式打开」回到真实主题；键不同所以互不覆盖。同一帖重复去水会
 * **覆盖**上一份去水版（而不是堆出一串），列表不会因此长草。
 *
 * ## 全帖覆盖与「不设页数上限」
 *
 * 产品要求是「帖子有多少页就抓多少页」，因此这里**没有**全帖 AI 总结那种
 * 「20 页上限 + 头尾取样」的策略：逐页顺序抓，pages 从 1 到服务端总页数。
 * 代价是上千页的帖子会跑几十分钟，所以：
 * - 全程发布进度（含**剩余时间估算**），用户随时可取消；
 * - 任务期间申请 dataTransfer 长时任务（见 `WaterFilterBackgroundTask`），
 *   退到后台仍能继续；申请不到时在进度提示里如实告知「请保持应用在前台」；
 * - 单页失败**只跳过该页**并计数，不中断整帖（上千页里偶发失败是常态）；
 * - 有**安全阀**（保留楼层数与输出字符数上限）：触顶立即停止扫描并如实汇报，
 *   避免在手机上 OOM 被系统杀死——那比拿一份标注清楚的局部结果更糟。
 *
 * ## 重组：合成「与官方同形状」的页
 *
 * 存档的取舍单位是**原始行（raw row）**而不是渲染后的 PostInfo：判定用解析后的
 * PostInfo（有 `lou`/`attachs`/`comments` 等语义字段），保留时却把该行**原样**
 * 塞进新页（图片、楼中楼、热评、投票全都不动）。这样去水版与原帖走完全相同的
 * 渲染管线，也不会因为字段裁剪而丢内容。
 *
 * 合成页只保留被引用的 `__U`（作者信息），并按页裁剪：`__U` 若不裁剪地复制到
 * 每一页，1000 页的存档光作者表就会膨胀到上百 MB。承载 `__GROUPS`（用户组名）
 * 的那一条**每页都带上**，否则除首页外的楼层会丢掉用户组显示。
 *
 * 内存策略：**不累积整页 raw**。每页解析后立即判定，只留下通过的原始行，
 * 其余（含该页的 `__U` 大表）当场变成垃圾。
 */

import { common } from '@kit.AbilityKit'
import { appStore } from '../store/AppStore'
import { fetchThreadRaw, fillThreadResult } from './api/ThreadApi'
import { compileRuleSet, judgeFloor, WaterJudgeInput, WaterRuleSet } from './WaterFilterEngine'
import { derivedArchiveIdOf } from '../store/SavedThreadStore'
import { SavedThread } from '../model/SavedThread'
import { ThreadResult } from '../model/ThreadResult'
import { WaterFilterRule } from '../model/WaterFilterRule'
import { waterFilterProgress, WaterFilterPhase } from '../common/media/WaterFilterProgress'
import { WaterFilterBackgroundTask } from '../common/managers/WaterFilterBackgroundTask'
import { Logger, DOMAIN_SERVICE, formatError } from '../common/utils/Logger'
import type { PostInfo } from '../model/PostInfo'

const logger = new Logger(DOMAIN_SERVICE, 'ThreadWaterFilter')

/** 相邻两页请求之间的最小间隔（毫秒），对 NGA 服务器保持节流礼貌。 */
const PAGE_FETCH_INTERVAL_MS: number = 250

/** 合成页每页的楼层数（沿用 NGA 的每页 20 楼，排版与在线一致）。 */
const ROWS_PER_PAGE: number = 20

/**
 * 安全阀：保留楼层的数量上限。
 *
 * 触顶后**立即停止扫描并落盘**（而不是继续抓完再把多余的丢掉）：触顶意味着
 * 这份存档已经接近手机内存上限，继续抓只会增加 OOM 风险。触发时结果里会明确
 * 说明「仅覆盖到第 N 页」。
 */
const MAX_KEPT_ROWS: number = 8000

/**
 * 安全阀：输出正文的字符数上限（近似值，按每行正文长度 + 固定开销估算）。
 *
 * 为什么不做精确统计：要拿精确字节数就得逐行 `JSON.stringify`，而上万行逐行
 * 序列化本身就是可观的额外开销。这个上限的作用是「兜住最坏情况」，不是精确
 * 配额，用廉价估算即可。
 */
const MAX_OUTPUT_CHARS: number = 8000000

/** 每行正文之外的固定开销估算（作者信息、时间、附件元数据等）。 */
const ROW_OVERHEAD_CHARS: number = 400

/**
 * 单页平均耗时估算（毫秒）：页间节流 + 实测请求耗时量级。
 *
 * 只用于确认弹窗里的「预计耗时约多少」与进度条的剩余时间参考，不参与任何
 * 逻辑判定——真实进度一律按已完成页数计算，展示值是实测而非这个常量。
 */
const AVERAGE_PAGE_COST_MS: number = 1100

/**
 * 估算全帖去水的耗时。
 *
 * @param totalPages - 总页数
 * @returns 估算耗时（毫秒）
 */
export function estimateWaterFilterMs(totalPages: number): number {
  return Math.max(1000, Math.round(totalPages * AVERAGE_PAGE_COST_MS))
}

/**
 * 把时长格式化为可读文案。
 *
 * @param ms - 毫秒
 * @returns 「40 秒」「8 分钟」「1 小时 20 分钟」形式
 */
export function formatDuration(ms: number): string {
  const seconds: number = Math.max(1, Math.round(ms / 1000))
  if (seconds < 60) {
    return String(seconds) + ' 秒'
  }
  const minutes: number = Math.round(seconds / 60)
  if (minutes < 60) {
    return String(minutes) + ' 分钟'
  }
  const hours: number = Math.floor(minutes / 60)
  const restMinutes: number = minutes % 60
  if (restMinutes === 0) {
    return String(hours) + ' 小时'
  }
  return String(hours) + ' 小时 ' + String(restMinutes) + ' 分钟'
}

/** 去水版标题后缀：与原帖同名的条目必须能在列表里一眼区分。 */
export const DERIVED_SUBJECT_SUFFIX: string = '（去水版）'

/**
 * 去水任务结果。
 */
export class WaterFilterOutcome {
  /** 是否产出了去水版存档。 */
  ok: boolean = false
  /** 是否被用户取消（与失败区分，供 UI 特判文案）。 */
  cancelled: boolean = false
  /** 结果/错误文案。 */
  message: string = ''
  /** 去水版存档标识（ok=true 时有效）。 */
  archiveId: string = ''
  /** 服务端报告的总页数。 */
  totalPages: number = 0
  /** 实际扫到的最后一页（触顶或取消时小于总页数）。 */
  coveredPages: number = 0
  /** 成功解析的页数。 */
  fetchedPages: number = 0
  /** 拉取或解析失败的页数（已跳过）。 */
  failedPages: number = 0
  /** 保留的楼层数。 */
  keptFloors: number = 0
  /** 判为水并剔除的楼层数。 */
  removedFloors: number = 0
  /** 产出的本地页数。 */
  outputPages: number = 0
  /** 是否因安全阀提前停止。 */
  capped: boolean = false
}

/**
 * 保留楼层的工作项：原始行 + 该行作者在 `__U` 中的条目。
 */
class KeptFloor {
  /** 合成页 `__R` 的键（楼层 pid；结构行退化为原键）。 */
  pid: string = ''
  /** 楼号（用于取 lastLou）。 */
  lou: number = 0
  /** 原始 raw row（原样保留）。 */
  row: Record<string, Object> = {}
  /** 该行作者在 `__U` 中的键（authorid）。 */
  userKey: string = ''
  /** 该行作者在 `__U` 中的条目。 */
  user: Record<string, Object> = {}
  /** 是否捕获到作者条目。 */
  hasUser: boolean = false
}

/** `__U` 中承载用户组表（`__GROUPS`）的那一条。 */
class GroupsCarrier {
  /** 该条目在 `__U` 中的键。 */
  key: string = ''
  /** 条目本体。 */
  value: Record<string, Object> = {}
}

export class ThreadWaterFilterService {
  /** 是否有任务在跑。 */
  private running: boolean = false
  /** 取消标记：置位后当前页完成即终止。 */
  private cancelled: boolean = false
  /** 任务代际：让取消或换代后仍在途的回调失效。 */
  private generation: number = 0
  /** 数据传输长时任务控制器（惰性创建）。 */
  private background: WaterFilterBackgroundTask | null = null
  /** 长时任务是否被系统暂停（暂停时在进度提示里说明）。 */
  private backgroundSuspended: boolean = false

  /**
   * 是否正在执行去水任务。
   */
  get isRunning(): boolean {
    return this.running
  }

  /**
   * 注入 UIAbility 上下文并注册长时任务监听（EntryAbility.onCreate 调用）。
   *
   * @param context - UIAbility 上下文
   */
  initialize(context: common.UIAbilityContext): void {
    if (this.background === null) {
      this.background = new WaterFilterBackgroundTask({
        onCancelled: (): void => {
          // 系统收回了长时任务（用户在通知里关闭 / 系统策略）：必须终止在途任务
          logger.warn('water filter background task cancelled by system, aborting run')
          this.cancel()
        },
        onSuspended: (suspended: boolean): void => {
          this.backgroundSuspended = suspended
        }
      })
    }
    this.background.initialize(context)
  }

  /**
   * 释放长时任务与监听（EntryAbility.onDestroy 调用）。
   */
  shutdown(): void {
    const background: WaterFilterBackgroundTask | null = this.background
    if (background !== null) {
      background.shutdown()
    }
  }

  /**
   * 请求取消当前去水任务。
   */
  cancel(): void {
    if (!this.running) {
      return
    }
    this.cancelled = true
  }

  /**
   * 执行一次全帖去水。
   *
   * **总页数由本方法自行探测**（请求末页读 `__ROWS`/`__R__ROWS_PAGE`），不依赖
   * 调用方传入的页数：调用方手里的页数可能是「只看楼主」这类**服务端筛选后**的
   * 页数、也可能来自单帖兜底响应，用它们决定抓取范围会漏抓大半个帖子。
   * `hintTotalPages` 只用于探测完成前的进度文案与耗时估算。
   *
   * @param tid - NGA 主题 ID
   * @param subject - 主题标题（服务端 `__T` 缺失时的兜底）
   * @param hintTotalPages - 调用方已知的总页数（仅作提示，探测失败时兜底）
   * @param level - 去水严格等级
   * @param rules - 自定义去水规则
   * @returns 去水结果
   */
  async run(tid: string, subject: string, hintTotalPages: number, level: number,
    rules: WaterFilterRule[]): Promise<WaterFilterOutcome> {
    const outcome: WaterFilterOutcome = new WaterFilterOutcome()
    if (this.running) {
      outcome.message = '已有去水任务进行中'
      return outcome
    }
    if (tid.length === 0) {
      outcome.message = '帖子信息不完整，请稍后再试'
      return outcome
    }
    const token: string = appStore.auth.token
    if (!appStore.getSession(token)) {
      outcome.message = '请先登录'
      return outcome
    }

    this.running = true
    this.cancelled = false
    this.generation++
    const generation: number = this.generation
    outcome.totalPages = hintTotalPages

    const ruleSet: WaterRuleSet = compileRuleSet(level, rules)
    const kept: KeptFloor[] = []
    const seenPids: Set<string> = new Set<string>()
    const emptyBlacklist: Set<string> = new Set<string>()
    const emptyKeywords: string[] = []
    const emptyNotes: Record<string, string> = {}
    let groupsCarrierKey: string = ''
    let groupsCarrierValue: Record<string, Object> | null = null
    let forumInfo: Record<string, Object> | null = null
    let threadInfo: Record<string, Object> | null = null
    let removedFloors: number = 0
    let outputChars: number = 0
    let capped: boolean = false
    let coveredPages: number = 0
    const startedAt: number = Date.now()
    let backgroundOk: boolean = false

    try {
      const background: WaterFilterBackgroundTask | null = this.background
      if (background !== null) {
        backgroundOk = await background.start()
      }
      // 先探测真实总页数：只看楼主等筛选态下的页数是筛选后的值，不能作为抓取范围
      waterFilterProgress.show(0, '正在确认帖子页数…', this.hintOf('', backgroundOk),
        WaterFilterPhase.FETCHING)
      const probed: number = await probeTotalPages(token, tid)
      if (this.isAborted(generation)) {
        outcome.cancelled = true
        outcome.message = '已取消去水'
        return outcome
      }
      const totalPages: number = probed > 0 ? probed : hintTotalPages
      if (totalPages < 1) {
        outcome.message = '无法确认帖子页数，帖子可能已失效'
        return outcome
      }
      outcome.totalPages = totalPages

      waterFilterProgress.show(0, '准备抓取全帖…', this.hintOf(
        formatDuration(estimateWaterFilterMs(totalPages)), backgroundOk),
        WaterFilterPhase.FETCHING)

      for (let page: number = 1; page <= totalPages; page++) {
        if (this.isAborted(generation)) {
          outcome.cancelled = true
          outcome.message = '已取消去水'
          return outcome
        }
        // 节流：相邻两页之间至少间隔 PAGE_FETCH_INTERVAL_MS
        if (page > 1) {
          await this.sleep(PAGE_FETCH_INTERVAL_MS)
          if (this.isAborted(generation)) {
            outcome.cancelled = true
            outcome.message = '已取消去水'
            return outcome
          }
        }
        waterFilterProgress.show(
          Math.round((page - 1) / totalPages * 100),
          '第 ' + String(page) + '/' + String(totalPages) + ' 页 · 已去 ' +
            String(removedFloors) + ' 层',
          this.hintOf(this.etaOf(startedAt, page - 1, totalPages), backgroundOk),
          WaterFilterPhase.FETCHING
        )

        const fetched = await fetchThreadRaw(token, tid, '', '', String(page))
        if (this.isAborted(generation)) {
          outcome.cancelled = true
          outcome.message = '已取消去水'
          return outcome
        }
        if (!fetched.raw) {
          outcome.failedPages++
          logger.warn('water-filter page fetch failed tid=%{public}s page=%{public}d: %{public}s',
            tid, page, fetched.error)
          coveredPages = page
          continue
        }
        // 用当前解析器解释本页（空黑名单/空关键词，与离线保存同口径：黑名单与
        // 关键词屏蔽在**阅读时**生效，不参与存档内容的取舍）
        const pageResult: ThreadResult = new ThreadResult()
        try {
          fillThreadResult(fetched.raw, pageResult, emptyBlacklist, emptyKeywords, emptyNotes)
        } catch (e) {
          outcome.failedPages++
          logger.warn('water-filter page parse failed tid=%{public}s page=%{public}d: %{public}s',
            tid, page, formatError(e))
          coveredPages = page
          continue
        }
        outcome.fetchedPages++
        coveredPages = page

        const dataObj: Record<string, Object> | null = readRecord(fetched.raw, 'data')
        if (dataObj !== null) {
          if (forumInfo === null) {
            forumInfo = readRecord(dataObj, '__F')
          }
          if (threadInfo === null) {
            threadInfo = readRecord(dataObj, '__T')
          }
        }
        let users: Record<string, Object> = {}
        if (dataObj !== null) {
          const rawUsers: Record<string, Object> | null = readRecord(dataObj, '__U')
          if (rawUsers !== null) {
            users = rawUsers
          }
        }
        if (groupsCarrierValue === null) {
          const carrier: GroupsCarrier | null = findGroupsCarrier(users)
          if (carrier !== null) {
            groupsCarrierKey = carrier.key
            groupsCarrierValue = carrier.value
          }
        }

        const postsByPid: Map<string, PostInfo> = new Map<string, PostInfo>()
        for (let pi: number = 0; pi < pageResult.posts.length; pi++) {
          const post: PostInfo = pageResult.posts[pi]
          postsByPid.set(String(post.pid), post)
        }
        let rows: Record<string, Object> = {}
        if (dataObj !== null) {
          const rawRows: Record<string, Object> | null = readRecord(dataObj, '__R')
          if (rawRows !== null) {
            rows = rawRows
          }
        }
        const rowKeys: string[] = Object.keys(rows)
        for (let ri: number = 0; ri < rowKeys.length; ri++) {
          const rowKey: string = rowKeys[ri]
          const rawRow: Object | undefined = rows[rowKey]
          if (rawRow === undefined || rawRow === null) {
            continue
          }
          const row: Record<string, Object> = rawRow as Record<string, Object>
          const pidStr: string = String(row['pid'] ?? '')
          const post: PostInfo | undefined = pidStr.length > 0 ? postsByPid.get(pidStr) : undefined
          if (post !== undefined) {
            if (seenPids.has(pidStr)) {
              // 相邻页偶有重复的尾楼，按 pid 去重，避免去水版里同楼出现两次
              continue
            }
            const verdictInput: WaterJudgeInput = new WaterJudgeInput()
            verdictInput.content = post.content
            verdictInput.isOp = post.lou === 0
            verdictInput.hasAttach = post.attachs.length > 0
            verdictInput.hasDiscussion = post.comments.length > 0 || post.hotReplies.length > 0
            if (judgeFloor(verdictInput, ruleSet).water) {
              removedFloors++
              continue
            }
            seenPids.add(pidStr)
          }
          // 通过判定（或不属于被判定楼层的结构行）：保留原始行
          if (kept.length >= MAX_KEPT_ROWS || outputChars >= MAX_OUTPUT_CHARS) {
            capped = true
            break
          }
          const entry: KeptFloor = new KeptFloor()
          entry.pid = pidStr.length > 0 ? pidStr : rowKey
          entry.lou = Number(row['lou'] ?? 0)
          entry.row = row
          const userKey: string = String(row['authorid'] ?? '')
          if (userKey.length > 0) {
            const user: Object | undefined = users[userKey]
            if (user !== undefined && user !== null) {
              entry.userKey = userKey
              entry.user = user as Record<string, Object>
              entry.hasUser = true
            }
          }
          kept.push(entry)
          outputChars += String(row['content'] ?? '').length + ROW_OVERHEAD_CHARS
        }
        if (capped) {
          logger.warn('water-filter capped tid=%{public}s page=%{public}d kept=%{public}d',
            tid, page, kept.length)
          break
        }
      }

      if (this.isAborted(generation)) {
        outcome.cancelled = true
        outcome.message = '已取消去水'
        return outcome
      }
      outcome.capped = capped
      outcome.coveredPages = coveredPages
      outcome.keptFloors = kept.length
      outcome.removedFloors = removedFloors

      if (kept.length === 0) {
        outcome.message = outcome.failedPages > 0
          ? '所有页都抓取失败，未生成去水版'
          : '没有需要保留的楼层，未生成去水版'
        return outcome
      }

      waterFilterProgress.show(100, '正在整理 ' + String(kept.length) + ' 层…',
        this.hintOf('', backgroundOk), WaterFilterPhase.PACKING)
      const outputPages: Object[] = buildOutputPages(kept, groupsCarrierKey, groupsCarrierValue,
        forumInfo, threadInfo)

      const thread: SavedThread = new SavedThread()
      thread.archiveId = derivedArchiveIdOf(tid)
      thread.tid = tid
      thread.derivedFrom = tid
      thread.savedAt = Date.now()
      thread.savedPages = outputPages.length
      // 本地页数即这份存档的「总页数」：去水版没有对应的服务端分页
      thread.totalPages = outputPages.length
      thread.rawPages = outputPages
      thread.lastLou = kept[kept.length - 1].lou
      fillDerivedMetadata(thread, threadInfo, forumInfo, subject)

      if (this.isAborted(generation)) {
        outcome.cancelled = true
        outcome.message = '已取消去水'
        return outcome
      }
      await appStore.savedThreadStore.save(thread)

      outcome.ok = true
      outcome.archiveId = thread.archiveId
      outcome.outputPages = outputPages.length
      outcome.message = buildSummary(outcome)
      logger.info(
        'water-filter done tid=%{public}s covered=%{public}d/%{public}d failed=%{public}d kept=%{public}d removed=%{public}d out=%{public}d capped=%{public}s',
        tid, coveredPages, totalPages, outcome.failedPages, kept.length, removedFloors,
        outputPages.length, String(capped))
      return outcome
    } catch (e) {
      outcome.message = '去水失败：' + formatError(e)
      logger.error('water-filter failed tid=%{public}s: %{public}s', tid, formatError(e))
      return outcome
    } finally {
      if (generation === this.generation) {
        this.running = false
      }
      waterFilterProgress.hide()
      const bg: WaterFilterBackgroundTask | null = this.background
      if (bg !== null) {
        bg.stop()
      }
    }
  }

  /**
   * 任务是否应终止（用户取消或代际已换）。
   *
   * @param generation - 进入本次任务时捕获的代际
   * @returns 是否终止
   */
  private isAborted(generation: number): boolean {
    return this.cancelled || generation !== this.generation
  }

  /**
   * 由「已处理页数 + 已耗时」估算剩余时长文案。
   *
   * 只在处理了足够页数（>=3）之后才给估算：前两页的耗时（含首包、鉴权）不具
   * 代表性，据此给出的估算会明显偏大，反而误导用户。
   *
   * @param startedAt - 任务开始时间戳
   * @param donePages - 已处理页数
   * @param totalPages - 总页数
   * @returns 剩余时长文案；无法估算时返回空串
   */
  private etaOf(startedAt: number, donePages: number, totalPages: number): string {
    if (donePages < 3 || donePages >= totalPages) {
      return ''
    }
    const elapsed: number = Date.now() - startedAt
    if (elapsed <= 0) {
      return ''
    }
    const remaining: number = Math.round(elapsed / donePages * (totalPages - donePages))
    return '约剩 ' + formatDuration(remaining)
  }

  /**
   * 组装进度提示行：剩余时间 +（长时任务不可用或暂停时的）前台提示。
   *
   * @param eta - 剩余时间文案（可空）
   * @param backgroundOk - 是否成功持有长时任务
   * @returns 提示文案
   */
  private hintOf(eta: string, backgroundOk: boolean): string {
    if (this.backgroundSuspended) {
      return '后台任务已被系统暂停'
    }
    if (!backgroundOk) {
      // 无长时任务：退到后台会被冻结，如实告知用户不要切走
      return eta.length > 0 ? eta + ' · 请保持应用在前台' : '请保持应用在前台'
    }
    return eta
  }

  /**
   * 简单延时。
   */
  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve()
      }, ms)
    })
  }
}

/**
 * 读取 Record 字段为子 Record。
 *
 * ArkTS 下不能直接把 `Object` 当 `Record` 用，必须显式判空 + 断言，故集中到
 * 这一处，避免每个读取点都写三段式判空。
 *
 * @param source - 源对象
 * @param key - 字段名
 * @returns 子对象；不存在或不是对象时返回 null
 */
function readRecord(source: Record<string, Object>, key: string): Record<string, Object> | null {
  const value: Object | undefined = source[key]
  if (value === undefined || value === null) {
    return null
  }
  return value as Record<string, Object>
}

/**
 * 探测主题的真实总页数。
 *
 * 请求末页（`page=e`）读 `__ROWS`（主题总行数）与 `__R__ROWS_PAGE`（每页行数）
 * 按 `parseThreadData` 同款公式换算，与 `locatePidPage` 的口径一致。这样拿到的是
 * **未经筛选**的整帖页数——调用方手里那个页数在「只看楼主」等筛选态下是筛选后的值。
 *
 * 不做重试：探测失败（网络抖动）时返回 -1，由调用方回退到调用方传入的提示页数，
 * 不因为一次探测失败就整个任务作废。
 *
 * @param token - 会话令牌
 * @param tid - NGA 主题 ID
 * @returns 总页数；无法确定时返回 -1
 */
async function probeTotalPages(token: string, tid: string): Promise<number> {
  try {
    const last = await fetchThreadRaw(token, tid, '', '', 'e')
    if (!last.raw) {
      logger.warn('water-filter probe failed tid=%{public}s: %{public}s', tid, last.error)
      return -1
    }
    const dataObj: Record<string, Object> | null = readRecord(last.raw, 'data')
    if (dataObj === null) {
      return -1
    }
    const totalRows: number = Number(dataObj['__ROWS'] ?? 0)
    const rowsPerPage: number = Math.max(20, Number(dataObj['__R__ROWS_PAGE'] ?? 0))
    if (totalRows > 0) {
      return Math.ceil(totalRows / rowsPerPage)
    }
    // __ROWS 缺失（异常响应）时按末页行数估算，与 parseThreadData 的降级口径一致
    const rows: Record<string, Object> | null = readRecord(dataObj, '__R')
    if (rows !== null) {
      const rowCount: number = Object.keys(rows).length
      if (rowCount > 0) {
        return Math.ceil(rowCount / rowsPerPage)
      }
    }
    return -1
  } catch (e) {
    logger.warn('water-filter probe raised tid=%{public}s: %{public}s', tid, formatError(e))
    return -1
  }
}

/**
 * 在 `__U` 中找出承载 `__GROUPS`（用户组名表）的那一条。
 *
 * `fillThreadResult` 会扫描 `__U` 的所有条目、取第一个带 `__GROUPS` 的来建
 * 「用户组 ID → 组名」映射；合成页必须把这条一起带上，否则除首页外的楼层
 * 会因为查不到组名而退化为数字组 ID。
 *
 * @param users - 源页的 `__U`
 * @returns 承载条目；不存在时返回 null
 */
function findGroupsCarrier(users: Record<string, Object>): GroupsCarrier | null {
  const keys: string[] = Object.keys(users)
  for (let i: number = 0; i < keys.length; i++) {
    const value: Object | undefined = users[keys[i]]
    if (value === undefined || value === null) {
      continue
    }
    const entry: Record<string, Object> = value as Record<string, Object>
    if (entry['__GROUPS'] !== undefined && entry['__GROUPS'] !== null) {
      const carrier: GroupsCarrier = new GroupsCarrier()
      carrier.key = keys[i]
      carrier.value = entry
      return carrier
    }
  }
  return null
}

/**
 * 把保留楼层重组成「与官方同形状」的页序列。
 *
 * 每页只带本页楼层引用到的作者条目（加一条用户组载体），避免作者表被复制到
 * 每一页而撑爆存档。
 *
 * @param kept - 保留楼层（按原帖顺序）
 * @param groupsCarrierKey - 用户组载体的键
 * @param groupsCarrierValue - 用户组载体的值
 * @param forumInfo - 版块信息（`__F`）
 * @param threadInfo - 主题信息（`__T`）
 * @returns 合成页数组（每页形状与在线响应一致）
 */
function buildOutputPages(kept: KeptFloor[], groupsCarrierKey: string,
  groupsCarrierValue: Record<string, Object> | null, forumInfo: Record<string, Object> | null,
  threadInfo: Record<string, Object> | null): Object[] {
  const pages: Object[] = []
  const total: number = kept.length
  const pageCount: number = Math.max(1, Math.ceil(total / ROWS_PER_PAGE))
  const emptyRecord: Record<string, Object> = {}
  for (let p: number = 0; p < pageCount; p++) {
    const start: number = p * ROWS_PER_PAGE
    const end: number = Math.min(total, start + ROWS_PER_PAGE)
    const rowMap: Record<string, Object> = {}
    const userMap: Record<string, Object> = {}
    for (let i: number = start; i < end; i++) {
      const entry: KeptFloor = kept[i]
      rowMap[entry.pid] = entry.row
      if (entry.hasUser) {
        userMap[entry.userKey] = entry.user
      }
    }
    if (groupsCarrierValue !== null) {
      userMap[groupsCarrierKey] = groupsCarrierValue
    }
    const dataObj: Record<string, Object> = {}
    dataObj['__R'] = rowMap
    dataObj['__U'] = userMap
    dataObj['__F'] = forumInfo !== null ? forumInfo : emptyRecord
    dataObj['__T'] = threadInfo !== null ? threadInfo : emptyRecord
    // __ROWS 报「全帖保留楼层总数」而非本页行数：与在线响应语义一致
    // （每页都报告主题总行数），也让 parseThreadData 推出的总页数与实际页数吻合
    dataObj['__ROWS'] = total
    dataObj['__R__ROWS_PAGE'] = ROWS_PER_PAGE
    dataObj['__PAGE'] = p + 1
    const rawPage: Record<string, Object> = {}
    rawPage['data'] = dataObj
    pages.push(rawPage)
  }
  return pages
}

/**
 * 填出去水版的元数据（版块/标题/作者），并把标题加上后缀以便列表区分。
 *
 * @param thread - 待填充的去水版存档
 * @param threadInfo - 源主题信息（`__T`，可能为 null）
 * @param forumInfo - 源版块信息（`__F`，可能为 null）
 * @param fallbackSubject - 标题兜底（调用方持有的主题标题）
 */
function fillDerivedMetadata(thread: SavedThread, threadInfo: Record<string, Object> | null,
  forumInfo: Record<string, Object> | null, fallbackSubject: string): void {
  let subject: string = fallbackSubject
  if (threadInfo !== null) {
    // __T 可能是直接对象，也可能是按 tid 键的映射，取第一个带 tid 的条目
    let rawT: Record<string, Object> | null = null
    if (threadInfo['tid'] !== undefined) {
      rawT = threadInfo
    } else {
      const tKeys: string[] = Object.keys(threadInfo)
      for (let i: number = 0; i < tKeys.length; i++) {
        const candidate: Record<string, Object> | null = readRecord(threadInfo, tKeys[i])
        if (candidate !== null && candidate['tid'] !== undefined) {
          rawT = candidate
          break
        }
      }
    }
    if (rawT !== null) {
      const infoSubject: string = String(rawT['subject'] ?? '')
      if (infoSubject.length > 0) {
        subject = infoSubject
      }
      thread.fid = Number(rawT['fid'] ?? 0)
      thread.author = String(rawT['author'] ?? '')
      thread.authorid = Number(rawT['authorid'] ?? 0)
    }
  }
  if (forumInfo !== null) {
    thread.forumName = String(forumInfo['name'] ?? '')
  }
  if (subject.length === 0) {
    subject = '帖子'
  }
  thread.subject = subject + DERIVED_SUBJECT_SUFFIX
}

/**
 * 组装结果文案：覆盖范围、剔除量、失败页与安全阀都如实说明。
 *
 * @param outcome - 去水结果
 * @returns 用户可读文案
 */
function buildSummary(outcome: WaterFilterOutcome): string {
  let text: string = '已生成去水版：保留 ' + String(outcome.keptFloors) + ' 层，去掉 ' +
    String(outcome.removedFloors) + ' 层'
  if (outcome.capped) {
    text += '（已到安全上限，仅覆盖前 ' + String(outcome.coveredPages) + ' 页）'
  } else if (outcome.coveredPages < outcome.totalPages) {
    text += '（覆盖前 ' + String(outcome.coveredPages) + ' 页）'
  }
  if (outcome.failedPages > 0) {
    text += '，' + String(outcome.failedPages) + ' 页未取到'
  }
  return text
}

/** 全局去水服务单例。 */
export const threadWaterFilterService: ThreadWaterFilterService = new ThreadWaterFilterService()
