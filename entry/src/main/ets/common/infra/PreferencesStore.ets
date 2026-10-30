import { preferences } from '@kit.ArkData'
import { Context } from '@kit.AbilityKit'
import { Logger, DOMAIN_INFRA } from '../utils/Logger'

const logger = new Logger(DOMAIN_INFRA, 'PreferencesStore')

export class PreferencesStore {
  private pref: preferences.Preferences | null = null
  private flushTimer: number = -1

  async init(context: Context, name: string): Promise<void> {
    try {
      this.pref = await preferences.getPreferences(context, name)
      logger.info( 'Initialized: %{public}s', name)
    } catch (e) {
      logger.error( 'init failed: %{public}s', name)
    }
  }

  async getString(key: string, def: string = ''): Promise<string> {
    if (!this.pref) return def
    try {
      return (await this.pref.get(key, def)) as string
    } catch (e) {
      logger.error( 'getString failed: %{public}s', key)
      return def
    }
  }

  async putString(key: string, value: string, flush: boolean = true): Promise<void> {
    if (!this.pref) return
    try {
      await this.pref.put(key, value)
      if (flush) {
        await this.pref.flush()
      }
    } catch (e) {
      logger.error( 'putString failed: %{public}s', key)
    }
  }

  async getJSON<T>(key: string): Promise<T | null> {
    if (!this.pref) return null
    try {
      const raw = (await this.pref.get(key, '')) as string
      if (raw) {
        return JSON.parse(raw) as T
      }
    } catch (e) {
      logger.info( 'getJSON miss: %{public}s', key)
    }
    return null
  }

  async putJSON(key: string, value: Object, flush: boolean = true): Promise<void> {
    if (!this.pref) return
    try {
      await this.pref.put(key, JSON.stringify(value))
      if (flush) {
        await this.pref.flush()
      }
    } catch (e) {
      logger.error( 'putJSON failed: %{public}s', key)
    }
  }

  async flush(): Promise<void> {
    if (!this.pref) return
    try {
      await this.pref.flush()
    } catch (e) {
      logger.error( 'flush failed')
    }
  }

  /**
   * 删除一个键（持久化数据统一治理的迁移/清理路径使用）。
   *
   * @param key - 键名
   * @param flush - 是否立即刷盘（默认 true）
   * @returns 是否实际删除（键不存在时返回 false）
   */
  async deleteKey(key: string, flush: boolean = true): Promise<boolean> {
    if (!this.pref) return false
    try {
      if (!(await this.pref.has(key))) {
        return false
      }
      await this.pref.delete(key)
      if (flush) {
        await this.pref.flush()
      }
      return true
    } catch (e) {
      logger.error( 'deleteKey failed: %{public}s', key)
      return false
    }
  }

  /**
   * 判断键是否存在。
   *
   * @param key - 键名
   * @returns 是否存在
   */
  async hasKey(key: string): Promise<boolean> {
    if (!this.pref) return false
    try {
      return await this.pref.has(key)
    } catch (e) {
      return false
    }
  }

  /**
   * 返回全部键值快照（迁移检测与数据管理页统计使用）。
   *
   * @returns 键 → 原始值（本项目全部以 string 落盘，值类型按 Object 返回以兼容旧数据）
   */
  async getAll(): Promise<Record<string, Object>> {
    if (!this.pref) return {}
    try {
      const all: Object = await this.pref.getAll()
      return all as Record<string, Object>
    } catch (e) {
      logger.error( 'getAll failed')
      return {}
    }
  }

  scheduleFlush(delay: number = 500): void {
    clearTimeout(this.flushTimer)
    this.flushTimer = setTimeout(async (): Promise<void> => {
      await this.flush()
    }, delay)
  }
}
