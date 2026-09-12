/**
 * 发新主题编辑器浮层。
 *
 * 与 `ReplyDialog` 同族，布局取向一致——**纵向尽量矮**，且不减少任何既有能力：
 * 标题输入 + 主题分类（对应官方客户端 TopicPostModel 的 loadTopicCategory /
 * insertTopicCategory 行为，分类以文本形式进入标题）+ BBCode 正文编辑器 + 图片上传 +
 * 匿名开关 + 草稿 + 发布预览 + 表情面板。
 *
 * 1. 正文输入区高度在历史值（190 / 240）基础上下调 30%（133 / 168），标题输入框随整体
 *    收紧到 42；表情面板展开时正文进一步收缩，把纵向空间让给表情区。
 * 2. 移除「内容将发布为新的主题帖 + 字数」提示行。
 * 3. 格式工具区从正文区上方移到**下方**（拇指可达区），与回复编辑器共用
 *    `EditorFormatBar`：第一行常显「表情 / 图片 / 超链接」并在其后放折叠按钮，右端固定
 *    「匿名 / 预览」；粗体以后的插入型格式收在折叠按钮之后、展开时另起一行。
 * 4. 取消按钮移除（下拉手势 / 点击蒙层 / 系统返回都能关闭），主操作按钮接管其右上角位置。
 * 5. 主题分类默认折叠，入口是标题输入框**内右端**的标签按钮（激活态为主题色），展开后 chips
 *    落在标题正下方——折叠态不再为分类单独占一行高度。
 *
 * 视觉契约（docs/IMMERSIVE_LIGHT_DESIGN.md §12）：面板本体是系统沉浸材质
 * （`SheetOptions.systemMaterial`），本组件属**内容层**——只用 `dialogFieldMaterial`
 * 这类「半透明填充 + 极淡描边、不做背景模糊」的玻璃表达层级；主操作按钮按 §12.5
 * 走实底主题色 + 高对比文字，是画面上唯一的视觉重点。
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
import { AlertDialog } from '@kit.ArkUI'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { Logger, DOMAIN_UI } from '../utils/Logger'
import { UIMaterialManager } from '../managers/UIMaterialManager'
import { EditorFormatBar } from './EditorFormatBar'

const logger = new Logger(DOMAIN_UI, 'NewTopicDialog')

/** 发帖标题输入框的组件标识：打开编辑器后自动聚焦它（发布前必须先有标题）。 */
const NEW_TOPIC_SUBJECT_ID: string = 'new-topic-editor-subject'

/** 发帖正文输入框的组件标识，用于通过 UIContext 恢复焦点并拉起软键盘。 */
const NEW_TOPIC_TEXT_AREA_ID: string = 'new-topic-editor-text-area'

/**
 * 打开编辑器后补一次焦点请求的延时（ms）。
 *
 * 面板刚打开时半模态转场尚未结束，转场期间系统会忽略焦点请求——因此组件挂载后先试一次，
 * 转场结束再补一次，保证软键盘一定被拉起；两次请求都是幂等的，重复请求不会重弹键盘。
 */
const AUTO_FOCUS_RETRY_DELAY_MS: number = 260

/** 正文输入区高度（vp）：历史值 190 / 240 的 70%，用于压低整面板高度。 */
const EDITOR_HEIGHT_SM: number = 133
const EDITOR_HEIGHT_MD: number = 168

/** 表情面板展开时的正文输入区高度（vp）：把纵向空间让给表情区。 */
const EDITOR_HEIGHT_EMOJI_SM: number = 96
const EDITOR_HEIGHT_EMOJI_MD: number = 118

/** 标题输入框高度（vp）：随整体压缩收紧，仍保持单行输入的舒适高度。 */
const SUBJECT_HEIGHT: number = 42

/** 标题输入框的左右内边距（vp）。 */
const SUBJECT_PADDING: number = 14

/** 标题输入框内「主题分类」入口按钮的边长（vp）、其距右边缘的距离（vp）与图标边长（vp）。 */
const SUBJECT_ENTRY_SIZE: number = 32
const SUBJECT_ENTRY_MARGIN: number = 5
const SUBJECT_ENTRY_ICON: number = 18

/**
 * 标题输入框右侧为分类入口预留的宽度（vp）。
 *
 * **恒定预留**，不随分类是否已加载出来变化：`categories` 是异步加载的，若按有无分类切换
 * 内边距，加载完成的一瞬间会看到标题文字与光标横向跳动。
 */
const SUBJECT_ENTRY_SLOT: number = SUBJECT_ENTRY_SIZE + SUBJECT_ENTRY_MARGIN + 9

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

  /** 主题分类是否展开（默认折叠，入口是标题输入框内右端的标签按钮）。 */
  @State categoryExpanded: boolean = false

  /** 当前表情分类。 */
  @State selectedCatKey: string = 'ac'

  /** 当前有效明暗色模式。 */
  @StorageProp('effectiveColorMode') effectiveColorMode: string = 'light'

  /** 正文输入框控制器。 */
  private textAreaController: TextAreaController = new TextAreaController()

  /**
   * 「放弃编辑」确认框（官方高级对话框模板）。
   *
   * 迁移前由 `floatingLayerStore.showReplyConfirm()` 驱动 `FloatingLayerComponent`
   * 用 `Stack` + 遮罩手搓，现改用官方 `AlertDialog` 承载，浮层栈不再保存确认框状态。
   */
  private abandonDialogController: CustomDialogController = new CustomDialogController({
    backgroundColor: Color.Transparent,
    systemMaterial: UIMaterialManager.dialogMaterial,
    builder: AlertDialog({
      primaryTitle: '放弃编辑？',
      content: '已保存为草稿，下次编辑可恢复',
      primaryButton: {
        value: '放弃',
        fontColor: AppColors.destructive,
        action: () => { this.onClose() }
      },
      secondaryButton: {
        value: '继续编辑'
      }
    }),
    autoCancel: true
  })

  /** 组件是否已销毁（防止异步回调在销毁后写 @State、抢焦点）。 */
  private disposed: boolean = false

  /**
   * 自动聚焦补试的定时器句柄。
   *
   * 补试是「转场期间焦点请求被忽略」的兜底，但它也可能把用户刚点下的焦点（连同光标）
   * 抢回来——发帖面板有两个输入框，抢焦点会让后续输入落进错误字段。因此用户一旦交互、
   * 开始关闭或组件销毁就撤销它（见 `cancelAutoFocusRetry`）。
   */
  private autoFocusRetryTimer: number = -1

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
    this.autoFocusEditor()
  }

  /**
   * 打开编辑器后自动聚焦标题输入框，由系统拉起软键盘。
   *
   * 与 `ReplyDialog` 同一套时序处理：输入框挂载后立即请求一次（多数情况这一步就够），
   * 半模态转场结束后再补一次，避免转场期间请求被系统忽略而键盘不弹。
   * 聚焦标题而不是正文，因为「先有标题才能发布」，标题是发布流程的第一步。
   */
  private autoFocusEditor(): void {
    setTimeout((): void => { this.focusSubject() }, 0)
    this.autoFocusRetryTimer = setTimeout((): void => { this.focusSubject() }, AUTO_FOCUS_RETRY_DELAY_MS)
  }

  /**
   * 撤销尚未触发的自动聚焦补试。
   *
   * 触发时机：某个输入框已经拿到焦点、用户开始关闭面板、组件销毁。少了这道撤销，
   * 用户在打开面板后 260ms 内点到正文打字，焦点会被抢回标题，字就落进了标题栏。
   */
  private cancelAutoFocusRetry(): void {
    if (this.autoFocusRetryTimer >= 0) {
      clearTimeout(this.autoFocusRetryTimer)
      this.autoFocusRetryTimer = -1
    }
  }

  /**
   * 聚焦标题输入框。
   *
   * 组件已销毁、用户已切到表情面板或预览态时跳过，避免把系统键盘抢回来。
   */
  private focusSubject(): void {
    if (this.disposed || this.showEmojiPanel || this.previewMode) {
      return
    }
    try {
      this.getUIContext().getFocusController().requestFocus(NEW_TOPIC_SUBJECT_ID)
    } catch (error) {
      logger.verbose('[IME] auto focus subject failed: %{public}s', String(error))
    }
  }

  /** 标记组件已销毁，并撤销尚未触发的自动聚焦补试。 */
  aboutToDisappear(): void {
    this.disposed = true
    this.cancelAutoFocusRetry()
  }

  /** 请求关闭编辑器，并在存在内容时保留草稿。 */
  private requestClose(): void {
    // 已经开始关闭：撤销补试，避免面板消失过程中又被抢焦点、重弹键盘
    this.cancelAutoFocusRetry()
    if (this.subject.trim().length > 0 || this.content.trim().length > 0) {
      newTopicManager.saveDraft(this.subject, this.content)
      this.abandonDialogController.open()
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
      this.showSystemKeyboard()
    } else {
      this.showEmojiPanel = false
      this.getUIContext().getFocusController().clearFocus()
      this.previewMode = true
    }
  }

  /** 关闭表情面板并在 TextArea 重建后恢复焦点，由系统拉起软键盘。 */
  private showSystemKeyboard(): void {
    this.showEmojiPanel = false
    setTimeout((): void => {
      try {
        this.getUIContext().getFocusController().requestFocus(NEW_TOPIC_TEXT_AREA_ID)
        this.textAreaController.caretPosition(this.selStart)
      } catch (error) {
        logger.verbose('[IME] request new-topic editor focus failed: %{public}s', String(error))
      }
    }, 0)
  }

  /** 清除正文焦点以关闭软键盘，再展示与软键盘互斥的表情面板。 */
  private showEmotionKeyboard(): void {
    this.textAreaController.caretPosition(this.selStart)
    this.getUIContext().getFocusController().clearFocus()
    this.showEmojiPanel = true
  }

  /** 在表情面板与系统软键盘之间互斥切换。 */
  private toggleEmotionKeyboard(): void {
    if (this.showEmojiPanel) {
      this.showSystemKeyboard()
    } else {
      this.showEmotionKeyboard()
    }
  }

  /** 任一文本输入框获得焦点时收起表情面板，保证两种输入面板不会同时显示。 */
  private onEditorFocus(): void {
    this.showEmojiPanel = false
    // 焦点已经就位（自动聚焦成功或用户自己点的），补试不再需要——留着只会抢焦点
    this.cancelAutoFocusRetry()
  }

  /**
   * 将工具行选定的格式应用到当前正文选区。
   *
   * 匿名开关由工具行内部处理（见 `EditorFormatBar`），这里只处理插入型格式与表情面板切换。
   */
  private applyFormatTag(tag: string): void {
    if (tag === 'emoticon') {
      this.toggleEmotionKeyboard()
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

  /** 获取当前主操作文案。头部按钮空间有限，取最短的可辨识写法。 */
  private getSubmitLabel(): string {
    return this.sending ? '发布中' : '发布'
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
        .margin({ right: 10 })

        // 主操作：实底主题色 + 高对比文字，成为画面上唯一的视觉重点（§12.5）。
        // 「取消」已移除——下拉手势、点击蒙层、系统返回都能关闭。
        Button(this.getSubmitLabel())
          .type(ButtonType.Capsule)
          .height(36)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.white)
          .backgroundColor(AppColors.primary)
          .padding({ left: 18, right: 18 })
          .enabled(!this.sending &&
            this.subject.trim().length > 0 && this.content.trim().length > 0)
          .onClick(() => { this.doSend() })
      }
      .width('100%')
      .padding({ bottom: 10 })
      .alignItems(VerticalAlign.Center)

      // 标题输入框：右端内嵌「主题分类」折叠入口——折叠态不额外占一行高度，
      // 展开后分类 chips 出现在标题正下方（见下一个区块）。版块没有分类时不显示入口。
      Stack({ alignContent: Alignment.End }) {
        TextInput({ text: this.subject, placeholder: '输入标题…' })
          .id(NEW_TOPIC_SUBJECT_ID)
          .width('100%')
          .height(SUBJECT_HEIGHT)
          .padding({ left: SUBJECT_PADDING, right: SUBJECT_ENTRY_SLOT })
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(UIMaterialManager.inputForeground)
          .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
          .caretColor(UIMaterialManager.inputForeground)
          .borderRadius(14)
          .attributeModifier(UIMaterialManager.dialogFieldMaterial)
          .maxLength(60)
          .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
          .onFocus(() => { this.onEditorFocus() })
          .onChange((value: string) => { this.subject = value })

        if (this.categories.length > 0) {
          Column() {
            Image($r('app.media.icon_category'))
              .width(SUBJECT_ENTRY_ICON)
              .height(SUBJECT_ENTRY_ICON)
              .fillColor(this.categoryExpanded
                ? AppColors.primary
                : UIMaterialManager.adaptiveIcon)
          }
          .width(SUBJECT_ENTRY_SIZE)
          .height(SUBJECT_ENTRY_SIZE)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .borderRadius(9)
          .backgroundColor(this.categoryExpanded ? AppColors.selectionTint : Color.Transparent)
          .margin({ right: SUBJECT_ENTRY_MARGIN })
          .accessibilityText(this.categoryExpanded ? '收起主题分类' : '展开主题分类')
          .onClick(() => { this.categoryExpanded = !this.categoryExpanded })
        }
      }
      .width('100%')
      .margin({ bottom: 10 })

      if (this.categoryExpanded && this.categories.length > 0) {
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
        .attributeModifier(UIMaterialManager.dialogFieldMaterial)
        .margin({ bottom: 10 })
      }

      if (this.previewMode) {
        BBCodePreviewPane({
          content: this.content,
          viewportHeight: this.currentBreakpoint === 'sm' ? EDITOR_HEIGHT_SM : EDITOR_HEIGHT_MD
        })
      } else {
        TextArea({ text: this.content, placeholder: '写下正文…', controller: this.textAreaController })
          .id(NEW_TOPIC_TEXT_AREA_ID)
          .width('100%')
          .height(this.showEmojiPanel
            ? (this.currentBreakpoint === 'sm' ? EDITOR_HEIGHT_EMOJI_SM : EDITOR_HEIGHT_EMOJI_MD)
            : (this.currentBreakpoint === 'sm' ? EDITOR_HEIGHT_SM : EDITOR_HEIGHT_MD))
          .padding(14)
          .fontSize(15)
          .fontColor(UIMaterialManager.inputForeground)
          .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
          .caretColor(UIMaterialManager.inputForeground)
          .borderRadius(16)
          .attributeModifier(UIMaterialManager.dialogFieldMaterial)
          .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
          .onFocus(() => { this.onEditorFocus() })
          .onChange((value: string) => { this.content = value })
          .onTextSelectionChange((start: number, end: number) => {
            if (this.previewMode) {
              return
            }
            this.selStart = start
            this.selEnd = end
          })
      }

      // 格式工具行：紧贴正文区下方（拇指可达区），与回复编辑器共用同一套工具行。
      // 第一行常显格式 + 右端「匿名 / 预览」，高级格式收在折叠按钮之后、展开时另起一行。
      EditorFormatBar({
        isAnonymous: $isAnonymous,
        previewMode: this.previewMode,
        emojiPanelOpen: this.showEmojiPanel,
        onFormat: (tag: string): void => { this.applyFormatTag(tag) },
        onTogglePreview: (): void => { this.togglePreview() }
      })

      // 表情面板：与系统键盘互斥，展开时正文区同步收缩（见上面的高度三元表达式）
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
        .attributeModifier(UIMaterialManager.dialogFieldMaterial)
        .margin({ top: 8 })
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: 600 })
    .padding({ left: 16, right: 16, bottom: 16 })
    .backgroundColor(Color.Transparent)
  }
}
