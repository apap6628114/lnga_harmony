import { describe, expect, it } from '@ohos/hypium'
import {
  KNOWN_MODEL_CONTEXT_WINDOWS,
  resolveModelContextWindow
} from '../main/ets/model/AiModelContextWindows'
import { ChatMessage } from '../main/ets/service/ai/AiProtocolTypes'
import { estimateTextTokens } from '../main/ets/service/ai/ContextBudget'
import {
  SUMMARY_INPUT_MIN_TOKENS,
  SUMMARY_MAX_CHARS,
  buildSummaryPrompt,
  buildSummarySection,
  cleanSummaryText
} from '../main/ets/service/ai/ContextSummarizer'

/**
 * 构造一条消息。
 *
 * @param role - 角色
 * @param content - 正文
 * @returns 消息
 */
function makeMessage(role: string, content: string): ChatMessage {
  return new ChatMessage(role, content)
}

/**
 * 构造指定长度的中文文本。
 *
 * @param count - 字数
 * @returns 文本
 */
function cjkText(count: number): string {
  let text: string = ''
  for (let i: number = 0; i < count; i++) {
    text += '字'
  }
  return text
}

/**
 * 记忆压缩链路回归测试。
 *
 * 覆盖两类最容易静默失效的契约：
 * 1. 已知模型窗口表——预埋值错了比不预埋更糟（会把请求推过窗口）；
 * 2. 生成式摘要的输入 / 输出边界——摘要请求自己不能超窗，输出不能带 markdown 垃圾。
 */
export default function aiContextSummaryTest(): void {
  describe('knownModelContextWindows', (): void => {
    it('resolvesOfficialDeepSeekModels', 0, (): void => {
      /* 官方价目表：deepseek-flash / deepseek-v4-pro 上下文 1M */
      expect(resolveModelContextWindow('deepseek-flash')).assertEqual(1000000)
      expect(resolveModelContextWindow('deepseek-v4-pro')).assertEqual(1000000)
      /* 大小写不敏感 */
      expect(resolveModelContextWindow('DeepSeek-Flash')).assertEqual(1000000)
      /* 首尾空白容错 */
      expect(resolveModelContextWindow('  deepseek-flash  ')).assertEqual(1000000)
    })

    it('returnsUnknownForUnlistedModels', 0, (): void => {
      /* 未知模型必须返回 0（回落保守预算），绝不猜一个值出来 */
      expect(resolveModelContextWindow('gpt-4o')).assertEqual(0)
      expect(resolveModelContextWindow('')).assertEqual(0)
      expect(resolveModelContextWindow('deepseek')).assertEqual(0)
    })

    it('keepsTableEntriesPositive', 0, (): void => {
      /* 表内每条都必须有正窗口值，防止维护时误写 0 导致预算塌回兜底 */
      for (let i: number = 0; i < KNOWN_MODEL_CONTEXT_WINDOWS.length; i++) {
        expect(KNOWN_MODEL_CONTEXT_WINDOWS[i].contextWindow > 0).assertTrue()
        expect(KNOWN_MODEL_CONTEXT_WINDOWS[i].modelId.length > 0).assertTrue()
      }
    })
  })

  describe('summaryPrompt', (): void => {
    it('formatsUserAndAssistantLines', 0, (): void => {
      const dropped: ChatMessage[] = []
      dropped.push(makeMessage('user', '帮我总结这个帖子'))
      dropped.push(makeMessage('assistant', '帖子主要讨论了三件事'))
      const prompt: string = buildSummaryPrompt(dropped)
      expect(prompt.indexOf('用户：帮我总结这个帖子') >= 0).assertTrue()
      expect(prompt.indexOf('助手：帖子主要讨论了三件事') >= 0).assertTrue()
      /* 摘要请求必须自带约束，否则模型会输出散文 */
      expect(prompt.indexOf('必须保留') >= 0).assertTrue()
      /* 结构化四段：结论 / 用户要求 / 关键数据 / 待办 */
      expect(prompt.indexOf('结论：') >= 0).assertTrue()
      expect(prompt.indexOf('用户要求：') >= 0).assertTrue()
      expect(prompt.indexOf('关键数据：') >= 0).assertTrue()
      expect(prompt.indexOf('待办：') >= 0).assertTrue()
    })

    it('includesPreviousDigestForIncrementalUpdate', 0, (): void => {
      const dropped: ChatMessage[] = []
      dropped.push(makeMessage('user', '这一轮的新问题'))
      dropped.push(makeMessage('assistant', '这一轮的新回答'))
      const prompt: string = buildSummaryPrompt(dropped, 12000, '- 结论：旧结论')
      expect(prompt.indexOf('【已有记忆】') >= 0).assertTrue()
      expect(prompt.indexOf('旧结论') >= 0).assertTrue()
      expect(prompt.indexOf('这一轮的新问题') >= 0).assertTrue()
      /* 增量模式必须明确要求保留旧结论，否则每次压缩都会丢掉上一段历史 */
      expect(prompt.indexOf('不要丢弃') >= 0).assertTrue()
    })

    it('keepsPreviousDigestWithoutNewMessages', 0, (): void => {
      /* 只有旧记忆、没有可压缩的新对话时，仍要产出（让模型整理现有记忆） */
      const prompt: string = buildSummaryPrompt([], 12000, '- 结论：旧结论')
      expect(prompt.length > 0).assertTrue()
      expect(prompt.indexOf('旧结论') >= 0).assertTrue()
    })

    it('skipsEmptyAndNonDialogRoles', 0, (): void => {
      const dropped: ChatMessage[] = []
      dropped.push(makeMessage('system', '系统提示'))
      dropped.push(makeMessage('tool', '工具结果'))
      dropped.push(makeMessage('user', '   '))
      /* 没有可压缩内容时返回空串，调用方据此跳过这次调用 */
      expect(buildSummaryPrompt(dropped)).assertEqual('')
    })

    it('keepsTailWhenInputTooLong', 0, (): void => {
      const dropped: ChatMessage[] = []
      for (let i: number = 0; i < 40; i++) {
        dropped.push(makeMessage('user', '第' + i.toString() + '轮' + cjkText(600)))
        dropped.push(makeMessage('assistant', '答' + i.toString() + cjkText(600)))
      }
      const prompt: string = buildSummaryPrompt(dropped)
      /* 输入必须有 token 上限：摘要请求自己不能超窗 */
      expect(estimateTextTokens(prompt) < SUMMARY_INPUT_MIN_TOKENS * 2).assertTrue()
      /* 保留尾部：靠近保留窗口的对话与当前话题最连续 */
      expect(prompt.indexOf('第39轮') >= 0).assertTrue()
      expect(prompt.indexOf('第0轮') < 0).assertTrue()
    })
  })

  describe('summaryCleaning', (): void => {
    it('stripsMarkdownDecoration', 0, (): void => {
      const raw: string = '```text\n# 要点\n**- 结论一**\n> 1. 结论二\n• 结论三\n```'
      const cleaned: string = cleanSummaryText(raw)
      expect(cleaned.indexOf('结论一') >= 0).assertTrue()
      expect(cleaned.indexOf('结论二') >= 0).assertTrue()
      expect(cleaned.indexOf('结论三') >= 0).assertTrue()
      /* 装饰符不能漏进 system：markdown 会让模型误以为要输出格式 */
      expect(cleaned.indexOf('```') < 0).assertTrue()
      expect(cleaned.indexOf('**') < 0).assertTrue()
      expect(cleaned.indexOf('# ') < 0).assertTrue()
    })

    it('dropsModelPreamble', 0, (): void => {
      const raw: string = '以下是这段对话的要点：\n- 用户要总结帖子'
      const cleaned: string = cleanSummaryText(raw)
      expect(cleaned.indexOf('以下是') < 0).assertTrue()
      expect(cleaned.indexOf('用户要总结帖子') >= 0).assertTrue()
    })

    it('capsLengthAndHandlesEmpty', 0, (): void => {
      const long: string = '- ' + cjkText(SUMMARY_MAX_CHARS * 2)
      const cleaned: string = cleanSummaryText(long)
      expect(cleaned.length <= SUMMARY_MAX_CHARS + 1).assertTrue()
      expect(cleanSummaryText('')).assertEqual('')
      /* 全是装饰符 → 等价于没有摘要，调用方回落抽取式 */
      expect(cleanSummaryText('```\n\n```')).assertEqual('')
    })
  })

  describe('summarySection', (): void => {
    it('buildsSectionWithOmittedHint', 0, (): void => {
      const section: string = buildSummarySection('- 结论一\n- 结论二', 3)
      expect(section.indexOf('【较早对话的记忆】') >= 0).assertTrue()
      expect(section.indexOf('- 结论一') >= 0).assertTrue()
      expect(section.indexOf('更早的 3 轮已省略') >= 0).assertTrue()
      /* 必须声明这是二次加工的记忆，防止模型把摘要当原文复述 */
      expect(section.indexOf('不是原文') >= 0).assertTrue()
    })

    it('returnsEmptyWithoutSummary', 0, (): void => {
      expect(buildSummarySection('', 3)).assertEqual('')
    })
  })
}
