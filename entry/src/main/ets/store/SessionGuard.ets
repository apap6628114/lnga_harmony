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
 * 本项目在此基础上多两步：**iflogin 二次确认**与**静默复验**。原因是实测 NGA 对"未登录"
 * 会下发 `code=12` / `2048` / `1` 三种码，且 `code=1` 同时用于其它业务错误；更要紧的是
 * **各接口的会话校验强度并不一致** —— 服务端局部异常期间完全可能「`read.php` 帖子能读、
 * `iflogin` 报 SESSION TIMEOUT」（实测：只有 `nuke.php` 系强校验接口会拒绝）。
 * 单点判定就清态，等于用最严格接口的结论否定最宽松接口的能力。
 *
 * ## 处置原则：降级，而不是清态
 *
 * 确认失效后**不清登录态、不导航**，只回调 `degradedHandler` 让上层把凭证标为降级：
 * 本地凭证与全部 Store 原样保留，读能力照常尝试（成功即自愈），写能力由上层拦截。
 * 这是"服务端波动不把用户踢出应用"的唯一保障。
 *
 * ## 四条入口
 *
 * 1. `onUnauthorizedSignal()`：网络层上报"响应里出现未登录信号"（60s 去抖 + 单飞 +
 *    iflogin 确认 + 静默复验 + 确认降级）；
 * 2. `verify()`：主动校验（启动页 / 进入主页面），返回三态，**不**由本类处置 INVALID；
 * 3. `verifyOnForeground()`：前台恢复时校验（正常 10 分钟节流，降级态缩短到 1 分钟）；
 * 4. `reverify()`：强制复验（横幅「重试」与降级后的后台自动复验）。
 *
 * 本类不 import AppStore（避免 store ↔ service 的循环依赖），处置动作全部经注入的回调完成。
 */

import { SessionCheckResult, SessionVerdict } from '../service/api/AuthErrors'
import { checkSessionByCredential } from '../service/api/SessionApi'
import type { Session } from './SessionRegistry'
import { Logger, DOMAIN_STORE } from '../common/utils/Logger'

const logger = new Logger(DOMAIN_STORE, 'SessionGuard')

/** 两次"未登录信号"触发确认的最小间隔（ms）。 */
const SIGNAL_COOLDOWN_MS: number = 60 * 1000

/** 单次主动校验的超时（ms）：超时按 UNKNOWN 处理，绝不据此降级。 */
const VERIFY_TIMEOUT_MS: number = 5000

/** 前台恢复校验的最小间隔（ms）：避免每次切回前台都打一次服务端。 */
const FOREGROUND_VERIFY_INTERVAL_MS: number = 10 * 60 * 1000

/**
 * 降级态下的前台恢复校验间隔（ms）。
 *
 * 缩短到 1 分钟：降级是"服务端暂时不认"，一旦它恢复，用户不必等满 10 分钟才被治愈。
 * 间隔仍远大于一次请求的往返时间，不会对服务端形成轮询压力。
 */
const DEGRADED_VERIFY_INTERVAL_MS: number = 60 * 1000

/**
 * 首次判定失效后、进入降级前的静默复验间隔（ms）。
 *
 * 目的：过滤服务端瞬时抖动与单接口校验抖动。用户实测反馈的"有时候服务端异常"里，
 * 绝大多数属于几百毫秒内自行恢复的类型 —— 静默复验一次就能把它们全部挡在降级之外。
 */
const CONFIRM_DELAY_MS: number = 2000

/** 当前会话的读取函数（由 AppStore 注入：用 auth.token 查 SessionRegistry）。 */
type SessionResolver = () => Session | null

/**
 * 降级回调（由 AppStore 注入：标记凭证降级 + 顶部横幅）。
 *
 * 参数是诊断文案（服务端原文或本地原因；不含任何凭证）。
 */
type DegradedHandler = (reason: string) => void

/** 恢复回调（由 AppStore 注入：清除降级标记 + 提示一次）。 */
type RecoveredHandler = () => void

/** 会话校验函数（默认走 SessionApi；测试可注入 fake）。 */
type CheckFn = (uid: string, cid: string) => Promise<SessionCheckResult>

/**
 * 等待指定毫秒数。
 *
 * @param ms - 毫秒
 * @returns 等待完成的 Promise
 */
function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => resolve(), ms)
  })
}

export class SessionGuard {
  private resolveSession: SessionResolver | null = null
  private degradedHandler: DegradedHandler | null = null
  private recoveredHandler: RecoveredHandler | null = null
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
  /**
   * 校验序号：每次真实请求自增，落地时只接受"最新"的结论。
   *
   * 没有它就会出现可感知的错误：用户点「重试」拿到 VALID 清掉横幅之后，一条更早发出、
   * 更晚返回的 INVALID 会把它重新降级 —— 表现为"横幅闪一下又回来"。
   */
  private verifySeq: number = 0
  /** 已落地的最大校验序号。 */
  private appliedSeq: number = 0
  /**
   * 最近一次落地结论是否为"凭证与账号错配"。
   *
   * 这一类 INVALID 与普通的"服务端不认"性质不同（见 `SessionCheckResult.mismatched`），
   * 上层必须清态重登而不是降级 —— 由本字段转达。
   */
  private lastMismatched: boolean = false
  /** 校验超时（ms）；测试可注入更短的值。 */
  private timeoutMs: number = VERIFY_TIMEOUT_MS
  /** 进入降级前的静默复验间隔（ms）；测试可注入 0 跳过长等待。 */
  private confirmDelayMs: number = CONFIRM_DELAY_MS
  /**
   * 当前是否处于降级态（服务端已明确拒绝、但本地凭证仍保留）。
   *
   * 这是守卫内部的判定开关（决定前台探针间隔、决定是否需要回调"恢复"）。
   * 给 UI 与写门禁消费的那份在 `AuthState.credentialState` + AppStorage，两处由 AppStore 同步。
   */
  private degraded: boolean = false

  /**
   * 注入当前会话读取函数。
   *
   * @param resolver - 返回当前 token 对应的会话；无会话时返回 null
   */
  bindSessionResolver(resolver: SessionResolver): void {
    this.resolveSession = resolver
  }

  /**
   * 注入降级回调（本地凭证仍保留，但服务端已明确拒绝）。
   *
   * @param handler - 进入降级时的回调
   */
  bindDegradedHandler(handler: DegradedHandler): void {
    this.degradedHandler = handler
  }

  /**
   * 注入恢复回调（任一次校验通过时触发）。
   *
   * **每次 VALID 都会回调**，不只在"确实从降级态恢复"时：降级入口不止本类一处 ——
   * 启动页与主页面拿到 INVALID 后会直接调 `AppStore.markCredentialDegraded`，
   * 此时本类的 `degraded` 仍是 false。若在这里用 `degraded` 早退，后续的成功复验就
   * 永远触发不了恢复。去重交给消费方（`AppStore.clearCredentialDegraded` 在非降级态直接返回）。
   *
   * @param handler - 恢复时的回调
   */
  bindRecoveredHandler(handler: RecoveredHandler): void {
    this.recoveredHandler = handler
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
   * 替换静默复验间隔（仅供单元测试注入 0 以跳过等待，业务代码不要调用）。
   *
   * @param delayMs - 毫秒数（>= 0）
   */
  bindConfirmDelayMs(delayMs: number): void {
    if (delayMs >= 0) {
      this.confirmDelayMs = delayMs
    }
  }

  /**
   * 当前是否处于降级态。
   *
   * @returns true 表示服务端已明确拒绝，但本地凭证仍保留
   */
  isDegraded(): boolean {
    return this.degraded
  }

  /**
   * 最近一次落地的校验结论是否为「凭证与账号错配」。
   *
   * 错配意味着服务端把这个 cid 解析成了另一个 uid，后续读接口会以别人身份返回数据。
   * 上层（`AppStore.markCredentialDegraded`）据此走**硬清态**而不是降级。
   *
   * @returns true 表示凭证属于另一个账号
   */
  isCredentialMismatched(): boolean {
    return this.lastMismatched
  }

  /**
   * 由上层标记降级态。
   *
   * 启动页与主页面在 `verify()` 拿到 INVALID 后会直接调 `AppStore.markCredentialDegraded`
   * （那里不经过本类的 `notifyDegraded`）。若不同步这个标志，守卫会认为自己仍是正常态，
   * 前台恢复探针继续按 10 分钟节流 —— 服务端早已恢复，用户却要等满 10 分钟才能被治愈。
   * 降级态下探针间隔是 1 分钟。
   */
  markDegraded(): void {
    this.degraded = true
  }

  /**
   * 新会话开始时复位守卫状态（登录成功 / 账号切换 / 退出登录）。
   *
   * 不复位 `degraded` 的话，用户重新登录后守卫仍认为"处于降级"，之后任何一次成功校验
   * 都不会触发恢复回调，横幅会一直挂着。同时复位信号去抖窗口：用户在 60s 内重新登录后
   * 若立刻又失效，信号不能被上一轮的窗口吞掉。
   *
   * `appliedSeq` 推进到当前 `verifySeq`：把**所有在途校验的结论作废**（它们属于旧会话）。
   * `verifySeq` 本身不回退 —— 序号必须保持单调，否则复位后新请求会与旧请求撞号。
   */
  resetForNewSession(): void {
    this.lastSignalAt = 0
    this.degraded = false
    this.lastVerdict = null
    this.lastVerdictKey = ''
    this.lastVerifyAt = 0
    this.inflight = null
    this.lastMismatched = false
    this.appliedSeq = this.verifySeq
  }

  /**
   * 主动校验当前会话。
   *
   * INVALID 的处置交给调用方（启动页 / 主页面各自决定是降级还是保持），本方法只负责
   * 在结论为 VALID 时清除可能残留的降级态 —— 这是"成功即治愈"的一半。
   *
   * @returns 三态结论；无本地会话时直接 INVALID
   */
  async verify(): Promise<SessionVerdict> {
    const result: SessionCheckResult = await this.verifyDetailed()
    if (result.verdict === SessionVerdict.VALID) {
      this.notifyRecovered()
    }
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
   * 强制复验（不走单飞、不复用旧结论）。
   *
   * 两个使用场景：降级后的后台自动复验，以及用户点横幅上的「重试」。
   * 三种结论都会如实反映到降级态上：VALID → 恢复，INVALID → 降级（幂等），UNKNOWN → 不动。
   *
   * @returns 三态结论
   */
  async reverify(): Promise<SessionVerdict> {
    const result: SessionCheckResult = await this.verifyNow()
    if (result.verdict === SessionVerdict.VALID) {
      this.notifyRecovered()
      return result.verdict
    }
    if (result.verdict === SessionVerdict.INVALID) {
      this.notifyDegraded(result.message)
    }
    return result.verdict
  }

  /**
   * 网络层上报"疑似未登录"：去抖 → 单飞确认 → 静默复验 → 才进入降级。
   *
   * @param source - 信号来源（服务端文案，仅用于日志）
   */
  async onUnauthorizedSignal(source: string): Promise<void> {
    // 已经无会话（刚被清掉）：没有可确认的对象，直接忽略，避免清态后批量响应刷屏
    if (!this.hasSession()) {
      return
    }
    const now: number = Date.now()
    if (now - this.lastSignalAt < SIGNAL_COOLDOWN_MS) {
      return
    }
    this.lastSignalAt = now

    const first: SessionCheckResult = await this.verifyDetailed()
    if (first.verdict === SessionVerdict.VALID) {
      this.notifyRecovered()
      return
    }
    if (first.verdict !== SessionVerdict.INVALID) {
      // 网络异常期间照常保留登录态：等下一次信号或前台恢复再确认
      logger.warn('会话校验无法判定（source=%{public}s）：%{public}s', source, first.message)
      return
    }

    // 首次判定失效：先静默复验一次。NGA 各接口的会话校验强度不一致，单点判定不足以
    // 关闭用户的写能力；这一步把"服务端抖一下"与"凭证真的失效"区分开。
    if (this.confirmDelayMs > 0) {
      await sleep(this.confirmDelayMs)
      // 等待期间用户可能已主动退出登录：本地已无会话时这次判定失去对象，直接放弃。
      // （换账号不需要单独判断：下面的 `verifyNow` 读的是**当前**会话，结论天然属于新会话。）
      if (!this.hasSession()) {
        return
      }
    }
    const second: SessionCheckResult = await this.verifyNow()
    if (second.verdict === SessionVerdict.VALID) {
      logger.info('会话失效信号经复验被否定（source=%{public}s），保持正常态', source)
      this.notifyRecovered()
      return
    }
    if (second.verdict === SessionVerdict.INVALID) {
      logger.warn('会话失效已确认（source=%{public}s）', source)
      this.notifyDegraded(second.message)
      return
    }
    logger.warn('会话复验无法判定（source=%{public}s）：%{public}s', source, second.message)
  }

  /**
   * 前台恢复校验：正常态 10 分钟节流，降级态 1 分钟，让服务端恢复后尽快自愈。
   *
   * 这里 INVALID 直接降级、不再静默复验：前台恢复本身就是"隔了一段时间的第二次机会"，
   * 再等 2 秒只会让用户从后台切回来时多看到 2 秒加载失败。
   */
  async verifyOnForeground(): Promise<void> {
    const interval: number = this.degraded ? DEGRADED_VERIFY_INTERVAL_MS : FOREGROUND_VERIFY_INTERVAL_MS
    if (Date.now() - this.lastVerifyAt < interval) {
      return
    }
    const result: SessionCheckResult = await this.verifyDetailed()
    if (result.verdict === SessionVerdict.VALID) {
      this.notifyRecovered()
      return
    }
    if (result.verdict === SessionVerdict.INVALID) {
      logger.warn('前台恢复校验确认会话失效')
      this.notifyDegraded(result.message)
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
    const task: Promise<SessionCheckResult> = this.verifyNow()
    this.inflight = task
    try {
      return await task
    } finally {
      if (this.inflight === task) {
        this.inflight = null
      }
    }
  }

  /**
   * 执行一次真实校验（不复用单飞任务，结果按当前会话落盘）。
   *
   * 两道丢弃规则（都归一为 UNKNOWN，让调用方不做任何处置）：
   * - **序号过期**：本次请求发出后已有更新的结论落地，本次是迟到的旧结果；
   * - **会话已变**：请求发出时的 `uid|cid` 与当前不同（换号/退出），结论属于上一个会话。
   *
   * @returns 校验结果（无会话/超时/异常均为 UNKNOWN 或 INVALID，见各自分支）
   */
  private async verifyNow(): Promise<SessionCheckResult> {
    const session: Session | null = this.resolveSession !== null ? this.resolveSession() : null
    if (session === null) {
      // 无会话也刷新节流基准，否则未登录状态下每次切前台都空转一遍
      this.lastVerifyAt = Date.now()
      const missing: SessionCheckResult = new SessionCheckResult()
      missing.verdict = SessionVerdict.INVALID
      missing.message = '本地会话不存在'
      return missing
    }
    const requestKey: string = session.uid + '|' + session.cid
    const seq: number = ++this.verifySeq
    const result: SessionCheckResult = await this.withTimeout(this.checkFn(session.uid, session.cid))
    if (seq < this.appliedSeq || requestKey !== this.currentSessionKey()) {
      const stale: SessionCheckResult = new SessionCheckResult()
      stale.verdict = SessionVerdict.UNKNOWN
      stale.message = '校验结果已过期'
      return stale
    }
    this.appliedSeq = seq
    this.lastVerifyAt = Date.now()
    this.lastVerdict = result.verdict
    this.lastVerdictKey = requestKey
    this.lastMismatched = result.mismatched
    return result
  }

  /**
   * 是否仍持有本地会话。
   *
   * 区分两种 INVALID：**无会话**（真未登录，该走登录流程）与**有会话但服务端不认**
   * （降级态）。后者才由本类处置，前者必须原样交给登录流程，不能被误标成降级。
   *
   * @returns 是否有本地会话
   */
  private hasSession(): boolean {
    return this.resolveSession !== null && this.resolveSession() !== null
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
   * 进入降级态并通知上层。
   *
   * 幂等由上层保证（AppStore 在状态已是降级时早退），这里不额外去重：
   * 守卫自己也需要在重复失败时保持 `degraded` 为真。
   *
   * @param reason - 诊断文案
   */
  private notifyDegraded(reason: string): void {
    if (!this.hasSession()) {
      // 真未登录：降级没有对象，交给登录流程处理
      return
    }
    this.degraded = true
    if (this.degradedHandler !== null) {
      this.degradedHandler(reason)
    }
  }

  /**
   * 从降级态恢复。
   *
   * 这是"成功即治愈"的落地：**任何一次通过的校验**都会走到这里，用户不需要做任何操作。
   *
   * 注意这里**不能**用 `degraded` 早退：降级入口不止本类的 `notifyDegraded` 一处 ——
   * 启动页与主页面在 `verify()` 拿到 INVALID 后会直接调 `AppStore.markCredentialDegraded`
   * （那里不经过本类），此时 `degraded` 仍是 false。若在此早退，之后的成功复验就永远
   * 触发不了恢复回调，横幅会一直挂到用户手动重新登录。去重交给消费方（AppStore 的
   * `clearCredentialDegraded` 在非降级态会直接返回）。
   */
  private notifyRecovered(): void {
    this.degraded = false
    if (this.recoveredHandler !== null) {
      this.recoveredHandler()
    }
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
}

/** 全局会话守卫（由 AppStore 在 init 时绑定依赖）。 */
export const sessionGuard: SessionGuard = new SessionGuard()
