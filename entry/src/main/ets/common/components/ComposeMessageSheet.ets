/**
 * 写私信底部面板（共享组件）。
 *
 * 由通知面板私信 Tab 与私信列表面板复用：收件人 / 主题 / 内容 / 发送；
 * 发送成功后通过 onSent 通知父组件刷新会话列表。
 * 支持 composeToInit 直达（如他人主页「发私信」跳转时自动弹出并预填收件人）。
 *
 * 承载方式为官方半模态面板（`bindSheet`）：进出场动效、下拉手势、键盘避让由系统承担；
 * 系统附属元素（拖动条 / 关闭叉）关闭，改用内容自带的指示条与既有交互；
 * 面板**背板**由系统沉浸材质承担（`SheetOptions.systemMaterial`——半模态转场属于 Release 允许
 * 「页面内全部区域」生效的弹窗类接口），内容层只保留半透明内容色
 * （`UIMaterialManager.dialogFieldMaterial`），不再自绘玻璃。
 * 内容层背景必须显式置 `Color.Transparent`：`BindOptions.backgroundColor` 默认是
 * `Color.White`，这层白色会盖住背板材质。
 */

import { appStore } from '../../store/AppStore'
import { sendMessage } from '../../service/api/MessageApi'
import type { MessageSendResult } from '../../model/MessageResult'
import { AppColors, SheetWidthConstants } from '../constants/Constants'
import { UIMaterialManager } from '../managers/UIMaterialManager'

@Component
export struct ComposeMessageSheet {
  /** 弹层是否可见（父组件双向绑定）。 */
  @Link showCompose: boolean
  /** 初始收件人（直达写私信时传入；可后续编辑）。 */
  @Prop composeToInit: string = ''
  /** 发送成功回调（父组件用于刷新会话列表）。 */
  onSent?: () => void
  @StorageProp('navBarHeight') navBarHeight: number = 0
  /** 当前窗口断点：决定半模态样式与面板宽度（与回复 / 发新主题编辑器同一套基准）。 */
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  /** 当前窗口宽度（vp）：面板宽度按窗口收敛的依据（见 `SheetWidthConstants`）。 */
  @StorageProp('windowWidthVp') windowWidthVp: number = 0
  @State composeTo: string = ''
  @State composeSubject: string = ''
  @State composeContent: string = ''
  @State sending: boolean = false

  aboutToAppear(): void {
    if (this.composeToInit.length > 0) {
      this.composeTo = this.composeToInit
    }
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
   * 形态与宽度基准对齐回复 / 发新主题编辑器（`FloatingLayerComponent.editorSheetOptions`）：
   * **所有断点统一走 `SheetType.BOTTOM` 贴底样式**（宽屏只限宽，不切居中浮层）。居中形态曾用于
   * md / lg，但它与应用自做的键盘避让互斥——会把面板撑高、在工具行下方留出长空白，并让面板
   * 底边越出可视区、平掉底部圆角（详见 `FloatingLayerComponent.editorSheetOptions` 的说明）。
   * 宽屏限宽仍是必要的：否则贴底面板会横贯整个窗口，内容里按百分比布局的输入框
   * （`width('92%')`）会跟着一起拉长。
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
   * 两层结构与 `FloatingLayerComponent.ReplyEditorSheet` 同构：外层负责居中、左右留白
   * （`sm` 10vp / 其余 24vp）与底部留白，内层是 600vp 上限的内容卡片。
   * 面板在 md/lg 被限宽后，内容恒按「上限 600 + 左右各 24」摆放，不会再跟着窗口拉伸
   * （`sm` 走贴底样式，窄屏下 600 上限不触发）。
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
    // 左右留白与编辑类面板同构（10）：三种断点都是贴底样式，窄屏面板撑满窗口、宽屏限宽后
    // 内容仍保持 10 的留白，不贴面板边缘。底部留白避让手势条（贴底样式下 `navBarHeight` 即
    // 屏幕底部安全区，无手势条的设备为 0，需保留最小贴底留白）
    .padding({
      left: 10,
      right: 10,
      bottom: this.navBarHeight > 0 ? this.navBarHeight : 8
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
