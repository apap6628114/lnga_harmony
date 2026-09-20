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
   * 它只是**兜底**：本地存有该楼层的草稿时，正文以草稿为准（见 `aboutToAppear`）。
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
   * 「放弃编辑」确认框（官方高级对话框模板）。
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
   */
  private abandonDialogController: CustomDialogController = new CustomDialogController({
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

  /** 提交回调。 */
  onSend?: (text: string, isAnony: boolean) => Promise<void>

  /** 关闭回调。 */
  onClose: () => void = () => {}

  /** 初始化编辑模式、草稿与浮层关闭处理器。 */
  aboutToAppear(): void {
    this.disposed = false
    if (this.editMode) {
      /*
       * 编辑模式同样接回草稿，判据与新回复分支**完全一致**：有草稿用草稿，没有才用服务端正文。
       *
       * 漏掉这一步，「编辑里插的图重开后仍能发出」就是空话：`startEdit` → `beginSession`
       * 确实把草稿媒体清单装回了 `sessionMedia`（B3），但正文若被 `initialContent`
       * 整串覆盖，用户刚插入的 `[img]` 标签就不在正文里了——`isMediaReferenced` 判不出引用，
       * 提交时这条媒体既不重传、也不进附件参数，图片**静默消失**（不报错：正文没引用
       * 这条媒体在过滤逻辑里是合法形态）；更糟的是 `requestClose` 随后会把这份不含标签的
       * 正文写回草稿，把磁盘上唯一记录着 `[img]` 的正文一起抹掉，媒体副本从此失去引用者，
       * 只能等草稿超期（7 天）连目录一起回收。
       *
       * 代价要认：服务端正文若在别处被改过（网页版 / 另一台设备），草稿会**盖住**它。
       * 这正是「已保存为草稿，下次编辑可恢复」这句文案的语义，与"放弃编辑"确认框一致；
       * 想以服务端为准，走设置里的「清除缓存」（文案已明示草稿会被删）。
       */
      const draft: string = replyManager.loadDraft()
      this.replyText = draft.length > 0 ? draft : this.initialContent
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
      this.abandonDialogController.open()
    } else {
      // 内容为空且没有任何被引用的媒体时清掉旧草稿，避免下次打开又恢复已删除的内容
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
           * 走 `...WithDraft` 变体：上传成功后立刻把封面与视频两半的字节写成草稿媒体副本。
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
      // 提交成功：清掉草稿（含媒体副本）。此时面板通常已被调用方关闭，
      // 但草稿属于 manager（进程级单例），与组件生命周期无关，必须清。
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
