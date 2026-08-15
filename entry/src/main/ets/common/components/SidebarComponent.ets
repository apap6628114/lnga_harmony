import { appStore } from '../../store/AppStore'
import type { AuthState } from '../../store/AuthStore'
import { routerStore, Screen } from '../../store/RouterStore'
import { AppColors } from '../constants/Constants'
import { Avatar } from './Avatar'
import { CommunityPanel } from '../../pages/CommunityPanel'

@Component
export struct SidebarComponent {
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
        Text('搜索板块、主题...')
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
    }
    .width(180)
    .height('100%')
    .backgroundColor(AppColors.bgTertiary)
    .border({ width: { right: 0.5 }, color: AppColors.separator })
  }
}
