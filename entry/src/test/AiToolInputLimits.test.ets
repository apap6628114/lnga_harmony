import { describe, it, expect } from '@ohos/hypium'
import {
  MAX_WEB_SEARCH_QUERY_CODE_POINTS,
  NGA_SEARCH_KEY_MAX_GBK_BYTES,
  LimitedText,
  containsNonAscii,
  gbkByteLength,
  truncateToCodePoints,
  truncateToGbkBytes
} from '../main/ets/service/ai/tools/ToolInputLimits'
import { AiToolContext } from '../main/ets/service/ai/tools/AiToolAdapter'
import { WebSearchTool } from '../main/ets/service/ai/tools/WebSearchTool'
import { WebFetchTool } from '../main/ets/service/ai/tools/WebFetchTool'
import { NgaSearchTopicsTool, NgaListTopicsTool } from '../main/ets/service/ai/tools/nga/NgaTopicTools'
import { NgaSearchForumTool } from '../main/ets/service/ai/tools/nga/NgaForumTools'
import { NgaReadThreadTool } from '../main/ets/service/ai/tools/nga/NgaThreadTools'
import { NgaSearchUserTool } from '../main/ets/service/ai/tools/nga/NgaUserTools'
import type { AiToolDefinition } from '../main/ets/service/ai/AiProtocolTypes'

/** 重复拼接单元串。 */
function repeatUnit(unit: string, times: number): string {
  let text: string = ''
  for (let i: number = 0; i < times; i++) {
    text += unit
  }
  return text
}

/**
 * 读取工具定义中某个参数 description。
 *
 * @param definition - 工具定义
 * @param name - 参数名
 * @returns 参数说明
 */
function readPropertyDescription(definition: AiToolDefinition, name: string): string {
  const parameters: Record<string, Object> = definition.parameters
  const properties: Record<string, Object> = parameters['properties'] as Record<string, Object>
  const prop: Record<string, Object> = properties[name] as Record<string, Object>
  return prop['description'] as string
}

/**
 * 工具输入长度约束回归测试。
 *
 * 覆盖两类服务端硬限制（见 ToolInputLimits 文件头）：
 * - DeepSeek Search API：query 1~128 个 Unicode 字符；
 * - NGA 主题搜索：key GBK 编码 ≤ 149 字节（74 汉字 / 149 ASCII）。
 *
 * 同时校验工具 Schema 把上限写进了 description——模型看不到常量，
 * 只能从描述里知道约束，漏写等于约束不存在。
 */
export default function aiToolInputLimitsTest(): void {
  describe('aiToolInputLimits', (): void => {
    it('countsGbkBytesForAsciiAndChinese', 0, (): void => {
      expect(gbkByteLength('')).assertEqual(0)
      expect(gbkByteLength('warcraft')).assertEqual(8)
      expect(gbkByteLength('魔兽世界')).assertEqual(8)
      expect(gbkByteLength('warcraft魔兽')).assertEqual(12)
    })

    it('countsEmojiAsFourGbkBytes', 0, (): void => {
      // GBK 无法表示 emoji：按 4 字节保守计，宁可早截断
      expect(gbkByteLength('\uD83D\uDE00')).assertEqual(4)
    })

    it('keepsKeyAtOrBelow149GbkBytes', 0, (): void => {
      const ok: string = repeatUnit('魔兽', 37) // 74 汉字 = 148 字节
      const kept: LimitedText = truncateToGbkBytes(ok, NGA_SEARCH_KEY_MAX_GBK_BYTES)
      expect(gbkByteLength(ok)).assertEqual(148)
      expect(kept.truncated).assertFalse()
      expect(kept.text).assertEqual(ok)
    })

    it('truncatesChineseKeyAbove149GbkBytes', 0, (): void => {
      const tooLong: string = repeatUnit('魔兽', 37) + '魔' // 75 汉字 = 150 字节
      const cut: LimitedText = truncateToGbkBytes(tooLong, NGA_SEARCH_KEY_MAX_GBK_BYTES)
      expect(cut.truncated).assertTrue()
      expect(cut.text.length).assertEqual(74)
      expect(gbkByteLength(cut.text) <= NGA_SEARCH_KEY_MAX_GBK_BYTES).assertTrue()
    })

    it('truncatesAsciiKeyAt149Bytes', 0, (): void => {
      const exactly: string = repeatUnit('a', 149)
      expect(truncateToGbkBytes(exactly, NGA_SEARCH_KEY_MAX_GBK_BYTES).truncated).assertFalse()
      const over: string = repeatUnit('a', 150)
      const cut: LimitedText = truncateToGbkBytes(over, NGA_SEARCH_KEY_MAX_GBK_BYTES)
      expect(cut.truncated).assertTrue()
      expect(cut.text.length).assertEqual(149)
    })

    it('doesNotSplitProxyPairWhenTruncatingByCodePoints', 0, (): void => {
      const emoji: string = '\uD83D\uDE00'
      const exact: string = repeatUnit('a', 127) + emoji // 128 码点，129 个 UTF-16 单元
      const kept: LimitedText = truncateToCodePoints(exact, MAX_WEB_SEARCH_QUERY_CODE_POINTS)
      expect(kept.truncated).assertFalse()
      expect(kept.text.length).assertEqual(129)

      const over: string = exact + emoji // 129 码点
      const cut: LimitedText = truncateToCodePoints(over, MAX_WEB_SEARCH_QUERY_CODE_POINTS)
      expect(cut.truncated).assertTrue()
      expect(cut.text.length).assertEqual(129)
      expect(cut.text.endsWith(emoji)).assertTrue()
    })

    it('detectsNonAsciiKeywords', 0, (): void => {
      expect(containsNonAscii('warcraft')).assertFalse()
      expect(containsNonAscii('warcraft wow')).assertFalse()
      expect(containsNonAscii('魔兽')).assertTrue()
      expect(containsNonAscii('warcraft 魔兽')).assertTrue()
    })

    it('webSearchSchemaDeclaresCodePointLimit', 0, (): void => {
      const definition: AiToolDefinition = new WebSearchTool().getDefinition(new AiToolContext())
      expect(readPropertyDescription(definition, 'query').indexOf('128') >= 0).assertTrue()
    })

    it('ngaSearchTopicsSchemaDeclaresGbkLimit', 0, (): void => {
      const definition: AiToolDefinition =
        new NgaSearchTopicsTool().getDefinition(new AiToolContext())
      expect(readPropertyDescription(definition, 'key').indexOf('149') >= 0).assertTrue()
    })

    it('ngaSearchForumSchemaWarnsAboutChineseKeyword', 0, (): void => {
      const definition: AiToolDefinition =
        new NgaSearchForumTool().getDefinition(new AiToolContext())
      expect(definition.description.indexOf('英文') >= 0).assertTrue()
      expect(readPropertyDescription(definition, 'key').indexOf('nga_list_forums') >= 0).assertTrue()
    })

    it('readThreadDeclaresFloorAndCharLimits', 0, (): void => {
      const definition: AiToolDefinition =
        new NgaReadThreadTool().getDefinition(new AiToolContext())
      /** 实现里 max_chars 被裁到 500-20000，声明必须让模型知道上限 */
      expect(readPropertyDescription(definition, 'max_chars').indexOf('20000') >= 0).assertTrue()
      /** 只给 pid 会失败：必须声明 pid 依赖 tid */
      expect(readPropertyDescription(definition, 'pid').indexOf('tid') >= 0).assertTrue()
      /** 单页约 20 楼，max_floors 不能跨页 */
      expect(readPropertyDescription(definition, 'max_floors').indexOf('跨页') >= 0).assertTrue()
    })

    it('webFetchDeclaresContentTruncation', 0, (): void => {
      const definition: AiToolDefinition = new WebFetchTool().getDefinition(new AiToolContext())
      expect(definition.description.indexOf('12000') >= 0).assertTrue()
    })

    it('searchUserDoesNotDeclareUnusedLimit', 0, (): void => {
      /** 用户搜索是精确匹配、最多 1 条，声明 limit 属于虚假能力 */
      const definition: AiToolDefinition =
        new NgaSearchUserTool().getDefinition(new AiToolContext())
      const properties: Record<string, Object> =
        definition.parameters['properties'] as Record<string, Object>
      expect(Object.keys(properties).indexOf('limit') < 0).assertTrue()
    })

    it('listTopicsDeclaresHotWindow', 0, (): void => {
      const definition: AiToolDefinition =
        new NgaListTopicsTool().getDefinition(new AiToolContext())
      expect(readPropertyDescription(definition, 'sort').indexOf('7') >= 0).assertTrue()
    })
  })
}
