/**
 * 全局 TTS 合成进度指示组件，需要在页面根部挂载。
 *
 * 通过轮询 ttsProgress 状态驱动显示，与 ToastComponent 保持一致的驱动方式。
 * 仅展示信息、不拦截任何点击，避免影响列表滚动与楼层交互。
 */

import { AppColors, TTS_PROGRESS_BOTTOM_MARGIN } from '../constants/Constants'
import { ttsProgress } from '../media/TtsProgress'

/** 轮询间隔（毫秒）。 */
const PROGRESS_POLL_INTERVAL_MS: number = 150

@Component
export struct TtsProgressIndicator {
  @State percent: number = -1
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
      this.pollProgress()
      this.schedulePoll()
    }, PROGRESS_POLL_INTERVAL_MS)
  }

  private pollProgress(): void {
    const state = ttsProgress.state
    if (state.visible !== this.visible) {
      this.visible = state.visible
    }
    if (state.percent !== this.percent) {
      this.percent = state.percent
    }
  }

  build() {
    if (this.visible) {
      Stack() {
        Row({ space: 8 }) {
          Progress({
            value: this.percent >= 0 ? this.percent : 0,
            total: 100,
            type: ProgressType.Linear
          })
            .width(100)
            .height(4)
            .color(AppColors.primary)
            .backgroundColor('#33FFFFFF')
            .borderRadius(2)
          Text('正在合成语音')
            .fontSize(13)
            .fontColor(AppColors.white)
            .maxLines(1)
          Text(this.percent.toString() + '%')
            .fontSize(13)
            .fontColor(AppColors.primaryLight)
            .maxLines(1)
        }
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .borderRadius(20)
        .backgroundColor(AppColors.toastBg)
      }
      .width('100%')
      .height('100%')
      .alignContent(Alignment.Bottom)
      .margin({ bottom: TTS_PROGRESS_BOTTOM_MARGIN + this.navBarHeight })
      .hitTestBehavior(HitTestMode.Transparent)
    }
  }
}
