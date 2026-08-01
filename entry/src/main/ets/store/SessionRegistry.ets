/**
 * NGA 登录会话数据。
 */
export interface Session {
  /** NGA 用户 ID。 */
  uid: string
  /** NGA 登录凭据。 */
  cid: string
  /** 用户昵称。 */
  nickName: string
  /** 用户头像地址。 */
  avatarUrl: string
  /** 会话创建时间戳。 */
  createdAt: number
}

/**
 * 进程内登录会话注册表。
 *
 * 注册表不依赖 AppStore，使网络 API 能读取会话而不形成 Store 与 API 的循环依赖。
 */
export class SessionRegistry {
  /** 按应用令牌保存的 NGA 登录会话。 */
  private readonly sessions: Map<string, Session> = new Map<string, Session>()

  /**
   * 保存或替换登录会话。
   *
   * @param token - 应用会话令牌
   * @param session - NGA 登录会话
   */
  setSession(token: string, session: Session): void {
    this.sessions.set(token, session)
  }

  /**
   * 查找登录会话。
   *
   * @param token - 应用会话令牌
   * @returns 对应会话；令牌不存在时返回 null
   */
  getSession(token: string): Session | null {
    return this.sessions.get(token) ?? null
  }

  /**
   * 删除登录会话。
   *
   * @param token - 应用会话令牌
   * @returns 是否删除了已有会话
   */
  deleteSession(token: string): boolean {
    return this.sessions.delete(token)
  }

  /**
   * 返回全部应用会话令牌。
   *
   * @returns 独立令牌数组
   */
  getTokens(): string[] {
    return Array.from(this.sessions.keys())
  }

  /**
   * 返回当前会话数量。
   *
   * @returns 会话数量
   */
  getSize(): number {
    return this.sessions.size
  }
}

/** 全局进程内登录会话注册表。 */
export const sessionRegistry: SessionRegistry = new SessionRegistry()
