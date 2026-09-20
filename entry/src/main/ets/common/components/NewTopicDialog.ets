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
import { resolveKeyboardAppearance } from '../utils/KeyboardAppearanceUtils'
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

  /** 是否正在选择/上传图片（含动态照片导出，耗时较长，防重复触发）。 */
  @State uploadingImage: boolean = false

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
   *
   * **主按钮是「关闭编辑器」而不是「删除草稿」**（A2，与 `ReplyDialog` 同构）：
   * `requestClose` 已经先 `saveDraft` 了，文案「已保存为草稿，下次编辑可恢复」描述的正是
   * "关掉编辑器、草稿留着"。早先主按钮挂的是 `discardDraft()`（删草稿 JSON + 删媒体目录），
   * 与文案恰好相反。真正删除草稿的入口是设置里的「清除缓存」（文案已明示）。
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
    /*
     * 保稿判据（与 `ReplyDialog` 同构）：
     * - 标题或正文非空 → 存；
     * - 正文里还引用着某个已登记的媒体 → 存（"只有图片、没有文字"的草稿必须留住，
     *   图片已经上传、本地副本已经复制，丢掉它等于让用户白传一次）；
     * - **有上传/重传在途** → 也要存（B9）。早先漏了这条：上传途中关面板会走 else 分支
     *   `clearDraft()`，随后上传完成又把媒体登记进已经清空的会话。
     */
    if (this.subject.trim().length > 0 || this.content.trim().length > 0 ||
      newTopicManager.hasReferencedMedia(this.content) || this.uploadingImage) {
      newTopicManager.saveDraft(this.subject, this.content)
      this.abandonDialogController.open()
    } else {
      // 内容为空且没有任何被引用的媒体时清掉残留草稿，避免下次打开又恢复旧内容
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

  /**
   * 选择并上传图片：**一个入口自适应动态照片**。
   *
   * 判断只在 `MovingPhotoExport.pickImage` 里做一次（按 Picker 返回的 URI 反查资产子类型），
   * 是动态照片就顺手把「封面 + 视频」导出到沙箱。这里只按结果分流：拿到两半就走动态照片上传
   * （三元组与附件累积都在 `NewTopicManager.uploadMovingPhoto` 里完成），否则把这一张静态图传上去。
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
      logger.verbose('[NTPIC] pick error: %{public}s', formatError(error))
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
          const tag: string = await newTopicManager.uploadMovingPhotoWithDraft(coverData, videoData)
          this.content = ReplyManagerClass.insertImg(this.content, this.selStart, this.selEnd, tag)
          appStore.showToast('动态照片已插入')
          return
        }
        logger.warn('[NTPIC] exported content empty, fallback to still image')
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
      logger.verbose('[NTPIC] read error: %{public}s', String(readError))
      appStore.showToast('读取图片失败')
      return
    }
    try {
      logger.verbose('[NTPIC] calling uploadImage, size: %{public}s', String(buffer.byteLength))
      /*
       * 走 `...WithDraft` 变体：上传成功后顺手把这份图片写进草稿媒体目录。
       * 字节直接用已读到的那一份（不再回头读 Picker URI），见 `DraftMediaStore` 文件头。
       */
      const imageUrl: string = await newTopicManager.uploadImageWithDraft(buffer, fileName)
      logger.verbose('[NTPIC] upload success, url: %{public}s', imageUrl)
      const imageTag: string = '[img]./' + imageUrl + '.medium.jpg[/img]'
      this.content = ReplyManagerClass.insertImg(this.content, this.selStart, this.selEnd, imageTag)
      appStore.showToast(movingPhotoDegraded ? '动态照片未能发送，已按普通图片发送' : '图片已插入')
    } catch (error) {
      const message: string = error instanceof Error ? error.message : '上传图片失败'
      logger.verbose('[NTPIC] error: %{public}s', message)
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
   * **不做整串覆盖**（A4）：`content` 是用户在重传期间可能已经改过的当前值，
   * 只把替换对逐条应用上去。
   *
   * 失败**不静默跳过**：明确提示并停在编辑器；**已完成的替换仍然应用**，
   * 否则 UI、请求体与磁盘草稿三者会不一致。
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
      prepared = await newTopicManager.ensureDraftMedia(this.content.trim())
    } catch (error) {
      appStore.showToast(error instanceof Error ? error.message : '草稿图片处理失败')
      return false
    } finally {
      // 详见 `ReplyDialog.prepareSubmitContent` 的同名注释
      this.uploadingImage = false
    }
    if (this.disposed || prepared === null) {
      return false
    }
    if (prepared.error.length > 0) {
      if (prepared.changed) {
        this.content = newTopicManager.applyMediaReplacements(this.content, prepared)
      }
      appStore.showToast(prepared.error)
      return false
    }
    if (prepared.changed) {
      // 正文被改写（标签换了新地址）：必须回写 UI，保证「看到的内容」就是「提交的内容」
      this.content = newTopicManager.applyMediaReplacements(this.content, prepared)
    }
    return true
  }

  /** 校验标题与正文并提交发帖。 */
  private async doSend(): Promise<void> {
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
    const draftPrepared: boolean = await this.prepareSubmitContent()
    /*
     * A1「幽灵发送」：`prepareSubmitContent` 会 `await` 一次可能长达数十秒的重传。
     * 这期间用户下拉关闭 → 确认框选「放弃」→ 面板销毁，但 Promise 返回后代码照常往下走，
     * 帖子**照样发出**，而用户明确表示过不要了。因此在任何状态写入（`sending`）
     * 与提交回调之前必须再确认组件还活着。
     */
    if (this.disposed) {
      return
    }
    if (!draftPrepared) {
      return
    }
    this.sending = true
    this.onSend(this.subject.trim(), this.content.trim(), this.isAnonymous).then(() => {
      // 提交成功：清掉草稿（含媒体副本）。草稿属于 manager（进程级单例），与组件生命周期无关。
      newTopicManager.clearDraft()
      if (!this.disposed) {
        this.onClose()
      }
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
          .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
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
          .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
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
