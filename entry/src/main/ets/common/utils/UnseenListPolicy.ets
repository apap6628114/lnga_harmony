/**
 * 未读列表通用策略 — 合并去重、已读维护与未读计数。
 *
 * 消息（NotificationStore）与动态（FollowActivityStore）两条列表的本地策略
 * 同构：按 id 合并去重并保留本地已读状态、时间倒序排序、上限截断、
 * 已读标记与未读计数。此处用访问器把业务字段差异（id 字段名、
 * 时间字段类型、排序第二键、模型是否允许原地改 seen）参数化，
 * 一份实现服务两个系统。
 *
 * 各系统的语义差异通过访问器表达，不在此层做业务判断：
 * - getSortTime：数值化排序时间（通知对 string 时间戳做 Number + isFinite 兜底）；
 * - getTieBreakId：稳定排序第二键（动态用 id 消除同秒抖动；通知返回固定值退化为纯时间排序）。
 */

/**
 * 未读列表访问器 — 解耦业务模型字段差异。
 */
export class UnseenListAccessors<T> {
  /** 条目的稳定 id。 */
  readonly getId: (item: T) => string
  /** 条目是否已读。 */
  readonly isSeen: (item: T) => boolean
  /** 设置条目的已读状态。 */
  readonly setSeen: (item: T, seen: boolean) => void
  /** 数值化排序时间（数值越大越靠前）。 */
  readonly getSortTime: (item: T) => number
  /** 排序第二键（同时间时用于稳定次序；无需第二键时返回固定值）。 */
  readonly getTieBreakId: (item: T) => string

  constructor(
    getId: (item: T) => string,
    isSeen: (item: T) => boolean,
    setSeen: (item: T, seen: boolean) => void,
    getSortTime: (item: T) => number,
    getTieBreakId: (item: T) => string
  ) {
    this.getId = getId
    this.isSeen = isSeen
    this.setSeen = setSeen
    this.getSortTime = getSortTime
    this.getTieBreakId = getTieBreakId
  }
}

/**
 * 未读列表策略 — 合并 / 追加去重 / 已读维护 / 未读计数。
 */
export class UnseenListPolicy<T> {
  private readonly accessors: UnseenListAccessors<T>

  /**
   * 构造策略实例。
   *
   * @param accessors - 列表条目的字段访问器
   */
  constructor(accessors: UnseenListAccessors<T>) {
    this.accessors = accessors
  }

  /**
   * 合并列表，重复条目保留原有本地已读状态（新增条目一律视为未读）。
   *
   * 注意副作用契约：incoming 的元素会被原地回填 seen（与既有语义一致），
   * 返回数组的元素与 existing/incoming 入参共享引用——调用方不得持有
   * 需要保持不变的受保护快照作为入参。
   *
   * @param existing - 当前列表
   * @param incoming - 本次拉取列表（元素会被原地修改 seen）
   * @param maxCount - 最大保留数量
   * @returns 合并、去重并按时间倒序排列的列表
   */
  merge(existing: T[], incoming: T[], maxCount: number): T[] {
    const mergedById: Map<string, T> = new Map<string, T>()
    for (let index: number = 0; index < existing.length; index++) {
      const item: T = existing[index]
      mergedById.set(this.accessors.getId(item), item)
    }

    for (let index: number = 0; index < incoming.length; index++) {
      const item: T = incoming[index]
      const previous: T | undefined = mergedById.get(this.accessors.getId(item))
      this.accessors.setSeen(item, previous !== undefined ? this.accessors.isSeen(previous) : false)
      mergedById.set(this.accessors.getId(item), item)
    }

    const merged: T[] = Array.from(mergedById.values())
    merged.sort((left: T, right: T): number => {
      const byTime: number = this.accessors.getSortTime(right) - this.accessors.getSortTime(left)
      if (byTime !== 0) {
        return byTime
      }
      // 同时间条目按第二键固定方向比较，消除排序抖动导致的偶发整体重建
      const leftTie: string = this.accessors.getTieBreakId(left)
      const rightTie: string = this.accessors.getTieBreakId(right)
      if (leftTie > rightTie) {
        return -1
      }
      if (leftTie < rightTie) {
        return 1
      }
      return 0
    })
    return merged.length > maxCount ? merged.slice(0, maxCount) : merged
  }

  /**
   * 按顺序追加去重：保持 existing 顺序，仅追加 id 不在 existing（含本次已追加）的条目。
   *
   * @param existing - 当前列表
   * @param incoming - 本次分页拉取的条目
   * @returns 追加去重后的列表（新数组，不改动入参）
   */
  appendDedupe(existing: T[], incoming: T[]): T[] {
    const knownIds: Set<string> = new Set<string>()
    for (let index: number = 0; index < existing.length; index++) {
      knownIds.add(this.accessors.getId(existing[index]))
    }
    const result: T[] = existing.slice()
    for (let index: number = 0; index < incoming.length; index++) {
      const item: T = incoming[index]
      if (!knownIds.has(this.accessors.getId(item))) {
        knownIds.add(this.accessors.getId(item))
        result.push(item)
      }
    }
    return result
  }

  /**
   * 将指定 id 的条目标记为已读。
   *
   * @param items - 条目列表
   * @param id - 目标条目 id
   * @returns 是否发生状态变化
   */
  markSeenById(items: T[], id: string): boolean {
    for (let index: number = 0; index < items.length; index++) {
      const item: T = items[index]
      if (this.accessors.getId(item) === id) {
        if (this.accessors.isSeen(item)) {
          return false
        }
        this.accessors.setSeen(item, true)
        return true
      }
    }
    return false
  }

  /**
   * 将指定 id 集合的条目标记为已读。
   *
   * @param items - 条目列表
   * @param ids - 目标条目 id 集合
   * @returns 是否发生状态变化
   */
  markSeenByIds(items: T[], ids: Set<string>): boolean {
    let changed: boolean = false
    for (let index: number = 0; index < items.length; index++) {
      const item: T = items[index]
      if (!this.accessors.isSeen(item) && ids.has(this.accessors.getId(item))) {
        this.accessors.setSeen(item, true)
        changed = true
      }
    }
    return changed
  }

  /**
   * 将全部条目标记为已读。
   *
   * @param items - 条目列表
   * @returns 是否发生状态变化
   */
  markAllSeen(items: T[]): boolean {
    let changed: boolean = false
    for (let index: number = 0; index < items.length; index++) {
      const item: T = items[index]
      if (!this.accessors.isSeen(item)) {
        this.accessors.setSeen(item, true)
        changed = true
      }
    }
    return changed
  }

  /**
   * 将满足条件的条目标记为已读（仅处理未读条目）。
   *
   * @param items - 条目列表
   * @param shouldMark - 是否应标记为已读
   * @returns 是否发生状态变化
   */
  markSeenWhere(items: T[], shouldMark: (item: T) => boolean): boolean {
    let changed: boolean = false
    for (let index: number = 0; index < items.length; index++) {
      const item: T = items[index]
      if (!this.accessors.isSeen(item) && shouldMark(item)) {
        this.accessors.setSeen(item, true)
        changed = true
      }
    }
    return changed
  }

  /**
   * 计算未读条目数量。
   *
   * @param items - 条目列表
   * @returns 未读条目数量
   */
  countUnseen(items: T[]): number {
    let count: number = 0
    for (let index: number = 0; index < items.length; index++) {
      if (!this.accessors.isSeen(items[index])) {
        count++
      }
    }
    return count
  }

  /**
   * 计算满足条件的未读条目数量。
   *
   * @param items - 条目列表
   * @param shouldCount - 是否计入统计
   * @returns 满足条件的未读条目数量
   */
  countUnseenWhere(items: T[], shouldCount: (item: T) => boolean): number {
    let count: number = 0
    for (let index: number = 0; index < items.length; index++) {
      const item: T = items[index]
      if (!this.accessors.isSeen(item) && shouldCount(item)) {
        count++
      }
    }
    return count
  }
}
