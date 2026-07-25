import { appStore } from '../store/AppStore'
import { AppColors } from '../common/constants/Constants'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { Avatar } from '../common/components/Avatar'
import { AnonymousName } from '../common/components/AnonymousName'

/**
 * 字体大小设置面板。
 */
@Component
export struct FontSizeSettingsPanel {
  /** 状态栏高度。 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 当前帖子内容字号。 */
  @State currentContentFontSize: number = appStore.settings.fontSize
  /** 当前帖子列表字号。 */
  @State currentTopicFontSize: number = appStore.settings.topicFontSize

  /**
   * 构建字体大小设置界面。
   */
  build() {
    Stack() {
      Column() {
        Row().width('100%').height(44 + this.statusBarHeight)

        Scroll() {
          Column() {
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

              Divider().margin({ left: 16, right: 16 }).color(AppColors.separator)

              this.ContentFontPreview()
            }
            .width('92%')
            .backgroundColor(AppColors.bgTertiary)
            .borderRadius(12)
            .padding(12)
            .margin({ top: 16 })

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

              Divider().margin({ left: 16, right: 16 }).color(AppColors.separator)

              this.TopicFontPreview()
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

  /**
   * 构建贴近真实楼层卡片的帖子正文字号预览。
   */
  @Builder
  ContentFontPreview() {
    Column() {
      Text('实时预览').fontSize(12).fontColor(AppColors.textTertiary).width('100%')

      Column() {
        Row() {
          Row() {
            Avatar({ avatar: '', uid: '', name: '示例用户', avatarSize: 32 })

            Column() {
              Row() {
                AnonymousName({
                  author: '示例用户',
                  isAnonymous: false,
                  fontSize: 14,
                  normalColor: AppColors.primary
                })
                Text('楼主')
                  .fontSize(11)
                  .fontColor(AppColors.primary)
                  .fontWeight(FontWeight.Medium)
                  .margin({ left: 4 })
              }
              Row() {
                Text('晴风村民').fontSize(11).fontColor(AppColors.textTertiary)
                Text('刚刚').fontSize(11).fontColor(AppColors.textTertiary).margin({ left: 6 })
              }
            }
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 8 })
            .layoutWeight(1)
          }
          .layoutWeight(1)

          Text('楼主').fontSize(13).fontColor(AppColors.textTertiary)
        }
        .width('100%')

        Text('2026-07-26 12:00').fontSize(11).fontColor(AppColors.textTertiary).margin({ top: 12 })

        Text() {
          Span('这是一段帖子正文，用于观察当前字号下的阅读效果。')
          Span('链接文字')
            .fontColor(AppColors.primary)
            .decoration({ type: TextDecorationType.Underline, color: AppColors.primary })
          Span('和普通文字会保持真实帖子的排版比例。')
        }
        .fontSize(this.currentContentFontSize)
        .fontColor(AppColors.textPrimary)
        .lineHeight(26)
        .width('100%')
        .margin({ top: 12 })

        Row() {
          Row() {
            Image($r('app.media.icon_thumb_up')).width(16).height(16).fillColor(AppColors.textTertiary)
            Text('12').fontSize(13).fontColor(AppColors.textSecondary).margin({ left: 3 })
          }
          .padding({ left: 6, right: 6, top: 4, bottom: 4 })

          Row() {
            Image($r('app.media.icon_thumb_down')).width(16).height(16).fillColor(AppColors.textTertiary)
          }
          .padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .margin({ left: 6 })

          Row() {
            Image($r('app.media.icon_reply')).width(16).height(16).fillColor(AppColors.textTertiary)
          }
          .padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .margin({ left: 6 })
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(AppColors.bg)
      .borderRadius(8)
      .border({ width: 0.5, color: AppColors.separator })
      .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 8 })
  }

  /**
   * 构建贴近真实主题卡片的帖子列表字号预览。
   */
  @Builder
  TopicFontPreview() {
    Column() {
      Text('实时预览').fontSize(12).fontColor(AppColors.textTertiary).width('100%')

      Column() {
        Row() {
          Text('[讨论]').fontSize(this.currentTopicFontSize).fontColor(AppColors.textTertiary)
          Text('调整字体大小后，帖子列表会呈现这样的阅读效果')
            .fontSize(this.currentTopicFontSize)
            .fontColor(AppColors.textPrimary)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        Text('这是主题内容摘要，可以用来判断较长文本在当前字号下的行数与阅读密度。')
          .fontSize(this.currentTopicFontSize - 2)
          .fontColor(AppColors.textSecondary)
          .maxLines(2)
          .lineHeight(19)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 10 })
          .width('100%')

        Row() {
          Row() {
            AnonymousName({ author: '示例用户', isAnonymous: false, fontSize: 12 })
            Text(' · 刚刚 · 艾泽拉斯国家地理')
              .fontSize(12)
              .fontColor(AppColors.textTertiary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)

          Row() {
            Image($r('app.media.icon_chat_bubble')).width(12).height(12).fillColor(AppColors.textTertiary)
            Text(' 24').fontSize(12).fontColor(AppColors.textTertiary)
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .margin({ top: 12 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(AppColors.bg)
      .borderRadius(8)
      .border({ width: 0.5, color: AppColors.separator })
      .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 8 })
  }
}
