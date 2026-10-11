import { appStore } from '../../store/AppStore'
import { routerStore, Screen } from '../../store/RouterStore'
import { AppColors } from '../constants/Constants'

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

/**
 * 侧边栏底部功能区。
 *
 * 两个侧边栏共用同一份实现，保证「设置入口永远在侧边栏底部同一个位置」：
 * - **多列侧边栏**（`SidebarComponent`，md/lg）：设置 + 列占比模式开关；
 * - **单列图标栏**（`CommunityPanel.MobileTwoPanelContent`，sm）：只有设置。
 *
 * 按钮**居中排列**，位置不写死：`Row` 的 `space` 负责间距、`justifyContent(Center)` 负责
 * 整体居中，按钮数量变化（`showColumnRatio`）时剩余宽度自动均分，不需要任何位置补偿。
 * 左对齐在这里是错的 —— 侧边栏宽度可变（120~320vp），左对齐会让按钮看起来贴着一个
 * 与内容无关的左边距。
 *
 * **曾经有过一枚「重置」，已移除，不要加回来**：它只在占比模式激活时露出，理由是"占比能
 * 拖得很窄，怕用户把自己锁死在难用的布局里"。这条兜底现在由两根更靠前的防线承担 ——
 * ① 侧边栏有 `SIDEBAR_MIN_VP` 下限、板块列有 `BOARD_RATIO_MIN`/`MAX`，把手**拖不出**可用
 * 区间；② 读数标尺在拖动全程显示当前数值，用户看得见自己拖到了哪，也就能原路拖回来。
 * 留着它反而有两个代价：激活态底栏凭空多出一个元素（切换时布局跳动），且它约 34vp 的
 * 固有宽度会把侧边栏最小宽度顶到 136vp（见 `SIDEBAR_MIN_VP` 的推导）。
 */
@Component
export struct SidebarFooterComponent {
  /**
   * 是否显示「列占比模式」开关。
   *
   * 只有多列侧边栏需要它：占比是列堆栈布局的概念，单列图标栏没有列可调，多一枚按钮
   * 只会让人以为点得动。设置入口两边都有，是无条件的那一枚。
   */
  @Prop showColumnRatio: boolean = true
  @StorageProp('navBarHeight') navBarHeight: number = 0
  /** 列占比模式开关（由本组件按钮切换，状态存 AppStorage 供 MainPage 消费）。 */
  @StorageProp('columnRatioMode') columnRatioMode: boolean = false

  build() {
    Row({ space: FOOTER_BUTTON_GAP }) {
      this.FooterButton(FOOTER_SETTINGS)

      if (this.showColumnRatio) {
        this.FooterButton(FOOTER_COLUMN_RATIO)
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    // 底部额外留出系统导航条高度：手势条压在按钮上会同时吃掉点击与观感
    .padding({ left: 10, right: 10, top: 6, bottom: 6 + this.navBarHeight })
    .alignItems(VerticalAlign.Center)
    .border({ width: { top: 0.5 }, color: AppColors.separator })
  }

  /**
   * 底栏图标按钮。
   *
   * `kind` 是按值传入的**编译期字面量**（`FOOTER_*`），不参与响应式依赖；图标 / 图标色 /
   * 底色 / 无障碍文案一律由 `this` 上的方法读取状态。
   */
  @Builder
  FooterButton(kind: number) {
    Stack() {
      Image(this.footerIcon(kind))
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

  /**
   * 底栏图标资源。
   *
   * 占比按钮**随状态换形**，不只是换色：
   * - 未激活：左右两条竖列块 + 夹在中间的双向箭头（`icon_column_ratio`）—— 拖动隐喻，
   *   读作"两列之间可以左右拖"；改造初版那枚静态「三竖条」只说得出"这是列布局"，
   *   说不出"点进去能调宽度、拖的是哪条线"；
   * - 激活后：换成叉号（`icon_close`）—— 退出隐喻，按钮当下唯一的作用就是关掉这个模式。
   *
   * 只换色（primary 高亮）时，用户既看不出自己正处在模式里，更看不出该怎么退出：
   * 一个开关的两个状态必须各自给出一个明确的动作。底色高亮仍保留，负责表达"模式开着"。
   *
   * 重画这枚图标时注意**小尺寸可辨识度**：它实际只按 18vp 渲染（`FOOTER_BUTTON_ICON`），
   * 两倍屏下也就 36 物理像素。实测在这个尺寸下，细竖线（宽 ≤ 1.5 于 24 视框）会被抗锯齿
   * 抹成灰线、视觉重量撑不住，箭头也会和线粘成一团；所以用**实心列块**（宽 2.2）划出两侧
   * 边界，箭头（翼展 7.6）夹在中间并留出 0.4 以上间隙。
   */
  private footerIcon(kind: number): Resource {
    if (kind === FOOTER_SETTINGS) {
      return $r('app.media.profile_settings')
    }
    return this.columnRatioMode ? $r('app.media.icon_close') : $r('app.media.icon_column_ratio')
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
   * 占比按钮**必须配 Toast**：图标再直白也只说得清"这里能调列宽"，说不清把手在哪、
   * 松开后怎么退出，必须在按下后立刻用一句话说清"刚才开了什么、接下来怎么用"。
   *
   * `animateTo` 只负责**底色与图标色**（`backgroundColor` / `fillColor`）走 180ms 缓动；
   * 图标**换形不走缓动**（`Image` 的 `src` 是资源替换，没有可补间的中间态），瞬时切换反而
   * 让"按钮的作用已经变了"这件事更干脆。MainPage 读数标尺的淡入也不依赖它 —— 标尺的
   * `TransitionEffect` 自带 `animation()` 参数，属"直接增删组件"式自播（见组件内转场文档）。
   * 因此**不要**删掉 MainPage 里的 `.animation(...)`，那才是标尺动画的承重件。
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
