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

@Component
export struct BrowseHistoryPanel {
  @State items: BrowseHistoryEntry[] = []
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @StorageProp('browseHistoryVersion') browseHistoryVersion: number = 0
  /** 黑名单变更版本号。 */
  @StorageProp('blacklistVersion') blacklistVersion: number = 0
  private historyDataSource: HistoryItemDataSource = new HistoryItemDataSource()

  aboutToAppear(): void {
    this.loadHistory()
  }

  private async loadHistory(): Promise<void> {
    if (!appStore.auth.isAuthenticated) {
      this.items = []
      this.historyDataSource.clear()
      return
    }
    try {
      this.items = await appStore.getBrowseHistory(appStore.auth.uid)
      this.historyDataSource.replaceAll(this.items as object[])
    } catch (e) {
      this.items = []
    }
  }

  private async removeItem(tid: string): Promise<void> {
    this.items = this.items.filter((item: BrowseHistoryEntry) => item.tid !== tid)
    this.historyDataSource.replaceAll(this.items as object[])
    await appStore.removeBrowseHistory(appStore.auth.uid, tid)
  }

  private async clearAll(): Promise<void> {
    this.items = []
    this.historyDataSource.clear()
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
          Row().width('100%').height(44 + this.statusBarHeight)
          Column() {
            Image($r('app.media.icon_clock')).width(40).height(40).fillColor(AppColors.textTertiary).opacity(0.4).margin({ bottom: 12 })
            Text('暂无浏览记录').fontSize(15).fontColor(AppColors.textTertiary)
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else {
          List() {
            ListItem() {
              Row().width('100%').height(44 + this.statusBarHeight)
            }
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
          .layoutWeight(1).divider({ strokeWidth: 0.5, color: AppColors.separator })
        }
      }
      .width('100%').height('100%')

      PanelNavBar({
        title: `浏览历史 (${this.items.length})`,
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
