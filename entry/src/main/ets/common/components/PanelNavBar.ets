import { routerStore } from '../../store/RouterStore'
import {
  AppColors,
  NAV_BAR_H,
  TITLE_ACTION_BUTTON_GAP,
  TITLE_BLUR_FADE_DISTANCE,
  TITLE_EDGE_PADDING,
  TITLE_POD_SIZE,
  TITLE_TEXT_GAP
} from '../constants/Constants'
import { UIMaterialManager } from '../managers/UIMaterialManager'
import { TitleScrollEffect } from '../utils/TitleScrollEffect'
import { HdsMaterialHost } from './HdsMaterialHost'

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
 * 标题栏本体不使用整块材质（栏位保持透明，正文从下方穿越），沉浸光感材质**只作用于返回 /
 * 右侧操作按钮**：每颗按钮的背板是 `HdsMaterialHost`（→ `HdsTabs` 悬浮页签栏材质），
 * 而不是自绘磨砂玻璃（见 `iconPod` 的说明）。`title`、渐变着色层与按钮布局都不参与材质。
 *
 * 列表滚动进入标题区时，正文自身承担空间渐变模糊，标题层不参与着色：向下衰减的着色层
 * 保留结构，但其两个颜色资源（title_backdrop_tint / title_backdrop_clear）在亮色与
 * 暗色下**均为全透明**（#00000000），因此不产生任何像素。需要恢复"主题同色偏色"时，
 * 只需改这两条资源，无需改组件。
 *
 * 说明：该着色层属于纯视觉层，不占用布局索引、不参与内容区定位；
 * 页面使用方通过 scrollEffectProgress 传递滚动进度，默认 0 保持原有视觉。
 *
 * ## 横向坐标约定（同一行两端必须对称）
 *
 * 同一行两端元素到屏幕左 / 右边界的距离**一律等于 `TITLE_EDGE_PADDING`**（8vp），左右两侧共用
 * 这一个常量：返回按钮容器与右侧操作按钮容器都与材质块**同宽**（`TITLE_POD_SIZE`），贴边位置
 * 只由各自的 `margin` 决定。踩坑记录——旧实现左侧是「`width(54)` + `FlexAlign.Center` +
 * `margin({ left: 8 })`」，按钮实际落在 `8 + (54-36)/2 = 17vp`，与右侧的 8vp 差 9vp；而那个
 * 54 容器不承载点击（`onClick` 挂在材质块内部的内容节点上），偏移没有任何功能收益。
 * 改这里时先算清 `margin + (容器宽 - TITLE_POD_SIZE) / 2`：容器宽不等于按钮宽时**不要写居中**。
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
   * 标题栏内可操作图标按钮：**HDS 材质块**底板 + 一颗承载动作 / 菜单的内容节点。
   *
   * ## 为什么不再用自绘磨砂玻璃
   *
   * 背板原为 `UIMaterialManager.fabMaterial`（自绘磨砂玻璃）。但标题栏是本组件自绘的
   * `Stack` + `Row`，**不属于 `docs/IMMERSIVE_LIGHT_DESIGN.md` §0 生效范围门禁里的
   * `Navigation` 标题栏**，普通组件写 `.systemMaterial(...)` 在 Release 下静默失效；HDS 材质由
   * HDS 组件自身渲染、不受该门禁约束，是这里唯一能拿到**真材质**（折射、高光、系统阴影、
   * 深浅色自适应色调）的通道（详见 `HdsMaterialHost` 文件头与 §12.9）。
   *
   * ## 与 `ThreadPanel` / `TopicListPanel` 现有调用点同构的三条约定
   *
   * 1. **尺寸显式**：HDS 悬浮栏不能像自绘玻璃那样由内容撑开，`barWidth` / `barHeight` 固定传
   *    `TITLE_POD_SIZE`（见该常量的真机核对提示）。
   * 2. **内容容器必须写 `'100%'`，不能写 `TITLE_POD_SIZE` 的显式高度**：HDS 页签项的**内容区比
   *    `barHeight` 矮**（页签项自带内边距），内容容器高于内容区时超出部分按**顶部溢出**对齐——
   *    真机现象是**图标整体偏下**（三颗按钮一致）。写成 `'100%'` 后容器高度 = 内容区高度，图标由
   *    `alignContent(Center)` 居中于内容区，即与材质块同心；这与 `ThreadPanel` 回复按钮（真机实测
   *    "图标中心 = 材质块中心"）的写法完全一致。角标不再用 `position`，见 `iconPodContent`。
   * 3. **宿主 `onTap` 与内容子元素交互二选一**：这里**一律不传宿主 `onTap`**，动作 / 菜单 / 无障碍
   *    名称全部挂在内容节点上——与迁移前 `.onClick` / `.bindMenu` 的行为、可聚焦性与无障碍语义
   *    逐条等价，也避免"宿主 `onTabBarClick` + 子元素 `onClick`"双触发。代价是拿不到 HDS 页签项
   *    自带的点击反馈（迁移前的自绘玻璃本来也没有按压动画）。
   *
   * ## 真机核对记录
   *
   * - **已核对**：36×36 材质块按 `TITLE_POD_SIZE` 正常显示（未被 HDS 规范撑大或截断）；图标**曾
   *   整体偏下**（原因与修法见约定 2），内容容器改 `'100%'` 后居中。
   * - 待核对：角标是否被 HDS 页签项裁切（角标锚在图标右上角、向图标外溢出最多 9vp）；
   * - 绑菜单那颗：菜单是否仍落在按钮下方、右边缘与之对齐——锚点从自绘底板换成了材质块**内部**的
   *   内容节点，多列路由下的锚点几何必须重新确认（`docs/UI_COMPONENT_MIGRATION.md` §7.7 记的是
   *   同一类坑，那次连挂错三层才定位到"锚点必须是标题栏里那颗真实按钮"）；
   * - 无障碍朗读是否仍落到按钮上（`accessibilityText` 挂在持有 `onClick` / `bindMenu` 的内容节点上，
   *   应仍可聚焦）。
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
      HdsMaterialHost({ barWidth: TITLE_POD_SIZE, barHeight: TITLE_POD_SIZE }) {
        Stack() {
          this.iconPodContent(isBack, isSecondary)
        }
        .width('100%').height('100%')
        .alignContent(Alignment.Center)
        .accessibilityText(accessibilityText)
        .onClick(onTap)
        // 两参形式：菜单开合完全交给系统（点锚点开合、点区域外关闭），本地**不持有显隐状态**。
        // 受控形式需要"本地布尔取反 + 系统关闭时回写"两个真源，二者在"点锚点本身"这条路径上会
        // 互相打架（结果取决于系统是否把该次点击透传给锚点）——这是踩过的坑，不要再改回一参形式。
        .bindMenu(this.navBarMenu(), this.navBarMenuOptions())
      }
    } else {
      HdsMaterialHost({ barWidth: TITLE_POD_SIZE, barHeight: TITLE_POD_SIZE }) {
        Stack() {
          this.iconPodContent(isBack, isSecondary)
        }
        .width('100%').height('100%')
        .alignContent(Alignment.Center)
        .accessibilityText(accessibilityText)
        .onClick(onTap)
      }
    }
  }

  /**
   * 按钮内容（图标 + 角标）：带菜单与不带菜单两个分支共用，避免重复。
   *
   * **角标锚在图标自己的右上角，不用 `position` 绝对坐标**：外层容器的高度由 HDS 页签项的
   * 内容区决定（不由我们控制），任何"假设容器尺寸"的绝对坐标都会失配（`IMMERSIVE_LIGHT_DESIGN.md`
   * §12.9 的教训）。`offset(8, -9)` 是"角标右上角对齐图标右上角"后的落点换算——旧实现是
   * `position({ x: 19, y: 0 })`（相对 36×36 材质块；角标宽 16 时右上角落在材质块坐标 `(35, 0)`），
   * 图标右上角在材质块坐标 `(27, 9)`，两者之差即 `(8, -9)`。
   *
   * **`draggable(false)` 必须显式写**：`Image` 自 API 10 起 `draggable` 默认为 `true`（官方声明：
   * 值为 `true` 时**绑定的长按手势不生效**，事件被拖拽消费），于是长按标题栏按钮会把图标当成
   * 图片拖起。标题栏按钮不做拖拽（真机现象：长按图标出现系统拖拽预览）。
   */
  @Builder
  iconPodContent(isBack: boolean, isSecondary: boolean) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Image(this.resolveIcon(isBack, isSecondary)).width(18).height(18).objectFit(ImageFit.Contain)
        .fillColor(this.resolveIconColor(isBack, isSecondary))
        .draggable(false)
      if (!isBack && this.resolveBadgeCount(isSecondary) > 0) {
        Text(this.formatBadgeCount(this.resolveBadgeCount(isSecondary)))
          .fontSize(9).fontColor(Color.White).textAlign(TextAlign.Center)
          .height(16).borderRadius(8).backgroundColor(Color.Red)
          .padding({ left: 5, right: 5 })
          .offset({ x: 8, y: -9 })
      }
    }
    .width(18).height(18)
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
          // 返回按钮容器与材质块**同宽**（TITLE_POD_SIZE）：贴边位置只由 margin 决定。
          // 不要再让容器比按钮宽并 `justifyContent(FlexAlign.Center)` —— 按钮会相对 margin
          // 额外内缩 `(容器宽 - TITLE_POD_SIZE) / 2`，与右侧按钮贴边不一致（见 TITLE_EDGE_PADDING）。
          Row() {
            this.iconPod(true, false, '返回', () => {
              if (this.onBack) { this.onBack() } else { routerStore.back() }
            })
          }
          .width(TITLE_POD_SIZE).height(NAV_BAR_H)
          .margin({ left: TITLE_EDGE_PADDING, right: TITLE_TEXT_GAP })
        } else {
          // 无返回按钮时左侧只留一份屏幕边距，标题文本因此靠左（如 md/lg 断点下的板块列）
          Blank().width(TITLE_EDGE_PADDING)
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
          .height(NAV_BAR_H)
          // 与左侧返回按钮共用同一条屏幕边距：同一行两端元素距屏幕边界的距离完全一致
          .margin({ right: TITLE_EDGE_PADDING })
        } else {
          // 无操作按钮时右侧同样只留一份屏幕边距。旧值 70 是按"永远预留两颗按钮"估的第三套数值，
          // 与有按钮时的实际占位（一颗 36 / 两颗 80）都对不上，标题可显示宽度会在页面间跳变
          Blank().width(TITLE_EDGE_PADDING)
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
