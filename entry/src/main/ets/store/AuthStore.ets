import { BaseStore } from './BaseStore'
import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { sessionRegistry } from './SessionRegistry'
import type { Session } from './SessionRegistry'

import { Logger, DOMAIN_STORE } from '../common/utils/Logger'

const logger = new Logger(DOMAIN_STORE, 'AuthStore')

/** 认证状态 */
@Observed
export class AuthState {
  token: string = ''
  uid: string = ''
  nickName: string = ''
  avatarUrl: string = ''
  isAuthenticated: boolean = false
  initialized: boolean = false
}

class PersistedAuth {
  token: string = ''
  uid: string = ''
  nickName: string = ''
  avatarUrl: string = ''
}

const SESSION_MAX_AGE: number = 7 * 24 * 3600 * 1000
const SESSION_KEY: string = 'sessions'

/**
 * 认证状态与多账户登录会话管理
 */
export class AuthStore extends BaseStore<AuthState> {
  override state: AuthState = new AuthState()
  private sessionsDirty: boolean = false

  async init(store: PreferencesStore, queue: SerialQueue): Promise<void> {
    this.setDeps(store, queue)
    await this.loadSessions()
    await this.loadAuth()
  }

  // ============== Auth ==============

  async setAuth(token: string, uid: string, nickName: string, avatarUrl: string): Promise<boolean> {
    const uidChanged = this.state.uid !== uid
    this.state.token = token
    this.state.uid = uid
    this.state.nickName = nickName
    this.state.avatarUrl = avatarUrl
    this.state.isAuthenticated = true
    this.state.initialized = true
    this.persistAuth()
    return uidChanged
  }

  clearAuth(): void {
    if (this.state.token) {
      sessionRegistry.deleteSession(this.state.token)
      this.sessionsDirty = true
      this.persistSessions(true)
    }
    this.state.token = ''
    this.state.uid = ''
    this.state.nickName = ''
    this.state.avatarUrl = ''
    this.state.isAuthenticated = false
    this.state.initialized = true
    this.persistAuth()
  }

  private persistAuth(): void {
    const data = new PersistedAuth()
    data.token = this.state.token
    data.uid = this.state.uid
    data.nickName = this.state.nickName
    data.avatarUrl = this.state.avatarUrl
    this.writeQueue.enqueue(async (): Promise<void> => {
      await this.store.putJSON('auth', data, false)
      this.store.scheduleFlush()
    })
  }

  private async loadAuth(): Promise<void> {
    const saved = await this.store.getJSON<PersistedAuth>('auth')
    if (saved) {
      this.state.token = saved.token
      this.state.uid = saved.uid
      this.state.nickName = saved.nickName
      this.state.avatarUrl = saved.avatarUrl
      this.state.isAuthenticated = this.state.token !== ''
    }
    this.state.initialized = true
  }


  // ============== Session ==============

  private async loadSessions(): Promise<void> {
    const saved = await this.store.getJSON<Array<Array<Object>>>(SESSION_KEY)
    if (!saved) return
    for (let i = 0; i < saved.length; i++) {
      const entry = saved[i]
      const token = String(entry[0])
      const sessionObj = entry[1] as Record<string, Object>
      const session: Session = {
        uid: String(sessionObj['uid'] ?? ''),
        cid: String(sessionObj['cid'] ?? ''),
        nickName: String(sessionObj['nickName'] ?? ''),
        avatarUrl: String(sessionObj['avatarUrl'] ?? ''),
        createdAt: Number(sessionObj['createdAt'] ?? 0),
      }
      sessionRegistry.setSession(token, session)
    }
    this.cleanupSessions()
    logger.info('Sessions loaded: %{public}d', sessionRegistry.getSize())
  }

  private persistSessions(immediate: boolean = false): void {
    if (!this.sessionsDirty) return
    this.sessionsDirty = false
    const entries: Array<Array<Object>> = []
    const keys: string[] = sessionRegistry.getTokens()
    for (const key of keys) {
      const session: Session | null = sessionRegistry.getSession(key)
      if (session) {
        entries.push([key, session])
      }
    }
    this.writeQueue.enqueue(async (): Promise<void> => {
      await this.store.putJSON(SESSION_KEY, entries, immediate)
    })
  }

  async createSession(uid: string, cid: string, nickName: string, avatarUrl: string): Promise<string> {
    const token = this.generateToken()
    const session: Session = { uid, cid, nickName, avatarUrl, createdAt: Date.now() }
    sessionRegistry.setSession(token, session)
    this.sessionsDirty = true
    this.persistSessions(true)
    return token
  }

  getSession(token: string): Session | null {
    return sessionRegistry.getSession(token)
  }

  async updateSession(token: string, nickName?: string, avatarUrl?: string): Promise<void> {
    const session: Session | null = sessionRegistry.getSession(token)
    if (!session) return
    if (nickName !== undefined) session.nickName = nickName
    if (avatarUrl !== undefined) session.avatarUrl = avatarUrl
    this.sessionsDirty = true
    this.persistSessions()
  }

  async destroySession(token: string): Promise<void> {
    if (sessionRegistry.deleteSession(token)) {
      this.sessionsDirty = true
      this.persistSessions(true)
    }
  }

  private cleanupSessions(): void {
    const now = Date.now()
    let changed = false
    const keys: string[] = sessionRegistry.getTokens()
    for (const token of keys) {
      const session: Session | null = sessionRegistry.getSession(token)
      if (session === null) {
        continue
      }
      if (now - session.createdAt > SESSION_MAX_AGE) {
        sessionRegistry.deleteSession(token)
        changed = true
      }
    }
    if (changed) {
      this.sessionsDirty = true
    }
  }

  private generateToken(): string {
    const chars = '0123456789abcdef'
    let result = ''
    for (let i = 0; i < 64; i++) {
      result += chars.charAt(Math.floor(Math.random() * chars.length))
    }
    return result
  }

  /** 重置认证状态（登出时调用） */
  reset(): void {
    this.clearAuth()
    super.reset()
  }
}
