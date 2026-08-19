/**
 * 全局保存帖子进度指示组件，需要在页面根部挂载。
 *
 * 通过轮询 savedThreadProgress 状态驱动显示，与 TtsProgressIndicator 保持
 * 一致的驱动方式。展示保存进度并提供一个「取消」入口（保存可能耗时很长，
 * 用户可随时终止）。
 *
 * 布局与 TtsProgressIndicator 相同：全屏定位层 alignContent(Bottom) 将胶囊
 * 沉到屏幕底部同一高度；定位层保持 Transparent，空白区域点击穿透不拦截帖子
 * 交互；「取消」以 HitTestMode.Block 独占拦截自身点击（自身仍响应命中测试，
 * 阻止祖先链命中），避免误触下层列表。
 */

import { AppColors, TTS_PROGRESS_BOTTOM_MARGIN } from '../constants/Constants'
import { savedThreadProgress } from '../media/SavedThreadProgress'
import { savedThreadService } from '../../service/SavedThreadService'

/** 轮询间隔（毫秒）。 */
const PROGRESS_POLL_INTERVAL_MS: number = 150

@Component
export struct SavedThreadProgressIndicator {
  @State percent: number = -1
  @State visible: boolean = false
  @State label: string = ''
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
    const state = savedThreadProgress.state
    if (state.visible !== this.visible) {
      this.visible = state.visible
    }
    if (state.percent !== this.percent) {
      this.percent = state.percent
    }
    if (state.label !== this.label) {
      this.label = state.label
    }
  }

  build() {
    if (this.visible) {
      // 全屏定位层：胶囊经 alignContent(Bottom) 沉底，与 TtsProgressIndicator 同位置；
      // 定位层保持 Transparent——空白区域点击穿透到下层，不拦截帖子交互。
      Stack() {
        Row({ space: 8 }) {
          Progress({
            value: this.percent >= 0 ? this.percent : 0,
            total: 100,
            type: ProgressType.Linear
          })
            .width(80)
            .height(4)
            .color(AppColors.primary)
            .backgroundColor('#33FFFFFF')
            .borderRadius(2)
          Text('正在保存帖子')
            .fontSize(13)
            .fontColor(AppColors.white)
            .maxLines(1)
          if (this.label.length > 0) {
            Text(this.label)
              .fontSize(13)
              .fontColor(AppColors.primaryLight)
              .maxLines(1)
          }
          Text(this.percent.toString() + '%')
            .fontSize(13)
            .fontColor(AppColors.primaryLight)
            .maxLines(1)
          Text('取消')
            .fontSize(13)
            .fontColor(AppColors.destructive)
            .fontWeight(FontWeight.Medium)
            .padding({ left: 8, right: 2, top: 6, bottom: 6 })
            .onClick(() => {
              savedThreadService.cancel()
            })
            // Block：自身仍响应命中测试（onClick 可触发）且独占拦截——
            // 阻止祖先链命中，点击不穿透到下层列表（防误触）。
            .hitTestBehavior(HitTestMode.Block)
        }
        .padding({ left: 14, right: 10, top: 8, bottom: 8 })
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
