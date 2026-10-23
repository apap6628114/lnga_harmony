import { describe, it, expect } from '@ohos/hypium'
import {
  ToolResultArchive,
  ToolArchiveSlice,
  ARCHIVE_DEFAULT_READ_CHARS
} from '../main/ets/service/ai/tools/ToolResultArchive'
import {
  ContextUsage,
  ToolContentFit,
  estimateToolDefinitionsTokens,
  fitToolResultContent,
  isContextOverflowError,
  resolveCalibratedBudget
} from '../main/ets/service/ai/ContextBudget'
import { AiToolContext, AiToolResult } from '../main/ets/service/ai/tools/AiToolAdapter'
import { ToolResultCache } from '../main/ets/service/ai/tools/ToolResultCache'
import { aiToolRegistry } from '../main/ets/service/ai/tools/ToolRegistry'
import { AiToolSettings } from '../main/ets/model/AiToolConfig'
import { AiToolDefinition } from '../main/ets/service/ai/AiProtocolTypes'
import { AiAgentPreset, presetAllowsTool } from '../main/ets/model/AiAgentPreset'
import { resolveSummaryInputLimit } from '../main/ets/service/ai/ContextSummarizer'

/**
 * 上下文续读 / 超窗识别 / 估算口径的回归测试。
 *
 * 覆盖的都是"不报错但会静默丢信息"的路径：
 * 1. 工具结果被预算截断后，模型必须能按 result_id 取回后半段；
 * 2. 超窗识别只能命中真正的 context overflow，不能把普通 400 也当成超窗；
 * 3. 工具 schema 必须计入预算，否则水位永远偏乐观；
 * 4. 元工具不受任务白名单限制，否则截断恢复通道会被用户的任务配置关死。
 */
export default function aiContextArchiveTest(): void {
  describe('toolResultArchive', (): void => {
    it('archivesAndReadsByOffset', 0, (): void => {
      const archive: ToolResultArchive = new ToolResultArchive()
      const content: string = '第一段内容'.repeat(20)
      const id: string = archive.put('nga_read_thread', content)
      expect(id.length > 0).assertTrue()
      expect(archive.size()).assertEqual(1)

      const head: ToolArchiveSlice | null = archive.read(id, 0, 10)
      expect(head !== null).assertTrue()
      if (head === null) {
        return
      }
      expect(head.text).assertEqual(content.substring(0, 10))
      expect(head.totalChars).assertEqual(content.length)
      expect(head.hasMore).assertTrue()
      expect(head.offset).assertEqual(0)
      expect(head.nextOffset).assertEqual(10)

      const tail: ToolArchiveSlice | null = archive.read(id, content.length - 5, 100)
      expect(tail !== null).assertTrue()
      if (tail === null) {
        return
      }
      expect(tail.text).assertEqual(content.substring(content.length - 5))
      expect(tail.hasMore).assertFalse()
    })

    it('doesNotSplitSurrogatePair', 0, (): void => {
      const archive: ToolResultArchive = new ToolResultArchive()
      /* emoji 是代理对：按 UTF-16 码元切会把一个字符劈成两半，产生非法文本 */
      const content: string = 'a😀b😀c'
      const id: string = archive.put('web_fetch', content)
      for (let offset: number = 0; offset < content.length; offset++) {
        const slice: ToolArchiveSlice | null = archive.read(id, offset, 1)
        expect(slice !== null).assertTrue()
        if (slice === null) {
          continue
        }
        const text: string = slice.text
        if (text.length === 0) {
          continue
        }
        const first: number = text.charCodeAt(0)
        const last: number = text.charCodeAt(text.length - 1)
        /* 不能以低位代理开头，也不能以高位代理结尾 */
        expect(first >= 0xDC00 && first <= 0xDFFF).assertFalse()
        expect(last >= 0xD800 && last <= 0xDBFF).assertFalse()
      }
    })

    it('evictsLeastRecentlyUsedByEntryLimit', 0, (): void => {
      const archive: ToolResultArchive = new ToolResultArchive(2, 100000)
      const first: string = archive.put('a', '内容一')
      const second: string = archive.put('b', '内容二')
      /* 读一次 first，把它顶到 LRU 队尾，second 变成最旧 */
      expect(archive.get(first) !== null).assertTrue()
      const third: string = archive.put('c', '内容三')
      expect(archive.size()).assertEqual(2)
      expect(archive.get(first) !== null).assertTrue()
      expect(archive.get(second) === null).assertTrue()
      expect(archive.get(third) !== null).assertTrue()
    })

    it('returnsNullForUnknownIdAndEmptyContent', 0, (): void => {
      const archive: ToolResultArchive = new ToolResultArchive()
      expect(archive.read('res_missing', 0, 100) === null).assertTrue()
      /* 空内容不归档：没有可续读的东西，给 ID 只会诱发无效调用 */
      expect(archive.put('nga_read_thread', '').length).assertEqual(0)
      expect(archive.size()).assertEqual(0)
    })

    it('hydratesOnlyFreshSuccessfulSnapshots', 0, (): void => {
      let now: number = 1000
      const clock: () => number = (): number => now
      const source: ToolResultCache = new ToolResultCache(10, clock)
      const result: AiToolResult = new AiToolResult()
      result.success = true
      result.content = '缓存内容'
      source.set('key_a', result, 5000)
      const snapshots = source.snapshot()
      expect(snapshots.length).assertEqual(1)

      const restored: ToolResultCache = new ToolResultCache(10, clock)
      expect(restored.hydrate(snapshots)).assertEqual(1)
      const hit: AiToolResult | null = restored.get('key_a')
      expect(hit !== null).assertTrue()
      if (hit !== null) {
        expect(hit.content).assertEqual('缓存内容')
      }
      /* 恢复不续命：原 TTL 到期后仍必须失效 */
      now = 10000
      expect(restored.get('key_a') === null).assertTrue()
    })

    it('evictsByCharBudget', 0, (): void => {
      const clock: () => number = (): number => 1000
      /* 总字符预算 10：两条 6 字符的结果只能留一条 */
      const cache: ToolResultCache = new ToolResultCache(10, clock, 10)
      const first: AiToolResult = new AiToolResult()
      first.success = true
      first.content = '123456'
      const second: AiToolResult = new AiToolResult()
      second.success = true
      second.content = 'abcdef'
      cache.set('a', first, 5000)
      cache.set('b', second, 5000)
      expect(cache.size).assertEqual(1)
      expect(cache.get('a') === null).assertTrue()
      expect(cache.get('b') !== null).assertTrue()
    })
  })

  describe('toolResultTruncation', (): void => {
    it('pointsToExpandWhenArchived', 0, (): void => {
      const long: string = '这是一段很长的工具结果'.repeat(100)
      const id: string = 'res_7_test'
      const fit: ToolContentFit = fitToolResultContent(long, 200, id)
      expect(fit.truncated).assertTrue()
      expect(fit.text.indexOf('result_id=' + id) >= 0).assertTrue()
      expect(fit.text.indexOf('expand_tool_result') >= 0).assertTrue()
      /* 关键：不能继续教模型"同参数重调"——那条路只会拿回同样的开头 */
      expect(fit.text.indexOf('再次调用该工具') < 0).assertTrue()
      expect(fit.text.length < long.length).assertTrue()
    })

    it('keepsLegacyHintWhenNoArchive', 0, (): void => {
      const long: string = '这是一段很长的工具结果'.repeat(100)
      const fit: ToolContentFit = fitToolResultContent(long, 200)
      expect(fit.truncated).assertTrue()
      expect(fit.text.indexOf('再次调用该工具') >= 0).assertTrue()
    })

    it('neverTruncatesWithinBudget', 0, (): void => {
      const short: string = '短内容'
      const fit: ToolContentFit = fitToolResultContent(short, 1000, 'res_x')
      expect(fit.truncated).assertFalse()
      expect(fit.text).assertEqual(short)
    })
  })

  describe('contextOverflowDetection', (): void => {
    it('matchesRealOverflowPhrases', 0, (): void => {
      expect(isContextOverflowError('400\nmaximum context length is 131072 tokens')).assertTrue()
      expect(isContextOverflowError('400\n{"code":"context_length_exceeded"}')).assertTrue()
      expect(isContextOverflowError('400\ninput is too long for this model')).assertTrue()
      expect(isContextOverflowError('400\n上下文长度超出限制')).assertTrue()
    })

    it('doesNotMatchOrdinaryBadRequest', 0, (): void => {
      expect(isContextOverflowError('400\ninvalid model name')).assertFalse()
      expect(isContextOverflowError('401\ninvalid api key')).assertFalse()
      expect(isContextOverflowError('请求已取消')).assertFalse()
    })
  })

  describe('budgetAccounting', (): void => {
    it('countsToolSchemaTokens', 0, (): void => {
      const tools: AiToolDefinition[] = []
      const definition: AiToolDefinition = new AiToolDefinition()
      definition.name = 'nga_read_thread'
      definition.description = '读取帖子正文与楼层'
      const properties: Record<string, Object> = {}
      properties['tid'] = 'string'
      definition.parameters = properties
      tools.push(definition)
      expect(estimateToolDefinitionsTokens(tools) > 0).assertTrue()
      expect(estimateToolDefinitionsTokens([])).assertEqual(0)
    })

    it('reportsUnknownCacheRatioWithoutUsage', 0, (): void => {
      const usage: ContextUsage = new ContextUsage()
      /* 没有真实用量 / 服务端没报告缓存字段时返回 -1，页面据此不展示"缓存 0%" */
      expect(usage.cacheHitRatio()).assertEqual(-1)
      usage.promptTokens = 1000
      usage.cachedTokens = 750
      expect(usage.cacheHitRatio()).assertEqual(-1)
      usage.cacheReported = true
      expect(usage.cacheHitRatio()).assertEqual(0.75)
      /* 服务端报告了但本次 0 命中：这是可信的 0%，不是"未知" */
      usage.cachedTokens = 0
      expect(usage.cacheHitRatio()).assertEqual(0)
    })

    it('calibratedBudgetNeverExceedsWindow', 0, (): void => {
      const window: number = 1000000
      /*
       * 校准系数 0.5 表示"我们高估一倍"，旧实现会把预算放大到 1.25M，
       * 主动制造超窗；新实现必须夹在窗口安全线内。
       */
      expect(resolveCalibratedBudget(window, 0.5) <= window).assertTrue()
      expect(resolveCalibratedBudget(window, 0.7) <= window).assertTrue()
      /* 校准 >1（低估）必须收紧 */
      expect(resolveCalibratedBudget(window, 2) < resolveCalibratedBudget(window, 1)).assertTrue()
      /* 非法系数按 1 处理，未知窗口仍给正预算 */
      expect(resolveCalibratedBudget(0, 0)).assertEqual(resolveCalibratedBudget(0, 1))
      expect(resolveCalibratedBudget(0, 1) > 0).assertTrue()
    })

    it('summaryInputFitsSmallWindow', 0, (): void => {
      /* 旧实现对小窗口返回 24000，摘要请求自己超窗 */
      expect(resolveSummaryInputLimit(0)).assertEqual(24000)
      const small: number = resolveSummaryInputLimit(8192)
      expect(small > 0).assertTrue()
      expect(small < 8192).assertTrue()
      const large: number = resolveSummaryInputLimit(1000000)
      expect(large > 24000).assertTrue()
      expect(large <= 1000000).assertTrue()
    })
  })

  describe('expandToolResult', (): void => {
    it('readsArchivedSliceThroughRegistry', 0, async (): Promise<void> => {
      const context: AiToolContext = new AiToolContext()
      context.tools = new AiToolSettings()
      const content: string = '一楼内容。'.repeat(50)
      const id: string = context.archive.put('nga_read_thread', content)
      const args: string = '{"result_id":"' + id + '","offset":0,"limit":' +
        ARCHIVE_DEFAULT_READ_CHARS.toString() + '}'
      const result: AiToolResult = await aiToolRegistry.execute('expand_tool_result', args, context, '')
      expect(result.success).assertTrue()
      expect(result.content.indexOf('续读结果') >= 0).assertTrue()
      expect(result.content.indexOf(content.substring(0, 20)) >= 0).assertTrue()
    })

    it('failsClearlyForUnknownId', 0, async (): Promise<void> => {
      const context: AiToolContext = new AiToolContext()
      context.tools = new AiToolSettings()
      const result: AiToolResult = await aiToolRegistry.execute('expand_tool_result',
        '{"result_id":"res_missing"}', context, '')
      expect(result.success).assertFalse()
      expect(result.content.indexOf('已不存在') >= 0).assertTrue()
    })

    it('bypassesPresetToolWhitelist', 0, (): void => {
      const preset: AiAgentPreset = new AiAgentPreset()
      preset.tools = ['nga_read_thread']
      /* 任务只允许读帖时，续读入口仍必须可用，否则截断就不可恢复 */
      expect(presetAllowsTool(preset, 'expand_tool_result')).assertTrue()
      expect(presetAllowsTool(preset, 'nga_read_thread')).assertTrue()
      expect(presetAllowsTool(preset, 'web_search')).assertFalse()
    })
  })
}
