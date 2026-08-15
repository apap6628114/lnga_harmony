/**
 * 关注动态面板 - 我关注的用户的发帖/回帖/收藏动态流（follow_v2.get_push_list）
 */

import { appStore } from '../store/AppStore'
import { routerStore, Screen } from '../store/RouterStore'
import { fetchFollowedActivity } from '../service/api/FollowApi'
import type { FollowedActivityListResult } from '../model/Follow'
import { FollowedActivity, FollowedActivityType } from '../model/Follow'
import { AppColors, BreakpointType } from '../common/constants/Constants'
import { formatTime } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { FollowedActivityDataSource } from '../common/datasource/LazyDataSource'
import { LoadingStateView, ErrorStateView, EmptyStateView } from '../common/components/PageStateView'
import { PageScope } from '../common/concurrency/PageScope'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'

@Component
export struct FollowedActivityPanel {
  @State activities: FollowedActivity[] = []
  @State isLoading: boolean = true
  @State hasError: boolean = false
  @State isLoadingMore: boolean = false
  @State currentPage: number = 1
  @State totalPages: number = 1
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 列表当前视口高度。 */
  @State listViewportHeight: number = 1
  /** 动态列表滚动控制器。 */
  private scroller: Scroller = new Scroller()
  private activitiesDataSource: FollowedActivityDataSource = new FollowedActivityDataSource()
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
    this.loadFirstPage(this.scope.begin())
  }

  /** 结束页面出现会话，使未完成的异步回调失效。 */
  aboutToDisappear(): void {
    this.scope.end()
  }

  /**
   * 加载关注动态第一页。
   *
   * @param appearanceGeneration - 请求发起时的页面出现会话代际
   */
  private async loadFirstPage(appearanceGeneration: number): Promise<void> {
    this.isLoading = true
    this.hasError = false
    this.titleScrollEffectProgress = 0
    try {
      const result: FollowedActivityListResult = await fetchFollowedActivity(appStore.auth.token, 1)
      if (!this.scope.isActive(appearanceGeneration)) {
        return
      }
      if (result.ok) {
        this.activities = result.data
        this.activitiesDataSource.replaceAll(this.activities)
        this.currentPage = 1
        this.totalPages = result.pages > 0 ? result.pages : 1
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

  /**
   * 加载关注动态下一页。
   */
  private async loadMore(): Promise<void> {
    if (this.isLoadingMore || this.currentPage >= this.totalPages) {
      return
    }
    this.isLoadingMore = true
    try {
      const result: FollowedActivityListResult = await fetchFollowedActivity(appStore.auth.token, this.currentPage + 1)
      // 页面已销毁：丢弃过期结果，防止回写已卸载组件
      if (!this.scope.isAlive()) {
        return
      }
      if (result.ok) {
        this.currentPage += 1
        if (result.pages > 0) {
          this.totalPages = result.pages
        }
        const merged: FollowedActivity[] = this.activities.concat(result.data)
        this.activities = merged
        this.activitiesDataSource.replaceAll(merged)
      }
    } catch (e) {
      // 加载更多失败静默，滚动到底部可再次触发
    } finally {
      this.isLoadingMore = false
    }
  }

  /** 生成动态的可见动作描述（对齐 NGA 网页端语义）。 */
  private describeAction(activity: FollowedActivity): string {
    const isReply: boolean = activity.pid.length > 0 && activity.pid !== '0'
    if (activity.type === FollowedActivityType.POST_TOPIC) {
      return isReply ? '发布了回复' : '发布了主题'
    }
    if (activity.type === FollowedActivityType.POST_REPLY) {
      return '回复了帖子'
    }
    if (activity.type === FollowedActivityType.FAVOR) {
      return isReply ? '收藏了回复' : '收藏了主题'
    }
    return '发布了动态'
  }

  /** 跳转到动态对应的帖子（回复定位楼层）。 */
  private openActivity(activity: FollowedActivity): void {
    if (activity.tid.length === 0) {
      return
    }
    if (activity.pid.length > 0 && activity.pid !== '0') {
      routerStore.navigateActivity(Screen.thread(activity.tid, 1, activity.pid))
    } else {
      routerStore.navigateActivity(Screen.thread(activity.tid))
    }
  }

  build() {
    Stack() {
      Column() {
        if (!appStore.auth.isAuthenticated) {
          Column() {
            EmptyStateView({ msg: '登录后查看关注动态', icon: $r('app.media.icon_people') })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .padding({ top: TitleScrollEffect.getContentStartOffset(this.statusBarHeight) })
        } else if (this.isLoading) {
          Column() {
            LoadingStateView()
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .padding({ top: TitleScrollEffect.getContentStartOffset(this.statusBarHeight) })
        } else if (this.hasError) {
          Column() {
            ErrorStateView({ msg: '加载失败', onRetry: () => this.loadFirstPage(this.scope.begin()) })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .padding({ top: TitleScrollEffect.getContentStartOffset(this.statusBarHeight) })
        } else if (this.activities.length === 0) {
          Column() {
            EmptyStateView({ msg: '暂无关注动态，先去关注感兴趣的用户吧', icon: $r('app.media.icon_people') })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          .padding({ top: TitleScrollEffect.getContentStartOffset(this.statusBarHeight) })
        } else {
          List({ scroller: this.scroller }) {
            LazyForEach(this.activitiesDataSource, (activity: FollowedActivity) => {
              ListItem() {
                Column() {
                  Row() {
                    Text(this.activitySubject(activity))
                      .fontSize(15).fontWeight(FontWeight.Medium)
                      .fontColor(AppColors.textPrimary)
                      .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                  }
                  .width('100%')

                  Row() {
                    Text(this.describeAction(activity))
                      .fontSize(12).fontColor(AppColors.primary)
                    Text(` · ${this.activityActor(activity)}`)
                      .fontSize(12).fontColor(AppColors.textTertiary)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(` · ${formatTime(activity.timestamp)}`)
                      .fontSize(12).fontColor(AppColors.textTertiary)
                  }
                  .width('100%').margin({ top: 4 }).alignItems(VerticalAlign.Center)
                }
                .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .alignItems(HorizontalAlign.Start)
                .onClick(() => { this.openActivity(activity) })
              }
            }, (activity: FollowedActivity) => activity.id)

            ListItem() {
              Row() {
                if (this.isLoadingMore) {
                  LoadingProgress().width(16).height(16).color(AppColors.textTertiary)
                  Text('加载更多...').fontSize(13).fontColor(AppColors.textTertiary).margin({ left: 8 })
                } else if (this.currentPage >= this.totalPages) {
                  Text('— 已到底 —').fontSize(12).fontColor(AppColors.textTertiary)
                }
              }
              .width('100%').justifyContent(FlexAlign.Center).padding(16)
            }
          }
          .width('100%').layoutWeight(1)
          .divider({ strokeWidth: 0.5, color: AppColors.separator })
          .lanes(new BreakpointType(1, 2, 2).getValue(this.currentBreakpoint), 12)
          .edgeEffect(EdgeEffect.Spring)
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
            const total: number = this.activitiesDataSource.totalCount()
            if (end >= total - 3 && total > 0) {
              this.loadMore()
            }
          })
        }
      }
      .width('100%').height('100%')

      PanelNavBar({
        title: '关注动态',
        scrollEffectProgress: this.titleScrollEffectProgress
      })
        .width('100%').position({ x: 0, y: 0 })
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg)
  }

  /** 动态主题标题（data[4] 缺失时以 tid 兜底）。 */
  private activitySubject(activity: FollowedActivity): string {
    const subject: string = unescapeHtml(activity.subject)
    return subject.length > 0 ? subject : `主题 ${activity.tid}`
  }

  /** 动态行为者显示名（data[1] 缺失时以 uid 兜底）。 */
  private activityActor(activity: FollowedActivity): string {
    const name: string = unescapeHtml(activity.actorName)
    return name.length > 0 ? name : `用户 ${activity.actorUid}`
  }
}
