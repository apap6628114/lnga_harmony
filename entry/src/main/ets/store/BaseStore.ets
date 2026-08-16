import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { GenerationGuard } from '../common/concurrency/GenerationGuard'

import type { AuthState } from './AuthStore'

/**
 * Store 基类 — 统一生命周期管理和异步防护。
 *
 * 所有持久化 Store 都应继承此类以获得：
 * - generation 版本标记：reset() 时自增，使过时异步回调自动失效
 * - uidGuard()：写入队列前检查 uid 有效性
 * - reset() 统一契约
 *
 * 泛型参数 T 用于标注 state 类型，受 ArkTS 约束限制，
 * 基类中不编写基于 T 的通用逻辑。
 *
 * ⚠️ init 不作为基类抽象方法：各 Store 的 init 参数列表不同
 * （AuthStore/VoteStore/HistoryStore 无 auth 参数，其余有），
 * ArkTS 不支持方法重载，因此各 Store 自行声明 init 签名。
 */
export abstract class BaseStore<T> {
  abstract state: T
  protected store!: PreferencesStore
  protected writeQueue!: SerialQueue
  protected auth!: AuthState

  /**
   * Store 级代际守卫。
   * reset() 时推进代际，使所有已捕获代际的异步回调自动失效。
   * 适用于"整个 Store 重置后不应再执行旧操作"的场景。
   */
  protected readonly generationGuard: GenerationGuard = new GenerationGuard()

  /**
   * 上一次成功刷新时间（普通刷新的最小成功间隔节流基准）。
   * 由 runGuardedRefresh 统一维护：perform 返回 true 即视为成功并刷新该时间戳。
   * 命名带 guarded 前缀：部分子类（如 FavoriteStore）自持同名私有字段，
   * 避免派生类与基类私有属性同名冲突。
   */
  private guardedLastSuccessTime: number = 0

  /**
   * 当前正在执行的刷新任务（并发调用复用同一请求）。
   * 由 runGuardedRefresh 统一维护。
   */
  private guardedRefreshPromise: Promise<boolean> | null = null

  /**
   * 供子类 init 调用的依赖注入辅助方法。
   * 各 Store init 签名不同（2 或 3 个参数），子类在自身 init 中调用此方法。
   */
  protected setDeps(store: PreferencesStore, queue: SerialQueue, auth?: AuthState): void {
    this.store = store
    this.writeQueue = queue
    if (auth) {
      this.auth = auth
    }
  }

  /** 子类 reset 完成后应调用 super.reset() 触发代际推进并重置刷新协调状态 */
  reset(): void {
    this.clearRefreshState()
    this.generationGuard.bump()
  }

  /**
   * 受控刷新协调：认证门禁 + 并发复用 + 最小成功间隔节流。
   *
   * 两个社交 Store 的普通刷新共用此骨架：
   * - 未认证直接返回 false；
   * - 已有在途刷新任务时复用同一请求（await 同一 promise）；
   * - 非 force 且距上次成功刷新不足 minDelayMs 时直接返回 true（视为已满足）；
   * - 否则捕获 generation/uid/token 快照后执行 perform，perform 返回 true 即
   *   视为一次成功刷新并更新节流基准。
   *
   * @param force - 是否忽略成功刷新间隔
   * @param minDelayMs - 普通刷新最短成功间隔（毫秒）
   * @param perform - 实际请求动作；参数为请求发起时的代际/uid/token 快照，
   *   内部须用 isRequestCurrent 做回写校验
   * @returns 请求是否成功（节流命中或复用成功时也返回 true）
   */
  protected async runGuardedRefresh(
    force: boolean,
    minDelayMs: number,
    perform: (generation: number, uid: string, token: string) => Promise<boolean>
  ): Promise<boolean> {
    if (!this.auth || !this.auth.isAuthenticated || !this.auth.uid) {
      return false
    }
    if (this.guardedRefreshPromise) {
      return await this.guardedRefreshPromise
    }

    const now: number = Date.now()
    if (!force && now - this.guardedLastSuccessTime < minDelayMs) {
      return true
    }

    const requestGeneration: number = this.generationGuard.current()
    const requestUid: string = this.auth.uid
    const requestToken: string = this.auth.token
    const task: Promise<boolean> = perform(requestGeneration, requestUid, requestToken)
    this.guardedRefreshPromise = task
    try {
      const ok: boolean = await task
      if (ok) {
        this.guardedLastSuccessTime = Date.now()
      }
      return ok
    } finally {
      if (this.guardedRefreshPromise === task) {
        this.guardedRefreshPromise = null
      }
    }
  }

  /**
   * 判断异步请求是否仍属于当前账号和当前 Store 生命周期。
   *
   * @param generation - 请求发起时的 Store generation
   * @param uid - 请求发起时的用户 ID
   * @param token - 请求发起时的认证 token
   * @returns 请求是否仍可回写
   */
  protected isRequestCurrent(generation: number, uid: string, token: string): boolean {
    return this.isCurrent(generation) &&
      this.auth.uid === uid &&
      this.auth.token === token &&
      this.auth.isAuthenticated
  }

  /**
   * 重置刷新协调状态（节流基准与在途任务引用）。
   * 子类 init/reset 时调用；reset 已通过 super.reset() 隐式调用。
   */
  protected clearRefreshState(): void {
    this.guardedLastSuccessTime = 0
    this.guardedRefreshPromise = null
  }

  /** 异步回调前调用：代际不匹配说明已过时，放弃执行 */
  protected isCurrent(gen: number): boolean {
    return this.generationGuard.isCurrent(gen)
  }

  /** 写入队列前检查 uid 是否仍有效（auth 未注入时返回 true 不拦截） */
  protected uidGuard(): boolean {
    return this.auth ? !!this.auth.uid : true
  }
}
