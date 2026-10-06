import { describe, expect, it } from '@ohos/hypium'
import {
  dismissAnalyzerSessions,
  registerAnalyzerSession,
  unregisterAnalyzerSession,
} from '../main/ets/common/media/ImageAnalyzerSession'

/**
 * 识图会话拆除回调探针：只记录被调用次数，不依赖任何 ArkUI 状态。
 */
class DismissProbe {
  /** 拆除回调被调用的次数。 */
  calls: number = 0

  /**
   * 构造拆除回调。
   *
   * @returns 每次被调用即自增计数的回调
   */
  handler(): () => void {
    return (): void => {
      this.calls += 1
    }
  }
}

/**
 * 注册识图选取态会话登记表的回归测试。
 *
 * 保护的行为是"取消选取态"这条链路里唯一可单测的纯逻辑：登记 / 注销 / 一次性拆除全部，
 * 以及**拆除回调在回调内部注销自己**这一真实时序（正文组件的 `endAnalyzerSession`
 * 既拆分析器又注销句柄，而登记表在回调前已整体换成空表）。
 */
export default function imageAnalyzerSessionUnitTest(): void {
  describe('imageAnalyzerSession', (): void => {
    it('dismissesRegisteredSessionExactlyOnce', 0, (): void => {
      dismissAnalyzerSessions()
      const probe: DismissProbe = new DismissProbe()
      registerAnalyzerSession(probe.handler())

      dismissAnalyzerSessions()

      expect(probe.calls).assertEqual(1)
      /* 会话已被收走，再次拆除不应重复回调（宿主列表每帧都会调一次）。 */
      dismissAnalyzerSessions()
      expect(probe.calls).assertEqual(1)
    })

    it('skipsUnregisteredSession', 0, (): void => {
      dismissAnalyzerSessions()
      const probe: DismissProbe = new DismissProbe()
      const token: number = registerAnalyzerSession(probe.handler())

      unregisterAnalyzerSession(token)
      dismissAnalyzerSessions()

      expect(probe.calls).assertEqual(0)
    })

    it('ignoresUnknownAndRepeatedToken', 0, (): void => {
      dismissAnalyzerSessions()
      const probe: DismissProbe = new DismissProbe()
      const token: number = registerAnalyzerSession(probe.handler())

      /* 组件销毁路径可能重复调用注销（含 0 号无效句柄），不能误伤别的会话。 */
      unregisterAnalyzerSession(0)
      unregisterAnalyzerSession(token)
      unregisterAnalyzerSession(token)
      dismissAnalyzerSessions()

      expect(probe.calls).assertEqual(0)
    })

    it('dismissesEveryLiveSession', 0, (): void => {
      dismissAnalyzerSessions()
      const first: DismissProbe = new DismissProbe()
      const second: DismissProbe = new DismissProbe()
      registerAnalyzerSession(first.handler())
      registerAnalyzerSession(second.handler())

      dismissAnalyzerSessions()

      expect(first.calls).assertEqual(1)
      expect(second.calls).assertEqual(1)
    })

    it('unregistersOnlyMatchingToken', 0, (): void => {
      dismissAnalyzerSessions()
      const first: DismissProbe = new DismissProbe()
      const second: DismissProbe = new DismissProbe()
      const firstToken: number = registerAnalyzerSession(first.handler())
      const secondToken: number = registerAnalyzerSession(second.handler())

      /* 句柄必须唯一：否则"注销自己那条"会误删别人的会话。 */
      expect(firstToken === secondToken).assertFalse()
      unregisterAnalyzerSession(firstToken)
      dismissAnalyzerSessions()

      expect(first.calls).assertEqual(0)
      expect(second.calls).assertEqual(1)
    })

    it('keepsOnlyLatestSessionOfSameOwner', 0, (): void => {
      /* 同一正文组件二次长按：先注销旧句柄再登记新句柄，一次拆除只应回调最新的那个。 */
      dismissAnalyzerSessions()
      const stale: DismissProbe = new DismissProbe()
      const latest: DismissProbe = new DismissProbe()
      unregisterAnalyzerSession(registerAnalyzerSession(stale.handler()))
      registerAnalyzerSession(latest.handler())

      dismissAnalyzerSessions()

      expect(stale.calls).assertEqual(0)
      expect(latest.calls).assertEqual(1)
    })

    it('toleratesUnregisterInsideDismissCallback', 0, (): void => {
      dismissAnalyzerSessions()
      const order: number[] = []
      let ownToken: number = 0
      ownToken = registerAnalyzerSession((): void => {
        order.push(1)
        unregisterAnalyzerSession(ownToken)
      })
      const probe: DismissProbe = new DismissProbe()
      registerAnalyzerSession(probe.handler())

      dismissAnalyzerSessions()

      expect(order.length).assertEqual(1)
      expect(order[0]).assertEqual(1)
      expect(probe.calls).assertEqual(1)
      /* 回调内注销的句柄不会破坏本次拆除，后续拆除也不残留。 */
      dismissAnalyzerSessions()
      expect(order.length).assertEqual(1)
      expect(probe.calls).assertEqual(1)
    })

    it('keepsSessionRegisteredDuringDismissCallback', 0, (): void => {
      dismissAnalyzerSessions()
      const late: DismissProbe = new DismissProbe()
      let reentered: boolean = false
      registerAnalyzerSession((): void => {
        if (!reentered) {
          reentered = true
          registerAnalyzerSession(late.handler())
        }
      })

      dismissAnalyzerSessions()

      /* 登记表在回调之前换表：回调里新登记的会话属于"下一次交互"，不被本次拆除吞掉。 */
      expect(reentered).assertTrue()
      expect(late.calls).assertEqual(0)

      dismissAnalyzerSessions()
      expect(late.calls).assertEqual(1)
    })
  })
}
