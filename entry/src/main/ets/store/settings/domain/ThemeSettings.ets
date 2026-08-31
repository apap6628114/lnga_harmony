import { ConfigurationConstant } from '@kit.AbilityKit'
import { updateStatusBarStyle } from '../../../common/managers/StatusBarManager'
import { SettingsContext } from '../SettingsContext'
import { KEY_THEME_NAME, KEY_EFFECTIVE_COLOR_MODE, KEY_SYSTEM_COLOR_MODE } from '../../../common/constants/AppStorageKeys'
import { PreferencesStore } from '../../../common/infra/PreferencesStore'
import { SerialQueue } from '../../../common/infra/SerialQueue'
import { isPageLoaded } from '../../../common/infra/PageLifecycle'

import { Logger, DOMAIN_SETTINGS, formatError } from '../../../common/utils/Logger'

const logger = new Logger(DOMAIN_SETTINGS, 'ThemeSettings')

/** 主题全局持久化的数据形状（仅承载 theme 字段）。 */
class ThemePersist {
  theme: string = ''
}

/**
 * 主题设置域子 store。
 *
 * 主题是全局设置，不随账号（uid）隔离：未登录用户同样可持久化并跨冷启动生效。
 * 持久化 key 与 uid 无关（GLOBAL_THEME_KEY），由 SettingsStore.initTheme 在
 * AppStore 初始化阶段无条件加载（设计记录见 docs/THEME_DESIGN.md）。
 *
 * theme 内存真源为本实例私有字段，不进入 uid 隔离的 SettingsState——
 * settings_${uid} 的持久化数据中不含主题，不存在旧数据兼容/迁移需求。
 */
export class ThemeSettings {
  /** 全局主题持久化 key：刻意不携带 uid，登出/切号不丢失。 */
  private static readonly GLOBAL_THEME_KEY: string = 'nga_theme'
  private ctx: SettingsContext
  private store?: PreferencesStore
  private writeQueue?: SerialQueue
  /** 主题内存真源（全局设置，与 uid 无关）。 */
  private theme: string = 'light'

  constructor(ctx: SettingsContext) {
    this.ctx = ctx
  }

  /** 注入持久化依赖（由 SettingsStore.initTheme 调用，与账号无关）。 */
  init(store: PreferencesStore, queue: SerialQueue): void {
    this.store = store
    this.writeQueue = queue
  }

  /** 从全局存储加载主题（冷启动 / 登出恢复的统一入口）。 */
  async loadGlobal(): Promise<void> {
    if (!this.store) return
    const saved = await this.store.getJSON<ThemePersist>(ThemeSettings.GLOBAL_THEME_KEY)
    if (saved && this.isValidTheme(saved.theme)) {
      this.theme = saved.theme
    }
  }

  /** 主题取值白名单校验（防御持久化脏数据）。 */
  private isValidTheme(theme: string): boolean {
    return theme === 'system' || theme === 'light' || theme === 'dark'
  }

  /** 登出/切号后恢复全局主题（同步：以 AppStorage 生效值对齐内存真源）。 */
  restoreGlobal(): void {
    this.theme = AppStorage.get<string>(KEY_THEME_NAME) ?? this.theme
  }

  /**
   * 登出/切号后重放主题持久化。
   *
   * clearAuth 的 writeQueue.cancel() 会丢弃队列中未执行的任务：若用户 setTheme
   * 后立即登出，原 persistGlobal 落盘任务可能被丢弃，导致下次冷启动主题回退。
   * 此处以当前内存真源（restoreGlobal 已对齐 AppStorage）重新入队，幂等无害。
   */
  repersist(): void {
    this.persistGlobal()
  }

  /** 设置主题并立即应用（全局持久化 + 切换颜色模式 + 更新状态栏） */
  setTheme(theme: string): void {
    this.theme = theme
    this.applyCurrentTheme()
    this.persistGlobal()
  }

  /** 按当前 theme 应用颜色模式与状态栏样式 */
  applyCurrentTheme(): void {
    let theme: string = this.theme
    let mode: ConfigurationConstant.ColorMode
    let effectiveTheme: string
    if (theme === 'system') {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
      // 系统真实颜色模式：读 AppStorage 缓存（EntryAbility.onCreate 初始化 +
      // onSystemConfigurationUpdated 系统级订阅实时维护，应用固定 light/dark
      // 主题期间系统切换也不会过时）。
      //
      // 不得用 resourceManager.getConfigurationSync() 或 context.config 读取——
      // 它们返回**应用当前生效**模式：从固定主题切回"跟随系统"的瞬间应用仍是
      // 旧固定模式，会误判（如系统暗色 + 切回 system 时得到 LIGHT → 状态栏
      // 文字仍置黑），详见 docs/THEME_DESIGN.md。
      effectiveTheme = AppStorage.get<string>(KEY_SYSTEM_COLOR_MODE) ?? 'light'
    } else if (theme === 'dark') {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      effectiveTheme = 'dark'
    } else {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
      effectiveTheme = 'light'
    }
    try {
      // 官方 NOTE：setColorMode 须在窗口创建且页面加载完成后调用。
      // 页面未就绪（appStore.init 先于 loadContent 完成）时跳过，
      // 由 EntryAbility.loadContent 兜底重放 applyCurrentTheme 应用
      //（此时页面必然已加载，见 docs/THEME_DESIGN.md 时序契约）。
      if (isPageLoaded()) {
        this.ctx.context?.getApplicationContext().setColorMode(mode)
      }
    } catch (err) {
      logger.error('setColorMode failed: %{public}s', formatError(err))
    }
    AppStorage.setOrCreate(KEY_THEME_NAME, theme)
    AppStorage.setOrCreate(KEY_EFFECTIVE_COLOR_MODE, effectiveTheme)

    try {
      updateStatusBarStyle(effectiveTheme === 'dark')
    } catch (err) {
      logger.error('updateStatusBarStyle failed: %{public}s', formatError(err))
    }
  }

  /** 持久化主题到全局 key（与账号无关；未登录用户同样生效）。 */
  private persistGlobal(): void {
    const store = this.store
    const queue = this.writeQueue
    if (!store || !queue) return
    const snapshot: ThemePersist = new ThemePersist()
    snapshot.theme = this.theme
    queue.enqueue(async (): Promise<void> => {
      await store.putJSON(ThemeSettings.GLOBAL_THEME_KEY, snapshot, false)
      store.scheduleFlush()
    })
  }
}
