import { describe, it, expect } from '@ohos/hypium'
import { parseVote, votePercent, barPercent, scoreValue } from '../main/ets/parser/VoteParser'
import { VoteInfo, VoteOption } from '../main/ets/model/Vote'

/**
 * 投票帖 vote 字段解析单元测试。
 * 样本字符串取自 tid=47344482（真实投票帖 JSON API 楼级 vote 字段）。
 */
export default function voteUnitTest(): void {
  const REAL_SAMPLE: string =
    '208214~华为~208215~美国高通~208216~弃权~max_select~1~end~1793505726~' +
    '_208214~170,0,209~_208215~11,0,0~_208216~28,0,0'

  describe('voteParser', (): void => {
    it('parsesRealVoteSampleWithCounts', 0, (): void => {
      const info: VoteInfo | null = parseVote(REAL_SAMPLE)
      expect(info !== null).assertTrue()
      if (!info) {
        return
      }
      expect(info.type).assertEqual(0)
      expect(info.maxSelect).assertEqual(1)
      expect(info.end).assertEqual(1793505726)
      expect(info.options.length).assertEqual(3)
      // 票数与官方网页渲染一致：170 / 11 / 28，总人数 209
      expect(info.options[0].title).assertEqual('华为')
      expect(info.options[0].voteNum).assertEqual(170)
      expect(info.options[1].title).assertEqual('美国高通')
      expect(info.options[1].voteNum).assertEqual(11)
      expect(info.options[2].title).assertEqual('弃权')
      expect(info.options[2].voteNum).assertEqual(28)
      expect(info.userSum).assertEqual(209)
      expect(info.voteSum).assertEqual(209)
    })

    it('supportsMultiSelectAndOptFlags', 0, (): void => {
      const info: VoteInfo | null = parseVote(
        '11~A~22~B~33~C~max_select~3~type~0~opt~1~_11~5,0,9~_22~3,0,9~_33~1,0,9')
      expect(info !== null).assertTrue()
      if (!info) {
        return
      }
      expect(info.maxSelect).assertEqual(3)
      expect(info.opt).assertEqual(1)
      expect(info.userSum).assertEqual(9)
      expect(info.voteSum).assertEqual(9)
      expect(info.options.length).assertEqual(3)
      expect(info.options[2].voteNum).assertEqual(1)
    })

    it('rejectsEmptyAndMalformedInput', 0, (): void => {
      expect(parseVote('') === null).assertTrue()
      expect(parseVote('single') === null).assertTrue()
      // 有控制键但没有选项：无实际选项时返回 null
      expect(parseVote('max_select~1') === null).assertTrue()
    })

    it('defaultsMissingKeysAndKeepsPerOptionStats', 0, (): void => {
      const info: VoteInfo | null = parseVote('7~选项一~_7~4,0,4')
      expect(info !== null).assertTrue()
      if (!info) {
        return
      }
      // type 缺省为投票、max_select 缺省为 1、end 缺省 0（不结束）
      expect(info.type).assertEqual(0)
      expect(info.maxSelect).assertEqual(1)
      expect(info.end).assertEqual(0)
      expect(info.priv).assertEqual('')
      expect(info.options.length).assertEqual(1)
      const opt: VoteOption = info.options[0]
      expect(opt.id).assertEqual('7')
      expect(opt.title).assertEqual('选项一')
      expect(opt.voteNum).assertEqual(4)
      expect(opt.scoNum).assertEqual(0)
      expect(info.userSum).assertEqual(4)
      expect(info.voteSum).assertEqual(4)
    })

    it('handlesOddTailAndStatsBeforeOptions', 0, (): void => {
      // 奇数段：尾部悬空键被忽略，不影响既有选项
      const odd: VoteInfo | null = parseVote('1~A~2~B~max_select~1~_1~3,0,5~_2~2,0,5~orphan')
      expect(odd !== null).assertTrue()
      if (!odd) {
        return
      }
      expect(odd.options.length).assertEqual(2)
      expect(odd.options[0].voteNum).assertEqual(3)
      expect(odd.userSum).assertEqual(5)
      // 统计对先于选项对出现仍正确关联
      const statFirst: VoteInfo | null = parseVote('_9~7,0,9~9~标题X~max_select~1')
      expect(statFirst !== null).assertTrue()
      if (!statFirst) {
        return
      }
      expect(statFirst.options.length).assertEqual(1)
      expect(statFirst.options[0].title).assertEqual('标题X')
      expect(statFirst.options[0].voteNum).assertEqual(7)
      expect(statFirst.userSum).assertEqual(9)
    })

    it('toleratesOrphanStatsAndBadCounts', 0, (): void => {
      // 孤儿统计（_999 无对应选项）不影响解析
      const orphan: VoteInfo | null = parseVote('3~C~_999~1,2,3~max_select~1')
      expect(orphan !== null).assertTrue()
      if (!orphan) {
        return
      }
      expect(orphan.options.length).assertEqual(1)
      expect(orphan.options[0].voteNum).assertEqual(0)
      expect(orphan.userSum).assertEqual(0)
      // 负数票数保留原值（官方 y[0]|0 同行为），NaN 归一为 0
      const bad: VoteInfo | null = parseVote('4~D~_4~-5,abc,xyz')
      expect(bad !== null).assertTrue()
      if (!bad) {
        return
      }
      expect(bad.options[0].voteNum).assertEqual(-5)
      expect(bad.userSum).assertEqual(0)
      expect(bad.voteSum).assertEqual(-5)
    })

    it('keepsLastDuplicateControlKeyAndClampsMaxSelectZero', 0, (): void => {
      // 重复 max_select 键：后值覆盖（与官方 scDe 顺序赋值一致）
      const dup: VoteInfo | null = parseVote('5~E~_5~1,0,1~max_select~2~max_select~3')
      expect(dup !== null).assertTrue()
      if (!dup) {
        return
      }
      expect(dup.maxSelect).assertEqual(3)
      // max_select~0（官方"不限"）按 1 处理（单选）
      const zero: VoteInfo | null = parseVote('6~F~_6~1,0,1~max_select~0')
      expect(zero !== null).assertTrue()
      if (!zero) {
        return
      }
      expect(zero.maxSelect).assertEqual(1)
    })

    it('parsesBetTypeWithScoNumAndControlKeys', 0, (): void => {
      // 投注帖（type=1）：scoNum 统计 + min/max/priv/done 控制键
      const bet: VoteInfo | null = parseVote(
        '101~甲~102~乙~type~1~min~10~max~100~priv~r2_~done~101~_101~30,500,50~_102~20,300,50')
      expect(bet !== null).assertTrue()
      if (!bet) {
        return
      }
      expect(bet.type).assertEqual(1)
      expect(bet.min).assertEqual(10)
      expect(bet.max).assertEqual(100)
      expect(bet.priv).assertEqual('r2_')
      expect(bet.done).assertEqual('101')
      expect(bet.options[0].scoNum).assertEqual(500)
      expect(bet.options[1].scoNum).assertEqual(300)
      expect(bet.scoSum).assertEqual(800)
      expect(bet.userSum).assertEqual(50)
    })
  })

  describe('voteMetricStats', (): void => {
    it('percentTruncatesToOneDecimal', 0, (): void => {
      // 官方 votePercentString：((x/y*1000)|0)/10 截断一位小数
      expect(votePercent(170, 209)).assertEqual(81.3)
      expect(votePercent(11, 209)).assertEqual(5.2)
      expect(votePercent(28, 209)).assertEqual(13.3)
      expect(votePercent(1, 3)).assertEqual(33.3)
      expect(votePercent(5, 0)).assertEqual(0)
    })

    it('barNormalizesTopOptionTo75Percent', 0, (): void => {
      // 最高项占比 <75% 时放大到 75% 宽度：5/10=50% → mul=0.75/0.5=1.5 → 75%
      expect(barPercent(5, 10, 5)).assertEqual(75)
      // 次高项同比例放大：3/10=30% × 1.5 = 45%
      expect(barPercent(3, 10, 5)).assertEqual(45)
      // 最高项占比 >=75% 不缩放：本样本 170/209=81.3%
      expect(barPercent(170, 209, 170)).assertEqual(81.3)
      // 边界：sum=0 安全
      expect(barPercent(1, 0, 1)).assertEqual(0)
    })

    it('scoreValueTruncatesToTwoDecimals', 0, (): void => {
      // 官方 voteScore scc：((scoNum/voteNum*100)|0)/100
      expect(scoreValue(500, 30)).assertEqual(16.66)
      expect(scoreValue(30, 10)).assertEqual(3)
      expect(scoreValue(7, 2)).assertEqual(3.5)
      expect(scoreValue(0, 0)).assertEqual(0)
    })
  })
}
