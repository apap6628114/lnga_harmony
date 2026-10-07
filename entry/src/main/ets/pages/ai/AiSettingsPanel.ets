/**
 * AI 配置管理面板。
 *
 * 管理 AI 服务商配置：选择平台预设、创建、编辑、删除、测试连接。
 * 采用内联可展开卡片模式，新建/编辑在同一页面内完成，无需切换模式。
 * 服务地址默认取预设端点且允许修改；服务商不支持的能力（如内置联网搜索）
 * 在表单内直接提示，避免用户在对话中被静默降级。
 */

import { appStore } from '../../store/AppStore'
import { routerStore } from '../../store/RouterStore'
import { AppColors } from '../../common/constants/Constants'
import { UIMaterialManager } from '../../common/managers/UIMaterialManager'
import { PanelNavBar } from '../../common/components/PanelNavBar'
import { TipsDialog, AlertDialog, SelectDialog } from '@kit.ArkUI'
import {
  AiProviderProfile,
  DEFAULT_AI_PROVIDER_ID,
  DEFAULT_AI_TEMPERATURE,
  MAX_AI_TEMPERATURE,
  MIN_AI_TEMPERATURE
} from '../../model/AiConfig'
import {
  PROVIDER_PRESETS,
  getProviderDisplayName,
  resolveProviderId
} from '../../service/ai/AiModelPresets'
import {
  getCapabilityNotice,
  getProfileSubtitle,
  resolveProfileEndpoint,
  testProviderConnection
} from '../../service/ai/AiProviderRouter'
import {
  clampTemperature,
  getPreset,
  getModelPlaceholder,
  getApiKeyPlaceholder
} from '../../service/ai/AiConfigFormLogic'
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
import { resolveKeyboardAppearance } from '../../common/utils/KeyboardAppearanceUtils'

/** 新建方案的哨兵 ID */
const NEW_ID: string = '__new__'

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
  /** 当前展开编辑的配置 ID。 */
  @State expandedProfileId: string = ''
  /** 方案名称输入值。 */
  @State editNameInput: string = ''
  /** 服务地址输入值。 */
  @State editEndpointInput: string = ''
  /** 当前编辑配置的服务商标识（决定协议链路与能力提示）。 */
  @State editProviderId: string = DEFAULT_AI_PROVIDER_ID
  /** API 密钥输入值。 */
  @State editApiKeyInput: string = ''
  /** 模型名称输入值。 */
  @State editModelInput: string = ''
  /** 温度参数输入值。 */
  @State editTemperatureInput: number = DEFAULT_AI_TEMPERATURE
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
  /**
   * 服务商选择弹窗中当前被选中的预设下标。
   *
   * SelectDialog 的 SheetInfo.action 只在「选中项变化」时触发，
   * selectedIndex 预选的单项不会触发任何回调，因此这里只记录选择，
   * 由确认按钮的 action 统一应用。
   */
  private pickedPresetIndex: number = 0
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
      this.editProviderId = DEFAULT_AI_PROVIDER_ID
      this.editNameInput = ''
      this.editEndpointInput = ''
      this.editApiKeyInput = ''
      this.editModelInput = ''
      this.editTemperatureInput = DEFAULT_AI_TEMPERATURE
      this.showAdvancedParams = false
    } else {
      const profile: AiProviderProfile | null = this.findProfile(profileId)
      if (profile) {
        this.editProviderId = resolveProviderId(profile.providerId)
        this.editNameInput = profile.name
        this.editEndpointInput = resolveProfileEndpoint(profile)
        this.editApiKeyInput = profile.apiKey
        this.editModelInput = profile.modelName
        this.editTemperatureInput = clampTemperature(profile.temperature)
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
      return this.editNameInput.length > 0 ||
        this.editEndpointInput.length > 0 ||
        this.editApiKeyInput.length > 0 ||
        this.editModelInput.length > 0 ||
        this.editTemperatureInput !== DEFAULT_AI_TEMPERATURE
    }
    const profile: AiProviderProfile | null = this.findProfile(this.expandedProfileId)
    if (!profile) {
      return false
    }
    return this.editNameInput !== profile.name ||
      this.editProviderId !== resolveProviderId(profile.providerId) ||
      this.editEndpointInput.trim() !== resolveProfileEndpoint(profile) ||
      this.editApiKeyInput !== profile.apiKey ||
      this.editModelInput !== profile.modelName ||
      this.editTemperatureInput !== clampTemperature(profile.temperature)
  }

  /** 清空编辑表单缓存和异步结果。 */
  private clearEditBuffers(): void {
    this.editProviderId = DEFAULT_AI_PROVIDER_ID
    this.editNameInput = ''
    this.editEndpointInput = ''
    this.editApiKeyInput = ''
    this.editModelInput = ''
    this.editTemperatureInput = DEFAULT_AI_TEMPERATURE
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

  /** 保存当前表单中的新建或编辑配置。 */
  saveProfile(): void {
    if (!this.editNameInput || this.editNameInput.trim().length === 0) {
      appStore.showToast('请输入方案名称')
      return
    }
    if (!this.editEndpointInput || this.editEndpointInput.trim().length === 0) {
      appStore.showToast('请输入服务地址')
      return
    }
    if (!this.editModelInput || this.editModelInput.trim().length === 0) {
      appStore.showToast('请输入模型名称')
      return
    }

    const profile: AiProviderProfile = new AiProviderProfile()
    profile.name = this.editNameInput.trim()
    profile.providerId = this.editProviderId
    profile.endpoint = this.editEndpointInput.trim()
    profile.modelName = this.editModelInput.trim()
    profile.temperature = clampTemperature(this.editTemperatureInput)

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
   * 只改「由平台决定」的字段（服务商 / 名称 / 端点 / 模型 / 温度），
   * **不改卡片归属**——是新建还是编辑现有配置由调用方决定。
   *
   * 密钥只在真正换平台时清空：用户点开平台弹窗又选了原来那一家，
   * 不该把已填好的密钥抹掉。
   *
   * @param index - 预设下标（PROVIDER_PRESETS 索引）
   */
  private applyProviderPreset(index: number): void {
    if (index < 0 || index >= PROVIDER_PRESETS.length) {
      return
    }
    this.invalidatePendingRequests()
    const preset: AiProviderPreset = PROVIDER_PRESETS[index]
    const sameProvider: boolean = this.editProviderId === preset.id
    this.editProviderId = preset.id
    this.editNameInput = preset.name
    this.editEndpointInput = preset.endpoint
    if (!sameProvider) {
      this.editApiKeyInput = ''
    }
    this.editModelInput = preset.defaultModelName
    this.editTemperatureInput = DEFAULT_AI_TEMPERATURE
    this.showAdvancedParams = false
    this.testResultMessage = ''
    this.testSuccess = false
  }

  /**
   * 点「+ 添加 AI 服务」：直接展开新建卡片并套用首选服务商。
   *
   * **刻意不经过任何弹窗回调**：「点一下就必须出现配置表单」这条不能依赖对话框
   * 语义——`SheetInfo.action` 的触发时机（选中变化才触发，与预选中项冲突）曾经
   * 让整个入口点不动。平台选择退化为表单里的一行，用户随时可换。
   */
  private startNewProfile(): void {
    if (this.hasUnsavedEdit()) {
      this.showDiscardConfirm((): void => {
        this.beginNewProfile()
      })
      return
    }
    this.beginNewProfile()
  }

  /** 执行新建卡片的初始化：先清空缓存，再套用首选服务商。 */
  private beginNewProfile(): void {
    this.clearEditBuffers()
    this.applyProviderPreset(0)
    this.expandedProfileId = NEW_ID
  }

  /**
   * 显示服务商预设选择弹窗。
   *
   * 三个必须遵守的点（前两点都由这里踩过）：
   * 1. **落地动作挂在 `SheetInfo.action` 上**。SDK 原文是 "Callback when the sheet
   *    is selected"，即选项被选中时触发；工程内 `SettingsPanel` 的「帖子楼层导航 /
   *    预加载页数 / 图片加载模式」三个单选框都是这么生效的，是已验证可靠的路径。
   * 2. **不传 `selectedIndex`**（`selectedIndex?: number` 本就可选）。一旦预选中某项，
   *    点中「已是选中态」的那一项不产生选中变化，回调就不会触发——表现为
   *    「选了没反应」；这曾让单服务商（列表只有一项且被预选中）的入口彻底点不动。
   * 3. 应用后**立即关闭弹窗**，否则用户点完看不到任何即时反馈，会以为没生效。
   *
   * `confirm.action` 作为兜底：用户不点选项直接按「确定」时，按 `pickedPresetIndex`
   * 应用（初值 0，即首选服务商）。`applyProviderPreset` 对同一下标幂等，两条路径
   * 都触发也不会重复建卡。
   */
  showProviderPresetPicker(): void {
    this.pickedPresetIndex = 0
    const items: SheetInfo[] = []
    for (let i = 0; i < PROVIDER_PRESETS.length; i++) {
      const presetIndex: number = i
      items.push({
        title: PROVIDER_PRESETS[i].name + ' - ' + PROVIDER_PRESETS[i].description,
        action: (): void => {
          this.pickedPresetIndex = presetIndex
          this.applyProviderPreset(presetIndex)
          this.providerPickerController?.close()
        }
      })
    }

    this.providerPickerController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: SelectDialog({
        title: '选择 AI 平台',
        radioContent: items,
        confirm: {
          value: '确定',
          action: (): void => {
            this.confirmProviderPreset()
          }
        }
      }),
      autoCancel: true
    })
    this.providerPickerController.open()
  }

  /**
   * 兜底应用「确定」按钮路径选定的服务商预设。
   */
  private confirmProviderPreset(): void {
    this.applyProviderPreset(this.pickedPresetIndex)
  }

  /**
   * 获取模型输入框占位提示。
   *
   * @returns 当前平台默认模型或通用提示
   */
  private getModelPlaceholder(): string {
    return getModelPlaceholder(this.getPreset())
  }

  /**
   * 获取 API Key 输入框占位提示。
   *
   * @returns DeepSeek 的 API Key 格式提示
   */
  private getApiKeyPlaceholder(): string {
    return getApiKeyPlaceholder(this.getPreset())
  }

  /**
   * 获取当前编辑配置对应的服务商预设。
   *
   * @returns 匹配的预设，未匹配时返回 null
   */
  private getPreset(): AiProviderPreset | null {
    return getPreset(this.editProviderId)
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
    tempProfile.providerId = this.editProviderId
    tempProfile.endpoint = endpoint
    tempProfile.apiKey = apiKey
    tempProfile.modelName = modelName

    try {
      const result: AiTestResult = await testProviderConnection(tempProfile)
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

            Text('选择服务商并填写连接信息；DeepSeek 支持内置联网搜索，其他平台按普通对话使用')
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
      this.ScenarioCard(AiScenario.THREAD_SUMMARY)
      this.ScenarioCard(AiScenario.USER_ANALYSIS)
      this.ScenarioCard(AiScenario.WATER_RULE_GEN)
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
    // 全帖总结与单楼层总结是两件事（跨页取数 vs 单层正文），图标必须分开，
    // 与 ThreadPanel 标题栏那颗按钮用的是同一份资源
    if (scenario === AiScenario.THREAD_SUMMARY) {
      return $r('app.media.icon_ai_thread')
    }
    // 去水规则生成是「漏斗 + 星芒」：与设置页那颗去水图标同族（漏斗），星芒区别于纯手动规则
    if (scenario === AiScenario.WATER_RULE_GEN) {
      return $r('app.media.icon_ai_water_rules')
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

        Text(getProfileSubtitle(profile))
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
   * 服务商选择行。
   *
   * 平台选择的唯一入口。刻意做成表单内的一行而不是"新建前置弹窗"：
   * 表单的出现时机不受任何对话框回调影响，也顺带让已建配置能直接换平台。
   */
  @Builder
  ProviderPickerRow() {
    Column() {
      Text('服务商')
        .fontSize(13)
        .fontColor(AppColors.textSecondary)
        .width('100%')
        .margin({ bottom: 4 })

      Row() {
        Text(getProviderDisplayName(this.editProviderId))
          .fontSize(14)
          .fontColor(UIMaterialManager.inputForeground)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text('更换 ▾')
          .fontSize(13)
          .fontColor(AppColors.primary)
          .flexShrink(0)
      }
      .width('100%')
      .height(40)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(AppColors.bgSecondary)
      .borderRadius(8)
      .onClick(() => {
        this.showProviderPresetPicker()
      })
    }
    .width('100%')
    .margin({ bottom: 10 })
  }

  /**
   * 能力提示行。
   *
   * 当前所选服务商缺少某项能力（如内置联网搜索）时明确告知用户，
   * 避免在对话中被静默降级后误以为 AI 已经联网检索过。
   */
  @Builder
  ProviderCapabilityNotice() {
    Column() {
      if (getCapabilityNotice(this.editProviderId).length > 0) {
        Row() {
          Text('ℹ️ ' + getCapabilityNotice(this.editProviderId))
            .fontSize(11)
            .fontColor(AppColors.textTertiary)
            .lineHeight(16)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .backgroundColor(AppColors.bgSecondary)
        .borderRadius(8)
        .margin({ bottom: 10 })
      }
    }
    .width('100%')
  }

  /**
   * 公共表单字段 — 按操作顺序排列：方案名称、服务地址（可编辑）、API 密钥、
   * 模型名称（手动输入）、联通测试及保存/取消按钮。
   *
   * 由 ProfileCardBody 和 NewProfileCard 共享，
   * 避免两处各维护一份相同的表单代码。
   */
  @Builder
  ProfileFormFields() {
    Column() {
      this.ProviderPickerRow()
      this.ProviderCapabilityNotice()

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

    Column() {
      Text('服务地址')
        .fontSize(13)
        .fontColor(AppColors.textSecondary)
        .width('100%')
        .margin({ bottom: 4 })

      TextInput({ placeholder: 'https://api.example.com/v1', text: this.editEndpointInput })
        .onChange((v: string) => {
          this.editEndpointInput = v
        })
        .width('100%')
        .height(40)
        .attributeModifier(UIMaterialManager.inputMaterial)
        .borderRadius(8)
        .fontSize(14)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .padding({ left: 12, right: 12 })

      Text('已按所选平台自动填充，可按需修改')
        .fontSize(11)
        .fontColor(AppColors.textTertiary)
        .width('100%')
        .margin({ top: 4 })
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
          Text('调整回答随机性；回复长度不设上限，由模型自行决定')
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
              .systemMaterial(UIMaterialManager.controlMaterial)
              .onChange((value: number, mode: SliderChangeMode): void => {
                this.editTemperatureInput = clampTemperature(value)
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
      this.startNewProfile()
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

      Text('添加 AI 服务后，\n帖子总结、用户分析、智能去水即可使用')
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
