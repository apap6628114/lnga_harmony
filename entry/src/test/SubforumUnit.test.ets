import { describe, it, expect } from '@ohos/hypium'
import { parseSubjectSubBoards } from '../main/ets/parser/AppSubjectListParser'
import type { SubBoard } from '../main/ets/model/Forum'

/**
 * 创建包含官方 subject/list subForum 数组的响应 result 对象。
 *
 * subForum 元素为「位置字段 + 命名键」双格式，checked=账号级真实订阅状态、
 * allow_checked=是否允许订阅。
 *
 * @returns NGA subject/list 响应 result 对象
 */
function createSubjectSubForumResult(): Record<string, Object> {
  const selectedSub: Record<string, Object> = {
    '0': 310,
    '1': '已显示子版块',
    '2': '普通子版块',
    '3': 19115466,
    '4': 558,
    'id': 310,
    'name': '已显示子版块',
    'info': '普通子版块',
    'checked': 1,
    'allow_checked': 1,
    'sub_type': 558,
    'tid': 19115466,
  }
  const blockedSub: Record<string, Object> = {
    '0': 12700430,
    '1': '已屏蔽分区',
    '2': '专题分区',
    '3': 12700430,
    '4': 41,
    'id': 12700430,
    'name': '已屏蔽分区',
    'info': '专题分区',
    'checked': 0,
    'allow_checked': 1,
    'sub_type': 41,
    'tid': 12700430,
  }
  const fixedSub: Record<string, Object> = {
    '0': 12700431,
    '1': '固定分区',
    '2': '',
    '3': 12700431,
    '4': 7,
    'id': 12700431,
    'name': '固定分区',
    'info': '',
    'checked': 1,
    'allow_checked': 0,
    'sub_type': 7,
    'tid': 12700431,
  }
  const subArr: Object[] = [selectedSub, blockedSub, fixedSub]
  const result: Record<string, Object> = {
    'subForum': subArr,
  }
  return result
}

/**
 * 注册子版块解析单元测试。
 */
export default function subforumUnitTest(): void {
  describe('SubforumUnit', () => {
    it('parsesOfficialSubForum', 0, () => {
      const parsed: SubBoard[] = parseSubjectSubBoards(createSubjectSubForumResult())
      expect(parsed.length).assertEqual(3)

      /* 已订阅子版块：checked=1（真实账号状态）、allow_checked=1 可屏蔽 */
      const selected = parsed[0]
      expect(selected.fid).assertEqual(310)
      expect(selected.stid).assertEqual(0)
      expect(selected.name).assertEqual('已显示子版块')
      expect(selected.description).assertEqual('普通子版块')
      expect(selected.tidStr).assertEqual('19115466')
      expect(selected.filterId).assertEqual('19115466')
      expect(selected.type).assertEqual(558)
      expect(selected.attributes).assertEqual(558)
      expect(selected.checked).assertTrue()
      expect(selected.filterable).assertTrue()

      /* 未订阅子版块：checked=0（主题已被服务端排除混合），仍可订阅 */
      const blocked = parsed[1]
      expect(blocked.fid).assertEqual(12700430)
      expect(blocked.stid).assertEqual(0)
      expect(blocked.checked).assertFalse()
      expect(blocked.filterable).assertTrue()

      /* 固定分区：allow_checked=0 → 不允许订阅，UI 禁用开关 */
      const fixed = parsed[2]
      expect(fixed.fid).assertEqual(12700431)
      expect(fixed.checked).assertTrue()
      expect(fixed.filterable).assertFalse()
      expect(fixed.description).assertEqual('')
    })

    it('skipsInvalidSubForumEntries', 0, () => {
      /* 缺关键字段的元素被跳过 */
      const broken: Record<string, Object> = {
        '0': 999,
        'name': '缺 tid 的条目',
      }
      const subArr: Object[] = [broken]
      const result: Record<string, Object> = {
        'subForum': subArr,
      }
      const parsed: SubBoard[] = parseSubjectSubBoards(result)
      expect(parsed.length).assertEqual(0)
    })

    it('returnsEmptyWhenMissing', 0, () => {
      /* 无 subForum 字段 / 非数组 / result 缺失 → 空列表 */
      const noField: Record<string, Object> = {
        'data': [],
      }
      expect(parseSubjectSubBoards(noField).length).assertEqual(0)
      expect(parseSubjectSubBoards(undefined).length).assertEqual(0)
    })
  })
}
