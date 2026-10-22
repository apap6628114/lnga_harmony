/**
 * AI 设置域子 store。
 *
 * 管理自定义 AI 提供方配置的增删改查及激活切换，
 * 遵循 SettingsContext 注入模式，子 store 之间无横向 import。
 */

import { SettingsContext } from '../SettingsContext'
import { SettingsState } from '../SettingsState'
import { AiProviderProfile, clampAgentSteps, normalizeAiProfile } from '../../../model/AiConfig'
import {
  AiSearchProfile,
  migrateSearchProfileFromChat,
  normalizeAiSearchProfile
} from '../../../model/AiSearchConfig'
import { DEFAULT_SYSTEM_PROMPTS } from '../../../model/AiScenarioConfig'
import {
  AiToolSettings,
  enabledAiToolNames,
  isAiToolEnabled,
  normalizeAiToolSettings,
  withAiToolEnabled
} from '../../../model/AiToolConfig'
import {
  AiAgentPreset,
  builtinPresets,
  isBuiltinPresetId,
  normalizeAiAgentPreset,
  resolvePresetPrompt
} from '../../../model/AiAgentPreset'
import { KEY_AI_CONFIG_VERSION } from '../../../common/constants/AppStorageKeys'
import { bumpAppStorageVersion } from '../../../common/utils/AppStorageVersion'

/** 生成简单唯一 ID */
function generateId(): string {
  return 'ai_' + Date.now() + '_' + Math.floor(Math.random() * 10000)
}

/** 生成搜索配置唯一 ID */
function generateSearchId(): string {
  return 'ais_' + Date.now() + '_' + Math.floor(Math.random() * 10000)
}

/** 生成 AI 任务唯一 ID */
function generatePresetId(): string {
  return 'task_' + Date.now() + '_' + Math.floor(Math.random() * 10000)
}

/**
 * 合并内置任务与用户任务。
 *
 * 内置任务永远存在且排在最前；用户对内置任务改过的工具 / 开关 / 入口予以保留，
 * 只有缺失字段才回落到内置默认值。
 *
 * @param list - 持久化读出的任务
 * @returns 合并后的任务列表（内置在前）
 */
function mergeBuiltinPresets(list: AiAgentPreset[]): AiAgentPreset[] {
  const result: AiAgentPreset[] = []
  const builtins: AiAgentPreset[] = builtinPresets()
  for (let i: number = 0; i < builtins.length; i++) {
    const fallback: AiAgentPreset = builtins[i]
    let existing: AiAgentPreset | null = null
    for (let j: number = 0; j < list.length; j++) {
      if (list[j].id === fallback.id) {
        existing = list[j]
        break
      }
    }
    if (existing === null) {
      result.push(fallback)
      continue
    }
    const kept: AiAgentPreset = new AiAgentPreset()
    kept.id = fallback.id
    kept.name = existing.name.length > 0 ? existing.name : fallback.name
    kept.icon = existing.icon
    kept.description = existing.description.length > 0 ? existing.description : fallback.description
    kept.tools = existing.tools
    kept.contexts = existing.contexts.length > 0 ? existing.contexts : fallback.contexts
    kept.entries = existing.entries.length > 0 ? existing.entries : fallback.entries
    kept.starters = existing.starters
    kept.builtin = true
    kept.enabled = existing.enabled
    result.push(kept)
  }
  for (let i: number = 0; i < list.length; i++) {
    if (!isBuiltinPresetId(list[i].id)) {
      result.push(list[i])
    }
  }
  return result
}

/**
 * 复制一个任务对象（避免 UI 编辑直接改到 state 里的实例）。
 *
 * @param src - 源任务
 * @returns 新任务
 */
function clonePreset(src: AiAgentPreset): AiAgentPreset {
  const dest: AiAgentPreset = new AiAgentPreset()
  dest.id = src.id
  dest.name = src.name
  dest.icon = src.icon
  dest.description = src.description
  dest.systemPrompt = src.systemPrompt
  dest.tools = copyStrings(src.tools)
  dest.contexts = copyStrings(src.contexts)
  dest.entries = copyStrings(src.entries)
  dest.starters = copyStrings(src.starters)
  dest.builtin = src.builtin
  dest.enabled = src.enabled
  return dest
}

/**
 * 复制字符串数组。
 *
 * @param src - 源数组
 * @returns 新数组
 */
function copyStrings(src: string[]): string[] {
  const dest: string[] = []
  for (let i: number = 0; i < src.length; i++) {
    dest.push(src[i])
  }
  return dest
}

/**
 * 复制任务数组（浅拷贝元素引用，调用方只做替换/追加）。
 *
 * @param src - 源数组
 * @returns 新数组
 */
function copyPresets(src: AiAgentPreset[]): AiAgentPreset[] {
  const dest: AiAgentPreset[] = []
  for (let i: number = 0; i < src.length; i++) {
    dest.push(src[i])
  }
  return dest
}


/**
 * AI 设置域子 store。
 *
 * 管理自定义 AI 提供方配置的增删改查及激活切换。
 */
export class AiSettings {
  /** 设置域上下文。 */
  private ctx: SettingsContext
  /** 本次加载是否执行了搜索配置迁移（需要回写持久化，否则每次冷启动都会重新迁移换 id）。 */
  private searchMigrationPending: boolean = false
  /** 本次加载是否补齐了全局工具设置 / 内置任务（同样需要回写一次）。 */
  private presetMigrationPending: boolean = false

  /**
   * 创建 AI 设置域子 store。
   *
   * @param ctx - 设置域共享上下文
   */
  constructor(ctx: SettingsContext) {
    this.ctx = ctx
  }

  /**
   * 添加新的 AI 提供方配置。
   *
   * @param profile - 新配置（id 字段被自动赋值）
   */
  addProfile(profile: AiProviderProfile): void {
    profile.id = generateId()
    this.ctx.state.aiProfiles = [...this.ctx.state.aiProfiles, profile]
    this.ctx.persist()
    this.notifyAiConfigChanged()
  }

  /**
   * 更新已有的 AI 提供方配置。
   *
   * @param profile - 已变更的配置
   */
  updateProfile(profile: AiProviderProfile): void {
    const newList: AiProviderProfile[] = []
    for (let i = 0; i < this.ctx.state.aiProfiles.length; i++) {
      if (this.ctx.state.aiProfiles[i].id === profile.id) {
        newList.push(profile)
      } else {
        newList.push(this.ctx.state.aiProfiles[i])
      }
    }
    this.ctx.state.aiProfiles = newList
    this.ctx.persist()
    this.notifyAiConfigChanged()
  }

  /**
   * 删除指定 ID 的 AI 提供方配置。
   *
   * 若删除的是当前激活配置，自动切换到剩余配置的第一项。
   *
   * @param id - 待删除的配置 ID
   */
  deleteProfile(id: string): void {
    const newList: AiProviderProfile[] = []
    for (let i = 0; i < this.ctx.state.aiProfiles.length; i++) {
      if (this.ctx.state.aiProfiles[i].id !== id) {
        newList.push(this.ctx.state.aiProfiles[i])
      }
    }
    this.ctx.state.aiProfiles = newList

    if (this.ctx.state.activeAiProfileId === id || !this.hasProfile(this.ctx.state.activeAiProfileId)) {
      this.ctx.state.activeAiProfileId = newList.length > 0 ? newList[0].id : ''
    }

    this.ctx.persist()
    this.notifyAiConfigChanged()
  }

  /**
   * 设置当前激活的 AI 配置。
   *
   * @param id - 配置 ID
   */
  setActiveProfile(id: string): void {
    this.ctx.state.activeAiProfileId = this.hasProfile(id) ? id : ''
    this.ctx.persist()
    this.notifyAiConfigChanged()
  }

  /**
   * 获取当前激活的 AI 配置。
   *
   * @returns 激活的配置，若未选择或配置已不存在则返回 null
   */
  getActiveProfile(): AiProviderProfile | null {
    for (let i = 0; i < this.ctx.state.aiProfiles.length; i++) {
      if (this.ctx.state.aiProfiles[i].id === this.ctx.state.activeAiProfileId) {
        return this.ctx.state.aiProfiles[i]
      }
    }
    return null
  }

  /** 从持久化对象加载 AI 设置 */
  load(saved: SettingsState): void {
    if (saved.aiProfiles) {
      const profiles: AiProviderProfile[] = []
      for (let i = 0; i < saved.aiProfiles.length; i++) {
        // 旧版本配置缺少协议 / 工具 / Agent 字段，统一补齐默认值
        profiles.push(normalizeAiProfile(saved.aiProfiles[i]))
      }
      this.ctx.state.aiProfiles = profiles
    }
    if (saved.activeAiProfileId !== undefined) {
      this.ctx.state.activeAiProfileId = this.hasProfile(saved.activeAiProfileId) ? saved.activeAiProfileId : ''
    }
    this.loadSearchProfiles(saved)
    if (saved.scenarioSystemPrompts !== undefined) {
      const src: Record<string, string> = saved.scenarioSystemPrompts
      const prompts: Record<string, string> = {}
      const keys: string[] = Object.keys(src)
      for (let i = 0; i < keys.length; i++) {
        prompts[keys[i]] = src[keys[i]]
      }
      this.ctx.state.scenarioSystemPrompts = prompts
    }
    // 工具与任务依赖已加载的 aiProfiles（迁移要读激活配置），必须放在最后
    this.loadTools(saved)
    this.loadPresets(saved)
  }

  /**
   * 加载全局工具设置。
   *
   * 老版本把工具开关挂在每套对话配置上，这里借激活配置做一次性迁移；
   * 之后工具与模型彻底解耦。
   *
   * @param saved - 持久化状态
   */
  private loadTools(saved: SettingsState): void {
    const raw: AiToolSettings | undefined = saved.aiToolSettings
    this.ctx.state.aiToolSettings = normalizeAiToolSettings(
      raw, this.ctx.state.aiProfiles, this.ctx.state.activeAiProfileId)
    if (raw === undefined || raw === null) {
      this.presetMigrationPending = true
    }
  }

  /**
   * 加载 AI 任务列表。
   *
   * 老版本没有任务概念：首次加载时用内置任务初始化，并保证两条内置任务永远存在
   * （用户改过工具 / 开关的保留其修改，缺失的补默认）。
   *
   * @param saved - 持久化状态
   */
  private loadPresets(saved: SettingsState): void {
    const savedPresets: AiAgentPreset[] | undefined = saved.aiPresets
    if (savedPresets === undefined || savedPresets === null) {
      this.ctx.state.aiPresets = builtinPresets()
      this.presetMigrationPending = true
      return
    }
    const list: AiAgentPreset[] = []
    for (let i: number = 0; i < savedPresets.length; i++) {
      list.push(normalizeAiAgentPreset(savedPresets[i]))
    }
    const merged: AiAgentPreset[] = mergeBuiltinPresets(list)
    this.ctx.state.aiPresets = merged
    if (merged.length !== list.length) {
      this.presetMigrationPending = true
    }
  }

  /**
   * 加载搜索配置；旧版本没有独立搜索配置时从对话配置迁移一次。
   *
   * @param saved - 持久化状态
   */
  private loadSearchProfiles(saved: SettingsState): void {
    const savedProfiles: AiSearchProfile[] | undefined = saved.aiSearchProfiles
    if (savedProfiles !== undefined && savedProfiles !== null) {
      // 字段存在即尊重用户状态：空数组表示「用户主动删光了」，不能再次迁移回默认配置
      if (savedProfiles.length === 0) {
        this.ctx.state.aiSearchProfiles = []
        this.ctx.state.activeAiSearchProfileId = ''
        return
      }
      const profiles: AiSearchProfile[] = []
      for (let i = 0; i < savedProfiles.length; i++) {
        profiles.push(normalizeAiSearchProfile(savedProfiles[i]))
      }
      this.ctx.state.aiSearchProfiles = profiles
      const activeId: string = saved.activeAiSearchProfileId ?? ''
      this.ctx.state.activeAiSearchProfileId =
        this.hasSearchProfile(activeId) ? activeId : profiles[0].id
      return
    }

    // 字段缺失 = 旧版本数据：从激活的对话配置迁移工具密钥 / 端点 / 服务商
    const chat: AiProviderProfile | null = this.getActiveProfile()
    const fallback: AiProviderProfile | null =
      chat !== null ? chat : (this.ctx.state.aiProfiles.length > 0 ? this.ctx.state.aiProfiles[0] : null)
    const migrated: AiSearchProfile = migrateSearchProfileFromChat(fallback)
    migrated.id = generateSearchId()
    const profiles: AiSearchProfile[] = []
    profiles.push(migrated)
    this.ctx.state.aiSearchProfiles = profiles
    this.ctx.state.activeAiSearchProfileId = migrated.id
    // 迁移结果必须尽快落盘：否则用户一改动前，每次冷启动都会重新迁移并换 id
    this.searchMigrationPending = true
  }

  /**
   * 取出并清空「本次加载执行过搜索配置迁移」标记。
   *
   * @returns true 表示本次加载发生了迁移，调用方应回写持久化
   */
  consumeSearchMigration(): boolean {
    const pending: boolean = this.searchMigrationPending
    this.searchMigrationPending = false
    return pending
  }

  /**
   * 取出并清空「本次加载补齐过工具设置 / 内置任务」标记。
   *
   * @returns true 表示本次加载发生了补齐，调用方应回写持久化
   */
  consumePresetMigration(): boolean {
    const pending: boolean = this.presetMigrationPending
    this.presetMigrationPending = false
    return pending
  }

  // ============== 全局工具 ==============

  /**
   * 获取全局工具设置。
   *
   * @returns 工具设置
   */
  getToolSettings(): AiToolSettings {
    return this.ctx.state.aiToolSettings
  }

  /**
   * 判断某个工具是否全局启用。
   *
   * @param name - 工具名称
   * @returns true 表示启用
   */
  isToolEnabled(name: string): boolean {
    return isAiToolEnabled(this.ctx.state.aiToolSettings, name)
  }

  /**
   * 切换全局工具开关（对所有 AI 配置生效）。
   *
   * @param name - 工具名称
   * @param enabled - 是否启用
   */
  setToolEnabled(name: string, enabled: boolean): void {
    this.ctx.state.aiToolSettings =
      withAiToolEnabled(this.ctx.state.aiToolSettings, name, enabled)
    this.ctx.persist()
    this.notifyAiConfigChanged()
  }

  /**
   * 获取当前全局启用的工具名。
   *
   * @returns 工具名数组
   */
  getEnabledToolNames(): string[] {
    return enabledAiToolNames(this.ctx.state.aiToolSettings)
  }

  /**
   * 设置全局 Agent 工具轮数。
   *
   * @param steps - 轮数
   */
  setToolMaxSteps(steps: number): void {
    const next: AiToolSettings = new AiToolSettings()
    next.maxAgentSteps = clampAgentSteps(steps)
    const keys: string[] = Object.keys(this.ctx.state.aiToolSettings.enabled)
    for (let i: number = 0; i < keys.length; i++) {
      next.enabled[keys[i]] = this.ctx.state.aiToolSettings.enabled[keys[i]]
    }
    this.ctx.state.aiToolSettings = next
    this.ctx.persist()
    this.notifyAiConfigChanged()
  }

  /**
   * 获取全局 Agent 工具轮数。
   *
   * @returns 轮数
   */
  getToolMaxSteps(): number {
    return this.ctx.state.aiToolSettings.maxAgentSteps
  }

  // ============== AI 任务 ==============

  /**
   * 确保内置任务存在。
   *
   * 首次启动（没有持久化）时 load 不会执行，任务列表会是空的；
   * 这里做一次惰性补齐，保证用户在任何时候都能看到内置任务。
   */
  ensurePresets(): void {
    if (this.ctx.state.aiPresets.length > 0) {
      return
    }
    this.ctx.state.aiPresets = builtinPresets()
    this.ctx.persist()
  }

  /**
   * 获取全部任务（内置在前，自定义按创建顺序）。
   *
   * @returns 任务列表
   */
  listPresets(): AiAgentPreset[] {
    if (this.ctx.state.aiPresets.length === 0) {
      this.ensurePresets()
    }
    return this.ctx.state.aiPresets
  }

  /**
   * 获取在指定入口可用的任务。
   *
   * @param entry - 入口标识（PRESET_ENTRY_*）
   * @returns 已启用的任务列表
   */
  listPresetsByEntry(entry: string): AiAgentPreset[] {
    this.ensurePresets()
    const result: AiAgentPreset[] = []
    const list: AiAgentPreset[] = this.ctx.state.aiPresets
    for (let i: number = 0; i < list.length; i++) {
      if (!list[i].enabled) {
        continue
      }
      if (list[i].entries.indexOf(entry) >= 0) {
        result.push(list[i])
      }
    }
    return result
  }

  /**
   * 按 ID 获取任务。
   *
   * @param id - 任务 ID
   * @returns 任务，不存在时返回 null
   */
  getPreset(id: string): AiAgentPreset | null {
    if (id.length === 0) {
      return null
    }
    this.ensurePresets();
    const list: AiAgentPreset[] = this.ctx.state.aiPresets
    for (let i: number = 0; i < list.length; i++) {
      if (list[i].id === id) {
        return list[i]
      }
    }
    return null
  }

  /**
   * 新增自定义任务。
   *
   * @param preset - 任务（id 由本方法赋值）
   * @returns 落库后的任务
   */
  addPreset(preset: AiAgentPreset): AiAgentPreset {
    const next: AiAgentPreset = clonePreset(preset)
    next.id = generatePresetId()
    next.builtin = false
    next.enabled = true
    const list: AiAgentPreset[] = copyPresets(this.ctx.state.aiPresets)
    list.push(next)
    this.ctx.state.aiPresets = list
    this.ctx.persist()
    this.notifyAiConfigChanged()
    return next
  }

  /**
   * 更新任务。
   *
   * 内置任务只允许改提示词以外的字段（提示词走场景存储），这里统一按 id 替换。
   *
   * @param preset - 已变更的任务
   */
  updatePreset(preset: AiAgentPreset): void {
    const list: AiAgentPreset[] = []
    const src: AiAgentPreset[] = this.ctx.state.aiPresets
    for (let i: number = 0; i < src.length; i++) {
      if (src[i].id === preset.id) {
        list.push(clonePreset(preset))
      } else {
        list.push(src[i])
      }
    }
    this.ctx.state.aiPresets = list
    this.ctx.persist()
    this.notifyAiConfigChanged()
  }

  /**
   * 删除自定义任务（内置任务不可删除）。
   *
   * @param id - 任务 ID
   * @returns true 表示已删除
   */
  deletePreset(id: string): boolean {
    if (this.getPreset(id) === null || isBuiltinPresetId(id)) {
      return false
    }
    const list: AiAgentPreset[] = []
    const src: AiAgentPreset[] = this.ctx.state.aiPresets
    for (let i: number = 0; i < src.length; i++) {
      if (src[i].id !== id) {
        list.push(src[i])
      }
    }
    this.ctx.state.aiPresets = list
    this.ctx.persist()
    this.notifyAiConfigChanged()
    return true
  }

  /**
   * 复制任务为新自定义任务。
   *
   * @param id - 源任务 ID
   * @returns 新任务，源任务不存在时返回 null
   */
  duplicatePreset(id: string): AiAgentPreset | null {
    const src: AiAgentPreset | null = this.getPreset(id)
    if (src === null) {
      return null
    }
    const copy: AiAgentPreset = clonePreset(src)
    copy.name = src.name + ' 副本'
    copy.builtin = false
    return this.addPreset(copy)
  }

  /**
   * 取任务实际生效的 System Prompt。
   *
   * @param id - 任务 ID
   * @returns 提示词；任务不存在时返回空串
   */
  getPresetPrompt(id: string): string {
    const preset: AiAgentPreset | null = this.getPreset(id)
    if (preset === null) {
      return ''
    }
    return resolvePresetPrompt(preset, this.ctx.state.scenarioSystemPrompts)
  }

  /**
   * 写入任务的 System Prompt。
   *
   * 内置任务的提示词继续存 `scenarioSystemPrompts`（与旧版本完全兼容），
   * 自定义任务存自身字段。
   *
   * @param id - 任务 ID
   * @param prompt - 新提示词
   */
  setPresetPrompt(id: string, prompt: string): void {
    const preset: AiAgentPreset | null = this.getPreset(id)
    if (preset === null) {
      return
    }
    if (preset.builtin) {
      this.setScenarioPrompt(id, prompt)
      return
    }
    const next: AiAgentPreset = clonePreset(preset)
    next.systemPrompt = prompt
    this.updatePreset(next)
  }

  /**
   * 恢复任务默认提示词。
   *
   * @param id - 任务 ID
   */
  resetPresetPrompt(id: string): void {
    const preset: AiAgentPreset | null = this.getPreset(id)
    if (preset === null) {
      return
    }
    if (preset.builtin) {
      this.resetScenarioPrompt(id)
      return
    }
    const next: AiAgentPreset = clonePreset(preset)
    next.systemPrompt = ''
    this.updatePreset(next)
  }

  /**
   * 添加搜索配置。
   *
   * @param profile - 新配置（id 自动赋值）
   */
  addSearchProfile(profile: AiSearchProfile): void {
    profile.id = generateSearchId()
    const next: AiSearchProfile[] = []
    for (let i: number = 0; i < this.ctx.state.aiSearchProfiles.length; i++) {
      next.push(this.ctx.state.aiSearchProfiles[i])
    }
    next.push(profile)
    this.ctx.state.aiSearchProfiles = next
    if (this.ctx.state.activeAiSearchProfileId.length === 0) {
      this.ctx.state.activeAiSearchProfileId = profile.id
    }
    this.ctx.persist()
    this.notifyAiConfigChanged()
  }

  /**
   * 更新搜索配置。
   *
   * @param profile - 已变更的配置
   */
  updateSearchProfile(profile: AiSearchProfile): void {
    const next: AiSearchProfile[] = []
    for (let i: number = 0; i < this.ctx.state.aiSearchProfiles.length; i++) {
      if (this.ctx.state.aiSearchProfiles[i].id === profile.id) {
        next.push(profile)
      } else {
        next.push(this.ctx.state.aiSearchProfiles[i])
      }
    }
    this.ctx.state.aiSearchProfiles = next
    this.ctx.persist()
    this.notifyAiConfigChanged()
  }

  /**
   * 删除搜索配置；删除激活项时自动切换到剩余第一项。
   *
   * @param id - 配置 ID
   */
  deleteSearchProfile(id: string): void {
    const next: AiSearchProfile[] = []
    for (let i: number = 0; i < this.ctx.state.aiSearchProfiles.length; i++) {
      if (this.ctx.state.aiSearchProfiles[i].id !== id) {
        next.push(this.ctx.state.aiSearchProfiles[i])
      }
    }
    this.ctx.state.aiSearchProfiles = next
    if (this.ctx.state.activeAiSearchProfileId === id ||
      !this.hasSearchProfile(this.ctx.state.activeAiSearchProfileId)) {
      this.ctx.state.activeAiSearchProfileId = next.length > 0 ? next[0].id : ''
    }
    this.ctx.persist()
    this.notifyAiConfigChanged()
  }

  /**
   * 设置激活的搜索配置。
   *
   * @param id - 配置 ID
   */
  setActiveSearchProfile(id: string): void {
    this.ctx.state.activeAiSearchProfileId = this.hasSearchProfile(id) ? id : ''
    this.ctx.persist()
    this.notifyAiConfigChanged()
  }

  /**
   * 获取激活的搜索配置。
   *
   * @returns 激活配置，不存在时返回 null
   */
  getActiveSearchProfile(): AiSearchProfile | null {
    for (let i: number = 0; i < this.ctx.state.aiSearchProfiles.length; i++) {
      if (this.ctx.state.aiSearchProfiles[i].id === this.ctx.state.activeAiSearchProfileId) {
        return this.ctx.state.aiSearchProfiles[i]
      }
    }
    return null
  }

  /**
   * 判断指定搜索配置是否存在。
   *
   * @param id - 配置 ID
   * @returns 是否存在
   */
  private hasSearchProfile(id: string): boolean {
    if (id.length === 0) {
      return false
    }
    for (let i: number = 0; i < this.ctx.state.aiSearchProfiles.length; i++) {
      if (this.ctx.state.aiSearchProfiles[i].id === id) {
        return true
      }
    }
    return false
  }

  /** 重置 AI 设置为默认，保留已配置的 profiles 由 SettingsState 重建时清空 */
  reset(): void {
  }

  /**
   * 获取指定场景的 system prompt。
   *
   * 优先返回用户自定义 prompt，未自定义时返回内置默认值。
   *
   * @param scenario - 场景标识
   * @returns system prompt 文本
   */
  getScenarioPrompt(scenario: string): string {
    const custom: string = (this.ctx.state.scenarioSystemPrompts[scenario] ?? '').trim()
    if (custom.length > 0) {
      return custom
    }
    return DEFAULT_SYSTEM_PROMPTS[scenario] ?? ''
  }

  /**
   * 设置指定场景的自定义 system prompt。
   *
   * 若文本与内置默认值完全相同则不写入持久化，
   * 避免 TextArea onChange 回写默认文本导致误标为"自定义"。
   *
   * @param scenario - 场景标识
   * @param prompt - 用户自定义 prompt 文本
   */
  setScenarioPrompt(scenario: string, prompt: string): void {
    const trimmed: string = prompt.trim()

    // 与默认值相同时不写入持久化，避免 TextArea onChange 回写默认值导致误标
    const defaultPrompt: string = DEFAULT_SYSTEM_PROMPTS[scenario] ?? ''
    if (trimmed === defaultPrompt.trim()) {
      // 若之前有持久化记录则清理
      if (this.ctx.state.scenarioSystemPrompts[scenario] !== undefined) {
        this.resetScenarioPrompt(scenario)
      }
      return
    }

    const src: Record<string, string> = this.ctx.state.scenarioSystemPrompts
    const newPrompts: Record<string, string> = {}
    const keys: string[] = Object.keys(src)
    for (let i = 0; i < keys.length; i++) {
      // 只拷贝非当前场景的旧条目
      if (keys[i] !== scenario) {
        newPrompts[keys[i]] = src[keys[i]]
      }
    }
    // 非空时才写入当前场景
    if (trimmed.length > 0) {
      newPrompts[scenario] = trimmed
    }
    this.ctx.state.scenarioSystemPrompts = newPrompts
    this.ctx.persist()
  }

  /**
   * 重置指定场景的自定义 system prompt，恢复为内置默认值。
   *
   * @param scenario - 场景标识
   */
  resetScenarioPrompt(scenario: string): void {
    const src: Record<string, string> = this.ctx.state.scenarioSystemPrompts
    const newPrompts: Record<string, string> = {}
    const keys: string[] = Object.keys(src)
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] !== scenario) {
        newPrompts[keys[i]] = src[keys[i]]
      }
    }
    this.ctx.state.scenarioSystemPrompts = newPrompts
    this.ctx.persist()
  }

  /**
   * 判断指定配置是否存在。
   *
   * @param id - 配置 ID
   * @returns 配置是否存在
   */
  private hasProfile(id: string): boolean {
    if (id.length === 0) {
      return false
    }
    for (let i = 0; i < this.ctx.state.aiProfiles.length; i++) {
      if (this.ctx.state.aiProfiles[i].id === id) {
        return true
      }
    }
    return false
  }

  /**
   * 通知依赖 AI 配置摘要的页面刷新。
   */
  private notifyAiConfigChanged(): void {
    bumpAppStorageVersion(KEY_AI_CONFIG_VERSION)
  }
}
