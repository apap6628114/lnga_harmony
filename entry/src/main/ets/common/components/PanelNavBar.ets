import { routerStore } from '../../store/RouterStore'
import {
  AppColors,
  NAV_BAR_H,
  TITLE_ACTION_BUTTON_GAP,
  TITLE_BLUR_FADE_DISTANCE
} from '../constants/Constants'
import { UIMaterialManager } from '../managers/UIMaterialManager'
import { TitleScrollEffect } from '../utils/TitleScrollEffect'

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
  /** 自定义返回操作。 */
  onBack?: () => void
  /** 是否显示返回按钮。 */
  @Prop showBack: boolean = true
  /** 主右侧图标点击操作。 */
  onRightClick?: () => void
  /** 主右侧图标。 */
  @Prop rightIcon: ResourceStr = ''
  /** 主右侧图标颜色。 */
  @Prop rightIconColor: ResourceColor = ''
  /** 主右侧图标的无障碍名称。 */
  @Prop rightIconAccessibilityText: string = ''
  /** 主右侧图标角标。 */
  @Prop rightIconBadge: number = 0
  /** 主图标右侧的第二个操作图标。 */
  @Prop secondaryRightIcon: ResourceStr = ''
  /** 第二个操作图标颜色。 */
  @Prop secondaryRightIconColor: ResourceColor = ''
  /** 第二个操作图标的无障碍名称。 */
  @Prop secondaryRightIconAccessibilityText: string = ''
  /** 第二个操作图标角标。 */
  @Prop secondaryRightIconBadge: number = 0
  /** 第二个操作图标点击操作。 */
  onSecondaryRightClick?: () => void
  /** 标题栏滚动效果进度，取值范围为 0 到 1。 */
  @Prop scrollEffectProgress: number = 0

  /**
   * 标题栏内可操作图标按钮：圆形光感底板 + 按压形变反馈。
   *
   * 图标与颜色、角标一样通过 this 读取状态变量，而不是按值传入：
   * @Builder 私有构建函数按值传递时，参数（状态变量）变化不会触发 UI 刷新，
   * 图标会固化为首次渲染值（切换 Tab 导致 rightIcon 变化时不更新）。
   * 通过 this 访问才建立响应式依赖（rightIcon / rightIconColor /
   * rightIconBadge 变化即刷新）。
   *
   * @param isBack - 是否为返回按钮（固定图标、无角标）
   * @param isSecondary - 是否为第二个操作图标
   * @param accessibilityText - 无障碍名称
   * @param onTap - 点击回调
   */
  @Builder
  iconPod(
    isBack: boolean,
    isSecondary: boolean,
    accessibilityText: string,
    onTap: () => void
  ) {
    Stack() {
      Image(this.resolveIcon(isBack, isSecondary)).width(18).height(18).objectFit(ImageFit.Contain)
        .fillColor(this.resolveIconColor(isBack, isSecondary))
      if (!isBack && this.resolveBadgeCount(isSecondary) > 0) {
        Text(this.formatBadgeCount(this.resolveBadgeCount(isSecondary)))
          .fontSize(9).fontColor(Color.White).textAlign(TextAlign.Center)
          .height(16).borderRadius(8).backgroundColor(Color.Red)
          .padding({ left: 5, right: 5 })
          .position({ x: 19, y: 0 })
      }
    }
    .width(36).height(36).borderRadius(18)
    .alignContent(Alignment.Center)
    .backgroundColor(Color.Transparent)
    .systemMaterial(UIMaterialManager.fabMaterial)
    .accessibilityText(accessibilityText)
    .onClick(onTap)
  }

  /**
   * 取图标资源：返回按钮固定返回图标，主/次操作图标取各自 @Prop。
   *
   * @param isBack - 是否为返回按钮
   * @param isSecondary - 是否为第二个操作图标
   * @returns 图标资源
   */
  private resolveIcon(isBack: boolean, isSecondary: boolean): ResourceStr {
    if (isBack) {
      return $r('app.media.icon_back')
    }
    return isSecondary ? this.secondaryRightIcon : this.rightIcon
  }

  /**
   * 取图标颜色：返回按钮固定前景色，主/次图标取各自角标色（未设置时兜底前景色）。
   *
   * @param isBack - 是否为返回按钮
   * @param isSecondary - 是否为第二个操作图标
   * @returns 图标颜色
   */
  private resolveIconColor(isBack: boolean, isSecondary: boolean): ResourceColor {
    if (isBack) {
      return UIMaterialManager.adaptiveForeground
    }
    return isSecondary
      ? (this.secondaryRightIconColor || UIMaterialManager.adaptiveForeground)
      : (this.rightIconColor || UIMaterialManager.adaptiveForeground)
  }

  /**
   * 取主/次操作图标的角标数。
   *
   * @param isSecondary - 是否为第二个操作图标
   * @returns 角标数
   */
  private resolveBadgeCount(isSecondary: boolean): number {
    return isSecondary ? this.secondaryRightIconBadge : this.rightIconBadge
  }

  /**
   * 将角标数格式化为显示文本（超过 99 显示 99+）。
   *
   * @param count - 角标数
   * @returns 角标文本
   */
  private formatBadgeCount(count: number): string {
    return count > 99 ? '99+' : String(count)
  }

  /**
   * 构建标题栏。
   */
  build() {
    Stack() {
      if (this.scrollEffectProgress > 0) {
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
          .opacity(TitleScrollEffect.getBackdropOpacity(this.scrollEffectProgress))
          .hitTestBehavior(HitTestMode.None)
      }

      Row() {
        if (this.showBack) {
          Row() {
            this.iconPod(true, false, '返回', () => {
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
          Row({ space: TITLE_ACTION_BUTTON_GAP }) {
            if (this.rightIcon) {
              this.iconPod(
                false,
                false,
                this.rightIconAccessibilityText,
                () => { if (this.onRightClick) { this.onRightClick() } }
              )
            }
            if (this.secondaryRightIcon) {
              this.iconPod(
                false,
                true,
                this.secondaryRightIconAccessibilityText,
                () => {
                  if (this.onSecondaryRightClick) { this.onSecondaryRightClick() }
                }
              )
            }
          }
          .height(44)
          .margin({ right: 8 })
        } else {
          Blank().width(70)
        }
      }
      .width('100%').height(NAV_BAR_H + this.statusBarHeight)
      .padding({ top: this.statusBarHeight })
      .backgroundColor(Color.Transparent)
      .alignItems(VerticalAlign.Center)

    }
    .width('100%').height(NAV_BAR_H + this.statusBarHeight)
    .clip(false)
  }
}
