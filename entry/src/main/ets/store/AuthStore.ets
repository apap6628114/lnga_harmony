import { BaseStore } from './BaseStore'
import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { sessionRegistry } from './SessionRegistry'
import type { Session } from './SessionRegistry'
import { RecoveryCredential, selectRecoveryCredential } from './SessionRecovery'

import { Logger, DOMAIN_STORE } from '../common/utils/Logger'
import { DomainIds, PersistenceCatalog } from '../common/persistence/PersistenceCatalog'
import { DomainSpec } from '../common/persistence/PersistenceTypes'

const logger = new Logger(DOMAIN_STORE, 'AuthStore')

/**
 * 返回凭证域的 Preferences 键（统一命名空间 `v2.auth`）。
 *
 * @returns 键名；域未登记时为空串
 */
function authKey(): string {
  const spec: DomainSpec | null = PersistenceCatalog.byId(DomainIds.AUTH)
  return spec === null ? '' : spec.fullKey()
}

/**
 * 返回多账号会话表域的 Preferences 键（统一命名空间 `v2.sessions`）。
 *
 * @returns 键名；域未登记时为空串
 */
function sessionsKey(): string {
  const spec: DomainSpec | null = PersistenceCatalog.byId(DomainIds.SESSIONS)
  return spec === null ? '' : spec.fullKey()
}

/**
 * 凭证的服务端确认状态。
 *
 * 与 `AuthState.isAuthenticated` 是**两个正交维度**，不可合并：
 * - `isAuthenticated` 表达「本地是否持有完整凭证」，全工程 30+ 处功能门禁
 *   （轮询启停 / 受控刷新 / 收藏 / 关注 / 通知 / AI 工具 / 阅读历史）读的是它。
 *   若把它改成「服务端已确认」，服务端一抖动这些功能会集体停摆，故障面反而被放大。
 * - `CredentialState` 只表达「服务端最近一次认不认这份凭证」，用于降级提示与写操作拦截。
 *
 * 降级**不清态、不跳页**：NGA 各接口的会话校验强度并不一致（`read.php` 弱于 `nuke.php`），
 * 服务端局部异常期间完全可能「帖子能读、iflogin 报失效」。因此单点判定只关闭"需要强确认"
 * 的能力，不否定整个登录态。
 */
export enum CredentialState {
  /** 本地凭证存在，且最近一次校验未被服务端拒绝（或尚未校验）。 */
  VALID = 0,
  /** 本地凭证仍在，但服务端已明确拒绝 —— 降级态。 */
  DEGRADED = 1,
}

/** 认证状态 */
@Observed
export class AuthState {
  token: string = ''
  uid: string = ''
  nickName: string = ''
  avatarUrl: string = ''
  isAuthenticated: boolean = false
  initialized: boolean = false
  /**
   * 凭证的服务端确认状态（见 {@link CredentialState}）。
   *
   * 纯内存态，不落盘：每次启动重新校验，避免陈旧结论挡住"服务端已恢复"。
   */
  credentialState: CredentialState = CredentialState.VALID
  /**
   * 本次启动是否从本地凭证重建了会话（供启动页提示一次）。
   *
   * 只表达"本地状态被修复"，**不代表**服务端会话仍有效——服务端有效性由
   * `AuthApi.checkSession` 的三态结论表达。读取方提示后应复位，避免重复提示。
   */
  sessionRestored: boolean = false
}

class PersistedAuth {
  token: string = ''
  uid: string = ''
  nickName: string = ''
  avatarUrl: string = ''
  /**
   * NGA 会话凭据（cid）的冗余副本。
   *
   * `sessions` 表按 token 索引保存 `uid/cid`，而 `auth` 只保存 token：一旦
   * `sessions` 丢失（清理、写盘失败、升级迁移），token 就会指向不存在的会话，
   * 登录态无法恢复。把 cid 冗余进 `auth` 后，`loadAuth` 可以在 token 悬空时
   * **原地重建**会话，避免"明明本地还留着有效凭证，却被迫重新登录"。
   *
   * 安全级别与 `sessions` 相同（同一 preferences 文件、同一目录），不新增暴露面。
   *
   * 可选字段：旧版本写入的 auth 记录没有该键，读取时按 `?? ''` 兼容。
   */
  cid?: string
}

/**
 * 认证状态与多账户登录会话管理
 */
export class AuthStore extends BaseStore<AuthState> {
  override state: AuthState = new AuthState()
  private sessionsDirty: boolean = false
  /** 最近一次持久化到 `auth` 记录的 cid（`PersistedAuth.cid` 的内存镜像）。 */
  private persistedCid: string = ''

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
    this.state.sessionRestored = false
    // 新会话一律从"未被拒绝"开始：旧账号的降级态不得跟到新账号上
    this.state.credentialState = CredentialState.VALID
    this.persistedCid = this.readSessionCid(token)
    this.persistAuth()
    // 登录态必须在返回前真正落盘：此前写入只 flush 于 500ms 后的定时器，
    // 登录成功后立刻杀进程/崩溃就会丢掉整份 auth（表现为"刚登录又要重登"）。
    await this.writeQueue.enqueue(async (): Promise<void> => {})
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
    this.state.sessionRestored = false
    // 已是"真未登录"，降级态失去意义；不复位会让下次登录前一直带着异常标记
    this.state.credentialState = CredentialState.VALID
    this.persistedCid = ''
    this.persistAuth()
  }

  /**
   * 持久化认证状态。
   *
   * @param immediate - 是否立即 flush（默认 true：登录态是"丢了就要用户重新输入"的
   *   数据，不接受掉电/杀进程的写入窗口；非关键更新才传 false 交给定时器合并）
   */
  private persistAuth(immediate: boolean = true): void {
    const key: string = authKey()
    if (key.length === 0) {
      return
    }
    const data = new PersistedAuth()
    data.token = this.state.token
    data.uid = this.state.uid
    data.nickName = this.state.nickName
    data.avatarUrl = this.state.avatarUrl
    data.cid = this.persistedCid
    this.writeQueue.enqueue(async (): Promise<void> => {
      await this.store.putJSON(key, data, immediate)
      if (!immediate) {
        this.store.scheduleFlush()
      }
    })
  }

  /**
   * 读取某个 token 对应的 cid（无会话时返回空串）。
   *
   * @param token - 应用会话令牌
   * @returns NGA cid；会话不存在时为空串
   */
  private readSessionCid(token: string): string {
    const session: Session | null = sessionRegistry.getSession(token)
    return session !== null ? session.cid : ''
  }

  private async loadAuth(): Promise<void> {
    const key: string = authKey()
    if (key.length === 0) {
      this.state.initialized = true
      return
    }
    const saved = await this.store.getJSON<PersistedAuth>(key)
    if (saved) {
      this.state.token = saved.token
      this.state.uid = saved.uid
      this.state.nickName = saved.nickName
      this.state.avatarUrl = saved.avatarUrl
      this.persistedCid = saved.cid ?? ''
      this.state.isAuthenticated = this.state.token !== ''
      if (this.state.isAuthenticated) {
        // token 可能悬空（sessions 丢失 / 旧版本只存了 auth）：先尝试本地重建，
        // 重建不成功才把登录态判为无效，避免"凭证还在却直接回登录页"。
        this.recoverSession()
      }
    }
    this.state.initialized = true
  }

  /**
   * 会话自愈：`auth` 有 token、但 `sessions` 里没有对应记录时，用本地仍留存的
   * uid/cid 原地重建会话（复用原 token，调用方持有的 token 不作废）。
   *
   * 只做**本地**重建，不访问网络：cid 是否仍被服务端接受，由启动校验
   * （`SessionGuard.verify` → `AuthApi.checkSession`）判断——这样"本地状态丢"与
   * "服务端会话失效"是两件事，前者可以无感修复，后者才需要用户重新登录。
   *
   * 凭据来源优先级：
   * 1. `auth` 记录内冗余的 `uid/cid`（新格式）；
   * 2. `sessions` 里同 uid 的其它会话（旧格式升级、token 换代残留）。
   */
  private recoverSession(): void {
    const token: string = this.state.token
    if (token === '') {
      this.state.isAuthenticated = false
      return
    }
    const existing: Session | null = sessionRegistry.getSession(token)
    if (existing !== null) {
      // cid 缺失（旧格式）时补写一次，让后续启动具备自愈能力
      if (this.persistedCid !== existing.cid) {
        this.persistedCid = existing.cid
        this.persistAuth(false)
      }
      return
    }

    // 候选来源交给纯函数裁决（uid 为空时拒绝猜测，见 SessionRecovery）
    const candidates: Session[] = []
    const tokens: string[] = sessionRegistry.getTokens()
    for (let i = 0; i < tokens.length; i++) {
      const candidate: Session | null = sessionRegistry.getSession(tokens[i])
      if (candidate !== null) {
        candidates.push(candidate)
      }
    }
    const credential: RecoveryCredential | null =
      selectRecoveryCredential(this.state.uid, this.persistedCid, candidates)
    if (credential === null) {
      // 没有任何可安全使用的本地凭据：token 已悬空，登录态判无效（启动页据此直接去登录页，
      // 不再发一次注定失败的校验请求）
      this.state.isAuthenticated = false
      logger.warn('auth token has no session and no local credential to recover')
      return
    }

    const session: Session = {
      uid: credential.uid,
      cid: credential.cid,
      nickName: this.state.nickName,
      avatarUrl: this.state.avatarUrl,
      createdAt: Date.now(),
    }
    sessionRegistry.setSession(token, session)
    this.state.uid = credential.uid
    this.state.isAuthenticated = true
    this.state.sessionRestored = true
    this.persistedCid = credential.cid
    this.sessionsDirty = true
    this.persistSessions(true)
    this.persistAuth()
    logger.info('session recovered from local credential')
  }


  // ============== Session ==============

  private async loadSessions(): Promise<void> {
    const key: string = sessionsKey()
    if (key.length === 0) {
      return
    }
    const saved = await this.store.getJSON<Array<Array<Object>>>(key)
    if (!saved) return
    for (let i = 0; i < saved.length; i++) {
      // 单条容错：坏条目（缺字段/结构被写坏）跳过即可，不能让整表解析失败——
      // 否则 authStore.init 抛错会让应用停在"初始化失败"，既不能自愈也回不到登录页。
      try {
        const entry = saved[i]
        const token = String(entry[0])
        const sessionObj = entry[1] as Record<string, Object>
        if (token.length === 0 || sessionObj === null || sessionObj === undefined) {
          continue
        }
        const session: Session = {
          uid: String(sessionObj['uid'] ?? ''),
          cid: String(sessionObj['cid'] ?? ''),
          nickName: String(sessionObj['nickName'] ?? ''),
          avatarUrl: String(sessionObj['avatarUrl'] ?? ''),
          createdAt: Number(sessionObj['createdAt'] ?? 0),
        }
        sessionRegistry.setSession(token, session)
      } catch (e) {
        logger.warn('跳过损坏的会话记录（index=%{public}d）', i)
      }
    }
    logger.info('Sessions loaded: %{public}d', sessionRegistry.getSize())
  }

  private persistSessions(immediate: boolean = false): void {
    if (!this.sessionsDirty) return
    this.sessionsDirty = false
    const key: string = sessionsKey()
    if (key.length === 0) {
      return
    }
    const entries: Array<Array<Object>> = []
    const keys: string[] = sessionRegistry.getTokens()
    for (const registryKey of keys) {
      const session: Session | null = sessionRegistry.getSession(registryKey)
      if (session) {
        entries.push([registryKey, session])
      }
    }
    this.writeQueue.enqueue(async (): Promise<void> => {
      await this.store.putJSON(key, entries, immediate)
    })
  }

  async createSession(uid: string, cid: string, nickName: string, avatarUrl: string): Promise<string> {
    const token = this.generateToken()
    const session: Session = { uid, cid, nickName, avatarUrl, createdAt: Date.now() }
    // 同一账号的历史会话（旧 token）不再被 auth 引用，登录时顺手回收，避免 sessions 无限增长。
    // 不再按时间清理会话：NGA 凭证没有"7 天有效期"，按创建时间到期会把仍有效的登录态误杀。
    const keys: string[] = sessionRegistry.getTokens()
    for (let i = 0; i < keys.length; i++) {
      const old: Session | null = sessionRegistry.getSession(keys[i])
      if (old !== null && old.uid === uid) {
        sessionRegistry.deleteSession(keys[i])
      }
    }
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
