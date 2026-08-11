import { AppColors } from '../constants/Constants'
import { unescapeHtml } from '../../parser/_shared/HtmlEntityCodec'
import { decodeAnonymousName } from '../../parser/AnonymousParser'

@Component
export struct AnonymousName {
  @Prop author: string = ''
  @Prop isAnonymous: boolean = false
  @Prop fontSize: number = 14
  @Prop normalColor: ResourceColor = AppColors.textTertiary
  /** 是否处于禁言状态（服务端 mute_time / buffs 105 判定），渲染「禁言中」红色徽章 */
  @Prop isMuted: boolean = false

  build() {
    Row() {
      Text(this.isAnonymous ? decodeAnonymousName(this.author) : unescapeHtml(this.author))
        .fontSize(this.fontSize)
        .fontColor(this.isAnonymous ? AppColors.textTertiary : this.normalColor)
        .fontWeight(FontWeight.Medium)
      if (this.isAnonymous) {
        Text('(匿名)')
          .fontSize(Math.max(10, this.fontSize - 3))
          .fontColor(AppColors.textTertiary)
          .margin({ left: 4 })
      }
      if (this.isMuted) {
        Text('禁言中')
          .fontSize(Math.max(10, this.fontSize - 3))
          .fontColor(AppColors.white)
          .backgroundColor(AppColors.destructive)
          .borderRadius(4)
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .margin({ left: 4 })
      }
    }
  }
}
