import { describe, it, expect } from '@ohos/hypium'
import {
  READ_BASELINE_UNKNOWN,
  READ_BASELINE_UNREAD,
  TopicReadState,
  isTopicRead,
  resolveTopicReadState,
  topicUpdateDelta
} from '../main/ets/common/utils/TopicReadPolicy'

/**
 * 注册主题列表「已读 / 有新回复」判定的回归测试。
 *
 * 保护的行为：列表行三态（没看过 / 看过 / 看过后有更新）的判定口径，以及底栏「+x」
 * 增量（= 上次进帖时与现在的回复数差）——核心契约是「只看回复数增加」与
 * 「基线未知时不误报」（见 TopicReadPolicy 文件头）。
 */
export default function topicReadUnitTest(): void {
  describe('topicReadState', (): void => {
    it('treatsUnreadBaselineAsNeverOpened', 0, (): void => {
      const state: TopicReadState = resolveTopicReadState(READ_BASELINE_UNREAD, 128)

      expect(state).assertEqual(TopicReadState.UNREAD)
      expect(isTopicRead(state)).assertFalse()
      expect(topicUpdateDelta(READ_BASELINE_UNREAD, 128)).assertEqual(0)
    })

    it('keepsReadStateAndShowsNoDeltaWhenReplyCountUnchanged', 0, (): void => {
      const state: TopicReadState = resolveTopicReadState(12, 12)

      expect(state).assertEqual(TopicReadState.READ)
      expect(isTopicRead(state)).assertTrue()
      expect(topicUpdateDelta(12, 12)).assertEqual(0)
    })

    it('marksUpdatedAndReportsDeltaWhenReplyCountGrew', 0, (): void => {
      const state: TopicReadState = resolveTopicReadState(12, 15)

      expect(state).assertEqual(TopicReadState.UPDATED)
      expect(isTopicRead(state)).assertTrue()
      expect(topicUpdateDelta(12, 15)).assertEqual(3)
    })

    it('reportsDeltaWhenFirstReplyArrivesOnZeroReplyThread', 0, (): void => {
      const state: TopicReadState = resolveTopicReadState(0, 1)

      expect(state).assertEqual(TopicReadState.UPDATED)
      expect(topicUpdateDelta(0, 1)).assertEqual(1)
    })

    it('reportsNoDeltaWhenRepliesDeleted', 0, (): void => {
      const state: TopicReadState = resolveTopicReadState(12, 9)

      expect(state).assertEqual(TopicReadState.READ)
      expect(topicUpdateDelta(12, 9)).assertEqual(0)
    })

    it('reportsNoDeltaWhenBaselineUnknown', 0, (): void => {
      const state: TopicReadState = resolveTopicReadState(READ_BASELINE_UNKNOWN, 999)

      expect(state).assertEqual(TopicReadState.READ)
      expect(isTopicRead(state)).assertTrue()
      expect(topicUpdateDelta(READ_BASELINE_UNKNOWN, 999)).assertEqual(0)
    })

    it('treatsMissingOrIllegalCurrentRepliesAsZero', 0, (): void => {
      const missing: TopicReadState = resolveTopicReadState(3, Number.NaN)
      const negative: TopicReadState = resolveTopicReadState(3, -5)

      expect(missing).assertEqual(TopicReadState.READ)
      expect(negative).assertEqual(TopicReadState.READ)
      expect(topicUpdateDelta(3, Number.NaN)).assertEqual(0)
      expect(topicUpdateDelta(3, -5)).assertEqual(0)
    })

    it('keepsDeltaUncappedForLargeGrowth', 0, (): void => {
      expect(topicUpdateDelta(20, 340)).assertEqual(320)
    })
  })
}
