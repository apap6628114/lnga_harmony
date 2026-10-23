import { describe, expect, it } from '@ohos/hypium'
import {
  AI_SESSION_ROLE_ASSISTANT,
  AI_SESSION_ROLE_USER,
  AI_SESSION_TITLE_MAX,
  AiSession,
  AiSessionMessage,
  MAX_AI_SESSIONS,
  MAX_AI_SESSION_MESSAGES,
  appendAiSessionMessage,
  cloneAiSession,
  createAiSession,
  formatAiSessionTime,
  isValidAiSession,
  normalizeAiSession,
  sessionSubtitle,
  sessionTitleFrom,
  sortAiSessions,
  trimAiSessionMessages
} from '../main/ets/model/AiSession'
import { ChatMessage } from '../main/ets/service/ai/AiProtocolTypes'
import {
  AI_MEMORY_MODE_BALANCED,
  AI_MEMORY_MODE_COMPACT,
  AI_MEMORY_MODE_LONG,
  AiMemorySettings,
  DEFAULT_AI_MEMORY_MODE,
  memoryKeepRatio,
  memoryTriggerRatio,
  normalizeAiMemorySettings
} from '../main/ets/model/AiMemoryConfig'
import {
  ASSUMED_CONTEXT_WINDOW,
  ContextUsage,
  FoldedTurn,
  HistoryFitResult,
  MAX_FOLDED_QUESTIONS,
  ToolContentFit,
  buildFoldedHistorySection,
  buildFoldedTurnsSection,
  estimateMessageTokens,
  estimateTextTokens,
  fitHistoryToBudget,
  fitToolResultContent,
  historyFingerprint,
  nextCalibrationFactor,
  resolveHistoryBudget,
  resolveToolResultBudget,
  resolveTriggerTokens
} from '../main/ets/service/ai/ContextBudget'

/**
 * 构造一条消息。
 *
 * @param role - 角色
 * @param content - 正文
 * @param notes - 工具证据
 * @returns 消息
 */
function makeMessage(role: string, content: string, notes: string[]): AiSessionMessage {
  const message: AiSessionMessage = new AiSessionMessage()
  message.role = role
  message.content = content
  message.createdAt = 1000
  for (let i: number = 0; i < notes.length; i++) {
    message.toolNotes.push(notes[i])
  }
  return message
}

/**
 * 构造一段中文文本（估算 1 字 1 token，便于精确断言）。
 *
 * @param count - 字数
 * @returns 文本
 */
function cjkText(count: number): string {
  let text: string = ''
  for (let i: number = 0; i < count; i++) {
    text += '啊'
  }
  return text
}

/**
 * 构造一轮完整对话（user + assistant）。
 *
 * @param index - 轮次
 * @param length - 每条正文字数
 * @returns 两条消息
 */
function makeTurn(index: number, length: number): ChatMessage[] {
  const messages: ChatMessage[] = []
  messages.push(new ChatMessage('user', '问题' + index.toString() + cjkText(length)))
  messages.push(new ChatMessage('assistant', '回答' + index.toString() + cjkText(length)))
  return messages
}

/**
 * 会话记忆与上下文预算回归测试。
 *
 * 覆盖两条最容易静默回归的契约：
 * 1. 持久化层的形状校验与裁剪（坏数据不能带进 UI，恢复必须从用户消息开始）；
 * 2. 历史预算的保留策略（最后一条必留、窗口对齐用户消息、折叠清单有上限）。
 */
export default function aiSessionUnitTest(): void {
  describe('aiSessionModel', (): void => {
    it('createsSessionWithIdentityAndTimestamp', 0, (): void => {
      const session: AiSession = createAiSession('task_1', '帖子总结')
      expect(session.id.startsWith('sess_')).assertTrue()
      expect(session.presetId).assertEqual('task_1')
      expect(session.presetName).assertEqual('帖子总结')
      expect(session.title).assertEqual('')
      expect(session.messages.length).assertEqual(0)
      expect(session.createdAt > 0).assertTrue()
    })

    it('flattensAndTruncatesTitle', 0, (): void => {
      expect(sessionTitleFrom('  第一行\n第二行  ')).assertEqual('第一行 第二行')
      const long: string = sessionTitleFrom(cjkText(AI_SESSION_TITLE_MAX + 10))
      expect(long.length).assertEqual(AI_SESSION_TITLE_MAX + 1)
      expect(long.endsWith('…')).assertTrue()
    })

    it('appendFillsTitleFromFirstUserMessage', 0, (): void => {
      const session: AiSession = createAiSession('', '')
      appendAiSessionMessage(session, makeMessage(AI_SESSION_ROLE_USER, '帮我总结这篇帖子', []))
      expect(session.title).assertEqual('帮我总结这篇帖子')
      /* 后续 assistant 消息不能覆盖标题 */
      appendAiSessionMessage(session, makeMessage(AI_SESSION_ROLE_ASSISTANT, '好的', []))
      expect(session.title).assertEqual('帮我总结这篇帖子')
      expect(session.messages.length).assertEqual(2)
    })

    it('appendKeepsMessageCountBounded', 0, (): void => {
      const session: AiSession = createAiSession('', '')
      for (let i: number = 0; i < MAX_AI_SESSION_MESSAGES + 5; i++) {
        const role: string = i % 2 === 0 ? AI_SESSION_ROLE_USER : AI_SESSION_ROLE_ASSISTANT
        appendAiSessionMessage(session, makeMessage(role, 'm' + i.toString(), []))
      }
      expect(session.messages.length).assertEqual(MAX_AI_SESSION_MESSAGES)
    })

    it('trimStartsFromUserMessage', 0, (): void => {
      const messages: AiSessionMessage[] = []
      /* 构造 205 条：user 在下标偶数位，裁剪后会从 user 开始 */
      for (let i: number = 0; i < MAX_AI_SESSION_MESSAGES + 5; i++) {
        const role: string = i % 2 === 0 ? AI_SESSION_ROLE_USER : AI_SESSION_ROLE_ASSISTANT
        messages.push(makeMessage(role, 'm' + i.toString(), []))
      }
      const trimmed: AiSessionMessage[] = trimAiSessionMessages(messages)
      /*
       * 裁剪从尾部保留 200 条后，起点可能落在 assistant 上；实现会把起点继续前移
       * 到最近的一条用户消息，因此结果**可能略少于上限**（199），这是预期行为。
       */
      expect(trimmed.length > 0).assertTrue()
      expect(trimmed.length <= MAX_AI_SESSION_MESSAGES).assertTrue()
      expect(trimmed[0].role).assertEqual(AI_SESSION_ROLE_USER)
    })

    it('validatesEnvelopeShapeStrictly', 0, (): void => {
      /*
       * 这里模拟的是"从磁盘读出的原始 JSON"：只能经 JSON.parse 得到无类型对象，
       * 与生产侧 PreferencesStore.getJSON 的入口形态一致（ArkTS 不允许无类型对象字面量）。
       */
      const valid: Record<string, Object> = JSON.parse('{"id":"s1","title":"标题","presetId":"",' +
        '"messages":[{"role":"' + AI_SESSION_ROLE_USER + '","content":"问题"}]}') as Record<string, Object>
      expect(isValidAiSession(valid)).assertTrue()

      const badRole: Record<string, Object> = JSON.parse('{"id":"s1","title":"","presetId":"",' +
        '"messages":[{"role":"tool","content":"x"}]}') as Record<string, Object>
      expect(isValidAiSession(badRole)).assertFalse()

      const missingContent: Record<string, Object> = JSON.parse('{"id":"s1","title":"","presetId":"",' +
        '"messages":[{"role":"' + AI_SESSION_ROLE_USER + '"}]}') as Record<string, Object>
      expect(isValidAiSession(missingContent)).assertFalse()

      const noId: Record<string, Object> = JSON.parse('{"id":"","title":"","presetId":"",' +
        '"messages":[]}') as Record<string, Object>
      expect(isValidAiSession(noId)).assertFalse()

      /* messages 不是数组：整封信封判为非法，避免坏数据进入恢复流程 */
      const badMessages: Record<string, Object> = JSON.parse('{"id":"s1","title":"","presetId":"",' +
        '"messages":"oops"}') as Record<string, Object>
      expect(isValidAiSession(badMessages)).assertFalse()
    })

    it('normalizeDropsIllegalMessagesAndCapsNotes', 0, (): void => {
      const raw: AiSession = new AiSession()
      raw.id = 's1'
      raw.messages = []
      raw.messages.push(makeMessage(AI_SESSION_ROLE_USER, '问题', []))
      raw.messages.push(makeMessage('system', '不该出现', []))
      raw.messages.push(makeMessage(AI_SESSION_ROLE_ASSISTANT, '回答',
        ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']))

      const normalized: AiSession = normalizeAiSession(raw)
      expect(normalized.id).assertEqual('s1')
      expect(normalized.messages.length).assertEqual(2)
      expect(normalized.messages[0].role).assertEqual(AI_SESSION_ROLE_USER)
      /* toolNotes 上限由 model 常量约束，避免单条消息无限膨胀 */
      expect(normalized.messages[1].toolNotes.length <= 6).assertTrue()
    })

    it('sortsSessionsByUpdatedAtDescending', 0, (): void => {
      const a: AiSession = createAiSession('', '')
      a.id = 'a'
      a.updatedAt = 100
      const b: AiSession = createAiSession('', '')
      b.id = 'b'
      b.updatedAt = 300
      const c: AiSession = createAiSession('', '')
      c.id = 'c'
      c.updatedAt = 200
      const sorted: AiSession[] = sortAiSessions([a, b, c])
      expect(sorted.length).assertEqual(3)
      expect(sorted[0].id).assertEqual('b')
      expect(sorted[1].id).assertEqual('c')
      expect(sorted[2].id).assertEqual('a')
    })

    it('cloneIsDeepForMessages', 0, (): void => {
      const session: AiSession = createAiSession('task', '任务')
      appendAiSessionMessage(session, makeMessage(AI_SESSION_ROLE_USER, '问题', []))
      const copy: AiSession = cloneAiSession(session)
      copy.messages[0].content = '改过了'
      copy.title = '改过了'
      expect(session.messages[0].content).assertEqual('问题')
      expect(session.title).assertEqual('问题')
    })

    it('formatsSessionTime', 0, (): void => {
      expect(formatAiSessionTime(0)).assertEqual('')
      expect(formatAiSessionTime(Date.now()).startsWith('今天 ')).assertTrue()
    })

    it('buildsSessionSubtitle', 0, (): void => {
      const session: AiSession = createAiSession('', '')
      appendAiSessionMessage(session, makeMessage(AI_SESSION_ROLE_USER, '问一', []))
      appendAiSessionMessage(session, makeMessage(AI_SESSION_ROLE_ASSISTANT, '答一', []))
      expect(sessionSubtitle(session)).assertEqual('自由对话 · 1 轮')

      const taskSession: AiSession = createAiSession('t1', '帖子总结')
      expect(sessionSubtitle(taskSession)).assertEqual('帖子总结 · 0 轮')
    })

    it('keepsSessionCapConstantPositive', 0, (): void => {
      expect(MAX_AI_SESSIONS > 0).assertTrue()
    })
  })

  describe('aiContextBudget', (): void => {
    it('estimatesCjkAndLatinTokens', 0, (): void => {
      expect(estimateTextTokens('')).assertEqual(0)
      expect(estimateTextTokens('你好')).assertEqual(2)
      expect(estimateTextTokens('abcd')).assertEqual(1)
      expect(estimateTextTokens('abcdefgh')).assertEqual(2)
      /* 中英混排：CJK 逐字 + 拉丁每 4 字符 1 token */
      expect(estimateTextTokens('你好abcd')).assertEqual(3)
    })

    it('countsMessageOverhead', 0, (): void => {
      const message: ChatMessage = new ChatMessage('user', '你好')
      expect(estimateMessageTokens(message) > estimateTextTokens('你好')).assertTrue()
    })

    it('keepsEverythingWhenWithinBudget', 0, (): void => {
      const messages: ChatMessage[] = makeTurn(1, 10)
      messages.push(new ChatMessage('user', '追问'))
      const fit: HistoryFitResult = fitHistoryToBudget(messages, 100000)
      expect(fit.truncated).assertFalse()
      expect(fit.messages.length).assertEqual(3)
      expect(fit.foldedQuestions.length).assertEqual(0)
      expect(fit.droppedMessages).assertEqual(0)
    })

    it('dropsOldestAndFoldsQuestions', 0, (): void => {
      const messages: ChatMessage[] = []
      for (let i: number = 1; i <= 4; i++) {
        const turn: ChatMessage[] = makeTurn(i, 100)
        messages.push(turn[0])
        messages.push(turn[1])
      }
      messages.push(new ChatMessage('user', '最后一问'))
      const fit: HistoryFitResult = fitHistoryToBudget(messages, 150)
      expect(fit.truncated).assertTrue()
      expect(fit.messages.length > 0).assertTrue()
      /* 保留窗口必须从用户消息开始 */
      expect(fit.messages[0].role).assertEqual('user')
      /* 最后一条（本次提问）必须在 */
      expect(fit.messages[fit.messages.length - 1].content).assertEqual('最后一问')
      expect(fit.droppedMessages > 0).assertTrue()
      expect(fit.foldedQuestions.length > 0).assertTrue()
      expect(fit.foldedQuestions[0].startsWith('问题1')).assertTrue()
    })

    it('keepsRecentTurnsAsOriginalText', 0, (): void => {
      /*
       * 压缩只允许动"老旧轮次"：最近 N 轮必须保持原文。
       * 这是"压缩不伤效果"的关键——当前话题的上下文永远是原样的。
       */
      const messages: ChatMessage[] = []
      for (let i: number = 1; i <= 10; i++) {
        messages.push(new ChatMessage('user', '问题' + i.toString() + cjkText(100)))
        messages.push(new ChatMessage('assistant', '回答' + i.toString() + cjkText(100)))
      }
      const recentTurns: number = 3
      const fit: HistoryFitResult = fitHistoryToBudget(messages, 800, 0.5, recentTurns)
      expect(fit.truncated).assertTrue()
      const tailCount: number = recentTurns * 2
      expect(fit.messages.length >= tailCount).assertTrue()
      /* 最近 N 轮的每一条都必须逐字等于原文 */
      for (let i: number = 0; i < tailCount; i++) {
        const actual: string = fit.messages[fit.messages.length - tailCount + i].content
        const original: string = messages[messages.length - tailCount + i].content
        expect(actual).assertEqual(original)
      }
      /* 被压的是更早的轮次，不是最近的 */
      expect(fit.droppedMessages > 0).assertTrue()
      expect(fit.droppedMessages <= messages.length - tailCount).assertTrue()
    })

    it('keepsLastMessageEvenWhenItAloneExceedsBudget', 0, (): void => {
      const messages: ChatMessage[] = []
      messages.push(new ChatMessage('user', cjkText(50)))
      messages.push(new ChatMessage('assistant', cjkText(50)))
      messages.push(new ChatMessage('user', cjkText(500)))
      const fit: HistoryFitResult = fitHistoryToBudget(messages, 10)
      expect(fit.messages.length).assertEqual(1)
      expect(fit.messages[0].content).assertEqual(cjkText(500))
    })

    it('capsFoldedQuestionList', 0, (): void => {
      const messages: ChatMessage[] = []
      for (let i: number = 1; i <= MAX_FOLDED_QUESTIONS + 3; i++) {
        const turn: ChatMessage[] = makeTurn(i, 100)
        messages.push(turn[0])
        messages.push(turn[1])
      }
      messages.push(new ChatMessage('user', '本次提问'))
      const fit: HistoryFitResult = fitHistoryToBudget(messages, 150)
      expect(fit.truncated).assertTrue()
      expect(fit.foldedQuestions.length).assertEqual(MAX_FOLDED_QUESTIONS)
      expect(fit.foldedOmitted > 0).assertTrue()
    })

    it('buildsFoldedSectionOnlyWhenNeeded', 0, (): void => {
      expect(buildFoldedHistorySection([], 0)).assertEqual('')
      const section: string = buildFoldedHistorySection(['问题一'], 2)
      expect(section.indexOf('【较早的对话已折叠】') >= 0).assertTrue()
      expect(section.indexOf('- 你问：问题一') >= 0).assertTrue()
      expect(section.indexOf('更早的 2 轮已省略') >= 0).assertTrue()
    })

    it('resolvesBudgetFromModelWindow', 0, (): void => {
      /*
       * 未知窗口不再回落 24000：假设 128K 的现代下限。
       * 保守应该是"防超窗"，不是"少用上下文"。
       */
      const unknown: number = resolveHistoryBudget(0)
      expect(unknown > 100000).assertTrue()
      expect(unknown <= ASSUMED_CONTEXT_WINDOW).assertTrue()

      /* 8K 窗口：扣掉输出预留后仍要能对话 */
      const small: number = resolveHistoryBudget(8000)
      expect(small < 8000).assertTrue()
      expect(small >= 4000).assertTrue()

      /* 1M 窗口必须几乎用满：不许再乘 0.75 这类折扣 */
      const large: number = resolveHistoryBudget(1000000)
      expect(large > 850000).assertTrue()
      expect(large < 1000000).assertTrue()

      /* 预算随窗口单调不减 */
      expect(resolveHistoryBudget(32000) >= resolveHistoryBudget(16000)).assertTrue()
    })

    it('derivesTriggerFromRatio', 0, (): void => {
      expect(resolveTriggerTokens(1000, 0.95)).assertEqual(950)
      expect(resolveTriggerTokens(1000, 0.8)).assertEqual(800)
      /* 越界比例回落默认（长记忆 95%）：不能让脏值变成"永不压缩" */
      expect(resolveTriggerTokens(1000, 0)).assertEqual(950)
      expect(resolveTriggerTokens(1000, 2)).assertEqual(950)
      expect(resolveTriggerTokens(0, 0.9)).assertEqual(0)
    })

    it('derivesToolBudgetFromHistoryBudget', 0, (): void => {
      expect(resolveToolResultBudget(0)).assertEqual(0)
      /* 工具结果与历史共享同一个窗口，不再单独打六折 */
      expect(resolveToolResultBudget(10000)).assertEqual(10000)
    })

    it('foldsQuestionWithAnswerHead', 0, (): void => {
      const messages: ChatMessage[] = []
      for (let i: number = 1; i <= 4; i++) {
        messages.push(new ChatMessage('user', '问题' + i.toString() + cjkText(100)))
        /* 第一句是结论，后面是长正文：折叠只应保留第一句 */
        messages.push(new ChatMessage('assistant', '结论' + i.toString() + '。' + cjkText(100)))
      }
      messages.push(new ChatMessage('user', '最后一问'))
      const fit: HistoryFitResult = fitHistoryToBudget(messages, 150)
      expect(fit.truncated).assertTrue()
      expect(fit.foldedTurns.length > 0).assertTrue()
      const first: FoldedTurn = fit.foldedTurns[0]
      expect(first.question.startsWith('问题1')).assertTrue()
      /* 改造前这里恒为空——"折叠 = 结论丢失"的根因 */
      expect(first.answer.length > 0).assertTrue()
      expect(first.answer.startsWith('结论1')).assertTrue()
      const section: string = buildFoldedTurnsSection(fit.foldedTurns, 0)
      expect(section.indexOf('你问：') >= 0).assertTrue()
      expect(section.indexOf('我答（摘要）：') >= 0).assertTrue()
    })

    it('compressesToolResultOverBudget', 0, (): void => {
      const long: string = cjkText(2000)
      const fit: ToolContentFit = fitToolResultContent(long, 100)
      expect(fit.truncated).assertTrue()
      expect(fit.text.length < long.length).assertTrue()
      /* 压缩必须给出可恢复路径，否则模型会以为数据就这么点 */
      expect(fit.text.indexOf('上下文预算压缩') >= 0).assertTrue()
      expect(fit.text.indexOf('再次调用该工具') >= 0).assertTrue()

      /* 预算不限（0）或未超限时不得动原文 */
      const untouched: ToolContentFit = fitToolResultContent(long, 0)
      expect(untouched.truncated).assertFalse()
      expect(untouched.text).assertEqual(long)
      const small: ToolContentFit = fitToolResultContent('短内容', 100)
      expect(small.truncated).assertFalse()
    })

    it('computesUsageRatioWithToolResults', 0, (): void => {
      const usage: ContextUsage = new ContextUsage()
      /* 进度条的分母是触发阈值，不是总预算：用户关心"离压缩还有多远" */
      usage.budgetTokens = 1000000
      usage.triggerTokens = 1000
      usage.systemTokens = 100
      usage.historyTokens = 200
      usage.toolTokens = 300
      expect(usage.usedTokens()).assertEqual(600)
      expect(usage.ratio()).assertEqual(0.6)

      /* 超阈值时比例夹到 1：进度条不能溢出 */
      usage.toolTokens = 900
      expect(usage.ratio()).assertEqual(1)
      /* 阈值未知时比例为 0，不误报"已满" */
      usage.triggerTokens = 0
      expect(usage.ratio()).assertEqual(0)
    })

    it('calibratesTowardRealPromptTokens', 0, (): void => {
      /* 真实是估算的 1.5 倍（我们低估）→ 系数增大，但 EMA 不一步到位 */
      const up: number = nextCalibrationFactor(1, 1000, 1500)
      expect(up > 1).assertTrue()
      expect(up < 1.5).assertTrue()

      /* 真实只有估算的 0.6（中文被高估）→ 系数减小 */
      const down: number = nextCalibrationFactor(1, 1000, 600)
      expect(down < 1).assertTrue()
      expect(down > 0.6).assertTrue()

      /* 缺样本（估算或真实为 0）→ 保持不变，不能凭单边数据乱调 */
      expect(nextCalibrationFactor(1, 0, 500)).assertEqual(1)
      expect(nextCalibrationFactor(1, 1000, 0)).assertEqual(1)

      /* 极端样本被夹紧：1000 倍的偏差也只能推到上限附近，不能把预算调爆 */
      const extreme: number = nextCalibrationFactor(1, 100, 100000)
      expect(extreme > 1).assertTrue()
      expect(extreme <= 2).assertTrue()
      /* 连续同类观测应单调收敛向上限 */
      const second: number = nextCalibrationFactor(extreme, 100, 100000)
      expect(second >= extreme).assertTrue()
    })

    it('fingerprintsHistoryPrefixStably', 0, (): void => {
      const messages: ChatMessage[] = []
      messages.push(new ChatMessage('user', '第一问'))
      messages.push(new ChatMessage('assistant', '第一答'))
      messages.push(new ChatMessage('user', '第二问'))
      const full: string = historyFingerprint(messages, 3)
      /* 同样的输入必须得到同样的指纹（否则记忆永远无法复用） */
      expect(historyFingerprint(messages, 3)).assertEqual(full)
      /* 覆盖范围不同 → 指纹不同 */
      expect(historyFingerprint(messages, 2) !== full).assertTrue()

      /* 内容变了 → 指纹必须变（否则会把旧摘要套到新对话上） */
      const changed: ChatMessage[] = []
      changed.push(new ChatMessage('user', '第一问改'))
      changed.push(new ChatMessage('assistant', '第一答'))
      expect(historyFingerprint(changed, 2) !== historyFingerprint(messages, 2)).assertTrue()

      /* 追加新消息不影响旧前缀：这是"增量更新摘要"的前提 */
      messages.push(new ChatMessage('assistant', '第二答'))
      expect(historyFingerprint(messages, 3)).assertEqual(full)
    })
  })

  describe('aiMemoryMode', (): void => {
    it('mapsModeToKeepRatio', 0, (): void => {
      expect(memoryKeepRatio(AI_MEMORY_MODE_COMPACT)).assertEqual(0.45)
      expect(memoryKeepRatio(AI_MEMORY_MODE_BALANCED)).assertEqual(0.6)
      expect(memoryKeepRatio(AI_MEMORY_MODE_LONG)).assertEqual(0.8)
      /* 触发阈值：长记忆最晚压缩（先把窗口用满） */
      expect(memoryTriggerRatio(AI_MEMORY_MODE_COMPACT)).assertEqual(0.8)
      expect(memoryTriggerRatio(AI_MEMORY_MODE_BALANCED)).assertEqual(0.9)
      expect(memoryTriggerRatio(AI_MEMORY_MODE_LONG)).assertEqual(0.95)
      /* 未知档位回落长记忆：默认档永远可解析，持久化脏值不能让预算失效 */
      expect(memoryTriggerRatio('bogus')).assertEqual(0.95)
      expect(memoryKeepRatio('bogus')).assertEqual(0.8)
      expect(DEFAULT_AI_MEMORY_MODE).assertEqual(AI_MEMORY_MODE_LONG)
    })

    it('normalizesLegacySettingsToLongMemory', 0, (): void => {
      const empty: AiMemorySettings = new AiMemorySettings()
      expect(empty.mode).assertEqual(AI_MEMORY_MODE_LONG)

      const raw: AiMemorySettings = new AiMemorySettings()
      raw.mode = AI_MEMORY_MODE_COMPACT
      expect(normalizeAiMemorySettings(raw).mode).assertEqual(AI_MEMORY_MODE_COMPACT)

      raw.mode = ''
      expect(normalizeAiMemorySettings(raw).mode).assertEqual(AI_MEMORY_MODE_LONG)
      raw.mode = 'bogus'
      expect(normalizeAiMemorySettings(raw).mode).assertEqual(AI_MEMORY_MODE_LONG)
    })

    it('normalizesTokenCalibration', 0, (): void => {
      /* 未观测样本前按 1 处理（不调整预算） */
      expect(new AiMemorySettings().tokenCalibration).assertEqual(1)
      const raw: AiMemorySettings = new AiMemorySettings()
      /* 越界值被夹到合法区间：脏数据不能把预算放大到撞窗口 */
      raw.tokenCalibration = 0.1
      expect(normalizeAiMemorySettings(raw).tokenCalibration).assertEqual(0.5)
      raw.tokenCalibration = 5
      expect(normalizeAiMemorySettings(raw).tokenCalibration).assertEqual(2)
      /* 合法值原样保留 */
      raw.tokenCalibration = 0.8
      expect(normalizeAiMemorySettings(raw).tokenCalibration).assertEqual(0.8)
    })

    it('longMemoryKeepsMoreHistoryThanBalanced', 0, (): void => {
      const messages: ChatMessage[] = []
      for (let i: number = 1; i <= 6; i++) {
        messages.push(new ChatMessage('user', '问题' + i.toString() + cjkText(100)))
        messages.push(new ChatMessage('assistant', '回答' + i.toString() + cjkText(100)))
      }
      messages.push(new ChatMessage('user', '最后一问'))

      const balanced: HistoryFitResult = fitHistoryToBudget(messages, 600, 0.55, 1)
      const long: HistoryFitResult = fitHistoryToBudget(messages, 600, 0.7, 1)
      expect(balanced.truncated).assertTrue()
      expect(long.truncated).assertTrue()
      /* 长记忆档必须保留更多、丢弃更少 */
      expect(long.messages.length >= balanced.messages.length).assertTrue()
      expect(long.droppedMessages <= balanced.droppedMessages).assertTrue()
      /* 两档都保底保留本次提问，且窗口从用户消息开始 */
      expect(long.messages[long.messages.length - 1].content).assertEqual('最后一问')
      expect(long.messages[0].role).assertEqual('user')

      /* 越界比例回落默认：裁到 100% 等于没裁，会退化成每轮都 miss */
      const clamped: HistoryFitResult = fitHistoryToBudget(messages, 600, 1.5)
      expect(clamped.truncated).assertTrue()
      expect(clamped.messages.length < messages.length).assertTrue()
    })
  })
}
