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
  @State actionText: string = ''
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
    if (appStore.toast.visible &&
      (appStore.toast.message !== this.message || appStore.toast.actionText !== this.actionText)) {
      this.message = appStore.toast.message
      this.actionText = appStore.toast.actionText
      this.visible = true
    } else if (!appStore.toast.visible && this.visible) {
      this.visible = false
      this.message = ''
      this.actionText = ''
    }
  }

  /**
   * 触发动作按钮回调并立即隐藏 Toast。
   *
   * 先取出回调并隐藏，再执行回调，防止回调内再次弹出 Toast 时被清空状态干扰；
   * 回调闭包只允许捕获值（如 pid），不得依赖已销毁的页面组件实例。
   */
  private triggerAction(): void {
    const action: (() => void) | null = appStore.toast.onAction
    appStore.toastManager.hideAction()
    if (action !== null) {
      action()
    }
  }

  build() {
    if (this.visible) {
      Stack() {
        Row() {
          Text(this.message)
            .fontSize(14)
            .fontColor(AppColors.white)
          if (this.actionText.length > 0) {
            Text(this.actionText)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColors.primary)
              .margin({ left: 12 })
          }
        }
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .borderRadius(20)
        .backgroundColor(AppColors.toastBg)
        .onClick((): void => {
          // 点击热区挂在 Row 自身：Block 会阻止子节点接收点击，
          // 若挂在内部 Text 上按钮将永远无法触发
          if (this.actionText.length > 0) {
            this.triggerAction()
          }
        })
        // 有动作按钮时 Block：整条 Toast 可点且独占拦截，事件不穿透到下层列表（防误触）；
        // 纯文本时 Transparent：保持穿透，不拦截帖子交互
        .hitTestBehavior(this.actionText.length > 0 ? HitTestMode.Block : HitTestMode.Transparent)
      }
      .width('100%')
      .height('100%')
      .alignContent(Alignment.Bottom)
      .margin({ bottom: TOAST_BOTTOM_MARGIN + this.navBarHeight })
      // 全屏定位层保持 Transparent：空白区域点击穿透到下层，不拦截帖子交互
      .hitTestBehavior(HitTestMode.Transparent)
    }
  }
}
