import { AppColors } from '../constants/Constants'
import { floatingLayerStore } from '../../store/FloatingLayerStore'
import { replyManager, ReplyManagerClass, ReplyType } from '../managers/ReplyManager'
import { appStore } from '../../store/AppStore'
import {
  getEmotionResource,
  CATEGORY_KEYS,
  getCategoryLabel,
  getCategoryNames,
  isEmotionCategoryNeedDarkBg
} from '../media/EmotionResources'
import fileIo from '@ohos.file.fs'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { Logger, DOMAIN_UI } from '../utils/Logger'
import { UIMaterialManager } from '../managers/UIMaterialManager'

const logger = new Logger(DOMAIN_UI, 'ReplyDialog')

/** 回复编辑器格式操作。 */
interface FormatAction {
  /** 显示文案。 */
  label: string

  /** BBCode 标签。 */
  tag: string
}

/** 回复编辑器支持的格式操作。 */
const FORMAT_ACTIONS: FormatAction[] = [
  { label: '表情', tag: 'emoticon' },
  { label: '粗体', tag: 'b' },
  { label: '斜体', tag: 'i' },
  { label: '下划线', tag: 'u' },
  { label: '删除线', tag: 'del' },
  { label: '引用', tag: 'quote' },
  { label: '链接', tag: 'url' },
  { label: '@', tag: 'at' },
  { label: '图片', tag: 'img' },
]

/** 使用沉浸光感材质承载帖子回复、贴条与编辑操作。 */
@Component
export struct ReplyDialog {
  /** 对话框标题。 */
  @Prop dialogTitle: string = '回复'

  /** 是否编辑既有回复。 */
  @Prop editMode: boolean = false

  /** 编辑模式下的初始正文。 */
  @Prop initialContent: string = ''

  /** 当前窗口断点。 */
  @Prop currentBreakpoint: string = 'sm'

  /** 回复正文。 */
  @State replyText: string = ''

  /** 是否正在提交。 */
  @State sending: boolean = false

  /** 是否匿名发布。 */
  @State isAnonymous: boolean = false

  /** 是否使用贴条模式。 */
  @State isCommentMode: boolean = false

  /** 当前选区起点。 */
  @State selStart: number = 0

  /** 当前选区终点。 */
  @State selEnd: number = 0

  /** 是否展示表情面板。 */
  @State showEmojiPanel: boolean = false

  /** 当前表情分类。 */
  @State selectedCatKey: string = 'ac'

  /** 当前有效明暗色模式。 */
  @StorageProp('effectiveColorMode') effectiveColorMode: string = 'light'

  /** 正文输入框控制器。 */
  private textAreaController: TextAreaController = new TextAreaController()

  /** 提交回调。 */
  onSend?: (text: string, isAnony: boolean) => Promise<void>

  /** 关闭回调。 */
  onClose: () => void = () => {}

  /** 初始化编辑模式、草稿与浮层关闭处理器。 */
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

  /** 请求关闭编辑器，并在存在正文时保留草稿。 */
  private requestClose(): void {
    if (this.replyText.trim().length > 0) {
      replyManager.saveDraft(this.replyText)
      floatingLayerStore.showReplyConfirm()
    } else {
      // 内容为空时清掉旧草稿，避免下次打开又恢复已删除的内容
      replyManager.clearDraft()
      this.onClose()
    }
  }

  /** 切换回复与贴条模式。 */
  private onModeChange(commentMode: boolean): void {
    if (commentMode === this.isCommentMode) {
      return
    }
    if (replyManager.canToggleComment) {
      replyManager.toggleMode()
      this.isCommentMode = commentMode
    }
  }

  /** 将选定格式应用到当前正文选区。 */
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

  /** 选择并上传图片，然后将图片标签插入正文。 */
  private async handleImagePick(): Promise<void> {
    try {
      const photoPicker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker()
      const pickResult: photoAccessHelper.PhotoSelectResult = await photoPicker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      })
      const photoUris: string[] = pickResult.photoUris
      if (photoUris.length === 0) {
        return
      }
      const uri: string = photoUris[0]
      if (uri.length === 0) {
        return
      }
      const fileName: string = uri.split('/').pop() ?? 'image.jpg'
      appStore.showToast('正在上传图片...')

      let buffer: ArrayBuffer = new ArrayBuffer(0)
      try {
        const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY)
        const stat = fileIo.statSync(uri)
        buffer = new ArrayBuffer(stat.size)
        fileIo.readSync(file.fd, buffer)
        fileIo.closeSync(file)
      } catch (readError) {
        logger.verbose('[IMGUP] read error: %{public}s', String(readError))
        appStore.showToast('读取图片失败')
        return
      }

      logger.verbose('[IMGUP] calling uploadImage, size: %{public}s', String(buffer.byteLength))
      const imageUrl: string = await replyManager.uploadImage(buffer, fileName)
      logger.verbose('[IMGUP] upload success, url: %{public}s', imageUrl)
      const imageTag: string = '[img]./' + imageUrl + '.medium.jpg[/img]'
      this.replyText = ReplyManagerClass.insertImg(this.replyText, this.selStart, this.selEnd, imageTag)
      appStore.showToast('图片已插入')
    } catch (error) {
      const message: string = error instanceof Error ? error.message : '上传图片失败'
      logger.verbose('[IMGUP] error: %{public}s', message)
      appStore.showToast(message)
    }
  }

  /** 校验正文并提交回复。 */
  private doSend(): void {
    if (this.onSend === undefined || (this.replyText.trim().length === 0 && !replyManager.shouldQuote)) {
      return
    }
    if (this.isCommentMode) {
      const byteLength: number = this.getByteLength(this.replyText.trim())
      if (byteLength < 6 || byteLength > 650) {
        appStore.showToast('贴条长度需在6~650字节之间')
        return
      }
    }
    this.sending = true
    this.onSend(this.replyText.trim(), this.isAnonymous).then(() => {
      replyManager.clearDraft()
      this.onClose()
    }).catch(() => {
      // 发送失败：保留内容与草稿（错误提示已由发送方 Toast 完成）
    }).finally(() => {
      this.sending = false
    })
  }

  /**
   * 计算 UTF-8 字节长度。
   *
   * @param str - 待计算文本
   * @returns 文本占用的 UTF-8 字节数
   */
  private getByteLength(str: string): number {
    let length: number = 0
    for (let index: number = 0; index < str.length; index++) {
      const code: number = str.charCodeAt(index)
      if (code <= 0x7f) {
        length++
      } else if (code <= 0x7ff) {
        length += 2
      } else if (code <= 0xffff) {
        length += 3
      } else {
        length += 4
      }
    }
    return length
  }

  /** 获取编辑器底部的实时内容统计。 */
  private getContentMetric(): string {
    const content: string = this.replyText.trim()
    if (this.isCommentMode) {
      return this.getByteLength(content).toString() + ' / 650 字节'
    }
    return content.length.toString() + ' 字'
  }

  /** 获取当前主操作文案。 */
  private getSubmitLabel(): string {
    if (this.sending) {
      return '发送中…'
    }
    if (this.editMode) {
      return '保存修改'
    }
    return this.isCommentMode ? '发布贴条' : '发送回复'
  }

  /** 构建回复编辑界面。 */
  build() {
    Column() {
      Row() {
        Blank()
        Divider()
          .width(40)
          .height(4)
          .color(AppColors.sheetIndicator)
          .borderRadius(2)
          .margin({ top: 8, bottom: 8 })
        Blank()
      }
      .width('100%')

      Row() {
        Column() {
          Text(this.dialogTitle)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(UIMaterialManager.adaptiveForeground)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (!this.editMode && replyManager.canToggleComment) {
            Row() {
              Text('回复')
                .fontSize(14)
                .fontWeight(this.isCommentMode ? FontWeight.Regular : FontWeight.Bold)
                .fontColor(this.isCommentMode ? UIMaterialManager.adaptiveSecondaryForeground : AppColors.white)
                .width(64)
                .height(32)
                .textAlign(TextAlign.Center)
                .backgroundColor(this.isCommentMode ? Color.Transparent : AppColors.primary)
                .onClick(() => { this.onModeChange(false) })

              Text('贴条')
                .fontSize(14)
                .fontWeight(this.isCommentMode ? FontWeight.Bold : FontWeight.Regular)
                .fontColor(this.isCommentMode ? AppColors.white : UIMaterialManager.adaptiveSecondaryForeground)
                .width(64)
                .height(32)
                .textAlign(TextAlign.Center)
                .backgroundColor(this.isCommentMode ? AppColors.primary : Color.Transparent)
                .onClick(() => { this.onModeChange(true) })
            }
            .height(32)
            .borderRadius(16)
            .clip(true)
            .backgroundColor(Color.Transparent)
            .systemMaterial(UIMaterialManager.inputMaterial)
            .alignItems(VerticalAlign.Center)
            .margin({ top: 7 })
          } else {
            Text(this.editMode ? '调整内容后保存修改' : '参与帖子讨论')
              .fontSize(11)
              .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
              .margin({ top: 2 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ right: 12 })

        Button('取消')
          .type(ButtonType.Capsule)
          .height(36)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(UIMaterialManager.adaptiveForeground)
          .backgroundColor(Color.Transparent)
          .systemMaterial(UIMaterialManager.inputMaterial)
          .padding({ left: 16, right: 16 })
          .onClick(() => { this.requestClose() })
      }
      .width('100%')
      .padding({ bottom: 12 })
      .alignItems(VerticalAlign.Center)

      if (this.isCommentMode) {
        Row() {
          Text('贴条')
            .fontSize(10)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColors.primary)
            .backgroundColor(AppColors.primaryLight)
            .borderRadius(8)
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          Text('贴条将附着在该楼层下方（6~650字节）')
            .fontSize(11)
            .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
            .margin({ left: 7 })
        }
        .width('100%')
        .padding({ left: 2, bottom: 8 })
        .alignItems(VerticalAlign.Center)
      }

      Column() {
        Row() {
          Text('格式工具')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
          Blank().layoutWeight(1)
          Text(this.showEmojiPanel ? '表情面板已展开' : '左右滑动查看更多')
            .fontSize(10)
            .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
        }
        .width('100%')
        .padding({ left: 4, right: 4, bottom: 6 })

        Scroll() {
          Row({ space: 6 }) {
            ForEach(FORMAT_ACTIONS, (action: FormatAction) => {
              Text(action.label)
                .fontSize(13)
                .fontColor(action.tag === 'emoticon' && this.showEmojiPanel
                  ? AppColors.primary : UIMaterialManager.adaptiveForeground)
                .fontWeight(action.tag === 'emoticon' && this.showEmojiPanel
                  ? FontWeight.Bold : FontWeight.Medium)
                .height(32)
                .padding({ left: 12, right: 12 })
                .borderRadius(10)
                .backgroundColor(action.tag === 'emoticon' && this.showEmojiPanel
                  ? AppColors.primaryLight : Color.Transparent)
                .border({ width: 0.5, color: AppColors.separator })
                .onClick(() => { this.applyFormat(action) })
            }, (action: FormatAction) => action.tag)
          }
          .padding({ left: 2, right: 2 })
        }
        .width('100%')
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })
      .borderRadius(14)
      .backgroundColor(Color.Transparent)
      .systemMaterial(UIMaterialManager.inputMaterial)
      .margin({ bottom: 10 })

      if (this.showEmojiPanel) {
        Column() {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(CATEGORY_KEYS, (key: string) => {
              Text(getCategoryLabel(key))
                .fontSize(12)
                .fontColor(key === this.selectedCatKey
                  ? AppColors.white : UIMaterialManager.adaptiveSecondaryForeground)
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .backgroundColor(key === this.selectedCatKey ? AppColors.primary : Color.Transparent)
                .border({ width: 0.5, color: AppColors.separator })
                .borderRadius(10)
                .margin({ right: 6, bottom: 4 })
                .onClick(() => {
                  this.selectedCatKey = key
                })
            }, (key: string) => key)
          }
          .padding({ left: 2, right: 2 })

          Scroll() {
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
              ForEach(getCategoryNames(this.selectedCatKey), (name: string) => {
                Column() {
                  Image(getEmotionResource(this.selectedCatKey, name))
                    .width(45)
                    .height(45)
                    .objectFit(ImageFit.Contain)
                    .backgroundColor(this.effectiveColorMode === 'dark' &&
                      isEmotionCategoryNeedDarkBg(this.selectedCatKey) ? Color.White : Color.Transparent)
                }
                .width(60)
                .height(60)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .borderRadius(10)
                .backgroundColor(Color.Transparent)
                .onClick(() => {
                  const code: string = '[s:' + this.selectedCatKey + ':' + name + ']'
                  this.replyText = ReplyManagerClass.insertEmoticon(
                    this.replyText,
                    this.selStart,
                    this.selEnd,
                    code
                  )
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
        .constraintSize({ maxHeight: 220 })
        .width('100%')
        .padding(10)
        .borderRadius(16)
        .backgroundColor(Color.Transparent)
        .systemMaterial(UIMaterialManager.inputMaterial)
        .margin({ bottom: 10 })
      }

      TextArea({ text: this.replyText, placeholder: '写下你的回复…', controller: this.textAreaController })
        .width('100%')
        .height(this.currentBreakpoint === 'sm' ? 210 : 250)
        .padding(14)
        .fontSize(15)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .borderRadius(16)
        .backgroundColor(Color.Transparent)
        .border({ width: 0.5, color: AppColors.separator })
        .systemMaterial(UIMaterialManager.inputMaterial)
        .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
        .onChange((value: string) => { this.replyText = value })
        .onTextSelectionChange((start: number, end: number) => {
          this.selStart = start
          this.selEnd = end
        })

      Row() {
        Text(this.isCommentMode ? '按 UTF-8 字节计数' : '内容将发布到当前帖子')
          .fontSize(10)
          .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
        Blank().layoutWeight(1)
        Text(this.getContentMetric())
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isCommentMode && this.getByteLength(this.replyText.trim()) > 650
            ? AppColors.destructive : UIMaterialManager.adaptiveSecondaryForeground)
      }
      .width('100%')
      .padding({ left: 4, right: 4, top: 7 })

      Row() {
        Row() {
          Toggle({ type: ToggleType.Checkbox, isOn: this.isAnonymous })
            .width(20)
            .height(20)
            .onChange((value: boolean) => { this.isAnonymous = value })
          Column() {
            Text('匿名发布')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(UIMaterialManager.adaptiveForeground)
            Text('隐藏账号信息')
              .fontSize(9)
              .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
              .margin({ top: 1 })
          }
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 6 })
        }
        .alignItems(VerticalAlign.Center)

        Blank().layoutWeight(1)

        Button(this.getSubmitLabel())
          .type(ButtonType.Capsule)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .height(42)
          .constraintSize({ minWidth: 104 })
          .fontColor(UIMaterialManager.adaptiveForeground)
          .backgroundColor(Color.Transparent)
          .systemMaterial(UIMaterialManager.neutralActionMaterial)
          .border({ width: 1, color: '#52FFFFFF' })
          .padding({ left: 20, right: 20 })
          .enabled(!this.sending &&
            (this.editMode || this.replyText.trim().length > 0 || replyManager.shouldQuote))
          .onClick(() => { this.doSend() })
      }
      .width('100%')
      .margin({ top: 10 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .constraintSize({ maxWidth: 600 })
    .padding({ left: 16, right: 16, bottom: 16 })
    .backgroundColor(Color.Transparent)
    .borderRadius(24)
    .border({ width: 1, color: '#52FFFFFF' })
    .shadow({ radius: 28, color: AppColors.shadow, offsetY: 12 })
    .clip(true)
    .systemMaterial(UIMaterialManager.surfaceMaterial)
  }
}
