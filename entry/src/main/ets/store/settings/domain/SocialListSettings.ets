import { fetchForumFavorites, syncForumFavorites } from '../../../service/api/FavoriteApi'
import { AuthScope } from '../../AuthScope'
import { FilterListManager } from '../../../common/utils/FilterListManager'
import { SettingsContext } from '../SettingsContext'
import { SettingsState } from '../SettingsState'
import { FavBoard } from '../../../model/SocialEntries'
import type { BlacklistEntry } from '../../../model/SocialEntries'
import type { ApiResult } from '../../../model/NgaApiResults'
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
 * 黑名单通过 FilterListManager 维护去重；收藏版块支持从服务端刷新
 * （forum_favor2/get）与写侧全量同步（favorforum/sync，官方模型 =
 * 本地整表 → 全量上传，乐观更新 + 失败回滚）。
 */
export class SocialListSettings {
  private ctx: SettingsContext
  private blacklistManager: FilterListManager<BlacklistEntry> = new FilterListManager<BlacklistEntry>()
  private favoritesLoaded: boolean = false
  /** 收藏版面同步是否在途（串行化：在途期间新变更仅标记 dirty，完成后再重放）。 */
  private favoritesSyncRunning: boolean = false
  /** 同步在途期间是否又发生本地变更（需要以最新整表重放一次）。 */
  private favoritesSyncDirty: boolean = false
  /** 最近一次本地变更前的整表快照（同步失败且本地未再变更时回滚到此状态）。 */
  private favoritesSyncBefore: FavBoard[] = []

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
    const scope: AuthScope = AuthScope.capture(this.ctx.auth, 0)
    try {
      const result = await fetchForumFavorites(this.ctx.auth!.token)
      // 请求期间可能已退出/切换账号：放弃回写，防止旧账号收藏写入新账号状态
      if (!scope.isCurrent(this.ctx.auth, 0)) {
        return
      }
      // 同步在途时跳过本次覆盖：本地已是用户最新操作（sync 完成后服务端
      // 已一致），避免旧服务端快照踩掉未落盘的本地变更
      if (this.favoritesSyncRunning || this.favoritesSyncDirty) {
        this.favoritesLoaded = true
        return
      }
      if (result.ok) {
        // 服务端为唯一真源（写侧已接 favorforum/sync）：无条件覆盖本地，
        // 含空列表（账号未收藏任何版面时清空本地残留）
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
    const before: FavBoard[] = this.ctx.state.favorites.slice()
    this.ctx.state.favorites = [...before, board]
    this.ctx.persist()
    bumpAppStorageVersion(KEY_FAV_VERSION)
    this.scheduleFavoritesSync(before)
  }

  removeFavorite(fid: number): void {
    const before: FavBoard[] = this.ctx.state.favorites.slice()
    this.ctx.state.favorites = before.filter(f => f.fid !== fid)
    this.ctx.persist()
    bumpAppStorageVersion(KEY_FAV_VERSION)
    this.scheduleFavoritesSync(before)
  }

  /**
   * 调度收藏版面全量同步（官方模型：本地整表 → favorforum/sync 上传）。
   *
   * 未登录时仅本地（与历史行为一致，登录后以服务端为准）。已登录时串行化
   * 执行：在途期间的新变更只标记 dirty，当前批次完成后以最新整表重放，
   * 避免并发请求乱序导致服务端收藏被旧整表覆盖。
   *
   * @param before - 本次本地变更前的整表快照（失败回滚基准）
   */
  private scheduleFavoritesSync(before: FavBoard[]): void {
    if (!this.ctx.auth || !this.ctx.auth.isAuthenticated) {
      return
    }
    this.favoritesSyncBefore = before
    if (this.favoritesSyncRunning) {
      this.favoritesSyncDirty = true
      return
    }
    this.favoritesSyncRunning = true
    this.runFavoritesSyncLoop()
  }

  private async runFavoritesSyncLoop(): Promise<void> {
    try {
      do {
        this.favoritesSyncDirty = false
        await this.syncFavoritesOnce()
      } while (this.favoritesSyncDirty && this.ctx.auth && this.ctx.auth.isAuthenticated)
    } finally {
      this.favoritesSyncRunning = false
    }
  }

  /**
   * 单次全量同步：捕获当前整表 → fidlist 逗号串上传 → 失败且本地未再变更
   * 时回滚到同步前快照。
   */
  private async syncFavoritesOnce(): Promise<void> {
    const auth = this.ctx.auth
    if (!auth || !auth.isAuthenticated) return
    const scope: AuthScope = AuthScope.capture(auth, 0)
    const snapshot: FavBoard[] = this.ctx.state.favorites.slice()
    const fidlist: string = snapshot.map(f => f.fid).join(',')
    const result: ApiResult = await syncForumFavorites(auth.token, fidlist)
    // 请求期间已退出/切换账号：放弃回写（本地可能已被 reset，回滚会污染新账号）
    if (!scope.isCurrent(this.ctx.auth, 0)) {
      return
    }
    if (!result.ok) {
      logger.warn('收藏版面同步失败: %{public}s', result.error)
      this.rollbackFavoritesIfUnchanged(snapshot)
    }
  }

  /**
   * 同步失败回滚：仅当本地列表与提交时一致（期间无新变更）才恢复为
   * 最近一次变更前的整表；本地已再变更时保留（由下一次同步重放最新整表，
   * 服务端最终一致）。
   *
   * @param snapshot - 本次同步提交时的整表快照
   */
  private rollbackFavoritesIfUnchanged(snapshot: FavBoard[]): void {
    if (!sameFidList(this.ctx.state.favorites, snapshot)) {
      return
    }
    this.ctx.state.favorites = this.favoritesSyncBefore.slice()
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

/**
 * 按 fid 序列比较两个收藏版面列表是否一致（顺序敏感，与整表同步语义一致）。
 *
 * @param left - 列表 A
 * @param right - 列表 B
 * @returns 是否完全一致
 */
function sameFidList(left: FavBoard[], right: FavBoard[]): boolean {
  if (left.length !== right.length) {
    return false
  }
  for (let i = 0; i < left.length; i++) {
    if (left[i].fid !== right[i].fid) {
      return false
    }
  }
  return true
}
