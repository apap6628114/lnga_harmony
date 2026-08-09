/**
 * 黑名单管理面板
 */

import { appStore } from '../store/AppStore'
import type { BlacklistEntry } from '../model/SocialEntries'
import { display } from '@kit.ArkUI'
import { AppColors } from '../common/constants/Constants'
import { escHtml } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { BlacklistDataSource } from '../common/datasource/LazyDataSource'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { EmptyStateView } from '../common/components/PageStateView'
import { ConfirmDialog, AddBlacklistDialog } from '../common/dialogs/Dialogs'
import { floatingLayerStore, FloatingPage } from '../store/FloatingLayerStore'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'

@Component
export struct BlacklistPanel {
  @State removeTarget: BlacklistEntry | null = null
  @State blacklistCount: number = 0
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @StorageProp('navBarHeight') navBarHeight: number = 0
  /** 是否启用沉浸式材质。 */
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 列表当前视口高度。 */
  @State listViewportHeight: number = 1
  /** 黑名单变更版本号。 */
  @StorageProp('blacklistVersion') @Watch('onBlacklistVersionChange') blacklistVersion: number = 0

  /** 黑名单列表滚动控制器。 */
  private scroller: Scroller = new Scroller()
  private blacklistDataSource: BlacklistDataSource = new BlacklistDataSource()

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

  addDialogController?: CustomDialogController

  deleteDialogController?: CustomDialogController = new CustomDialogController({
    builder: ConfirmDialog({
      title: '移除黑名单',
      message: '确定要将其从黑名单中移除吗？',
      confirmLabel: '移除',
      destructive: true,
      onConfirm: () => {
        if (this.removeTarget) {
          appStore.settingsStore.removeBlacklist(this.removeTarget.userId)
          this.removeTarget = null
        }
      },
      onCancel: () => {
        this.removeTarget = null
      }
    }),
    autoCancel: true,
    customStyle: true
  })

  /** 清空黑名单确认对话框。 */
  clearDialogController?: CustomDialogController = new CustomDialogController({
    builder: ConfirmDialog({
      title: '清空黑名单',
      message: '确定要清空全部黑名单吗？此操作无法撤销。',
      confirmLabel: '清空',
      destructive: true,
      onConfirm: () => {
        if (appStore.settingsStore.removeAllBlacklist()) {
          appStore.showToast('已清空黑名单')
        }
      },
      onCancel: () => {}
    }),
    autoCancel: true,
    customStyle: true
  })

  aboutToDisappear(): void {
    this.deleteDialogController = undefined
    this.clearDialogController = undefined
    this.addDialogController = undefined
  }

  aboutToAppear(): void {
    this.refreshBlacklist()
  }

  /** 响应黑名单变更并刷新管理列表。 */
  private onBlacklistVersionChange(): void {
    this.refreshBlacklist()
  }

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

  private refreshBlacklist(): void {
    this.blacklistCount = appStore.settings.blacklist.length
    this.blacklistDataSource.replaceAll(appStore.settings.blacklist)
    if (this.blacklistCount === 0) {
      this.titleScrollEffectProgress = 0
    }
  }

  build() {
    Stack() {
      Column() {
        if (this.blacklistCount === 0) {
          Row().width('100%').height(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          Column() {
            EmptyStateView({ msg: '黑名单为空', icon: $r('app.media.icon_block') })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else {
          List({ scroller: this.scroller }) {
            ListItem() {
              Row() {
                Text('共 ' + String(this.blacklistCount) + ' 人').fontSize(13).fontColor(AppColors.textTertiary).layoutWeight(1)
                Text('删除全部').fontSize(13).fontColor(AppColors.destructive)
                  .onClick(() => {
                    this.clearDialogController?.open()
                  })
              }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
            }
            LazyForEach(this.blacklistDataSource, (entry: BlacklistEntry) => {
              ListItem() {
                Row() {
                  Stack() {
                    Image($r('app.media.icon_person')).width(20).height(20).fillColor(AppColors.textTertiary)
                  }
                  .width(40).height(40).borderRadius(20).backgroundColor(AppColors.bgSecondary)

                  Column() {
                    Text(unescapeHtml(entry.nickName)).fontSize(15).fontColor(AppColors.textPrimary)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`UID: ${escHtml(entry.userId)}`).fontSize(13).fontColor(AppColors.textTertiary).margin({ top: 2 })
                  }
                  .layoutWeight(1).margin({ left: 12 }).alignItems(HorizontalAlign.Start)
                  .onClick((event: ClickEvent) => {
                    this.showProfileCard(entry.userId, event.windowX, event.windowY)
                  })

                  Stack() {
                    Image($r('app.media.icon_delete')).width(18).height(18).fillColor(AppColors.destructive)
                  }
                  .width(40).height(40)
                  .onClick(() => {
                    this.removeTarget = entry
                    this.deleteDialogController?.open()
                  })
                }
                .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 }).alignItems(VerticalAlign.Center)
              }
            }, (entry: BlacklistEntry) => entry.userId)
          }
          .width('100%').layoutWeight(1)
          .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          .divider({ strokeWidth: 0.5, color: AppColors.separator })
          .edgeEffect(EdgeEffect.Spring)
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
        }
      }
      .width('100%').height('100%')

      PanelNavBar({ title: '黑名单管理', rightIcon: $r('app.media.icon_nav_add'),
        rightIconAccessibilityText: '添加黑名单', scrollEffectProgress: this.titleScrollEffectProgress,
        onRightClick: (): void => {
        this.addDialogController = new CustomDialogController({
          builder: AddBlacklistDialog({
            currentUserId: appStore.auth.uid,
            existingUserIds: appStore.settings.blacklist.map((entry: BlacklistEntry): string => entry.userId),
            onConfirm: (uid: string): void => {
              if (appStore.settingsStore.addBlacklist({ userId: uid, nickName: `User${uid}` })) {
                appStore.showToast('已加入黑名单')
              } else {
                appStore.showToast('该用户无法加入黑名单')
              }
            }
          }),
          autoCancel: true,
          customStyle: true,
          alignment: DialogAlignment.Center
        })
        this.addDialogController.open()
        } })
        .width('100%').position({ x: 0, y: 0 })
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg)
  }
}
