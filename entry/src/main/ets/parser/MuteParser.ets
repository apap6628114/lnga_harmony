/**
 * 禁言判定工具 - 与 NGA 官方数据语义对齐。
 *
 * 两个判据（任意命中即视为禁言）：
 * 1. 用户表 mute_time：禁言到期时间戳（epoch 秒），空/0/null 为未禁言。
 *    JSON 通道（__output=8 __U）与 HTML 通道（userInfo.setAll JSON）均携带；
 * 2. 用户表 buffs：buff id 键表，105 = 禁言 buff（__output=8 JSON 通道增强，
 *    与官方 js_read.js / MNGA 客户端 MUTE_BUFF 语义一致）。
 */

import { formatTimestampCST } from '../common/utils/Utils'

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

/**
 * 判断字符串形式的禁言到期时间是否有效（epoch 秒时间戳）。
 * 用于私信详情等仅有 mute_time 字符串的场景（'' / '0' / 非法串均视为未禁言）。
 *
 * @param muteTime - 禁言到期时间戳字符串（NGA mute_time 字段）
 * @returns 是否禁言中
 */
export function isMutedByMuteTime(muteTime: string): boolean {
  return Number(muteTime) > 0
}

/**
 * 取有效禁言到期时间戳。
 * ucp 接口的 maxBuffMute 为 buff 类禁言（105）到期时间戳，
 * muteTime 为旧字段（仅反映历史 mute_time，对 buff 禁言恒为 0）——优先 maxBuffMute。
 *
 * @param legacyMuteTime - 旧字段 muteTime（epoch 秒，0 表示未禁言）
 * @param buffMute - buff 类禁言到期时间戳 maxBuffMute（epoch 秒，0 表示无）
 * @returns 有效禁言到期时间戳；未禁言时返回 0
 */
export function resolveEffectiveMuteTs(legacyMuteTime: number, buffMute: number): number {
  if (buffMute > 0) {
    return buffMute
  }
  return legacyMuteTime
}

/**
 * 归一化禁言到期时间的展示格式。
 * 兼容本地持久化缓存中的旧格式：早期版本用 toISOString() 写入 UTC 时间
 * （"2026-08-13T12:15"），新版本为 formatTimestampCST 的本地时间
 * （"2026-08-13 20:15"）——旧格式统一转换为本地时间后展示。
 *
 * @param rawMuteTime - 缓存中的禁言到期时间字符串
 * @returns 本地时间展示串（"YYYY-MM-DD HH:mm"）；空串原样返回
 */
export function normalizeMuteTimeDisplay(rawMuteTime: string): string {
  if (rawMuteTime.length === 0) {
    return ''
  }
  if (rawMuteTime.includes('T')) {
    const ms: number = new Date(rawMuteTime).getTime()
    if (isNaN(ms)) {
      return rawMuteTime
    }
    return formatTimestampCST(ms / 1000)
  }
  return rawMuteTime
}
