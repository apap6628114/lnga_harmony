import { appStore } from '../../store/AppStore'
import type { AuthState } from '../../store/AuthStore'
import { routerStore, Screen } from '../../store/RouterStore'
import { AppColors } from '../constants/Constants'
import { Avatar } from './Avatar'
import { CommunityPanel } from '../../pages/CommunityPanel'

/** 底部按钮的边长（vp）。 */
const FOOTER_BUTTON_SIZE: number = 32

/** 底部按钮的图标尺寸（vp）。 */
const FOOTER_BUTTON_ICON: number = 18

/** 底部按钮间距（vp）。 */
const FOOTER_BUTTON_GAP: number = 4

/** 底栏按钮槽位：设置。 */
const FOOTER_SETTINGS: number = 0

/** 底栏按钮槽位：列占比模式。 */
const FOOTER_COLUMN_RATIO: number = 1

@Component
export struct SidebarComponent {
  /**
   * 侧边栏宽度（vp），由 MainPage 按列堆栈占比下发。
   *
   * 走 @Prop 而不是让父组件在这个组件实例上写 `.width()`：组件内部根容器同样要设宽度，
   * 两处都写就变成"父子的同名属性谁生效"的隐式约定；集中在组件内部一处设置，拖动把手时
   * 父组件改值 → @Prop 同步 → 根容器宽度跟随，链路唯一。
   */
  @Prop sidebarWidth: number = 180
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @StorageProp('navBarHeight') navBarHeight: number = 0
  /** 列堆栈占比模式开关（由本组件底部按钮切换）。 */
  @StorageProp('columnRatioMode') columnRatioMode: boolean = false
  @State private authState: AuthState = appStore.auth

  build() {
    Column() {
      Column() {
        Avatar({
          avatar: this.authState.avatarUrl,
          uid: this.authState.uid,
          name: this.authState.nickName,
          avatarSize: 36
        })
        Text(this.authState.nickName || '未登录')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 8 })
      }
      .width('100%')
      .padding({ top: 14 + this.statusBarHeight, bottom: 14 })
      .alignItems(HorizontalAlign.Center)
      .border({ width: { bottom: 0.5 }, color: AppColors.separator })
      .onClick(() => {
        if (this.authState.uid) {
          routerStore.navigateActivity(Screen.profile(this.authState.uid))
        }
      })

      Row() {
        Image($r('app.media.icon_search'))
          .width(14).height(14).fillColor(AppColors.textTertiary).margin({ right: 6 })
        Text('搜索板块、帖子...')
          .fontSize(12).fontColor(AppColors.textTertiary)
      }
      .width('100%').height(36).padding({ left: 12, right: 12 })
      .backgroundColor(AppColors.bgSecondary).borderRadius(8)
      .margin({ left: 12, right: 12, top: 8 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        routerStore.navigateSearch()
      })

      Column() {
        // 侧边栏内 CommunityPanel 永不以 sm 渲染: 侧边栏仅在 md+ 可见, 且 sm 下渲染 MobileTwoPanelContent 是浪费
        CommunityPanel({ currentBreakpoint: this.currentBreakpoint === 'sm' ? 'md' : this.currentBreakpoint })
      }
      .layoutWeight(1)

      this.ColumnRatioFooter()
    }
    .width(this.sidebarWidth)
    .height('100%')
    .backgroundColor(AppColors.bgTertiary)
    .border({ width: { right: 0.5 }, color: AppColors.separator })
  }

  /**
   * 侧边栏底部工具条：设置入口 + 列占比模式开关。
   *
   * 只在多列断点出现 —— 侧边栏本身在 `sm` 是 `Visibility.None`，整块随父一起隐藏，
   * 不需要在这里再判一次断点。
   *
   * 「重置」只在模式激活时露出：占比可以拖到很窄，没有一键还原的话用户可能把自己锁在
   * 一个难用的布局里；常驻又会和普通状态下的极简底部冲突。
   */
  @Builder
  ColumnRatioFooter() {
    Row({ space: FOOTER_BUTTON_GAP }) {
      this.FooterButton(FOOTER_SETTINGS)

      this.FooterButton(FOOTER_COLUMN_RATIO)

      Blank()

      if (this.columnRatioMode) {
        Text('重置')
          .fontSize(11)
          .fontColor(AppColors.textSecondary)
          .padding({ left: 6, right: 6, top: 6, bottom: 6 })
          .borderRadius(8)
          .accessibilityText('恢复默认列占比')
          .onClick(() => {
            appStore.settingsStore.resetColumnLayout(this.currentBreakpoint)
            appStore.showToast('已恢复默认列占比')
          })
      }
    }
    .width('100%')
    // 底部额外留出系统导航条高度：手势条压在按钮上会同时吃掉点击与观感
    .padding({ left: 10, right: 10, top: 6, bottom: 6 + this.navBarHeight })
    .alignItems(VerticalAlign.Center)
    .border({ width: { top: 0.5 }, color: AppColors.separator })
  }

  /**
   * 底栏图标按钮。
   *
   * `kind` 是按值传入的**编译期字面量**（`FOOTER_*`），不参与响应式依赖；图标色 / 底色 /
   * 无障碍文案一律由 `this` 上的方法读取状态。
   */
  @Builder
  FooterButton(kind: number) {
    Stack() {
      Image(kind === FOOTER_SETTINGS
        ? $r('app.media.profile_settings')
        : $r('app.media.icon_column_ratio'))
        .width(FOOTER_BUTTON_ICON)
        .height(FOOTER_BUTTON_ICON)
        .fillColor(this.footerIconColor(kind))
    }
    .width(FOOTER_BUTTON_SIZE)
    .height(FOOTER_BUTTON_SIZE)
    .borderRadius(8)
    .backgroundColor(this.footerButtonBg(kind))
    .accessibilityText(this.footerLabel(kind))
    .onClick(() => {
      this.handleFooterTap(kind)
    })
  }

  private footerIconColor(kind: number): Resource {
    if (kind === FOOTER_SETTINGS) {
      return AppColors.textSecondary
    }
    return this.columnRatioMode ? AppColors.primary : AppColors.textSecondary
  }

  private footerButtonBg(kind: number): ResourceColor {
    if (kind === FOOTER_COLUMN_RATIO && this.columnRatioMode) {
      return AppColors.selectionTint
    }
    return Color.Transparent
  }

  private footerLabel(kind: number): string {
    if (kind === FOOTER_SETTINGS) {
      return '设置'
    }
    return this.columnRatioMode ? '关闭列占比模式' : '调整列占比'
  }

  /**
   * 底栏按钮点击。
   *
   * 占比按钮**必须配 Toast**：三竖图标本身表意不足，用户按下去之前无从知道它是干什么的，
   * 必须在按下后立刻用一句话说清"刚才开了什么、接下来怎么用"。
   *
   * `animateTo` 只负责**按钮自身的配色**（`backgroundColor` / `fillColor`）走 180ms 缓动；
   * MainPage 读数标尺的淡入不依赖它 —— 标尺的 `TransitionEffect` 自带 `animation()` 参数，
   * 属"直接增删组件"式自播（见组件内转场文档）。因此**不要**删掉 MainPage 里的
   * `.animation(...)`，那才是标尺动画的承重件。
   */
  private handleFooterTap(kind: number): void {
    if (kind === FOOTER_SETTINGS) {
      routerStore.navigateActivity(Screen.settings())
      return
    }
    const next: boolean = !this.columnRatioMode
    this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, (): void => {
      appStore.settingsStore.setColumnRatioMode(next)
    })
    appStore.showToast(next
      ? '列占比模式：拖动列与列之间的把手，可调整每列宽度'
      : '已关闭列占比模式（占比设置已保留）')
  }
}
