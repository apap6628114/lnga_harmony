import { Context } from '@kit.AbilityKit'
import { BaseStore } from './BaseStore'
import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { SettingsState } from './settings/SettingsState'
import { FavBoard } from '../model/SocialEntries'
import type { BlacklistEntry } from '../model/SocialEntries'
import { SettingsContext } from './settings/SettingsContext'
import { ThemeSettings } from './settings/domain/ThemeSettings'
import { DisplaySettings } from './settings/domain/DisplaySettings'
import { MediaSettings } from './settings/domain/MediaSettings'
import { ReadingSettings } from './settings/domain/ReadingSettings'
import { SocialListSettings } from './settings/domain/SocialListSettings'
import { FilterKeywordSettings } from './settings/domain/FilterKeywordSettings'
import { NoteSettings } from './settings/domain/NoteSettings'
import { CheckinSettings } from './settings/domain/CheckinSettings'
import { AiSettings } from './settings/domain/AiSettings'
import type { AuthState } from './AuthStore'
import type { AiProviderProfile } from '../model/AiConfig'
import {
  KEY_SHOW_SIGNATURE,
  KEY_IMAGE_LOAD_STRATEGY,
  KEY_SHOW_TOPIC_PREVIEW,
  KEY_VIDEO_MUTED,
  KEY_USE_INTERNAL_WEBVIEW,
  KEY_DEBUG_MODE,
  KEY_CONTENT_FONT_SIZE,
  KEY_TOPIC_FONT_SIZE,
  KEY_COLUMN_RATIO_MODE,
  KEY_COLUMN_SIDEBAR_MD,
  KEY_COLUMN_SIDEBAR_LG,
  KEY_COLUMN_BOARD_RATIO_LG,
} from '../common/constants/AppStorageKeys'


/**
 * 用户设置管理门面（Facade）。
 *
 * 持有持久化根状态 state 与设置域子 store，编排 init / loadUserSettings /
 * persistSettings / reset 生命周期。
 */
export class SettingsStore extends BaseStore<SettingsState> {
  override state: SettingsState = new SettingsState()
  private context?: Context
  private ctx: SettingsContext

  readonly themeSettings: ThemeSettings
  readonly displaySettings: DisplaySettings
  readonly mediaSettings: MediaSettings
  readonly readingSettings: ReadingSettings
  readonly socialListSettings: SocialListSettings
  readonly filterKeywordSettings: FilterKeywordSettings
  readonly noteSettings: NoteSettings
  readonly checkinSettings: CheckinSettings
  readonly aiSettings: AiSettings

  constructor() {
    super()
    this.ctx = new SettingsContext(this.state, (): void => this.persistSettings())
    this.themeSettings = new ThemeSettings(this.ctx)
    this.displaySettings = new DisplaySettings(this.ctx)
    this.mediaSettings = new MediaSettings(this.ctx)
    this.readingSettings = new ReadingSettings(this.ctx)
    this.socialListSettings = new SocialListSettings(this.ctx)
    this.filterKeywordSettings = new FilterKeywordSettings(this.ctx)
    this.noteSettings = new NoteSettings(this.ctx)
    this.checkinSettings = new CheckinSettings(this.ctx)
    this.aiSettings = new AiSettings(this.ctx)
  }

  /**
   * 初始化主题（全局设置，无条件执行，与账号无关）。
   *
   * 主题持久化在全局 key（nga_theme）而非 settings_${uid}：未登录用户同样
   * 可保存主题并跨冷启动生效。须在 AppStore 初始化阶段、applyCurrentTheme
   * 之前调用（设计记录见 docs/THEME_DESIGN.md）。
   */
  async initTheme(store: PreferencesStore, queue: SerialQueue, ctx?: Context): Promise<void> {
    this.themeSettings.init(store, queue)
    this.ctx.context = ctx
    await this.themeSettings.loadGlobal()
  }

  async init(store: PreferencesStore, queue: SerialQueue, auth: AuthState, ctx?: Context): Promise<void> {
    this.setDeps(store, queue, auth)
    this.context = ctx
    this.ctx.auth = auth
    this.ctx.context = ctx
    if (auth.uid) {
      await this.loadUserSettings()
    }
  }

  /** 重置为用户默认设置（切换/登出时调用） */
  reset(): void {
    this.state = new SettingsState()
    this.ctx.state = this.state
    // 主题为全局设置，不随账号重置：恢复全局主题内存真源，
    // 与登出/切号后 applyCurrentTheme 的取值保持一致。
    this.themeSettings.restoreGlobal()
    // clearAuth 的 writeQueue.cancel() 可能丢弃未执行的主题落盘任务，
    // 重放一次保证 Preferences 与内存一致（幂等无害）。
    this.themeSettings.repersist()
    this.socialListSettings.reset()
    this.filterKeywordSettings.reset()
    this.noteSettings.reset()
    this.aiSettings.reset()
    // AppStorage 里的列占比键不在 state 里，必须显式回到默认值：否则会残留上一个账号
    // 的布局与"占比模式已激活"的内存标记，直到下一次登录才被 syncColumnLayoutStorage 覆盖。
    // 当前登出态不挂载 MainPage，观察不到，但把这条不变量显式化，免得日后加了登出预览页就漏。
    this.syncColumnLayoutStorage()
    super.reset()
  }

  // ============== Persist ==============

  private settingsKey(): string {
    return `settings_${this.auth.uid}`
  }

  persistSettings(): void {
    if (!this.auth.uid) return
    this.writeQueue.enqueue(async (): Promise<void> => {
      await this.store.putJSON(this.settingsKey(), this.state, false)
      this.store.scheduleFlush()
    })
  }

  private async loadUserSettings(): Promise<void> {
    if (!this.auth.uid) return
    const saved = await this.store.getJSON<SettingsState>(this.settingsKey())
    if (saved) {
      // 主题已全局化（nga_theme key），不随用户设置持久化，此处不再读取
      this.displaySettings.load(saved)
      this.mediaSettings.load(saved)
      this.readingSettings.load(saved)
      this.socialListSettings.load(saved)
      this.filterKeywordSettings.load(saved)
      this.noteSettings.load(saved)
      this.checkinSettings.load(saved)
      this.aiSettings.load(saved)
      if (saved.useInternalWebView !== undefined) {
        this.state.useInternalWebView = saved.useInternalWebView
      }
      if (saved.debugMode !== undefined) {
        this.state.debugMode = saved.debugMode
      }
    }
    AppStorage.setOrCreate(KEY_SHOW_SIGNATURE, this.state.showSignature)
    AppStorage.setOrCreate(KEY_IMAGE_LOAD_STRATEGY, this.state.imageLoadStrategy)
    AppStorage.setOrCreate(KEY_SHOW_TOPIC_PREVIEW, this.state.showTopicPreview)
    AppStorage.setOrCreate(KEY_VIDEO_MUTED, this.state.videoMuted)
    AppStorage.setOrCreate(KEY_USE_INTERNAL_WEBVIEW, this.state.useInternalWebView)
    AppStorage.setOrCreate(KEY_DEBUG_MODE, this.state.debugMode)
    AppStorage.setOrCreate(KEY_CONTENT_FONT_SIZE, this.state.fontSize)
    AppStorage.setOrCreate(KEY_TOPIC_FONT_SIZE, this.state.topicFontSize)
    this.syncColumnLayoutStorage()
  }

  /**
   * 把列堆栈**占比**设定同步到 AppStorage（供 `MainPage` 以 @StorageProp 响应式读取）。
   *
   * 登出后 AppStorage 里的旧值不会被清掉（历史其它键同样如此），所以每次
   * `loadUserSettings` 都要**无条件**重写一遍，避免下一个账号继承上一个账号的布局。
   *
   * 「列占比模式」开关一并在此归零：它是**纯内存态**的临时调整模式，不随账号、
   * 也不跨会话保留 —— 重新登录后从头开始（此时占比本身照常从 `settings_${uid}` 恢复）。
   */
  private syncColumnLayoutStorage(): void {
    AppStorage.setOrCreate(KEY_COLUMN_RATIO_MODE, false)
    AppStorage.setOrCreate(KEY_COLUMN_SIDEBAR_MD, this.state.columnSidebarMd)
    AppStorage.setOrCreate(KEY_COLUMN_SIDEBAR_LG, this.state.columnSidebarLg)
    AppStorage.setOrCreate(KEY_COLUMN_BOARD_RATIO_LG, this.state.columnBoardRatioLg)
  }

  // ============== 设置域 setter ==============

  // --- Blacklist (SocialList) ---
  /** 添加黑名单用户并返回是否实际新增。 */
  addBlacklist(entry: BlacklistEntry): boolean { return this.socialListSettings.addBlacklist(entry) }
  /** 移除黑名单用户并返回是否实际移除。 */
  removeBlacklist(userId: string): boolean { return this.socialListSettings.removeBlacklist(userId) }
  /** 清空黑名单并返回是否实际清除。 */
  removeAllBlacklist(): boolean { return this.socialListSettings.removeAllBlacklist() }
  /** 获取黑名单 UID 集合。 */
  getBlacklistIds(): Set<string> { return this.socialListSettings.getBlacklistIds() }
  /** 判断用户是否已被加入黑名单。 */
  isBlacklisted(userId: string): boolean { return this.socialListSettings.isBlacklisted(userId) }
  /** 获取逗号分隔的黑名单 UID。 */
  getBlacklistHeaderString(): string { return this.socialListSettings.getBlacklistHeaderString() }

  // --- Favorites (SocialList) ---
  ensureFavorites(): void { this.socialListSettings.ensureFavorites() }
  addFavorite(board: FavBoard): void { this.socialListSettings.addFavorite(board) }
  removeFavorite(fid: number): void { this.socialListSettings.removeFavorite(fid) }

  // --- Theme ---
  setTheme(theme: string): void { this.themeSettings.setTheme(theme) }
  applyCurrentTheme(): void { this.themeSettings.applyCurrentTheme() }

  // --- Display ---
  setFontSize(size: number): void { this.displaySettings.setFontSize(size) }
  setTopicFontSize(size: number): void { this.displaySettings.setTopicFontSize(size) }
  setDomainIndex(index: number): void { this.displaySettings.setDomainIndex(index) }
  setHoldingHand(value: number): void { this.displaySettings.setHoldingHand(value) }
  setSmartGrip(enabled: boolean): void { this.displaySettings.setSmartGrip(enabled) }
  setShowSignature(enabled: boolean): void { this.displaySettings.setShowSignature(enabled) }

  // --- Column Layout (列堆栈占比) ---
  /**
   * 切换「列堆栈占比模式」（控制占比读数条与拖动把手的显示）。
   *
   * **纯内存态，刻意不落盘**：它是"正在调整布局"的临时模式，冷启动与重新登录一律从
   * 关闭开始。占比本身由下面的 setter 正常持久化。
   *
   * @param enabled - 是否激活
   */
  setColumnRatioMode(enabled: boolean): void {
    AppStorage.setOrCreate(KEY_COLUMN_RATIO_MODE, enabled)
  }
  /**
   * 设置指定断点的侧边栏宽度（vp）。
   * @param breakpoint - md / lg（sm 无侧边栏，忽略）
   * @param widthVp - 侧边栏宽度
   */
  setColumnSidebarWidth(breakpoint: string, widthVp: number): void {
    this.displaySettings.setColumnSidebarWidth(breakpoint, widthVp)
  }
  /** 设置 lg 断点板块列占内容区的比例。 */
  setColumnBoardRatio(ratio: number): void { this.displaySettings.setColumnBoardRatio(ratio) }
  /** 把指定断点的列占比恢复为默认值。 */
  resetColumnLayout(breakpoint: string): void { this.displaySettings.resetColumnLayout(breakpoint) }

  // --- Media (TTS / Image / Video) ---
  setTtsPerson(v: number): void { this.mediaSettings.setTtsPerson(v) }
  setTtsSpeed(v: number): void { this.mediaSettings.setTtsSpeed(v) }
  setTtsVolume(v: number): void { this.mediaSettings.setTtsVolume(v) }
  setTtsPitch(v: number): void { this.mediaSettings.setTtsPitch(v) }
  setImageLoadStrategy(v: string): void { this.mediaSettings.setImageLoadStrategy(v) }
  /** 设置是否在主题列表卡片显示帖子预览图 */
  setShowTopicPreview(enabled: boolean): void { this.mediaSettings.setShowTopicPreview(enabled) }
  setVideoMuted(enabled: boolean): void { this.mediaSettings.setVideoMuted(enabled) }

  // --- Internal WebView ---
  /** 设置是否在没有可用 App Linking 应用时使用应用内 WebView */
  setUseInternalWebView(enabled: boolean): void {
    this.state.useInternalWebView = enabled
    AppStorage.setOrCreate(KEY_USE_INTERNAL_WEBVIEW, enabled)
    this.persistSettings()
  }

  // --- Debug ---
  /** 设置调试模式（开启后输出额外诊断信息） */
  setDebugMode(enabled: boolean): void {
    this.state.debugMode = enabled
    AppStorage.setOrCreate(KEY_DEBUG_MODE, enabled)
    this.persistSettings()
  }

  // --- Reading ---
  setThreadNavMode(v: string): void { this.readingSettings.setThreadNavMode(v) }
  setPrefetchPageCount(v: number): void { this.readingSettings.setPrefetchPageCount(v) }
  /** 设置是否记录帖子阅读进度（开启后下次进入自动恢复阅读位置） */
  setRecordReadingProgress(enabled: boolean): void { this.readingSettings.setRecordReadingProgress(enabled) }

  // --- Notes ---
  addOrUpdateNote(userId: string, nickName: string, note: string): void {
    this.noteSettings.addOrUpdateNote(userId, nickName, note)
  }
  removeNote(userId: string): void { this.noteSettings.removeNote(userId) }
  removeAllNotes(): void { this.noteSettings.removeAllNotes() }
  getNote(userId: string): string { return this.noteSettings.getNote(userId) }
  getNoteMap(): Record<string, string> { return this.noteSettings.getNoteMap() }

  // --- Filter Keywords ---
  addKeyword(keyword: string): void { this.filterKeywordSettings.addKeyword(keyword) }
  removeKeyword(keyword: string): void { this.filterKeywordSettings.removeKeyword(keyword) }
  toggleKeyword(keyword: string): void { this.filterKeywordSettings.toggleKeyword(keyword) }
  removeAllKeywords(): void { this.filterKeywordSettings.removeAllKeywords() }
  getEnabledKeywords(): string[] { return this.filterKeywordSettings.getEnabledKeywords() }

  // --- Checkin ---
  setAutoCheckin(enabled: boolean): void { this.checkinSettings.setAutoCheckin(enabled) }
  autoCheckinIfNeeded(): Promise<boolean> { return this.checkinSettings.autoCheckinIfNeeded() }

  // --- AI ---
  addAiProfile(profile: AiProviderProfile): void { this.aiSettings.addProfile(profile) }
  updateAiProfile(profile: AiProviderProfile): void { this.aiSettings.updateProfile(profile) }
  deleteAiProfile(id: string): void { this.aiSettings.deleteProfile(id) }
  setActiveAiProfile(id: string): void { this.aiSettings.setActiveProfile(id) }
  getActiveAiProfile(): AiProviderProfile | null { return this.aiSettings.getActiveProfile() }

  // --- AI Scenario Prompts ---
  getScenarioPrompt(scenario: string): string { return this.aiSettings.getScenarioPrompt(scenario) }
  setScenarioPrompt(scenario: string, prompt: string): void { this.aiSettings.setScenarioPrompt(scenario, prompt) }
  resetScenarioPrompt(scenario: string): void { this.aiSettings.resetScenarioPrompt(scenario) }
}
