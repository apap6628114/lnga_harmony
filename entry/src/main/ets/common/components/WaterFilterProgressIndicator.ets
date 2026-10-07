/**
 * 全局「智能去水」进度指示组件，需要在页面根部（`MainPage`）挂载。
 *
 * 去水任务可能跑几十分钟（上千页的帖子），必须给出可离开页面的进度与取消入口，
 * 因此与 `SavedThreadProgressIndicator` 同样采用「发布器 + 轮询」的解耦方式：
 * 组件只读 `waterFilterProgress.state`，不依赖任何页面存活。
 *
 * 位置比保存进度胶囊再高一档（`WATER_FILTER_PROGRESS_BOTTOM_MARGIN`）：两者是独立任务，
 * 可能同时进行，各自成行才不会叠在一起。
 *
 * 布局与 `SavedThreadProgressIndicator` 一致：全屏定位层 `alignContent(Bottom)`
 * 把胶囊沉到屏幕底部；定位层保持 `Transparent`，空白区域点击穿透不拦截内容交互；
 * 「取消」以 `HitTestMode.Block` 独占拦截自身点击，避免误触下层列表。
 */

import { AppColors, WATER_FILTER_PROGRESS_BOTTOM_MARGIN } from '../constants/Constants'
import { waterFilterProgress, WaterFilterPhase } from '../media/WaterFilterProgress'
import { threadWaterFilterService } from '../../service/ThreadWaterFilterService'

/** 轮询间隔（毫秒）。 */
const PROGRESS_POLL_INTERVAL_MS: number = 150

@Component
export struct WaterFilterProgressIndicator {
  @State percent: number = -1
  @State visible: boolean = false
  @State label: string = ''
  @State hint: string = ''
  @State phase: string = WaterFilterPhase.FETCHING
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
    const state = waterFilterProgress.state
    if (state.visible !== this.visible) {
      this.visible = state.visible
    }
    if (state.percent !== this.percent) {
      this.percent = state.percent
    }
    if (state.label !== this.label) {
      this.label = state.label
    }
    if (state.hint !== this.hint) {
      this.hint = state.hint
    }
    if (state.phase !== this.phase) {
      this.phase = state.phase
    }
  }

  private title(): string {
    return this.phase === WaterFilterPhase.PACKING ? '正在生成去水版' : '正在智能去水'
  }

  build() {
    if (this.visible) {
      Stack() {
        Column({ space: 2 }) {
          Row({ space: 8 }) {
            Progress({
              value: this.percent >= 0 ? this.percent : 0,
              total: 100,
              type: ProgressType.Linear
            })
              .width(72)
              .height(4)
              .color(AppColors.primary)
              .backgroundColor('#33FFFFFF')
              .borderRadius(2)
            Text(this.title())
              .fontSize(13)
              .fontColor(AppColors.white)
              .maxLines(1)
            if (this.label.length > 0) {
              Text(this.label)
                .fontSize(13)
                .fontColor(AppColors.toastAccent)
                .maxLines(1)
                .layoutWeight(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            Text('取消')
              .fontSize(13)
              .fontColor(AppColors.destructive)
              .fontWeight(FontWeight.Medium)
              .padding({ left: 8, right: 2, top: 6, bottom: 6 })
              .onClick(() => {
                threadWaterFilterService.cancel()
              })
              // Block：自身仍响应命中测试（onClick 可触发）且独占拦截——
              // 阻止祖先链命中，点击不穿透到下层列表（防误触）
              .hitTestBehavior(HitTestMode.Block)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (this.hint.length > 0) {
            Text(this.hint)
              .fontSize(11)
              .fontColor(AppColors.toastAccent)
              .opacity(0.8)
              .maxLines(1)
              .width('100%')
              .textAlign(TextAlign.Start)
          }
        }
        .constraintSize({ maxWidth: '92%' })
        .padding({ left: 14, right: 10, top: 8, bottom: 8 })
        .borderRadius(20)
        .backgroundColor(AppColors.toastBg)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .alignContent(Alignment.Bottom)
      .margin({ bottom: WATER_FILTER_PROGRESS_BOTTOM_MARGIN + this.navBarHeight })
      .hitTestBehavior(HitTestMode.Transparent)
    }
  }
}
