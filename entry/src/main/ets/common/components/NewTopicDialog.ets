/**
 * 发新主题编辑器浮层。
 *
 * 与 ReplyDialog 同族：标题输入 + 主题分类（对应官方客户端 TopicPostModel
 * 的 loadTopicCategory/insertTopicCategory 行为，分类以文本形式进入标题）+
 * BBCode 正文编辑器 + 图片上传 + 匿名开关 + 草稿。
 */

import { AppColors } from '../constants/Constants'
import { floatingLayerStore } from '../../store/FloatingLayerStore'
import { BBCodePreviewPane } from './BBCodePreviewPane'
import { newTopicManager } from '../managers/NewTopicManager'
import { ReplyManagerClass } from '../managers/ReplyManager'
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

const logger = new Logger(DOMAIN_UI, 'NewTopicDialog')

/** 发帖编辑器格式操作。 */
interface FormatAction {
  /** 显示文案。 */
  label: string

  /** BBCode 标签。 */
  tag: string
}

/** 发帖编辑器支持的格式操作。 */
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

/** 使用沉浸光感材质承载发新主题操作。 */
@Component
export struct NewTopicDialog {
  /** 当前窗口断点。 */
  @Prop currentBreakpoint: string = 'sm'

  /** 标题输入。 */
  @State subject: string = ''

  /** 正文内容。 */
  @State content: string = ''

  /** 是否正在提交。 */
  @State sending: boolean = false

  /** 是否匿名发布。 */
  @State isAnonymous: boolean = false

  /** 主题分类列表（空则隐藏分类行）。 */
  @State categories: string[] = []

  /** 当前选区起点。 */
  @State selStart: number = 0

  /** 当前选区终点。 */
  @State selEnd: number = 0

  /** 是否展示表情面板。 */
  @State showEmojiPanel: boolean = false

  /** 是否处于发布预览模式（以 BBCode 渲染结果替换正文输入区）。 */
  @State previewMode: boolean = false

  /** 当前表情分类。 */
  @State selectedCatKey: string = 'ac'

  /** 当前有效明暗色模式。 */
  @StorageProp('effectiveColorMode') effectiveColorMode: string = 'light'

  /** 正文输入框控制器。 */
  private textAreaController: TextAreaController = new TextAreaController()

  /** 组件是否已销毁（防止异步回调在销毁后写 @State）。 */
  private disposed: boolean = false

  /** 提交回调（失败需 reject，编辑器将保留内容与草稿）。 */
  onSend?: (subject: string, content: string, isAnony: boolean) => Promise<void>

  /** 关闭回调。 */
  onClose: () => void = () => {}

  /** 初始化草稿、分类与浮层关闭处理器。 */
  aboutToAppear(): void {
    this.disposed = false
    const draft = newTopicManager.loadDraft()
    this.subject = draft.subject
    this.content = draft.content
    floatingLayerStore.registerReplyCloseHandler(() => { this.requestClose() })
    newTopicManager.loadCategories().then((list: string[]) => {
      if (!this.disposed) {
        this.categories = list
      }
    }).catch(() => {
      logger.verbose('[NTCAT] load categories failed')
    })
  }

  /** 标记组件已销毁。 */
  aboutToDisappear(): void {
    this.disposed = true
  }

  /** 请求关闭编辑器，并在存在内容时保留草稿。 */
  private requestClose(): void {
    if (this.subject.trim().length > 0 || this.content.trim().length > 0) {
      newTopicManager.saveDraft(this.subject, this.content)
      floatingLayerStore.showReplyConfirm()
    } else {
      // 内容为空时清掉残留草稿，避免下次打开又恢复旧内容
      newTopicManager.clearDraft()
      this.onClose()
    }
  }

  /** 将分类标签置为标题前缀（对应官方客户端 insertTopicCategory）。 */
  private applyCategory(category: string): void {
    const trimmed: string = this.subject.trim()
    if (trimmed.length === 0) {
      this.subject = category
    } else if (!trimmed.startsWith(category)) {
      this.subject = category + trimmed
    }
  }

  /**
   * 切换编辑/预览模式。
   *
   * 进入预览时收起表情面板；返回编辑后等待 TextArea 重建，
   * 在下一帧恢复切换前的光标位置。
   */
  private togglePreview(): void {
    if (this.previewMode) {
      this.previewMode = false
      setTimeout((): void => {
        this.textAreaController.caretPosition(this.selStart)
      }, 0)
    } else {
      this.showEmojiPanel = false
      this.previewMode = true
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
      this.content = ReplyManagerClass.insertUrl(this.content, this.selStart, this.selEnd)
    } else if (tag === 'at') {
      this.content = ReplyManagerClass.insertAtTag(this.content, this.selStart, this.selEnd)
    } else if (tag === 'img') {
      this.handleImagePick()
    } else {
      this.content = ReplyManagerClass.wrapSelectedText(this.content, this.selStart, this.selEnd, tag)
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
        logger.verbose('[NTPIC] read error: %{public}s', String(readError))
        appStore.showToast('读取图片失败')
        return
      }

      logger.verbose('[NTPIC] calling uploadImage, size: %{public}s', String(buffer.byteLength))
      const imageUrl: string = await newTopicManager.uploadImage(buffer, fileName)
      logger.verbose('[NTPIC] upload success, url: %{public}s', imageUrl)
      const imageTag: string = '[img]./' + imageUrl + '.medium.jpg[/img]'
      this.content = ReplyManagerClass.insertImg(this.content, this.selStart, this.selEnd, imageTag)
      appStore.showToast('图片已插入')
    } catch (error) {
      const message: string = error instanceof Error ? error.message : '上传图片失败'
      logger.verbose('[NTPIC] error: %{public}s', message)
      appStore.showToast(message)
    }
  }

  /** 校验标题与正文并提交发帖。 */
  private doSend(): void {
    if (this.onSend === undefined) {
      return
    }
    if (this.subject.trim().length === 0) {
      appStore.showToast('请先填写标题')
      return
    }
    if (this.content.trim().length === 0) {
      appStore.showToast('正文不能为空')
      return
    }
    this.sending = true
    this.onSend(this.subject.trim(), this.content.trim(), this.isAnonymous).then(() => {
      newTopicManager.clearDraft()
      this.onClose()
    }).catch(() => {
      // 发送失败：保留内容与草稿（错误提示已由发送方 Toast 完成）
    }).finally(() => {
      this.sending = false
    })
  }

  /** 获取当前主操作文案。 */
  private getSubmitLabel(): string {
    return this.sending ? '发布中…' : '发布主题'
  }

  /** 构建发帖编辑界面。 */
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
          Text('发新主题')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(UIMaterialManager.adaptiveForeground)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(newTopicManager.boardName ? '发布到 ' + newTopicManager.boardName : '选择版块发布')
            .fontSize(11)
            .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
            .margin({ top: 2 })
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

      TextInput({ text: this.subject, placeholder: '输入标题…' })
        .width('100%')
        .height(48)
        .padding({ left: 14, right: 14 })
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .borderRadius(14)
        .backgroundColor(Color.Transparent)
        .border({ width: 0.5, color: AppColors.separator })
        .systemMaterial(UIMaterialManager.inputMaterial)
        .maxLength(60)
        .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
        .onChange((value: string) => { this.subject = value })
        .margin({ bottom: 10 })

      if (this.categories.length > 0) {
        Column() {
          Row() {
            Text('主题分类')
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
            Blank().layoutWeight(1)
            Text('点击分类可置入标题')
              .fontSize(10)
              .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
          }
          .width('100%')
          .padding({ left: 4, right: 4, bottom: 6 })

          Scroll() {
            Row({ space: 6 }) {
              ForEach(this.categories, (category: string) => {
                Text(category)
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.subject.trim().startsWith(category)
                    ? AppColors.primary : UIMaterialManager.adaptiveForeground)
                  .height(32)
                  .padding({ left: 12, right: 12 })
                  .borderRadius(10)
                  .backgroundColor(this.subject.trim().startsWith(category)
                    ? AppColors.selectionTint : Color.Transparent)
                  .border({ width: 0.5, color: AppColors.separator })
                  .onClick(() => { this.applyCategory(category) })
              }, (category: string) => category)
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
      }

      Column() {
        Row() {
          Text(this.previewMode ? '发布预览' : '格式工具')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
          Blank().layoutWeight(1)
          if (!this.previewMode) {
            Text(this.showEmojiPanel ? '表情面板已展开' : '左右滑动查看更多')
              .fontSize(10)
              .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
              .margin({ right: 10 })
          }
          Text(this.previewMode ? '返回编辑' : '预览')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColors.primary)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(10)
            .backgroundColor(AppColors.selectionTint)
            .onClick(() => { this.togglePreview() })
        }
        .width('100%')
        .padding({ left: 4, right: 4, bottom: 6 })

        if (!this.previewMode) {
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
                    ? AppColors.selectionTint : Color.Transparent)
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
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })
      .borderRadius(14)
      .backgroundColor(Color.Transparent)
      .systemMaterial(UIMaterialManager.inputMaterial)
      .margin({ bottom: 10 })

      if (this.showEmojiPanel && !this.previewMode) {
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
                  this.content = ReplyManagerClass.insertEmoticon(
                    this.content,
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

      if (this.previewMode) {
        BBCodePreviewPane({
          content: this.content,
          viewportHeight: this.currentBreakpoint === 'sm' ? 190 : 240
        })
      } else {
        TextArea({ text: this.content, placeholder: '写下正文…', controller: this.textAreaController })
          .width('100%')
          .height(this.showEmojiPanel ? 120 : (this.currentBreakpoint === 'sm' ? 190 : 240))
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
          .onChange((value: string) => { this.content = value })
          .onTextSelectionChange((start: number, end: number) => {
            if (this.previewMode) {
              return
            }
            this.selStart = start
            this.selEnd = end
          })
      }

      Row() {
        Text('内容将发布为新的主题帖')
          .fontSize(10)
          .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
        Blank().layoutWeight(1)
        Text(this.content.trim().length.toString() + ' 字')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
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
          .enabled(!this.sending && this.subject.trim().length > 0 && this.content.trim().length > 0)
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
