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
  HistoryFitResult,
  MAX_FOLDED_QUESTIONS,
  buildFoldedHistorySection,
  estimateMessageTokens,
  estimateTextTokens,
  fitHistoryToBudget
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
      expect(section.indexOf('- 问题一') >= 0).assertTrue()
      expect(section.indexOf('更早的 2 轮提问已省略') >= 0).assertTrue()
    })
  })
}
