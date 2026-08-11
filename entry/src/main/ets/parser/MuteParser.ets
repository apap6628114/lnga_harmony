/**
 * 禁言判定工具 - 与 NGA 官方数据语义对齐。
 *
 * 两个判据（任意命中即视为禁言）：
 * 1. 用户表 mute_time：禁言到期时间戳（epoch 秒），空/0/null 为未禁言。
 *    JSON 通道（__output=8 __U）与 HTML 通道（userInfo.setAll JSON）均携带；
 * 2. 用户表 buffs：buff id 键表，105 = 禁言 buff（__output=8 JSON 通道增强，
 *    与官方 js_read.js / MNGA 客户端 MUTE_BUFF 语义一致）。
 */

/** 禁言 buff 编号（NGA 用户 buffs 键表） */
export const MUTE_BUFF_ID: string = '105'

/**
 * 判断用户是否处于禁言状态。
 *
 * @param userInfo - __U 用户表条目（may be undefined when user not in table）
 * @param fallbackMuteTime - 楼层行级 mute_time 兜底（通常为空）
 * @returns 是否禁言中
 */
export function isUserMuted(userInfo: Record<string, Object> | undefined,
  fallbackMuteTime: string = ''): boolean {
  const rawMuteTime: Object | undefined = userInfo?.['mute_time'] ?? fallbackMuteTime
  const muteTs: number = Number(rawMuteTime ?? 0)
  if (muteTs > 0) {
    return true
  }

  const buffs: Object | undefined = userInfo?.['buffs']
  if (buffs && typeof buffs === 'object') {
    return Object.keys(buffs as Record<string, Object>).includes(MUTE_BUFF_ID)
  }
  return false
}
