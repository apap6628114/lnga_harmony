import { routerStore } from '../../store/RouterStore'
import { AppColors, NAV_BAR_H, TITLE_BLUR_FADE_DISTANCE } from '../constants/Constants'
import { KEY_IMMERSIVE_MATERIAL_ENABLED } from '../constants/AppStorageKeys'
import { UIMaterialManager } from '../managers/UIMaterialManager'

/**
 * 面板通用标题栏。
 *
 * 标题栏本体不使用整块系统材质，沉浸光感材质只作用于返回、菜单等操作按钮。
 * 列表滚动进入标题区时，正文自身承担空间渐变模糊，标题层只叠加向下衰减的
 * 主题同色偏色，避免均匀毛玻璃与分割线形成明显区域边界。
 *
 * 说明：渐变偏色属于纯视觉层，不占用布局索引、不参与内容区定位；
 * 页面使用方通过 scrollEffectProgress 传递滚动进度，默认 0 保持原有视觉。
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
  /** 标题栏滚动效果进度，取值范围为 0 到 1。 */
  @Prop scrollEffectProgress: number = 0

  /**
   * 标题栏内可操作图标按钮：圆形光感底板 + 按压形变反馈。
   */
  @Builder
  iconPod(icon: ResourceStr, color: ResourceColor, badge: number, onTap: () => void) {
    Stack() {
      Image(icon).width(18).height(18).objectFit(ImageFit.Contain).fillColor(color)
      if (badge > 0) {
        Text(badge > 99 ? '99+' : String(badge))
          .fontSize(9).fontColor(Color.White).textAlign(TextAlign.Center)
          .height(16).borderRadius(8).backgroundColor(Color.Red)
          .padding({ left: 5, right: 5 })
          .position({ x: 19, y: 0 })
      }
    }
    .width(36).height(36).borderRadius(18)
    .alignContent(Alignment.Center)
    .backgroundColor(this.materialEnabled ? Color.Transparent : AppColors.frostGlass)
    .systemMaterial(this.materialEnabled ? UIMaterialManager.fabMaterial : undefined)
    .onClick(onTap)
  }

  /**
   * 构建标题栏。
   */
  build() {
    Stack() {
      if (this.materialEnabled && this.scrollEffectProgress > 0) {
        Column()
          .width('100%')
          .height(this.statusBarHeight + NAV_BAR_H + TITLE_BLUR_FADE_DISTANCE)
          .linearGradient({
            angle: 180,
            colors: [
              [$r('app.color.title_backdrop_tint'), 0],
              [
                $r('app.color.title_backdrop_tint'),
                (this.statusBarHeight + NAV_BAR_H) /
                  (this.statusBarHeight + NAV_BAR_H + TITLE_BLUR_FADE_DISTANCE)
              ],
              [$r('app.color.title_backdrop_clear'), 1]
            ]
          })
          .opacity(Math.max(0, Math.min(this.scrollEffectProgress, 1)))
          .hitTestBehavior(HitTestMode.None)
      }

      Row() {
        if (this.showBack) {
          Row() {
            this.iconPod($r('app.media.icon_back'), AppColors.primary, 0, () => {
              if (this.onBack) { this.onBack() } else { routerStore.back() }
            })
          }
          .width(54).height(44).justifyContent(FlexAlign.Center)
          .margin({ left: 8, right: 10 })
        } else {
          Blank().width(16)
        }

        Text(this.title).fontSize(17).fontWeight(FontWeight.Bold).layoutWeight(1)
          .fontColor(AppColors.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.rightIcon || this.secondaryRightIcon) {
          Row() {
            if (this.rightIcon) {
              this.iconPod(this.rightIcon, this.rightIconColor || AppColors.primary,
                this.rightIconBadge, () => { if (this.onRightClick) { this.onRightClick() } })
            }
            if (this.secondaryRightIcon) {
              this.iconPod(this.secondaryRightIcon, this.secondaryRightIconColor || AppColors.primary,
                this.secondaryRightIconBadge, () => {
                  if (this.onSecondaryRightClick) { this.onSecondaryRightClick() }
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
      .width('100%').height(NAV_BAR_H + this.statusBarHeight)
      .padding({ top: this.statusBarHeight })
      .backgroundColor(this.materialEnabled ? Color.Transparent : AppColors.frostGlassStrong)
      .border(this.materialEnabled ? undefined : { width: { bottom: 0.5 }, color: '#33FFFFFF' })
      .alignItems(VerticalAlign.Center)

    }
    .width('100%').height(NAV_BAR_H + this.statusBarHeight)
    .clip(false)
  }
}
