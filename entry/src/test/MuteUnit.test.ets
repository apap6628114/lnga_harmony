import { describe, it, expect } from '@ohos/hypium'
import { isUserMuted } from '../main/ets/parser/MuteParser'

/**
 * 禁言判定工具单元测试。
 * 判据：__U 用户表 mute_time 时间戳 > 0，或 buffs 键表含 105（禁言 buff）。
 */
export default function muteUnitTest(): void {
  describe('isUserMuted', (): void => {
    it('mutedWhenMuteTimeIsTimestamp', 0, (): void => {
      const user: Record<string, Object> =
        JSON.parse('{"mute_time":"1786457254"}') as Record<string, Object>
      expect(isUserMuted(user)).assertTrue()
    })

    it('mutedWhenMuteTimeIsNumericTimestamp', 0, (): void => {
      const user: Record<string, Object> =
        JSON.parse('{"mute_time":1786457254}') as Record<string, Object>
      expect(isUserMuted(user)).assertTrue()
    })

    it('notMutedWhenMuteTimeEmpty', 0, (): void => {
      const user: Record<string, Object> =
        JSON.parse('{"mute_time":""}') as Record<string, Object>
      expect(isUserMuted(user)).assertFalse()
    })

    it('notMutedWhenMuteTimeNull', 0, (): void => {
      const user: Record<string, Object> =
        JSON.parse('{"mute_time":null}') as Record<string, Object>
      expect(isUserMuted(user)).assertFalse()
    })

    it('notMutedWhenMuteTimeZero', 0, (): void => {
      const user: Record<string, Object> =
        JSON.parse('{"mute_time":0}') as Record<string, Object>
      expect(isUserMuted(user)).assertFalse()
    })

    it('mutedWhenBuffsContains105', 0, (): void => {
      const user: Record<string, Object> =
        JSON.parse('{"mute_time":"","buffs":{"105":{"0":{"0":1,"1":105}}}}') as Record<string, Object>
      expect(isUserMuted(user)).assertTrue()
    })

    it('notMutedWhenBuffsContainsOtherBuffs', 0, (): void => {
      const user: Record<string, Object> =
        JSON.parse('{"mute_time":"","buffs":{"107":{"0":{"0":1,"1":107}}}}') as Record<string, Object>
      expect(isUserMuted(user)).assertFalse()
    })

    it('mutedByMuteTimeEvenWithoutBuffs', 0, (): void => {
      const user: Record<string, Object> =
        JSON.parse('{"mute_time":"1700000000"}') as Record<string, Object>
      expect(isUserMuted(user)).assertTrue()
    })

    it('notMutedWhenUserInfoMissing', 0, (): void => {
      let noUser: Record<string, Object> | undefined = undefined
      expect(isUserMuted(noUser)).assertFalse()
    })

    it('notMutedWhenUserInfoEmpty', 0, (): void => {
      const user: Record<string, Object> = JSON.parse('{}') as Record<string, Object>
      expect(isUserMuted(user)).assertFalse()
    })

    it('fallsBackToRowMuteTime', 0, (): void => {
      let noUser: Record<string, Object> | undefined = undefined
      expect(isUserMuted(noUser, '1786457254')).assertTrue()
      expect(isUserMuted(noUser, '')).assertFalse()
    })

    it('emptyMuteTimeWinsOverFallback', 0, (): void => {
      const user: Record<string, Object> =
        JSON.parse('{"mute_time":""}') as Record<string, Object>
      expect(isUserMuted(user, '1786457254')).assertFalse()
    })

    it('muteTimeTakesPriorityOverNonMuteBuffs', 0, (): void => {
      const user: Record<string, Object> =
        JSON.parse('{"mute_time":"1700000000","buffs":{"107":{"0":{"0":1,"1":107}}}}') as Record<string, Object>
      expect(isUserMuted(user)).assertTrue()
    })

    it('nonNumericMuteTimeDegradesToBuffs', 0, (): void => {
      const user: Record<string, Object> =
        JSON.parse('{"mute_time":"abc","buffs":{"105":{"0":{"0":1,"1":105}}}}') as Record<string, Object>
      expect(isUserMuted(user)).assertTrue()
      const noBuffs: Record<string, Object> =
        JSON.parse('{"mute_time":"abc"}') as Record<string, Object>
      expect(isUserMuted(noBuffs)).assertFalse()
    })

    it('buffsNonObjectDegradesToMuteTime', 0, (): void => {
      const user: Record<string, Object> =
        JSON.parse('{"mute_time":"","buffs":"oops"}') as Record<string, Object>
      expect(isUserMuted(user)).assertFalse()
    })
  })
}
