import { AppColors } from '../common/constants/Constants'
import { formatTime } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { appStore } from '../store/AppStore'
import { BrowseHistoryEntry } from '../store/HistoryStore'
import { routerStore, Screen } from '../store/RouterStore'
import { floatingLayerStore } from '../store/FloatingLayerStore'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { HistoryItemDataSource } from '../common/datasource/LazyDataSource'
import { AnonymousName } from '../common/components/AnonymousName'
import { PageScope } from '../common/concurrency/PageScope'
import { KEY_IMMERSIVE_MATERIAL_ENABLED } from '../common/constants/AppStorageKeys'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'

@Component
export struct BrowseHistoryPanel {
  @State items: BrowseHistoryEntry[] = []
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 是否启用沉浸式材质。 */
  @StorageProp(KEY_IMMERSIVE_MATERIAL_ENABLED) materialEnabled: boolean = true
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 列表当前视口高度。 */
  @State listViewportHeight: number = 1
  @StorageProp('browseHistoryVersion') browseHistoryVersion: number = 0
  /** 黑名单变更版本号。 */
  @StorageProp('blacklistVersion') blacklistVersion: number = 0
  /** 浏览历史列表滚动控制器。 */
  private scroller: Scroller = new Scroller()
  private historyDataSource: HistoryItemDataSource = new HistoryItemDataSource()
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
    this.loadHistory(this.scope.begin())
  }

  /** 结束页面出现会话，使未完成的异步回调失效。 */
  aboutToDisappear(): void {
    this.scope.end()
  }

  private async loadHistory(gen: number): Promise<void> {
    if (!appStore.auth.isAuthenticated) {
      if (!this.scope.isActive(gen)) {
        return
      }
      this.items = []
      this.historyDataSource.clear()
      this.titleScrollEffectProgress = 0
      return
    }
    try {
      const items: BrowseHistoryEntry[] = await appStore.getBrowseHistory(appStore.auth.uid)
      if (!this.scope.isActive(gen)) {
        return
      }
      this.items = items
      this.historyDataSource.replaceAll(this.items as object[])
      if (this.items.length === 0) {
        this.titleScrollEffectProgress = 0
      }
    } catch (e) {
      if (!this.scope.isActive(gen)) {
        return
      }
      this.items = []
      this.titleScrollEffectProgress = 0
    }
  }

  private async removeItem(tid: string): Promise<void> {
    this.items = this.items.filter((item: BrowseHistoryEntry) => item.tid !== tid)
    this.historyDataSource.replaceAll(this.items as object[])
    if (this.items.length === 0) {
      this.titleScrollEffectProgress = 0
    }
    await appStore.removeBrowseHistory(appStore.auth.uid, tid)
  }

  private async clearAll(): Promise<void> {
    this.items = []
    this.historyDataSource.clear()
    this.titleScrollEffectProgress = 0
    await appStore.clearBrowseHistory(appStore.auth.uid)
  }

  /**
   * 判断浏览记录中的主题作者是否已被屏蔽。
   *
   * @param item - 浏览记录
   * @returns 作者是否在实时黑名单中
   */
  private isAuthorBlacklisted(item: BrowseHistoryEntry): boolean {
    return this.blacklistVersion >= 0 &&
      appStore.settingsStore.isBlacklisted(item.authorid)
  }

  build() {
    Stack() {
      Column() {
        if (this.items.length === 0) {
          Row().width('100%').height(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          Column() {
            Image($r('app.media.icon_clock')).width(40).height(40).fillColor(AppColors.textTertiary).opacity(0.4).margin({ bottom: 12 })
            Text('暂无浏览记录').fontSize(15).fontColor(AppColors.textTertiary)
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else {
          List({ scroller: this.scroller }) {
            LazyForEach(this.historyDataSource, (itemObj: object) => {
              ListItem() {
                Row() {
                  Column() {
                    Text(this.isAuthorBlacklisted(itemObj as BrowseHistoryEntry) ?
                      '该用户已被屏蔽' : unescapeHtml((itemObj as BrowseHistoryEntry).subject))
                      .fontSize(15).fontColor(AppColors.textPrimary).maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                    Row() {
                      if ((itemObj as BrowseHistoryEntry).board) {
                        Text(unescapeHtml((itemObj as BrowseHistoryEntry).board))
                          .fontSize(12).fontColor(AppColors.textTertiary).margin({ right: 4 })
                      }
                      Row() {
                        AnonymousName({
                          author: (itemObj as BrowseHistoryEntry).author,
                          isAnonymous: (itemObj as BrowseHistoryEntry).author.startsWith('#anony_') &&
                            (itemObj as BrowseHistoryEntry).author.length === 39,
                          fontSize: 12
                        })
                        if (appStore.settingsStore.getNote((itemObj as BrowseHistoryEntry).authorid).length > 0) {
                          Text('(' + appStore.settingsStore.getNote((itemObj as BrowseHistoryEntry).authorid) + ')')
                            .fontSize(11).fontColor(AppColors.warning).margin({ left: 3 })
                        }
                        Text(` · ${formatTime((itemObj as BrowseHistoryEntry).ts / 1000)}`)
                          .fontSize(12).fontColor(AppColors.textTertiary)
                      }
                      Row() { Image($r('app.media.icon_chat_bubble')).width(12).height(12).fillColor(AppColors.textTertiary); Text(` ${(itemObj as BrowseHistoryEntry).replies}`).fontSize(12).fontColor(AppColors.textTertiary) }.margin({ left: 8 })
                    }
                    .margin({ top: 6 })
                  }
                  .layoutWeight(1).alignItems(HorizontalAlign.Start)

                  Text('✕').fontSize(16).fontColor(AppColors.textTertiary).padding(8)
                    .onClick(() => this.removeItem((itemObj as BrowseHistoryEntry).tid))
                }
                .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 }).alignItems(VerticalAlign.Center)
                .onClick(() => {
                  routerStore.navigateActivity(Screen.thread((itemObj as BrowseHistoryEntry).tid))
                })
              }
            }, (itemObj: object) => (itemObj as BrowseHistoryEntry).tid)
          }
          .layoutWeight(1)
          .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          .divider({ strokeWidth: 0.5, color: AppColors.separator })
          .edgeEffect(EdgeEffect.Spring)
          .linearGradientBlur(
            TitleScrollEffect.getBlurRadius(this.materialEnabled, this.titleScrollEffectProgress),
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
        }
      }
      .width('100%').height('100%')

      PanelNavBar({
        title: `浏览历史 (${this.items.length})`,
        scrollEffectProgress: this.titleScrollEffectProgress,
        rightLabel: this.items.length > 0 ? '清空' : '',
        onRightClick: (): void => {
          floatingLayerStore.showConfirm(
            '清空浏览记录',
            '确定清空所有浏览记录？此操作不可撤销。',
            '清空',
            true,
            () => {
              this.clearAll()
              appStore.showToast('已清空浏览记录')
            }
          )
        }
      })
      .width('100%').position({ x: 0, y: 0 })
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg)
  }
}
