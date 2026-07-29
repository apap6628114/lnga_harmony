import { describe, it, expect } from '@ohos/hypium'
import { parseTopicList } from '../main/ets/parser/TopicParser'
import type { TopicListInfo } from '../main/ets/model/Topic'

/**
 * 创建包含 MNGA 位置字段格式子版块的主题列表响应。
 *
 * @returns NGA 主题列表响应
 */
function createSubforumResponse(): Record<string, Object> {
  const selectedFid: Record<string, Object> = {
    '0': '310',
    '1': '已显示子版块',
    '2': '普通子版块',
    '3': '19115466',
    '4': 558,
  }
  const blockedStid: Record<string, Object> = {
    '0': '12700430',
    '1': '已屏蔽分区',
    '2': '专题分区',
    '3': '12700430',
    '4': 41,
  }
  const fixedStid: Record<string, Object> = {
    '0': '12700431',
    '1': '固定分区',
    '2': '',
    '3': '12700431',
    '4': 7,
  }
  const subForums: Record<string, Object> = {
    'item': [selectedFid],
    'special': [blockedStid, fixedStid],
  }
  const forum: Record<string, Object> = {
    'name': '父版块',
    'sub_forums': subForums,
  }
  const data: Record<string, Object> = {
    '__T': {},
    '__ROWS': 0,
    '__T__ROWS_PAGE': 35,
    '__F': forum,
  }
  return {
    'data': data,
    'time': 100,
  }
}

/**
 * 注册子版块解析单元测试。
 */
export default function subforumUnitTest(): void {
  describe('SubforumUnit', () => {
    it('parsesMngaSubforumFields', 0, () => {
      const parsed: TopicListInfo = parseTopicList(createSubforumResponse())
      expect(parsed.subBoardList.length).assertEqual(3)

      const selected = parsed.subBoardList[0]
      expect(selected.fid).assertEqual(310)
      expect(selected.stid).assertEqual(0)
      expect(selected.filterId).assertEqual('19115466')
      expect(selected.attributes).assertEqual(558)
      expect(selected.filterable).assertTrue()
      expect(selected.checked).assertTrue()

      const blocked = parsed.subBoardList[1]
      expect(blocked.fid).assertEqual(0)
      expect(blocked.stid).assertEqual(12700430)
      expect(blocked.filterable).assertTrue()
      expect(blocked.checked).assertFalse()

      const fixed = parsed.subBoardList[2]
      expect(fixed.filterable).assertFalse()
      expect(fixed.checked).assertTrue()
    })
  })
}
