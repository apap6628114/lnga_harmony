/**
 * 黑名单管理面板
 */

import { appStore } from '../store/AppStore'
import type { BlacklistEntry } from '../model/SocialEntries'
import { display, AlertDialog, CustomContentDialog } from '@kit.ArkUI'
import { AppColors } from '../common/constants/Constants'
import { escHtml } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { BlacklistDataSource } from '../common/datasource/LazyDataSource'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { EmptyStateView } from '../common/components/PageStateView'
import { BlacklistEditorContent } from '../common/dialogs/Dialogs'
import { normalizeBlacklistUserId } from '../common/utils/BlacklistUtils'
import { floatingLayerStore, FloatingPage } from '../store/FloatingLayerStore'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'
import { UIMaterialManager } from '../common/managers/UIMaterialManager'

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

  /** 添加黑名单弹窗的 UID 输入（供 CustomContentDialog 内容构件双向绑定）。 */
  @State addBlacklistUid: string = ''

  deleteDialogController?: CustomDialogController = new CustomDialogController({
    backgroundColor: Color.Transparent,
    systemMaterial: UIMaterialManager.dialogMaterial,
    builder: AlertDialog({
      primaryTitle: '移除黑名单',
      content: '确定要将其从黑名单中移除吗？',
      primaryButton: {
        value: '移除',
        fontColor: AppColors.white,
        background: AppColors.destructive,
        action: () => {
          if (this.removeTarget) {
            appStore.settingsStore.removeBlacklist(this.removeTarget.userId)
            this.removeTarget = null
          }
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {
          this.removeTarget = null
        }
      }
    }),
    autoCancel: true
  })

  /** 清空黑名单确认对话框。 */
  clearDialogController?: CustomDialogController = new CustomDialogController({
    backgroundColor: Color.Transparent,
    systemMaterial: UIMaterialManager.dialogMaterial,
    builder: AlertDialog({
      primaryTitle: '清空黑名单',
      content: '确定要清空全部黑名单吗？此操作无法撤销。',
      primaryButton: {
        value: '清空',
        fontColor: AppColors.white,
        background: AppColors.destructive,
        action: () => {
          if (appStore.settingsStore.removeAllBlacklist()) {
            appStore.showToast('已清空黑名单')
          }
        }
      },
      secondaryButton: {
        value: '取消'
      }
    }),
    autoCancel: true
  })

  /** 添加黑名单弹窗的自定义内容。 */
  @Builder
  addBlacklistContent() {
    BlacklistEditorContent({
      uid: this.addBlacklistUid,
      currentUserId: appStore.auth.uid,
      existingUserIds: appStore.settings.blacklist.map((entry: BlacklistEntry): string => entry.userId),
      onUidChange: (value: string): void => { this.addBlacklistUid = value }
    })
  }

  /**
   * 提交新增黑名单。
   *
   * 官方对话框模板的按钮不支持动态禁用，原先「校验不通过时按钮半透明」的即时反馈
   * 改为提交时校验并以 Toast 提示；校验规则与迁移前一致。
   */
  private submitAddBlacklist(): void {
    const normalizedUserId: string | null = normalizeBlacklistUserId(this.addBlacklistUid)
    if (normalizedUserId === null) {
      appStore.showToast('UID 必须是大于 0 的整数')
      return
    }
    if (normalizedUserId === normalizeBlacklistUserId(appStore.auth.uid)) {
      appStore.showToast('不能将自己加入黑名单')
      return
    }
    const existing: string[] = appStore.settings.blacklist.map((entry: BlacklistEntry): string => entry.userId)
    if (existing.indexOf(normalizedUserId) >= 0) {
      appStore.showToast('该用户已在黑名单中')
      return
    }
    if (appStore.settingsStore.addBlacklist({ userId: normalizedUserId, nickName: `User${normalizedUserId}` })) {
      appStore.showToast('已加入黑名单')
    } else {
      appStore.showToast('该用户无法加入黑名单')
    }
  }

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
        this.addBlacklistUid = ''
        this.addDialogController = new CustomDialogController({
          backgroundColor: Color.Transparent,
          systemMaterial: UIMaterialManager.dialogMaterial,
          builder: CustomContentDialog({
            primaryTitle: '添加黑名单',
            contentBuilder: this.addBlacklistContent,
            buttons: [
              { value: '取消' },
              {
                value: '确定添加',
                fontColor: AppColors.white,
                background: AppColors.primary,
                action: (): void => { this.submitAddBlacklist() }
              }
            ]
          }),
          autoCancel: true
        })
        this.addDialogController.open()
        } })
        .width('100%').position({ x: 0, y: 0 })
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg)
  }
}
