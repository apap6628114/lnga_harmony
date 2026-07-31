import type { AuthState } from './AuthStore'

/**
 * 身份快照 — await 前捕获登录身份，await 后校验未变化。
 *
 * 用于"异步请求结束后回写带 uid 归属的数据"场景（缓存、持久化、状态更新）：
 * 请求发起前 {@link capture} 快照身份与代际，回调恢复后 {@link isCurrent}
 * 逐项比对——退出登录、切换账号、Store 重置期间身份或代际已变化，应放弃回写，
 * 防止旧账号数据污染新账号存储。
 *
 * 与 NotificationStore.isRequestCurrent 的四重校验（generation + uid + token +
 * isAuthenticated）同构。无代际来源的调用方（如 settings 域子 store）传 0，
 * 退化为纯身份校验。
 */
export class AuthScope {
  /** 捕获时的代际值。 */
  private requestGeneration: number
  /** 捕获时的用户 ID。 */
  private uid: string
  /** 捕获时的认证 token。 */
  private token: string
  /** 捕获时是否已认证。 */
  private authenticated: boolean

  /**
   * 私有构造，统一经 {@link capture} 创建。
   *
   * @param generation - 捕获时代际值
   * @param uid - 捕获时用户 ID
   * @param token - 捕获时认证 token
   * @param authenticated - 捕获时认证状态
   */
  private constructor(generation: number, uid: string, token: string, authenticated: boolean) {
    this.requestGeneration = generation
    this.uid = uid
    this.token = token
    this.authenticated = authenticated
  }

  /**
   * 捕获当前身份快照。调用时机：异步请求发起前。
   *
   * @param auth - 当前 AuthState；未注入时捕获为空快照（isCurrent 恒为 false）
   * @param generation - 当前代际；无代际源传 0（退化为纯身份校验）
   * @returns 身份快照
   */
  static capture(auth: AuthState | undefined, generation: number): AuthScope {
    if (!auth) {
      return new AuthScope(generation, '', '', false)
    }
    return new AuthScope(generation, auth.uid, auth.token, auth.isAuthenticated)
  }

  /**
   * 校验快照是否仍代表当前身份与生命周期。
   * 调用时机：异步请求回调恢复、任何回写之前。
   *
   * @param auth - 当前 AuthState；未注入或已清空视为身份失效
   * @param generation - 当前代际
   * @returns true 表示身份与代际均未变化，可安全回写
   */
  isCurrent(auth: AuthState | undefined, generation: number): boolean {
    if (!auth) {
      return false
    }
    return generation === this.requestGeneration &&
      auth.uid === this.uid &&
      auth.token === this.token &&
      auth.isAuthenticated === this.authenticated
  }
}
