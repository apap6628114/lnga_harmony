/**
 * 写私信底部面板（共享组件）。
 *
 * 由通知面板私信 Tab 与私信列表面板复用：收件人 / 主题 / 内容 / 发送；
 * 发送成功后通过 onSent 通知父组件刷新会话列表。
 * 支持 composeToInit 直达（如他人主页「发私信」跳转时自动弹出并预填收件人）。
 *
 * 承载方式为官方半模态面板（`bindSheet`）：进出场动效、下拉手势由系统承担；
 * 系统附属元素（拖动条 / 关闭叉）关闭，改用内容自带的指示条与既有交互；
 * 面板**背板**由系统沉浸材质承担（`SheetOptions.systemMaterial`——半模态转场属于 Release 允许
 * 「页面内全部区域」生效的弹窗类接口），内容层只保留半透明内容色
 * （`UIMaterialManager.dialogFieldMaterial`），不再自绘玻璃。
 * 内容层背景必须显式置 `Color.Transparent`：`BindOptions.backgroundColor` 默认是
 * `Color.White`，这层白色会盖住背板材质。
 *
 * **弹出与键盘避让接线与 `NewTopicDialog` / `ReplyDialog` 同构**（编辑器两件套的适配模式）：
 * 1. `SheetOptions.preferType` 一律 `SheetType.BOTTOM`（贴底弹出，宽屏只限宽）；
 * 2. `SheetOptions.keyboardAvoidMode: NONE` 关掉系统避让，**避让由本组件自己做**；
 * 3. 本组件订阅窗口 `keyboardHeightChange`，把键盘高度垫进内容底部留白，输入区与发送按钮
 *    因此始终位于输入法上方。
 *
 * 只做其中一部分会得到"看起来能用、键盘一弹就错位"的面板：只设 `NONE` 不垫高 → 内容被键盘盖住；
 * 只垫高不设 `NONE` → 系统与应用各避让一次，留出双倍空白。
 */

import { window } from '@kit.ArkUI'
import { appStore } from '../../store/AppStore'
import { sendMessage } from '../../service/api/MessageApi'
import type { MessageSendResult } from '../../model/MessageResult'
import { AppColors, SheetWidthConstants } from '../constants/Constants'
import { UIMaterialManager } from '../managers/UIMaterialManager'
import { DOMAIN_UI, formatError, Logger } from '../utils/Logger'

/** 写私信面板日志。 */
const logger = new Logger(DOMAIN_UI, 'ComposeMessageSheet')

/** 无键盘时的最小贴底留白（vp），与编辑器两件套同值。 */
const BOTTOM_GAP: number = 8

@Component
export struct ComposeMessageSheet {
  /** 弹层是否可见（父组件双向绑定）。 */
  @Link showCompose: boolean
  /** 初始收件人（直达写私信时传入；可后续编辑）。 */
  @Prop composeToInit: string = ''
  /** 发送成功回调（父组件用于刷新会话列表）。 */
  onSent?: () => void
  /** 当前窗口断点：决定半模态样式与面板宽度（与回复 / 发新主题编辑器同一套基准）。 */
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  /** 当前窗口宽度（vp）：面板宽度按窗口收敛的依据（见 `SheetWidthConstants`）。 */
  @StorageProp('windowWidthVp') windowWidthVp: number = 0
  @State composeTo: string = ''
  @State composeSubject: string = ''
  @State composeContent: string = ''
  @State sending: boolean = false

  /**
   * 当前软键盘高度（vp）。
   *
   * 与编辑器两件套同一套避让方式：面板关掉了系统避让（`keyboardAvoidMode: NONE`），
   * 由本组件把键盘高度垫进内容底部留白，输入区因此始终位于输入法上方。
   */
  @State private keyboardHeightVp: number = 0

  /** 当前应用主窗口，用于管理软键盘高度监听。 */
  private hostWindow: window.Window | undefined = undefined

  /**
   * 软键盘高度变化回调。
   *
   * 系统事件返回 px；布局属性使用 vp，因此通过当前 UIContext 完成单位转换。
   */
  private readonly keyboardHeightChangeCallback: (height: number) => void = (height: number): void => {
    this.keyboardHeightVp = this.getUIContext().px2vp(height)
  }

  aboutToAppear(): void {
    if (this.composeToInit.length > 0) {
      this.composeTo = this.composeToInit
    }
    this.subscribeKeyboardHeightChange()
  }

  aboutToDisappear(): void {
    this.unsubscribeKeyboardHeightChange()
  }

  /** 获取主窗口并订阅软键盘高度变化（面板消失时必须注销，见 `unsubscribeKeyboardHeightChange`）。 */
  private async subscribeKeyboardHeightChange(): Promise<void> {
    try {
      const hostContext = this.getUIContext().getHostContext()
      if (hostContext === undefined) {
        return
      }
      const hostWindow = await window.getLastWindow(hostContext)
      this.hostWindow = hostWindow
      hostWindow.on('keyboardHeightChange', this.keyboardHeightChangeCallback)
    } catch (error) {
      logger.warn('subscribe keyboard height change failed: %{public}s', formatError(error))
    }
  }

  /**
   * 注销软键盘高度变化监听并清空避让高度。
   *
   * 少了这道注销，面板关闭后回调仍会写 `@State`（组件已销毁时的无效写入），
   * 且窗口上会逐次累积监听。
   */
  private unsubscribeKeyboardHeightChange(): void {
    if (this.hostWindow !== undefined) {
      try {
        this.hostWindow.off('keyboardHeightChange', this.keyboardHeightChangeCallback)
      } catch (error) {
        logger.warn('unsubscribe keyboard height change failed: %{public}s', formatError(error))
      }
      this.hostWindow = undefined
    }
    this.keyboardHeightVp = 0
  }

  /** 关闭弹层并清空输入（发送成功路径）。 */
  private closeAndReset(): void {
    this.showCompose = false
    this.composeTo = ''
    this.composeSubject = ''
    this.composeContent = ''
  }

  /**
   * 半模态面板选项。
   *
   * 弹出与键盘避让参数对齐回复 / 发新主题编辑器（`FloatingLayerComponent.editorSheetOptions`）：
   * - **所有断点统一走 `SheetType.BOTTOM` 贴底弹出**（宽屏只限宽，不切居中浮层）。居中形态曾用于
   *   md / lg，但它与应用自做的键盘避让互斥——会把面板撑高、在内容下方留出长空白，并让面板底边
   *   越出可视区、平掉底部圆角（详见 `FloatingLayerComponent.editorSheetOptions` 的说明）；
   * - `keyboardAvoidMode: NONE` 关掉**系统**避让，避让改由本组件订阅窗口键盘高度自己完成
   *   （见 `keyboardHeightChangeCallback` 与 `ComposeSheetContent` 的底部留白），与
   *   `NewTopicDialog` 完全同构；
   * - 宽屏限宽仍是必要的：否则贴底面板会横贯整个窗口，内容里按百分比布局的输入框
   *   （`width('92%')`）会跟着一起拉长。
   *
   * @returns 半模态面板选项
   */
  private composeSheetOptions(): SheetOptions {
    const options: SheetOptions = {
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      showClose: false,
      // 内容层完全让位给系统材质，不做设备降级（见 UIMaterialManager 的约定说明）
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.sheetMaterial,
      maskColor: AppColors.overlay,
      preferType: SheetType.BOTTOM,
      // 关闭系统避让：键盘避让由本组件自己做（底部留白 = BOTTOM_GAP + 键盘高度）。
      // 少了这一项，系统会先按自己的方式避让一次，内容再叠加一次键盘高度，
      // 结果是输入法上方凭空多出一段空白，且面板高度随键盘抖动。
      keyboardAvoidMode: SheetKeyboardAvoidMode.NONE,
      onDisappear: () => {
        // 系统关闭（下滑 / 点击蒙层）后回写可见性，保证 @Link 状态与面板一致
        this.showCompose = false
      }
    }
    // 宽屏限宽（基准 648vp，按窗口收敛），避免贴底面板横贯整个窗口；窄屏由系统撑满。
    // 窗口宽度未知时不设 width，交给系统默认宽度，避免用猜测值覆盖
    if (this.currentBreakpoint !== 'sm' && this.windowWidthVp > 0) {
      options.width = SheetWidthConstants.resolve(this.windowWidthVp)
    }
    return options
  }

  private async handleSend(): Promise<void> {
    const to: string = this.composeTo.trim()
    const subject: string = this.composeSubject.trim()
    const content: string = this.composeContent.trim()
    if (!to || !subject || !content) {
      return
    }

    this.sending = true
    try {
      const result: MessageSendResult = await sendMessage(appStore.auth.token, to, '', subject, content)
      if (result.ok) {
        appStore.showToast('发送成功')
        this.closeAndReset()
        if (this.onSent) {
          this.onSent()
        }
      } else {
        appStore.showToast(result.error || '发送失败')
      }
    } catch (e) {
      appStore.showToast('发送失败')
    }
    this.sending = false
  }

  /**
   * 半模态面板内容。
   *
   * 两层结构与 `FloatingLayerComponent.ReplyEditorSheet` 同构：外层负责居中、左右留白与底部留白，
   * 内层是 600vp 上限的内容卡片。面板在宽屏被限宽后，内容恒按「上限 600 + 左右各 10」摆放，
   * 不会再跟着窗口拉伸（窄屏下 600 上限不触发）。
   */
  @Builder
  ComposeSheetContent() {
    Column() {
      Column() {
        Divider().width(36).height(4).borderRadius(2).color(AppColors.sheetIndicator).margin({ top: 8, bottom: 12 })
        Row() {
          Text('写私信').fontSize(17).fontWeight(FontWeight.Bold).layoutWeight(1)
          Text('✕').fontSize(20).fontColor(AppColors.textTertiary)
            .onClick(() => { this.showCompose = false })
        }.width('100%').padding({ left: 16, right: 16 })

        TextInput({ text: this.composeTo, placeholder: '收件人（用户名）' })
          .width('92%').height(44).fontSize(15).borderRadius(12)
          .fontColor(UIMaterialManager.inputForeground)
          .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
          .caretColor(UIMaterialManager.inputForeground)
          .margin({ top: 12 })
          .attributeModifier(UIMaterialManager.dialogFieldMaterial)
          .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
          .onChange((value: string) => { this.composeTo = value })

        TextInput({ text: this.composeSubject, placeholder: '主题' })
          .width('92%').height(44).fontSize(15).borderRadius(12)
          .fontColor(UIMaterialManager.inputForeground)
          .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
          .caretColor(UIMaterialManager.inputForeground)
          .margin({ top: 8 })
          .attributeModifier(UIMaterialManager.dialogFieldMaterial)
          .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
          .onChange((value: string) => { this.composeSubject = value })

        TextArea({ text: this.composeContent, placeholder: '内容' })
          .width('92%').height(100).fontSize(15).borderRadius(12)
          .fontColor(UIMaterialManager.inputForeground)
          .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
          .caretColor(UIMaterialManager.inputForeground)
          .margin({ top: 8 })
          .attributeModifier(UIMaterialManager.dialogFieldMaterial)
          .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
          .onChange((value: string) => { this.composeContent = value })

        Button(this.sending ? '发送中...' : '发送')
          .width('92%').height(44).fontSize(16)
          .fontColor(AppColors.white)
          .backgroundColor(AppColors.primary)
          .borderRadius(12).margin({ top: 12, bottom: 20 })
          .enabled(!this.sending && this.composeTo.trim().length > 0 &&
            this.composeSubject.trim().length > 0 && this.composeContent.trim().length > 0)
          .onClick(() => this.handleSend())
      }
      .width('100%')
      .constraintSize({ maxWidth: SheetWidthConstants.CONTENT_MAX_WIDTH })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    // 左右留白与编辑类面板同构（10）：三种断点都是贴底弹出，窄屏面板撑满窗口、宽屏限宽后
    // 内容仍保持 10 的留白，不贴面板边缘。
    // 底部留白 = 最小贴底留白 + 窗口上报的键盘高度：面板关掉了系统避让，输入区靠这段留白
    // 顶到输入法上方（与 `NewTopicDialog` / `ReplyDialog` 同一套做法）。不用 `navBarHeight`：
    // 贴底面板的下边框落在手势条下沿，滑动手势条本身就是系统的关闭手势，无需再避让；
    // 键盘弹起时若还叠一层手势条留白，反而会把内容多顶高一次。
    .padding({
      left: 10,
      right: 10,
      bottom: BOTTOM_GAP + this.keyboardHeightVp
    })
    .backgroundColor(Color.Transparent)
  }

  build() {
    // 零尺寸锚点：只作为官方半模态面板的宿主，不参与布局与命中测试
    Column()
      .width(0).height(0)
      .bindSheet(this.showCompose, this.ComposeSheetContent(), this.composeSheetOptions())
  }
}
