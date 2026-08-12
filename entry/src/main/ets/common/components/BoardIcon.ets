/**
 * 版块图标组件。
 *
 * NGA 部分版块没有专属图标资源（如“消费踩坑避雷”），网页版以默认图标
 * `ngabbs/nga_classic/f/00.png` 替代；本组件在专属图标加载失败时自动回退显示该默认图标。
 */

import { NGA_IMG4_BASE } from '../constants/NgaDomains'

/** NGA 网页版无专属图标版块的默认图标路径。 */
const BOARD_DEFAULT_ICON_PATH: string = 'ngabbs/nga_classic/f/00.png'

@Component
export struct BoardIcon {
  /** 版块专属图标 URL（加载失败时回退为默认图标）。 */
  @Prop url: string = ''
  /** 图标宽高。 */
  @Prop iconSize: number = 36
  /** 图标圆角半径。 */
  @Prop iconRadius: number = 8
  /** 专属图标是否加载失败。 */
  @State useDefaultIcon: boolean = false

  build() {
    Image(this.currentIconUrl())
      .width(this.iconSize)
      .height(this.iconSize)
      .borderRadius(this.iconRadius)
      .objectFit(ImageFit.Cover)
      .onError(() => {
        this.useDefaultIcon = true
      })
  }

  private currentIconUrl(): string {
    if (this.useDefaultIcon) {
      return `${NGA_IMG4_BASE}/${BOARD_DEFAULT_ICON_PATH}`
    }
    return this.url
  }
}
