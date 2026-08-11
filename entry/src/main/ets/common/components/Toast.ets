/**
 * Toast 提示组件
 * 通过 AppStorage 驱动显示
 */

import { appStore } from '../../store/AppStore'
import { AppColors, TOAST_BOTTOM_MARGIN } from '../constants/Constants'

@CustomDialog
export struct ToastOverlay {
  controller: CustomDialogController
  @State message: string = ''

  build() {
    Text(this.message)
      .fontSize(14)
      .fontColor(AppColors.white)
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .borderRadius(20)
      .backgroundColor(AppColors.toastBg)
  }
}

/**
 * 全局 Toast 组件，需要在页面根部挂载
 */
@Component
export struct ToastComponent {
  @State message: string = ''
  @State visible: boolean = false
  @StorageProp('navBarHeight') navBarHeight: number = 0
  private pollTimer: number = -1

  aboutToAppear(): void {
    this.schedulePoll()
  }

  aboutToDisappear(): void {
    clearTimeout(this.pollTimer)
  }

  private schedulePoll(): void {
    this.pollTimer = setTimeout(() => {
      this.pollToast()
      this.schedulePoll()
    }, 150)
  }

  private pollToast(): void {
    if (appStore.toast.visible && appStore.toast.message !== this.message) {
      this.message = appStore.toast.message
      this.visible = true
    } else if (!appStore.toast.visible && this.visible) {
      this.visible = false
      this.message = ''
    }
  }

  build() {
    if (this.visible) {
      Stack() {
        Text(this.message)
          .fontSize(14)
          .fontColor(AppColors.white)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(20)
          .backgroundColor(AppColors.toastBg)
      }
      .width('100%')
      .height('100%')
      .alignContent(Alignment.Bottom)
      .margin({ bottom: TOAST_BOTTOM_MARGIN + this.navBarHeight })
      .hitTestBehavior(HitTestMode.Transparent)
    }
  }
}
