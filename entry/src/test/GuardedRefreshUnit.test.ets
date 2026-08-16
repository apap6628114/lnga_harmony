import { describe, expect, it } from '@ohos/hypium'
import { BaseStore } from '../main/ets/store/BaseStore'
import { AuthState } from '../main/ets/store/AuthStore'
import { PreferencesStore } from '../main/ets/common/infra/PreferencesStore'
import { SerialQueue } from '../main/ets/common/infra/SerialQueue'
import { PollingController } from '../main/ets/common/concurrency/PollingController'

/**
 * 受控刷新测试桩：暴露 runGuardedRefresh，可控 perform 的返回值与挂起。
 */
class GuardedRefreshHarness extends BaseStore<Object> {
  override state: Object = new Object()
  /** perform 执行次数。 */
  performCalls: number = 0
  /** perform 返回值（每次执行时读取）。 */
  performResult: boolean = true
  /** perform 是否抛异常（用于验证异常后刷新可重发）。 */
  performThrows: boolean = false
  /** 捕获的 uid。 */
  lastUid: string = ''
  /** 捕获的 token。 */
  lastToken: string = ''
  /** 挂起的 perform 任务。 */
  private pending: Promise<boolean> | null = null
  /** 挂起任务的释放函数。 */
  private release: ((ok: boolean) => void) | null = null

  /**
   * 注入认证依赖（持久化与写队列仅占位，runGuardedRefresh 不触碰）。
   *
   * @param auth - 认证状态
   */
  attach(auth: AuthState): void {
    this.setDeps(new PreferencesStore(), new SerialQueue(), auth)
  }

  /**
   * 发起一次受控刷新。
   *
   * @param force - 是否忽略成功刷新间隔
   * @param minDelayMs - 普通刷新最短成功间隔
   * @returns 刷新是否成功
   */
  async guardedRefresh(force: boolean, minDelayMs: number): Promise<boolean> {
    return this.runGuardedRefresh(force, minDelayMs,
      (generation: number, uid: string, token: string): Promise<boolean> => {
        this.performCalls += 1
        this.lastUid = uid
        this.lastToken = token
        if (this.performThrows) {
          return Promise.reject(new Error('perform boom'))
        }
        if (this.pending) {
          return this.pending
        }
        return Promise.resolve(this.performResult)
      })
  }

  /**
   * 挂起下一次 perform（用于验证并发复用）。
   */
  holdPerform(): void {
    this.pending = new Promise<boolean>((resolve: (ok: boolean) => void): void => {
      this.release = resolve
    })
  }

  /**
   * 释放挂起的 perform。
   *
   * @param ok - 挂起任务的返回值
   */
  releasePerform(ok: boolean): void {
    if (this.release) {
      const resolve: (ok: boolean) => void = this.release
      this.release = null
      this.pending = null
      resolve(ok)
    }
  }
}

/**
 * 创建已认证状态。
 *
 * @returns 已认证的 AuthState
 */
function createAuthenticatedAuth(): AuthState {
  const auth: AuthState = new AuthState()
  auth.uid = '100'
  auth.token = 'token-1'
  auth.isAuthenticated = true
  return auth
}

/**
 * 注册受控刷新与轮询调度器单元测试。
 */
export default function guardedRefreshUnitTest(): void {
  describe('runGuardedRefresh', (): void => {
    it('rejectsWhenUnauthenticated', 0, async (): Promise<void> => {
      const harness: GuardedRefreshHarness = new GuardedRefreshHarness()
      harness.attach(new AuthState())

      const ok: boolean = await harness.guardedRefresh(true, 30000)

      expect(ok).assertFalse()
      expect(harness.performCalls).assertEqual(0)
    })

    it('throttlesNonForcedRefreshWithinMinDelay', 0, async (): Promise<void> => {
      const harness: GuardedRefreshHarness = new GuardedRefreshHarness()
      harness.attach(createAuthenticatedAuth())

      const first: boolean = await harness.guardedRefresh(true, 60000)
      const second: boolean = await harness.guardedRefresh(false, 60000)

      expect(first).assertTrue()
      expect(second).assertTrue()
      expect(harness.performCalls).assertEqual(1)
    })

    it('reusesInflightRefreshPromise', 0, async (): Promise<void> => {
      const harness: GuardedRefreshHarness = new GuardedRefreshHarness()
      harness.attach(createAuthenticatedAuth())
      harness.holdPerform()

      const firstCall: Promise<boolean> = harness.guardedRefresh(true, 0)
      const secondCall: Promise<boolean> = harness.guardedRefresh(true, 0)
      expect(harness.performCalls).assertEqual(1)

      harness.releasePerform(true)
      const firstResult: boolean = await firstCall
      const secondResult: boolean = await secondCall

      expect(firstResult).assertTrue()
      expect(secondResult).assertTrue()
      expect(harness.performCalls).assertEqual(1)
    })

    it('recordsSuccessTimeOnlyAfterSuccess', 0, async (): Promise<void> => {
      const harness: GuardedRefreshHarness = new GuardedRefreshHarness()
      harness.attach(createAuthenticatedAuth())
      harness.performResult = false

      const failed: boolean = await harness.guardedRefresh(true, 60000)
      expect(failed).assertFalse()
      expect(harness.performCalls).assertEqual(1)

      harness.performResult = true
      const retried: boolean = await harness.guardedRefresh(false, 60000)
      expect(retried).assertTrue()
      expect(harness.performCalls).assertEqual(2)

      const throttled: boolean = await harness.guardedRefresh(false, 60000)
      expect(throttled).assertTrue()
      expect(harness.performCalls).assertEqual(2)
    })

    it('passesCurrentUidAndTokenSnapshot', 0, async (): Promise<void> => {
      const harness: GuardedRefreshHarness = new GuardedRefreshHarness()
      harness.attach(createAuthenticatedAuth())

      await harness.guardedRefresh(true, 0)

      expect(harness.lastUid).assertEqual('100')
      expect(harness.lastToken).assertEqual('token-1')
    })

    it('clearsInflightPromiseAfterPerformError', 0, async (): Promise<void> => {
      const harness: GuardedRefreshHarness = new GuardedRefreshHarness()
      harness.attach(createAuthenticatedAuth())
      harness.performThrows = true

      let caught: boolean = false
      try {
        await harness.guardedRefresh(true, 0)
      } catch (e) {
        caught = true
      }
      expect(caught).assertTrue()

      harness.performThrows = false
      const retried: boolean = await harness.guardedRefresh(true, 0)

      expect(retried).assertTrue()
      expect(harness.performCalls).assertEqual(2)
    })
  })

  describe('pollingController', (): void => {
    it('startsWithImmediatePollAndIdempotentStart', 0, (): void => {
      let pollCount: number = 0
      const controller: PollingController = new PollingController(60000, (): void => {
        pollCount += 1
      })

      controller.start()
      controller.start()

      expect(pollCount).assertEqual(1)
    })

    it('restartsAfterStop', 0, (): void => {
      let pollCount: number = 0
      const controller: PollingController = new PollingController(60000, (): void => {
        pollCount += 1
      })

      controller.start()
      controller.stop()
      controller.start()

      expect(pollCount).assertEqual(2)
    })

    it('stopIsIdempotent', 0, (): void => {
      let pollCount: number = 0
      const controller: PollingController = new PollingController(60000, (): void => {
        pollCount += 1
      })

      controller.stop()
      controller.stop()
      controller.start()

      expect(pollCount).assertEqual(1)
    })
  })
}
