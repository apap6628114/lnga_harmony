/**
 * AI 配置管理面板。
 *
 * 管理 DeepSeek Responses API 配置：创建、编辑、删除、测试连接。
 * 采用内联可展开卡片模式，新建/编辑在同一页面内完成，
 * 无需切换模式。端点固定为 https://api.deepseek.com，
 * 联网搜索由服务端内置 web_search 工具完成，无需额外配置。
 */

import { appStore } from '../../store/AppStore'
import { routerStore } from '../../store/RouterStore'
import { AppColors } from '../../common/constants/Constants'
import { UIMaterialManager } from '../../common/managers/UIMaterialManager'
import { PanelNavBar } from '../../common/components/PanelNavBar'
import { ConfirmDialog, ActionSheetDialog } from '../../common/dialogs/Dialogs'
import {
  AiProviderProfile,
  DEFAULT_AI_MAX_TOKENS,
  DEFAULT_AI_TEMPERATURE,
  DEFAULT_DEEPSEEK_ENDPOINT,
  MAX_AI_MAX_TOKENS,
  MAX_AI_TEMPERATURE,
  MIN_AI_MAX_TOKENS,
  MIN_AI_TEMPERATURE
} from '../../model/AiConfig'
import { PROVIDER_PRESETS } from '../../service/ai/AiModelPresets'
import { testConnection } from '../../service/ai/ResponsesApiClient'
import type { ActionOption } from '../../common/dialogs/Dialogs'
import type { AiTestResult } from '../../model/AiConfig'
import type { AiProviderPreset } from '../../service/ai/AiModelPresets'
import {
  AiScenario,
  SCENARIO_META,
  DEFAULT_SYSTEM_PROMPTS,
  SCENARIO_INJECTED_FIELDS,
  type InjectedFieldInfo
} from '../../model/AiScenarioConfig'
import { TitleScrollEffect } from '../../common/utils/TitleScrollEffect'

/** 新建方案的哨兵 ID */
const NEW_ID: string = '__new__'

@Component
export struct AiSettingsPanel {
  /** 配置列表快照。 */
  @State profiles: AiProviderProfile[] = []
  /** 状态栏高度。 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 当前展开编辑的配置 ID。 */
  @State expandedProfileId: string = ''
  /** 方案名称输入值。 */
  @State editNameInput: string = ''
  /** 服务地址输入值。 */
  @State editEndpointInput: string = ''
  /** API 密钥输入值。 */
  @State editApiKeyInput: string = ''
  /** 模型名称输入值。 */
  @State editModelInput: string = ''
  /** 温度参数输入值。 */
  @State editTemperatureInput: number = DEFAULT_AI_TEMPERATURE
  /** 输出上限输入值。 */
  @State editMaxTokensInput: number = DEFAULT_AI_MAX_TOKENS
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
  /** 服务商预设选择弹窗控制器。 */
  providerPickerController?: CustomDialogController
  /** 放弃修改确认弹窗控制器。 */
  discardConfirmController?: CustomDialogController

  /** 页面出现时同步配置列表并注册返回拦截。 */
  aboutToAppear(): void {
    this.syncProfiles()
    const entry = routerStore.topActivity
    if (entry) {
      entry.preBack = (): boolean => {
        if (this.hasUnsavedEdit()) {
          this.showDiscardConfirm((): void => {
            this.doCollapse()
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
    this.providerPickerController = undefined
    this.discardConfirmController = undefined
  }

  /** 同步当前持久化配置列表到页面状态。 */
  private syncProfiles(): void {
    this.profiles = appStore.settings.aiProfiles
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

    if (profileId === NEW_ID) {
      this.editNameInput = ''
      this.editEndpointInput = DEFAULT_DEEPSEEK_ENDPOINT
      this.editApiKeyInput = ''
      this.editModelInput = ''
      this.editTemperatureInput = DEFAULT_AI_TEMPERATURE
      this.editMaxTokensInput = DEFAULT_AI_MAX_TOKENS
      this.showAdvancedParams = false
    } else {
      const profile: AiProviderProfile | null = this.findProfile(profileId)
      if (profile) {
        this.editNameInput = profile.name
        this.editEndpointInput = DEFAULT_DEEPSEEK_ENDPOINT
        this.editApiKeyInput = profile.apiKey
        this.editModelInput = profile.modelName
        this.editTemperatureInput = this.clampTemperature(profile.temperature)
        this.editMaxTokensInput = this.clampMaxTokens(profile.maxTokens)
        this.showAdvancedParams = false
      }
    }
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

  /** 使正在返回途中的异步结果失效 */
  private invalidatePendingRequests(): void {
    this.testConnectionRequestId++
    this.testing = false
  }

  /**
   * 显示放弃修改确认弹窗。
   *
   * @param onConfirm - 用户确认放弃后的动作
   */
  private showDiscardConfirm(onConfirm: () => void): void {
    this.discardConfirmController = new CustomDialogController({
      builder: ConfirmDialog({
        title: '放弃修改',
        message: '当前编辑的内容尚未保存，确定要放弃吗？',
        confirmLabel: '放弃',
        destructive: false,
        onConfirm: onConfirm,
        onCancel: (): void => {}
      }),
      autoCancel: true,
      customStyle: true
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
      return this.editNameInput.length > 0 ||
        this.editApiKeyInput.length > 0 ||
        this.editModelInput.length > 0 ||
        this.editTemperatureInput !== DEFAULT_AI_TEMPERATURE ||
        this.editMaxTokensInput !== DEFAULT_AI_MAX_TOKENS
    }
    const profile: AiProviderProfile | null = this.findProfile(this.expandedProfileId)
    if (!profile) {
      return false
    }
    return this.editNameInput !== profile.name ||
      this.editApiKeyInput !== profile.apiKey ||
      this.editModelInput !== profile.modelName ||
      this.editTemperatureInput !== this.clampTemperature(profile.temperature) ||
      this.editMaxTokensInput !== this.clampMaxTokens(profile.maxTokens)
  }

  /** 清空编辑表单缓存和异步结果。 */
  private clearEditBuffers(): void {
    this.editNameInput = ''
    this.editEndpointInput = DEFAULT_DEEPSEEK_ENDPOINT
    this.editApiKeyInput = ''
    this.editModelInput = ''
    this.editTemperatureInput = DEFAULT_AI_TEMPERATURE
    this.editMaxTokensInput = DEFAULT_AI_MAX_TOKENS
    this.showAdvancedParams = false
    this.testResultMessage = ''
    this.testSuccess = false
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

  /**
   * 将温度参数限制到可编辑范围并规范到一位小数。
   *
   * @param value - 待规范化的温度参数
   * @returns 规范化后的温度参数
   */
  private clampTemperature(value: number): number {
    const clamped: number = Math.max(MIN_AI_TEMPERATURE, Math.min(MAX_AI_TEMPERATURE, value))
    return Math.round(clamped * 10) / 10
  }

  /**
   * 将输出上限限制到可编辑范围并规范到整数。
   *
   * @param value - 待规范化的输出上限
   * @returns 规范化后的输出上限
   */
  private clampMaxTokens(value: number): number {
    const clamped: number = Math.max(MIN_AI_MAX_TOKENS, Math.min(MAX_AI_MAX_TOKENS, value))
    return Math.round(clamped)
  }

  /** 保存当前表单中的新建或编辑配置。 */
  saveProfile(): void {
    if (!this.editNameInput || this.editNameInput.trim().length === 0) {
      appStore.showToast('请输入方案名称')
      return
    }
    if (!this.editModelInput || this.editModelInput.trim().length === 0) {
      appStore.showToast('请输入模型名称')
      return
    }

    const profile: AiProviderProfile = new AiProviderProfile()
    profile.name = this.editNameInput.trim()
    profile.endpoint = DEFAULT_DEEPSEEK_ENDPOINT
    profile.modelName = this.editModelInput.trim()
    profile.temperature = this.clampTemperature(this.editTemperatureInput)
    profile.maxTokens = this.clampMaxTokens(this.editMaxTokensInput)

    if (this.expandedProfileId === NEW_ID) {
      profile.apiKey = this.editApiKeyInput.trim()
      appStore.settingsStore.addAiProfile(profile)
      appStore.settingsStore.setActiveAiProfile(profile.id)
      appStore.showToast('已添加并切换到 ' + profile.name)
    } else {
      const old: AiProviderProfile | null = this.findProfile(this.expandedProfileId)
      if (old) {
        profile.id = old.id
        profile.apiKey = this.editApiKeyInput.trim()
      } else {
        profile.id = this.expandedProfileId
        profile.apiKey = this.editApiKeyInput.trim()
      }
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
      builder: ConfirmDialog({
        title: '删除 AI 配置',
        message: this.isActiveProfile(id)
          ? '你将删除当前正在使用的配置「' + name + '」。\n删除后会自动切换到剩余配置；若没有其他配置，AI 功能需要重新添加配置后使用。'
          : '确定要删除配置「' + name + '」吗？\n删除后该配置将从列表中移除。',
        confirmLabel: '删除',
        destructive: true,
        icon: $r('app.media.icon_delete'),
        onConfirm: (): void => {
          appStore.settingsStore.deleteAiProfile(id)
          this.syncProfiles()
          if (this.expandedProfileId === id) {
            this.doCollapse()
          }
        },
        onCancel: (): void => {}
      }),
      autoCancel: true,
      customStyle: true
    })
    this.deleteConfirmController.open()
  }

  /** 显示服务商预设选择弹窗。 */
  showProviderPresetPicker(): void {
    const options: ActionOption[] = []
    for (let i = 0; i < PROVIDER_PRESETS.length; i++) {
      const opt: ActionOption = {
        label: PROVIDER_PRESETS[i].name + ' - ' + PROVIDER_PRESETS[i].description,
        value: i
      }
      options.push(opt)
    }

    this.providerPickerController = new CustomDialogController({
      builder: ActionSheetDialog({
        title: '选择 AI 平台',
        options: options,
        selected: -1,
        onSelect: (v: number): void => {
          this.invalidatePendingRequests()
          const preset: AiProviderPreset = PROVIDER_PRESETS[v]
          this.editNameInput = preset.name
          this.editEndpointInput = DEFAULT_DEEPSEEK_ENDPOINT
          this.editApiKeyInput = ''
          this.editModelInput = preset.defaultModelName
          this.testResultMessage = ''
          this.testSuccess = false
          this.expandedProfileId = NEW_ID
        }
      }),
      autoCancel: true,
      customStyle: true
    })
    this.providerPickerController.open()
  }

  /**
   * 获取模型输入框占位提示。
   *
   * @returns 当前平台默认模型或通用提示
   */
  private getModelPlaceholder(): string {
    const preset: AiProviderPreset | null = this.getPreset()
    if (preset && preset.defaultModelName.length > 0) {
      return preset.defaultModelName
    }
    return '请输入模型名称'
  }

  /**
   * 获取 API Key 输入框占位提示。
   *
   * @returns DeepSeek 的 API Key 格式提示
   */
  private getApiKeyPlaceholder(): string {
    const preset: AiProviderPreset | null = this.getPreset()
    if (preset && preset.apiKeyPlaceholder.length > 0) {
      return preset.apiKeyPlaceholder
    }
    return '请输入 API Key'
  }

  /**
   * 获取当前唯一预设（DeepSeek）。
   *
   * @returns DeepSeek 预设，列表为空时返回 null
   */
  private getPreset(): AiProviderPreset | null {
    if (PROVIDER_PRESETS.length > 0) {
      return PROVIDER_PRESETS[0]
    }
    return null
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

  /** 测试当前表单中的 AI 连接配置。 */
  async doTestConnection(): Promise<void> {
    if (this.testing) {
      return
    }
    if (!this.editEndpointInput || this.editEndpointInput.trim().length === 0 ||
        !this.editModelInput || this.editModelInput.trim().length === 0) {
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

    this.testConnectionRequestId = requestId
    this.testing = true
    this.testResultMessage = ''

    const tempProfile: AiProviderProfile = new AiProviderProfile()
    tempProfile.endpoint = endpoint
    tempProfile.apiKey = apiKey
    tempProfile.modelName = modelName

    try {
      const result: AiTestResult = await testConnection(tempProfile)
      if (!this.isCurrentTestConnectionRequest(requestId, profileId, endpoint, apiKey, modelName)) {
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
      if (this.isCurrentTestConnectionRequest(requestId, profileId, endpoint, apiKey, modelName)) {
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
   * @returns 是否仍为当前请求
   */
  private isCurrentTestConnectionRequest(
    requestId: number,
    profileId: string,
    endpoint: string,
    apiKey: string,
    modelName: string
  ): boolean {
    return this.testConnectionRequestId === requestId &&
      this.expandedProfileId === profileId &&
      this.editEndpointInput.trim() === endpoint &&
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

            Text('配置 DeepSeek Responses API 连接信息和模型参数，联网搜索由服务端内置完成')
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
          if (this.hasUnsavedEdit()) {
            this.showDiscardConfirm((): void => {
              this.doCollapse()
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
        .backgroundColor(Color.Transparent)
        .systemMaterial(UIMaterialManager.inputMaterial)
        .borderRadius(8)
        .fontSize(14)
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

        Text('DeepSeek Responses API')
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
   * 公共表单字段 — 按操作顺序排列：方案名称、服务地址（只读）、API 密钥、
   * 模型名称（手动输入）、联通测试及保存/取消按钮。
   *
   * 由 ProfileCardBody 和 NewProfileCard 共享，
   * 避免两处各维护一份相同的表单代码。
   */
  @Builder
  ProfileFormFields() {
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
        .backgroundColor(Color.Transparent)
        .systemMaterial(UIMaterialManager.inputMaterial)
        .borderRadius(8)
        .fontSize(14)
        .padding({ left: 12, right: 12 })
    }
    .width('100%')
    .margin({ bottom: 10 })

    Column() {
      Text('服务地址')
        .fontSize(13)
        .fontColor(AppColors.textSecondary)
        .width('100%')
        .margin({ bottom: 4 })

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
    }
    .width('100%')
    .margin({ bottom: 10 })

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
        .backgroundColor(Color.Transparent)
        .systemMaterial(UIMaterialManager.inputMaterial)
        .borderRadius(8)
        .fontSize(14)
        .padding({ left: 12, right: 12 })
    }
    .width('100%')
    .margin({ bottom: 10 })

    Column() {
      Text('模型名称')
        .fontSize(13)
        .fontColor(AppColors.textSecondary)
        .width('100%')
        .margin({ bottom: 4 })

      TextInput({ placeholder: this.getModelPlaceholder(), text: this.editModelInput })
        .onChange((v: string) => {
          this.editModelInput = v
        })
        .width('100%')
        .height(40)
        .backgroundColor(Color.Transparent)
        .systemMaterial(UIMaterialManager.inputMaterial)
        .borderRadius(8)
        .fontSize(14)
        .padding({ left: 12, right: 12 })
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
          Text('调整回答随机性和输出长度')
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
              .onChange((value: number, mode: SliderChangeMode): void => {
                this.editTemperatureInput = this.clampTemperature(value)
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

          Text('越低越稳定，越高越发散')
            .fontSize(11)
            .fontColor(AppColors.textTertiary)
            .width('100%')
            .margin({ left: 52, bottom: 8 })

          Row() {
            Text('输出')
              .fontSize(13)
              .fontColor(AppColors.textPrimary)
              .width(52)
            Slider({
              value: this.editMaxTokensInput,
              min: MIN_AI_MAX_TOKENS,
              max: MAX_AI_MAX_TOKENS,
              step: 100,
              style: SliderStyle.InSet
            })
              .onChange((value: number, mode: SliderChangeMode): void => {
                this.editMaxTokensInput = this.clampMaxTokens(value)
              })
              .layoutWeight(1)
              .height(40)
            Text(this.editMaxTokensInput.toString())
              .fontSize(13)
              .fontColor(AppColors.textSecondary)
              .width(50)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .height(46)
          .alignItems(VerticalAlign.Center)

          Text('限制单次回复的最大 token 数')
            .fontSize(11)
            .fontColor(AppColors.textTertiary)
            .width('100%')
            .margin({ left: 52 })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 12 })
        .alignItems(HorizontalAlign.Start)
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
            Text(this.editEndpointInput)
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

      Text('添加 DeepSeek AI 服务后，\n帖子总结、用户分析即可使用，联网搜索由服务端内置完成')
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
