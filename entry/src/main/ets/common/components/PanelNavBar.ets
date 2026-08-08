import { routerStore } from '../../store/RouterStore'
import { AppColors } from '../constants/Constants'
import { KEY_IMMERSIVE_MATERIAL_ENABLED } from '../constants/AppStorageKeys'
import { UIMaterialManager } from '../managers/UIMaterialManager'

/**
 * 面板通用标题栏。
 */
@Component
export struct PanelNavBar {
  /** 标题文本。 */
  @Prop title: string = ''
  /** 系统状态栏高度。 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 沉浸光感开关。 */
  @StorageProp(KEY_IMMERSIVE_MATERIAL_ENABLED) materialEnabled: boolean = true
  /** 自定义返回操作。 */
  onBack?: () => void
  /** 是否显示返回按钮。 */
  @Prop showBack: boolean = true
  /** 右侧文本按钮。 */
  @Prop rightLabel: string = ''
  /** 右侧文本颜色。 */
  @Prop rightLabelColor: ResourceColor = ''
  /** 主右侧图标点击操作。 */
  onRightClick?: () => void
  /** 主右侧图标。 */
  @Prop rightIcon: ResourceStr = ''
  /** 主右侧图标颜色。 */
  @Prop rightIconColor: string = ''
  /** 主右侧图标角标。 */
  @Prop rightIconBadge: number = 0
  /** 主图标右侧的第二个操作图标。 */
  @Prop secondaryRightIcon: ResourceStr = ''
  /** 第二个操作图标颜色。 */
  @Prop secondaryRightIconColor: string = ''
  /** 第二个操作图标角标。 */
  @Prop secondaryRightIconBadge: number = 0
  /** 第二个操作图标点击操作。 */
  onSecondaryRightClick?: () => void

  /**
   * 构建标题栏。
   */
  build() {
    Row() {
      if (this.showBack) {
        Row() {
          Image($r('app.media.icon_back')).width(22).height(22).objectFit(ImageFit.Contain).fillColor(AppColors.primary)
        }
        .padding({ left: 8, right: 8 })
        .onClick(() => { if (this.onBack) { this.onBack() } else { routerStore.back() } })
      } else {
        Blank().width(16)
      }

      Text(this.title).fontSize(17).fontWeight(FontWeight.Bold).layoutWeight(1)
        .fontColor(AppColors.textPrimary)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.rightIcon || this.secondaryRightIcon) {
        Row() {
          if (this.rightIcon) {
            Stack() {
              Image(this.rightIcon).width(18).height(18).fillColor(this.rightIconColor || AppColors.primary)
              if (this.rightIconBadge > 0) {
                Text(this.rightIconBadge > 99 ? '99+' : String(this.rightIconBadge))
                  .fontSize(9).fontColor(Color.White).textAlign(TextAlign.Center)
                  .height(16).borderRadius(8).backgroundColor(Color.Red)
                  .padding({ left: 5, right: 5 })
                  .position({ x: 19, y: 1 })
              }
            }
            .width(36).height(44)
            .onClick(() => { if (this.onRightClick) { this.onRightClick() } })
          }
          if (this.secondaryRightIcon) {
            Stack() {
              Image(this.secondaryRightIcon).width(18).height(18)
                .fillColor(this.secondaryRightIconColor || AppColors.primary)
              if (this.secondaryRightIconBadge > 0) {
                Text(this.secondaryRightIconBadge > 99 ? '99+' : String(this.secondaryRightIconBadge))
                  .fontSize(9).fontColor(Color.White).textAlign(TextAlign.Center)
                  .height(16).borderRadius(8).backgroundColor(Color.Red)
                  .padding({ left: 5, right: 5 })
                  .position({ x: 19, y: 1 })
              }
            }
            .width(36).height(44)
            .onClick(() => {
              if (this.onSecondaryRightClick) {
                this.onSecondaryRightClick()
              }
            })
          }
        }
        .height(44)
        .margin({ right: 8 })
      } else if (this.rightLabel) {
        Text(this.rightLabel).fontSize(14)
          .fontColor(this.rightLabelColor || AppColors.primary)
          .onClick(() => { if (this.onRightClick) { this.onRightClick() } })
          .padding({ left: 8, right: 16 })
      } else {
        Blank().width(70)
      }
    }
    .width('100%').height(44 + this.statusBarHeight)
    .padding({ top: this.statusBarHeight })
    .backgroundColor(this.materialEnabled ? Color.Transparent : AppColors.frostGlassStrong)
    .border({ width: { bottom: 0.5 }, color: AppColors.separator }).alignItems(VerticalAlign.Center)
    .systemMaterial(this.materialEnabled ? UIMaterialManager.titleBarMaterial : undefined)
  }
}
