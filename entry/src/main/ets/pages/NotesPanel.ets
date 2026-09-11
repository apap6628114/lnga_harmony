import { appStore } from '../store/AppStore'
import type { UserNoteEntry } from '../model/NoteInfo'
import { display, AlertDialog, CustomContentDialog } from '@kit.ArkUI'
import { AppColors } from '../common/constants/Constants'
import { escHtml } from '../common/utils/Utils'
import { unescapeHtml } from '../parser/_shared/HtmlEntityCodec'
import { NotesDataSource } from '../common/datasource/LazyDataSource'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { NoteEditorContent, NoteAddContent } from '../common/dialogs/Dialogs'
import { floatingLayerStore, FloatingPage } from '../store/FloatingLayerStore'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'

@Component
export struct NotesPanel {
  @State removeTarget: UserNoteEntry | null = null
  @State editTarget: UserNoteEntry | null = null
  @State notesCount: number = 0
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @StorageProp('navBarHeight') navBarHeight: number = 0
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 列表当前视口高度。 */
  @State listViewportHeight: number = 1

  /** 用户备注列表滚动控制器。 */
  private scroller: Scroller = new Scroller()
  private notesDataSource: NotesDataSource = new NotesDataSource()

  /** 编辑备注弹窗的备注输入（供 CustomContentDialog 内容构件双向绑定）。 */
  @State noteDialogText: string = ''
  /** 新增备注弹窗的昵称与 UID 输入。 */
  @State addNoteNickName: string = ''
  @State addNoteUid: string = ''

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

  noteDialogController?: CustomDialogController
  addDialogController?: CustomDialogController

  deleteDialogController?: CustomDialogController = new CustomDialogController({
    builder: AlertDialog({
      primaryTitle: '删除备注',
      content: '确定要删除该用户的备注吗？',
      primaryButton: {
        value: '删除',
        fontColor: AppColors.white,
        background: AppColors.destructive,
        action: () => {
          if (this.removeTarget) {
            appStore.settingsStore.removeNote(this.removeTarget.userId)
            this.refreshNotes()
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

  /** 编辑备注弹窗的自定义内容（官方 CustomContentDialog 的 contentBuilder）。 */
  @Builder
  noteEditorContent() {
    NoteEditorContent({
      noteText: this.noteDialogText,
      userName: this.editTarget ? this.editTarget.nickName : '',
      onNoteChange: (value: string): void => { this.noteDialogText = value }
    })
  }

  /** 新增备注弹窗的自定义内容。 */
  @Builder
  addNoteContent() {
    NoteAddContent({
      nickName: this.addNoteNickName,
      uid: this.addNoteUid,
      onNickNameChange: (value: string): void => { this.addNoteNickName = value },
      onUidChange: (value: string): void => { this.addNoteUid = value }
    })
  }

  private showEditNote(entry: UserNoteEntry): void {
    this.editTarget = entry
    this.noteDialogText = entry.note
    this.noteDialogController = new CustomDialogController({
      builder: CustomContentDialog({
        primaryTitle: '编辑备注',
        contentBuilder: this.noteEditorContent,
        buttons: [
          { value: '取消' },
          {
            value: '确认',
            fontColor: AppColors.white,
            background: AppColors.primary,
            action: (): void => {
              const note: string = this.noteDialogText
              if (note.length >= 1 && note.length <= 20) {
                appStore.settingsStore.addOrUpdateNote(entry.userId, entry.nickName, note)
                appStore.showToast('备注已保存')
                this.editTarget = null
                this.refreshNotes()
              } else {
                appStore.showToast('备注需 1~20 字')
              }
            }
          }
        ]
      }),
      autoCancel: true
    })
    this.noteDialogController.open()
  }

  aboutToDisappear(): void {
    this.deleteDialogController = undefined
    this.noteDialogController = undefined
    this.addDialogController = undefined
  }

  aboutToAppear(): void {
    this.refreshNotes()
  }

  private refreshNotes(): void {
    this.notesCount = appStore.settings.notes.length
    this.notesDataSource.replaceAll(appStore.settings.notes)
    if (this.notesCount === 0) {
      this.titleScrollEffectProgress = 0
    }
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

  build() {
    Stack() {
      Column() {
        if (this.notesCount === 0) {
          Row().width('100%').height(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          Column() {
            Image($r('app.media.icon_text_fields')).width(40).height(40).fillColor(AppColors.textTertiary).opacity(0.4)
            Text('暂无备注').fontSize(15).fontColor(AppColors.textTertiary).margin({ top: 8 })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else {
          List({ scroller: this.scroller }) {
            ListItem() {
              Row() {
                Text('共 ' + String(this.notesCount) + ' 条备注').fontSize(13).fontColor(AppColors.textTertiary).layoutWeight(1)
                Text('删除全部').fontSize(13).fontColor(AppColors.destructive)
                  .onClick(() => {
                    appStore.settingsStore.removeAllNotes()
                    this.refreshNotes()
                    appStore.showToast('已清空备注')
                  })
              }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
            }
            LazyForEach(this.notesDataSource, (entry: UserNoteEntry) => {
              ListItem() {
                Row() {
                  Stack() {
                    Image($r('app.media.icon_person')).width(20).height(20).fillColor(AppColors.textTertiary)
                  }
                  .width(40).height(40).borderRadius(20).backgroundColor(AppColors.bgSecondary)

                  Column() {
                    Row() {
                      Text(unescapeHtml(entry.nickName)).fontSize(15).fontColor(AppColors.textPrimary)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      if (entry.note.length > 0) {
                        Text('(' + entry.note + ')')
                          .fontSize(13).fontColor(AppColors.warning).margin({ left: 4 })
                      }
                    }
                    Text('UID: ' + escHtml(entry.userId)).fontSize(13).fontColor(AppColors.textTertiary).margin({ top: 2 })
                  }
                  .layoutWeight(1).margin({ left: 12 }).alignItems(HorizontalAlign.Start)
                  .onClick((event: ClickEvent) => {
                    this.showProfileCard(entry.userId, event.windowX, event.windowY)
                  })

                  Stack() {
                    Image($r('app.media.icon_compose')).width(18).height(18).fillColor(AppColors.primary)
                  }
                  .width(36).height(36)
                  .onClick(() => { this.showEditNote(entry) })

                  Stack() {
                    Image($r('app.media.icon_delete')).width(18).height(18).fillColor(AppColors.destructive)
                  }
                  .width(36).height(36)
                  .onClick(() => {
                    this.removeTarget = entry
                    this.deleteDialogController?.open()
                  })
                }
                .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 }).alignItems(VerticalAlign.Center)
              }
            }, (entry: UserNoteEntry) => entry.userId)
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

      PanelNavBar({ title: '用户备注', rightIcon: $r('app.media.icon_nav_add'),
        rightIconAccessibilityText: '添加用户备注', scrollEffectProgress: this.titleScrollEffectProgress,
        onRightClick: (): void => {
        this.addNoteNickName = ''
        this.addNoteUid = ''
        this.addDialogController = new CustomDialogController({
          builder: CustomContentDialog({
            primaryTitle: '添加备注',
            contentBuilder: this.addNoteContent,
            buttons: [
              { value: '取消' },
              {
                value: '确定添加',
                fontColor: AppColors.white,
                background: AppColors.primary,
                action: (): void => {
                  const nickName: string = this.addNoteNickName.trim()
                  const uid: string = this.addNoteUid.trim()
                  if (nickName.length > 0 && uid.length > 0) {
                    appStore.settingsStore.addOrUpdateNote(uid, nickName, '')
                    this.refreshNotes()
                    appStore.showToast('已添加备注')
                  } else {
                    appStore.showToast('请填写昵称与 UID')
                  }
                }
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
