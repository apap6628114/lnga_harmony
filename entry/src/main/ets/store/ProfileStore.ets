import { getUserProfile } from '../service/api/UserApi'
import { LruCache } from '../common/cache/LruCache'
import { BaseStore } from './BaseStore'
import { AuthScope } from './AuthScope'
import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { KEY_PROFILE_VERSION } from '../common/constants/AppStorageKeys'
import { bumpAppStorageVersion } from '../common/utils/AppStorageVersion'
import type { ProfileData } from '../model/User'
import type { AuthState } from './AuthStore'

import { Logger, DOMAIN_STORE } from '../common/utils/Logger'
import { DomainIds, PersistenceCatalog } from '../common/persistence/PersistenceCatalog'
import { DomainSpec } from '../common/persistence/PersistenceTypes'

const logger = new Logger(DOMAIN_STORE, 'ProfileStore')

/**
 * 返回用户资料缓存域的 Preferences 键（统一命名空间 `v2.profiles`）。
 *
 * @returns 键名；域未登记时为空串
 */
function profilesDomainKey(): string {
  const spec: DomainSpec | null = PersistenceCatalog.byId(DomainIds.PROFILES)
  return spec === null ? '' : spec.fullKey()
}

/**
 * 用户资料 LRU 缓存管理（设备级：资料缓存与查看者账号无关，未登录也加载）
 */
export class ProfileStore extends BaseStore<Object> {
  override state: Object = new Object()
  private cache: LruCache<ProfileData> = new LruCache<ProfileData>(200, 5 * 60 * 1000)
  private refreshingUids: Set<string> = new Set()
  private static readonly REFRESH_DELAY: number = 10000

  async init(store: PreferencesStore, queue: SerialQueue, auth: AuthState): Promise<void> {
    this.setDeps(store, queue, auth)
    await this.loadCachedProfiles()
  }

  /** 重置缓存（登出时调用） */
  reset(): void {
    this.cache.clear()
    this.refreshingUids = new Set()
    super.reset()
  }

  // ============== Cache ==============

  private async loadCachedProfiles(): Promise<void> {
    const key: string = profilesDomainKey()
    if (key.length === 0) {
      return
    }
    const saved = await this.store.getJSON<Record<string, ProfileData>>(key)
    if (saved) {
      const keys = Object.keys(saved)
      for (let i = 0; i < keys.length; i++) {
        const val = saved[keys[i]]
        if (val) {
          this.cache.set(keys[i], val)
        }
      }
      logger.info('Loaded cached profiles: %{public}d', keys.length)
    }
  }

  private persistProfiles(): void {
    const key: string = profilesDomainKey()
    if (key.length === 0) {
      return
    }
    const snapshot: Record<string, ProfileData> = {}
    const keys: string[] = this.cache.keys()
    for (let i = 0; i < keys.length; i++) {
      const val = this.cache.get(keys[i])
      if (val) {
        snapshot[keys[i]] = val
      }
    }
    this.writeQueue.enqueue(async (): Promise<void> => {
      await this.store.putJSON(key, snapshot, false)
      this.store.scheduleFlush()
    })
  }

  getCachedProfile(uid: string): ProfileData | null {
    const result = this.cache.getWithStale(uid)
    if (result.value) {
      if (result.stale) {
        this.ensureProfile(uid)
      }
      return result.value
    }
    return null
  }

  /**
   * 使指定用户的资料缓存失效并持久化（关注状态变化后调用，
   * 保证下次进入主页/资料卡时重新拉取最新 follow 状态）。
   *
   * @param uid - 目标用户 ID
   */
  invalidateProfile(uid: string): void {
    this.cache.delete(uid)
    this.persistProfiles()
    bumpAppStorageVersion(KEY_PROFILE_VERSION)
  }

  ensureProfile(uid: string): void {
    if (this.refreshingUids.has(uid)) return
    this.refreshingUids.add(uid)
    const hasFreshCache: boolean = this.cache.isFresh(uid)
    const cachedProfile: ProfileData | undefined = this.cache.getWithStale(uid).value
    const cachedLikeCount: string = String(cachedProfile?.likeCount ?? '')
    const hasLikeCount: boolean = cachedLikeCount.length > 0
    setTimeout(async () => {
      await this.doRefreshProfile(uid)
      this.refreshingUids.delete(uid)
    }, hasFreshCache && hasLikeCount ? ProfileStore.REFRESH_DELAY : 0)
  }

  /**
   * 按需读取用户资料（供非 UI 调用方使用，例如 AI 工具）。
   *
   * 与 `getCachedProfile` 的差别：这里是 `await` 语义——新鲜缓存直接返回；
   * 过期或缺失时**同步等待一次刷新**，刷新失败则回退到过期值。
   * 目的是让"刚在资料卡看过的用户"不再被 AI 工具重复请求一次接口。
   *
   * @param uid - 目标用户 ID
   * @returns 资料；取不到时返回 null
   */
  async loadProfileForTool(uid: string): Promise<ProfileData | null> {
    if (uid.length === 0) return null
    if (this.cache.isFresh(uid)) {
      const fresh: ProfileData | undefined = this.cache.get(uid)
      if (fresh !== undefined) return fresh
    }
    const stale: ProfileData | undefined = this.cache.getWithStale(uid).value
    const refreshed: ProfileData | null = await this.doRefreshProfile(uid)
    if (refreshed !== null) return refreshed
    return stale !== undefined ? stale : null
  }

  private async doRefreshProfile(uid: string): Promise<ProfileData | null> {
    if (!this.auth.isAuthenticated) return null
    const scope: AuthScope = AuthScope.capture(this.auth, this.generationGuard.current())
    try {
      const result = await getUserProfile(this.auth.token, uid)
      // 请求期间会话可能已退出/切换：放弃回写，防止旧账号数据写入新账号缓存
      if (!scope.isCurrent(this.auth, this.generationGuard.current())) {
        return null
      }
      if (result.ok && result.data) {
        const newJson = JSON.stringify(result.data)
        const cachedResult = this.cache.getWithStale(uid)
        const oldJson = cachedResult.value ? JSON.stringify(cachedResult.value) : ''
        this.cache.set(uid, result.data)
        if (newJson !== oldJson) {
          bumpAppStorageVersion(KEY_PROFILE_VERSION)
          this.persistProfiles()
        }
        return result.data
      }
    } catch (e) {
      logger.error('refreshProfile failed for uid=%{public}s', uid)
    }
    return null
  }
}
