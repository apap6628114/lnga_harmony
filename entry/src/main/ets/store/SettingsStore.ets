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
import { WebSearchSettings } from './settings/domain/WebSearchSettings'
import type { AuthState } from './AuthStore'
import type { AiProviderProfile } from '../model/AiConfig'
import type { WebSearchProviderProfile } from '../model/WebSearchConfig'
import {
  KEY_SHOW_SIGNATURE,
  KEY_IMAGE_LOAD_STRATEGY,
  KEY_ENABLE_IMAGE_SIZE_PREFETCH,
  KEY_VIDEO_MUTED,
  KEY_USE_INTERNAL_WEBVIEW,
  KEY_CONTENT_FONT_SIZE,
  KEY_TOPIC_FONT_SIZE,
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
  readonly webSearchSettings: WebSearchSettings

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
    this.webSearchSettings = new WebSearchSettings(this.ctx)
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
    this.socialListSettings.reset()
    this.filterKeywordSettings.reset()
    this.noteSettings.reset()
    this.aiSettings.reset()
    this.webSearchSettings.reset()
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
      this.themeSettings.load(saved)
      this.displaySettings.load(saved)
      this.mediaSettings.load(saved)
      this.readingSettings.load(saved)
      this.socialListSettings.load(saved)
      this.filterKeywordSettings.load(saved)
      this.noteSettings.load(saved)
      this.checkinSettings.load(saved)
      this.aiSettings.load(saved)
      this.webSearchSettings.load(saved)
    }
    AppStorage.setOrCreate(KEY_SHOW_SIGNATURE, this.state.showSignature)
    AppStorage.setOrCreate(KEY_IMAGE_LOAD_STRATEGY, this.state.imageLoadStrategy)
    AppStorage.setOrCreate(KEY_ENABLE_IMAGE_SIZE_PREFETCH, this.state.enableImageSizePrefetch)
    AppStorage.setOrCreate(KEY_VIDEO_MUTED, this.state.videoMuted)
    AppStorage.setOrCreate(KEY_USE_INTERNAL_WEBVIEW, this.state.useInternalWebView)
    AppStorage.setOrCreate(KEY_CONTENT_FONT_SIZE, this.state.fontSize)
    AppStorage.setOrCreate(KEY_TOPIC_FONT_SIZE, this.state.topicFontSize)
  }

  // ============== 设置域 setter ==============

  // --- Blacklist (SocialList) ---
  addBlacklist(entry: BlacklistEntry): void { this.socialListSettings.addBlacklist(entry) }
  removeBlacklist(userId: string): void { this.socialListSettings.removeBlacklist(userId) }
  removeAllBlacklist(): void { this.socialListSettings.removeAllBlacklist() }
  getBlacklistIds(): Set<string> { return this.socialListSettings.getBlacklistIds() }
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

  // --- Media (TTS / Image / Video) ---
  setTtsPerson(v: number): void { this.mediaSettings.setTtsPerson(v) }
  setTtsSpeed(v: number): void { this.mediaSettings.setTtsSpeed(v) }
  setTtsVolume(v: number): void { this.mediaSettings.setTtsVolume(v) }
  setTtsPitch(v: number): void { this.mediaSettings.setTtsPitch(v) }
  setImageLoadStrategy(v: string): void { this.mediaSettings.setImageLoadStrategy(v) }
  setEnableImageSizePrefetch(enabled: boolean): void { this.mediaSettings.setEnableImageSizePrefetch(enabled) }
  setVideoMuted(enabled: boolean): void { this.mediaSettings.setVideoMuted(enabled) }

  // --- Internal WebView ---
  /** 设置是否在应用内 WebView 打开无关联链接 */
  setUseInternalWebView(enabled: boolean): void {
    this.state.useInternalWebView = enabled
    AppStorage.setOrCreate(KEY_USE_INTERNAL_WEBVIEW, enabled)
    this.persistSettings()
  }

  // --- Reading ---
  setThreadNavMode(v: string): void { this.readingSettings.setThreadNavMode(v) }
  setPrefetchPageCount(v: number): void { this.readingSettings.setPrefetchPageCount(v) }

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

  // --- Web Search ---
  addWebSearchProfile(profile: WebSearchProviderProfile): void { this.webSearchSettings.addProfile(profile) }
  updateWebSearchProfile(profile: WebSearchProviderProfile): void { this.webSearchSettings.updateProfile(profile) }
  deleteWebSearchProfile(id: string): void { this.webSearchSettings.deleteProfile(id) }
  setActiveWebSearchProfile(id: string): void { this.webSearchSettings.setActiveProfile(id) }
  getActiveWebSearchProfile(): WebSearchProviderProfile | null { return this.webSearchSettings.getActiveProfile() }
}
