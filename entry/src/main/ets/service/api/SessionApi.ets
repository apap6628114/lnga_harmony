/**
 * 会话有效性校验（`nuke.php?__lib=login&__act=iflogin`）。
 *
 * ## 为什么是 iflogin
 *
 * 官方客户端（nga.apk 7.17.17）**不做主动校验**：`UserProviderImpl.isLogin()` 只读
 * `bt.a.k()`（SharedPreferences 的 `login_state` + 本地 LoginDataBean），全代码没有
 * `iflogin` 调用点。但逆向同时确认了 `iflogin` 的 URL 映射（`ct.d.d` pswitch_68f），
 * 并且它是**唯一**能在服务端层面判定"这份 uid+cid 还能不能用"的轻量接口：
 *
 * - `code=0` + `result.uid`：凭证有效（`result` 还带 username/avatar，可顺带刷新昵称）
 * - `code=1` + `msg="SESSION TIMEOUT OR FAIL"`：凭证明确失效
 * - 实测 `ucp/get` **不能**用作判据：匿名请求也返回 `code=0` + 用户对象（username 退化为
 *   `UID<uid>` 占位名），旧 `verifyToken` 的假阳性正源于此。
 *
 * ## 为什么不在这里处理"失效后怎么办"
 *
 * 本模块只回答"有效/失效/无法判定"三态；去抖、二次确认、清态与跳转由
 * `store/SessionGuard` 统一编排。`UNKNOWN` 必须原样返回——网络异常、超时、
 * 频率限制都不能被当成"失效"（官方 `BaseActivity.updateViewByError` 同样不跳登录、不清态）。
 */

import { ngaClient } from '../NgaClient'
import { SessionCheckResult, SessionVerdict, verdictFromIfloginResponse } from './AuthErrors'

/**
 * 用一组 NGA 凭证校验会话是否仍被服务端接受。
 *
 * @param uid - NGA uid（`ngaPassportUid` / LoginDataBean.mUID）
 * @param cid - NGA cid（`ngaPassportCid` / LoginDataBean.token）
 * @returns 三态结论；网络异常/非预期响应一律返回 UNKNOWN
 */
export async function checkSessionByCredential(uid: string, cid: string): Promise<SessionCheckResult> {
  const result: SessionCheckResult = new SessionCheckResult()
  if (uid.length === 0 || cid.length === 0) {
    result.verdict = SessionVerdict.INVALID
    result.message = '会话凭据缺失'
    return result
  }
  try {
    // 登录系接口不走标准业务签名（同 logout），但 iflogin 需要 access_uid/access_token，
    // 签名通道会自动带上它们并计算 sign。
    // 最后一个参数 signalAuthFailure=false：这是"校验请求"本身，不能再触发失效信号，
    // 否则会与 SessionGuard 形成信号回环。
    const raw: object = await ngaClient.postSigned(
      '/nuke.php', 'login', 'iflogin', {}, { uid: uid, cid: cid }, '', '12',
      false, 'utf-8', false
    )
    return verdictFromIfloginResponse(raw, uid)
  } catch (e) {
    // 网络不可达 / 超时 / 连接被拒：无法判定，绝不据此登出
    result.verdict = SessionVerdict.UNKNOWN
    result.message = '无法连接服务器'
    return result
  }
}
