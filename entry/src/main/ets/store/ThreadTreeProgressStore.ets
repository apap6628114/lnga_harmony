import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { BaseStore } from './BaseStore'
import { DomainIds, PersistenceCatalog } from '../common/persistence/PersistenceCatalog'
import { DomainSpec } from '../common/persistence/PersistenceTypes'
import { Logger, DOMAIN_STORE, formatError } from '../common/utils/Logger'

const logger = new Logger(DOMAIN_STORE, 'ThreadTreeProgressStore')

/**
 * 单帖「递进树」阅读进度条目。
 *
 * 与列表阅读进度（`ReadingProgressStore.ReadingProgressEntry`）**不是同一张表**：
 * 列表页以「服务端页码 + 锚点楼层 pid」定位，重新进入时先整页加载再页内定位；
 * 递进树页一次性持有全帖、视口里是**扁平可见行**，定位方式变成「按 pid 找行 →
 * 被折叠时先展开所属根 → 居中滚动」，因此记录的是树内锚点：
 *
 * - `pid`：锚点楼层 pid（主楼在 HTML 通道恒为 0，`findIndexByPid(0)` 可正常命中）；
 * - `rootPid`：锚点所属根楼层 pid（恢复时先展开该根，避免锚点被折叠隐藏）；
 * - `page`：锚点楼层所属服务端页码（诊断快照；切列表时以抓取时的 `pageByPid` 为准，
 *   两者同源，见 `ThreadTreePanel.recordTreeProgress`）。
 *
 * 刻意**不记录扁平行下标**：下标随折叠/展开与只看楼主过滤漂移，用它兜底会把用户
 * 带到无关楼层；pid 找不到（楼层被删、树结构变化）时宁可提示原位置不可用。
 */
export class ThreadTreeProgressEntry {
  /** 主题 tid。 */
  tid: string = ''
  /** 锚点楼层 pid；主楼在 HTML 通道为 0，小于 0 表示无有效锚点。 */
  pid: number = -1
  /** 锚点所属根楼层 pid（主楼根为 0；-1 表示未知）。 */
  rootPid: number = -1
  /** 锚点楼层所属服务端页码（从 1 开始，诊断快照）。 */
  page: number = 1
  /** 最近更新时间戳（LRU 淘汰依据）。 */
  ts: number = 0
}

/** 递进树阅读进度最多保留的帖子数（按最近阅读时间淘汰）。 */
const TREE_PROGRESS_MAX_COUNT: number = 200

/**
 * 返回递进树阅读进度域的 Preferences 键（统一命名空间 `v2.tree_reading_progress`，与账号无关）。
 *
 * @returns 键名；域未登记时为空串
 */
function treeProgressDomainKey(): string {
  const spec: DomainSpec | null = PersistenceCatalog.byId(DomainIds.TREE_READING_PROGRESS)
  return spec === null ? '' : spec.fullKey()
}

/**
 * 帖子「递进树」阅读进度管理（设备级数据，不按账号物理隔离）。
 *
 * 记录每个帖子在树视图里最近一次阅读到的锚点行（pid / 所属根 / 页码），
 * 下次以递进树打开同帖时用于恢复树内位置。持久化到统一命名空间的
 * `v2.tree_reading_progress`，与列表阅读进度域（`v2.reading_progress`）互不覆盖。
 *
 * public 方法上的 `uid` 参数与其他设备级 Store 保持一致：仅为兼容既有调用点保留，
 * 函数体内不再使用（数据是设备级的；「是否记录」由调用方按登录态与设置开关判定）。
 *
 * 读取侧按**不可信数据**处理：导入文件可能把裸数组域写成 `{items: []}`、磁盘数据
 * 可能混入损坏条目；加载时统一解包、逐条校验并归一化 `tid` / 数值字段，坏条目丢弃，
 * 避免"进度静默消失"或 `null` 条目抛异常。
 */
export class ThreadTreeProgressStore extends BaseStore<Object> {
  override state: Object = new Object()
  private progressMap: Map<string, ThreadTreeProgressEntry> = new Map()
  /** 是否已从持久化加载过（设备级数据只加载一次）。 */
  private loaded: boolean = false
  /** 在途加载任务（并发首次访问共用一次读盘，避免后完成的读清掉先写入的条目）。 */
  private loadPromise: Promise<void> | null = null

  init(store: PreferencesStore, queue: SerialQueue): void {
    this.setDeps(store, queue)
  }

  /** 重置缓存（清空本地数据时调用）。 */
  reset(): void {
    this.progressMap.clear()
    this.loaded = false
    // 允许 reset 后立刻重新读盘；旧任务由 generationGuard 自行失效
    this.loadPromise = null
    super.reset()
  }

  /**
   * 懒加载进度缓存（设备级：只加载一次，不再因 uid 变化重载）。
   *
   * 多个首次访问并发时共用同一个加载 Promise：否则后完成的读会先 clear map、
   * 把先完成的 `setProgress` 写入条目清掉。
   */
  private async ensureLoaded(): Promise<void> {
    if (this.loaded) return
    let task: Promise<void> | null = this.loadPromise
    if (task === null) {
      task = this.loadFromStore()
      this.loadPromise = task
    }
    try {
      await task
    } finally {
      // 只清自己创建的任务：reset 后新的加载任务不能被旧任务的 finally 误清
      if (this.loadPromise === task) {
        this.loadPromise = null
      }
    }
  }

  /**
   * 从持久化读取并归一化进度表。
   */
  private async loadFromStore(): Promise<void> {
    const gen: number = this.generationGuard.current()
    const key: string = treeProgressDomainKey()
    let raw: Object | null = null
    if (key.length > 0) {
      try {
        raw = await this.store.getJSON<Object>(key)
      } catch (e) {
        logger.warn('tree progress read failed: %{public}s', formatError(e))
      }
    }
    // 加载期间已清空数据（reset 推进代际）：放弃本次，避免把过时数据写回内存
    if (!this.generationGuard.isCurrent(gen)) {
      return
    }
    this.progressMap.clear()
    const entries: ThreadTreeProgressEntry[] = this.normalizeEntries(raw)
    for (let i: number = 0; i < entries.length; i++) {
      const entry: ThreadTreeProgressEntry = entries[i]
      const existing: ThreadTreeProgressEntry | undefined = this.progressMap.get(entry.tid)
      // 同 tid 的多份条目（损坏数据/旧合并结果）按 ts 取新
      if (existing === undefined || entry.ts >= existing.ts) {
        this.progressMap.set(entry.tid, entry)
      }
    }
    this.trimToLimit()
    this.loaded = true
  }

  /**
   * 把持久化载荷归一化为合法条目数组。
   *
   * 兼容裸数组与 `{items: T[]}` 两种形态（导入合并器允许输出形态跟随导入文件），
   * 逐条校验对象类型与 `tid`，数值字段非法时回落到默认值。
   *
   * @param raw - 已解析的持久化载荷
   * @returns 合法条目数组
   */
  private normalizeEntries(raw: Object | null): ThreadTreeProgressEntry[] {
    const result: ThreadTreeProgressEntry[] = []
    const list: Object[] = this.extractList(raw)
    for (let i: number = 0; i < list.length; i++) {
      const item: Object = list[i]
      if (item === null || item === undefined || typeof item !== 'object') {
        continue
      }
      const source: ThreadTreeProgressEntry = item as ThreadTreeProgressEntry
      const tid: string = String(source.tid ?? '').trim()
      if (tid.length === 0) {
        continue
      }
      const entry: ThreadTreeProgressEntry = new ThreadTreeProgressEntry()
      entry.tid = tid
      entry.pid = this.toInteger(source.pid, -1)
      entry.rootPid = this.toInteger(source.rootPid, -1)
      entry.page = Math.max(1, this.toInteger(source.page, 1))
      entry.ts = Math.max(0, this.toInteger(source.ts, 0))
      result.push(entry)
    }
    return result
  }

  /**
   * 从载荷中取出条目数组（裸数组或 `{items: T[]}` 信封）。
   *
   * @param raw - 已解析的持久化载荷
   * @returns 条目数组；形态非法时为空数组
   */
  private extractList(raw: Object | null): Object[] {
    if (raw === null || raw === undefined) {
      return []
    }
    if (Array.isArray(raw)) {
      return raw as Object[]
    }
    if (typeof raw === 'object') {
      const record: Record<string, Object> = raw as Record<string, Object>
      const items: Object | undefined = record['items']
      if (items !== undefined && items !== null && Array.isArray(items)) {
        return items as Object[]
      }
    }
    return []
  }

  /**
   * 数值字段归一化：非有限数字回落到默认值。
   *
   * @param value - 原始值（运行时可能是字符串/undefined）
   * @param fallback - 非法时的默认值
   * @returns 整数结果
   */
  private toInteger(value: Object, fallback: number): number {
    const parsed: number = parseFloat(String(value))
    return Number.isFinite(parsed) ? Math.trunc(parsed) : fallback
  }

  /**
   * 按 LRU 上限裁剪内存表（超上限时淘汰最旧条目）。
   */
  private trimToLimit(): void {
    while (this.progressMap.size > TREE_PROGRESS_MAX_COUNT) {
      let oldestKey: string = ''
      let oldestTs: number = Number.MAX_SAFE_INTEGER
      this.progressMap.forEach((value: ThreadTreeProgressEntry, key: string): void => {
        if (value.ts < oldestTs) {
          oldestTs = value.ts
          oldestKey = key
        }
      })
      if (oldestKey.length === 0) {
        return
      }
      this.progressMap.delete(oldestKey)
    }
  }

  /**
   * 读取指定帖子的递进树阅读进度。
   *
   * @param uid - **仅为兼容既有调用点保留**（设备级数据）
   * @param tid - 主题 tid
   * @returns 进度条目；无记录或参数无效时返回 null
   */
  async getProgress(uid: string, tid: string): Promise<ThreadTreeProgressEntry | null> {
    if (tid.length === 0) return null
    await this.ensureLoaded()
    const entry: ThreadTreeProgressEntry | undefined = this.progressMap.get(tid)
    return entry !== undefined ? entry : null
  }

  /**
   * 写入（覆盖）指定帖子的递进树阅读进度。
   *
   * 同帖只保留最新一条；条目数超过上限时按最近阅读时间淘汰最早记录。
   *
   * @param uid - **仅为兼容既有调用点保留**（设备级数据）
   * @param entry - 进度条目（tid 必须非空）
   */
  async setProgress(uid: string, entry: ThreadTreeProgressEntry): Promise<void> {
    if (entry.tid.length === 0) return
    const gen: number = this.generationGuard.current()
    await this.ensureLoaded()
    // 加载期间已清空数据（reset 推进代际）：中止写入，避免旧会话数据写入新上下文
    if (!this.generationGuard.isCurrent(gen)) {
      return
    }
    entry.ts = Date.now()
    this.progressMap.set(entry.tid, entry)
    this.trimToLimit()
    this.persistProgress()
  }

  private persistProgress(): void {
    const key: string = treeProgressDomainKey()
    if (key.length === 0) {
      return
    }
    // 入队时戳代际：reset/清空后队列里残留的写入不得把空表写回磁盘
    const gen: number = this.generationGuard.current()
    this.writeQueue.enqueue(async (): Promise<void> => {
      if (!this.generationGuard.isCurrent(gen)) {
        return
      }
      const items: ThreadTreeProgressEntry[] = []
      this.progressMap.forEach((value: ThreadTreeProgressEntry): void => {
        items.push(value)
      })
      await this.store.putJSON(key, items, false)
      this.store.scheduleFlush()
    })
  }
}
