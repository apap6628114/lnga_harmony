/**
 * 域健康状态跟踪（DomainHealth）— 每个域的读/写健康、体积与条目数。
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §4.5。纯内存态：不落盘、不参与导出，
 * 由数据管理页消费（异常域高亮 + 修复入口），进程重启后归零（下一次读取会重新发现异常）。
 *
 * 纪律：本类方法不得抛错（它在读写失败路径上被调用，自身再抛错会把故障放大成崩溃）。
 */

import { DomainHealthSnapshot, DOMAIN_SIZE_WARN_BYTES, shortError } from './PersistenceTypes'

/**
 * 域健康跟踪器。
 */
export class DomainHealthTracker {
  /** 域 ID → 健康快照。 */
  private records: Map<string, DomainHealthSnapshot> = new Map<string, DomainHealthSnapshot>()

  /**
   * 取（或创建）指定域的健康快照。
   *
   * @param domain - 域 ID
   * @returns 健康快照（引用可写）
   */
  private ensure(domain: string): DomainHealthSnapshot {
    let snapshot: DomainHealthSnapshot | undefined = this.records.get(domain)
    if (snapshot === undefined) {
      snapshot = new DomainHealthSnapshot(domain)
      this.records.set(domain, snapshot)
    }
    return snapshot
  }

  /**
   * 记录一次读取结果。
   *
   * @param domain - 域 ID
   * @param ok - 是否成功
   * @param droppedItems - 被跳过的坏条目数
   * @param error - 错误对象（成功时传 null）
   */
  recordLoad(domain: string, ok: boolean, droppedItems: number, error: Object | null): void {
    try {
      const snapshot: DomainHealthSnapshot = this.ensure(domain)
      snapshot.loadFailed = !ok
      snapshot.droppedItems = ok ? droppedItems : 0
      snapshot.lastError = ok || error === null ? '' : shortError(error)
    } catch (e) {
      // 健康记录失败不影响业务
    }
  }

  /**
   * 记录一次写入结果。
   *
   * @param domain - 域 ID
   * @param ok - 是否成功
   * @param bytes - 写入体积（估算）
   * @param error - 错误对象（成功时传 null）
   */
  recordWrite(domain: string, ok: boolean, bytes: number, error: Object | null): void {
    try {
      const snapshot: DomainHealthSnapshot = this.ensure(domain)
      snapshot.writeFailed = !ok
      snapshot.estimatedBytes = bytes
      if (ok) {
        snapshot.lastWriteAt = Date.now()
        snapshot.lastError = ''
      } else if (error !== null) {
        snapshot.lastError = shortError(error)
      }
    } catch (e) {
      // 同上
    }
  }

  /**
   * 更新域的条目数与估算体积（读取/统计时调用）。
   *
   * @param domain - 域 ID
   * @param itemCount - 条目数
   * @param estimatedBytes - 估算体积
   */
  updateSize(domain: string, itemCount: number, estimatedBytes: number): void {
    try {
      const snapshot: DomainHealthSnapshot = this.ensure(domain)
      snapshot.itemCount = itemCount
      snapshot.estimatedBytes = estimatedBytes
    } catch (e) {
      // 同上
    }
  }

  /**
   * 返回全部健康快照（按域 ID 排序稳定）。
   *
   * @returns 快照数组
   */
  snapshot(): DomainHealthSnapshot[] {
    const result: DomainHealthSnapshot[] = []
    this.records.forEach((value: DomainHealthSnapshot): void => {
      result.push(value)
    })
    result.sort((a: DomainHealthSnapshot, b: DomainHealthSnapshot): number => {
      return a.domain < b.domain ? -1 : (a.domain > b.domain ? 1 : 0)
    })
    return result
  }

  /**
   * 返回存在问题的快照（读/写失败或有坏条目）。
   *
   * @returns 问题快照数组
   */
  problems(): DomainHealthSnapshot[] {
    const result: DomainHealthSnapshot[] = []
    const all: DomainHealthSnapshot[] = this.snapshot()
    for (let i: number = 0; i < all.length; i++) {
      if (all[i].loadFailed || all[i].writeFailed || all[i].droppedItems > 0) {
        result.push(all[i])
      }
    }
    return result
  }

  /**
   * 判断指定域体积是否超过告警阈值。
   *
   * @param domain - 域 ID
   * @returns 是否超限
   */
  isOversized(domain: string): boolean {
    const snapshot: DomainHealthSnapshot | undefined = this.records.get(domain)
    return snapshot !== undefined && snapshot.estimatedBytes > DOMAIN_SIZE_WARN_BYTES
  }

  /**
   * 重置指定域的健康状态（修复/清空后调用）。
   *
   * @param domain - 域 ID
   */
  reset(domain: string): void {
    this.records.delete(domain)
  }

  /**
   * 重置全部健康状态（登出/清空数据后调用）。
   */
  resetAll(): void {
    this.records.clear()
  }
}
