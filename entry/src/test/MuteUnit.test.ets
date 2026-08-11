import { describe, it, expect } from '@ohos/hypium'
import {
  isUserMuted, isMutedByMuteTime, resolveEffectiveMuteTs, normalizeMuteTimeDisplay,
} from '../main/ets/parser/MuteParser'

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

  describe('isMutedByMuteTime', (): void => {
    it('mutedWhenTimestampString', 0, (): void => {
      expect(isMutedByMuteTime('1786623325')).assertTrue()
    })

    it('notMutedWhenEmptyOrZeroOrInvalid', 0, (): void => {
      expect(isMutedByMuteTime('')).assertFalse()
      expect(isMutedByMuteTime('0')).assertFalse()
      expect(isMutedByMuteTime('abc')).assertFalse()
    })
  })

  describe('resolveEffectiveMuteTs', (): void => {
    it('prefersBuffMuteWhenBothPresent', 0, (): void => {
      expect(resolveEffectiveMuteTs(0, 1786623325)).assertEqual(1786623325)
      expect(resolveEffectiveMuteTs(1700000000, 1786623325)).assertEqual(1786623325)
    })

    it('fallsBackToLegacyMuteTime', 0, (): void => {
      expect(resolveEffectiveMuteTs(1700000000, 0)).assertEqual(1700000000)
    })

    it('returnsZeroWhenNotMuted', 0, (): void => {
      expect(resolveEffectiveMuteTs(0, 0)).assertEqual(0)
    })
  })

  describe('normalizeMuteTimeDisplay', (): void => {
    it('keepsNewLocalFormat', 0, (): void => {
      expect(normalizeMuteTimeDisplay('2026-08-13 20:15')).assertEqual('2026-08-13 20:15')
    })

    it('convertsLegacyUtcIsoFormatToLocalShape', 0, (): void => {
      const result: string = normalizeMuteTimeDisplay('2026-08-13T12:15')
      expect(result.includes('T')).assertFalse()
      const shape: RegExp = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/
      expect(shape.test(result)).assertTrue()
    })

    it('returnsEmptyForEmptyInput', 0, (): void => {
      expect(normalizeMuteTimeDisplay('')).assertEqual('')
    })
  })
}
