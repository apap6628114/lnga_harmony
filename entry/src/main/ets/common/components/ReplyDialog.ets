/**
 * 回复 / 贴条 / 编辑回复编辑器（沉浸光感半模态面板内容层）。
 *
 * 布局取向：**纵向尽量矮**，且不牺牲任何既有能力（模式切换、表情面板、预览、
 * 格式插入、图片上传、匿名、草稿、输入法互斥）。为此做了四件事：
 *
 * 1. 正文输入区高度在历史值（210 / 250）基础上下调 30%（147 / 175）；表情面板
 *    展开时进一步收缩，把纵向空间让给表情区，避免面板整体顶到屏幕上沿。
 * 2. 移除「内容将发布到当前帖子 + 字数」提示行：普通回复不再占一行；贴条模式
 *    必需的 6~650 字节计数并入既有的贴条提示行，不额外增加高度。
 * 3. 格式工具区从正文区上方移到**下方**（拇指可达区）：文字按钮全部换成 SVG 图标。
 *    第一行常显「表情 / 图片 / 超链接」并在其后放折叠按钮，右端固定「匿名 / 预览」；
 *    粗体及以后的插入型格式收在折叠按钮之后，展开时**另起一行**显示，避免窄屏一进来
 *    就要滑动找工具。格式区左对齐、开关区右对齐，激活态只靠颜色区分（主题色图标 +
 *    极淡琥珀底）。
 * 4. 取消按钮移除（下拉手势、点击蒙层、系统返回均能关闭），主操作按钮接管其
 *    右上角位置。
 *
 * 视觉契约（docs/IMMERSIVE_LIGHT_DESIGN.md §12）：面板本体是系统沉浸材质
 * （`SheetOptions.systemMaterial`），本组件属**内容层**——只用 `dialogFieldMaterial`
 * 这类「半透明填充 + 极淡描边、不做背景模糊」的玻璃表达层级，不再叠二次模糊；
 * 未激活的工具按钮保持透明底，让材质背板尽量透出来（§12.8）。主操作按钮按 §12.5
 * 走实底主题色 + 高对比文字，它是画面上唯一的视觉重点。
 */

import { AppColors } from '../constants/Constants'
import { floatingLayerStore } from '../../store/FloatingLayerStore'
import { BBCodePreviewPane } from './BBCodePreviewPane'
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
import { AlertDialog } from '@kit.ArkUI'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { Logger, DOMAIN_UI } from '../utils/Logger'
import { UIMaterialManager } from '../managers/UIMaterialManager'
import { EditorFormatBar } from './EditorFormatBar'

const logger = new Logger(DOMAIN_UI, 'ReplyDialog')

/** 回复正文输入框的组件标识，用于通过 UIContext 恢复焦点并拉起软键盘。 */
const REPLY_TEXT_AREA_ID: string = 'reply-editor-text-area'

/**
 * 打开编辑器后补一次焦点请求的延时（ms）。
 *
 * 面板刚打开时半模态转场尚未结束，转场期间系统会忽略焦点请求——因此组件挂载后先试一次，
 * 转场结束再补一次，保证软键盘一定被拉起；两次请求都是幂等的，重复请求不会重弹键盘。
 */
const AUTO_FOCUS_RETRY_DELAY_MS: number = 260

/** 正文输入区高度（vp）：历史值 210 / 250 的 70%，用于压低整面板高度。 */
const EDITOR_HEIGHT_SM: number = 147
const EDITOR_HEIGHT_MD: number = 175

/** 表情面板展开时的正文输入区高度（vp）：把纵向空间让给表情区。 */
const EDITOR_HEIGHT_EMOJI_SM: number = 104
const EDITOR_HEIGHT_EMOJI_MD: number = 128

/** 贴条正文的 UTF-8 字节上限，与提交校验、服务端限制一致。 */
const COMMENT_MAX_BYTES: number = 650

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

  /** 是否处于发布预览模式（以 BBCode 渲染结果替换正文输入区）。 */
  @State previewMode: boolean = false

  /** 当前表情分类。 */
  @State selectedCatKey: string = 'ac'

  /** 当前有效明暗色模式。 */
  @StorageProp('effectiveColorMode') effectiveColorMode: string = 'light'

  /** 正文输入框控制器。 */
  private textAreaController: TextAreaController = new TextAreaController()

  /**
   * 自动聚焦补试的定时器句柄。
   *
   * 补试是「转场期间焦点请求被忽略」的兜底，但它也可能反过来把用户刚点下的焦点（连同光标）
   * 抢回来，因此用户一旦交互、开始关闭或组件销毁就撤销它（见 `cancelAutoFocusRetry`）。
   */
  private autoFocusRetryTimer: number = -1

  /** 组件是否已销毁：异步回调据此停止改状态、停止抢焦点。 */
  private disposed: boolean = false

  /**
   * 「放弃编辑」确认框（官方高级对话框模板）。
   *
   * 迁移前由 `floatingLayerStore.showReplyConfirm()` 驱动 `FloatingLayerComponent`
   * 用 `Stack` + 遮罩手搓，现改用官方 `AlertDialog`：系统对话框样式、系统返回键与
   * 点击外部关闭均由组件自身承担，不再需要浮层栈里的独立布尔状态。
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

  /** 提交回调。 */
  onSend?: (text: string, isAnony: boolean) => Promise<void>

  /** 关闭回调。 */
  onClose: () => void = () => {}

  /** 初始化编辑模式、草稿与浮层关闭处理器。 */
  aboutToAppear(): void {
    this.disposed = false
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
    this.autoFocusEditor()
  }

  /** 标记组件已销毁，并撤销尚未触发的自动聚焦补试。 */
  aboutToDisappear(): void {
    this.disposed = true
    this.cancelAutoFocusRetry()
  }

  /**
   * 打开编辑器后自动聚焦正文，由系统拉起软键盘。
   *
   * 新回复、贴条、编辑回复三种入口一致：输入框挂载后立即请求一次（多数情况这一步就够），
   * 半模态转场结束后再补一次，避免转场期间请求被系统忽略而键盘不弹。
   */
  private autoFocusEditor(): void {
    setTimeout((): void => { this.focusReplyEditor() }, 0)
    this.autoFocusRetryTimer = setTimeout((): void => { this.focusReplyEditor() }, AUTO_FOCUS_RETRY_DELAY_MS)
  }

  /**
   * 撤销尚未触发的自动聚焦补试。
   *
   * 触发时机：输入框已经拿到焦点、用户开始关闭面板、组件销毁。少了这道撤销，用户在打开
   * 面板后 260ms 内落到别处的焦点会被抢回来、光标会被拽到末尾。
   */
  private cancelAutoFocusRetry(): void {
    if (this.autoFocusRetryTimer >= 0) {
      clearTimeout(this.autoFocusRetryTimer)
      this.autoFocusRetryTimer = -1
    }
  }

  /**
   * 聚焦正文输入框，光标落在已有内容（草稿 / 编辑内容）末尾。
   *
   * 组件已销毁、用户已切到表情面板或预览态时跳过，避免把系统键盘从表情面板手里抢回来。
   */
  private focusReplyEditor(): void {
    if (this.disposed || this.showEmojiPanel || this.previewMode) {
      return
    }
    this.requestEditorFocus(this.replyText.length)
  }

  /** 请求正文输入框焦点并把光标放到指定位置。 */
  private requestEditorFocus(caret: number): void {
    try {
      this.getUIContext().getFocusController().requestFocus(REPLY_TEXT_AREA_ID)
      this.textAreaController.caretPosition(caret)
    } catch (error) {
      logger.verbose('[IME] request reply editor focus failed: %{public}s', String(error))
    }
  }

  /** 请求关闭编辑器，并在存在正文时保留草稿。 */
  private requestClose(): void {
    // 已经开始关闭：撤销补试，避免面板消失过程中又被抢焦点、重弹键盘
    this.cancelAutoFocusRetry()
    if (this.replyText.trim().length > 0) {
      replyManager.saveDraft(this.replyText)
      this.abandonDialogController.open()
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
    setTimeout((): void => { this.requestEditorFocus(this.selStart) }, 0)
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

  /** 正文输入框获得焦点时收起表情面板，保证两种输入面板不会同时显示。 */
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
      if (byteLength < 6 || byteLength > COMMENT_MAX_BYTES) {
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

  /** 贴条模式下的实时字节计数（对应 6~650 字节的硬性限制）。 */
  private getCommentMetric(): string {
    return this.getByteLength(this.replyText.trim()).toString() +
      ' / ' + COMMENT_MAX_BYTES.toString() + ' 字节'
  }

  /** 获取当前主操作文案。图标化工具行后按钮移到标题右侧，取最短的可辨识写法。 */
  private getSubmitLabel(): string {
    if (this.sending) {
      return '发送中'
    }
    if (this.editMode) {
      return '保存'
    }
    return this.isCommentMode ? '发贴条' : '发送'
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

      // 头部：标题 +（模式切换 / 副标题）+ 主操作。
      // 「取消」已移除——下拉手势、点击蒙层、系统返回都能关闭；主操作按钮接管右上角，
      // 并以实底主题色成为画面上唯一的视觉重点（§12.5）。
      Row() {
        Column() {
          Text(this.dialogTitle)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(UIMaterialManager.adaptiveForeground)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (!this.editMode && !this.previewMode && replyManager.canToggleComment) {
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
            .attributeModifier(UIMaterialManager.dialogFieldMaterial)
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
        .margin({ right: 10 })

        Button(this.getSubmitLabel())
          .type(ButtonType.Capsule)
          .height(36)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.white)
          .backgroundColor(AppColors.primary)
          .padding({ left: 18, right: 18 })
          .enabled(!this.sending &&
            (this.editMode || this.replyText.trim().length > 0 || replyManager.shouldQuote))
          .onClick(() => { this.doSend() })
      }
      .width('100%')
      .padding({ bottom: 10 })
      .alignItems(VerticalAlign.Center)

      // 贴条提示与实时字节计数合并为一行：不加高度，也不丢贴条的硬性长度反馈
      if (this.isCommentMode) {
        Row() {
          Text('贴条')
            .fontSize(10)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColors.primary)
            .backgroundColor(AppColors.selectionTint)
            .borderRadius(8)
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          Text('将附着在该楼层下方（6~650字节）')
            .fontSize(11)
            .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
            .margin({ left: 7 })
          Blank().layoutWeight(1)
          Text(this.getCommentMetric())
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.getByteLength(this.replyText.trim()) > COMMENT_MAX_BYTES
              ? AppColors.destructive
              : UIMaterialManager.adaptiveSecondaryForeground)
        }
        .width('100%')
        .padding({ left: 2, bottom: 8 })
        .alignItems(VerticalAlign.Center)
      }

      if (this.previewMode) {
        BBCodePreviewPane({
          content: replyManager.buildContent(this.replyText),
          viewportHeight: this.currentBreakpoint === 'sm' ? EDITOR_HEIGHT_SM : EDITOR_HEIGHT_MD
        })
      } else {
        TextArea({ text: this.replyText, placeholder: '写下你的回复…', controller: this.textAreaController })
          .id(REPLY_TEXT_AREA_ID)
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
          .onChange((value: string) => { this.replyText = value })
          .onTextSelectionChange((start: number, end: number) => {
            if (this.previewMode) {
              return
            }
            this.selStart = start
            this.selEnd = end
          })
      }

      // 格式工具行：紧贴正文区下方（拇指可达区）。
      // 布局与交互契约集中在 `EditorFormatBar`：第一行是常显格式 + 右端「匿名 / 预览」，
      // 高级格式收在折叠按钮之后、展开时另起一行（回复与发新主题共用同一套工具行）。
      EditorFormatBar({
        isAnonymous: $isAnonymous,
        previewMode: this.previewMode,
        emojiPanelOpen: this.showEmojiPanel,
        onFormat: (tag: string): void => { this.applyFormatTag(tag) },
        onTogglePreview: (): void => { this.togglePreview() }
      })

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
