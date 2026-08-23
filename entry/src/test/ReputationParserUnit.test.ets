import { describe, expect, it } from '@ohos/hypium'
import { parseReputationList } from '../main/ets/parser/ReputationParser'

/**
 * 多版面声望（ucp.get reputation，APP 签名通道 __output=12）解析单元测试。
 *
 * 覆盖 APP 接口数组形态，以及缺失/异常输入兜底与 NaN 回归。
 */
export default function reputationParserUnitTest(): void {
  describe('reputationParser', (): void => {
    it('parsesAppArrayForm', 0, (): void => {
      const raw: object = JSON.parse('{"reputation":[["N币",181,"用于N币商店兑换,作货币使用"]]}')
      const rep = (raw as Record<string, Object>)['reputation']
      const list = parseReputationList(rep)
      expect(list.length).assertEqual(1)
      expect(list[0].name).assertEqual('N币')
      expect(list[0].value).assertEqual('181')
      expect(list[0].reputation).assertEqual(181)
      expect(list[0].desc).assertEqual('用于N币商店兑换,作货币使用')
    })

    it('parsesMultipleEntries', 0, (): void => {
      const raw: object = JSON.parse('{"reputation":[["N币",181,"描述A"],["声望X",-5,"描述B"]]}')
      const rep = (raw as Record<string, Object>)['reputation']
      const list = parseReputationList(rep)
      expect(list.length).assertEqual(2)
      expect(list[1].name).assertEqual('声望X')
      expect(list[1].reputation).assertEqual(-5)
    })

    it('returnsEmptyWhenMissingOrInvalid', 0, (): void => {
      expect(parseReputationList(undefined).length).assertEqual(0)
      expect(parseReputationList('28_15,-7_285' as Object).length).assertEqual(0)
    })

    it('toleratesPartialTuple', 0, (): void => {
      /* 三元组元素缺失：仅名称 / 名称+数值，其余字段兜底 */
      const raw: object = JSON.parse('{"reputation":[["N币"],["声望X",181]]}')
      const rep = (raw as Record<string, Object>)['reputation']
      const list = parseReputationList(rep)
      expect(list.length).assertEqual(2)
      expect(list[0].name).assertEqual('N币')
      expect(list[0].value).assertEqual('')
      expect(list[0].desc).assertEqual('')
      expect(list[0].reputation).assertEqual(0)
      expect(list[1].name).assertEqual('声望X')
      expect(list[1].reputation).assertEqual(181)
    })

    it('skipsNonArrayEntries', 0, (): void => {
      /* 非三元组容器（如网页对象形态条目或扁平数组）一律跳过 */
      const raw: object = JSON.parse('{"reputation":{"0":{"0":"N币","1":180,"2":"描述"},"1":["声望X",-5,"描述B"]}}')
      const rep = (raw as Record<string, Object>)['reputation']
      const list = parseReputationList(rep)
      expect(list.length).assertEqual(1)
      expect(list[0].name).assertEqual('声望X')
    })

    it('neverProducesNaN', 0, (): void => {
      /* 回归：早期按 7 元素错位解析时，描述字符串被 Number() 成 NaN */
      const raw: object = JSON.parse('{"reputation":[["N币",181,"用于N币商店兑换,作货币使用"]]}')
      const rep = (raw as Record<string, Object>)['reputation']
      const list = parseReputationList(rep)
      expect(Number.isNaN(list[0].reputation)).assertFalse()
    })

    it('sanitizesNonNumericValueToZero', 0, (): void => {
      /* value 为垃圾串时 reputation 归零，不产生 NaN */
      const raw: object = JSON.parse('{"reputation":[["N币","abc","描述"]]}')
      const rep = (raw as Record<string, Object>)['reputation']
      const list = parseReputationList(rep)
      expect(list[0].value).assertEqual('abc')
      expect(list[0].reputation).assertEqual(0)
      expect(Number.isNaN(list[0].reputation)).assertFalse()
    })
  })
}
