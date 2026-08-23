/**
 * 写私信底部面板（共享组件）。
 *
 * 由通知面板私信 Tab 与私信列表面板复用：系统材质底部 sheet，
 * 收件人 / 主题 / 内容 / 发送；发送成功后通过 onSent 通知父组件刷新会话列表。
 * 支持 composeToInit 直达（如他人主页「发私信」跳转时自动弹出并预填收件人）。
 */

import { appStore } from '../../store/AppStore'
import { sendMessage } from '../../service/api/MessageApi'
import type { MessageSendResult } from '../../model/MessageResult'
import { AppColors } from '../constants/Constants'
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

  build() {
    if (this.showCompose) {
      Column() {
      }
      .width('100%').height('100%')
      .position({ x: 0, y: 0 })
      .backgroundColor(AppColors.overlay)
      .onClick(() => { this.showCompose = false })

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
          .backgroundColor(Color.Transparent).margin({ top: 12 })
          .systemMaterial(UIMaterialManager.inputMaterial)
          .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
          .onChange((value: string) => { this.composeTo = value })

        TextInput({ text: this.composeSubject, placeholder: '主题' })
          .width('92%').height(44).fontSize(15).borderRadius(12)
          .fontColor(UIMaterialManager.inputForeground)
          .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
          .caretColor(UIMaterialManager.inputForeground)
          .backgroundColor(Color.Transparent).margin({ top: 8 })
          .systemMaterial(UIMaterialManager.inputMaterial)
          .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
          .onChange((value: string) => { this.composeSubject = value })

        TextArea({ text: this.composeContent, placeholder: '内容' })
          .width('92%').height(100).fontSize(15).borderRadius(12)
          .fontColor(UIMaterialManager.inputForeground)
          .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
          .caretColor(UIMaterialManager.inputForeground)
          .backgroundColor(Color.Transparent).margin({ top: 8 })
          .systemMaterial(UIMaterialManager.inputMaterial)
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
      .width('100%').backgroundColor(Color.Transparent)
      .borderRadius(14).alignItems(HorizontalAlign.Center)
      .padding({ bottom: this.navBarHeight })
      .systemMaterial(UIMaterialManager.surfaceMaterial)
      .position({ x: 0, y: '40%' })
    }
  }
}
