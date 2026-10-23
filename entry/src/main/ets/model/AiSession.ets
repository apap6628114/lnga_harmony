/**
 * AI 会话（对话记忆的持久化形态）。
 *
 * 设计定位：**情节记忆**。改造前对话只活在 `AiChatPage` 的 `@State bubbles` 里，
 * 退出页面即销毁，用户上一轮辛苦问出来的结论下次进来要重新问一遍。
 *
 * 三条边界（与 L2 语义记忆的分工）：
 * 1. 本模型只存**用户与模型说过的话**，不存跨会话的偏好/事实——那是独立的记忆条目层；
 * 2. `toolNotes` 只存"这一轮做了什么"的短摘要，用于恢复会话后展示依据，
 *    **不回传给模型**（模型要原文时应重新调用工具，客户端有结果缓存）；
 * 3. 会话按 uid 隔离（信封校验），切换账号看不到上一个账号的对话。
 */

/** 会话信封结构版本（结构演进时 +1，旧信封会被整体判为非法并丢弃）。 */
export const AI_SESSION_SCHEMA_VERSION: number = 1

/** 单账号最多保留的会话数，超出按「最后更新」淘汰。 */
export const MAX_AI_SESSIONS: number = 20

/**
 * 单会话最多保留的消息数。
 *
 * 超出后丢弃最早的消息：会话恢复是为了"接着聊最近的"，不是归档全文。
 * 真正的上下文长度控制由 `ContextBudget` 在请求侧做，这里只防单条会话无限增长。
 */
export const MAX_AI_SESSION_MESSAGES: number = 200

/** 会话标题最大长度（取第一条用户消息）。 */
export const AI_SESSION_TITLE_MAX: number = 28

/** 单条消息最多保留的工具证据行数。 */
export const MAX_AI_SESSION_TOOL_NOTES: number = 6

/** 消息角色：用户。 */
export const AI_SESSION_ROLE_USER: string = 'user'

/** 消息角色：AI。 */
export const AI_SESSION_ROLE_ASSISTANT: string = 'assistant'

/**
 * 会话中的一条消息。
 *
 * 与 `ChatMessage` 的区别：这里不含 `toolCalls` / `outputItems` 等协议字段。
 * 协议字段只在一次 Agent 循环内有效，跨请求回传反而容易造出结构不匹配的请求
 * （tool 消息必须与 tool_calls 一一对应），因此持久层刻意只留纯文本。
 */
export class AiSessionMessage {
  /** 角色（user / assistant） */
  role: string = AI_SESSION_ROLE_USER
  /** 消息正文 */
  content: string = ''
  /**
   * 该轮工具调用的短摘要（仅 assistant 消息可能非空）。
   *
   * 例：`读帖 tid=44191387 · 20 条`。仅用于 UI 展示"这一轮依据什么"，不参与请求。
   */
  toolNotes: string[] = []
  /** 创建时间（毫秒时间戳） */
  createdAt: number = 0
}

/**
 * 一次对话会话。
 */
export class AiSession {
  /** 唯一标识 */
  id: string = ''
  /** 所属任务 ID（空表示自由对话） */
  presetId: string = ''
  /** 任务名称快照（任务被删除后仍能显示当时的任务名） */
  presetName: string = ''
  /** 会话标题（首条用户消息摘要，空表示尚未产生用户消息） */
  title: string = ''
  /** 消息列表（按时间顺序） */
  messages: AiSessionMessage[] = []
  /** 创建时间 */
  createdAt: number = 0
  /** 最后更新时间（会话列表排序依据） */
  updatedAt: number = 0
  /**
   * 早期对话的**压缩记忆**（生成式摘要）。
   *
   * 压缩一次、长期复用：只要历史前缀没变，后续轮次直接拿这份记忆进 system，
   * 不必每轮重新摘要。存盘后，重进会话也能恢复"聊过什么"。
   */
  digest: string = ''
  /** `digest` 覆盖的历史消息条数（0 表示尚无记忆） */
  digestCoveredCount: number = 0
  /** `digest` 覆盖范围的前缀指纹（历史被改动时作废） */
  digestFingerprint: string = ''
}

/**
 * 创建一条空白会话。
 *
 * @param presetId - 任务 ID（自由对话传空串）
 * @param presetName - 任务名称（自由对话传空串）
 * @returns 新会话
 */
export function createAiSession(presetId: string, presetName: string): AiSession {
  const session: AiSession = new AiSession()
  const now: number = Date.now()
  session.id = 'sess_' + now.toString() + '_' + Math.floor(Math.random() * 100000).toString()
  session.presetId = presetId
  session.presetName = presetName
  session.title = ''
  session.messages = []
  session.createdAt = now
  session.updatedAt = now
  return session
}

/**
 * 从用户消息生成会话标题。
 *
 * @param text - 用户消息
 * @returns 单行标题（超长截断）
 */
export function sessionTitleFrom(text: string): string {
  const flat: string = text.replace(/\s+/g, ' ').trim()
  if (flat.length <= AI_SESSION_TITLE_MAX) {
    return flat
  }
  return flat.substring(0, AI_SESSION_TITLE_MAX) + '…'
}

/**
 * 追加一条消息并维持消息数上限。
 *
 * @param session - 目标会话（原地修改）
 * @param message - 新消息
 */
export function appendAiSessionMessage(session: AiSession, message: AiSessionMessage): void {
  session.messages.push(message)
  if (session.messages.length > MAX_AI_SESSION_MESSAGES) {
    session.messages = session.messages.slice(session.messages.length - MAX_AI_SESSION_MESSAGES)
  }
  session.updatedAt = message.createdAt > 0 ? message.createdAt : Date.now()
  if (session.title.length === 0 && message.role === AI_SESSION_ROLE_USER) {
    session.title = sessionTitleFrom(message.content)
  }
}

/**
 * 把消息数组裁剪到上限，并保证**以用户消息开头**。
 *
 * 以用户消息开头的原因：恢复会话后第一条就是 assistant 的回复会让人莫名其妙，
 * 模型侧也不应该看到"没有提问的回答"。裁剪时丢弃最早的消息，可能把配对拆开，
 * 所以最后再从头部丢弃直到角色正确。
 *
 * @param messages - 原始消息
 * @returns 新的消息数组
 */
export function trimAiSessionMessages(messages: AiSessionMessage[]): AiSessionMessage[] {
  let start: number = 0
  if (messages.length > MAX_AI_SESSION_MESSAGES) {
    start = messages.length - MAX_AI_SESSION_MESSAGES
  }
  while (start < messages.length && messages[start].role !== AI_SESSION_ROLE_USER) {
    start++
  }
  const result: AiSessionMessage[] = []
  for (let i: number = start; i < messages.length; i++) {
    result.push(messages[i])
  }
  return result
}

/**
 * 复制一条消息（避免 UI 与存储共享同一批对象）。
 *
 * @param src - 源消息
 * @returns 新消息
 */
export function cloneAiSessionMessage(src: AiSessionMessage): AiSessionMessage {
  const dest: AiSessionMessage = new AiSessionMessage()
  dest.role = src.role
  dest.content = src.content
  dest.createdAt = src.createdAt
  dest.toolNotes = []
  for (let i: number = 0; i < src.toolNotes.length; i++) {
    dest.toolNotes.push(src.toolNotes[i])
  }
  return dest
}

/**
 * 复制一个会话（含消息深拷贝），避免调用方与存储共享同一批对象。
 *
 * @param src - 源会话
 * @returns 新会话
 */
export function cloneAiSession(src: AiSession): AiSession {
  const dest: AiSession = new AiSession()
  dest.id = src.id
  dest.presetId = src.presetId
  dest.presetName = src.presetName
  dest.title = src.title
  dest.createdAt = src.createdAt
  dest.updatedAt = src.updatedAt
  dest.digest = src.digest
  dest.digestCoveredCount = src.digestCoveredCount
  dest.digestFingerprint = src.digestFingerprint
  for (let i: number = 0; i < src.messages.length; i++) {
    dest.messages.push(cloneAiSessionMessage(src.messages[i]))
  }
  return dest
}

/**
 * 归一化一条从磁盘读出的会话。
 *
 * 逐字段重建而不是直接返回原对象：磁盘上的 JSON 可能来自旧版本、也可能被写坏，
 * 把缺字段的对象带进 UI 会让后续的 `.length` / `.indexOf` 抛 TypeError。
 *
 * @param raw - 原始会话
 * @returns 归一化后的会话（无效时返回空会话）
 */
export function normalizeAiSession(raw: AiSession): AiSession {
  const session: AiSession = new AiSession()
  if (raw === null || raw === undefined) {
    return session
  }
  session.id = readString(raw.id)
  session.presetId = readString(raw.presetId)
  session.presetName = readString(raw.presetName)
  session.title = readString(raw.title)
  session.createdAt = readNumber(raw.createdAt)
  session.updatedAt = readNumber(raw.updatedAt)
  session.digest = readString(raw.digest)
  session.digestCoveredCount = readNumber(raw.digestCoveredCount)
  session.digestFingerprint = readString(raw.digestFingerprint)
  session.messages = []
  const rawMessages: AiSessionMessage[] = raw.messages
  if (rawMessages !== null && rawMessages !== undefined && Array.isArray(rawMessages)) {
    for (let i: number = 0; i < rawMessages.length; i++) {
      const item: AiSessionMessage = normalizeAiSessionMessage(rawMessages[i])
      /*
       * 空 role 表示这条消息不可用（协议字段缺失 / 角色非法），
       * 丢弃而不是带着坏数据进 UI。
       */
      if (item.role.length > 0) {
        session.messages.push(item)
      }
    }
  }
  return session
}

/**
 * 归一化单条消息。
 *
 * @param raw - 原始消息
 * @returns 归一化消息；角色非法时返回 `role` 为空的消息（由调用方丢弃）
 */
function normalizeAiSessionMessage(raw: AiSessionMessage): AiSessionMessage {
  const message: AiSessionMessage = new AiSessionMessage()
  message.role = ''
  if (raw === null || raw === undefined) {
    return message
  }
  const role: string = readString(raw.role)
  if (role !== AI_SESSION_ROLE_USER && role !== AI_SESSION_ROLE_ASSISTANT) {
    return message
  }
  message.role = role
  message.content = readString(raw.content)
  message.createdAt = readNumber(raw.createdAt)
  message.toolNotes = []
  const rawNotes: string[] = raw.toolNotes
  if (rawNotes !== null && rawNotes !== undefined && Array.isArray(rawNotes)) {
    for (let i: number = 0; i < rawNotes.length; i++) {
      const note: string = readString(rawNotes[i])
      if (note.length > 0 && message.toolNotes.length < MAX_AI_SESSION_TOOL_NOTES) {
        message.toolNotes.push(note)
      }
    }
  }
  return message
}

/**
 * 严格校验一条会话（缓存信封用：任一项不满足即整封信封判为非法）。
 *
 * @param value - 待校验对象
 * @returns 是否有效
 */
export function isValidAiSession(value: Object): boolean {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return false
  }
  const record: Record<string, Object> = value as Record<string, Object>
  if (typeof record['id'] !== 'string' || String(record['id']).length === 0) {
    return false
  }
  if (typeof record['title'] !== 'string') {
    return false
  }
  if (typeof record['presetId'] !== 'string') {
    return false
  }
  const rawMessages: Object | undefined = record['messages']
  if (!Array.isArray(rawMessages)) {
    return false
  }
  const messages: Object[] = rawMessages as Object[]
  for (let i: number = 0; i < messages.length; i++) {
    const item: Object = messages[i]
    if (!item || typeof item !== 'object' || Array.isArray(item)) {
      return false
    }
    const itemRecord: Record<string, Object> = item as Record<string, Object>
    const role: Object | undefined = itemRecord['role']
    if (role !== AI_SESSION_ROLE_USER && role !== AI_SESSION_ROLE_ASSISTANT) {
      return false
    }
    if (typeof itemRecord['content'] !== 'string') {
      return false
    }
  }
  return true
}

/**
 * 按最后更新时间倒序排序会话。
 *
 * @param sessions - 会话列表
 * @returns 新的已排序数组
 */
export function sortAiSessions(sessions: AiSession[]): AiSession[] {
  const sorted: AiSession[] = []
  for (let i: number = 0; i < sessions.length; i++) {
    sorted.push(sessions[i])
  }
  sorted.sort((a: AiSession, b: AiSession): number => b.updatedAt - a.updatedAt)
  return sorted
}

/**
 * 会话列表展示用的一行副标题（任务名 · 消息数）。
 *
 * @param session - 会话
 * @returns 副标题
 */
export function sessionSubtitle(session: AiSession): string {
  const task: string = session.presetName.length > 0 ? session.presetName : '自由对话'
  let turns: number = 0
  for (let i: number = 0; i < session.messages.length; i++) {
    if (session.messages[i].role === AI_SESSION_ROLE_USER) {
      turns++
    }
  }
  return task + ' · ' + turns.toString() + ' 轮'
}

/**
 * 会话时间展示文案（今天 / 昨天 / 具体日期）。
 *
 * @param timestamp - 毫秒时间戳
 * @returns 展示文案（无效时间返回空串）
 */
export function formatAiSessionTime(timestamp: number): string {
  if (timestamp <= 0) {
    return ''
  }
  const now: Date = new Date()
  const target: Date = new Date(timestamp)
  const hour: string = padTwo(target.getHours())
  const minute: string = padTwo(target.getMinutes())
  if (isSameDay(now, target)) {
    return '今天 ' + hour + ':' + minute
  }
  const yesterday: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1)
  if (isSameDay(yesterday, target)) {
    return '昨天 ' + hour + ':' + minute
  }
  if (now.getFullYear() === target.getFullYear()) {
    return (target.getMonth() + 1).toString() + '月' + target.getDate().toString() + '日'
  }
  return target.getFullYear().toString() + '年' +
    (target.getMonth() + 1).toString() + '月' + target.getDate().toString() + '日'
}

/**
 * 判断两个日期是否为同一天。
 *
 * @param a - 日期 A
 * @param b - 日期 B
 * @returns 是否同一天
 */
function isSameDay(a: Date, b: Date): boolean {
  return a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate()
}

/**
 * 两位补零。
 *
 * @param value - 数值
 * @returns 两位文本
 */
function padTwo(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString()
}

/**
 * 防御性读取字符串。
 *
 * @param value - 原始值
 * @returns 字符串
 */
function readString(value: string): string {
  return typeof value === 'string' ? value : ''
}

/**
 * 防御性读取数值。
 *
 * @param value - 原始值
 * @returns 有限数值，非法时返回 0
 */
function readNumber(value: number): number {
  if (typeof value !== 'number' || !isFinite(value)) {
    return 0
  }
  return value
}
