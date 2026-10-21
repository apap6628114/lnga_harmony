import { describe, expect, it } from '@ohos/hypium'
import { classifyAuthFailure, verdictFromIfloginResponse, SessionCheckResult, SessionVerdict } from '../main/ets/service/api/AuthErrors'
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
 * 鉴权错误识别 / iflogin 三态归一 / SessionGuard 去抖与处置的回归测试。
 *
 * 判定矩阵来自 2026-10 对 NGA 真实接口的实测（坏 cid 场景）与 nga-hack 官方客户端逆向
 * （`NetProviderImpl.checkHttpResult` 的判据：code==12 或未登录文案）。
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
    })

    it('verdictFromIfloginResponseIsThreeState', 0, (): void => {
      // 有效：code=0 + result.uid 与本地一致
      const valid: SessionCheckResult =
        verdictFromIfloginResponse(resp('{"code":0,"result":{"uid":"1001","username":"tester"}}'), '1001')
      expect(valid.verdict).assertEqual(SessionVerdict.VALID)
      expect(valid.uid).assertEqual('1001')

      // 凭证错配：code=0 但 uid 是另一个账号
      expect(verdictFromIfloginResponse(resp('{"code":0,"result":{"uid":"2002"}}'), '1001').verdict)
        .assertEqual(SessionVerdict.INVALID)

      // 明确失效
      expect(verdictFromIfloginResponse(resp('{"code":1,"msg":"SESSION TIMEOUT OR FAIL"}'), '1001').verdict)
        .assertEqual(SessionVerdict.INVALID)
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

    it('confirmedInvalidTriggersExpiredOnce', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      let checked: number = 0
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        checked++
        return makeResult(SessionVerdict.INVALID)
      })
      let expired: number = 0
      let navigated: number = 0
      guard.bindExpiredHandler((): boolean => {
        expired++
        return true
      })
      guard.attachNavigator((): void => { navigated++ })

      await guard.onUnauthorizedSignal('未登录')
      expect(checked).assertEqual(1)
      expect(expired).assertEqual(1)
      expect(navigated).assertEqual(1)

      // 60s 去抖：第二次信号不再校验、不再重复清态
      await guard.onUnauthorizedSignal('未登录')
      expect(checked).assertEqual(1)
      expect(expired).assertEqual(1)
    })

    it('unknownDoesNotLogout', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        return makeResult(SessionVerdict.UNKNOWN)
      })
      let expired: number = 0
      guard.bindExpiredHandler((): boolean => {
        expired++
        return true
      })
      guard.attachNavigator((): void => { expired++ })

      await guard.onUnauthorizedSignal('SESSION TIMEOUT OR FAIL')
      expect(expired).assertEqual(0)
    })

    it('validSignalKeepsSession', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        return makeResult(SessionVerdict.VALID)
      })
      let expired: number = 0
      guard.bindExpiredHandler((): boolean => {
        expired++
        return true
      })
      guard.attachNavigator((): void => { expired++ })

      await guard.onUnauthorizedSignal('未登录')
      expect(expired).assertEqual(0)
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

    it('genericCodeOneStaysUnknownAndNeverLogsOut', 0, (): void => {
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

    it('timeoutIsUnknownAndNeverLogsOut', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      guard.bindTimeoutMs(30)
      // 永不 settle 的校验：只能靠超时兜底
      guard.bindCheckFn((): Promise<SessionCheckResult> => {
        return new Promise<SessionCheckResult>((resolve: (value: SessionCheckResult) => void): void => {})
      })
      let expired: number = 0
      guard.bindExpiredHandler((): boolean => {
        expired++
        return true
      })
      expect(await guard.verify()).assertEqual(SessionVerdict.UNKNOWN)
      expect(expired).assertEqual(0)
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

    it('declinedExpiredHandlerSkipsNavigation', 0, async (): Promise<void> => {
      const guard: SessionGuard = new SessionGuard()
      guard.bindSessionResolver((): Session | null => makeSession())
      guard.bindCheckFn(async (uid: string, cid: string): Promise<SessionCheckResult> => {
        return makeResult(SessionVerdict.INVALID)
      })
      let navigated: number = 0
      // 未登录/页面销毁窗口：AppStore 早退返回 false，此时不应再跳登录页
      guard.bindExpiredHandler((): boolean => false)
      guard.attachNavigator((): void => { navigated++ })

      await guard.onUnauthorizedSignal('未登录')
      expect(navigated).assertEqual(0)
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
