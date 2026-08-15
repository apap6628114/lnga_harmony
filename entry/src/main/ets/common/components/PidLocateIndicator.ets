/**
 * 全局楼层定位进度指示组件，需要在页面根部挂载（与 TtsProgressIndicator 并列）。
 *
 * 通过轮询 pidLocateProgress 状态驱动显示，与 TtsProgressIndicator 保持一致的
 * 驱动方式。仅展示信息、不拦截任何点击，避免影响列表滚动与楼层交互。
 * 定位指示器显示在 TTS 进度条上方，避免两者同时出现时重叠。
 */

import { AppColors, TTS_PROGRESS_BOTTOM_MARGIN } from '../constants/Constants'
import { pidLocateProgress } from '../media/PidLocateProgress'

/** 轮询间隔（毫秒）。 */
const PROGRESS_POLL_INTERVAL_MS: number = 150

/** 与 TTS 进度指示器的纵向间距（px）。 */
const TTS_INDICATOR_OFFSET: number = 48

@Component
export struct PidLocateIndicator {
  @State visible: boolean = false
  @State step: number = 0
  @State total: number = 0
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
      this.pollProgress()
      this.schedulePoll()
    }, PROGRESS_POLL_INTERVAL_MS)
  }

  private pollProgress(): void {
    const state = pidLocateProgress.state
    if (state.visible !== this.visible) {
      this.visible = state.visible
    }
    if (state.step !== this.step) {
      this.step = state.step
    }
    if (state.total !== this.total) {
      this.total = state.total
    }
  }

  build() {
    if (this.visible) {
      Stack() {
        Row({ space: 8 }) {
          LoadingProgress().width(14).height(14).color(AppColors.primary)
          Text(this.total > 1
            ? `正在定位楼层… ${this.step}/${this.total}`
            : '正在定位楼层…')
            .fontSize(13)
            .fontColor(AppColors.white)
            .maxLines(1)
        }
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .borderRadius(20)
        .backgroundColor(AppColors.toastBg)
      }
      .width('100%')
      .height('100%')
      .alignContent(Alignment.Bottom)
      .margin({ bottom: TTS_PROGRESS_BOTTOM_MARGIN + this.navBarHeight + TTS_INDICATOR_OFFSET })
      .hitTestBehavior(HitTestMode.Transparent)
    }
  }
}
