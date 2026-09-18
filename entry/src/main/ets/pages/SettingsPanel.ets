/**
 * 设置面板
 */


import { appStore } from '../store/AppStore'
import { routerStore, Screen } from '../store/RouterStore'
import { logoutOrchestrator } from '../service/LogoutOrchestrator'
import {
  AppColors,
  ImageLoadStrategy,
  SettingsIconColors,
  ThreadNavMode,
  THEME_OPTIONS,
  ThemeOption
} from '../common/constants/Constants'
import { TipsDialog, SelectDialog, CustomContentDialog } from '@kit.ArkUI'
import { ActionOption, CredentialPasswordContent, SelectRadioResult } from '../common/dialogs/Dialogs'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { SettingRow, SettingToggleRow, SettingPickerRow } from '../common/components/SettingRow'
import { serializeCredentialExport } from '../common/security/CredentialExportCrypto'
import { picker, fileIo, storageStatistics } from '@kit.CoreFileKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { common, contextConstant } from '@kit.AbilityKit'
import type { AiProviderProfile } from '../model/AiConfig'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'
import { UIMaterialManager } from '../common/managers/UIMaterialManager'
import { movingPhotoCacheDir } from '../common/media/MovingPhotoCache'
import { removeDirRecursively } from '../common/utils/FileUtils'

@Component
export struct SettingsPanel {
  @StorageProp('themeName') themeName: string = 'light'
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @StorageProp('aiConfigVersion') @Watch('onAiConfigVersionChange') aiConfigVersion: number = 0
  /** 当前帖子内容字号，用于响应字体设置页的实时更新。 */
  @StorageProp('contentFontSize') contentFontSize: number = 15
  @State cacheSizeText: string = ''
  @State clearingCache: boolean = false
  @State imageStrategyBadge: string = '始终加载'
  @State threadNavBadge: string = '无缝加载'
  @State prefetchPageBadge: string = '3 页'
  @State aiProviderBadge: string = '未配置 AI'
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 滚动容器当前视口高度。 */
  @State scrollViewportHeight: number = 1
  /** 凭证导出弹窗的密码输入（供 CustomContentDialog 内容构件双向绑定）。 */
  @State exportPassword: string = ''

  /** 设置页滚动控制器。 */
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

  clearCacheDialogController?: CustomDialogController = new CustomDialogController({
    backgroundColor: Color.Transparent,
    systemMaterial: UIMaterialManager.dialogMaterial,
    maskColor: UIMaterialManager.scrim,
    builder: TipsDialog({
      imageRes: $r('app.media.settings_clear_cache'),
      title: '清除缓存',
      content: '确定要清除所有缓存吗？\n清除后图片等资源需要重新加载',
      primaryButton: {
        value: '清除',
        fontColor: AppColors.white,
        background: AppColors.destructive,
        action: () => {
          this.clearCache()
        }
      },
      secondaryButton: {
        value: '取消'
      }
    }),
    autoCancel: true
  })

  imageStrategyDialogController?: CustomDialogController
  threadNavDialogController?: CustomDialogController
  prefetchPageDialogController?: CustomDialogController
  exportCredentialDialogController?: CustomDialogController
  logoutDialogController?: CustomDialogController = new CustomDialogController({
    backgroundColor: Color.Transparent,
    systemMaterial: UIMaterialManager.dialogMaterial,
    maskColor: UIMaterialManager.scrim,
    builder: TipsDialog({
      imageRes: $r('app.media.settings_logout'),
      title: '退出登录',
      content: '确定要退出登录吗？\n退出后需要重新输入账号密码登录',
      primaryButton: {
        value: '退出',
        fontColor: AppColors.white,
        background: AppColors.destructive,
        action: async () => {
          await logoutOrchestrator.logout(this.getUIContext())
        }
      },
      secondaryButton: {
        value: '取消'
      }
    }),
    autoCancel: true
  })

  /** 凭证导出弹窗的自定义内容（按钮随密码位数切换激活态，故自绘在内容区）。 */
  @Builder
  exportPasswordContent() {
    CredentialPasswordContent({
      password: this.exportPassword,
      minLength: 8,
      confirmLabel: '导出',
      onPasswordChange: (value: string): void => { this.exportPassword = value },
      onConfirm: (password: string): void => {
        this.exportCredentialDialogController?.close()
        this.exportEncryptedCredential(password)
      },
      onCancel: (): void => { this.exportCredentialDialogController?.close() }
    })
  }

  /**
   * 构造选项类对话框的 radioContent。
   *
   * 官方 `SelectDialog` 的选项是 `SheetInfo[]`，选中即触发该项 action；
   * 这里把「选中 → 应用设置」的回调直接挂在每一项上，交互与迁移前的
   * ActionSheetDialog（点选项立即生效）保持一致。
   *
   * @param options - 选项表
   * @param current - 当前生效取值（用于换算初始选中下标）
   * @param onPick - 选中回调
   * @returns 官方单选列表内容与初始下标
   */
  private buildRadioContent(options: ActionOption[], current: number,
    onPick: (value: number) => void): SelectRadioResult {
    const result: SelectRadioResult = new SelectRadioResult()
    for (let i = 0; i < options.length; i++) {
      const opt: ActionOption = options[i]
      if (opt.value === current) {
        result.selectedIndex = i
      }
      result.items.push({
        title: opt.label,
        action: (): void => { onPick(opt.value) }
      })
    }
    return result
  }

  aboutToAppear(): void {
    this.refreshCacheSize()
    this.imageStrategyBadge = this.imageStrategyLabel(appStore.settings.imageLoadStrategy)
    this.threadNavBadge = this.threadNavLabel(appStore.settings.threadNavMode)
    this.prefetchPageBadge = this.prefetchPageLabel(appStore.settings.prefetchPageCount)
    this.updateAiBadge()
  }

  aboutToDisappear() {
    this.clearCacheDialogController = undefined
    this.logoutDialogController = undefined
    this.imageStrategyDialogController = undefined
    this.threadNavDialogController = undefined
    this.prefetchPageDialogController = undefined
    this.exportCredentialDialogController = undefined
  }

  private onAiConfigVersionChange(): void {
    this.updateAiBadge()
  }

  private formatSize(bytes: number): string {
    if (bytes < 1024) {
      return bytes + ' B'
    }
    const kb: number = bytes / 1024
    if (kb < 1024) {
      return kb.toFixed(1) + ' KB'
    }
    const mb: number = kb / 1024
    if (mb < 1024) {
      return mb.toFixed(1) + ' MB'
    }
    const gb: number = mb / 1024
    return gb.toFixed(2) + ' GB'
  }

  private refreshCacheSize(): void {
    storageStatistics.getCurrentBundleStats((err: BusinessError, bundleStats: storageStatistics.BundleStats) => {
      if (!err) {
        this.cacheSizeText = this.formatSize(bundleStats.cacheSize)
      } else {
        this.cacheSizeText = '未知'
      }
    })
  }

  private async clearCache(): Promise<void> {
    if (this.clearingCache) {
      return
    }
    this.clearingCache = true
    let context: common.UIAbilityContext | null = null
    let originArea: number = 0
    let appContext: common.Context | null = null
    let originAppArea: number = 0
    try {
      context = this.getUIContext().getHostContext() as common.UIAbilityContext
      originArea = context.area
      /* filesDir 随 `area` 变化，必须在切换分区**之前**取：播放器写缓存用的是默认分区的
         filesDir（见 `MovingPhotoCache`）。若在 `area = EL2` 之后再读，一旦默认分区不是
         EL2，这里算出的就是另一个目录，"清除缓存"会静默失效。 */
      const abilityFilesDir: string = context.filesDir
      const dirs: string[] = []

      context.area = contextConstant.AreaMode.EL1
      dirs.push(context.cacheDir)
      context.area = contextConstant.AreaMode.EL2
      dirs.push(context.cacheDir)
      /* 动态照片播放器的封面/视频缓存：位于持久目录 filesDir 下，
         不在上面的 cacheDir 范围内，必须显式加入，否则"清除缓存"清不掉它。
         另注：整目录删除不避让正在播放的实例（播放器下次点播放会报错并收起），
         缓存淘汰路径本身是避让的（见 MovingPhotoCache 的占用计数）。 */
      dirs.push(movingPhotoCacheDir(abilityFilesDir))

      appContext = context.getApplicationContext()
      originAppArea = appContext.area
      appContext.area = contextConstant.AreaMode.EL1
      dirs.push(appContext.cacheDir)
      appContext.area = contextConstant.AreaMode.EL2
      dirs.push(appContext.cacheDir)

      for (let i = 0; i < dirs.length; i++) {
        /* 必须递归删：`fileIo.rmdirSync` 只删空目录（13900032 Directory not empty），
           而这些目录里必然有文件——直接用它只会静默失败，「缓存已清除」名不副实 */
        removeDirRecursively(dirs[i])
      }
      this.refreshCacheSize()
      appStore.showToast('缓存已清除')
    } catch (e) {
      appStore.showToast('清除缓存失败')
    } finally {
      if (context) {
        context.area = originArea
      }
      if (appContext) {
        appContext.area = originAppArea
      }
      this.clearingCache = false
    }
  }

  private async handleExport(): Promise<void> {
    const token = appStore.auth.token
    const session = appStore.getSession(token)
    if (!session) {
      appStore.showToast('未找到登录会话')
      return
    }

    this.exportPassword = ''
    this.exportCredentialDialogController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: CustomContentDialog({
        primaryTitle: '加密导出凭证',
        secondaryTitle: '导出的文件将使用此密码加密，导入时需要再次输入（至少 8 位）。',
        contentBuilder: (): void => { this.exportPasswordContent() }
        // 不传 buttons：官方按钮区不支持动态激活态（见 CredentialPasswordContent 说明），
        // 「取消 / 导出」由内容区自绘。
      }),
      autoCancel: true
    })
    this.exportCredentialDialogController?.open()
  }

  private async exportEncryptedCredential(password: string): Promise<void> {
    try {
      const token = appStore.auth.token
      const session = appStore.getSession(token)
      if (!session) {
        appStore.showToast('未找到登录会话')
        return
      }

      const context = this.getUIContext().getHostContext() as common.UIAbilityContext
      const userName = session?.nickName || `User${session?.uid ?? ''}`
      const documentSaveOptions = new picker.DocumentSaveOptions()
      documentSaveOptions.newFileNames = [`nga_${userName}.ngacred`]
      documentSaveOptions.fileSuffixChoices = ['NGA 凭证|.ngacred']

      const documentViewPicker = new picker.DocumentViewPicker(context)
      const uris: string[] = await documentViewPicker.save(documentSaveOptions)

      if (uris.length === 0) {
        return
      }

      const content = await serializeCredentialExport({ uid: session.uid, cid: session.cid }, password)
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE)
      fileIo.writeSync(file.fd, content)
      fileIo.closeSync(file)
      appStore.showToast('账号凭证已加密导出')
    } catch (e) {
      appStore.showToast((e as Error).message || '导出失败')
    }
  }

  private imageStrategyLabel(strategy: string): string {
    if (strategy === ImageLoadStrategy.MANUAL) {
      return '手动加载'
    }
    if (strategy === ImageLoadStrategy.WIFI_ONLY) {
      return 'WiFi下加载'
    }
    return '始终加载'
  }

  private imageStrategyOptions(): ActionOption[] {
    return [
      { label: '始终加载（主动式）', value: 0 },
      { label: '手动加载（被动式）', value: 1 },
      { label: '只在WiFi下加载', value: 2 },
    ]
  }

  private threadNavLabel(mode: string): string {
    if (mode === ThreadNavMode.PAGE) {
      return '传统翻页'
    }
    return '无缝加载'
  }

  private threadNavOptions(): ActionOption[] {
    return [
      { label: '无缝加载（连续滚动）', value: parseInt(ThreadNavMode.SEAMLESS) },
      { label: '传统翻页（跳转器换页）', value: parseInt(ThreadNavMode.PAGE) },
    ]
  }

  private showThreadNavPicker(): void {
    const radio: SelectRadioResult = this.buildRadioContent(
      this.threadNavOptions(),
      parseInt(appStore.settings.threadNavMode),
      (v: number): void => {
        appStore.settingsStore.setThreadNavMode(String(v))
        this.threadNavBadge = this.threadNavLabel(String(v))
      }
    )
    this.threadNavDialogController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: SelectDialog({
        title: '帖子楼层导航',
        selectedIndex: radio.selectedIndex,
        radioContent: radio.items,
        confirm: { value: '确定' }
      }),
      autoCancel: true
    })
    this.threadNavDialogController?.open()
  }

  private prefetchPageLabel(count: number): string {
    if (count <= 0) {
      return '关闭'
    }
    return `${count} 页`
  }

  private prefetchPageOptions(): ActionOption[] {
    const options: ActionOption[] = []
    for (let i = 0; i <= 5; i++) {
      options.push({
        label: i === 0 ? '关闭（不预加载）' : `${i} 页`,
        value: i
      })
    }
    return options
  }

  private showPrefetchPagePicker(): void {
    const radio: SelectRadioResult = this.buildRadioContent(
      this.prefetchPageOptions(),
      appStore.settings.prefetchPageCount,
      (v: number): void => {
        appStore.settingsStore.setPrefetchPageCount(v)
        this.prefetchPageBadge = this.prefetchPageLabel(v)
      }
    )
    this.prefetchPageDialogController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: SelectDialog({
        title: '预加载页数',
        selectedIndex: radio.selectedIndex,
        radioContent: radio.items,
        confirm: { value: '确定' }
      }),
      autoCancel: true
    })
    this.prefetchPageDialogController?.open()
  }

  private showImageStrategyPicker(): void {
    const radio: SelectRadioResult = this.buildRadioContent(
      this.imageStrategyOptions(),
      parseInt(appStore.settings.imageLoadStrategy),
      (v: number): void => {
        appStore.settingsStore.setImageLoadStrategy(String(v))
        this.imageStrategyBadge = this.imageStrategyLabel(String(v))
      }
    )
    this.imageStrategyDialogController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: SelectDialog({
        title: '图片加载模式',
        selectedIndex: radio.selectedIndex,
        radioContent: radio.items,
        confirm: { value: '确定' }
      }),
      autoCancel: true
    })
    this.imageStrategyDialogController?.open()
  }

  private updateAiBadge(): void {
    const profile: AiProviderProfile | null = appStore.settingsStore.getActiveAiProfile()
    if (profile) {
      this.aiProviderBadge = profile.name
    } else if (appStore.settings.aiProfiles.length > 0) {
      this.aiProviderBadge = '未选择 AI'
    } else {
      this.aiProviderBadge = '未配置 AI'
    }
  }

  build() {
    Stack() {
      Column() {
        Scroll(this.scroller) {
          Column() {
            // ---- 主题选择 ----
            Column() {
              Text('主题选择').fontSize(15).fontColor(AppColors.textSecondary)
                .width('100%').padding({ bottom: 10 })

              Row() {
                ForEach(THEME_OPTIONS, (theme: ThemeOption) => {
                  this.ThemeCard(theme)
                }, (theme: ThemeOption) => theme.name)
              }
              .width('100%')
            }
            .width('92%')
            .backgroundColor(AppColors.bgTertiary)
            .borderRadius(12)
            .padding(12)
            .margin({ top: 16 })

            // ---- Block 1: 黑名单管理 / 用户备注 / 关键词屏蔽 / 自动签到 ----
            Column() {
              SettingRow({
                iconRes: $r('app.media.settings_blacklist'), iconColor: SettingsIconColors.blacklist, label: '黑名单管理',
                onAction: () => {
                  routerStore.navigateActivity(Screen.blacklist())
                }
              })

              Divider().margin({ left: 60 }).color(AppColors.separator)

              SettingRow({
                iconRes: $r('app.media.settings_user_notes'), iconColor: SettingsIconColors.userNotes, label: '用户备注',
                onAction: () => {
                  routerStore.navigateActivity(Screen.notes())
                }
              })

              Divider().margin({ left: 60 }).color(AppColors.separator)

              SettingRow({
                iconRes: $r('app.media.settings_keyword_filter'), iconColor: SettingsIconColors.keywordFilter, label: '关键词屏蔽',
                onAction: () => {
                  routerStore.navigateActivity(Screen.filterKeywords())
                }
              })

              Divider().margin({ left: 60 }).color(AppColors.separator)

              SettingToggleRow({
                iconRes: $r('app.media.settings_auto_checkin'), iconColor: SettingsIconColors.autoCheckin, label: '自动签到',
                isOn: appStore.settings.autoCheckin,
                onChange: (v: boolean) => {
                  appStore.settingsStore.setAutoCheckin(v)
                }
              })

            }
            .width('92%')
            .backgroundColor(AppColors.bgTertiary)
            .borderRadius(12)
            .margin({ top: 12 })

            // ---- Block 2: AI 配置 / 智感握姿 / 语音朗读 ----
            Column() {
              SettingPickerRow({
                iconRes: $r('app.media.settings_ai_config'), iconColor: SettingsIconColors.aiConfig, label: 'AI 配置',
                badgeText: this.aiProviderBadge,
                onAction: () => {
                  routerStore.navigateActivity(Screen.aiSettings())
                }
              })

              Divider().margin({ left: 60 }).color(AppColors.separator)

              SettingToggleRow({
                iconRes: $r('app.media.settings_smart_grip'), iconColor: SettingsIconColors.smartGrip, label: '智感握姿',
                isOn: appStore.settings.smartGrip,
                onChange: (v: boolean) => {
                  appStore.settingsStore.setSmartGrip(v)
                }
              })

              Divider().margin({ left: 60 }).color(AppColors.separator)

              SettingRow({
                iconRes: $r('app.media.settings_tts'), iconColor: SettingsIconColors.tts, label: '语音朗读',
                onAction: () => {
                  routerStore.navigateActivity(Screen.ttsSettings())
                }
              })
            }
            .width('92%')
            .backgroundColor(AppColors.bgTertiary)
            .borderRadius(12)
            .margin({ top: 12 })

            // ---- Block 3A: 显示签名 / 图片加载模式 ----
            Column() {
              SettingToggleRow({
                iconRes: $r('app.media.settings_signature'), iconColor: SettingsIconColors.signature, label: '显示签名',
                isOn: appStore.settings.showSignature,
                onChange: (v: boolean) => {
                  appStore.settingsStore.setShowSignature(v)
                }
              })

              Divider().margin({ left: 60 }).color(AppColors.separator)

              SettingPickerRow({
                iconRes: $r('app.media.settings_image_loading'), iconColor: SettingsIconColors.imageLoading, label: '图片加载模式',
                badgeText: this.imageStrategyBadge,
                onAction: () => {
                  this.showImageStrategyPicker()
                }
              })

              Divider().margin({ left: 60 }).color(AppColors.separator)

              SettingPickerRow({
                iconRes: $r('app.media.settings_font_size'), iconColor: SettingsIconColors.fontSize, label: '字体大小',
                badgeText: `${this.contentFontSize}`,
                onAction: () => {
                  routerStore.navigateActivity(Screen.fontSizeSettings())
                }
              })

              Divider().margin({ left: 60 }).color(AppColors.separator)

              SettingPickerRow({
                iconRes: $r('app.media.settings_thread_navigation'), iconColor: SettingsIconColors.threadNavigation, label: '帖子楼层导航',
                badgeText: this.threadNavBadge,
                onAction: () => {
                  this.showThreadNavPicker()
                }
              })

              Divider().margin({ left: 60 }).color(AppColors.separator)

              SettingPickerRow({
                iconRes: $r('app.media.settings_page_prefetch'), iconColor: SettingsIconColors.pagePrefetch, label: '预加载页数',
                badgeText: this.prefetchPageBadge,
                onAction: () => {
                  this.showPrefetchPagePicker()
                }
              })

              Divider().margin({ left: 60 }).color(AppColors.separator)

              SettingToggleRow({
                iconRes: $r('app.media.settings_reading_progress'), iconColor: SettingsIconColors.readingProgress, label: '记录阅读进度',
                isOn: appStore.settings.recordReadingProgress,
                onChange: (v: boolean) => {
                  appStore.settingsStore.setRecordReadingProgress(v)
                }
              })

              Divider().margin({ left: 60 }).color(AppColors.separator)

              SettingToggleRow({
                iconRes: $r('app.media.settings_internal_browser'), iconColor: SettingsIconColors.internalBrowser, label: '内置网页浏览',
                isOn: appStore.settings.useInternalWebView,
                onChange: (v: boolean) => {
                  appStore.settingsStore.setUseInternalWebView(v)
                }
              })

            }
            .width('92%')
            .backgroundColor(AppColors.bgTertiary)
            .borderRadius(12)
            .margin({ top: 12 })

            // ---- Block 3B: 调试模式 ----
            Column() {
              SettingToggleRow({
                iconRes: $r('app.media.settings_debug_mode'), iconColor: SettingsIconColors.debugMode, label: '调试模式',
                isOn: appStore.settings.debugMode,
                onChange: (v: boolean) => {
                  appStore.settingsStore.setDebugMode(v)
                }
              })
            }
            .width('92%')
            .backgroundColor(AppColors.bgTertiary)
            .borderRadius(12)
            .margin({ top: 12 })

            // ---- Block 3C: 导出账号凭证 / 清除缓存 / 退出登录 ----
            Column() {
              SettingRow({
                iconRes: $r('app.media.settings_credential_export'), iconColor: SettingsIconColors.credentialExport, label: '导出账号凭证',
                onAction: () => {
                  this.handleExport()
                }
              })

              Divider().margin({ left: 60 }).color(AppColors.separator)

              SettingPickerRow({
                iconRes: $r('app.media.settings_clear_cache'), iconColor: SettingsIconColors.clearCache, label: '清除缓存',
                badgeText: this.cacheSizeText,
                onAction: () => {
                  this.clearCacheDialogController?.open()
                }
              })

              Divider().margin({ left: 60 }).color(AppColors.separator)

              Row() {
                Stack() {
                  Image($r('app.media.settings_logout')).width(17).height(17).fillColor(AppColors.white)
                }
                .width(29).height(29).borderRadius(6).backgroundColor(AppColors.destructive).margin({ right: 12 })

                Text('退出登录').fontSize(17).fontColor(AppColors.destructive).layoutWeight(1)
              }
              .width('100%').height(44).padding({ left: 16, right: 16 }).alignItems(VerticalAlign.Center)
              .onClick(() => {
                this.logoutDialogController?.open()
              })
            }
            .width('92%')
            .backgroundColor(AppColors.bgTertiary)
            .borderRadius(12)
            .margin({ top: 12 })
          }
          .width('100%').alignItems(HorizontalAlign.Center).padding({ bottom: 32 })
        }
        .layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
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
      .width('100%').height('100%').backgroundColor(AppColors.bg)

      PanelNavBar({ title: '设置', scrollEffectProgress: this.titleScrollEffectProgress })
        .width('100%').position({ x: 0, y: 0 })
    }
    .width('100%').height('100%')
  }

  @Builder
  ThemeCard(theme: ThemeOption) {
    Column() {
      Stack() {
        if (theme.name === 'system') {
          Column() {
            Stack() {
              Column() {
                Row().width('80%').height(3).backgroundColor('#C08A4A').borderRadius(2)
                Row().width('60%').height(3).backgroundColor('#3E2A1D').borderRadius(2).opacity(0.5).margin({ top: 5 })
                Row().width('45%').height(3).backgroundColor('#3E2A1D').borderRadius(2).opacity(0.25).margin({ top: 4 })
              }
              .padding(8).alignItems(HorizontalAlign.Start).width('100%')
            }
            .width('100%').layoutWeight(1).backgroundColor('#FEFAF6')

            Stack() {
              Column() {
                Row().width('80%').height(3).backgroundColor('#D4A85A').borderRadius(2)
                Row().width('60%').height(3).backgroundColor('#EAE2D8').borderRadius(2).opacity(0.5).margin({ top: 5 })
                Row().width('45%').height(3).backgroundColor('#EAE2D8').borderRadius(2).opacity(0.25).margin({ top: 4 })
              }
              .padding(8).alignItems(HorizontalAlign.Start).width('100%')
            }
            .width('100%').layoutWeight(1).backgroundColor('#1A1A1E')
          }
          .width('100%').height('100%')
        } else {
          Column() {
            Row().width('100%').height(2).backgroundColor(theme.primaryColor)
            Column() {
              Row().width('55%').height(3).backgroundColor(theme.textColor).borderRadius(2).opacity(0.55)
              Row().width('35%').height(3).backgroundColor(theme.textColor).borderRadius(2).opacity(0.25).margin({ top: 5 })
              Row().width('70%').height(3).backgroundColor(theme.textColor).borderRadius(2).opacity(0.35).margin({ top: 5 })
              Row().width('45%').height(3).backgroundColor(theme.textColor).borderRadius(2).opacity(0.15).margin({ top: 5 })
            }
            .padding(8).alignItems(HorizontalAlign.Start).width('100%')
          }
          .width('100%').height('100%').backgroundColor(theme.bgColor)
        }
      }
      .width('100%').height(90).borderRadius(8)
      .clip(true)
      .border({
        width: this.themeName === theme.name ? 2 : 1,
        color: this.themeName === theme.name ? AppColors.primary : AppColors.separator
      })

      Row() {
        Text(theme.label).fontSize(13).fontColor(AppColors.textPrimary).fontWeight(FontWeight.Medium)
        Blank()
        if (this.themeName === theme.name) {
          Image($r('app.media.icon_check')).width(14).height(14).fillColor(AppColors.primary)
        } else {
          Stack().width(14).height(14).borderRadius(7).border({ width: 1.5, color: AppColors.separator })
        }
      }
      .width('100%').margin({ top: 8 })
    }
    .layoutWeight(1)
    .margin({ left: 4, right: 4 })
    .padding(8)
    .backgroundColor(AppColors.bgSecondary)
    .borderRadius(10)
    .onClick(() => {
      if (theme.name !== this.themeName) {
        appStore.settingsStore.setTheme(theme.name)
      }
    })
  }
}
