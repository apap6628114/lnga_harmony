/**
 * 会话守卫：把"疑似未登录信号 → 是否真的失效 → 怎么处置"收敛到一处。
 *
 * ## 设计依据（官方客户端 nga.apk 7.17.17）
 *
 * - 官方在网络层统一识别 `code==12` / 未登录文案（`NetProviderImpl.checkHttpResult`），
 *   命中后 `jumpToLogin()` 打开登录页，只有 `checktoken == "-1"` 才清本地态并广播 LOGOUT；
 * - 网络/解析失败走 `updateViewByError` 分支，**不跳登录、不清态**；
 * - 通知轮询（`NOTIFY_LIST` / `DO_TASK`）不跳登录页。
 *
 * 本项目在此基础上多一步：**iflogin 二次确认**。原因是实测 NGA 对"未登录"会下发
 * `code=12` / `2048` / `1` 三种码，且 `code=1` 同时用于其它业务错误；不确认就清态，
 * 一次接口抖动或参数错误就能把用户踢下线。
 *
 * ## 三条入口
 *
 * 1. `onUnauthorizedSignal()`：网络层上报"响应里出现未登录信号"（60s 去抖 + 单飞 + 确认）；
 * 2. `verify()`：主动校验（启动页 / 进入主页面），返回三态，**不由本类清态**；
 * 3. `verifyOnForeground()`：前台恢复时按 10 分钟间隔校验一次。
 *
 * 清态与跳转分别由注入的 `expiredHandler`（AppStore：`clearAuth` + Toast）与
 * `navigator`（MainPage：`router.replaceUrl` 登录页）完成——本类不 import AppStore，
 * 避免 store ↔ service 的循环依赖。
 */

import { SessionCheckResult, SessionVerdict } from '../service/api/AuthErrors'
import { checkSessionByCredential } from '../service/api/SessionApi'
import type { Session } from './SessionRegistry'
import { Logger, DOMAIN_STORE } from '../common/utils/Logger'

const logger = new Logger(DOMAIN_STORE, 'SessionGuard')

/** 两次"未登录信号"触发确认的最小间隔（ms）。 */
const SIGNAL_COOLDOWN_MS: number = 60 * 1000

/** 单次主动校验的超时（ms）：超时按 UNKNOWN 处理，绝不据此登出。 */
const VERIFY_TIMEOUT_MS: number = 5000

/** 前台恢复校验的最小间隔（ms）：避免每次切回前台都打一次服务端。 */
const FOREGROUND_VERIFY_INTERVAL_MS: number = 10 * 60 * 1000

/** 当前会话的读取函数（由 AppStore 注入：用 auth.token 查 SessionRegistry）。 */
type SessionResolver = () => Session | null

/** 失效处置回调（由 AppStore 注入：清登录态 + Toast）。返回是否真的处置了。 */
type ExpiredHandler = () => boolean

/** 路由回调（由 MainPage 注入：跳登录页）。 */
type Navigator = () => void

/** 会话校验函数（默认走 SessionApi；测试可注入 fake）。 */
type CheckFn = (uid: string, cid: string) => Promise<SessionCheckResult>

export class SessionGuard {
  private resolveSession: SessionResolver | null = null
  private expiredHandler: ExpiredHandler | null = null
  private navigator: Navigator | null = null
  private checkFn: CheckFn = checkSessionByCredential

  /** 上一次"未登录信号"的处理时间（去抖基准）。 */
  private lastSignalAt: number = 0
  /** 上一次完成主动校验的时间（前台恢复与短时复用基准）。 */
  private lastVerifyAt: number = 0
  /** 上一次校验结论与其对应的会话标识（`uid|cid`），用于短时复用避免重复请求。 */
  private lastVerdict: SessionVerdict | null = null
  private lastVerdictKey: string = ''
  /** 在途校验（单飞：并发调用复用同一请求）。 */
  private inflight: Promise<SessionCheckResult> | null = null
  /** 校验超时（ms）；测试可注入更短的值。 */
  private timeoutMs: number = VERIFY_TIMEOUT_MS

  /**
   * 注入当前会话读取函数。
   *
   * @param resolver - 返回当前 token 对应的会话；无会话时返回 null
   */
  bindSessionResolver(resolver: SessionResolver): void {
    this.resolveSession = resolver
  }

  /**
   * 注入失效处置回调（清登录态 + 提示）。
   *
   * @param handler - 确认失效后的回调
   */
  bindExpiredHandler(handler: ExpiredHandler): void {
    this.expiredHandler = handler
  }

  /**
   * 注入路由回调（跳登录页）。
   *
   * @param navigator - 路由动作
   */
  attachNavigator(navigator: Navigator): void {
    this.navigator = navigator
  }

  /** 取消路由回调（页面销毁时调用）。 */
  detachNavigator(): void {
    this.navigator = null
  }

  /**
   * 替换校验函数（仅供单元测试注入 fake，业务代码不要调用）。
   *
   * @param fn - 校验函数
   */
  bindCheckFn(fn: CheckFn): void {
    this.checkFn = fn
  }

  /**
   * 替换校验超时（仅供单元测试注入更短的值，业务代码不要调用）。
   *
   * @param timeoutMs - 超时毫秒数（必须为正数）
   */
  bindTimeoutMs(timeoutMs: number): void {
    if (timeoutMs > 0) {
      this.timeoutMs = timeoutMs
    }
  }

  /**
   * 复位"未登录信号"的去抖窗口（账号恢复/重新登录时调用）。
   *
   * 不复位的话，用户在 60s 内重新登录后若立刻又失效，信号会被上一轮的窗口吞掉；
   * 由 `AppStore.setAuth` 在登录成功后调用，比在 `onUnauthorizedSignal` 里无脑复位更精确
   * （后者会让同一会话的批量响应反复触发确认）。
   */
  resetSignalThrottle(): void {
    this.lastSignalAt = 0
  }

  /**
   * 主动校验当前会话。
   *
   * @returns 三态结论；无本地会话时直接 INVALID
   */
  async verify(): Promise<SessionVerdict> {
    const result: SessionCheckResult = await this.verifyDetailed()
    return result.verdict
  }

  /**
   * 短时内复用上一次结论的校验（避免启动页与主页面连续打两次 iflogin）。
   *
   * 复用的前提是**会话标识一致**（uid+cid）：账号切换/重新登录后不得沿用旧结论。
   *
   * @param maxAgeMs - 结论的最大有效期（ms）
   * @returns 三态结论
   */
  async verifyIfStale(maxAgeMs: number): Promise<SessionVerdict> {
    const key: string = this.currentSessionKey()
    if (this.lastVerdict !== null && key.length > 0 && key === this.lastVerdictKey &&
      Date.now() - this.lastVerifyAt < maxAgeMs) {
      return this.lastVerdict
    }
    return this.verify()
  }

  /**
   * 网络层上报"疑似未登录"：去抖 + 单飞 + 确认后才清态。
   *
   * @param source - 信号来源（服务端文案，仅用于日志）
   */
  async onUnauthorizedSignal(source: string): Promise<void> {
    // 已经无会话（刚被清掉）：没有可确认的对象，直接忽略，避免清态后批量响应刷屏
    if (this.resolveSession === null || this.resolveSession() === null) {
      return
    }
    const now: number = Date.now()
    if (now - this.lastSignalAt < SIGNAL_COOLDOWN_MS) {
      return
    }
    this.lastSignalAt = now
    const result: SessionCheckResult = await this.verifyDetailed()
    if (result.verdict === SessionVerdict.INVALID) {
      logger.warn('会话失效已确认（source=%{public}s）', source)
      this.notifyExpired()
      return
    }
    if (result.verdict === SessionVerdict.UNKNOWN) {
      // 网络异常期间照常保留登录态：等下一次信号或前台恢复再确认
      logger.warn('会话校验无法判定（source=%{public}s）：%{public}s', source, result.message)
    }
  }

  /**
   * 前台恢复校验：距上次校验不足 10 分钟时直接跳过。
   */
  async verifyOnForeground(): Promise<void> {
    if (Date.now() - this.lastVerifyAt < FOREGROUND_VERIFY_INTERVAL_MS) {
      return
    }
    const result: SessionCheckResult = await this.verifyDetailed()
    if (result.verdict === SessionVerdict.INVALID) {
      logger.warn('前台恢复校验确认会话失效')
      this.notifyExpired()
    }
  }

  /**
   * 执行一次带超时、单飞的校验。
   *
   * @returns 校验结果（超时/异常均为 UNKNOWN）
   */
  private async verifyDetailed(): Promise<SessionCheckResult> {
    if (this.inflight !== null) {
      return this.inflight
    }
    const task: Promise<SessionCheckResult> = this.runVerify()
    this.inflight = task
    try {
      return await task
    } finally {
      if (this.inflight === task) {
        this.inflight = null
      }
    }
  }

  private async runVerify(): Promise<SessionCheckResult> {
    const session: Session | null = this.resolveSession !== null ? this.resolveSession() : null
    if (session === null) {
      // 无会话也刷新节流基准，否则未登录状态下每次切前台都空转一遍
      this.lastVerifyAt = Date.now()
      const missing: SessionCheckResult = new SessionCheckResult()
      missing.verdict = SessionVerdict.INVALID
      missing.message = '本地会话不存在'
      return missing
    }
    const result: SessionCheckResult = await this.withTimeout(this.checkFn(session.uid, session.cid))
    this.lastVerifyAt = Date.now()
    this.lastVerdict = result.verdict
    this.lastVerdictKey = session.uid + '|' + session.cid
    return result
  }

  /**
   * 当前会话标识（`uid|cid`），用于判断"上一次结论是否仍属于同一会话"。
   *
   * @returns 会话标识；无会话时为空串
   */
  private currentSessionKey(): string {
    const session: Session | null = this.resolveSession !== null ? this.resolveSession() : null
    return session === null ? '' : session.uid + '|' + session.cid
  }

  /**
   * 给校验请求加超时：超时返回 UNKNOWN（绝不能因为慢响应判失效）。
   *
   * @param pending - 校验请求
   * @returns 校验结果
   */
  private withTimeout(pending: Promise<SessionCheckResult>): Promise<SessionCheckResult> {
    return new Promise<SessionCheckResult>((resolve: (value: SessionCheckResult) => void): void => {
      let settled: boolean = false
      const timer: number = setTimeout((): void => {
        if (settled) {
          return
        }
        settled = true
        const timeout: SessionCheckResult = new SessionCheckResult()
        timeout.verdict = SessionVerdict.UNKNOWN
        timeout.message = '校验超时'
        resolve(timeout)
      }, this.timeoutMs)
      pending.then((result: SessionCheckResult): void => {
        if (settled) {
          return
        }
        settled = true
        clearTimeout(timer)
        resolve(result)
      }).catch((): void => {
        if (settled) {
          return
        }
        settled = true
        clearTimeout(timer)
        const failed: SessionCheckResult = new SessionCheckResult()
        failed.verdict = SessionVerdict.UNKNOWN
        failed.message = '校验异常'
        resolve(failed)
      })
    })
  }

  /**
   * 确认失效：先让 AppStore 处置（清态/提示），**只有真的处置了**才跳登录页。
   *
   * 未登录状态下 `expiredHandler` 会返回 false（早退），此时不得再导航——
   * 否则会对正在销毁的页面重复 replaceUrl，把用户已经输入一半的登录页重建。
   */
  private notifyExpired(): void {
    const handled: boolean = this.expiredHandler !== null ? this.expiredHandler() : false
    if (handled && this.navigator !== null) {
      this.navigator()
    }
  }
}

/** 全局会话守卫（由 AppStore 在 init 时绑定依赖）。 */
export const sessionGuard: SessionGuard = new SessionGuard()
