/**
 * AI 会话存储（情节记忆的持久化层）。
 *
 * 职责边界：
 * - **只管存取**：不做裁剪策略之外的业务判断（任务是否存在、气泡怎么渲染都在页面侧）；
 * - **设备级数据**：复用 `CacheEnvelopeStore`（键 `v2.ai_sessions`），取消账号物理隔离——
 *   本机会话是所有账号共享的情节记忆，信封内不再做 owner 校验；
 * - **写盘延迟**：`putString(flush=false)` + `scheduleFlush`，与通知/动态缓存同一套节流，
 *   避免每轮对话都同步刷盘。
 *
 * 为什么不做「会话内的滑动窗口」：那是请求侧的事（`ContextBudget`）。这里只维持
 * 「单会话最多 N 条、单设备最多 M 个」两个硬上限，防止持久化体积无限膨胀。
 */

import { BaseStore } from './BaseStore'
import { CacheEnvelopeStore } from '../common/infra/CacheEnvelopeStore'
import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { Logger, DOMAIN_STORE, formatError } from '../common/utils/Logger'
import { DomainIds } from '../common/persistence/PersistenceCatalog'
import {
  AI_SESSION_ROLE_USER,
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

const logger: Logger = new Logger(DOMAIN_STORE, 'AiSessionStore')

/**
 * AI 会话 Store。
 */
export class AiSessionStore extends BaseStore<Object> {
  /** BaseStore 状态占位对象（会话列表不走 @Observed 状态，页面通过方法读取）。 */
  override state: Object = new Object()

  /** 本机会话列表（按最后更新倒序）。 */
  private sessions: AiSession[] = []

  /** 设备级域信封工具（键与版本取自域注册表）。 */
  private envelope: CacheEnvelopeStore<AiSession> = new CacheEnvelopeStore<AiSession>(
    DomainIds.AI_SESSIONS,
    (value: Object): boolean => isValidAiSession(value)
  )

  /**
   * 注入依赖并加载本机会话（设备级，未登录也加载）。
   *
   * @param store - 偏好存储
   * @param queue - 串行写队列
   * @param auth - 当前认证状态
   */
  async init(store: PreferencesStore, queue: SerialQueue, auth: AuthState): Promise<void> {
    this.setDeps(store, queue, auth)
    this.sessions = []
    const generation: number = this.generationGuard.current()
    await this.load()
    /*
     * 加载期间 Store 可能已被 reset（登出/切号会推进代际）：代际不一致时整体丢弃，
     * 避免把过时读取结果带进新一轮状态。
     */
    if (!this.isCurrent(generation)) {
      this.sessions = []
    }
  }

  /**
   * 清空内存中的会话（登出 / 切号）。
   *
   * 磁盘上的记录**保留**：会话是设备级记忆，重新登录（任意账号）仍能看到之前的对话。
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
   * 设备级语义：不再校验会话/账号归属（旧版 `ownerUid` 仅作为历史字段保留，
   * 迁移器已把存量条目的该字段清空）。
   *
   * @param session - 待保存的会话
   */
  saveSession(session: AiSession): void {
    if (session.id.length === 0 || session.messages.length === 0) {
      return
    }
    const beforeCount: number = session.messages.length
    session.messages = trimAiSessionMessages(session.messages)
    if (session.messages.length === 0) {
      return
    }
    /*
     * 摘要游标必须跟着物理裁剪一起前移。
     *
     * `digestCoveredCount` 指的是「压缩记忆覆盖到历史的前多少条」。消息被
     * `MAX_AI_SESSION_MESSAGES` 从头部裁掉 k 条后，前缀整体前移，如果游标不跟着减，
     * 下一次压缩就会把"覆盖条数"算多，指纹校验必然失败 → 旧摘要被丢弃重压，
     * 而重压时被裁掉的那部分原文已经不在磁盘上——一次裁剪变成二次失忆。
     */
    const dropped: number = beforeCount - session.messages.length
    if (dropped > 0 && session.digestCoveredCount > 0) {
      session.digestCoveredCount = Math.max(0, session.digestCoveredCount - dropped)
    }
    if (session.digestCoveredCount > session.messages.length) {
      session.digestCoveredCount = session.messages.length
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

  /** 清空全部会话记录（设备级：清空本机全部对话）。 */
  clearAllSessions(): void {
    if (this.sessions.length === 0) {
      return
    }
    this.sessions = []
    this.persist()
  }

  /**
   * 从磁盘加载本机会话（设备级，与当前账号无关）。
   */
  private async load(): Promise<void> {
    try {
      /*
       * 宽容加载：一条坏会话不应该让其余 19 条一起消失（严格信封会让
       * 整封判非法，下一次 persist 再把空列表写回，数据永久丢失）。
       * 信封级非法（结构/items 非数组）仍返回 null。
       */
      const items: AiSession[] | null = await this.envelope.loadTolerant(this.store, this.auth ? this.auth.uid : '')
      if (items === null) {
        this.sessions = []
        return
      }
      const normalized: AiSession[] = []
      for (let i: number = 0; i < items.length; i++) {
        const session: AiSession = normalizeAiSession(items[i])
        /* 空 ID 的会话无法被打开也无法被删除，读到即丢弃 */
        if (session.id.length > 0) {
          if (session.digestCoveredCount > session.messages.length) {
            session.digestCoveredCount = session.messages.length
          }
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

  /** 落盘会话列表（设备级：未登录也可写）。 */
  private persist(): void {
    this.envelope.persist(this.auth ? this.auth.uid : '', this.sessions, this.store, this.writeQueue)
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
