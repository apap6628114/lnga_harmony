import { AppColors } from '../constants/Constants'
import { floatingLayerStore } from '../../store/FloatingLayerStore'
import { replyManager, ReplyManagerClass, ReplyType } from '../managers/ReplyManager'
import { appStore } from '../../store/AppStore'
import { getEmotionResource, CATEGORY_KEYS, getCategoryLabel, getCategoryNames, isEmotionCategoryNeedDarkBg } from '../media/EmotionResources'
import fileIo from '@ohos.file.fs'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { Logger, DOMAIN_UI } from '../utils/Logger'
import { KEY_IMMERSIVE_MATERIAL_ENABLED } from '../constants/AppStorageKeys'
import { UIMaterialManager } from '../managers/UIMaterialManager'

const logger = new Logger(DOMAIN_UI, 'ReplyDialog')

interface FormatAction {
  label: string
  tag: string
}

const FORMAT_ACTIONS: FormatAction[] = [
  { label: '粗体', tag: 'b' },
  { label: '斜体', tag: 'i' },
  { label: '下划线', tag: 'u' },
  { label: '删除线', tag: 'del' },
  { label: '引用', tag: 'quote' },
  { label: '链接', tag: 'url' },
  { label: '@', tag: 'at' },
  { label: '图片', tag: 'img' },
  { label: '表情', tag: 'emoticon' },
]

@Component
export struct ReplyDialog {
  @Prop dialogTitle: string = '回复'
  @Prop editMode: boolean = false
  @Prop initialContent: string = ''
  @State replyText: string = ''
  @State sending: boolean = false
  @State isAnonymous: boolean = false
  @State isCommentMode: boolean = false
  @State selStart: number = 0
  @State selEnd: number = 0
  @State showEmojiPanel: boolean = false
  @State selectedCatKey: string = 'ac'
  @StorageProp('effectiveColorMode') effectiveColorMode: string = 'light'
  @StorageProp(KEY_IMMERSIVE_MATERIAL_ENABLED) materialEnabled: boolean = true
  private textAreaController: TextAreaController = new TextAreaController()
  onSend?: (text: string, isAnony: boolean) => Promise<void>
  onClose: () => void = () => {}

  aboutToAppear(): void {
    if (this.editMode) {
      this.replyText = this.initialContent
      this.isAnonymous = replyManager.isEditMode && replyManager.targetPost !== null
        ? replyManager.targetPost.isanonymous
        : false
    } else {
      this.isCommentMode = replyManager.type === ReplyType.COMMENT
      const draft: string = replyManager.loadDraft()
      if (draft.length > 0) {
        this.replyText = draft
      }
    }
    floatingLayerStore.registerReplyCloseHandler(() => { this.requestClose() })
  }

  private requestClose(): void {
    if (this.replyText.trim().length > 0) {
      replyManager.saveDraft(this.replyText)
      floatingLayerStore.showReplyConfirm()
    } else {
      this.onClose()
    }
  }

  private onModeChange(commentMode: boolean): void {
    if (commentMode === this.isCommentMode) {
      return
    }
    if (replyManager.canToggleComment) {
      replyManager.toggleMode()
      this.isCommentMode = commentMode
    }
  }

  private applyFormat(action: FormatAction): void {
    const tag: string = action.tag
    if (tag === 'emoticon') {
      this.showEmojiPanel = !this.showEmojiPanel
      if (this.showEmojiPanel) {
        this.textAreaController.caretPosition(this.selStart)
      }
    } else if (tag === 'url') {
      this.replyText = ReplyManagerClass.insertUrl(this.replyText, this.selStart, this.selEnd)
    } else if (tag === 'at') {
      this.replyText = ReplyManagerClass.insertAtTag(this.replyText, this.selStart, this.selEnd)
    } else if (tag === 'img') {
      this.handleImagePick()
    } else {
      this.replyText = ReplyManagerClass.wrapSelectedText(this.replyText, this.selStart, this.selEnd, tag)
    }
  }

  private async handleImagePick(): Promise<void> {
    try {
      const photoPicker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker()
      const pickResult: photoAccessHelper.PhotoSelectResult = await photoPicker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      })
      const photoUris: string[] = pickResult.photoUris
      if (!photoUris || photoUris.length === 0) {
        return
      }
      const uri: string = photoUris[0]
      if (!uri || uri.length === 0) {
        return
      }
      const fileName: string = uri.split('/').pop() || 'image.jpg'
      appStore.showToast('正在上传图片...')

      let buf: ArrayBuffer = new ArrayBuffer(0)
      try {
        const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY)
        const stat = fileIo.statSync(uri)
        buf = new ArrayBuffer(stat.size)
        fileIo.readSync(file.fd, buf)
        fileIo.closeSync(file)
      } catch (readErr) {
        appStore.showToast('读取图片失败')
        return
      }

      logger.verbose('[IMGUP] calling uploadImage, size: %{public}s', String(buf.byteLength))
      const imgUrl: string = await replyManager.uploadImage(buf, fileName)
      logger.verbose('[IMGUP] upload success, url: %{public}s', imgUrl)
      const imgTag: string = '[img]./' + imgUrl + '.medium.jpg[/img]'
      this.replyText = ReplyManagerClass.insertImg(this.replyText, this.selStart, this.selEnd, imgTag)
      appStore.showToast('图片已插入')
    } catch (e) {
      const msg: string = (e as Error).message || '上传图片失败'
      logger.verbose('[IMGUP] error: %{public}s', msg)
      appStore.showToast(msg)
    }
  }

  private doSend(): void {
    if (!this.onSend || (!this.replyText.trim() && !replyManager.shouldQuote)) {
      return
    }
    if (this.isCommentMode) {
      const byteLen: number = this.getByteLength(this.replyText.trim())
      if (byteLen < 6 || byteLen > 650) {
        appStore.showToast('贴条长度需在6~650字节之间')
        return
      }
    }
    this.sending = true
    this.onSend(this.replyText.trim(), this.isAnonymous).then(() => {
      replyManager.clearDraft()
      this.onClose()
    }).finally(() => {
      this.sending = false
    })
  }

  private getByteLength(str: string): number {
    let len: number = 0
    for (let i: number = 0; i < str.length; i++) {
      const code: number = str.charCodeAt(i)
      if (code <= 0x7f) { len++ }
      else if (code <= 0x7ff) { len += 2 }
      else if (code <= 0xffff) { len += 3 }
      else { len += 4 }
    }
    return len
  }

  build() {
    Column() {
      // 拖拽指示条
      Row() {
        Blank()
        Divider().width(36).height(3).borderRadius(2).margin({ top: 6, bottom: 4 })
        Blank()
      }.width('100%')

      // 标题行：模式切换 + 取消
      Row() {
        if (!this.editMode && replyManager.canToggleComment) {
          Row() {
            Text('回复')
              .fontSize(14).fontWeight(this.isCommentMode ? FontWeight.Regular : FontWeight.Bold)
              .fontColor(this.isCommentMode ? AppColors.textTertiary : AppColors.white)
              .padding({ left: 14, right: 14, top: 5, bottom: 5 })
              .backgroundColor(this.isCommentMode ? AppColors.bgSecondary : AppColors.primary)
              .borderRadius({ topLeft: 14, bottomLeft: 14 })
              .onClick(() => { this.onModeChange(false) })

            Text('贴条')
              .fontSize(14).fontWeight(this.isCommentMode ? FontWeight.Bold : FontWeight.Regular)
              .fontColor(this.isCommentMode ? AppColors.white : AppColors.textTertiary)
              .padding({ left: 14, right: 14, top: 5, bottom: 5 })
              .backgroundColor(this.isCommentMode ? AppColors.primary : AppColors.bgSecondary)
              .borderRadius({ topRight: 14, bottomRight: 14 })
              .onClick(() => { this.onModeChange(true) })
          }
          .alignItems(VerticalAlign.Center)
        } else {
          Text(this.dialogTitle).fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppColors.textPrimary)
        }

        Blank().layoutWeight(1)

        Text('取消').fontSize(15).fontColor(AppColors.textSecondary)
          .onClick(() => { this.requestClose() }).padding({ left: 8, right: 4 })
      }
      .width('100%').padding({ left: 16, right: 12, top: 6, bottom: 6 })

      // 贴条提示
      if (this.isCommentMode) {
        Row() {
          Text('贴条将附着在该楼层下方（6~650字节）')
            .fontSize(11).fontColor(AppColors.textTertiary)
        }.width('100%').padding({ top: 2, bottom: 2 })
      }

      // 格式工具栏（自动换行）
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(FORMAT_ACTIONS, (action: FormatAction) => {
          Text(action.label)
            .fontSize(13).fontColor(AppColors.primary)
            .fontWeight(FontWeight.Medium)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(4)
            .backgroundColor(AppColors.bgSecondary)
            .margin({ right: 5, bottom: 4 })
            .onClick(() => { this.applyFormat(action) })
        }, (action: FormatAction) => action.tag)
      }
      .width('100%').padding({ top: 4, bottom: 2 })

      // 表情面板
      if (this.showEmojiPanel) {
        Column() {
          // 分类标签-左对齐换行，同工具栏
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(CATEGORY_KEYS, (key: string) => {
              Text(getCategoryLabel(key))
                .fontSize(12)
                .fontColor(key === this.selectedCatKey ? AppColors.white : AppColors.textSecondary)
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .backgroundColor(key === this.selectedCatKey ? AppColors.primary : AppColors.bgSecondary)
                .borderRadius(10)
                .margin({ right: 6, bottom: 4 })
                .onClick(() => {
                  this.selectedCatKey = key
                })
            }, (key: string) => key)
          }
          .padding({ left: 2, right: 2 })

          // 表情网格-X轴居中
          Scroll() {
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
              ForEach(getCategoryNames(this.selectedCatKey), (name: string) => {
                Column() {
                  Image(getEmotionResource(this.selectedCatKey, name))
                    .width(45).height(45).objectFit(ImageFit.Contain)
                    .backgroundColor(this.effectiveColorMode === 'dark' && isEmotionCategoryNeedDarkBg(this.selectedCatKey)
                      ? Color.White : Color.Transparent)
                }
                .width(60).height(60)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .borderRadius(4)
                .onClick(() => {
                  const code: string = '[s:' + this.selectedCatKey + ':' + name + ']'
                  this.replyText = ReplyManagerClass.insertEmoticon(this.replyText, this.selStart, this.selEnd, code)
                  this.selStart = this.selStart + code.length
                  this.selEnd = this.selStart
                })
              }, (name: string) => this.selectedCatKey + '_' + name)
            }
          }
          .layoutWeight(1)
          .padding({ left: 2, right: 2 })
          .scrollable(ScrollDirection.Vertical)
        }
        .constraintSize({ maxHeight: 240 }).width('100%').padding({ top: 4, bottom: 2 })

        Divider().width('100%').height(1).color(AppColors.separator).margin({ top: 6, bottom: 8 })
      }

      // 正文输入
      TextArea({ text: this.replyText, placeholder: '输入内容...', controller: this.textAreaController })
        .width('100%').height(220).padding(12).fontSize(15)
        .borderRadius(8).backgroundColor(this.materialEnabled ? Color.Transparent : AppColors.bgSecondary)
        .systemMaterial(this.materialEnabled ? UIMaterialManager.inputMaterial : undefined)
        .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
        .onChange((value: string) => { this.replyText = value })
        .onTextSelectionChange((start: number, end: number) => {
          this.selStart = start
          this.selEnd = end
        })

      // 底栏：匿名 + 发送/保存
      Row() {
        Row() {
          Toggle({ type: ToggleType.Checkbox, isOn: this.isAnonymous })
            .width(16).height(16)
            .onChange((value: boolean) => { this.isAnonymous = value })
          Text('匿名').fontSize(11).fontColor(AppColors.textTertiary).margin({ left: 3 })
        }
        .alignItems(VerticalAlign.Center)

        Blank().layoutWeight(1)

        Button(this.sending ? '...' : (this.editMode ? '保存' : '发送'))
          .fontSize(14).fontWeight(FontWeight.Medium).height(34)
          .fontColor(AppColors.white)
          .backgroundColor(this.materialEnabled ? Color.Transparent : AppColors.primary)
          .systemMaterial(this.materialEnabled ? UIMaterialManager.buttonMaterial : undefined)
          .borderRadius(17).padding({ left: 20, right: 20 })
          .enabled(!this.sending && (this.editMode || this.replyText.trim().length > 0 || replyManager.shouldQuote))
          .onClick(() => { this.doSend() })
      }
      .width('100%').margin({ top: 6, bottom: 4 }).alignItems(VerticalAlign.Center)
    }
    .width('100%').constraintSize({ maxWidth: 576 }).padding({ left: 16, right: 16, bottom: 16 })
    .backgroundColor(this.materialEnabled ? Color.Transparent : AppColors.bg).borderRadius(16)
    .systemMaterial(this.materialEnabled ? UIMaterialManager.surfaceMaterial : undefined)
  }
}
