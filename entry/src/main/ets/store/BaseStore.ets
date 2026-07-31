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

  /** 子类 reset 完成后应调用 super.reset() 触发代际推进 */
  reset(): void {
    this.generationGuard.bump()
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
