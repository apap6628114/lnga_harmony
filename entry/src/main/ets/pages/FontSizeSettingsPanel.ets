import { appStore } from '../store/AppStore'
import { AppColors } from '../common/constants/Constants'
import { PanelNavBar } from '../common/components/PanelNavBar'

@Component
export struct FontSizeSettingsPanel {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @State currentContentFontSize: number = appStore.settings.fontSize
  @State currentTopicFontSize: number = appStore.settings.topicFontSize

  build() {
    Stack() {
      Column() {
        Row().width('100%').height(44 + this.statusBarHeight)

        Scroll() {
          Column() {
            // ---- 字体大小 ----
            Column() {
              Text('帖子内容').fontSize(15).fontColor(AppColors.textSecondary)
                .width('100%').padding({ bottom: 10 })

              Row() {
                Text('Aa').fontSize(13).fontColor(AppColors.textSecondary).width(40)
                Slider({
                  value: this.currentContentFontSize,
                  min: 12,
                  max: 24,
                  step: 1,
                  style: SliderStyle.InSet
                })
                  .onChange((v: number, mode: SliderChangeMode) => {
                    this.currentContentFontSize = v
                    appStore.settingsStore.setFontSize(v)
                  })
                  .layoutWeight(1)
                  .height(40)
                Text(`${this.currentContentFontSize}`).fontSize(14)
                  .fontColor(AppColors.textSecondary).width(40).textAlign(TextAlign.End)
              }
              .width('100%').height(48).padding({ left: 16, right: 16 }).alignItems(VerticalAlign.Center)
            }
            .width('92%')
            .backgroundColor(AppColors.bgTertiary)
            .borderRadius(12)
            .padding(12)
            .margin({ top: 16 })

            // ---- 帖子列表字体 ----
            Column() {
              Text('帖子列表').fontSize(15).fontColor(AppColors.textSecondary)
                .width('100%').padding({ bottom: 10 })

              Row() {
                Text('Aa').fontSize(13).fontColor(AppColors.textSecondary).width(40)
                Slider({
                  value: this.currentTopicFontSize,
                  min: 12,
                  max: 24,
                  step: 1,
                  style: SliderStyle.InSet
                })
                  .onChange((v: number, mode: SliderChangeMode) => {
                    this.currentTopicFontSize = v
                    appStore.settingsStore.setTopicFontSize(v)
                  })
                  .layoutWeight(1)
                  .height(40)
                Text(`${this.currentTopicFontSize}`).fontSize(14)
                  .fontColor(AppColors.textSecondary).width(40).textAlign(TextAlign.End)
              }
              .width('100%').height(48).padding({ left: 16, right: 16 }).alignItems(VerticalAlign.Center)
            }
            .width('92%')
            .backgroundColor(AppColors.bgTertiary)
            .borderRadius(12)
            .padding(12)
            .margin({ top: 12 })
          }
          .width('100%').alignItems(HorizontalAlign.Center).padding({ bottom: 32 })
        }
        .layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
      }
      .width('100%').height('100%').backgroundColor(AppColors.bg)

      PanelNavBar({ title: '字体大小' })
        .width('100%').position({ x: 0, y: 0 })
    }
    .width('100%').height('100%')
  }
}
