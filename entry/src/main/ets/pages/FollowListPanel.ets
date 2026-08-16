/**
 * 关注/被关注列表面板 - 我关注的用户（get_follow）与我的被关注（get_follow_by）
 * 布局对齐帖子列表面板：标题区（PanelNavBar）+ 筛选区（SegmentButton 随列表滚动）+ 列表
 * 用户行对齐黑名单面板：头像/昵称/UID + 右侧操作
 */

import { SegmentButton, SegmentButtonOptions, SegmentButtonItemTuple } from '@kit.ArkUI'
import { appStore } from '../store/AppStore'
import { routerStore, Screen } from '../store/RouterStore'
import { fetchFollowedUsers, fetchFollowers, followUser } from '../service/api/FollowApi'
import { ApiResult } from '../model/NgaApiResults'
import type { FollowedUserListResult } from '../model/Follow'
import { FollowedUser, FollowListTab } from '../model/Follow'
import { display } from '@kit.ArkUI'
import { AppColors, BreakpointType } from '../common/constants/Constants'
import { escHtml } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { Avatar } from '../common/components/Avatar'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { FollowedUserDataSource } from '../common/datasource/LazyDataSource'
import { EmptyStateView, LoadingStateView, ErrorStateView } from '../common/components/PageStateView'
import { floatingLayerStore, FloatingPage } from '../store/FloatingLayerStore'
import { PageScope } from '../common/concurrency/PageScope'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'

@Component
export struct FollowListPanel {
  /** 初始 Tab（FollowListTab：0 关注 / 1 被关注）。 */
  @Prop initialMode: number = FollowListTab.FOLLOWED
  @State mode: FollowListTab = FollowListTab.FOLLOWED
  @State users: FollowedUser[] = []
  @State isLoading: boolean = true
  @State hasError: boolean = false
  @State isLoadingMore: boolean = false
  /** 正在取消关注的用户 uid（防重复提交）。 */
  @State removingUid: string = ''
  @State currentPage: number = 1
  /** 是否还有更多页（get_follow/get_follow_by 无总页数，以"上一页非空"推断）。 */
  @State hasMore: boolean = true
  /** 分段切换按钮选中下标（双向绑定）。 */
  @State sortSelected: number[] = [0]
  /** 分段切换按钮选项（关注 / 被关注，纯文字）。 */
  @State tabOptions: SegmentButtonOptions = FollowListPanel.makeTabOptions()
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 列表当前视口高度。 */
  @State listViewportHeight: number = 1
  /** 切换条在窗口中的底部纵坐标（供状态视图撑满切换条下方可视区）。 */
  private sortBarBottomY: number = 0
  /** 列表滚动控制器。 */
  private scroller: Scroller = new Scroller()
  private usersDataSource: FollowedUserDataSource = new FollowedUserDataSource()
  /** 页面出现会话作用域，驱动异步回调的存活与代际校验。 */
  private scope: PageScope = new PageScope()

  /** 按列表绝对滚动偏移同步标题栏视觉效果。 */
  private syncTitleScrollEffect(): void {
    const progress: number = TitleScrollEffect.getProgress(
      this.scroller.currentOffset().yOffset,
      this.statusBarHeight
    )
    if (TitleScrollEffect.shouldUpdateProgress(this.titleScrollEffectProgress, progress)) {
      this.titleScrollEffectProgress = progress
    }
  }

  aboutToAppear(): void {
    if (!appStore.auth.isAuthenticated) {
      // 未登录：不发请求，登录引导空态由 UI 分支负责
      this.isLoading = false
      return
    }
    if (this.initialMode === FollowListTab.FOLLOWERS) {
      this.mode = FollowListTab.FOLLOWERS
      this.sortSelected = [1]
    }
    this.loadFirstPage(this.scope.begin())
  }

  /** 结束页面出现会话，使未完成的异步回调失效。 */
  aboutToDisappear(): void {
    this.scope.end()
  }

  /** 构建分段切换按钮选项（关注 / 被关注，纯文字不含人数）。 */
  private static makeTabOptions(): SegmentButtonOptions {
    return SegmentButtonOptions.capsule({
      buttons: [
        { text: '关注' },
        { text: '被关注' },
      ] as SegmentButtonItemTuple,
      multiply: false,
      fontColor: AppColors.textSecondary,
      selectedFontColor: AppColors.primary,
      fontSize: 13,
      selectedFontSize: 13,
      fontWeight: FontWeight.Normal,
      selectedFontWeight: FontWeight.Bold,
      backgroundColor: AppColors.bgSecondary,
      selectedBackgroundColor: AppColors.primaryLight,
    })
  }

  /** 状态视图高度：撑满切换条下方的列表可视区。 */
  private getStateViewHeight(): number {
    const topOffset: number = this.sortBarBottomY > 0
      ? this.sortBarBottomY
      : TitleScrollEffect.getContentStartOffset(this.statusBarHeight) + 50
    return Math.max(this.listViewportHeight - topOffset, 400)
  }

  /** 切换关注/被关注模式并重新加载。 */
  private switchMode(mode: FollowListTab): void {
    if (this.mode === mode) {
      return
    }
    this.mode = mode
    this.loadFirstPage(this.scope.begin())
  }

  /**
   * 按当前模式发起列表请求。
   *
   * @param page - 页码（1 基）
   * @returns 列表结果
   */
  private async fetchPage(page: number): Promise<FollowedUserListResult> {
    if (this.mode === FollowListTab.FOLLOWED) {
      return await fetchFollowedUsers(appStore.auth.token, page)
    }
    return await fetchFollowers(appStore.auth.token, page)
  }

  /**
   * 加载第一页。
   *
   * @param appearanceGeneration - 请求发起时的页面出现会话代际
   */
  private async loadFirstPage(appearanceGeneration: number): Promise<void> {
    this.isLoading = true
    this.hasError = false
    this.titleScrollEffectProgress = 0
    try {
      const result: FollowedUserListResult = await this.fetchPage(1)
      if (!this.scope.isActive(appearanceGeneration)) {
        return
      }
      if (result.ok) {
        this.users = result.data
        this.usersDataSource.replaceAll(this.users)
        this.currentPage = 1
        this.hasMore = result.data.length > 0
        this.isLoading = false
        return
      }
      this.hasError = true
    } catch (e) {
      if (this.scope.isActive(appearanceGeneration)) {
        this.hasError = true
      }
    }
    if (this.scope.isActive(appearanceGeneration)) {
      this.isLoading = false
    }
  }

  /** 加载下一页。 */
  private async loadMore(): Promise<void> {
    if (this.isLoadingMore || !this.hasMore) {
      return
    }
    this.isLoadingMore = true
    const modeSnapshot: FollowListTab = this.mode
    try {
      const result: FollowedUserListResult = await this.fetchPage(this.currentPage + 1)
      // 页面销毁或 Tab 已切换：丢弃过期分页结果，防止旧数据回写新 Tab
      if (!this.scope.isAlive() || this.mode !== modeSnapshot) {
        return
      }
      if (result.ok) {
        this.currentPage += 1
        this.hasMore = result.data.length > 0
        const merged: FollowedUser[] = this.users.concat(result.data)
        this.users = merged
        this.usersDataSource.replaceAll(merged)
      }
    } catch (e) {
      // 加载更多失败静默，滚动到底部可再次触发
    } finally {
      this.isLoadingMore = false
    }
  }

  /** 点击用户行弹出资料卡（对齐黑名单面板）。 */
  private showProfileCard(uid: string, windowX: number, windowY: number): void {
    const cardW: number = 280
    const cardH: number = 400
    const pad: number = 8
    let posX: number = windowX
    let posY: number = windowY
    try {
      const context = this.getUIContext()
      const displayInfo = display.getDefaultDisplaySync()
      const screenW = context.px2vp(displayInfo.width)
      const screenH = context.px2vp(displayInfo.height)
      posX = Math.max(pad, Math.min(windowX - cardW / 2, screenW - cardW - pad))
      posY = Math.max(pad, Math.min(windowY + pad, screenH - cardH - pad))
    } catch (e) {
      posX = windowX - cardW / 2
      posY = windowY + pad
    }
    floatingLayerStore.profileCardUid = uid
    floatingLayerStore.profileCardX = posX
    floatingLayerStore.profileCardY = posY
    floatingLayerStore.push(FloatingPage.PROFILE_CARD)
  }

  /**
   * 取消关注指定用户并更新列表（仅关注 Tab 可用）。
   *
   * @param user - 目标用户
   */
  private async unfollowUser(user: FollowedUser): Promise<void> {
    if (this.removingUid.length > 0) {
      return
    }
    this.removingUid = user.uid
    try {
      const result: ApiResult = await followUser(appStore.auth.token, user.uid, false)
      // 页面销毁或已切到被关注 Tab：不回写列表与计数
      if (!this.scope.isAlive() || this.mode !== FollowListTab.FOLLOWED) {
        return
      }
      if (result.ok) {
        const merged: FollowedUser[] = this.users.filter((u: FollowedUser): boolean => u.uid !== user.uid)
        this.users = merged
        this.usersDataSource.replaceAll(merged)
        appStore.showToast('已取消关注')
        appStore.invalidateProfile(user.uid)
      } else {
        appStore.showToast(result.error || '操作失败')
      }
    } catch (e) {
      if (this.scope.isAlive() && this.mode === FollowListTab.FOLLOWED) {
        appStore.showToast('操作失败')
      }
    } finally {
      this.removingUid = ''
    }
  }

  build() {
    Stack() {
      Column() {
        List({ scroller: this.scroller }) {
          ListItem() {
            Row() {
              SegmentButton({
                options: this.tabOptions,
                selectedIndexes: $sortSelected,
                onItemClicked: (index: number): void => {
                  this.switchMode(index === 0 ? FollowListTab.FOLLOWED : FollowListTab.FOLLOWERS)
                }
              })
            }
            .width('100%')
            .padding({ left: '4%', right: '4%' })
            .margin({ top: 8, bottom: 6 })
            .onAreaChange((_oldValue: Area, newValue: Area): void => {
              if (typeof newValue.globalPosition.y === 'number' && typeof newValue.height === 'number') {
                this.sortBarBottomY = newValue.globalPosition.y + newValue.height
              }
            })
          }

          if (!appStore.auth.isAuthenticated) {
            ListItem() {
              Column() {
                EmptyStateView({ msg: '登录后查看关注列表', icon: $r('app.media.icon_people') })
              }
              .width('100%').height(this.getStateViewHeight())
              .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
            }
          } else if (this.isLoading) {
            ListItem() {
              Column() {
                LoadingStateView()
              }
              .width('100%').height(this.getStateViewHeight())
              .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
            }
          } else if (this.hasError) {
            ListItem() {
              Column() {
                ErrorStateView({ msg: '加载失败', onRetry: () => this.loadFirstPage(this.scope.begin()) })
              }
              .width('100%').height(this.getStateViewHeight())
              .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
            }
          } else if (this.users.length === 0) {
            ListItem() {
              Column() {
                EmptyStateView({
                  msg: this.mode === FollowListTab.FOLLOWED ? '还没有关注任何用户' : '还没有被关注',
                  icon: $r('app.media.icon_people')
                })
              }
              .width('100%').height(this.getStateViewHeight())
              .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
            }
          } else {
            LazyForEach(this.usersDataSource, (user: FollowedUser) => {
              ListItem() {
                Row() {
                  Avatar({ avatar: user.avatarUrl, uid: user.uid, name: user.userName, avatarSize: 40 })

                  Column() {
                    Text(unescapeHtml(user.userName))
                      .fontSize(15).fontColor(AppColors.textPrimary)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`UID: ${escHtml(user.uid)}`)
                      .fontSize(13).fontColor(AppColors.textTertiary).margin({ top: 2 })
                  }
                  .layoutWeight(1).margin({ left: 12 }).alignItems(HorizontalAlign.Start)
                  .onClick((event: ClickEvent) => {
                    this.showProfileCard(user.uid, event.windowX, event.windowY)
                  })

                  if (this.mode === FollowListTab.FOLLOWED) {
                    Text(this.removingUid === user.uid ? '取消中...' : '取消关注')
                      .fontSize(13)
                      .fontColor(this.removingUid === user.uid ? AppColors.textTertiary : AppColors.destructive)
                      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                      .enabled(this.removingUid.length === 0)
                      .onClick(() => { this.unfollowUser(user) })
                  }
                }
                .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 })
                .alignItems(VerticalAlign.Center)
              }
            }, (user: FollowedUser) => user.uid)

            ListItem() {
              Row() {
                if (this.isLoadingMore) {
                  LoadingProgress().width(16).height(16).color(AppColors.textTertiary)
                  Text('加载更多...').fontSize(13).fontColor(AppColors.textTertiary).margin({ left: 8 })
                } else if (!this.hasMore) {
                  Text('— 已到底 —').fontSize(12).fontColor(AppColors.textTertiary)
                }
              }
              .width('100%').justifyContent(FlexAlign.Center).padding(16)
            }
          }
        }
        .width('100%').layoutWeight(1)
        .scrollBar(BarState.Off)
        .divider({ strokeWidth: 0.5, color: AppColors.separator })
        .lanes(new BreakpointType(1, 2, 2).getValue(this.currentBreakpoint), 12)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(3)
        .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
        .linearGradientBlur(
          TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),
          {
            fractionStops: TitleScrollEffect.getBlurStops(this.listViewportHeight, this.statusBarHeight),
            direction: GradientDirection.Bottom
          }
        )
        .onAreaChange((_oldValue: Area, newValue: Area): void => {
          if (typeof newValue.height === 'number' && newValue.height > 0 &&
            newValue.height !== this.listViewportHeight) {
            this.listViewportHeight = newValue.height
          }
        })
        .onDidScroll((): void => {
          this.syncTitleScrollEffect()
        })
        .onAppear((): void => {
          this.syncTitleScrollEffect()
        })
        .onScrollIndex((start: number, end: number): void => {
          const total: number = this.usersDataSource.totalCount()
          if (end >= total - 3 && total > 0) {
            this.loadMore()
          }
        })
      }
      .width('100%').height('100%')

      PanelNavBar({
        title: '我的关注',
        scrollEffectProgress: this.titleScrollEffectProgress,
        // 「关注动态」直达入口：铃铛跳通知页动态 tab（Screen.notifications(1)），
        // 与帖子列表标题栏铃铛（进通知页消息 tab）的图标语言一致
        secondaryRightIcon: $r('app.media.icon_bell'),
        secondaryRightIconAccessibilityText: '关注动态',
        onSecondaryRightClick: (): void => {
          routerStore.navigateActivity(Screen.notifications(1))
        }
      })
        .width('100%').position({ x: 0, y: 0 })
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg)
  }
}
