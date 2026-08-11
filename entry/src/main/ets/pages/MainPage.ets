/**
 * 主页面 - 统一三列 Panel 架构
 *
 * 三列均保持在相同树节点位置，通过 .visibility() 控制显隐，避免断点切换时组件重建导致 @State 丢失。
 * SidebarComponent 内部 CommunityPanel 始终以 md+ 模式渲染 (SidebarListContent)，
 * 避免 sm 隐藏时浪费渲染 MobileTwoPanelContent。
 *
 * sm (一列): 侧边栏隐藏, 单列内容 (activity > board > 社区网格)
 * md (两列): 侧边栏 + 单列内容 (activity > board > empty)
 * lg (三列): 侧边栏 + 板块列 + 活动列 (并行显示)
 */

import { appStore } from '../store/AppStore'
import { routerStore, RouterStoreClass } from '../store/RouterStore'
import { verifyToken } from '../service/api/AuthApi'

import { floatingLayerStore, FloatingLayerStoreClass, FloatingPage } from '../store/FloatingLayerStore'
import { AppColors } from '../common/constants/Constants'
import { ActivityRouter } from './ActivityRouter'
import { BoardRouter } from './BoardRouter'
import { SidebarComponent } from '../common/components/SidebarComponent'
import { CommunityPanel } from './CommunityPanel'
import { FloatingLayerComponent } from '../common/components/FloatingLayerComponent'
import { EmptyHint } from '../common/components/EmptyHint'
import { ToastComponent } from '../common/components/Toast'
import { TtsProgressIndicator } from '../common/components/TtsProgressIndicator'
import { Logger, DOMAIN_UI } from '../common/utils/Logger'
import { enableKeepScreenOn, disableKeepScreenOn } from '../common/managers/ScreenOnManager'

const logger = new Logger(DOMAIN_UI, 'MainPage')

@Entry
@Component
struct MainPage {
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  @StorageProp('profileVersion') @Watch('onProfileRefresh') profileVersion: number = 0
  @StorageProp('themeName') themeName: string = 'original'
  @State private router: RouterStoreClass = routerStore
  @State private floating: FloatingLayerStoreClass = floatingLayerStore

  aboutToAppear(): void {
    // 登录进入主页面后保持屏幕常亮（不息屏），离开主页面时恢复自动息屏
    enableKeepScreenOn()
    this.checkAuth()
  }

  aboutToDisappear(): void {
    disableKeepScreenOn()
  }

  private onProfileRefresh(): void {
    const cached = appStore.getCachedProfile(appStore.auth.uid)
    if (cached) {
      appStore.auth.nickName = cached.userName
      appStore.auth.avatarUrl = cached.avatarUrl
    }
  }

  onBackPress(): boolean {
    if (this.floating.size > 0) {
      if (this.floating.top === FloatingPage.REPLY_DIALOG) {
        this.floating.notifyReplyCloseRequested()
      } else if (this.floating.top === FloatingPage.CONFIRM_DIALOG) {
        this.floating.hideConfirm()
      } else {
        this.floating.pop()
      }
      return true
    }
    if (this.router.activityStack.length > 0) {
      this.router.back()
      return true
    }
    if (this.router.boardSlot) {
      if (this.currentBreakpoint === 'sm' || this.router.boardSlot.type === 'search') {
        this.router.back()
        return true
      }
      return true
    }
    return false
  }

  build() {
    Stack() {
      Row() {
        SidebarComponent()
          .width(180)
          .height('100%')
          .visibility(this.currentBreakpoint === 'sm' ? Visibility.None : Visibility.Visible)

        Row() {
          Column() {
            if (this.currentBreakpoint === 'sm') {
              CommunityPanel({ currentBreakpoint: 'sm' })
                .width('100%').height('100%')
                .visibility(!this.router.boardSlot && !this.router.topActivity
                  ? Visibility.Visible : Visibility.None)
            }
            if (this.router.boardSlot) {
              BoardRouter({ boardSlot: this.router.boardSlot })
            }
            if (this.currentBreakpoint !== 'sm' && !this.router.boardSlot && !this.router.topActivity) {
              EmptyHint()
            }
          }
          .height('100%')
          .width(this.getBoardColWidth())
          .backgroundColor(AppColors.bg)
          .visibility(this.getBoardColVisibility())

          Column() {
            ActivityRouter({ activityStack: this.router.activityStack })
          }
          .layoutWeight(1)
          .height('100%')
          .backgroundColor(AppColors.bg)
          .visibility(this.getActivityColVisibility())
        }
        .layoutWeight(1)
        .height('100%')
        .backgroundColor(AppColors.bg)
      }
      .width('100%')
      .height('100%')

      FloatingLayerComponent({ currentBreakpoint: this.currentBreakpoint })
      ToastComponent()
      TtsProgressIndicator()
    }
    .width('100%').height('100%')
  }

  private getBoardColVisibility(): Visibility {
    if (this.currentBreakpoint === 'lg') {
      return (this.router.boardSlot || !this.router.topActivity) ? Visibility.Visible : Visibility.None
    }
    return this.router.topActivity ? Visibility.None : Visibility.Visible
  }

  private getBoardColWidth(): string {
    if (this.currentBreakpoint === 'lg' && this.router.topActivity && this.router.boardSlot) {
      return '40%'
    }
    return '100%'
  }

  private getActivityColVisibility(): Visibility {
    return this.router.topActivity ? Visibility.Visible : Visibility.None
  }

  private async checkAuth(): Promise<void> {
    if (!appStore.auth.isAuthenticated) {
      try { this.getUIContext().getRouter().replaceUrl({ url: 'pages/LoginPage' }) } catch (e) { logger.error('route failed: %{public}s', (e as Error).message) }
      return
    }

    const valid = await verifyToken(appStore.auth.token)
    if (!valid) {
      appStore.clearAuth()
      try { this.getUIContext().getRouter().replaceUrl({ url: 'pages/LoginPage' }) } catch (e) { logger.error('route failed: %{public}s', (e as Error).message) }
      return
    }

    const cached = appStore.getCachedProfile(appStore.auth.uid)
    if (cached) {
      appStore.auth.nickName = cached.userName
      appStore.auth.avatarUrl = cached.avatarUrl
    }

    appStore.ensureProfile(appStore.auth.uid)
    appStore.settingsStore.ensureFavorites()
    appStore.autoCheckinIfNeeded()
  }
}
