import { getForumCategories } from '../service/api/ForumApi'
import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { BaseStore } from './BaseStore'
import { AuthScope } from './AuthScope'
import type { Category } from '../model/Forum'
import type { AuthState } from './AuthStore'
import { KEY_CAT_VERSION } from '../common/constants/AppStorageKeys'
import { bumpAppStorageVersion } from '../common/utils/AppStorageVersion'

import { Logger, DOMAIN_STORE } from '../common/utils/Logger'
import { DomainIds, PersistenceCatalog } from '../common/persistence/PersistenceCatalog'
import { DomainSpec } from '../common/persistence/PersistenceTypes'

const logger = new Logger(DOMAIN_STORE, 'CategoryStore')

/**
 * 返回板块分类缓存域的 Preferences 键（统一命名空间 `v2.categories`）。
 *
 * @returns 键名；域未登记时为空串
 */
function categoriesKey(): string {
  const spec: DomainSpec | null = PersistenceCatalog.byId(DomainIds.CATEGORIES)
  return spec === null ? '' : spec.fullKey()
}

/**
 * 论坛分类缓存管理
 */
export class CategoryStore extends BaseStore<Object> {
  override state: Object = new Object()
  cachedCategories: Category[] = []
  private categoriesRefreshing: boolean = false
  categoriesLoaded: boolean = false
  categoriesError: string = ''
  private static readonly REFRESH_DELAY: number = 10000
  async init(store: PreferencesStore, queue: SerialQueue, auth: AuthState): Promise<void> {
    this.setDeps(store, queue, auth)
    await this.loadCachedCategories()
  }

  /** 重置缓存（登出时调用） */
  reset(): void {
    this.cachedCategories = []
    this.categoriesRefreshing = false
    this.categoriesLoaded = false
    this.categoriesError = ''
    super.reset()
  }

  // ============== Cache ==============

  private async loadCachedCategories(): Promise<void> {
    const key: string = categoriesKey()
    if (key.length === 0) {
      return
    }
    const saved = await this.store.getJSON<Category[]>(key)
    if (saved && saved.length > 0) {
      this.cachedCategories = saved
      this.bumpCategoriesVersion()
      logger.info('Loaded cached categories: %{public}d', saved.length)
    }
  }

  private bumpCategoriesVersion(): void {
    bumpAppStorageVersion(KEY_CAT_VERSION)
  }

  private persistCategories(): void {
    const key: string = categoriesKey()
    if (key.length === 0) {
      return
    }
    this.writeQueue.enqueue(async (): Promise<void> => {
      await this.store.putJSON(key, this.cachedCategories, false)
      this.store.scheduleFlush()
    })
  }

  ensureCategories(): void {
    if (this.categoriesRefreshing) return
    this.categoriesRefreshing = true
    const gen = this.generationGuard.bump()
    const hasCache = this.cachedCategories.length > 0
    setTimeout(async () => {
      await this.doRefreshCategories(gen)
      this.categoriesRefreshing = false
    }, hasCache ? CategoryStore.REFRESH_DELAY : 0)
  }

  private async doRefreshCategories(gen: number): Promise<void> {
    if (!this.isCurrent(gen)) return
    if (!this.auth.isAuthenticated) {
      this.categoriesLoaded = true
      this.categoriesError = '未登录'
      if (this.cachedCategories.length === 0) {
        this.bumpCategoriesVersion()
      }
      return
    }
    const scope: AuthScope = AuthScope.capture(this.auth, gen)
    try {
      const result = await getForumCategories(this.auth.token)
      // 请求期间可能已重置或切号：代际与身份任一变化即放弃回写
      if (!this.isCurrent(gen) || !scope.isCurrent(this.auth, gen)) {
        return
      }
      this.categoriesLoaded = true
      if (result.ok) {
        this.categoriesError = ''
        if (result.data.length > 0) {
          const newJson = JSON.stringify(result.data)
          const oldJson = JSON.stringify(this.cachedCategories)
          if (newJson !== oldJson) {
            this.cachedCategories = result.data
            this.bumpCategoriesVersion()
            this.persistCategories()
            logger.info('Categories updated from network')
          } else {
            logger.info('Categories unchanged')
          }
        } else if (this.cachedCategories.length === 0) {
          this.bumpCategoriesVersion()
        }
      } else {
        this.categoriesError = result.error || '获取板块分类失败'
        if (this.cachedCategories.length === 0) {
          this.bumpCategoriesVersion()
        }
      }
    } catch (e) {
      this.categoriesLoaded = true
      this.categoriesError = '获取板块分类失败'
      if (this.cachedCategories.length === 0) {
        this.bumpCategoriesVersion()
      }
      logger.error('refreshCategories failed')
    }
  }
}
