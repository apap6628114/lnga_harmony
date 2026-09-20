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
 *
 * 草稿取信规则（本组件同时承载"新建"与"编辑"两种语义，两者判据相反）：
 * - **新回复 / 贴条**：没有服务端内容，草稿是**唯一来源** —— 有草稿一律用草稿；
 * - **编辑既有帖子 / 回复**：服务端已经有内容，**以服务端原文为准，不读也不写草稿** ——
 *   草稿只在本地存在，服务端可能在别处（网页版 / 另一台设备 / 版主操作）已被改动，
 *   拿本地草稿去覆盖等于把别人的修改顶掉。退出编辑器因此也不再承诺"可恢复"，
 *   确认框文案随之改成"修改将丢失"（见 `requestClose`）。
 */

import { AppColors } from '../constants/Constants'
import { floatingLayerStore } from '../../store/FloatingLayerStore'
import { BBCodePreviewPane } from './BBCodePreviewPane'
import { replyManager, ReplyManagerClass, ReplyType } from '../managers/ReplyManager'
import { PreparedContent } from '../managers/DraftMediaUploader'
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
import {
  pickImage,
  releaseExportedMovingPhoto,
  readExportedFile,
  ExportedMovingPhoto,
  PickedImage
} from '../media/MovingPhotoExport'
import { Logger, DOMAIN_UI, formatError } from '../utils/Logger'
import { resolveKeyboardAppearance } from '../utils/KeyboardAppearanceUtils'
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

  /**
   * 编辑模式下的**服务端正文**（`ThreadPanel.onEdit` 传入的楼层原文）。
   *
   * 编辑模式**以它为准**：这种语义下本地草稿不被采信（见文件头「草稿取信规则」），
   * 因此它不是"兜底"，而是唯一来源。
   */
  @Prop initialContent: string = ''

  /** 当前窗口断点。 */
  @Prop currentBreakpoint: string = 'sm'

  /** 回复正文。 */
  @State replyText: string = ''

  /** 是否正在提交。 */
  @State sending: boolean = false

  /** 是否正在选择/上传图片（含动态照片导出，耗时较长，防重复触发）。 */
  @State uploadingImage: boolean = false

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
   * 打开编辑器时的匿名态（编辑模式取自服务端楼层；新建模式恒为 false）。
   *
   * 编辑模式关闭面板前用它判断"用户到底改没改"：只动了匿名开关、正文一字未落时，
   * 也该走确认框而不是静默关闭（见 `hasUnsavedEdit`）。
   */
  private initialAnonymity: boolean = false

  /**
   * 新建模式（回复 / 贴条）的「放弃编辑」确认框（官方高级对话框模板）。
   *
   * 迁移前由 `floatingLayerStore.showReplyConfirm()` 驱动 `FloatingLayerComponent`
   * 用 `Stack` + 遮罩手搓，现改用官方 `AlertDialog`：系统对话框样式、系统返回键与
   * 点击外部关闭均由组件自身承担，不再需要浮层栈里的独立布尔状态。
   *
   * **主按钮是「关闭编辑器」而不是「删除草稿」**（A2）：`requestClose` 已经先 `saveDraft`
   * 了，文案「已保存为草稿，下次编辑可恢复」描述的正是"关掉编辑器、草稿留着"。
   * 早先主按钮挂的是 `discardDraft()`（删草稿 JSON + 删媒体目录），与文案**恰好相反**——
   * 用户以为自己在关编辑器，实际把草稿和已经上传好的图片副本一起删了。
   * 需要真正删除草稿的入口是设置里的「清除缓存」（文案已明示草稿会被删）。
   *
   * 编辑模式**不复用这个文案**：那里没有草稿可恢复（见 `discardEditDialogController`）。
   */
  private savedDraftDialogController: CustomDialogController = new CustomDialogController({
    backgroundColor: Color.Transparent,
    systemMaterial: UIMaterialManager.dialogMaterial,
    maskColor: UIMaterialManager.nestedScrim,
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

  /**
   * 编辑模式（修改既有帖子 / 回复）的「放弃修改」确认框。
   *
   * 与新建模式**必须分成两个实例**：差别不是措辞，而是事实——编辑模式不写草稿
   * （正文以服务端原文为准，见文件头「草稿取信规则」），关闭就是**真的丢掉**这次修改，
   * 继续沿用「已保存为草稿，下次编辑可恢复」等于对用户撒谎。
   *
   * 也不写成 `content: this.editMode ? ... : ...` 的单实例：那取决于编译器对
   * 「组件调用表达式作 builder」的求值时机，两个静态实例不依赖这个假设。
   */
  private discardEditDialogController: CustomDialogController = new CustomDialogController({
    backgroundColor: Color.Transparent,
    systemMaterial: UIMaterialManager.dialogMaterial,
    maskColor: UIMaterialManager.nestedScrim,
    builder: AlertDialog({
      primaryTitle: '放弃修改？',
      content: '本次修改尚未保存，关闭后将丢失',
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
      /*
       * 编辑既有帖子 / 回复：正文**只取服务端原文，不读草稿**。
       *
       * 判据与新建分支**刻意相反**，因为两者前提不同：新建时服务端没有这份内容，草稿是唯一
       * 来源；编辑时服务端已经有权威版本，而本地草稿是**上一次会话没提交成功**的残骸——它的
       * 基线可能早已过期（网页版 / 另一台设备 / 版主改过这一层），拿它整串覆盖服务端内容，
       * 就是在用户不知情的情况下把别人对这篇帖子的修改顶掉（标题的取信同理，见
       * `ReplyManager.ensureEditSubject`：只认服务端 `post/check` 回传的 `subject`）。
       *
       * 代价同样要认，并且必须在 UI 上说清楚：编辑面板里未提交的修改**不跨会话**——关掉面板
       * 或进程被杀就丢。因此编辑模式既不写草稿（`requestClose` 不再 `saveDraft`，
       * `ReplyManager.saveDraft` / `loadDraft` 另有模式拦截做双保险），也不再承诺"下次可恢复"，
       * 确认框文案随之改成「放弃修改？本次修改尚未保存，关闭后将丢失」。
       *
       * 另有一个可感知的后果：上一次编辑里上传成功、但没提交的图片，凭证随 `beginSession`
       * 作废、正文又只认服务端，重进后只能重新上传。这不再是当初那个"静默丢图"的损坏形态
       * ——编辑器里显示的就是将要提交的内容，用户看得见那张图不在。
       */
      this.replyText = this.initialContent
      this.initialAnonymity = replyManager.isEditMode && replyManager.targetPost !== null
        ? replyManager.targetPost.isanonymous
        : false
      this.isAnonymous = this.initialAnonymity
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

  /**
   * 请求关闭编辑器。
   *
   * 两种语义的收尾方式**不同**：
   * - 新建（回复 / 贴条）：保稿——正文非空、仍引用着已登记的媒体、或有上传在途时存草稿，
   *   否则清掉空草稿；
   * - 编辑既有帖子 / 回复：**不写草稿**（正文以服务端原文为准，存了也不会再被读），
   *   只判断有没有未保存的修改：没有就直接关闭，有则让用户确认丢弃。
   */
  private requestClose(): void {
    // 已经开始关闭：撤销补试，避免面板消失过程中又被抢焦点、重弹键盘
    this.cancelAutoFocusRetry()
    if (this.editMode) {
      /*
       * 什么都没改就直接关：编辑面板刚打开、看一眼就退出是常态，这种情况弹"修改将丢失"
       * 只会制造噪音（此时也的确没有修改会丢）。
       */
      if (!this.hasUnsavedEdit()) {
        this.onClose()
        return
      }
      this.discardEditDialogController.open()
      return
    }
    /*
     * 保稿判据（B9 + B12）：
     * - 正文非空 → 存；
     * - 正文里还引用着某个已登记的媒体 → 存（"只有图片、没有文字"的草稿必须留住：
     *   图片已经上传、本地副本已经复制，丢掉它等于让用户白传一次）；
     * - **有上传/重传在途** → 也要存（B9）。早先漏了这条：用户在图片上传途中关面板会走
     *   else 分支 `clearDraft()`，随后上传完成又把媒体登记进已经清空的会话，
     *   磁盘上就出现"有副本目录、没有草稿 JSON"的劈叉态。
     */
    if (this.replyText.trim().length > 0 ||
      replyManager.hasReferencedMedia(this.replyText) || this.uploadingImage) {
      replyManager.saveDraft(this.replyText)
      this.savedDraftDialogController.open()
    } else {
      // 内容为空且没有任何被引用的媒体时清掉旧草稿，避免下次打开又恢复已删除的内容
      replyManager.clearDraft()
      this.onClose()
    }
  }

  /**
   * 编辑模式下是否存在**未保存的修改**。
   *
   * 三项判据：正文与服务端原文不同、匿名开关与打开时不同、有上传在途。
   * 最后一项不能省：上传在途时正文里还没有 `[img]` 标签，若因为"正文没变"就静默关闭，
   * 用户会以为自己插进去的那张图还在（它随后被登记进一个已经关掉的会话，然后随进程消失）。
   */
  private hasUnsavedEdit(): boolean {
    return this.replyText !== this.initialContent ||
      this.isAnonymous !== this.initialAnonymity ||
      this.uploadingImage
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

  /**
   * 选择并上传图片：**一个入口自适应动态照片**。
   *
   * 判断只在 `MovingPhotoExport.pickImage` 里做一次（按 Picker 返回的 URI 反查资产子类型），
   * 是动态照片就顺手把「封面 + 视频」导出到沙箱。这里只按结果分流：拿到两半就走动态照片上传
   * （三元组与附件累积都在 `ReplyManager.uploadMovingPhoto` 里完成），否则把这一张静态图传上去。
   *
   * 动态照片**导出**失败会自动降级为普通图片（封面本来就躺在所选 URI 上），并且明说一句，
   * 不让用户以为发出去的是动态照片；两半已经拿到之后的**上传**失败则照旧报错、不降级——
   * 那种情况用户要的是重试，而不是悄悄发出半张图。
   */
  private async handleImagePick(): Promise<void> {
    if (this.uploadingImage) {
      return
    }
    this.uploadingImage = true
    let picked: PickedImage | null = null
    try {
      const ctx: Context = this.getUIContext().getHostContext() as Context
      picked = await pickImage(ctx)
    } catch (error) {
      /* 选择本身失败（选择器打不开 / 反查异常）：不占用后续流程，提示后收工 */
      logger.verbose('[IMGUP] pick error: %{public}s', formatError(error))
      appStore.showToast(error instanceof Error ? error.message : '选择图片失败')
      this.uploadingImage = false
      return
    }
    try {
      if (picked === null) {
        return
      }
      const exported: ExportedMovingPhoto | null = picked.movingPhoto
      /*
       * 「本该发动态照片、最终只能发静态图」的两种情况：
       *   ① `movingPhotoExportFailed`：导出抛错（超时 / 被拒 / 内容为空）；
       *   ② `picked.movingPhoto !== null`：导出成功，但下面读完发现两半有空的（防御分支）。
       * ② 不是冗余条件：走到下面时 ① 为 false 而 ② 成立是可能的，去掉它就会漏掉这次提示。
       */
      const movingPhotoFallback: boolean =
        picked.movingPhotoExportFailed || picked.movingPhoto !== null
      if (exported !== null) {
        const coverData: ArrayBuffer = readExportedFile(exported.coverPath)
        const videoData: ArrayBuffer = readExportedFile(exported.videoPath)
        if (coverData.byteLength > 0 && videoData.byteLength > 0) {
          appStore.showToast('正在上传动态照片...')
          /*
           * 走 `...WithDraft` 变体：上传成功后立刻把封面与视频两半的字节写成草稿媒体副本
           * （**编辑模式下 manager 内部跳过**，见 `ReplyManager.uploadMovingPhotoWithDraft`）。
           * 两条约束同时成立——① 字节必须此刻拿（`finally` 的 `releaseExportedMovingPhoto`
           * 会把 `cacheDir/mphoto_upload/<ts>/` 整个删掉）；② 本方法不做 URI 转换，
           * 视频半边本来就只有沙箱路径、没有持久 URI（见 `DraftMediaStore` 文件头）。
           */
          const tag: string = await replyManager.uploadMovingPhotoWithDraft(coverData, videoData)
          this.replyText = ReplyManagerClass.insertImg(this.replyText, this.selStart, this.selEnd, tag)
          appStore.showToast('动态照片已插入')
          return
        }
        logger.warn('[MPUP] exported content empty, fallback to still image')
      }
      await this.uploadStillImage(picked.uri, picked.fileName, movingPhotoFallback)
    } catch (error) {
      const message: string = error instanceof Error ? error.message : '上传失败'
      /* 用 formatError 打出错误码：线上排查「权限被拒（201）/ 资产不是动态照片」要靠它 */
      logger.verbose('[MPUP] error: %{public}s', formatError(error))
      appStore.showToast(message)
    } finally {
      if (picked !== null && picked.movingPhoto !== null) {
        releaseExportedMovingPhoto(picked.movingPhoto)
      }
      this.uploadingImage = false
    }
  }

  /**
   * 把所选 URI 当成一张静态图上传并插入正文。
   *
   * 动态照片降级时也走这里——Picker 返回的 URI 读出来本来就是这个资产的封面图。
   * 失败只提示、不抛出：本方法跑在动态照片分支之后，抛出会被外层再包装成一次重复提示。
   *
   * @param uri 资产 URI
   * @param fileName 上传用的原始文件名
   * @param movingPhotoDegraded 是否为「本该发动态照片、降级成静态图」，成功与失败提示都据此改写
   */
  private async uploadStillImage(uri: string, fileName: string, movingPhotoDegraded: boolean): Promise<void> {
    appStore.showToast('正在上传图片...')
    let buffer: ArrayBuffer = new ArrayBuffer(0)
    try {
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY)
      try {
        const stat = fileIo.statSync(uri)
        buffer = new ArrayBuffer(stat.size)
        fileIo.readSync(file.fd, buffer)
      } finally {
        /* fd 必须成对关闭：`statSync` / `readSync`（大图分配失败）都会抛，漏在这里就是 fd 泄漏 */
        fileIo.closeSync(file)
      }
    } catch (readError) {
      logger.verbose('[IMGUP] read error: %{public}s', String(readError))
      appStore.showToast('读取图片失败')
      return
    }
    try {
      logger.verbose('[IMGUP] calling uploadImage, size: %{public}s', String(buffer.byteLength))
      /*
       * 走 `...WithDraft` 变体：上传成功后顺手把这份图片写进草稿媒体目录。
       * 字节直接用已读到的那一份（不再回头读 Picker URI），见 `DraftMediaStore` 文件头。
       * **编辑模式下 manager 内部会跳过写副本**（正文以服务端原文为准，草稿不会被读回，
       * 副本没有认领者），这里保持同一入口即可，不必在 UI 层分流。
       */
      const imageUrl: string = await replyManager.uploadImageWithDraft(buffer, fileName)
      logger.verbose('[IMGUP] upload success, url: %{public}s', imageUrl)
      const imageTag: string = '[img]./' + imageUrl + '.medium.jpg[/img]'
      this.replyText = ReplyManagerClass.insertImg(this.replyText, this.selStart, this.selEnd, imageTag)
      appStore.showToast(movingPhotoDegraded ? '动态照片未能发送，已按普通图片发送' : '图片已插入')
    } catch (error) {
      const message: string = error instanceof Error ? error.message : '上传图片失败'
      logger.verbose('[IMGUP] error: %{public}s', message)
      /* 降级场景连失败一起说清楚：否则用户只看到"上传失败"，永远不知道选的是动态照片 */
      appStore.showToast(movingPhotoDegraded ? '动态照片未发出，普通图片也上传失败：' + message : message)
    }
  }

  /**
   * 提交前的媒体准备：对草稿里**正文仍引用、但本会话已无凭证**的图片，用本地副本重新上传，
   * 并把"哪段地址变成哪段地址"应用到**当前**正文上。
   *
   * 这是「草稿持久化 + 本地副本」存在的意义所在：凭证是进程内的临时物，杀进程后必然丢失，
   * 而正文里的 `[img]` 还在——不重传就会带着"未声明附件"提交。
   *
   * **不做整串覆盖**（A4）：`replyText` 是用户在重传期间可能已经改过的当前值，
   * 只把替换对逐条应用上去。重传一张大图期间用户接着打字/插图都不会丢。
   *
   * 失败**不静默跳过**：明确提示并停在编辑器（用户可重选图片或直接改正文），
   * 与 `DRAFT_MEDIA_PLAN.md` 阶段 3 的验收口径一致。**已完成的替换仍然应用**——
   * 前面几张已经换了新地址，不回写就会让 UI 与请求体、磁盘草稿三者不一致。
   *
   * @returns 是否已就绪（false 表示已提示用户、应中止本次提交）
   */
  private async prepareSubmitContent(): Promise<boolean> {
    if (this.uploadingImage) {
      return false
    }
    this.uploadingImage = true
    let prepared: PreparedContent | null = null
    try {
      prepared = await replyManager.ensureDraftMedia(this.replyText.trim())
    } catch (error) {
      appStore.showToast(error instanceof Error ? error.message : '草稿图片处理失败')
      return false
    } finally {
      /*
       * 组件已被销毁（用户在重传期间下拉关闭并选了「放弃」）时不再改 @State：
       * 那会让一次"已经关掉的编辑"回头写状态。
       * 注意 `uploadingImage` 仍要复位——`disposed` 之后组件不再渲染，但保持字段一致
       * 可以让"销毁后又被复用"这类异常路径不至于一直卡在 true。
       */
      this.uploadingImage = false
    }
    if (this.disposed || prepared === null) {
      return false
    }
    if (prepared.error.length > 0) {
      // 失败前已完成的替换也要落到 UI 上（否则正文里新旧地址混在一起）
      if (prepared.changed) {
        this.replyText = replyManager.applyMediaReplacements(this.replyText, prepared)
      }
      appStore.showToast(prepared.error)
      return false
    }
    if (prepared.changed) {
      // 正文被改写（标签换了新地址）：必须回写 UI，保证「看到的内容」就是「提交的内容」
      this.replyText = replyManager.applyMediaReplacements(this.replyText, prepared)
    }
    return true
  }

  /** 校验正文并提交回复。 */
  private async doSend(): Promise<void> {
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
    const draftPrepared: boolean = await this.prepareSubmitContent()
    /*
     * A1「幽灵发送」：`prepareSubmitContent` 会 `await` 一次可能长达数十秒的重传
     * （动态照片视频可达数十 MB）。这期间用户下拉关闭 → 确认框选「放弃」→ 面板销毁，
     * 但 Promise 返回后代码照常往下走，帖子**照样发出**，而用户明确表示过不要了。
     * 因此在任何状态写入（`sending`）与提交回调之前必须再确认组件还活着。
     */
    if (this.disposed) {
      return
    }
    if (!draftPrepared) {
      return
    }
    this.sending = true
    /*
     * 提交前快照草稿键：提交是长往返，期间用户可能关掉面板、又打开**另一个帖子**的编辑器，
     * 那时 `clearDraft()` 的"当前键"已经指向那一份草稿，无参清理会删掉别人的草稿 JSON 与
     * 媒体副本目录（`replyManager.send` 内部已按同一快照清理，这里是把同一条契约补齐）。
     */
    const draftKey: string = replyManager.draftKeySnapshot
    this.onSend(this.replyText.trim(), this.isAnonymous).then(() => {
      /*
       * 提交成功：清掉草稿（含媒体副本）。此时面板通常已被调用方关闭，
       * 但草稿属于 manager（进程级单例），与组件生命周期无关，必须清。
       * 编辑模式本身没有草稿可清（`saveDraft` 不写），这次调用在那里是**兜底**：
       * 万一还有更早版本遗留的编辑草稿，提交成功这一刻一并回收。
       */
      replyManager.clearDraft(draftKey)
      if (!this.disposed) {
        this.onClose()
      }
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
          .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
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
