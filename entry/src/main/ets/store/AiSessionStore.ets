/**
 * AI 会话存储（情节记忆的持久化层）。
 *
 * 职责边界：
 * - **只管存取**：不做裁剪策略之外的业务判断（任务是否存在、气泡怎么渲染都在页面侧）；
 * - **按账号隔离**：复用 `CacheEnvelopeStore`（键 `ai_sessions_<uid>`），信封里带 uid 与
 *   结构版本，换账号读到上一个账号的信封会被判为非法，整体丢弃；
 * - **写盘延迟**：`putString(flush=false)` + `scheduleFlush`，与通知/动态缓存同一套节流，
 *   避免每轮对话都同步刷盘。
 *
 * 为什么不做「会话内的滑动窗口」：那是请求侧的事（`ContextBudget`）。这里只维持
 * 「单会话最多 N 条、单账号最多 M 个」两个硬上限，防止持久化体积无限膨胀。
 */

import { BaseStore } from './BaseStore'
import { CacheEnvelopeStore } from '../common/infra/CacheEnvelopeStore'
import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { Logger, DOMAIN_STORE, formatError } from '../common/utils/Logger'
import {
  AI_SESSION_ROLE_USER,
  AI_SESSION_SCHEMA_VERSION,
  AiSession,
  MAX_AI_SESSIONS,
  cloneAiSession,
  createAiSession,
  isValidAiSession,
  normalizeAiSession,
  sessionTitleFrom,
  sortAiSessions,
  trimAiSessionMessages
} from '../model/AiSession'
import type { AuthState } from './AuthStore'

/** 会话缓存键前缀（最终键形如 `ai_sessions_<uid>`）。 */
const AI_SESSION_KEY_PREFIX: string = 'ai_sessions'

const logger: Logger = new Logger(DOMAIN_STORE, 'AiSessionStore')

/**
 * AI 会话 Store。
 */
export class AiSessionStore extends BaseStore<Object> {
  /** BaseStore 状态占位对象（会话列表不走 @Observed 状态，页面通过方法读取）。 */
  override state: Object = new Object()

  /** 当前账号的会话列表（按最后更新倒序）。 */
  private sessions: AiSession[] = []

  /** 按账号隔离的信封工具（校验 / 加载 / 落盘统一封装）。 */
  private envelope: CacheEnvelopeStore<AiSession> = new CacheEnvelopeStore<AiSession>(
    AI_SESSION_SCHEMA_VERSION,
    AI_SESSION_KEY_PREFIX,
    (value: Object): boolean => isValidAiSession(value)
  )

  /**
   * 注入依赖并加载当前账号的会话。
   *
   * @param store - 偏好存储
   * @param queue - 串行写队列
   * @param auth - 当前认证状态
   */
  async init(store: PreferencesStore, queue: SerialQueue, auth: AuthState): Promise<void> {
    this.setDeps(store, queue, auth)
    this.sessions = []
    if (auth.uid) {
      await this.load(auth.uid)
    }
  }

  /**
   * 清空内存中的会话（登出 / 切号）。
   *
   * 磁盘上的记录**保留**：登出只是当前会话结束，重新登录同一账号应能看到之前的对话。
   * 另一个账号读到的是另一个键，且信封 uid 校验会拒绝错配。
   */
  reset(): void {
    this.sessions = []
    super.reset()
  }

  /**
   * 列出全部会话（按最后更新倒序，元素为副本）。
   *
   * @returns 会话数组副本
   */
  listSessions(): AiSession[] {
    const result: AiSession[] = []
    for (let i: number = 0; i < this.sessions.length; i++) {
      result.push(cloneAiSession(this.sessions[i]))
    }
    return result
  }

  /**
   * 按 ID 取单个会话的副本。
   *
   * @param id - 会话 ID
   * @returns 会话副本；不存在时返回 null
   */
  getSession(id: string): AiSession | null {
    for (let i: number = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id === id) {
        return cloneAiSession(this.sessions[i])
      }
    }
    return null
  }

  /**
   * 创建一条空白会话（只进内存，首次保存时才落盘）。
   *
   * @param presetId - 任务 ID（自由对话传空串）
   * @param presetName - 任务名称
   * @returns 新会话
   */
  createSession(presetId: string, presetName: string): AiSession {
    return createAiSession(presetId, presetName)
  }

  /**
   * 保存会话（不存在则插入，存在则整体覆盖）。
   *
   * 会补齐标题、裁剪消息数、按上限淘汰最旧会话，然后落盘。
   * 消息为空时视为"用户开了会话但没说话"，直接忽略（不产生空记录）。
   *
   * @param session - 待保存的会话
   */
  saveSession(session: AiSession): void {
    if (session.id.length === 0 || session.messages.length === 0) {
      return
    }
    session.messages = trimAiSessionMessages(session.messages)
    if (session.messages.length === 0) {
      return
    }
    if (session.title.length === 0) {
      session.title = firstUserQuestion(session)
    }
    session.updatedAt = Date.now()

    let replaced: boolean = false
    for (let i: number = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id === session.id) {
        /*
         * 存副本：页面会继续原地改自己那份 session（追加消息、改标题），
         * 直接存引用会让 store 的内存列表跟着"未保存的未来态"一起变。
         */
        this.sessions[i] = cloneAiSession(session)
        replaced = true
        break
      }
    }
    if (!replaced) {
      this.sessions.push(cloneAiSession(session))
    }
    this.sessions = sortAiSessions(this.sessions)
    if (this.sessions.length > MAX_AI_SESSIONS) {
      this.sessions = this.sessions.slice(0, MAX_AI_SESSIONS)
    }
    this.persist()
  }

  /**
   * 删除指定会话。
   *
   * @param id - 会话 ID
   */
  deleteSession(id: string): void {
    const kept: AiSession[] = []
    for (let i: number = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id !== id) {
        kept.push(this.sessions[i])
      }
    }
    if (kept.length === this.sessions.length) {
      return
    }
    this.sessions = kept
    this.persist()
  }

  /** 清空当前账号的全部会话记录。 */
  clearAllSessions(): void {
    if (this.sessions.length === 0) {
      return
    }
    this.sessions = []
    this.persist()
  }

  /**
   * 从磁盘加载当前账号的会话。
   *
   * @param uid - 当前账号 ID
   */
  private async load(uid: string): Promise<void> {
    try {
      const items: AiSession[] | null = await this.envelope.load(this.store, uid)
      if (items === null) {
        this.sessions = []
        return
      }
      const normalized: AiSession[] = []
      for (let i: number = 0; i < items.length; i++) {
        const session: AiSession = normalizeAiSession(items[i])
        /* 空 ID 的会话无法被打开也无法被删除，读到即丢弃 */
        if (session.id.length > 0) {
          normalized.push(session)
        }
      }
      this.sessions = sortAiSessions(normalized)
      if (this.sessions.length > MAX_AI_SESSIONS) {
        this.sessions = this.sessions.slice(0, MAX_AI_SESSIONS)
      }
      logger.info('loaded %{public}d ai sessions', this.sessions.length)
    } catch (e) {
      logger.warn('load failed: %{public}s', formatError(e))
      this.sessions = []
    }
  }

  /** 落盘当前会话列表（未登录时跳过：会话按账号隔离，没有账号就没有归属）。 */
  private persist(): void {
    const uid: string = this.auth ? this.auth.uid : ''
    if (uid.length === 0) {
      logger.verbose('skip persist ai sessions: no uid')
      return
    }
    this.envelope.persist(uid, this.sessions, this.store, this.writeQueue)
  }
}

/**
 * 取会话中第一条用户消息作为标题。
 *
 * @param session - 会话
 * @returns 标题（无用户消息时为空串）
 */
function firstUserQuestion(session: AiSession): string {
  for (let i: number = 0; i < session.messages.length; i++) {
    if (session.messages[i].role === AI_SESSION_ROLE_USER) {
      return sessionTitleFrom(session.messages[i].content)
    }
  }
  return ''
}
