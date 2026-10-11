import { appStore } from '../../store/AppStore'
import type { AuthState } from '../../store/AuthStore'
import { routerStore, Screen } from '../../store/RouterStore'
import { AppColors } from '../constants/Constants'
import { Avatar } from './Avatar'
import { SidebarFooterComponent } from './SidebarFooterComponent'
import { CommunityPanel } from '../../pages/CommunityPanel'

/**
 * 多列侧边栏（md/lg）。
 *
 * 底部功能区与单列图标栏共用 {@link SidebarFooterComponent}：设置入口的位置在两个侧边栏里
 * 必须一致，占比开关则只属于多列（`showColumnRatio: true`）。
 */
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

      // 底部功能区：设置 + 列占比开关（单列图标栏只有前者，见 SidebarFooterComponent）
      SidebarFooterComponent({ showColumnRatio: true })
    }
    .width(this.sidebarWidth)
    .height('100%')
    .backgroundColor(AppColors.bgTertiary)
    .border({ width: { right: 0.5 }, color: AppColors.separator })
  }
}
