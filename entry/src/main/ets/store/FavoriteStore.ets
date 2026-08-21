import { BaseStore } from './BaseStore'
import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { bumpAppStorageVersion } from '../common/utils/AppStorageVersion'
import {
  KEY_FAVORITE_FOLDER_VERSION,
  KEY_FAVORITE_TOPIC_VERSION
} from '../common/constants/AppStorageKeys'
import {
  createFavoriteTopicFolder,
  deleteFavoriteTopicFolder,
  fetchFavoriteTopicFolders,
  mutateTopicFavorite,
  renameFavoriteTopicFolder,
  setDefaultFavoriteTopicFolder
} from '../service/api/FavoriteApi'
import {
  FavoriteMembershipState,
  FavoriteTopicFolder,
  TopicFavoriteOperation
} from '../model/Favorite'
import { ApiResult, FavoriteFolderListResult, TopicFavoriteResult } from '../model/NgaApiResults'
import type { AuthState } from './AuthStore'
import { Logger, DOMAIN_STORE, formatError } from '../common/utils/Logger'
import { AuthScope } from './AuthScope'

/**
 * 收藏系统日志实例。
 */
const logger: Logger = new Logger(DOMAIN_STORE, 'FavoriteStore')

/**
 * 收藏关系缓存结构版本。
 */
const FAVORITE_MEMBERSHIP_CACHE_SCHEMA_VERSION: number = 1

/**
 * 收藏关系缓存键前缀。
 */
const FAVORITE_MEMBERSHIP_CACHE_KEY_PREFIX: string = 'favorite_topic_membership_v1_'

/**
 * 账号级收藏关系提示缓存。
 */
class FavoriteMembershipCacheEnvelope {
  /**
   * 缓存结构版本。
   */
  schemaVersion: number = FAVORITE_MEMBERSHIP_CACHE_SCHEMA_VERSION
  /**
   * 缓存所属 NGA 用户 ID。
   */
  uid: string = ''
  /**
   * 每个主题已确认收藏的收藏夹 ID。
   */
  favoredFolderIds: Record<string, string[]> = {}
  /**
   * 每个主题已确认状态的收藏夹 ID。
   */
  knownFolderIds: Record<string, string[]> = {}
}

/**
 * 克隆收藏夹，避免页面直接持有 Store 内部对象。
 *
 * @param source - 待克隆收藏夹
 * @returns 独立收藏夹对象
 */
function cloneFavoriteFolder(source: FavoriteTopicFolder): FavoriteTopicFolder {
  const folder: FavoriteTopicFolder = new FavoriteTopicFolder()
  folder.id = source.id
  folder.name = source.name
  folder.topicCount = source.topicCount
  folder.isDefault = source.isDefault
  return folder
}

/**
 * NGA 账号级主题收藏夹与轻量成员关系提示缓存。
 */
export class FavoriteStore extends BaseStore<Object> {
  /**
   * BaseStore 状态占位对象。
   */
  override state: Object = new Object()
  /**
   * 当前账号的服务端收藏夹快照。
   */
  private folders: FavoriteTopicFolder[] = []
  /**
   * 主题到收藏夹已知成员状态映射，缺少条目表示未知。
   */
  private topicFolderStates: Map<string, Map<string, boolean>> = new Map<string, Map<string, boolean>>()
  /**
   * 当前正在执行的主题收藏关系操作键。
   */
  private pendingTopicMutations: Set<string> = new Set<string>()
  /**
   * 各收藏夹已确认服务端 mutation 的运行期版本。
   */
  private folderMutationVersions: Map<string, number> = new Map<string, number>()
  /**
   * 当前收藏夹刷新任务。
   */
  private refreshPromise: Promise<boolean> | null = null
  /**
   * 当前刷新结束后是否还需执行一轮强制刷新。
   */
  private refreshAfterCurrent: boolean = false
  /**
   * 是否已经成功加载过收藏夹列表。
   */
  foldersLoaded: boolean = false
  /**
   * 是否正在加载收藏夹列表。
   */
  foldersLoading: boolean = false
  /**
   * 最近一次收藏夹操作错误。
   */
  error: string = ''

  /**
   * 注入持久化、写队列和认证依赖。
   *
   * 收藏夹与收藏关系仍以 NGA 服务端为准；本地仅保存无法直接查询的关系提示。
   *
   * @param store - 应用偏好存储
   * @param queue - 应用串行写队列
   * @param auth - 当前认证状态
   */
  async init(store: PreferencesStore, queue: SerialQueue, auth: AuthState): Promise<void> {
    this.generationGuard.bump()
    this.setDeps(store, queue, auth)
    this.resetMemoryState()
    if (auth.uid.length > 0) {
      await this.loadMembershipCache(auth.uid)
    }
  }

  /**
   * 清空账号相关收藏状态。
   */
  reset(): void {
    this.resetMemoryState()
    this.publishFolderState()
    this.publishTopicState()
    super.reset()
  }

  /**
   * 返回当前收藏夹快照。
   *
   * @returns 默认收藏夹优先的独立对象列表
   */
  getFolders(): FavoriteTopicFolder[] {
    const result: FavoriteTopicFolder[] = []
    for (let i = 0; i < this.folders.length; i++) {
      result.push(cloneFavoriteFolder(this.folders[i]))
    }
    return result
  }

  /**
   * 返回默认收藏夹。
   *
   * @returns 默认收藏夹；尚未加载或不存在时返回 null
   */
  getDefaultFolder(): FavoriteTopicFolder | null {
    for (let i = 0; i < this.folders.length; i++) {
      if (this.folders[i].isDefault) {
        return cloneFavoriteFolder(this.folders[i])
      }
    }
    return null
  }

  /**
   * 获取主题当前已知的收藏夹 ID。
   *
   * @param topicId - NGA 主题 ID
   * @returns 收藏夹 ID 列表
   */
  getTopicFolderIds(topicId: string): string[] {
    const states: Map<string, boolean> | undefined = this.topicFolderStates.get(topicId)
    if (states === undefined) {
      return []
    }
    const ids: string[] = []
    states.forEach((favored: boolean, folderId: string): void => {
      if (favored) {
        ids.push(folderId)
      }
    })
    return ids
  }

  /**
   * 获取主题在任意收藏夹中的可信状态。
   *
   * @param topicId - NGA 主题 ID
   * @returns 已收藏、未收藏或未知
   */
  getTopicFavoriteState(topicId: string): FavoriteMembershipState {
    const states: Map<string, boolean> | undefined = this.topicFolderStates.get(topicId)
    if (states !== undefined) {
      const values: boolean[] = Array.from(states.values())
      for (let i = 0; i < values.length; i++) {
        if (values[i]) {
          return FavoriteMembershipState.FAVORED
        }
      }
    }
    if (!this.foldersLoaded) {
      return FavoriteMembershipState.UNKNOWN
    }
    for (let i = 0; i < this.folders.length; i++) {
      if (states?.has(this.folders[i].id) !== true) {
        return FavoriteMembershipState.UNKNOWN
      }
    }
    return FavoriteMembershipState.NOT_FAVORED
  }

  /**
   * 判断主题是否位于任意已知收藏夹。
   *
   * @param topicId - NGA 主题 ID
   * @returns 是否已知为收藏状态
   */
  isTopicFavored(topicId: string): boolean {
    return this.getTopicFavoriteState(topicId) === FavoriteMembershipState.FAVORED
  }

  /**
   * 获取主题在指定收藏夹中的可信状态。
   *
   * @param topicId - NGA 主题 ID
   * @param folderId - 收藏夹服务端 ID
   * @returns 已收藏、未收藏或未知
   */
  getTopicFolderState(topicId: string, folderId: string): FavoriteMembershipState {
    const resolvedFolderId: string = this.resolveFolderId(folderId)
    const favored: boolean | undefined = this.topicFolderStates.get(topicId)?.get(resolvedFolderId)
    if (favored === undefined) {
      return FavoriteMembershipState.UNKNOWN
    }
    return favored ? FavoriteMembershipState.FAVORED : FavoriteMembershipState.NOT_FAVORED
  }

  /**
   * 判断主题是否位于指定收藏夹。
   *
   * @param topicId - NGA 主题 ID
   * @param folderId - 收藏夹服务端 ID
   * @returns 是否已知属于该收藏夹
   */
  isTopicInFolder(topicId: string, folderId: string): boolean {
    return this.getTopicFolderState(topicId, folderId) === FavoriteMembershipState.FAVORED
  }

  /**
   * 判断主题与收藏夹的关系是否正在修改。
   *
   * @param topicId - NGA 主题 ID
   * @param folderId - 收藏夹服务端 ID
   * @returns 是否正在请求
   */
  isTopicMutationPending(topicId: string, folderId: string): boolean {
    return this.pendingTopicMutations.has(this.topicMutationKey(topicId, folderId))
  }

  /**
   * 获取指定收藏夹最近一次服务端收藏操作版本。
   *
   * @param folderId - 收藏夹服务端 ID 或默认收藏夹别名
   * @returns 当前运行期 mutation 版本
   */
  getFolderMutationVersion(folderId: string): number {
    return this.folderMutationVersions.get(this.resolveFolderId(folderId)) ?? 0
  }

  /**
   * 确保收藏夹列表至少成功加载一次。
   *
   * @returns 是否存在可用的收藏夹列表响应
   */
  async ensureFolders(): Promise<boolean> {
    return this.refreshFolders(false)
  }

  /**
   * 从 NGA 服务端刷新收藏夹列表。
   *
   * @param force - 是否忽略已加载状态强制刷新
   * @returns 刷新是否成功
   */
  async refreshFolders(force: boolean = true): Promise<boolean> {
    if (!this.auth || !this.auth.isAuthenticated || this.auth.uid.length === 0) {
      this.error = '未登录'
      this.publishFolderState()
      return false
    }
    if (!force && this.foldersLoaded) {
      return true
    }
    if (this.refreshPromise !== null) {
      if (force) {
        this.refreshAfterCurrent = true
      }
      return await this.refreshPromise
    }

    const scope: AuthScope = AuthScope.capture(this.auth, this.generationGuard.current())
    const requestToken: string = this.auth.token
    this.foldersLoading = true
    this.publishFolderState()
    this.refreshAfterCurrent = false
    const task: Promise<boolean> = this.performFolderRefreshLoop(scope, requestToken)
    this.refreshPromise = task
    try {
      return await task
    } finally {
      if (this.refreshPromise === task) {
        this.refreshPromise = null
      }
      if (scope.isCurrent(this.auth, this.generationGuard.current())) {
        this.foldersLoading = false
        this.publishFolderState()
      }
    }
  }

  /**
   * 新建收藏夹并同步服务端最新列表。
   *
   * @param name - 收藏夹名称
   * @param setDefault - 是否设为默认收藏夹
   * @returns 新收藏夹；失败时返回 null
   */
  async createFolder(name: string, setDefault: boolean = false): Promise<FavoriteTopicFolder | null> {
    if (!this.auth || !this.auth.isAuthenticated) {
      this.error = '未登录'
      return null
    }
    const scope: AuthScope = AuthScope.capture(this.auth, this.generationGuard.current())
    const requestToken: string = this.auth.token
    const result = await createFavoriteTopicFolder(requestToken, name, setDefault)
    if (!scope.isCurrent(this.auth, this.generationGuard.current())) {
      return null
    }
    if (!result.ok) {
      this.error = result.error || '新建收藏夹失败'
      this.publishFolderState()
      return null
    }

    const created: FavoriteTopicFolder = new FavoriteTopicFolder()
    created.id = result.folderId
    created.name = name.trim()
    created.isDefault = setDefault
    if (setDefault) {
      for (let i = 0; i < this.folders.length; i++) {
        this.folders[i].isDefault = false
      }
    }
    this.folders.push(created)
    this.sortFolders()
    this.error = ''
    this.publishFolderState()
    await this.refreshFolders(true)
    if (!scope.isCurrent(this.auth, this.generationGuard.current())) {
      return null
    }
    const refreshed: FavoriteTopicFolder | null = this.findFolder(created.id)
    return refreshed ?? cloneFavoriteFolder(created)
  }

  /**
   * 重命名收藏夹。
   *
   * @param folderId - 收藏夹服务端 ID
   * @param name - 新名称
   * @returns 操作结果
   */
  async renameFolder(folderId: string, name: string): Promise<ApiResult> {
    if (!this.auth || !this.auth.isAuthenticated) {
      const unavailable: ApiResult = new ApiResult()
      unavailable.error = '未登录'
      return unavailable
    }
    const scope: AuthScope = AuthScope.capture(this.auth, this.generationGuard.current())
    const requestToken: string = this.auth.token
    // 服务端 modify_folder 缺省 opt 会「设为默认」（实测），重命名必须显式携带
    // opt 保持默认状态意图：当前为默认夹 → 传 "0"（设为默认），否则传 "1"（不设）
    const currentFolder: FavoriteTopicFolder | null = this.findFolderReference(folderId)
    const result: ApiResult = await renameFavoriteTopicFolder(requestToken, folderId, name,
      currentFolder?.isDefault ?? false)
    if (!scope.isCurrent(this.auth, this.generationGuard.current())) {
      result.ok = false
      result.error = '登录状态已变更'
      return result
    }
    if (result.ok) {
      const folder: FavoriteTopicFolder | null = this.findFolderReference(folderId)
      if (folder !== null) {
        folder.name = name.trim()
      }
      this.error = ''
      this.publishFolderState()
      await this.refreshFolders(true)
      if (!scope.isCurrent(this.auth, this.generationGuard.current())) {
        result.ok = false
        result.error = '登录状态已变更'
      }
    } else {
      this.error = result.error || '重命名收藏夹失败'
      this.publishFolderState()
    }
    return result
  }

  /**
   * 设置账号默认收藏夹。
   *
   * @param folderId - 收藏夹服务端 ID
   * @returns 操作结果
   */
  async setDefaultFolder(folderId: string): Promise<ApiResult> {
    if (!this.auth || !this.auth.isAuthenticated) {
      const unavailable: ApiResult = new ApiResult()
      unavailable.error = '未登录'
      return unavailable
    }
    const scope: AuthScope = AuthScope.capture(this.auth, this.generationGuard.current())
    const requestToken: string = this.auth.token
    // 服务端 modify_folder 的 name 必填（实测缺 name 时默认状态异常），
    // 由快照提供当前夹名；快照缺失时防御性返回错误
    const currentFolder: FavoriteTopicFolder | null = this.findFolderReference(folderId)
    if (currentFolder === null || currentFolder.name.length === 0) {
      const unavailable: ApiResult = new ApiResult()
      unavailable.error = '无法确定收藏夹名称'
      return unavailable
    }
    const result: ApiResult = await setDefaultFavoriteTopicFolder(requestToken, folderId,
      currentFolder.name)
    if (!scope.isCurrent(this.auth, this.generationGuard.current())) {
      result.ok = false
      result.error = '登录状态已变更'
      return result
    }
    if (result.ok) {
      for (let i = 0; i < this.folders.length; i++) {
        this.folders[i].isDefault = this.folders[i].id === folderId
      }
      this.sortFolders()
      this.error = ''
      this.publishFolderState()
      await this.refreshFolders(true)
      if (!scope.isCurrent(this.auth, this.generationGuard.current())) {
        result.ok = false
        result.error = '登录状态已变更'
      }
    } else {
      this.error = result.error || '设置默认收藏夹失败'
      this.publishFolderState()
    }
    return result
  }

  /**
   * 删除收藏夹及本地已知成员关系。
   *
   * @param folderId - 收藏夹服务端 ID
   * @returns 操作结果
   */
  async deleteFolder(folderId: string): Promise<ApiResult> {
    if (!this.auth || !this.auth.isAuthenticated) {
      const unavailable: ApiResult = new ApiResult()
      unavailable.error = '未登录'
      return unavailable
    }
    const scope: AuthScope = AuthScope.capture(this.auth, this.generationGuard.current())
    const requestToken: string = this.auth.token
    const result: ApiResult = await deleteFavoriteTopicFolder(requestToken, folderId)
    if (!scope.isCurrent(this.auth, this.generationGuard.current())) {
      result.ok = false
      result.error = '登录状态已变更'
      return result
    }
    if (result.ok) {
      this.folders = this.folders.filter((folder: FavoriteTopicFolder): boolean => folder.id !== folderId)
      const membershipChanged: boolean = this.removeFolderFromMemberships(folderId)
      this.folderMutationVersions.delete(folderId)
      this.error = ''
      this.publishFolderState()
      if (membershipChanged) {
        this.persistMembershipCache()
        this.publishTopicState()
      }
      await this.refreshFolders(true)
      if (!scope.isCurrent(this.auth, this.generationGuard.current())) {
        result.ok = false
        result.error = '登录状态已变更'
      }
    } else {
      this.error = result.error || '删除收藏夹失败'
      this.publishFolderState()
    }
    return result
  }

  /**
   * 修改主题与收藏夹的服务端关系。
   *
   * @param topicId - NGA 主题 ID
   * @param folderId - 收藏夹服务端 ID
   * @param favored - 操作后的目标成员状态
   * @returns 收藏关系操作结果
   */
  async setTopicFavorite(topicId: string, folderId: string,
    favored: boolean): Promise<TopicFavoriteResult> {
    if (!this.auth || !this.auth.isAuthenticated) {
      const unavailable: TopicFavoriteResult = new TopicFavoriteResult()
      unavailable.folderId = folderId
      unavailable.favored = false
      unavailable.error = '未登录'
      return unavailable
    }
    const scope: AuthScope = AuthScope.capture(this.auth, this.generationGuard.current())
    const requestToken: string = this.auth.token
    if (folderId === '1' && this.getDefaultFolder() === null) {
      const loaded: boolean = await this.ensureFolders()
      if (!scope.isCurrent(this.auth, this.generationGuard.current())) {
        const unavailable: TopicFavoriteResult = new TopicFavoriteResult()
        unavailable.folderId = folderId
        unavailable.favored = false
        unavailable.error = '登录状态已变更'
        return unavailable
      }
      if (!loaded || this.getDefaultFolder() === null) {
        const unavailable: TopicFavoriteResult = new TopicFavoriteResult()
        unavailable.folderId = folderId
        unavailable.favored = false
        unavailable.error = this.error || '无法确定默认收藏夹'
        return unavailable
      }
    }
    const resolvedFolderId: string = this.resolveFolderId(folderId)
    const previousState: FavoriteMembershipState = this.getTopicFolderState(topicId, resolvedFolderId)
    const key: string = this.topicMutationKey(topicId, resolvedFolderId)
    if (this.pendingTopicMutations.has(key)) {
      const pendingResult: TopicFavoriteResult = new TopicFavoriteResult()
      pendingResult.folderId = resolvedFolderId
      pendingResult.favored = this.isTopicInFolder(topicId, resolvedFolderId)
      pendingResult.error = '收藏操作正在进行中'
      return pendingResult
    }

    const pendingMutations: Set<string> = this.pendingTopicMutations
    pendingMutations.add(key)
    const operation: TopicFavoriteOperation = favored
      ? TopicFavoriteOperation.ADD : TopicFavoriteOperation.DELETE
    try {
      const result: TopicFavoriteResult = await mutateTopicFavorite(
        requestToken, topicId, resolvedFolderId, operation)
      if (!scope.isCurrent(this.auth, this.generationGuard.current())) {
        result.ok = false
        result.error = '登录状态已变更'
        return result
      }
      if (result.ok) {
        const changed: boolean = this.applyTopicMembership(topicId, resolvedFolderId, favored, true)
        this.bumpFolderMutationVersion(resolvedFolderId)
        this.error = ''
        if (changed) {
          this.persistMembershipCache()
        }
        this.publishTopicState()
        if (previousState === FavoriteMembershipState.UNKNOWN) {
          this.refreshFolders(true)
        }
      } else {
        this.error = result.error || '修改收藏失败'
      }
      return result
    } finally {
      pendingMutations.delete(key)
    }
  }

  /**
   * 记录从收藏夹主题列表确认的成员关系。
   *
   * @param topicId - NGA 主题 ID
   * @param folderId - 收藏夹服务端 ID
   * @param favored - 是否属于该收藏夹
   */
  recordTopicMembership(topicId: string, folderId: string, favored: boolean = true): void {
    if (!this.auth || !this.auth.isAuthenticated) {
      return
    }
    if (this.applyTopicMembership(topicId, folderId, favored, false)) {
      this.persistMembershipCache()
      this.publishTopicState()
    }
  }

  /**
   * 批量记录同一收藏夹列表响应确认的主题成员关系。
   *
   * @param topicIds - NGA 主题 ID 列表
   * @param folderId - 收藏夹服务端 ID
   * @param favored - 是否属于该收藏夹
   */
  recordTopicMemberships(topicIds: string[], folderId: string, favored: boolean = true): void {
    if (!this.auth || !this.auth.isAuthenticated) {
      return
    }
    let changed: boolean = false
    for (let i = 0; i < topicIds.length; i++) {
      changed = this.applyTopicMembership(topicIds[i], folderId, favored, false) || changed
    }
    if (changed) {
      this.persistMembershipCache()
      this.publishTopicState()
    }
  }

  /**
   * 连续执行收藏夹刷新，并处理请求期间追加的强制刷新需求。
   *
   * @param scope - 请求发起时的身份与 Store 代际快照
   * @param requestToken - 请求发起时的会话令牌
   * @returns 最后一轮刷新是否成功
   */
  private async performFolderRefreshLoop(scope: AuthScope, requestToken: string): Promise<boolean> {
    let success: boolean = false
    do {
      this.refreshAfterCurrent = false
      success = await this.performFolderRefresh(scope, requestToken)
    } while (this.refreshAfterCurrent &&
      scope.isCurrent(this.auth, this.generationGuard.current()))
    return success
  }

  /**
   * 执行收藏夹列表请求并写回仍属于当前账号的响应。
   *
   * @param scope - 请求发起时的身份与 Store 代际快照
   * @param requestToken - 请求发起时的会话令牌
   * @returns 刷新是否成功
   */
  private async performFolderRefresh(scope: AuthScope, requestToken: string): Promise<boolean> {
    try {
      const result: FavoriteFolderListResult = await fetchFavoriteTopicFolders(requestToken)
      if (!scope.isCurrent(this.auth, this.generationGuard.current())) {
        return false
      }
      if (!result.ok) {
        this.error = result.error || '获取收藏夹失败'
        return false
      }
      this.folders = result.data.map((folder: FavoriteTopicFolder): FavoriteTopicFolder =>
        cloneFavoriteFolder(folder))
      this.sortFolders()
      this.foldersLoaded = true
      if (this.reconcileMembershipFolders()) {
        this.persistMembershipCache()
        this.publishTopicState()
      }
      this.error = ''
      return true
    } catch (error) {
      if (scope.isCurrent(this.auth, this.generationGuard.current())) {
        this.error = formatError(error as Object) || '获取收藏夹失败'
      }
      logger.warn('收藏夹刷新失败: %{public}s', formatError(error as Object))
      return false
    }
  }

  /**
   * 在内存中修改主题成员关系，并按需调整收藏夹数量。
   *
   * @param topicId - NGA 主题 ID
   * @param folderId - 收藏夹服务端 ID
   * @param favored - 新成员状态
   * @param updateCount - 是否在旧状态已知时同步调整收藏夹数量
   * @returns 成员状态是否发生变化
   */
  private applyTopicMembership(topicId: string, folderId: string,
    favored: boolean, updateCount: boolean): boolean {
    const resolvedFolderId: string = this.resolveFolderId(folderId)
    const current: Map<string, boolean> = this.topicFolderStates.get(topicId) ??
      new Map<string, boolean>()
    const previous: boolean | undefined = current.get(resolvedFolderId)
    if (previous === favored) {
      return false
    }
    current.set(resolvedFolderId, favored)
    this.topicFolderStates.set(topicId, current)
    if (updateCount && previous !== undefined) {
      this.adjustFolderCount(resolvedFolderId, favored ? 1 : -1)
      this.publishFolderState()
    }
    return true
  }

  /**
   * 调整收藏夹本地展示数量。
   *
   * @param folderId - 收藏夹服务端 ID
   * @param delta - 数量变化
   */
  private adjustFolderCount(folderId: string, delta: number): void {
    const folder: FavoriteTopicFolder | null = this.findFolderReference(folderId)
    if (folder !== null) {
      folder.topicCount = Math.max(0, folder.topicCount + delta)
    }
  }

  /**
   * 从所有运行期主题成员关系中移除收藏夹。
   *
   * @param folderId - 收藏夹服务端 ID
   */
  private removeFolderFromMemberships(folderId: string): boolean {
    const topicIds: string[] = Array.from(this.topicFolderStates.keys())
    let changed: boolean = false
    for (let i = 0; i < topicIds.length; i++) {
      const states: Map<string, boolean> | undefined = this.topicFolderStates.get(topicIds[i])
      if (states === undefined) {
        continue
      }
      changed = states.delete(folderId) || changed
      if (states.size === 0) {
        this.topicFolderStates.delete(topicIds[i])
      }
    }
    return changed
  }

  /**
   * 使用最新收藏夹列表迁移默认别名并清理失效收藏夹状态。
   *
   * @returns 成员关系缓存是否发生变化
   */
  private reconcileMembershipFolders(): boolean {
    const validFolderIds: Set<string> = new Set<string>()
    let defaultFolderId: string = ''
    for (let i = 0; i < this.folders.length; i++) {
      validFolderIds.add(this.folders[i].id)
      if (this.folders[i].isDefault) {
        defaultFolderId = this.folders[i].id
      }
    }

    let changed: boolean = false
    const topicIds: string[] = Array.from(this.topicFolderStates.keys())
    for (let i = 0; i < topicIds.length; i++) {
      const states: Map<string, boolean> | undefined = this.topicFolderStates.get(topicIds[i])
      if (states === undefined) {
        continue
      }
      if (defaultFolderId.length > 0 && defaultFolderId !== '1' && states.has('1')) {
        const aliasState: boolean = states.get('1') ?? false
        if (!states.has(defaultFolderId)) {
          states.set(defaultFolderId, aliasState)
        }
        states.delete('1')
        changed = true
      }
      const cachedFolderIds: string[] = Array.from(states.keys())
      for (let j = 0; j < cachedFolderIds.length; j++) {
        if (!validFolderIds.has(cachedFolderIds[j])) {
          states.delete(cachedFolderIds[j])
          changed = true
        }
      }
      if (states.size === 0) {
        this.topicFolderStates.delete(topicIds[i])
      }
    }

    const mutationFolderIds: string[] = Array.from(this.folderMutationVersions.keys())
    for (let i = 0; i < mutationFolderIds.length; i++) {
      if (!validFolderIds.has(mutationFolderIds[i])) {
        this.folderMutationVersions.delete(mutationFolderIds[i])
      }
    }
    return changed
  }

  /**
   * 解析兼容入口使用的默认收藏夹别名。
   *
   * @param folderId - 原始收藏夹 ID
   * @returns 实际收藏夹 ID
   */
  private resolveFolderId(folderId: string): string {
    if (folderId !== '1') {
      return folderId
    }
    const defaultFolder: FavoriteTopicFolder | null = this.getDefaultFolder()
    return defaultFolder?.id ?? folderId
  }

  /**
   * 查找并克隆收藏夹。
   *
   * @param folderId - 收藏夹服务端 ID
   * @returns 收藏夹副本或 null
   */
  private findFolder(folderId: string): FavoriteTopicFolder | null {
    const folder: FavoriteTopicFolder | null = this.findFolderReference(folderId)
    return folder === null ? null : cloneFavoriteFolder(folder)
  }

  /**
   * 查找 Store 内部收藏夹引用。
   *
   * @param folderId - 收藏夹服务端 ID
   * @returns 内部收藏夹或 null
   */
  private findFolderReference(folderId: string): FavoriteTopicFolder | null {
    for (let i = 0; i < this.folders.length; i++) {
      if (this.folders[i].id === folderId) {
        return this.folders[i]
      }
    }
    return null
  }

  /**
   * 将默认收藏夹稳定排列在首位。
   */
  private sortFolders(): void {
    this.folders.sort((left: FavoriteTopicFolder, right: FavoriteTopicFolder): number => {
      if (left.isDefault === right.isDefault) {
        return 0
      }
      return left.isDefault ? -1 : 1
    })
  }

  /**
   * 构建主题收藏关系操作去重键。
   *
   * @param topicId - NGA 主题 ID
   * @param folderId - 收藏夹服务端 ID
   * @returns 操作键
   */
  private topicMutationKey(topicId: string, folderId: string): string {
    return `${topicId}:${this.resolveFolderId(folderId)}`
  }

  /**
   * 推进指定收藏夹的服务端 mutation 版本。
   *
   * @param folderId - 实际收藏夹服务端 ID
   */
  private bumpFolderMutationVersion(folderId: string): void {
    const current: number = this.folderMutationVersions.get(folderId) ?? 0
    this.folderMutationVersions.set(folderId, current + 1)
  }

  /**
   * 构建当前账号收藏关系缓存键。
   *
   * @param uid - NGA 用户 ID
   * @returns 偏好存储键
   */
  private membershipCacheKey(uid: string): string {
    return `${FAVORITE_MEMBERSHIP_CACHE_KEY_PREFIX}${uid}`
  }

  /**
   * 加载当前账号的收藏关系提示缓存。
   *
   * @param uid - NGA 用户 ID
   */
  private async loadMembershipCache(uid: string): Promise<void> {
    const scope: AuthScope = AuthScope.capture(this.auth, this.generationGuard.current())
    const saved: FavoriteMembershipCacheEnvelope | null =
      await this.store.getJSON<FavoriteMembershipCacheEnvelope>(this.membershipCacheKey(uid))
    if (!scope.isCurrent(this.auth, this.generationGuard.current()) || saved === null ||
      saved.schemaVersion !== FAVORITE_MEMBERSHIP_CACHE_SCHEMA_VERSION || saved.uid !== uid) {
      return
    }
    const knownRecord: Record<string, string[]> = saved.knownFolderIds ?? {}
    const favoredRecord: Record<string, string[]> = saved.favoredFolderIds ?? {}
    const topicIds: string[] = Object.keys(knownRecord)
    for (let i = 0; i < topicIds.length; i++) {
      const knownIds: string[] = knownRecord[topicIds[i]] ?? []
      const favoredIds: Set<string> = new Set<string>(favoredRecord[topicIds[i]] ?? [])
      const states: Map<string, boolean> = new Map<string, boolean>()
      for (let j = 0; j < knownIds.length; j++) {
        states.set(knownIds[j], favoredIds.has(knownIds[j]))
      }
      if (states.size > 0) {
        this.topicFolderStates.set(topicIds[i], states)
      }
    }
    this.publishTopicState()
  }

  /**
   * 将当前账号收藏关系提示写入既有偏好存储队列。
   */
  private persistMembershipCache(): void {
    if (!this.auth || !this.auth.isAuthenticated || this.auth.uid.length === 0) {
      return
    }
    const uid: string = this.auth.uid
    const scope: AuthScope = AuthScope.capture(this.auth, this.generationGuard.current())
    const envelope: FavoriteMembershipCacheEnvelope = new FavoriteMembershipCacheEnvelope()
    envelope.uid = uid
    const topicIds: string[] = Array.from(this.topicFolderStates.keys())
    for (let i = 0; i < topicIds.length; i++) {
      const states: Map<string, boolean> | undefined = this.topicFolderStates.get(topicIds[i])
      if (states === undefined || states.size === 0) {
        continue
      }
      const knownIds: string[] = []
      const favoredIds: string[] = []
      states.forEach((favored: boolean, folderId: string): void => {
        knownIds.push(folderId)
        if (favored) {
          favoredIds.push(folderId)
        }
      })
      envelope.knownFolderIds[topicIds[i]] = knownIds
      envelope.favoredFolderIds[topicIds[i]] = favoredIds
    }
    this.writeQueue.enqueue(async (): Promise<void> => {
      if (!scope.isCurrent(this.auth, this.generationGuard.current())) {
        return
      }
      await this.store.putJSON(this.membershipCacheKey(uid), envelope, false)
      this.store.scheduleFlush()
    })
  }

  /**
   * 清空当前账号的运行期状态。
   */
  private resetMemoryState(): void {
    this.folders = []
    this.topicFolderStates = new Map<string, Map<string, boolean>>()
    this.pendingTopicMutations = new Set<string>()
    this.folderMutationVersions = new Map<string, number>()
    this.refreshPromise = null
    this.refreshAfterCurrent = false
    this.foldersLoaded = false
    this.foldersLoading = false
    this.error = ''
  }

  /**
   * 发布收藏夹列表状态变更。
   */
  private publishFolderState(): void {
    bumpAppStorageVersion(KEY_FAVORITE_FOLDER_VERSION)
  }

  /**
   * 发布主题收藏关系状态变更。
   */
  private publishTopicState(): void {
    bumpAppStorageVersion(KEY_FAVORITE_TOPIC_VERSION)
  }
}
