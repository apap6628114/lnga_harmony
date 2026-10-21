/**
 * 鉴权类错误的统一识别与会话校验结论归一化。
 *
 * 这里只放**纯函数**（不 import 网络层 / Store），以便 Hypium 本地用例覆盖：
 *
 * - `classifyAuthFailure`：网络层出口用来识别"响应里出现未登录/会话失效信号"。
 *   官方客户端（nga.apk 7.17.17）的判据是 `code == 12` 或 msg ∈
 *   {未登录, token错误, 你没有登录}（`NetProviderImpl.checkHttpResult` /
 *   `BaseActivity.updateViewForFailed`）；但实测 NGA 对同一件事会下发
 *   `code=12` / `code=2048` / `code=1` 三种码，因此这里按"码 + 文案"组合识别，
 *   且**必须再经服务端确认**（`SessionGuard` 的 iflogin 校验）才允许登出——
 *   单个业务错误绝不能直接清登录态。
 *
 * - `verdictFromIfloginResponse`：把 `login/iflogin` 的响应归一成三态结论。
 *   `UNKNOWN`（网络异常、非预期响应、频率限制等）**永远不能**当成失效，
 *   这是"离线/服务端抖动不把用户踢下线"的唯一保障。
 */

import { extractAppUser } from '../../parser/AppUserParser'

/** 会话校验结论。 */
export enum SessionVerdict {
  /** 凭证有效（服务端明确认可）。 */
  VALID = 0,
  /** 凭证明确失效（服务端明确拒绝）。 */
  INVALID = 1,
  /** 无法判定（网络异常、超时、非预期响应）——不得据此登出。 */
  UNKNOWN = 2,
}

/** 一次会话校验的结果。 */
export class SessionCheckResult {
  /** 结论。 */
  verdict: SessionVerdict = SessionVerdict.UNKNOWN
  /** 服务端返回的 uid（可能为空）。 */
  uid: string = ''
  /** 诊断文案（服务端原文或本地原因；不含任何凭证）。 */
  message: string = ''
}

/**
 * 读取响应里的文案字段（App 通道为 string；部分通道为 `{0: "..."}`）。
 *
 * @param value - `msg` / `error` 字段
 * @returns 文案；无法读取时为空串
 */
function readMessage(value: Object | undefined): string {
  if (value === undefined || value === null) {
    return ''
  }
  if (typeof value === 'string') {
    return value
  }
  if (typeof value === 'object') {
    const record: Record<string, Object> = value as Record<string, Object>
    const first: Object | undefined = record['0']
    if (typeof first === 'string') {
      return first
    }
  }
  return ''
}

/**
 * 识别响应中的"未登录 / 会话失效"信号。
 *
 * 判定矩阵（依据实测的 App 通道响应）：
 * - `code == 12`：未登录/登录态失效（favor/all 下发"尚未登录"、notify/list 下发"未登录"）
 * - `code == 2048` 且文案含"登录"：message/list 下发"你必须先登录论坛"
 * - `code == 1` 且文案命中会话类措辞：follow_v2/check_in 下发"你必须先登录论坛"、
 *   iflogin 下发"SESSION TIMEOUT OR FAIL"
 * - HTML 错误页的 `error_code == 11 / 12`（网页通道未登录，带 `error` 对象）
 * - 无 `code` 但文案恰为会话类措辞：网页通道其它错误页
 *
 * 明确**不**命中的：`code == 521`（业务错误但带 html，官方会跳说明页）、
 * `__parseError`（解析失败）、`code == 15`（频率限制）、`code == 5`（签名错误）。
 *
 * @param raw - NGA 响应对象
 * @returns 命中时的文案（用于日志/提示）；未命中返回 null
 */
export function classifyAuthFailure(raw: object): string | null {
  if (raw === null || raw === undefined) {
    return null
  }
  const data: Record<string, Object> = raw as Record<string, Object>
  if (data['__parseError'] !== undefined) {
    return null
  }

  const message: string = readMessage(data['msg'])
  const rawCode: Object | undefined = data['code']
  if (rawCode === undefined || rawCode === null) {
    // HTML 错误页：`ngaRequest` 归一化为 { error: {0:...}, error_code }，没有 code/msg
    const rawErrorCode: Object | undefined = data['error_code']
    if (rawErrorCode !== undefined && rawErrorCode !== null) {
      const errorCode: number = Number(rawErrorCode)
      if (errorCode === 11 || errorCode === 12) {
        const errorMessage: string = readMessage(data['error'])
        return errorMessage.length > 0 ? errorMessage : '未登录'
      }
    }
    return isSessionMessage(message) ? message : null
  }

  const code: number = Number(rawCode)
  if (code === 12) {
    return message.length > 0 ? message : '未登录'
  }
  if (code === 2048) {
    return message.indexOf('登录') >= 0 ? message : null
  }
  if (code === 1) {
    return isSessionMessage(message) ? message : null
  }
  return null
}

/**
 * 判断文案是否为会话类措辞（服务端可能换皮，按关键词匹配）。
 *
 * @param message - 服务端文案
 * @returns 是否为"未登录/会话失效"类文案
 */
function isSessionMessage(message: string): boolean {
  if (message.length === 0) {
    return false
  }
  if (message.indexOf('未登录') >= 0 || message.indexOf('尚未登录') >= 0) {
    return true
  }
  if (message.indexOf('必须先登录') >= 0 || message.indexOf('你没有登录') >= 0) {
    return true
  }
  if (message.indexOf('SESSION TIMEOUT') >= 0) {
    return true
  }
  // 大小写不敏感：官方文案是"token错误"，服务端换皮成"Token错误"同样要识别
  return message.toLowerCase().indexOf('token') >= 0 && message.indexOf('错误') >= 0
}

/**
 * 把 `login/iflogin` 的响应归一成三态结论。
 *
 * - `code == 0` 且 `result.uid` 与本地 uid 一致 → VALID
 * - `code == 0` 但 `result.uid` 属于另一个账号 → INVALID（凭证错配）
 * - `code == 12`（未登录）→ INVALID
 * - `code == 1` 且文案为会话类（SESSION TIMEOUT OR FAIL 等）→ INVALID；
 *   文案不是会话类（如"ACTION NOT FOUND"）→ UNKNOWN（不能因通用业务失败登出）
 * - 其它（无 code、解析失败、频率限制、签名错误、uid 为空）→ UNKNOWN
 *
 * @param raw - iflogin 响应对象
 * @param expectedUid - 本地会话的 uid
 * @returns 归一化结果
 */
export function verdictFromIfloginResponse(raw: object, expectedUid: string): SessionCheckResult {
  const result: SessionCheckResult = new SessionCheckResult()
  if (raw === null || raw === undefined) {
    return result
  }
  const data: Record<string, Object> = raw as Record<string, Object>
  if (data['__parseError'] !== undefined) {
    return result
  }
  result.message = readMessage(data['msg'])

  const rawCode: Object | undefined = data['code']
  if (rawCode === undefined || rawCode === null) {
    // 无业务码（HTML 错误页 / 维护页）：无法判定，交给 UNKNOWN
    return result
  }

  const code: number = Number(rawCode)
  if (code === 0) {
    const user: Record<string, Object> | null = extractAppUser(raw)
    const uid: string = user !== null ? String(user['uid'] ?? '') : ''
    result.uid = uid
    if (uid === '') {
      // code=0 但没有用户对象：响应形态异常，不据此判有效/失效
      return result
    }
    if (expectedUid.length > 0 && uid !== expectedUid) {
      result.verdict = SessionVerdict.INVALID
      result.message = 'credential belongs to another account'
      return result
    }
    result.verdict = SessionVerdict.VALID
    return result
  }

  if (code === 12) {
    result.verdict = SessionVerdict.INVALID
    return result
  }
  if (code === 1) {
    // code=1 是通用业务失败码（官方也用它表示"ACTION NOT FOUND"等），
    // 只有文案命中会话类措辞才判失效；否则保持 UNKNOWN，绝不据此登出。
    result.verdict = isSessionMessage(result.message)
      ? SessionVerdict.INVALID
      : SessionVerdict.UNKNOWN
    return result
  }
  // 频率限制（15）、签名错误（5）等与登录态无关：保持 UNKNOWN
  return result
}
