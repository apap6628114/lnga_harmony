/**
 * 会话自愈的凭据选择（纯函数，便于单测）。
 *
 * `AuthStore.recoverSession` 在「auth 有 token、sessions 里却没有对应记录」时，
 * 需要从本地仍留存的凭据里挑一组来重建会话。两条来源：
 *
 * 1. `auth` 记录里冗余的 `cid`（新格式，最可靠）；
 * 2. `sessions` 表里**同一 uid** 的其它会话（旧格式升级、token 换代残留）。
 *
 * 关键安全约束：**uid 为空时绝不从 sessions 里"随便挑一个"**。那等于用别人的
 * 凭据重建登录态，会把用户 A 的 token 指向用户 B 的账号（手工改过 preferences、
 * 迁移异常时都可能出现）。宁可判未登录回登录页，也不做无 uid 的 fallback。
 */

import type { Session } from './SessionRegistry'

/** 会话自愈选出的凭据。 */
export class RecoveryCredential {
  /** NGA uid。 */
  uid: string = ''
  /** NGA cid。 */
  cid: string = ''
}

/**
 * 选出可用于重建会话的凭据。
 *
 * @param authUid - `auth` 记录里的 uid（当前账号）
 * @param authCid - `auth` 记录里冗余的 cid（可能为空：旧格式）
 * @param sessions - 本地仍留存的全部会话
 * @returns 可用凭据；无法安全确定时返回 null
 */
export function selectRecoveryCredential(authUid: string, authCid: string,
  sessions: Session[]): RecoveryCredential | null {
  if (authUid.length === 0) {
    return null
  }
  if (authCid.length > 0) {
    const direct: RecoveryCredential = new RecoveryCredential()
    direct.uid = authUid
    direct.cid = authCid
    return direct
  }
  for (let i = 0; i < sessions.length; i++) {
    const candidate: Session = sessions[i]
    if (candidate.uid === authUid && candidate.cid.length > 0) {
      const matched: RecoveryCredential = new RecoveryCredential()
      matched.uid = authUid
      matched.cid = candidate.cid
      return matched
    }
  }
  return null
}
