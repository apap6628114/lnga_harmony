import { floatingLayerStore, FloatingLayerStoreClass, FloatingPage } from '../../store/FloatingLayerStore'
import { AppColors } from '../constants/Constants'
import { ImageViewer } from './ImageViewer'
import { ProfileCardPopup } from './ProfileCardPopup'
import { ReplyDialog } from './ReplyDialog'
import { NewTopicDialog } from './NewTopicDialog'

/**
 * 全局浮层承载：图片预览、资料卡、回复编辑器与发新主题。
 *
 * 承载方式已从「`Stack` + 全屏遮罩手搓弹窗」迁移到官方模态 API：
 * - 回复 / 发新主题编辑器 → `bindSheet` 半模态面板。系统承担进出场动效、下拉手势与
 *   键盘避让；`sm` 断点为底部面板，`md+` 断点用 `SheetType.CENTER` 保持原先的居中浮层形态。
 * - 图片查看器 → `bindContentCover` 全屏模态。
 * - 资料卡 → 保持自绘 `.position()` 定位，原因见 build 内注释（`bindPopup` 的定位模型
 *   不覆盖「任意屏幕坐标气泡」）。
 *
 * 确认类弹窗（通用确认、放弃编辑确认）已迁出本组件，改由各调用点的官方高级对话框
 * 模板（`@ohos.arkui.advanced.Dialog` 的 `AlertDialog`）承载。
 *
 * 视觉不变的关键：半模态 / 全屏模态自身背景一律置透明、系统模糊关闭并把蒙层色对齐
 * `AppColors.overlay`，弹层外观继续由内容容器的 `UIMaterialManager` 磨砂玻璃承担
 * （见 docs/IMMERSIVE_LIGHT_DESIGN.md §12）。
 */
@Component
export struct FloatingLayerComponent {
  /** 全局浮层状态。 */
  @State private floating: FloatingLayerStoreClass = floatingLayerStore

  /** 当前窗口断点。 */
  @Prop currentBreakpoint: string = 'sm'

  /** 应用导航栏高度。 */
  @StorageProp('navBarHeight') navBarHeight: number = 0

  /**
   * 编辑器半模态面板选项（回复与发新主题共用）。
   *
   * `dragBar` / `showClose` 关闭系统附属元素：编辑器自带拖动指示条与「取消」按钮，
   * 再叠一套系统元素会出现重复的条与关闭叉。
   * 交互式关闭（下拉手势 / 点击蒙层）统一转到 `notifyReplyCloseRequested`：
   * 先保存草稿，有正文时弹出放弃确认；不调用 `dismiss`，由浮层状态驱动真正的关闭，
   * 保证「状态单一真源在 store」这一前提不被系统的自行关闭打破。
   *
   * @returns 半模态面板选项
   */
  private editorSheetOptions(): SheetOptions {
    const options: SheetOptions = {
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      showClose: false,
      backgroundColor: Color.Transparent,
      maskColor: AppColors.overlay,
      preferType: this.currentBreakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
      shouldDismiss: (sheetDismiss: SheetDismiss) => {
        this.floating.notifyReplyCloseRequested()
      }
    }
    if (this.currentBreakpoint !== 'sm') {
      // 居中形态下由内容宽度决定面板宽度（原实现的 600 + 左右 24 内边距）
      options.width = 648
    }
    return options
  }

  /**
   * 图片查看器全屏模态选项。
   *
   * @returns 全屏模态选项
   */
  private imageCoverOptions(): ContentCoverOptions {
    const options: ContentCoverOptions = {
      modalTransition: ModalTransition.DEFAULT,
      onWillDismiss: (action: DismissContentCoverAction) => {
        action.dismiss()
      }
    }
    return options
  }

  /** 回复编辑器半模态内容。 */
  @Builder
  ReplyEditorSheet() {
    Column() {
      ReplyDialog({
        dialogTitle: this.floating.replyDialogTitle,
        editMode: this.floating.editMode,
        initialContent: this.floating.editInitialContent,
        currentBreakpoint: this.currentBreakpoint,
        onSend: this.floating.replyOnSend,
        onClose: () => {
          this.floating.registerReplyCloseHandler(null)
          this.floating.remove(FloatingPage.REPLY_DIALOG)
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({
      left: this.currentBreakpoint === 'sm' ? 10 : 24,
      right: this.currentBreakpoint === 'sm' ? 10 : 24,
      bottom: this.currentBreakpoint === 'sm' ? 8 : 24
    })
  }

  /** 发新主题半模态内容。 */
  @Builder
  NewTopicEditorSheet() {
    Column() {
      NewTopicDialog({
        currentBreakpoint: this.currentBreakpoint,
        onSend: this.floating.newTopicOnSend,
        onClose: () => {
          this.floating.registerReplyCloseHandler(null)
          this.floating.remove(FloatingPage.NEW_TOPIC_DIALOG)
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({
      left: this.currentBreakpoint === 'sm' ? 10 : 24,
      right: this.currentBreakpoint === 'sm' ? 10 : 24,
      bottom: this.currentBreakpoint === 'sm' ? 8 : 24
    })
  }

  /** 图片查看器全屏模态内容。 */
  @Builder
  ImageViewerCover() {
    ImageViewer({
      urls: this.floating.imageViewerUrls,
      initialIndex: this.floating.imageViewerIndex,
      onClose: () => { this.floating.remove(FloatingPage.IMAGE_VIEWER) }
    })
  }

  build() {
    Stack() {
      // 半模态锚点（回复编辑器）：锚点只作为官方面板的宿主，不参与命中测试
      Column()
        .width('100%').height('100%')
        .hitTestBehavior(HitTestMode.None)
        .bindSheet(
          this.floating.top === FloatingPage.REPLY_DIALOG,
          this.ReplyEditorSheet(),
          this.editorSheetOptions()
        )

      // 半模态锚点（发新主题）
      Column()
        .width('100%').height('100%')
        .hitTestBehavior(HitTestMode.None)
        .bindSheet(
          this.floating.top === FloatingPage.NEW_TOPIC_DIALOG,
          this.NewTopicEditorSheet(),
          this.editorSheetOptions()
        )

      // 全屏模态锚点（图片查看器）
      Column()
        .width('100%').height('100%')
        .hitTestBehavior(HitTestMode.None)
        .bindContentCover(
          this.floating.top === FloatingPage.IMAGE_VIEWER,
          this.ImageViewerCover(),
          this.imageCoverOptions()
        )

      // 资料卡：任意屏幕坐标浮层。
      //
      // 这里保持自绘定位而不是 `bindPopup`（实测结论，勿轻易改回）：
      // `bindPopup` 的位置由**锚点组件的几何区域**经 `placement` 推导，`offset` 只是相对该
      // 推导结果的偏移（声明原文：Offset of the popup relative to the display position
      // specified by placement）。资料卡要出现在「用户点哪就在哪」的任意坐标上，与这个模型
      // 不匹配，两种锚点方案实测均不可用：
      // - 零尺寸锚点：建立不出气泡基准位置，内容不渲染、只剩蒙层挡屏（表现为「看不见但点不动」）；
      // - 1×1 锚点：气泡以锚点几何推导，实际跑到屏幕左上角外并被裁剪，遮罩也未覆盖全屏。
      // 调用点算好的 profileCardX / profileCardY 是屏幕绝对 vp 坐标，用 `.position()` 才能精确落位。
      if (this.floating.top === FloatingPage.PROFILE_CARD) {
        Stack() {
          Column().width('100%').height('100%').backgroundColor(AppColors.overlay)
            .onClick(() => { this.floating.remove(FloatingPage.PROFILE_CARD) })
          ProfileCardPopup({
            targetUid: this.floating.profileCardUid,
            currentBreakpoint: this.currentBreakpoint,
            onClose: () => { this.floating.remove(FloatingPage.PROFILE_CARD) }
          })
          .position({
            x: this.floating.profileCardX,
            y: this.floating.profileCardY
          })
        }
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
    .hitTestBehavior(
      (this.floating.top === FloatingPage.IMAGE_VIEWER ||
       this.floating.top === FloatingPage.PROFILE_CARD ||
       this.floating.top === FloatingPage.REPLY_DIALOG ||
       this.floating.top === FloatingPage.NEW_TOPIC_DIALOG)
        ? HitTestMode.Default : HitTestMode.None
    )
  }
}
