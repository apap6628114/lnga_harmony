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
 * 标题栏菜单项。
 *
 * 菜单**在 PanelNavBar 内部渲染**，锚点是标题栏里那颗真实的操作按钮——本工程折叠屏多列路由
 * （`MainPage` 的"侧边栏 + 板块列 + 活动列"）下，把 `bindMenu` 挂在标题栏整体或外层容器上，
 * 菜单会被算到窗口左侧，只有挂在按钮上才稳定。
 *
 * 菜单项因此以"数据 + 回调"的形式由使用方提供：回调必须写成**箭头函数**，才能捕获使用方的
 * `this`。注意 `@BuilderParam` 的坑只针对**方法引用**形式（`xxxBuilder: this.myBuilder`）——
 * 那种写法下构造器在 PanelNavBar 实例上执行，回调里的 `this.xxx` 会落到子组件上；箭头包装
 * （`(): void => { this.myBuilder() }`）的 `this` 仍是使用方，是安全的（见 entry/src/AGENTS.md）。
 */
export interface NavBarMenuItem {
  /** 菜单项文本。 */
  label: string
  /** 是否为当前生效项：用主题色文字表达，不占用系统菜单的选中图标位。 */
  active?: boolean
  /** 点击回调（写成箭头函数以捕获使用方的 this）。 */
  action: () => void
}

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
  /** 是否在右侧操作按钮上绑定标题栏菜单。 */
  @Prop hasMenu: boolean = false
  /**
   * 菜单项提供者（由使用方以箭头函数传入，菜单构建时调用）。
   *
   * 用"提供者"而不是 `@Prop menuItems: NavBarMenuItem[]`：菜单项里带 `action` 回调，而平台
   * **不允许 `@Prop` 装饰 Function 类型**（官方 `@Prop` 文档：不支持装饰 Function 类型变量，
   * API 23 起编译期校验；且 `@Prop` 深拷贝只对基本类型 / Map / Set / Date / Array 保证语义，
   * 数组元素里的函数是否按引用保留取决于运行时实现）。提供者还顺带保证菜单每次构建都取到
   * 最新的文案与激活态，并避免滚动期间每帧新建数组灌进 `@Prop`。
   */
  menuItemsProvider?: () => NavBarMenuItem[]
  /** 菜单是否挂在第二个右侧按钮上（默认挂主按钮）。 */
  @Prop menuOnSecondary: boolean = false
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
    if (this.hasMenu && !isBack && isSecondary === this.menuOnSecondary) {
      // 只有这一颗按钮绑定菜单，避免给返回 / 铃铛等按钮挂上无意义的菜单
      Stack() {
        this.iconPodContent(isBack, isSecondary)
      }
      .width(36).height(36).borderRadius(18)
      .alignContent(Alignment.Center)
      .attributeModifier(UIMaterialManager.fabMaterial)
      .accessibilityText(accessibilityText)
      .onClick(onTap)
      // 两参形式：菜单开合完全交给系统（点锚点开合、点区域外关闭），本地**不持有显隐状态**。
      // 受控形式需要"本地布尔取反 + 系统关闭时回写"两个真源，二者在"点锚点本身"这条路径上会
      // 互相打架（结果取决于系统是否把该次点击透传给锚点）——这是踩过的坑，不要再改回一参形式。
      .bindMenu(this.navBarMenu(), this.navBarMenuOptions())
    } else {
      Stack() {
        this.iconPodContent(isBack, isSecondary)
      }
      .width(36).height(36).borderRadius(18)
      .alignContent(Alignment.Center)
      .attributeModifier(UIMaterialManager.fabMaterial)
      .accessibilityText(accessibilityText)
      .onClick(onTap)
    }
  }

  /** 按钮内容（图标 + 角标）：带菜单与不带菜单两个分支共用，避免重复。 */
  @Builder
  iconPodContent(isBack: boolean, isSecondary: boolean) {
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

  /**
   * 标题栏菜单内容。
   *
   * 本体材质由 `MenuOptions.systemMaterial` 的系统沉浸材质承担（**菜单控制**属 Release 允许
   * 「页面内全部区域」生效的弹窗类接口）。激活态用文字色表达，不用 `.selectIcon()`——后者会为
   * 选中图标预留一块左侧空位，"只看楼主"那种单项激活的菜单里会显得像多了几个空格。
   */
  @Builder
  navBarMenu() {
    Menu() {
      ForEach(this.resolveMenuItems(), (item: NavBarMenuItem) => {
        MenuItem({ content: item.label })
          .contentFontColor(item.active === true ? AppColors.primary : $r('sys.color.font_primary'))
          .onClick(() => { item.action() })
        // key 带激活态指纹：ForEach 的键不变时子组件不会重建，只改 active 会让激活色不刷新
      }, (item: NavBarMenuItem) => item.label + (item.active === true ? '|1' : '|0'))
    }
  }

  /**
   * 取当前菜单项（菜单构建时求值，保证拿到最新文案与激活态）。
   *
   * @returns 菜单项数组；使用方未提供时为空数组
   */
  private resolveMenuItems(): NavBarMenuItem[] {
    return this.menuItemsProvider ? this.menuItemsProvider() : []
  }

  /**
   * 标题栏菜单选项。
   *
   * `Placement.BottomRight`：菜单落在按钮下方、右边缘与按钮右边缘对齐。按钮本身就在标题栏右端，
   * 菜单因此始终保持在标题栏范围内——不再依赖"整条标题栏"那种宽锚点，也就绕开了多列路由下
   * 锚点几何被算错的问题。**落点与迁移前的 `.position({ top: …NAV_BAR_H + 6, right: 16 })`
   * 不再是像素等价**（锚点从整条标题栏换成了 36×36 按钮），需要精确间距时显式给 `targetSpace`。
   *
   * 这里刻意**不设** `onDisappear` 之类的显隐回写：两参 `bindMenu` 下开合由系统持有，
   * 本地没有需要同步的状态。
   *
   * @returns 菜单选项
   */
  private navBarMenuOptions(): MenuOptions {
    const options: MenuOptions = {
      placement: Placement.BottomRight,
      // 箭头是 Tips 语义，操作菜单不要（这也是 ContextMenuOptions 的默认值，显式写出表达意图）
      enableArrow: false,
      // 背板交给系统材质：不设 backgroundColor / backgroundBlurStyle（不做设备降级，
      // 见 UIMaterialManager 的约定说明）
      systemMaterial: UIMaterialManager.menuMaterial
    }
    return options
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
