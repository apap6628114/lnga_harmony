/**
 * AI 配置管理面板。
 *
 * 管理两类独立配置：
 * - AI 服务（对话）：DeepSeek 官方预填 / 自定义服务商；协议、模型拉取、测试连接；
 * - 搜索服务：联网工具（web_search / web_fetch）的执行后端，当前仅 DeepSeek 官方。
 *
 * 两类配置都是一套列表 + 激活一套，互不影响。
 */

import { appStore } from '../../store/AppStore'
import { routerStore } from '../../store/RouterStore'
import { AppColors } from '../../common/constants/Constants'
import { UIMaterialManager } from '../../common/managers/UIMaterialManager'
import { PanelNavBar } from '../../common/components/PanelNavBar'
import { TipsDialog, AlertDialog, CustomContentDialog } from '@kit.ArkUI'
import {
  AiApiProtocol,
  AiProviderKind,
  AiProviderProfile,
  DEFAULT_AI_MAX_AGENT_STEPS,
  DEFAULT_AI_TEMPERATURE,
  DEFAULT_AI_TOOLS_ENDPOINT,
  DEFAULT_DEEPSEEK_ENDPOINT,
  MAX_AI_MAX_AGENT_STEPS,
  MAX_AI_TEMPERATURE,
  MIN_AI_TEMPERATURE,
  SEARCH_PROVIDER_DEEPSEEK,
  clampAgentSteps,
  clampAiTemperature,
  normalizeAiProfile
} from '../../model/AiConfig'
import { AiModelInfo } from '../../model/AiModelInfo'
import {
  AiSearchProfile,
  createDefaultAiSearchProfile,
  normalizeAiSearchProfile
} from '../../model/AiSearchConfig'
import { AiProviderPreset, PROVIDER_PRESETS } from '../../service/ai/AiModelPresets'
import { fetchModelList, ModelListResult, testConnection } from '../../service/ai/AiChatClient'
import {
  createProfileFromPreset,
  endpointPreview,
  formatContextWindow,
  getApiKeyPlaceholder,
  getModelPlaceholder,
  getPresetById,
  isDeepSeekProfile,
  isHttpEndpoint,
  protocolDescription,
  protocolLabel,
  validateProfileInputs
} from '../../service/ai/AiConfigFormLogic'
import type { AiTestResult } from '../../model/AiConfig'
import { aiSearchProviderRegistry } from '../../service/ai/search/SearchProviderRegistry'
import type { AiSearchProvider } from '../../service/ai/search/AiSearchProvider'
import {
  AiScenario,
  SCENARIO_META,
  DEFAULT_SYSTEM_PROMPTS,
  SCENARIO_INJECTED_FIELDS,
  type InjectedFieldInfo
} from '../../model/AiScenarioConfig'
import { TitleScrollEffect } from '../../common/utils/TitleScrollEffect'
import { resolveKeyboardAppearance } from '../../common/utils/KeyboardAppearanceUtils'

/** 新建方案的哨兵 ID */
const NEW_ID: string = '__new__'
/** 模型列表最多直接展示的条数（避免撑爆页面） */
const MAX_VISIBLE_MODELS: number = 12

@Component
export struct AiSettingsPanel {
  /** 配置列表快照。 */
  @State profiles: AiProviderProfile[] = []
  /** 状态栏高度。 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /**
   * 当前生效明暗色模式。
   *
   * 本页输入框（方案名称 / API 密钥 / 模型名称 / 场景系统提示词）的键盘沉浸样式
   * 必须按**应用主题**（而非系统模式）取色，否则固定主题与系统模式相反时键盘
   * 配色错配（见 `KeyboardAppearanceUtils` 文件头）。
   */
  @StorageProp('effectiveColorMode') effectiveColorMode: string = 'light'
  /**
   * AI 配置版本号。
   *
   * 激活项切换只改 `activeAiProfileId` 这个普通字段，本页既不是 @ObjectLink
   * 也不持有该字段的响应式引用；订阅版本号并在变化时重建列表数组，
   * 保证 Radio 选中态与「哪套生效」同步刷新。
   */
  @StorageProp('aiConfigVersion') @Watch('onAiConfigVersionChange') aiConfigVersion: number = 0
  /** 当前展开编辑的配置 ID。 */
  @State expandedProfileId: string = ''
  /** 方案名称输入值。 */
  @State editNameInput: string = ''
  /** 服务商类型（DeepSeek / 自定义）。 */
  @State editPresetId: string = AiProviderKind.DEEPSEEK
  /** 对话协议。 */
  @State editProtocol: AiApiProtocol = AiApiProtocol.RESPONSES
  /** 服务地址输入值。 */
  @State editEndpointInput: string = ''
  /** API 密钥输入值。 */
  @State editApiKeyInput: string = ''
  /** 模型名称输入值。 */
  @State editModelInput: string = ''
  /** 温度参数输入值。 */
  @State editTemperatureInput: number = DEFAULT_AI_TEMPERATURE
  /** 是否启用客户端工具。 */
  @State editToolsEnabled: boolean = true
  /** 是否启用联网搜索。 */
  @State editWebSearchEnabled: boolean = true
  /** 是否启用网页抓取。 */
  @State editWebFetchEnabled: boolean = true
  /** Agent 最大工具轮数（输入框文本）。 */
  @State editAgentStepsInput: string = DEFAULT_AI_MAX_AGENT_STEPS.toString()
  /** 搜索服务配置列表快照。 */
  @State searchProfiles: AiSearchProfile[] = []
  /** 当前展开编辑的搜索配置 ID。 */
  @State expandedSearchProfileId: string = ''
  /** 搜索配置名称输入值。 */
  @State searchEditName: string = ''
  /** 搜索配置端点输入值。 */
  @State searchEditEndpoint: string = ''
  /** 搜索配置密钥输入值。 */
  @State searchEditApiKey: string = ''
  /** 搜索连接测试结果文案。 */
  @State searchTestMessage: string = ''
  /** 搜索连接测试是否成功。 */
  @State searchTestSuccess: boolean = false
  /** 是否正在测试搜索连接。 */
  @State searchTesting: boolean = false
  /** 拉取到的模型列表。 */
  @State modelOptions: AiModelInfo[] = []
  /** 是否正在拉取模型。 */
  @State loadingModels: boolean = false
  /** 模型拉取结果提示。 */
  @State modelLoadMessage: string = ''
  /** 是否展开模型选择列表。 */
  @State showModelList: boolean = false
  /** 是否展开高级 AI 参数。 */
  @State showAdvancedParams: boolean = false
  /** 当前展开编辑的场景 ID（空字符串表示无展开）。 */
  @State expandedScenario: string = ''
  /** 当前编辑的场景 prompt 文本缓冲。 */
  @State editScenarioPromptInput: string = ''
  /**
   * 场景 Prompt 版本号，用于强制刷新自定义状态徽章。
   *
   * TextArea onChange 和「恢复默认」触发时 bump，
   * 确保 ScenarioBadge 中的 isScenarioCustom 能读到最新持久化状态。
   */
  @State scenarioPromptVersion: number = 0
  /** 是否展开数据预览。 */
  @State showDataPreview: boolean = false
  /** 测试连接结果文案。 */
  @State testResultMessage: string = ''
  /** 测试连接是否成功。 */
  @State testSuccess: boolean = false
  /** 是否正在测试连接。 */
  @State testing: boolean = false
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 滚动容器当前视口高度。 */
  @State scrollViewportHeight: number = 1
  /** 测试连接请求序号。 */
  private testConnectionRequestId: number = 0
  /** 模型拉取请求序号。 */
  private modelRequestId: number = 0
  /** 搜索连接测试请求序号。 */
  private searchTestRequestId: number = 0
  /** 新建表单的初始方案名，用于判断用户是否真的改过名称。 */
  private newProfileBaselineName: string = ''
  /** AI 设置页滚动控制器。 */
  private scroller: Scroller = new Scroller()

  /** 按滚动容器绝对偏移同步标题栏视觉效果。 */
  private syncTitleScrollEffect(): void {
    const progress: number = TitleScrollEffect.getProgress(
      this.scroller.currentOffset().yOffset,
      this.statusBarHeight
    )
    if (TitleScrollEffect.shouldUpdateProgress(this.titleScrollEffectProgress, progress)) {
      this.titleScrollEffectProgress = progress
    }
  }

  /** 是否正在新建方案 */
  private isNew(): boolean {
    return this.expandedProfileId === NEW_ID
  }

  /** 删除确认弹窗控制器。 */
  deleteConfirmController?: CustomDialogController
  /** 搜索配置删除确认弹窗控制器。 */
  searchDeleteConfirmController?: CustomDialogController
  /** 服务商预设选择弹窗控制器。 */
  providerPickerController?: CustomDialogController
  /** 放弃修改确认弹窗控制器。 */
  discardConfirmController?: CustomDialogController
  /** 服务商选择弹窗内的临时选中下标（点确定才生效）。 */
  private pendingPresetIndex: number = 0

  /** 页面出现时同步配置列表并注册返回拦截。 */
  aboutToAppear(): void {
    this.syncProfiles()
    this.syncSearchProfiles()
    const entry = routerStore.topActivity
    if (entry) {
      entry.preBack = (): boolean => {
        if (this.hasUnsavedEdit() || this.hasSearchUnsavedEdit()) {
          this.showDiscardConfirm((): void => {
            this.doCollapse()
            this.doCollapseSearch()
            if (entry) {
              entry.preBack = undefined
            }
            routerStore.back()
          })
          return true
        }
        return false
      }
    }
  }

  /** 页面消失时释放弹窗控制器引用并注销返回拦截。 */
  aboutToDisappear(): void {
    const entry = routerStore.topActivity
    if (entry) {
      entry.preBack = undefined
    }
    this.deleteConfirmController = undefined
    this.searchDeleteConfirmController = undefined
    this.providerPickerController = undefined
    this.discardConfirmController = undefined
  }

  /** 同步当前持久化配置列表到页面状态。 */
  private syncProfiles(): void {
    const src: AiProviderProfile[] = appStore.settings.aiProfiles
    const next: AiProviderProfile[] = []
    for (let i: number = 0; i < src.length; i++) {
      next.push(src[i])
    }
    this.profiles = next
  }

  /**
   * AI 配置版本变化时重建列表快照，刷新激活态与删除/新增结果。
   */
  private onAiConfigVersionChange(): void {
    this.syncProfiles()
    this.syncSearchProfiles()
  }

  /**
   * 展开指定卡片。
   *
   * 若当前有未保存的编辑，先弹出放弃确认。
   *
   * @param profileId - 已有配置的 ID，或 NEW_ID 表示新建
   */
  private expandCard(profileId: string): void {
    if (this.expandedProfileId === profileId) {
      return
    }
    if (this.hasUnsavedEdit()) {
      this.showDiscardConfirm((): void => {
        this.doExpandCard(profileId)
      })
      return
    }
    this.doExpandCard(profileId)
  }

  /**
   * 执行卡片展开并初始化表单缓存。
   *
   * @param profileId - 已有配置的 ID，或 NEW_ID 表示新建
   */
  private doExpandCard(profileId: string): void {
    this.invalidatePendingRequests()
    this.expandedProfileId = profileId
    this.testResultMessage = ''
    this.testSuccess = false
    this.showAdvancedParams = false
    this.resetModelState()

    if (profileId === NEW_ID) {
      this.applyPresetToForm(PROVIDER_PRESETS[0], false)
    } else {
      const profile: AiProviderProfile | null = this.findProfile(profileId)
      if (profile) {
        this.applyProfileToForm(profile)
      }
    }
  }

  /**
   * 把已有配置填入表单。
   *
   * @param profile - AI 配置
   */
  private applyProfileToForm(profile: AiProviderProfile): void {
    this.editNameInput = profile.name
    this.editPresetId = profile.presetId
    this.editProtocol = profile.protocol
    this.editEndpointInput = profile.endpoint
    this.editApiKeyInput = profile.apiKey
    this.editModelInput = profile.modelName
    this.editTemperatureInput = clampAiTemperature(profile.temperature)
    this.editToolsEnabled = profile.toolsEnabled
    this.editWebSearchEnabled = profile.enableWebSearch
    this.editWebFetchEnabled = profile.enableWebFetch
    this.editAgentStepsInput = clampAgentSteps(profile.maxAgentSteps).toString()
  }

  /**
   * 用预设初始化表单。
   *
   * @param preset - 服务商预设
   * @param fillName - 是否用预设名填充方案名
   */
  private applyPresetToForm(preset: AiProviderPreset, fillName: boolean): void {
    const profile: AiProviderProfile = createProfileFromPreset(preset)
    this.applyProfileToForm(profile)
    this.editApiKeyInput = ''
    if (fillName) {
      this.editNameInput = preset.name
    } else {
      // 直接新建时名称留空，避免一打开卡片就被判定为「有未保存修改」
      this.editNameInput = ''
    }
    this.newProfileBaselineName = this.editNameInput
  }

  /** 重置模型拉取状态。 */
  private resetModelState(): void {
    this.modelOptions = []
    this.loadingModels = false
    this.modelLoadMessage = ''
    this.showModelList = false
  }

  /** 折叠当前展开的卡片，若有未保存修改则先确认 */
  private collapseCard(): void {
    if (this.hasUnsavedEdit()) {
      this.showDiscardConfirm((): void => {
        this.doCollapse()
      })
      return
    }
    this.doCollapse()
  }

  /** 执行卡片折叠并清空表单缓存。 */
  private doCollapse(): void {
    this.invalidatePendingRequests()
    this.expandedProfileId = ''
    this.clearEditBuffers()
  }

  /** 使正在返回途中的异步结果失效（连接测试与模型拉取一并作废） */
  private invalidatePendingRequests(): void {
    this.testConnectionRequestId++
    this.modelRequestId++
    this.testing = false
    this.loadingModels = false
  }

  /**
   * 显示放弃修改确认弹窗。
   *
   * @param onConfirm - 用户确认放弃后的动作
   */
  private showDiscardConfirm(onConfirm: () => void): void {
    this.discardConfirmController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: AlertDialog({
        primaryTitle: '放弃修改',
        content: '当前编辑的内容尚未保存，确定要放弃吗？',
        primaryButton: {
          value: '放弃',
          fontColor: AppColors.white,
          background: AppColors.primary,
          action: onConfirm
        },
        secondaryButton: {
          value: '取消'
        }
      }),
      autoCancel: true
    })
    this.discardConfirmController.open()
  }

  /**
   * 判断当前展开的卡片是否有未保存的修改。
   *
   * @returns 是否有未保存修改
   */
  private hasUnsavedEdit(): boolean {
    if (this.expandedProfileId.length === 0) {
      return false
    }
    if (this.expandedProfileId === NEW_ID) {
      const baseline: AiProviderProfile = createProfileFromPreset(PROVIDER_PRESETS[0])
      return this.editNameInput !== this.newProfileBaselineName ||
        this.editApiKeyInput.length > 0 ||
        this.editModelInput !== baseline.modelName ||
        this.editEndpointInput !== baseline.endpoint ||
        this.editPresetId !== baseline.presetId ||
        this.editProtocol !== baseline.protocol ||
        this.editTemperatureInput !== DEFAULT_AI_TEMPERATURE ||
        this.resolveAgentSteps() !== DEFAULT_AI_MAX_AGENT_STEPS ||
        !this.editToolsEnabled ||
        !this.editWebSearchEnabled ||
        !this.editWebFetchEnabled
    }
    const profile: AiProviderProfile | null = this.findProfile(this.expandedProfileId)
    if (!profile) {
      return false
    }
    const saved: AiProviderProfile = normalizeAiProfile(profile)
    return this.editNameInput !== saved.name ||
      this.editApiKeyInput !== saved.apiKey ||
      this.editModelInput !== saved.modelName ||
      this.editEndpointInput !== saved.endpoint ||
      this.editPresetId !== saved.presetId ||
      this.editProtocol !== saved.protocol ||
      this.editTemperatureInput !== clampAiTemperature(saved.temperature) ||
      this.resolveAgentSteps() !== clampAgentSteps(saved.maxAgentSteps) ||
      this.editToolsEnabled !== saved.toolsEnabled ||
      this.editWebSearchEnabled !== saved.enableWebSearch ||
      this.editWebFetchEnabled !== saved.enableWebFetch
  }

  /** 清空编辑表单缓存和异步结果。 */
  private clearEditBuffers(): void {
    this.editNameInput = ''
    this.editPresetId = AiProviderKind.DEEPSEEK
    this.editProtocol = AiApiProtocol.RESPONSES
    this.editEndpointInput = DEFAULT_DEEPSEEK_ENDPOINT
    this.editApiKeyInput = ''
    this.editModelInput = ''
    this.editTemperatureInput = DEFAULT_AI_TEMPERATURE
    this.editToolsEnabled = true
    this.editWebSearchEnabled = true
    this.editWebFetchEnabled = true
    this.editAgentStepsInput = DEFAULT_AI_MAX_AGENT_STEPS.toString()
    this.showAdvancedParams = false
    this.testResultMessage = ''
    this.testSuccess = false
    this.newProfileBaselineName = ''
    this.resetModelState()
  }

  // ============================================================
  // 搜索服务配置
  // ============================================================

  /** 同步搜索配置列表到页面状态。 */
  private syncSearchProfiles(): void {
    const src: AiSearchProfile[] = appStore.settings.aiSearchProfiles
    const next: AiSearchProfile[] = []
    for (let i: number = 0; i < src.length; i++) {
      next.push(src[i])
    }
    this.searchProfiles = next
  }

  /**
   * 判断搜索配置是否为当前激活项。
   *
   * @param id - 配置 ID
   * @returns 是否为激活配置
   */
  private isActiveSearchProfile(id: string): boolean {
    return appStore.settings.activeAiSearchProfileId === id
  }

  /**
   * 展开搜索配置卡片（有未保存修改时先确认）。
   *
   * @param id - 配置 ID
   */
  private expandSearchCard(id: string): void {
    if (this.expandedSearchProfileId === id) {
      return
    }
    if (this.hasSearchUnsavedEdit()) {
      this.showDiscardConfirm((): void => {
        this.doExpandSearchCard(id)
      })
      return
    }
    this.doExpandSearchCard(id)
  }

  /**
   * 执行搜索卡片展开并初始化表单。
   *
   * @param id - 配置 ID
   */
  private doExpandSearchCard(id: string): void {
    this.searchTestRequestId++
    this.searchTesting = false
    this.expandedSearchProfileId = id
    this.searchTestMessage = ''
    this.searchTestSuccess = false
    const profile: AiSearchProfile | null = this.findSearchProfile(id)
    if (profile) {
      const normalized: AiSearchProfile = normalizeAiSearchProfile(profile)
      this.searchEditName = normalized.name
      this.searchEditEndpoint = normalized.endpoint
      this.searchEditApiKey = normalized.apiKey
    }
  }

  /** 折叠搜索卡片（有未保存修改时先确认）。 */
  private collapseSearchCard(): void {
    if (this.hasSearchUnsavedEdit()) {
      this.showDiscardConfirm((): void => {
        this.doCollapseSearch()
      })
      return
    }
    this.doCollapseSearch()
  }

  /** 执行搜索卡片折叠并清空表单。 */
  private doCollapseSearch(): void {
    this.searchTestRequestId++
    this.searchTesting = false
    this.expandedSearchProfileId = ''
    this.searchEditName = ''
    this.searchEditEndpoint = DEFAULT_AI_TOOLS_ENDPOINT
    this.searchEditApiKey = ''
    this.searchTestMessage = ''
    this.searchTestSuccess = false
  }

  /**
   * 按 ID 查找搜索配置。
   *
   * @param id - 配置 ID
   * @returns 找到的配置，未找到时返回 null
   */
  private findSearchProfile(id: string): AiSearchProfile | null {
    for (let i: number = 0; i < this.searchProfiles.length; i++) {
      if (this.searchProfiles[i].id === id) {
        return this.searchProfiles[i]
      }
    }
    return null
  }

  /**
   * 判断搜索卡片是否有未保存修改。
   *
   * @returns 是否有未保存修改
   */
  private hasSearchUnsavedEdit(): boolean {
    if (this.expandedSearchProfileId.length === 0) {
      return false
    }
    const saved: AiSearchProfile | null = this.findSearchProfile(this.expandedSearchProfileId)
    if (!saved) {
      return false
    }
    const normalized: AiSearchProfile = normalizeAiSearchProfile(saved)
    return this.searchEditName !== normalized.name ||
      this.searchEditEndpoint !== normalized.endpoint ||
      this.searchEditApiKey !== normalized.apiKey
  }

  /** 添加一套默认搜索配置（DeepSeek 官方）并展开。 */
  private addSearchProfile(): void {
    const profile: AiSearchProfile = createDefaultAiSearchProfile()
    appStore.settingsStore.addAiSearchProfile(profile)
    appStore.settingsStore.setActiveAiSearchProfile(profile.id)
    this.syncSearchProfiles()
    this.doExpandSearchCard(profile.id)
    appStore.showToast('已添加搜索服务')
  }

  /** 保存当前搜索配置。 */
  private saveSearchProfile(): void {
    if (this.searchEditName.trim().length === 0) {
      appStore.showToast('请输入方案名称')
      return
    }
    if (this.searchEditEndpoint.trim().length === 0) {
      appStore.showToast('请输入服务地址')
      return
    }
    if (!isHttpEndpoint(this.searchEditEndpoint)) {
      appStore.showToast('服务地址需以 http:// 或 https:// 开头')
      return
    }

    const profile: AiSearchProfile = new AiSearchProfile()
    profile.id = this.expandedSearchProfileId
    profile.name = this.searchEditName.trim()
    const old: AiSearchProfile | null = this.findSearchProfile(this.expandedSearchProfileId)
    profile.providerKind = old !== null ? old.providerKind : SEARCH_PROVIDER_DEEPSEEK
    profile.endpoint = this.searchEditEndpoint.trim()
    profile.apiKey = this.searchEditApiKey.trim()

    appStore.settingsStore.updateAiSearchProfile(profile)
    this.syncSearchProfiles()
    appStore.showToast('搜索服务已更新')
    this.doCollapseSearch()
  }

  /**
   * 删除搜索配置。
   *
   * @param id - 配置 ID
   */
  private deleteSearchProfile(id: string): void {
    const profile: AiSearchProfile | null = this.findSearchProfile(id)
    const name: string = profile ? profile.name : '此配置'

    this.searchDeleteConfirmController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: TipsDialog({
        imageRes: $r('app.media.icon_delete'),
        title: '删除搜索服务',
        content: this.isActiveSearchProfile(id)
          ? '你将删除当前正在使用的搜索服务「' + name + '」。\n删除后联网工具会不可用，直到重新添加并激活一套搜索服务。'
          : '确定要删除搜索服务「' + name + '」吗？',
        primaryButton: {
          value: '删除',
          fontColor: AppColors.white,
          background: AppColors.destructive,
          action: (): void => {
            appStore.settingsStore.deleteAiSearchProfile(id)
            this.syncSearchProfiles()
            if (this.expandedSearchProfileId === id) {
              this.doCollapseSearch()
            }
          }
        },
        secondaryButton: {
          value: '取消'
        }
      }),
      autoCancel: true
    })
    this.searchDeleteConfirmController.open()
  }

  /** 测试当前搜索配置的连接（会发起一次真实搜索）。 */
  async doTestSearchConnection(): Promise<void> {
    if (this.searchTesting) {
      return
    }
    if (this.searchEditApiKey.trim().length === 0) {
      appStore.showToast('请先填写 API 密钥')
      return
    }
    if (!isHttpEndpoint(this.searchEditEndpoint)) {
      appStore.showToast('服务地址需以 http:// 或 https:// 开头')
      return
    }

    const requestId: number = this.searchTestRequestId + 1
    this.searchTestRequestId = requestId
    this.searchTesting = true
    this.searchTestMessage = ''

    const old: AiSearchProfile | null = this.findSearchProfile(this.expandedSearchProfileId)
    const temp: AiSearchProfile = new AiSearchProfile()
    temp.name = this.searchEditName
    temp.providerKind = old !== null ? old.providerKind : SEARCH_PROVIDER_DEEPSEEK
    temp.endpoint = this.searchEditEndpoint.trim()
    temp.apiKey = this.searchEditApiKey.trim()

    const provider: AiSearchProvider = aiSearchProviderRegistry.get(temp.providerKind)
    const startTime: number = Date.now()
    try {
      const response = await provider.search(temp, 'DeepSeek', 1, '')
      if (this.searchTestRequestId !== requestId) {
        return
      }
      if (response.success) {
        this.searchTestSuccess = true
        this.searchTestMessage = '连接成功 · 耗时 ' + (Date.now() - startTime).toString() +
          'ms · ' + response.results.length.toString() + ' 条结果'
      } else {
        this.searchTestSuccess = false
        this.searchTestMessage = '连接失败 · ' + response.errorMessage
      }
    } catch (e) {
      if (this.searchTestRequestId === requestId) {
        this.searchTestSuccess = false
        const err: Error = e as Error
        this.searchTestMessage = '连接失败 · ' + (err.message.length > 0 ? err.message : '未知错误')
      }
    } finally {
      if (this.searchTestRequestId === requestId) {
        this.searchTesting = false
      }
    }
  }

  /**
   * 按 ID 查找配置。
   *
   * @param id - 配置 ID
   * @returns 找到的配置，未找到时返回 null
   */
  private findProfile(id: string): AiProviderProfile | null {
    for (let i = 0; i < this.profiles.length; i++) {
      if (this.profiles[i].id === id) {
        return this.profiles[i]
      }
    }
    return null
  }

  /**
   * 判断配置是否为当前激活项。
   *
   * @param id - 配置 ID
   * @returns 是否为当前激活配置
   */
  private isActiveProfile(id: string): boolean {
    return appStore.settings.activeAiProfileId === id
  }

  /** 保存当前表单中的新建或编辑配置。 */
  saveProfile(): void {
    const validation: string = validateProfileInputs(
      this.editNameInput, this.editEndpointInput, this.editModelInput)
    if (validation.length > 0) {
      appStore.showToast(validation)
      return
    }
    const endpoint: string = this.editEndpointInput.trim()
    if (!isHttpEndpoint(endpoint)) {
      appStore.showToast('服务地址需以 http:// 或 https:// 开头')
      return
    }

    const profile: AiProviderProfile = new AiProviderProfile()
    profile.name = this.editNameInput.trim()
    profile.presetId = this.editPresetId
    profile.endpoint = endpoint
    profile.modelName = this.editModelInput.trim()
    profile.protocol = this.editProtocol
    profile.temperature = clampAiTemperature(this.editTemperatureInput)
    profile.apiKey = this.editApiKeyInput.trim()
    profile.toolsEnabled = this.editToolsEnabled
    profile.enableWebSearch = this.editWebSearchEnabled
    profile.enableWebFetch = this.editWebFetchEnabled
    profile.maxAgentSteps = this.resolveAgentSteps()

    if (this.expandedProfileId === NEW_ID) {
      appStore.settingsStore.addAiProfile(profile)
      appStore.settingsStore.setActiveAiProfile(profile.id)
      appStore.showToast('已添加并切换到 ' + profile.name)
    } else {
      profile.id = this.expandedProfileId
      appStore.settingsStore.updateAiProfile(profile)
      appStore.showToast('配置已更新')
    }

    this.syncProfiles()
    this.doCollapse()
  }

  /**
   * 删除指定 AI 配置。
   *
   * @param id - 配置 ID
   */
  deleteProfile(id: string): void {
    const profile: AiProviderProfile | null = this.findProfile(id)
    const name: string = profile ? profile.name : '此配置'

    this.deleteConfirmController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: TipsDialog({
        imageRes: $r('app.media.icon_delete'),
        title: '删除 AI 配置',
        content: this.isActiveProfile(id)
          ? '你将删除当前正在使用的配置「' + name + '」。\n删除后会自动切换到剩余配置；若没有其他配置，AI 功能需要重新添加配置后使用。'
          : '确定要删除配置「' + name + '」吗？\n删除后该配置将从列表中移除。',
        primaryButton: {
          value: '删除',
          fontColor: AppColors.white,
          background: AppColors.destructive,
          action: (): void => {
            appStore.settingsStore.deleteAiProfile(id)
            this.syncProfiles()
            if (this.expandedProfileId === id) {
              this.doCollapse()
            }
          }
        },
        secondaryButton: {
          value: '取消'
        }
      }),
      autoCancel: true
    })
    this.deleteConfirmController.open()
  }

  /**
   * 应用服务商预设到编辑表单。
   *
   * @param index - 预设下标（PROVIDER_PRESETS 索引）
   */
  private applyProviderPreset(index: number): void {
    this.invalidatePendingRequests()
    const preset: AiProviderPreset = PROVIDER_PRESETS[index]
    this.applyPresetToForm(preset, true)
    this.testResultMessage = ''
    this.testSuccess = false
    this.resetModelState()
    this.expandedProfileId = NEW_ID
  }

  /**
   * 显示服务商预设选择弹窗。
   *
   * 使用自定义单选列表：点击列表项只切换选中态（弹窗保持打开），
   * 点「确定」才创建并展开表单。
   */
  showProviderPresetPicker(): void {
    this.pendingPresetIndex = 0
    this.providerPickerController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: CustomContentDialog({
        primaryTitle: '选择服务商',
        contentBuilder: (): void => {
          this.ProviderPickerContent()
        },
        buttons: [
          { value: '取消' },
          {
            value: '确定',
            fontColor: AppColors.white,
            background: AppColors.primary,
            action: (): void => {
              this.applyProviderPreset(this.pendingPresetIndex)
            }
          }
        ]
      }),
      autoCancel: true
    })
    this.providerPickerController.open()
  }

  /** 服务商单选列表内容。 */
  @Builder
  ProviderPickerContent() {
    Column() {
      ForEach(PROVIDER_PRESETS, (preset: AiProviderPreset, index: number) => {
        Row() {
          Radio({ value: preset.id, group: 'aiPresetPicker' })
            .checked(this.pendingPresetIndex === index)
            .onChange((checked: boolean): void => {
              if (checked) {
                this.pendingPresetIndex = index
              }
            })
            .width(20)
            .height(20)

          Column() {
            Text(preset.name)
              .fontSize(15)
              .fontColor(AppColors.textPrimary)
              .width('100%')
            Text(preset.description)
              .fontSize(12)
              .fontColor(AppColors.textTertiary)
              .lineHeight(16)
              .width('100%')
              .margin({ top: 2 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 10 })
        }
        .width('100%')
        .padding({ top: 10, bottom: 10 })
        .alignItems(VerticalAlign.Center)
        .onClick((): void => {
          this.pendingPresetIndex = index
        })
      }, (preset: AiProviderPreset): string => preset.id)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 4 })
  }

  /**
   * 获取模型输入框占位提示。
   *
   * @returns 当前预设的默认模型或通用提示
   */
  private getModelPlaceholder(): string {
    return getModelPlaceholder(this.getPreset())
  }

  /**
   * 获取 API Key 输入框占位提示。
   *
   * @returns 当前预设的密钥格式提示
   */
  private getApiKeyPlaceholder(): string {
    return getApiKeyPlaceholder(this.getPreset())
  }

  /**
   * 获取当前选中的预设。
   *
   * @returns 预设
   */
  private getPreset(): AiProviderPreset {
    return getPresetById(this.editPresetId)
  }

  /**
   * 解析当前编辑场景下的 API Key。
   *
   * 当前表单为空时返回空字符串，避免用户清空密钥后仍使用旧密钥。
   *
   * @returns 有效的 API Key 字符串
   */
  private resolveApiKey(): string {
    return this.editApiKeyInput.trim()
  }

  /**
   * 切换服务商类型。
   *
   * 切到 DeepSeek 时回填官方端点、Responses 协议与默认模型；
   * 切到自定义时保留用户已填写的端点与模型，只把协议换成更通用的
   * Chat Completions（用户仍可手动改回 Responses）。
   *
   * @param kind - 服务商类型
   */
  private selectPresetKind(kind: string): void {
    if (this.editPresetId === kind) {
      return
    }
    this.editPresetId = kind
    this.invalidatePendingRequests()
    this.resetModelState()
    if (kind === AiProviderKind.DEEPSEEK) {
      this.editEndpointInput = DEFAULT_DEEPSEEK_ENDPOINT
      this.editProtocol = AiApiProtocol.RESPONSES
      if (this.editModelInput.trim().length === 0) {
        this.editModelInput = getPresetById(kind).defaultModelName
      }
    } else {
      if (this.editEndpointInput.trim() === DEFAULT_DEEPSEEK_ENDPOINT) {
        this.editEndpointInput = ''
      }
      this.editProtocol = AiApiProtocol.CHAT_COMPLETIONS
    }
  }

  /**
   * 切换对话协议。
   *
   * @param protocol - 协议
   */
  private selectProtocol(protocol: AiApiProtocol): void {
    if (this.editProtocol === protocol) {
      return
    }
    this.editProtocol = protocol
    this.invalidatePendingRequests()
  }

  /**
   * 构造当前表单对应的临时配置（用于测试连接与拉取模型）。
   *
   * @returns 临时配置
   */
  private buildFormProfile(): AiProviderProfile {
    const profile: AiProviderProfile = new AiProviderProfile()
    profile.presetId = this.editPresetId
    profile.endpoint = this.editEndpointInput.trim()
    profile.apiKey = this.resolveApiKey()
    profile.modelName = this.editModelInput.trim()
    profile.protocol = this.editProtocol
    profile.temperature = clampAiTemperature(this.editTemperatureInput)
    profile.toolsEnabled = this.editToolsEnabled
    profile.enableWebSearch = this.editWebSearchEnabled
    profile.enableWebFetch = this.editWebFetchEnabled
    profile.maxAgentSteps = this.resolveAgentSteps()
    return profile
  }

  /**
   * 解析并裁剪 Agent 轮数输入。
   *
   * 输入框允许空串或非法输入，此处统一回退默认值并裁剪到 1–1000。
   *
   * @returns 合法的 Agent 轮数
   */
  private resolveAgentSteps(): number {
    const parsed: number = parseInt(this.editAgentStepsInput)
    if (isNaN(parsed)) {
      return DEFAULT_AI_MAX_AGENT_STEPS
    }
    return clampAgentSteps(parsed)
  }

  /** 拉取当前端点的可用模型列表。 */
  async doFetchModels(): Promise<void> {
    if (this.loadingModels) {
      return
    }
    if (this.editEndpointInput.trim().length === 0) {
      appStore.showToast('请先填写服务地址')
      return
    }
    if (this.resolveApiKey().length === 0) {
      appStore.showToast('请先填写 API 密钥')
      return
    }

    const requestId: number = this.modelRequestId + 1
    this.modelRequestId = requestId
    this.loadingModels = true
    this.modelLoadMessage = ''

    const profile: AiProviderProfile = this.buildFormProfile()
    try {
      const result: ModelListResult = await fetchModelList(profile)
      if (this.modelRequestId !== requestId) {
        return
      }
      if (result.models.length === 0) {
        this.modelOptions = []
        this.showModelList = false
        this.modelLoadMessage = result.errorMessage.length > 0
          ? result.errorMessage
          : '没有拉取到模型，请手动填写模型名称'
        return
      }
      this.modelOptions = result.models
      this.showModelList = true
      this.modelLoadMessage = '已拉取 ' + result.models.length.toString() + ' 个模型'
      if (this.editModelInput.trim().length === 0) {
        this.editModelInput = result.models[0].id
      }
    } catch (e) {
      if (this.modelRequestId === requestId) {
        const err: Error = e as Error
        this.modelLoadMessage = '拉取失败：' + (err.message.length > 0 ? err.message : '未知错误')
      }
    } finally {
      if (this.modelRequestId === requestId) {
        this.loadingModels = false
      }
    }
  }

  /**
   * 从模型列表选中一个模型。
   *
   * @param modelId - 模型标识
   */
  private selectModel(modelId: string): void {
    this.editModelInput = modelId
    this.showModelList = false
  }

  /**
   * 获取模型列表项的副标题。
   *
   * @param model - 模型元数据
   * @returns 副标题文案
   */
  private modelSubtitle(model: AiModelInfo): string {
    const parts: string[] = []
    const context: string = formatContextWindow(model.contextWindow)
    if (context.length > 0) {
      parts.push(context)
    }
    if (model.supportsImage) {
      parts.push('支持图片')
    }
    return parts.join(' · ')
  }

  /** 测试当前表单中的 AI 连接配置。 */
  async doTestConnection(): Promise<void> {
    if (this.testing) {
      return
    }
    if (this.editEndpointInput.trim().length === 0 ||
      this.editModelInput.trim().length === 0) {
      appStore.showToast('请先填写服务地址和模型名称')
      return
    }

    const apiKey: string = this.resolveApiKey()
    if (apiKey.length === 0) {
      appStore.showToast('请先填写 API 密钥')
      return
    }

    const requestId: number = this.testConnectionRequestId + 1
    const profileId: string = this.expandedProfileId
    const endpoint: string = this.editEndpointInput.trim()
    const modelName: string = this.editModelInput.trim()
    const protocol: AiApiProtocol = this.editProtocol

    this.testConnectionRequestId = requestId
    this.testing = true
    this.testResultMessage = ''

    const tempProfile: AiProviderProfile = this.buildFormProfile()

    try {
      const result: AiTestResult = await testConnection(tempProfile)
      if (!this.isCurrentTestConnectionRequest(requestId, profileId, endpoint, apiKey, modelName, protocol)) {
        return
      }
      if (result.success) {
        this.testSuccess = true
        this.testResultMessage = '连接成功 · 耗时 ' + result.durationMs + 'ms\n' + result.message
      } else {
        this.testSuccess = false
        this.testResultMessage = '连接失败 · ' + result.errorMessage
      }
    } catch (e) {
      if (this.isCurrentTestConnectionRequest(requestId, profileId, endpoint, apiKey, modelName, protocol)) {
        this.testSuccess = false
        const err: Error = e as Error
        this.testResultMessage = '连接失败 · ' + (err.message || '未知错误')
      }
    } finally {
      if (this.testConnectionRequestId === requestId) {
        this.testing = false
      }
    }
  }

  /**
   * 判断测试连接请求返回时是否仍属于当前编辑上下文。
   *
   * @param requestId - 请求序号
   * @param profileId - 发起请求时展开的配置 ID
   * @param endpoint - 发起请求时的端点
   * @param apiKey - 发起请求时的密钥
   * @param modelName - 发起请求时的模型名
   * @param protocol - 发起请求时的协议
   * @returns 是否仍为当前请求
   */
  private isCurrentTestConnectionRequest(
    requestId: number,
    profileId: string,
    endpoint: string,
    apiKey: string,
    modelName: string,
    protocol: AiApiProtocol
  ): boolean {
    return this.testConnectionRequestId === requestId &&
      this.expandedProfileId === profileId &&
      this.editEndpointInput.trim() === endpoint &&
      this.editProtocol === protocol &&
      this.resolveApiKey() === apiKey &&
      this.editModelInput.trim() === modelName
  }

  /** 构建 AI 配置页面。 */
  build() {
    Stack() {
      Column() {
        Scroll(this.scroller) {
          Column() {
            Text('AI 服务')
              .fontSize(14)
              .fontColor(AppColors.textPrimary)
              .fontWeight(FontWeight.Medium)
              .width('92%')
              .margin({ top: 8, bottom: 2 })

            Text('默认 DeepSeek 官方：填 Key 即可拉取模型；自定义服务商需自行填写端点与协议。' +
              '联网工具在下方「搜索服务」中单独配置')
              .fontSize(11)
              .fontColor(AppColors.textTertiary)
              .lineHeight(16)
              .width('92%')
              .margin({ bottom: 8, top: 2 })

            if (this.profiles.length === 0 && !this.isNew()) {
              this.EmptyHint()
            } else {
              ForEach(this.profiles, (profile: AiProviderProfile) => {
                this.ProfileCard(profile)
              }, (profile: AiProviderProfile): string => profile.id)
            }

            if (this.isNew()) {
              this.NewProfileCard()
            }

            this.AddButton()
            this.SearchSection()
            this.ScenarioSection()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ bottom: 32, top: 8 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
        .linearGradientBlur(
          TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),
          {
            fractionStops: TitleScrollEffect.getBlurStops(this.scrollViewportHeight, this.statusBarHeight),
            direction: GradientDirection.Bottom
          }
        )
        .onAreaChange((oldValue: Area, newValue: Area): void => {
          if (typeof newValue.height === 'number' && newValue.height !== this.scrollViewportHeight) {
            this.scrollViewportHeight = newValue.height
          }
        })
        .onDidScroll((): void => {
          this.syncTitleScrollEffect()
        })
        .onAppear((): void => {
          this.syncTitleScrollEffect()
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(AppColors.bg)

      PanelNavBar({
        title: 'AI 配置',
        scrollEffectProgress: this.titleScrollEffectProgress,
        onBack: (): void => {
          if (this.hasUnsavedEdit() || this.hasSearchUnsavedEdit()) {
            this.showDiscardConfirm((): void => {
              this.doCollapse()
              this.doCollapseSearch()
              routerStore.back()
            })
            return
          }
          routerStore.back()
        }
      })
        .width('100%')
        .position({ x: 0, y: 0 })
    }
    .width('100%')
    .height('100%')
  }


  // ============================================================
  // 搜索服务配置
  // ============================================================

  /** 构建搜索服务区域。 */
  @Builder
  SearchSection() {
    Column() {
      Text('搜索服务')
        .fontSize(14)
        .fontColor(AppColors.textPrimary)
        .fontWeight(FontWeight.Medium)
        .width('92%')
        .margin({ top: 20, bottom: 2 })

      Text('联网工具（搜索 / 抓取）的执行后端。对话服务与搜索服务相互独立，' +
        '可分别为它们配置密钥；当前仅支持 DeepSeek 官方')
        .fontSize(11)
        .fontColor(AppColors.textTertiary)
        .lineHeight(16)
        .width('92%')
        .margin({ bottom: 8, top: 2 })

      if (this.searchProfiles.length === 0) {
        this.EmptySearchHint()
      } else {
        ForEach(this.searchProfiles, (profile: AiSearchProfile) => {
          this.SearchProfileCard(profile)
        }, (profile: AiSearchProfile): string => profile.id)
      }

      this.AddSearchButton()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 构建搜索配置卡片。
   *
   * @param profile - 搜索配置
   */
  @Builder
  SearchProfileCard(profile: AiSearchProfile) {
    Column() {
      this.SearchProfileCardHeader(profile)
      if (this.expandedSearchProfileId === profile.id) {
        Divider().color(AppColors.separator).width('100%').margin({ bottom: 4 })
        Column() {
          this.SearchFormFields()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 16 })
      }
    }
    .width('92%')
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(12)
    .margin({ top: 8 })
  }

  /**
   * 构建搜索配置卡片头部。
   *
   * @param profile - 搜索配置
   */
  @Builder
  SearchProfileCardHeader(profile: AiSearchProfile) {
    Row() {
      Row() {
        Radio({ value: profile.id, group: 'aiSearchProvider' })
          .checked(this.isActiveSearchProfile(profile.id))
          .onChange((checked: boolean): void => {
            if (checked) {
              appStore.settingsStore.setActiveAiSearchProfile(profile.id)
              this.syncSearchProfiles()
            }
          })
          .width(20)
          .height(20)
      }
      .width(36)
      .height(48)
      .justifyContent(FlexAlign.Center)

      Column() {
        Text(profile.name)
          .fontSize(15)
          .fontColor(AppColors.textPrimary)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.searchProfileSubtitle(profile))
          .fontSize(11)
          .fontColor(AppColors.textTertiary)
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick((): void => {
        if (this.expandedSearchProfileId === profile.id) {
          this.collapseSearchCard()
        } else {
          this.expandSearchCard(profile.id)
        }
      })

      Text('删除')
        .fontSize(12)
        .fontColor(AppColors.destructive)
        .padding({ left: 6, right: 6, top: 4, bottom: 4 })
        .onClick((): void => {
          this.deleteSearchProfile(profile.id)
        })
    }
    .width('100%')
    .padding({ left: 12, right: 8, top: 12, bottom: 12 })
  }

  /**
   * 搜索配置副标题：服务商 + 端点。
   *
   * @param profile - 搜索配置
   * @returns 副标题文案
   */
  private searchProfileSubtitle(profile: AiSearchProfile): string {
    const provider: AiSearchProvider = aiSearchProviderRegistry.get(profile.providerKind)
    const endpoint: string = profile.endpoint.trim().length > 0
      ? profile.endpoint
      : DEFAULT_AI_TOOLS_ENDPOINT
    return provider.getName() + ' · ' + endpoint
  }

  /** 构建搜索配置表单。 */
  @Builder
  SearchFormFields() {
    // ---- 方案名称 ----
    Column() {
      Text('方案名称')
        .fontSize(13)
        .fontColor(AppColors.textSecondary)
        .width('100%')
        .margin({ bottom: 4 })

      TextInput({ placeholder: '为这套搜索服务起个名字', text: this.searchEditName })
        .onChange((v: string): void => {
          this.searchEditName = v
        })
        .width('100%')
        .height(40)
        .attributeModifier(UIMaterialManager.inputMaterial)
        .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
        .borderRadius(8)
        .fontSize(14)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .padding({ left: 12, right: 12 })
    }
    .width('100%')
    .margin({ bottom: 10 })

    // ---- 服务商（当前只读） ----
    Column() {
      Text('服务商')
        .fontSize(13)
        .fontColor(AppColors.textSecondary)
        .width('100%')
        .margin({ bottom: 4 })

      Row() {
        Text(this.searchEditProviderName())
          .fontSize(13)
          .fontColor(AppColors.textPrimary)
          .layoutWeight(1)
        Text('当前仅支持 DeepSeek 官方')
          .fontSize(11)
          .fontColor(AppColors.textTertiary)
      }
      .width('100%')
      .height(36)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(AppColors.bgSecondary)
      .borderRadius(8)
    }
    .width('100%')
    .margin({ bottom: 10 })

    // ---- 服务地址 ----
    Column() {
      Text('服务地址')
        .fontSize(13)
        .fontColor(AppColors.textSecondary)
        .width('100%')
        .margin({ bottom: 4 })

      TextInput({ placeholder: DEFAULT_AI_TOOLS_ENDPOINT, text: this.searchEditEndpoint })
        .onChange((v: string): void => {
          this.searchEditEndpoint = v
        })
        .width('100%')
        .height(40)
        .attributeModifier(UIMaterialManager.inputMaterial)
        .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
        .borderRadius(8)
        .fontSize(14)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .padding({ left: 12, right: 12 })

      Text('Search / Fetch 会请求 ' + this.searchEndpointPreview())
        .fontSize(11)
        .fontColor(AppColors.textTertiary)
        .width('100%')
        .margin({ top: 4 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .margin({ bottom: 10 })

    // ---- API 密钥 ----
    Column() {
      Text('API 密钥')
        .fontSize(13)
        .fontColor(AppColors.textSecondary)
        .width('100%')
        .margin({ bottom: 4 })

      TextInput({ placeholder: 'DeepSeek API Key', text: this.searchEditApiKey })
        .type(InputType.Password)
        .onChange((v: string): void => {
          this.searchEditApiKey = v
        })
        .width('100%')
        .height(40)
        .attributeModifier(UIMaterialManager.inputMaterial)
        .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
        .borderRadius(8)
        .fontSize(14)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .padding({ left: 12, right: 12 })

      Text('联网工具使用这里的密钥；与对话服务的密钥相互独立')
        .fontSize(11)
        .fontColor(AppColors.textTertiary)
        .width('100%')
        .margin({ top: 4 })
        .lineHeight(16)
    }
    .width('100%')
    .margin({ bottom: 10 })

    // ---- 测试连接 ----
    Row() {
      Text(this.searchTesting ? '测试中...' : '测试连接')
        .fontSize(13)
        .fontColor(this.searchTesting ? AppColors.textTertiary : AppColors.primary)
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .border({
          width: 1,
          color: this.searchTesting ? AppColors.textTertiary : AppColors.primary,
          style: BorderStyle.Solid
        })
        .borderRadius(8)
        .onClick((): void => {
          this.doTestSearchConnection()
        })
    }
    .width('100%')
    .margin({ bottom: 2 })

    Text('测试会发起一次真实搜索请求（按次计费）')
      .fontSize(11)
      .fontColor(AppColors.textTertiary)
      .width('100%')
      .margin({ bottom: 10 })
      .lineHeight(16)

    if (this.searchTestMessage.length > 0) {
      Text(this.searchTestMessage)
        .fontSize(12)
        .fontColor(this.searchTestSuccess ? AppColors.success : AppColors.destructive)
        .margin({ bottom: 10 })
        .width('100%')
        .lineHeight(18)
    }

    // ---- 取消 / 保存 ----
    Row() {
      Text('取消')
        .fontSize(14)
        .fontColor(AppColors.textSecondary)
        .layoutWeight(1)
        .height(38)
        .textAlign(TextAlign.Center)
        .onClick((): void => {
          this.collapseSearchCard()
        })

      Text('保存')
        .fontSize(14)
        .fontColor(AppColors.white)
        .layoutWeight(1)
        .height(38)
        .textAlign(TextAlign.Center)
        .backgroundColor(AppColors.primary)
        .borderRadius(10)
        .onClick((): void => {
          this.saveSearchProfile()
        })
    }
    .width('100%')
    .margin({ top: 4 })
  }

  /**
   * 获取当前编辑搜索配置的服务商展示名。
   *
   * @returns 展示名
   */
  private searchEditProviderName(): string {
    const old: AiSearchProfile | null = this.findSearchProfile(this.expandedSearchProfileId)
    const kind: string = old !== null ? old.providerKind : SEARCH_PROVIDER_DEEPSEEK
    return aiSearchProviderRegistry.get(kind).getName()
  }

  /**
   * 拼接搜索端点的实际请求路径预览。
   *
   * @returns 请求路径预览
   */
  private searchEndpointPreview(): string {
    const base: string = this.searchEditEndpoint.trim().replace(/\/+$/, '')
    if (base.length === 0) {
      return DEFAULT_AI_TOOLS_ENDPOINT + '/v1/tools/{search|fetch}'
    }
    if (base.indexOf('/tools/') >= 0) {
      return base
    }
    return base + '/v1/tools/{search|fetch}'
  }

  /** 构建搜索服务空状态。 */
  @Builder
  EmptySearchHint() {
    Column() {
      Text('还没有搜索服务配置')
        .fontSize(15)
        .fontColor(AppColors.textPrimary)
        .fontWeight(FontWeight.Medium)

      Text('添加后联网搜索与网页抓取才可用；\n当前仅支持 DeepSeek 官方接口')
        .fontSize(12)
        .fontColor(AppColors.textTertiary)
        .textAlign(TextAlign.Center)
        .margin({ top: 6 })
        .lineHeight(18)
    }
    .width('92%')
    .padding({ top: 20, bottom: 8 })
    .alignItems(HorizontalAlign.Center)
  }

  /** 构建添加搜索服务按钮。 */
  @Builder
  AddSearchButton() {
    Row() {
      Text('+ 添加搜索服务')
        .fontSize(15)
        .fontColor(AppColors.primary)
        .fontWeight(FontWeight.Medium)
    }
    .width('92%')
    .height(44)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(12)
    .margin({ top: 8 })
    .onClick((): void => {
      if (this.hasSearchUnsavedEdit()) {
        this.showDiscardConfirm((): void => {
          this.addSearchProfile()
        })
        return
      }
      this.addSearchProfile()
    })
  }

  // ============================================================
  // AI 场景 Prompt 模板
  // ============================================================

  /** 构建场景 Prompt 模板区域。 */
  @Builder
  ScenarioSection() {
    Column() {
      // Section header
      Text('Prompt 模板')
        .fontSize(14)
        .fontColor(AppColors.textPrimary)
        .fontWeight(FontWeight.Medium)
        .width('92%')
        .margin({ top: 20, bottom: 2 })

      Text('自定义各 AI 功能的角色行为和输出风格，注入数据由系统自动拼接')
        .fontSize(11)
        .fontColor(AppColors.textTertiary)
        .lineHeight(16)
        .width('92%')
        .margin({ bottom: 8, top: 2 })

      this.ScenarioCard(AiScenario.POST_SUMMARY)
      this.ScenarioCard(AiScenario.USER_ANALYSIS)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 构建单个场景卡片。
   *
   * @param scenario - 场景标识
   */
  @Builder
  ScenarioCard(scenario: string) {
    Column() {
      this.ScenarioCardHeader(scenario)

      if (this.expandedScenario === scenario) {
        Divider().color(AppColors.separator).width('100%').margin({ bottom: 4 })
        this.ScenarioCardBody(scenario)
      }
    }
    .width('92%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(12)
    .margin({ top: 8 })
  }

  /**
   * 场景卡片头部。
   *
   * @param scenario - 场景标识
   */
  @Builder
  ScenarioCardHeader(scenario: string) {
    Row() {
      Image(this.scenarioIcon(scenario))
        .width(20)
        .height(20)
        .fillColor(AppColors.textSecondary)
        .margin({ right: 10 })

      Column() {
        Text(SCENARIO_META[scenario].name)
          .fontSize(15)
          .fontColor(AppColors.textPrimary)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(SCENARIO_META[scenario].desc)
          .fontSize(11)
          .fontColor(AppColors.textTertiary)
          .lineHeight(16)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // Status badge
      this.ScenarioBadge(scenario)

      // Expand chevron
      Text(this.expandedScenario === scenario ? '▾' : '▸')
        .fontSize(14)
        .fontColor(AppColors.chevron)
        .margin({ left: 8 })
        .flexShrink(0)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .onClick(() => {
      if (this.expandedScenario === scenario) {
        this.expandedScenario = ''
      } else {
        this.doExpandScenario(scenario)
      }
    })
  }

  /**
   * 展开场景卡片并初始化编辑缓冲。
   *
   * @param scenario - 场景标识
   */
  private doExpandScenario(scenario: string): void {
    this.expandedScenario = scenario
    this.editScenarioPromptInput = appStore.settingsStore.getScenarioPrompt(scenario)
    this.showDataPreview = false
  }

  /**
   * 场景状态徽章。
   *
   * @param scenario - 场景标识
   */
  @Builder
  ScenarioBadge(scenario: string) {
    Text(this.scenarioPromptVersion > -1 && this.isScenarioCustom(scenario) ? '自定义' : '默认')
      .fontSize(11)
      .fontColor(this.scenarioPromptVersion > -1 && this.isScenarioCustom(scenario) ? AppColors.primary : AppColors.textTertiary)
      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
      .border({
        width: 1,
        color: this.scenarioPromptVersion > -1 && this.isScenarioCustom(scenario) ? AppColors.primary : AppColors.textTertiary,
        style: BorderStyle.Solid
      })
      .borderRadius(10)
  }

  /**
   * 判断指定场景是否已自定义。
   *
   * 与 DEFAULT_SYSTEM_PROMPTS 比对，内容相同时不视为自定义，
   * 防止 TextArea onChange 回写默认文本导致场景被误判。
   *
   * @param scenario - 场景标识
   * @returns 是否已自定义
   */
  private isScenarioCustom(scenario: string): boolean {
    const custom: string = (appStore.settings.scenarioSystemPrompts[scenario] ?? '').trim()
    if (custom.length === 0) {
      return false
    }
    const defaultPrompt: string = DEFAULT_SYSTEM_PROMPTS[scenario] ?? ''
    return custom !== defaultPrompt.trim()
  }

  /**
   * 获取场景对应的图标资源。
   *
   * @param scenario - 场景标识
   * @returns 图标资源引用
   */
  private scenarioIcon(scenario: string): Resource {
    if (scenario === AiScenario.POST_SUMMARY) {
      return $r('app.media.icon_ai_summary')
    }
    return $r('app.media.icon_ai_profile')
  }

  /**
   * 场景卡片展开体。
   *
   * @param scenario - 场景标识
   */
  @Builder
  ScenarioCardBody(scenario: string) {
    Column() {
      // System prompt label
      Text('系统提示词')
        .fontSize(13)
        .fontColor(AppColors.textSecondary)
        .width('100%')
        .margin({ bottom: 4 })

      // TextArea
      TextArea({ text: this.editScenarioPromptInput, placeholder: '在此输入系统提示词…' })
        .onChange((value: string): void => {
          this.editScenarioPromptInput = value
          appStore.settingsStore.setScenarioPrompt(scenario, value)
          this.scenarioPromptVersion++
        })
        .width('100%')
        .height(150)
        .attributeModifier(UIMaterialManager.inputMaterial)
        .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
        .borderRadius(8)
        .fontSize(14)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })

      // Reset button + info
      Row() {
        if (this.scenarioPromptVersion > -1 && this.isScenarioCustom(scenario)) {
          Text('↺ 恢复默认')
            .fontSize(12)
            .fontColor(AppColors.textTertiary)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .onClick(() => {
              appStore.settingsStore.resetScenarioPrompt(scenario)
              this.editScenarioPromptInput = appStore.settingsStore.getScenarioPrompt(scenario)
              this.scenarioPromptVersion++
            })
        }

        Blank()

        Text(this.editScenarioPromptInput.length.toString() + ' 字')
          .fontSize(11)
          .fontColor(AppColors.textTertiary)
      }
      .width('100%')
      .margin({ top: 6, bottom: 10 })

      // Data preview toggle
      this.ScenarioDataPreview(scenario)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 8, bottom: 16 })
  }

  /**
   * 注入数据预览区域。
   *
   * @param scenario - 场景标识
   */
  @Builder
  ScenarioDataPreview(scenario: string) {
    Column() {
      Row() {
        Text('ℹ️ 以下数据会自动注入到每次请求中')
          .fontSize(11)
          .fontColor(AppColors.textTertiary)
          .lineHeight(16)
          .layoutWeight(1)

        Text(this.showDataPreview ? '收起 ▲' : '展开 ▼')
          .fontSize(11)
          .fontColor(AppColors.textTertiary)
          .margin({ left: 8 })
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .backgroundColor(AppColors.bgSecondary)
      .borderRadius(8)
      .onClick(() => {
        this.showDataPreview = !this.showDataPreview
      })

      if (this.showDataPreview) {
        Column() {
          ForEach(SCENARIO_INJECTED_FIELDS[scenario], (field: InjectedFieldInfo) => {
            Column() {
              Text(field.label)
                .fontSize(12)
                .fontColor(AppColors.textSecondary)
                .fontWeight(FontWeight.Medium)

              Text(field.example)
                .fontSize(12)
                .fontColor(AppColors.textTertiary)
                .fontStyle(FontStyle.Italic)
                .lineHeight(16)
                .margin({ top: 2 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 10, top: 4, bottom: 4 })
          }, (field: InjectedFieldInfo): string => field.label)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 6, bottom: 8 })
        .backgroundColor(AppColors.bgSecondary)
        .borderRadius({ bottomLeft: 8, bottomRight: 8 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 4 })
  }

  /**
   * 构建已有配置卡片。
   *
   * @param profile - AI 配置
   */
  @Builder
  ProfileCard(profile: AiProviderProfile) {
    Column() {
      this.ProfileCardHeader(profile)

      if (this.expandedProfileId === profile.id) {
        Divider().color(AppColors.separator).width('100%').margin({ bottom: 4 })
        this.ProfileCardBody()
      }
    }
    .width('92%')
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(12)
    .margin({ top: 8 })
  }

  /**
   * 构建配置卡片头部。
   *
   * @param profile - AI 配置
   */
  @Builder
  ProfileCardHeader(profile: AiProviderProfile) {
    Row() {
      Row() {
        Radio({ value: profile.id, group: 'aiProvider' })
          .checked(this.isActiveProfile(profile.id))
          .onChange((checked: boolean) => {
            if (checked) {
              appStore.settingsStore.setActiveAiProfile(profile.id)
              this.syncProfiles()
            }
          })
          .width(20)
          .height(20)
      }
      .width(36)
      .height(48)
      .justifyContent(FlexAlign.Center)

      Column() {
        Text(profile.name)
          .fontSize(15)
          .fontColor(AppColors.textPrimary)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.profileSubtitle(profile))
          .fontSize(11)
          .fontColor(AppColors.textTertiary)
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => {
        if (this.expandedProfileId === profile.id) {
          this.collapseCard()
        } else {
          this.expandCard(profile.id)
        }
      })

      Text('删除')
        .fontSize(12)
        .fontColor(AppColors.destructive)
        .padding({ left: 6, right: 6, top: 4, bottom: 4 })
        .onClick(() => {
          this.deleteProfile(profile.id)
        })
    }
    .width('100%')
    .padding({ left: 12, right: 8, top: 12, bottom: 12 })
  }

  /**
   * 配置卡片副标题：服务商类型 + 协议 + 模型。
   *
   * @param profile - AI 配置
   * @returns 副标题文案
   */
  private profileSubtitle(profile: AiProviderProfile): string {
    const normalized: AiProviderProfile = normalizeAiProfile(profile)
    const provider: string = isDeepSeekProfile(normalized) ? 'DeepSeek' : '自定义'
    const model: string = normalized.modelName.trim().length > 0 ? normalized.modelName : '未选择模型'
    return provider + ' · ' + protocolLabel(normalized.protocol) + ' · ' + model
  }

  /**
   * 公共表单字段 — 方案名称、服务商、协议、服务地址、密钥、模型（可拉取）、
   * 高级参数（温度 / 工具 / Agent 轮数）与测试保存按钮。
   *
   * 由 ProfileCardBody 和 NewProfileCard 共享。
   */
  @Builder
  ProfileFormFields() {
    // ---- 方案名称 ----
    Column() {
      Text('方案名称')
        .fontSize(13)
        .fontColor(AppColors.textSecondary)
        .width('100%')
        .margin({ bottom: 4 })

      TextInput({ placeholder: '为这个方案起个名字', text: this.editNameInput })
        .onChange((v: string) => {
          this.editNameInput = v
        })
        .width('100%')
        .height(40)
        .attributeModifier(UIMaterialManager.inputMaterial)
        .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
        .borderRadius(8)
        .fontSize(14)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .padding({ left: 12, right: 12 })
    }
    .width('100%')
    .margin({ bottom: 10 })

    // ---- 服务商 ----
    Column() {
      Text('服务商')
        .fontSize(13)
        .fontColor(AppColors.textSecondary)
        .width('100%')
        .margin({ bottom: 6 })

      Row() {
        ForEach(PROVIDER_PRESETS, (preset: AiProviderPreset) => {
          Text(preset.name)
            .fontSize(13)
            .fontColor(this.editPresetId === preset.kind ? AppColors.white : AppColors.textPrimary)
            .fontWeight(this.editPresetId === preset.kind ? FontWeight.Medium : FontWeight.Normal)
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .backgroundColor(this.editPresetId === preset.kind ? AppColors.primary : AppColors.bgSecondary)
            .borderRadius(16)
            .margin({ right: 8 })
            .onClick(() => {
              this.selectPresetKind(preset.kind)
            })
        }, (preset: AiProviderPreset): string => preset.id)

        Blank()
      }
      .width('100%')

      Text(this.getPreset().description)
        .fontSize(11)
        .fontColor(AppColors.textTertiary)
        .width('100%')
        .margin({ top: 6 })
        .lineHeight(16)
    }
    .width('100%')
    .margin({ bottom: 10 })

    // ---- 协议（自定义服务商才需要选） ----
    if (this.editPresetId === AiProviderKind.CUSTOM) {
      Column() {
        Text('对话协议')
          .fontSize(13)
          .fontColor(AppColors.textSecondary)
          .width('100%')
          .margin({ bottom: 6 })

        Row() {
          Text('Chat Completions')
            .fontSize(13)
            .fontColor(this.editProtocol === AiApiProtocol.CHAT_COMPLETIONS ? AppColors.white : AppColors.textPrimary)
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .backgroundColor(this.editProtocol === AiApiProtocol.CHAT_COMPLETIONS ? AppColors.primary : AppColors.bgSecondary)
            .borderRadius(16)
            .margin({ right: 8 })
            .onClick(() => {
              this.selectProtocol(AiApiProtocol.CHAT_COMPLETIONS)
            })

          Text('Responses')
            .fontSize(13)
            .fontColor(this.editProtocol === AiApiProtocol.RESPONSES ? AppColors.white : AppColors.textPrimary)
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .backgroundColor(this.editProtocol === AiApiProtocol.RESPONSES ? AppColors.primary : AppColors.bgSecondary)
            .borderRadius(16)
            .onClick(() => {
              this.selectProtocol(AiApiProtocol.RESPONSES)
            })

          Blank()
        }
        .width('100%')

        Text(protocolDescription(this.editProtocol))
          .fontSize(11)
          .fontColor(AppColors.textTertiary)
          .width('100%')
          .margin({ top: 6 })
          .lineHeight(16)
      }
      .width('100%')
      .margin({ bottom: 10 })
    }

    // ---- 服务地址 ----
    Column() {
      Text('服务地址')
        .fontSize(13)
        .fontColor(AppColors.textSecondary)
        .width('100%')
        .margin({ bottom: 4 })

      if (this.editPresetId === AiProviderKind.DEEPSEEK) {
        Row() {
          Text('🔒 ' + this.editEndpointInput)
            .fontSize(13)
            .fontColor(AppColors.textTertiary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .height(40)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(AppColors.bgSecondary)
        .borderRadius(8)
        .padding({ left: 12, right: 12 })
      } else {
        TextInput({ placeholder: 'https://api.example.com/v1', text: this.editEndpointInput })
          .onChange((v: string) => {
            this.editEndpointInput = v
          })
          .width('100%')
          .height(40)
          .attributeModifier(UIMaterialManager.inputMaterial)
          .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
          .borderRadius(8)
          .fontSize(14)
          .fontColor(UIMaterialManager.inputForeground)
          .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
          .caretColor(UIMaterialManager.inputForeground)
          .padding({ left: 12, right: 12 })
      }

      if (this.editEndpointInput.trim().length > 0) {
        Text('实际请求：' + endpointPreview(this.editEndpointInput, this.editProtocol))
          .fontSize(11)
          .fontColor(AppColors.textTertiary)
          .width('100%')
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .margin({ bottom: 10 })

    // ---- API 密钥 ----
    Column() {
      Text('API 密钥')
        .fontSize(13)
        .fontColor(AppColors.textSecondary)
        .width('100%')
        .margin({ bottom: 4 })

      TextInput({ placeholder: this.getApiKeyPlaceholder(), text: this.editApiKeyInput })
        .type(InputType.Password)
        .onChange((v: string) => {
          this.editApiKeyInput = v
        })
        .width('100%')
        .height(40)
        .attributeModifier(UIMaterialManager.inputMaterial)
        .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
        .borderRadius(8)
        .fontSize(14)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .padding({ left: 12, right: 12 })
    }
    .width('100%')
    .margin({ bottom: 10 })

    // ---- 模型名称 + 拉取 ----
    Column() {
      Row() {
        Text('模型名称')
          .fontSize(13)
          .fontColor(AppColors.textSecondary)
          .layoutWeight(1)

        Text(this.loadingModels ? '拉取中...' : '↻ 拉取模型')
          .fontSize(12)
          .fontColor(this.loadingModels ? AppColors.textTertiary : AppColors.primary)
          .padding({ left: 8, right: 2, top: 2, bottom: 2 })
          .onClick(() => {
            this.doFetchModels()
          })
      }
      .width('100%')
      .margin({ bottom: 4 })

      TextInput({ placeholder: this.getModelPlaceholder(), text: this.editModelInput })
        .onChange((v: string) => {
          this.editModelInput = v
        })
        .width('100%')
        .height(40)
        .attributeModifier(UIMaterialManager.inputMaterial)
        .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
        .borderRadius(8)
        .fontSize(14)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .padding({ left: 12, right: 12 })

      if (this.modelLoadMessage.length > 0) {
        Text(this.modelLoadMessage)
          .fontSize(11)
          .fontColor(this.modelOptions.length > 0 ? AppColors.textTertiary : AppColors.destructive)
          .width('100%')
          .margin({ top: 4 })
          .lineHeight(16)
      }

      if (this.showModelList && this.modelOptions.length > 0) {
        Column() {
          ForEach(this.modelOptions.slice(0, MAX_VISIBLE_MODELS), (model: AiModelInfo) => {
            Column() {
              Row() {
                Text(model.displayName)
                  .fontSize(13)
                  .fontColor(this.editModelInput === model.id ? AppColors.primary : AppColors.textPrimary)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })

                if (this.editModelInput === model.id) {
                  Text('✓')
                    .fontSize(13)
                    .fontColor(AppColors.primary)
                }
              }
              .width('100%')

              if (this.modelSubtitle(model).length > 0) {
                Text(this.modelSubtitle(model))
                  .fontSize(11)
                  .fontColor(AppColors.textTertiary)
                  .width('100%')
                  .margin({ top: 1 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .onClick(() => {
              this.selectModel(model.id)
            })
          }, (model: AiModelInfo): string => model.id)

          if (this.modelOptions.length > MAX_VISIBLE_MODELS) {
            Text('仅展示前 ' + MAX_VISIBLE_MODELS.toString() + ' 个，可手动输入其他模型名')
              .fontSize(11)
              .fontColor(AppColors.textTertiary)
              .width('100%')
              .padding({ left: 12, top: 6, bottom: 6 })
          }
        }
        .width('100%')
        .margin({ top: 6 })
        .backgroundColor(AppColors.bgSecondary)
        .borderRadius(8)
      }
    }
    .width('100%')
    .margin({ bottom: 10 })

    this.AdvancedParameterFields()

    Row() {
      Text(this.testing ? '测试中...' : '测试连接')
        .fontSize(13)
        .fontColor(this.testing ? AppColors.textTertiary : AppColors.primary)
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .border({
          width: 1,
          color: this.testing ? AppColors.textTertiary : AppColors.primary,
          style: BorderStyle.Solid
        })
        .borderRadius(8)
        .onClick(() => {
          this.doTestConnection()
        })
    }
    .width('100%')
    .margin({ bottom: 6 })

    if (this.testResultMessage.length > 0) {
      Text(this.testResultMessage)
        .fontSize(12)
        .fontColor(this.testSuccess ? AppColors.success : AppColors.destructive)
        .margin({ bottom: 10 })
        .width('100%')
        .lineHeight(18)
    }

    Row() {
      Text('取消')
        .fontSize(14)
        .fontColor(AppColors.textSecondary)
        .layoutWeight(1)
        .height(38)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.collapseCard()
        })

      Text('保存')
        .fontSize(14)
        .fontColor(AppColors.white)
        .layoutWeight(1)
        .height(38)
        .textAlign(TextAlign.Center)
        .backgroundColor(AppColors.primary)
        .borderRadius(10)
        .onClick(() => {
          this.saveProfile()
        })
    }
    .width('100%')
    .margin({ top: 4 })
  }

  /**
   * 构建默认折叠的高级 AI 参数编辑区。
   */
  @Builder
  AdvancedParameterFields() {
    Column() {
      Row() {
        Column() {
          Text('高级参数')
            .fontSize(13)
            .fontColor(AppColors.textSecondary)
            .width('100%')
          Text('温度、联网工具与 Agent 工具轮数')
            .fontSize(11)
            .fontColor(AppColors.textTertiary)
            .width('100%')
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.showAdvancedParams ? '收起 ▲' : '展开 ▼')
          .fontSize(12)
          .fontColor(AppColors.primary)
      }
      .width('100%')
      .height(46)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.showAdvancedParams = !this.showAdvancedParams
      })

      if (this.showAdvancedParams) {
        Divider().color(AppColors.separator).margin({ left: 12, right: 12 })

        // ---- 温度 ----
        Column() {
          Row() {
            Text('温度')
              .fontSize(13)
              .fontColor(AppColors.textPrimary)
              .width(52)
            Slider({
              value: this.editTemperatureInput,
              min: MIN_AI_TEMPERATURE,
              max: MAX_AI_TEMPERATURE,
              step: 0.1,
              style: SliderStyle.InSet
            })
              .systemMaterial(UIMaterialManager.controlMaterial)
              .onChange((value: number, mode: SliderChangeMode): void => {
                this.editTemperatureInput = clampAiTemperature(value)
              })
              .layoutWeight(1)
              .height(40)
            Text(this.editTemperatureInput.toFixed(1))
              .fontSize(13)
              .fontColor(AppColors.textSecondary)
              .width(42)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .height(46)
          .alignItems(VerticalAlign.Center)

          Text('越低越稳定，越高越发散；思考模式下部分模型忽略此参数')
            .fontSize(11)
            .fontColor(AppColors.textTertiary)
            .width('100%')
            .margin({ left: 52 })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 4 })
        .alignItems(HorizontalAlign.Start)

        Divider().color(AppColors.separator).margin({ left: 12, right: 12, top: 4, bottom: 4 })

        // ---- 工具总开关 ----
        Row() {
          Column() {
            Text('联网工具')
              .fontSize(13)
              .fontColor(AppColors.textPrimary)
              .width('100%')
            Text('web_search 搜索 + web_fetch 抓取网页')
              .fontSize(11)
              .fontColor(AppColors.textTertiary)
              .width('100%')
              .margin({ top: 2 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Toggle({ type: ToggleType.Switch, isOn: this.editToolsEnabled })
            .systemMaterial(UIMaterialManager.controlMaterial)
            .onChange((isOn: boolean): void => {
              this.editToolsEnabled = isOn
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 2 })
        .alignItems(VerticalAlign.Center)

        if (this.editToolsEnabled) {
          Row() {
            Text('联网搜索')
              .fontSize(13)
              .fontColor(AppColors.textPrimary)
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.editWebSearchEnabled })
              .systemMaterial(UIMaterialManager.controlMaterial)
              .onChange((isOn: boolean): void => {
                this.editWebSearchEnabled = isOn
              })
          }
          .width('100%')
          .height(40)
          .padding({ left: 24, right: 12 })
          .alignItems(VerticalAlign.Center)

          Row() {
            Text('网页抓取')
              .fontSize(13)
              .fontColor(AppColors.textPrimary)
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.editWebFetchEnabled })
              .systemMaterial(UIMaterialManager.controlMaterial)
              .onChange((isOn: boolean): void => {
                this.editWebFetchEnabled = isOn
              })
          }
          .width('100%')
          .height(40)
          .padding({ left: 24, right: 12 })
          .alignItems(VerticalAlign.Center)

          // ---- Agent 工具轮数 ----
          Row() {
            Text('Agent 轮数')
              .fontSize(13)
              .fontColor(AppColors.textPrimary)
              .width(80)
            TextInput({
              text: this.editAgentStepsInput,
              placeholder: DEFAULT_AI_MAX_AGENT_STEPS.toString()
            })
              .type(InputType.Number)
              .onChange((value: string): void => {
                this.editAgentStepsInput = value
              })
              .layoutWeight(1)
              .height(36)
              .attributeModifier(UIMaterialManager.inputMaterial)
              .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
              .borderRadius(8)
              .fontSize(13)
              .fontColor(UIMaterialManager.inputForeground)
              .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
              .caretColor(UIMaterialManager.inputForeground)
              .padding({ left: 10, right: 10 })
            Text('轮')
              .fontSize(13)
              .fontColor(AppColors.textSecondary)
              .width(24)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .height(46)
          .padding({ left: 12, right: 12 })
          .alignItems(VerticalAlign.Center)

          Text('1–' + MAX_AI_MAX_AGENT_STEPS.toString() +
            ' 轮。上限越高越适合长链路任务，注意调用费用与耗时；超出后强制收尾')
            .fontSize(11)
            .fontColor(AppColors.textTertiary)
            .width('100%')
            .padding({ left: 12, right: 12 })
            .margin({ bottom: 4 })
        }
      }
    }
    .width('100%')
    .backgroundColor(AppColors.bgSecondary)
    .borderRadius(8)
    .margin({ bottom: 10 })
  }

  /** 构建已存在配置的展开编辑区。 */
  @Builder
  ProfileCardBody() {
    Column() {
      this.ProfileFormFields()
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 16 })
  }

  /** 新建方案卡片 */
  @Builder
  NewProfileCard() {
    Column() {
      Row() {
        Column() {
          Text(this.editNameInput.length > 0 ? this.editNameInput : '新建方案')
            .fontSize(15)
            .fontColor(AppColors.textPrimary)
            .fontWeight(FontWeight.Medium)
            .maxLines(1)

          if (this.editEndpointInput.length > 0) {
            Text(protocolLabel(this.editProtocol) + ' · ' +
              (this.editModelInput.length > 0 ? this.editModelInput : '未选择模型'))
              .fontSize(11)
              .fontColor(AppColors.textTertiary)
              .margin({ top: 2 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .onClick(() => {
          this.collapseCard()
        })

        Text('放弃')
          .fontSize(12)
          .fontColor(AppColors.textTertiary)
          .padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .onClick(() => {
            this.collapseCard()
          })
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 12, bottom: 4 })

      Divider().color(AppColors.separator).width('100%').margin({ bottom: 4 })

      Column() {
        this.ProfileFormFields()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 16 })
    }
    .width('92%')
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(12)
    .margin({ top: 8 })
  }

  /** 构建添加 AI 服务按钮。 */
  @Builder
  AddButton() {
    Row() {
      Text('+ 添加 AI 服务')
        .fontSize(15)
        .fontColor(AppColors.primary)
        .fontWeight(FontWeight.Medium)
    }
    .width('92%')
    .height(44)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(12)
    .margin({ top: 8 })
    .onClick(() => {
      if (this.hasUnsavedEdit()) {
        this.showDiscardConfirm((): void => {
          this.showProviderPresetPicker()
        })
        return
      }
      this.showProviderPresetPicker()
    })
  }

  /** 构建空状态提示。 */
  @Builder
  EmptyHint() {
    Column() {
      Text('🤖')
        .fontSize(36)

      Text('还没有自定义 AI 配置')
        .fontSize(15)
        .fontColor(AppColors.textPrimary)
        .fontWeight(FontWeight.Medium)
        .margin({ top: 10 })

      Text('添加 DeepSeek 官方服务后，\n帖子总结、用户分析即可使用；\n联网能力需在下方「搜索服务」中另行配置')
        .fontSize(12)
        .fontColor(AppColors.textTertiary)
        .textAlign(TextAlign.Center)
        .margin({ top: 6 })
        .lineHeight(18)
    }
    .width('92%')
    .padding({ top: 28, bottom: 8 })
    .alignItems(HorizontalAlign.Center)
  }

}
