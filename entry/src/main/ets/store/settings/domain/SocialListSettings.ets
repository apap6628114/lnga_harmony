import { fetchForumFavorites } from '../../../service/api/FavoriteApi'
import { FilterListManager } from '../../../common/utils/FilterListManager'
import { SettingsContext } from '../SettingsContext'
import { SettingsState } from '../SettingsState'
import { FavBoard } from '../../../model/SocialEntries'
import type { BlacklistEntry } from '../../../model/SocialEntries'
import { KEY_BLACKLIST_VERSION, KEY_FAV_VERSION } from '../../../common/constants/AppStorageKeys'
import { bumpAppStorageVersion } from '../../../common/utils/AppStorageVersion'
import {
  areBlacklistEntriesEqual,
  normalizeBlacklistEntries,
  normalizeBlacklistUserId
} from '../../../common/utils/BlacklistUtils'

import { Logger, DOMAIN_SETTINGS } from '../../../common/utils/Logger'

const logger = new Logger(DOMAIN_SETTINGS, 'SocialListSettings')
const REFRESH_DELAY: number = 10000

/**
 * 社交列表设置域子 store。
 *
 * 承载黑名单（BlacklistEntry）与收藏版块（FavBoard）字段及其增删查逻辑。
 * 黑名单通过 FilterListManager 维护去重，收藏版块支持从服务端刷新。
 */
export class SocialListSettings {
  private ctx: SettingsContext
  private blacklistManager: FilterListManager<BlacklistEntry> = new FilterListManager<BlacklistEntry>()
  private favoritesLoaded: boolean = false

  constructor(ctx: SettingsContext) {
    this.ctx = ctx
  }

  // ============== Blacklist ==============

  /**
   * 添加黑名单用户。
   *
   * @param entry - 待添加的用户条目
   * @returns 是否实际新增
   */
  addBlacklist(entry: BlacklistEntry): boolean {
    const normalizedUserId: string | null = normalizeBlacklistUserId(entry.userId)
    const currentUserId: string | null = normalizeBlacklistUserId(this.ctx.auth?.uid ?? '')
    if (normalizedUserId === null || normalizedUserId === currentUserId ||
      this.ctx.state.blacklist.some((item: BlacklistEntry): boolean => item.userId === normalizedUserId)) {
      return false
    }
    const normalizedEntry: BlacklistEntry = {
      userId: normalizedUserId,
      nickName: entry.nickName.trim() || `User${normalizedUserId}`,
    }
    this.ctx.state.blacklist = this.blacklistManager.add(normalizedEntry)
    this.ctx.persist()
    bumpAppStorageVersion(KEY_BLACKLIST_VERSION)
    return true
  }

  /**
   * 移除指定黑名单用户。
   *
   * @param userId - 待移除的用户 UID
   * @returns 是否实际移除
   */
  removeBlacklist(userId: string): boolean {
    const normalizedUserId: string | null = normalizeBlacklistUserId(userId)
    if (normalizedUserId === null ||
      !this.ctx.state.blacklist.some((item: BlacklistEntry): boolean => item.userId === normalizedUserId)) {
      return false
    }
    this.ctx.state.blacklist = this.blacklistManager.remove(
      (item: BlacklistEntry): boolean => item.userId === normalizedUserId)
    this.ctx.persist()
    bumpAppStorageVersion(KEY_BLACKLIST_VERSION)
    return true
  }

  /**
   * 清空黑名单。
   *
   * @returns 是否实际清除了条目
   */
  removeAllBlacklist(): boolean {
    if (this.ctx.state.blacklist.length === 0) {
      return false
    }
    this.ctx.state.blacklist = this.blacklistManager.clear()
    this.ctx.persist()
    bumpAppStorageVersion(KEY_BLACKLIST_VERSION)
    return true
  }

  /**
   * 获取当前黑名单 UID 集合。
   *
   * @returns 黑名单 UID 集合
   */
  getBlacklistIds(): Set<string> {
    const ids = new Set<string>()
    for (let i = 0; i < this.ctx.state.blacklist.length; i++) {
      ids.add(this.ctx.state.blacklist[i].userId)
    }
    return ids
  }

  /**
   * 判断用户是否在黑名单中。
   *
   * @param userId - 待判断的用户 UID
   * @returns 是否已被加入黑名单
   */
  isBlacklisted(userId: string): boolean {
    const normalizedUserId: string | null = normalizeBlacklistUserId(userId)
    return normalizedUserId !== null &&
      this.ctx.state.blacklist.some((item: BlacklistEntry): boolean => item.userId === normalizedUserId)
  }

  /**
   * 获取用于请求头的黑名单 UID 字符串。
   *
   * @returns 逗号分隔的 UID 字符串
   */
  getBlacklistHeaderString(): string {
    return this.ctx.state.blacklist.map(u => u.userId).join(',')
  }

  // ============== Favorites ==============

  ensureFavorites(): void {
    if (this.favoritesLoaded || !this.ctx.auth!.isAuthenticated) return
    const hasCache = this.ctx.state.favorites.length > 0
    if (hasCache) {
      this.favoritesLoaded = true
    }
    setTimeout(async () => {
      await this.doRefreshFavorites()
    }, hasCache ? REFRESH_DELAY : 0)
  }

  private async doRefreshFavorites(): Promise<void> {
    if (!this.ctx.auth!.isAuthenticated) return
    try {
      const result = await fetchForumFavorites(this.ctx.auth!.token)
      if (result.ok && result.data.length > 0) {
        const favs: FavBoard[] = []
        for (let i = 0; i < result.data.length; i++) {
          const item = result.data[i]
          const fb = new FavBoard()
          fb.fid = item.fid
          fb.stid = item.stid
          fb.name = item.name
          favs.push(fb)
        }
        this.ctx.state.favorites = favs
        this.ctx.persist()
        bumpAppStorageVersion(KEY_FAV_VERSION)
      }
      this.favoritesLoaded = true
    } catch (e) {
      logger.error('fetchFavorites failed')
    }
  }

  addFavorite(board: FavBoard): void {
    this.ctx.state.favorites = [...this.ctx.state.favorites, board]
    this.ctx.persist()
    bumpAppStorageVersion(KEY_FAV_VERSION)
  }

  removeFavorite(fid: number): void {
    this.ctx.state.favorites = this.ctx.state.favorites.filter(f => f.fid !== fid)
    this.ctx.persist()
    bumpAppStorageVersion(KEY_FAV_VERSION)
  }

  // ============== Lifecycle ==============

  /** 从持久化对象加载黑名单与收藏（黑名单需要回填 FilterListManager） */
  load(saved: SettingsState): void {
    if (saved.favorites) this.ctx.state.favorites = saved.favorites
    if (saved.blacklist) {
      const normalizedBlacklist: BlacklistEntry[] =
        normalizeBlacklistEntries(saved.blacklist, this.ctx.auth?.uid ?? '')
      this.ctx.state.blacklist = normalizedBlacklist
      this.blacklistManager.init(normalizedBlacklist)
      if (!areBlacklistEntriesEqual(normalizedBlacklist, saved.blacklist)) {
        this.ctx.persist()
      }
    }
  }

  /** 重置黑名单与收藏到默认（清空 manager、加载标志位） */
  reset(): void {
    this.blacklistManager = new FilterListManager<BlacklistEntry>()
    this.favoritesLoaded = false
  }
}
