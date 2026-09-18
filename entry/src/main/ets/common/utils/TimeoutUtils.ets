/**
 * 给 Promise 加超时上限。
 *
 * `Promise.race` 只能让"超时结果"失去意义，挂着的 `setTimeout` 仍需显式清掉——
 * 否则每次成功的调用都会在事件循环里留一个待触发的定时器（长会话页面上会持续累积）。
 *
 * @param promise 被包裹的 Promise
 * @param ms 超时上限（ms）
 * @returns 原 Promise 的结果；超时则以 `Error('timeout')` 拒绝
 */
export function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  let timer: number = -1
  const timeout: Promise<T> = new Promise<T>((_: (value: T) => void, reject: (reason: Error) => void): void => {
    timer = setTimeout((): void => {
      reject(new Error('timeout'))
    }, ms)
  })
  return Promise.race([promise, timeout]).finally((): void => {
    clearTimeout(timer)
  })
}
