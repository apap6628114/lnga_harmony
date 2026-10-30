import { describe, expect, it } from '@ohos/hypium'
import { classifyAuthFailure, verdictFromIfloginResponse, SessionCheckResult, SessionVerdict } from '../main/ets/service/api/AuthErrors'
import { buildBlockedResponse } from '../main/ets/service/NgaClient'
import { parseNgaError } from '../main/ets/parser/ErrorParser'
import { SessionGuard } from '../main/ets/store/SessionGuard'
import { selectRecoveryCredential, RecoveryCredential } from '../main/ets/store/SessionRecovery'
import type { Session } from '../main/ets/store/SessionRegistry'

/**
 * 构造一个响应对象（与线上一致：JSON 解析后的普通对象）。
 *
 * @param json - 响应 JSON 文本
 * @returns 响应对象
 */
function resp(json: string): Record<string, Object> {
  return JSON.parse(json) as Record<string, Object>
}

/**
 * 构造一个可用的本地会话。
 *
 * @returns 会话对象
 */
function makeSession(): Session {
  const session: Session = {
    uid: '1001',
    cid: 'cid-1001',
    nickName: 'tester',
    avatarUrl: '',
    createdAt: 0,
  }
  return session
}

/**
 * 构造指定账号的会话。
 *
 * @param uid - NGA uid
 * @param cid - NGA cid
 * @returns 会话对象
 */
function makeSessionOf(uid: string, cid: string): Session {
  const session: Session = {
    uid: uid,
    cid: cid,
    nickName: 'tester',
    avatarUrl: '',
    createdAt: 0,
  }
  return session
}

/**
 * 构造指定结论的校验结果。
 *
 * @param verdict - 结论
 * @returns 校验结果
 */
function makeResult(verdict: SessionVerdict): SessionCheckResult {
  const result: SessionCheckResult = new SessionCheckResult()
  result.verdict = verdict
  return result
}

/**
 * 鉴权错误识别 / iflogin 三态归一 / SessionGuard 去抖、降级与自愈的回归测试。
 *
 * 判定矩阵来自 2026-10 对 NGA 真实接口的实测（坏 cid 场景）与 nga-hack 官方客户端逆向
 * （`NetProviderImpl.checkHttpResult` 的判据：code==12 或未登录文案）。
 *
 * 处置契约已从「确认失效 → 清登录态 + 跳登录页」改为「确认失效 → 进入降级态」：
 * 本地凭证与全部 Store 保留，读能力照常尝试，写能力由网络层门禁拦截。原因是实测
 * NGA 各接口的会话校验强度不一致（`read.php` 弱于 `nuke.php`），服务端局部异常期间
 * 完全可能「帖子能读、iflogin 报失效」——用最严格接口的结论清空一切会误杀有效凭证。
 */
export default function sessionUnitTest(): void {
  describe('sessionAuth', (): void => {
    it('classifyAuthFailureMatchesRealServerSignals', 0, (): void => {
      // 未登录/会话失效：实测三种码都出现过
      expect(classifyAuthFailure(resp('{"code":12,"msg":"未登录"}'))).assertEqual('未登录')
      expect(classifyAuthFailure(resp('{"code":12,"msg":"尚未登录"}'))).assertEqual('尚未登录')
      expect(classifyAuthFailure(resp('{"code":2048,"msg":"你必须先登录论坛"}'))).assertEqual('你必须先登录论坛')
      expect(classifyAuthFailure(resp('{"code":1,"msg":"SESSION TIMEOUT OR FAIL"}'))).assertEqual('SESSION TIMEOUT OR FAIL')
      expect(classifyAuthFailure(resp('{"code":1,"msg":"你必须先登录论坛"}'))).assertEqual('你必须先登录论坛')
      // 无 code 的网页通道错误页也按文案识别
      expect(classifyAuthFailure(resp('{"msg":"未登录"}'))).assertEqual('未登录')

      // 与登录态无关：不得触发失效
      expect(classifyAuthFailure(resp('{"code":0,"msg":"操作成功"}'))).assertNull()
      expect(classifyAuthFailure(resp('{"code":1,"msg":"ACTION NOT FOUND __act_list lib_notify"}'))).assertNull()
      expect(classifyAuthFailure(resp('{"code":2,"msg":"未定义服务"}'))).assertNull()
      expect(classifyAuthFailure(resp('{"code":5,"msg":"签名错误"}'))).assertNull()
      expect(classifyAuthFailure(resp('{"code":15,"msg":"频率限制"}'))).assertNull()
      expect(classifyAuthFailure(resp('{"code":2048,"msg":"参数错误"}'))).assertNull()
      expect(classifyAuthFailure(resp('{"code":521,"html":"<html></html>"}'))).assertNull()
      expect(classifyAuthFailure(resp('{"__parseError":true}'))).assertNull()
      // 本地写门禁合成的失败响应不是服务端信号：识别成未登录会与降级态形成信号回环
      expect(classifyAuthFailure(resp('{"error":{"0":"请先登录后再操作"},"__localBlocked":true}'))).assertNull()
    })

    it('blockedResponseFailsEveryConsumerContract', 0, (): void => {
      // 本地门禁合成的失败响应必须同时满足三类调用方的判读方式，否则会把"被拦下"误判成成功：
      // 签到用的是 `Number(raw['code'] ?? 0) === 0` 即成功，缺 `code` 就会报"签到成功"。
      const blocked: Record<string, Object> = buildBlockedResponse('登录状态异常，请点击顶部提示重新登录后再试')
      expect(Number(blocked['code'])).assertEqual(1)
      expect(String(blocked['msg'])).assertEqual('登录状态异常，请点击顶部提示重新登录后再试')
      // 按 error['0'] 取文案的通道（网页错误页形态 / readAppError 的兜底分支）
      expect(parseNgaError(blocked)).assertEqual('登录状态异常，请点击顶部提示重新登录后再试')
      // 不能被当成服务端的未登录信号，否则降级态会被自己的拦截反复确认
      expect(classifyAuthFailure(blocked)).assertNull()
    })

    it('verdictFromIfloginResponseIsThreeState', 0, (): void => {
      // 有效：code=0 + result.uid 与本地一致
      const valid: SessionCheckResult =
        verdictFromIfloginResponse(resp('{"code":0,"result":{"uid":"1001","username":"tester"}}'), '1001')
      expect(valid.verdict).assertEqual(SessionVerdict.VALID)
      expect(valid.uid).assertEqual('1001')

      // 凭证错配：code=0 但 uid 是另一个账号 —— 必须与普通失效区分开（上层要清态重登）
      const mismatch: SessionCheckResult =
        verdictFromIfloginResponse(resp('{"code":0,"result":{"uid":"2002"}}'), '1001')
      expect(mismatch.verdict).assertEqual(SessionVerdict.INVALID)
      expect(mismatch.mismatched).assertTrue()

      // 明确失效
      expect(verdictFromIfloginResponse(resp('{"code":1,"msg":"SESSION TIMEOUT OR FAIL"}'), '1001').verdict)
        .assertEqual(SessionVerdict.INVALID)
      expect(verdictFromIfloginResponse(resp('{"code":1,"msg":"SESSION TIMEOUT OR FAIL"}'), '1001').mismatched)
        .assertFalse()
      expect(verdictFromIfloginResponse(resp('{"code":12,"msg":"未登录"}'), '1001').verdict)
        .assertEqual(SessionVerdict.INVALID)

      // 无法判定：频率限制 / 签名错误 / 空响应 / 解析失败 / code=0 但无 uid
      expect(verdictFromIfloginResponse(resp('{"code":15,"msg":"频率限制"}'), '1001').verdict)
        .assertEqual(SessionVerdict.UNKNOWN)
      expect(verdictFromIfloginResponse(resp('{"code":5,"msg":"签名错误"}'), '1001').verdict)
        .assertEqual(SessionVerdict.UNKNOWN)
      expect(verdictFromIfloginResponse(resp('{}'), '1001').verdict)
        .assertEqual(SessionVerdict.UNKNOWN)
      expect(verdictFromIfloginResponse(resp('{"__parseError":true}'), '1001').verdict)
        .assertEqual(SessionVerdict.UNKNOWN)
      expect(verdictFromIfloginResponse(resp('{"code":0,"result":{}}'), '1001').verdict)
        .assertEqual(SessionVerdict.UNKNOWN)
    })

    it('noLocalSessionIsInvalidWithoutNetwork', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      let checked: number = 0
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        checked++
        return makeResult(SessionVerdict.VALID)
      })
      // 未注入 resolver → 无本地会话
      expect(await guard.verify()).assertEqual(SessionVerdict.INVALID)
      expect(checked).assertEqual(0)
    })

    it('confirmedInvalidEntersDegradedAfterSilentRecheck', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      // 跳过 2 秒静默复验等待（业务常量不变，只压缩测试时长）
      guard.bindConfirmDelayMs(0)
      let checked: number = 0
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        checked++
        return makeResult(SessionVerdict.INVALID)
      })
      let degraded: number = 0
      let recovered: number = 0
      guard.bindDegradedHandler((reason: string): void => { degraded++ })
      guard.bindRecoveredHandler((): void => { recovered++ })

      await guard.onUnauthorizedSignal('未登录')
      // 首次判定 + 静默复验各一次；确认后进入降级（不清态、不导航）
      expect(checked).assertEqual(2)
      expect(degraded).assertEqual(1)
      expect(recovered).assertEqual(0)
      expect(guard.isDegraded()).assertTrue()

      // 60s 去抖：第二次信号不再校验、不再重复触发
      await guard.onUnauthorizedSignal('未登录')
      expect(checked).assertEqual(2)
      expect(degraded).assertEqual(1)
    })

    it('silentRecheckCancelsTransientFailure', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      guard.bindConfirmDelayMs(0)
      let checked: number = 0
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        checked++
        // 首次报失效、复验通过：典型的服务端瞬时抖动
        return makeResult(checked === 1 ? SessionVerdict.INVALID : SessionVerdict.VALID)
      })
      let degraded: number = 0
      guard.bindDegradedHandler((reason: string): void => { degraded++ })

      await guard.onUnauthorizedSignal('未登录')
      expect(checked).assertEqual(2)
      // 抖动被静默复验挡在降级之外：用户完全无感
      expect(degraded).assertEqual(0)
      expect(guard.isDegraded()).assertFalse()
    })

    it('reverifyRecoversFromDegraded', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      guard.bindConfirmDelayMs(0)
      let invalid: boolean = true
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        return makeResult(invalid ? SessionVerdict.INVALID : SessionVerdict.VALID)
      })
      let degraded: number = 0
      let recovered: number = 0
      guard.bindDegradedHandler((reason: string): void => { degraded++ })
      guard.bindRecoveredHandler((): void => { recovered++ })

      await guard.onUnauthorizedSignal('未登录')
      expect(guard.isDegraded()).assertTrue()

      // 服务端恢复：强制复验应自动治愈（横幅靠这条链路消失）
      invalid = false
      expect(await guard.reverify()).assertEqual(SessionVerdict.VALID)
      expect(recovered).assertEqual(1)
      expect(guard.isDegraded()).assertFalse()
    })

    it('verifyDoesNotDegradeOnItsOwn', 0, async (): Promise<void> => {
      // 主动校验只提供结论，INVALID 的处置由调用方（启动页/主页面）决定：
      // 它们在"无本地凭证"与"有凭证但服务端不认"两种 INVALID 上要走不同分支。
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        return makeResult(SessionVerdict.INVALID)
      })
      let degraded: number = 0
      guard.bindDegradedHandler((reason: string): void => { degraded++ })

      expect(await guard.verify()).assertEqual(SessionVerdict.INVALID)
      expect(degraded).assertEqual(0)
      expect(guard.isDegraded()).assertFalse()
    })

    it('unknownDoesNotDegrade', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        return makeResult(SessionVerdict.UNKNOWN)
      })
      let degraded: number = 0
      guard.bindDegradedHandler((reason: string): void => { degraded++ })

      await guard.onUnauthorizedSignal('SESSION TIMEOUT OR FAIL')
      expect(degraded).assertEqual(0)
    })

    it('validSignalKeepsSession', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        return makeResult(SessionVerdict.VALID)
      })
      let degraded: number = 0
      guard.bindDegradedHandler((reason: string): void => { degraded++ })

      await guard.onUnauthorizedSignal('未登录')
      expect(degraded).assertEqual(0)
    })

    it('degradedHandlerIsOptional', 0, async (): Promise<void> => {
      // 未注入任何回调时不得抛错（AppStore 尚未完成初始化的窗口期）
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      guard.bindConfirmDelayMs(0)
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        return makeResult(SessionVerdict.INVALID)
      })
      await guard.onUnauthorizedSignal('未登录')
      expect(guard.isDegraded()).assertTrue()
    })

    it('foregroundVerifyIsThrottled', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      let checked: number = 0
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        checked++
        return makeResult(SessionVerdict.VALID)
      })
      await guard.verifyOnForeground()
      expect(checked).assertEqual(1)
      // 10 分钟内再次前台恢复：跳过
      await guard.verifyOnForeground()
      expect(checked).assertEqual(1)
    })

    it('verifyIfStaleReusesVerdictOnlyForSameSession', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      let uid: string = '1001'
      guard.bindSessionResolver((): Session | null => {
        const session: Session = makeSession()
        session.uid = uid
        return session
      })
      let checked: number = 0
      guard.bindCheckFn(async (uidValue: string, cidValue: string): Promise<SessionCheckResult> => {
        checked++
        return makeResult(SessionVerdict.VALID)
      })

      await guard.verify()
      // 同一会话 30s 内复用结论，不再请求
      await guard.verifyIfStale(30 * 1000)
      expect(checked).assertEqual(1)
      // 换账号（会话标识变化）必须重新校验，不能沿用上一个账号的结论
      uid = '2002'
      await guard.verifyIfStale(30 * 1000)
      expect(checked).assertEqual(2)
    })

    it('genericCodeOneStaysUnknownAndNeverDegrades', 0, (): void => {
      // code=1 是通用业务失败码（官方也用它表示 ACTION NOT FOUND），
      // 只有文案命中会话类措辞才判失效——否则本次修复会把登录态误杀回来。
      expect(verdictFromIfloginResponse(
        resp('{"code":1,"msg":"ACTION NOT FOUND __act_list lib_notify"}'), '1001').verdict)
        .assertEqual(SessionVerdict.UNKNOWN)
      expect(verdictFromIfloginResponse(
        resp('{"code":1,"msg":"SESSION TIMEOUT OR FAIL"}'), '1001').verdict)
        .assertEqual(SessionVerdict.INVALID)
    })

    it('stringCodeAndHtmlErrorCodeAreNormalized', 0, (): void => {
      // 服务端部分接口把 code 下发成字符串
      expect(classifyAuthFailure(resp('{"code":"12","msg":"未登录"}'))).assertEqual('未登录')
      expect(verdictFromIfloginResponse(
        resp('{"code":"0","result":{"uid":"1001"}}'), '1001').verdict)
        .assertEqual(SessionVerdict.VALID)
      // 网页通道 HTML 错误页：{ error: {0:...}, error_code: 11 }
      expect(classifyAuthFailure(resp('{"error":{"0":"未登录"},"error_code":11}'))).assertEqual('未登录')
      expect(classifyAuthFailure(resp('{"error":{"0":"服务器繁忙"},"error_code":15}'))).assertNull()
    })

    it('concurrentVerifyReusesInflight', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      let calls: number = 0
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        calls++
        return makeResult(SessionVerdict.VALID)
      })
      const first: Promise<SessionVerdict> = guard.verify()
      const second: Promise<SessionVerdict> = guard.verify()
      expect(await first).assertEqual(SessionVerdict.VALID)
      expect(await second).assertEqual(SessionVerdict.VALID)
      expect(calls).assertEqual(1)
    })

    it('timeoutIsUnknownAndNeverDegrades', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      guard.bindTimeoutMs(30)
      // 永不 settle 的校验：只能靠超时兜底
      guard.bindCheckFn((): Promise<SessionCheckResult> => {
        return new Promise<SessionCheckResult>((resolve: (value: SessionCheckResult) => void): void => {})
      })
      let degraded: number = 0
      guard.bindDegradedHandler((reason: string): void => { degraded++ })
      expect(await guard.verify()).assertEqual(SessionVerdict.UNKNOWN)
      expect(degraded).assertEqual(0)
    })

    it('clearedSessionIsInvalidWithoutReuse', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      let session: Session | null = makeSession()
      guard.bindSessionResolver((): Session | null => session)
      let calls: number = 0
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        calls++
        return makeResult(SessionVerdict.VALID)
      })
      await guard.verify()
      expect(calls).assertEqual(1)
      // 清登录态后：不复用旧结论、也不发请求（无会话）
      session = null
      expect(await guard.verifyIfStale(60 * 1000)).assertEqual(SessionVerdict.INVALID)
      expect(calls).assertEqual(1)
    })

    it('noSessionNeverDegrades', 0, async (): Promise<void> => {
      // 真未登录（本地无会话）不是降级：必须原样交给登录流程，不能被标成降级态
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => null)
      guard.bindConfirmDelayMs(0)
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        return makeResult(SessionVerdict.INVALID)
      })
      let degraded: number = 0
      guard.bindDegradedHandler((reason: string): void => { degraded++ })

      await guard.onUnauthorizedSignal('未登录')
      expect(degraded).assertEqual(0)
      expect(guard.isDegraded()).assertFalse()
    })

    it('resetForNewSessionClearsDegradedState', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      guard.bindConfirmDelayMs(0)
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        return makeResult(SessionVerdict.INVALID)
      })
      await guard.onUnauthorizedSignal('未登录')
      expect(guard.isDegraded()).assertTrue()

      // 重新登录：守卫必须复位，否则之后任何成功校验都不会触发恢复回调，横幅会一直挂着
      guard.resetForNewSession()
      expect(guard.isDegraded()).assertFalse()
      // 信号去抖窗口同时复位：新会话立刻失效也要能被识别
      let checked: number = 0
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        checked++
        return makeResult(SessionVerdict.INVALID)
      })
      await guard.onUnauthorizedSignal('未登录')
      expect(checked).assertEqual(2)
    })

    it('markDegradedIsExposedAndResettable', 0, (): void => {
      // 启动页/主页面直接判定 INVALID 时不经过 notifyDegraded，必须显式同步这个标志：
      // 它决定前台恢复探针的节流间隔（降级态 1 分钟 / 正常态 10 分钟）。
      const guard: SessionGuard = new SessionGuard()
      expect(guard.isDegraded()).assertFalse()
      guard.markDegraded()
      expect(guard.isDegraded()).assertTrue()
      guard.resetForNewSession()
      expect(guard.isDegraded()).assertFalse()
    })

    it('abandonsConfirmWhenSessionClearedDuringWait', 0, async (): Promise<void> => {
      // 静默复验的 2 秒窗口里用户可能已经主动退出登录。
      // 用非 0 的等待时长真正走进那个分支（bindConfirmDelayMs(0) 会整块跳过）。
      const guard: SessionGuard = new SessionGuard()
      let session: Session | null = makeSession()
      guard.bindSessionResolver((): Session | null => session)
      guard.bindConfirmDelayMs(1)
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        session = null
        return makeResult(SessionVerdict.INVALID)
      })
      let degraded: number = 0
      guard.bindDegradedHandler((reason: string): void => { degraded++ })

      await guard.onUnauthorizedSignal('未登录')
      // 等待结束时会话已不存在：这次判定失去对象，不得降级
      expect(degraded).assertEqual(0)
      expect(guard.isDegraded()).assertFalse()
    })

    it('secondRecheckUnknownDoesNotDegrade', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      guard.bindConfirmDelayMs(0)
      let calls: number = 0
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        calls++
        // 首次明确失效、复验无法判定：证据不足，不能据此降级
        return makeResult(calls === 1 ? SessionVerdict.INVALID : SessionVerdict.UNKNOWN)
      })
      let degraded: number = 0
      guard.bindDegradedHandler((reason: string): void => { degraded++ })

      await guard.onUnauthorizedSignal('未登录')
      expect(calls).assertEqual(2)
      expect(degraded).assertEqual(0)
      expect(guard.isDegraded()).assertFalse()
    })

    it('externalMarkDegradedStillRecoversOnNextValidCheck', 0, async (): Promise<void> => {
      // 启动页/主页面直接标记降级时，守卫内部 degraded 仍为 false。
      // 之后的成功校验必须照样触发恢复回调，否则横幅永远不消失。
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        return makeResult(SessionVerdict.VALID)
      })
      let recovered: number = 0
      guard.bindRecoveredHandler((): void => { recovered++ })

      guard.markDegraded()
      expect(await guard.verify()).assertEqual(SessionVerdict.VALID)
      expect(recovered).assertEqual(1)
      expect(guard.isDegraded()).assertFalse()
    })

    it('lateVerifyResultCannotOverrideNewerOne', 0, async (): Promise<void> => {
      // 降级态下用户点「重试」时，信号路径可能还有一个更早发出的校验在途。
      // 若不做序号判定，迟到的 VALID 会把刚落地的 INVALID 撤销 —— 表现为横幅闪一下又回来。
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      const pending: Array<(result: SessionCheckResult) => void> = []
      guard.bindCheckFn((uid: string, cid: string): Promise<SessionCheckResult> => {
        return new Promise<SessionCheckResult>((resolve: (value: SessionCheckResult) => void): void => {
          pending.push(resolve)
        })
      })
      let degraded: number = 0
      let recovered: number = 0
      guard.bindDegradedHandler((reason: string): void => { degraded++ })
      guard.bindRecoveredHandler((): void => { recovered++ })

      const first: Promise<SessionVerdict> = guard.reverify()
      const second: Promise<SessionVerdict> = guard.reverify()
      // 后发先至：第二次校验先返回 INVALID，降级生效
      pending[1](makeResult(SessionVerdict.INVALID))
      expect(await second).assertEqual(SessionVerdict.INVALID)
      expect(guard.isDegraded()).assertTrue()

      // 更早发出的第一次迟到返回 VALID：必须被作废（归一为 UNKNOWN），不得撤销降级
      pending[0](makeResult(SessionVerdict.VALID))
      expect(await first).assertEqual(SessionVerdict.UNKNOWN)
      expect(recovered).assertEqual(0)
      expect(guard.isDegraded()).assertTrue()
    })
  })

  describe('sessionRecovery', (): void => {
    it('refusesToGuessAccountWithoutUid', 0, (): void => {
      // auth.uid 为空时绝不能从其它会话里"随便挑一个"，否则会把 A 的 token 绑到 B 的账号
      const sessions: Session[] = [makeSessionOf('1001', 'cid-a'), makeSessionOf('2002', 'cid-b')]
      expect(selectRecoveryCredential('', 'cid-x', sessions)).assertNull()
      expect(selectRecoveryCredential('', '', sessions)).assertNull()
    })

    it('prefersPersistedCidAndFallsBackToSameUidOnly', 0, (): void => {
      const otherAccounts: Session[] = [makeSessionOf('2002', 'cid-b')]
      // auth 里冗余的 cid 最可靠：直接可用
      const direct: RecoveryCredential | null = selectRecoveryCredential('1001', 'cid-auth', otherAccounts)
      expect(direct).not().assertNull()
      if (direct !== null) {
        expect(direct.uid).assertEqual('1001')
        expect(direct.cid).assertEqual('cid-auth')
      }
      // auth.cid 缺失（旧格式）且 sessions 里没有同 uid → 不得借用别人的会话
      expect(selectRecoveryCredential('1001', '', otherAccounts)).assertNull()
      // 同 uid 的其它会话（token 换代残留）可用
      const sameUid: Session[] = [makeSessionOf('1001', 'cid-a'), makeSessionOf('2002', 'cid-b')]
      const matched: RecoveryCredential | null = selectRecoveryCredential('1001', '', sameUid)
      expect(matched).not().assertNull()
      if (matched !== null) {
        expect(matched.uid).assertEqual('1001')
        expect(matched.cid).assertEqual('cid-a')
      }
    })
  })
}
