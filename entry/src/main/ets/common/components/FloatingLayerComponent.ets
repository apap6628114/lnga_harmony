import { window } from '@kit.ArkUI'
import { floatingLayerStore, FloatingLayerStoreClass, FloatingPage } from '../../store/FloatingLayerStore'
import { AppColors } from '../constants/Constants'
import { UIMaterialManager } from '../managers/UIMaterialManager'
import { DOMAIN_UI, formatError, Logger } from '../utils/Logger'
import { ImageViewer } from './ImageViewer'
import { ProfileCardPopup } from './ProfileCardPopup'
import { ReplyDialog } from './ReplyDialog'
import { NewTopicDialog } from './NewTopicDialog'

/** 浮层组件日志。 */
const logger = new Logger(DOMAIN_UI, 'FloatingLayerComponent')

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
 * 视觉：半模态面板的**背板**交由系统沉浸材质承担（`SheetOptions.systemMaterial`）——半模态转场
 * 属于 API 26 Release 允许「页面内全部区域」生效的弹窗类接口，模糊、折射、高光、阴影与弹出
 * 空间动效都由系统接管；面板**内容层**只保留半透明内容色（`UIMaterialManager.dialogFieldMaterial`），
 * 不再自绘玻璃，避免对同一层背景二次糊化。内容层背景仍需显式置 `Color.Transparent`
 * （`BindOptions.backgroundColor` 默认 `Color.White`，会盖住背板材质），蒙层色对齐
 * `AppColors.overlay`。
 * 图片查看器是固定暗场景的全屏模态（`ContentCoverOptions` 没有材质字段，且整页不宜套材质），
 * 继续由 `UIMaterialManager` 的暗场景玻璃承担。
 * 详见 docs/IMMERSIVE_LIGHT_DESIGN.md §12。
 */
@Component
export struct FloatingLayerComponent {
  /** 全局浮层状态。 */
  @State private floating: FloatingLayerStoreClass = floatingLayerStore

  /** 当前窗口断点。 */
  @Prop currentBreakpoint: string = 'sm'

  /** 应用导航栏高度。 */
  @StorageProp('navBarHeight') navBarHeight: number = 0

  /** 当前固定态软键盘的实际高度，单位 vp。 */
  @State private keyboardHeightVp: number = 0

  /** 当前应用主窗口，用于管理软键盘高度监听。 */
  private hostWindow: window.Window | undefined = undefined

  /**
   * 软键盘高度变化回调。
   *
   * 系统事件返回 px；布局属性使用 vp，因此通过当前 UIContext 完成单位转换。
   */
  private readonly keyboardHeightChangeCallback: (height: number) => void = (height: number): void => {
    this.keyboardHeightVp = this.getUIContext().px2vp(height)
  }

  /** 组件显示时订阅主窗口软键盘高度变化。 */
  aboutToAppear(): void {
    this.subscribeKeyboardHeightChange()
  }

  /** 组件消失时注销监听，避免组件销毁后继续接收窗口事件。 */
  aboutToDisappear(): void {
    this.unsubscribeKeyboardHeightChange()
  }

  /** 获取主窗口并订阅软键盘高度变化。 */
  private async subscribeKeyboardHeightChange(): Promise<void> {
    try {
      const hostContext = this.getUIContext().getHostContext()
      if (hostContext === undefined) {
        return
      }
      const hostWindow = await window.getLastWindow(hostContext)
      this.hostWindow = hostWindow
      hostWindow.on('keyboardHeightChange', this.keyboardHeightChangeCallback)
    } catch (error) {
      logger.warn('subscribe keyboard height change failed: %{public}s', formatError(error))
    }
  }

  /** 注销软键盘高度变化监听并清空避让高度。 */
  private unsubscribeKeyboardHeightChange(): void {
    if (this.hostWindow !== undefined) {
      try {
        this.hostWindow.off('keyboardHeightChange', this.keyboardHeightChangeCallback)
      } catch (error) {
        logger.warn('unsubscribe keyboard height change failed: %{public}s', formatError(error))
      }
      this.hostWindow = undefined
    }
    this.keyboardHeightVp = 0
  }

  /**
   * 编辑器半模态面板选项（回复与发新主题共用）。
   *
   * `dragBar` / `showClose` 关闭系统附属元素：编辑器自带拖动指示条与「取消」按钮，
   * 再叠一套系统元素会出现重复的条与关闭叉。
   * 交互式关闭（下拉手势 / 点击蒙层）统一转到 `notifyReplyCloseRequested`：
   * 先保存草稿，有正文时弹出放弃确认；不调用 `dismiss`，由浮层状态驱动真正的关闭，
   * 保证「状态单一真源在 store」这一前提不被系统的自行关闭打破。
   * 关闭 `bindSheet` 默认的局部避让，防止它只滚动到焦点输入项并与外层的整面板避让叠加；
   * 回复与发帖内容通过窗口上报的完整键盘高度在底部占位，从而整体位于输入法上方。
   *
   * @returns 半模态面板选项
   */
  private editorSheetOptions(): SheetOptions {
    const options: SheetOptions = {
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      showClose: false,
      // 内容层一律让位给系统材质：BindOptions.backgroundColor 默认是 Color.White，
      // 不显式置透明的话，这层白色内容会盖住背板层的沉浸材质；
      // 设备不支持沉浸材质时该常量回退为半透明填充兜底（见 UIMaterialManager）。
      backgroundColor: UIMaterialManager.sheetContentBackdrop,
      // 背板材质：半模态转场属于 Release 允许「页面内全部区域」生效的弹窗类接口，
      // 面板本体由系统接管模糊、折射、边框、阴影与弹出动效（含空间形变）。
      systemMaterial: UIMaterialManager.sheetMaterial,
      maskColor: AppColors.overlay,
      preferType: this.currentBreakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
      keyboardAvoidMode: SheetKeyboardAvoidMode.NONE,
      shouldDismiss: (sheetDismiss: SheetDismiss) => {
        this.floating.notifyReplyCloseRequested()
      }
    }
    if (this.currentBreakpoint !== 'sm') {
      options.width = 648
    }
    return options
  }

  /**
   * 图片查看器全屏模态选项。
   *
   * 关闭路径有两条，**两条都必须把浮层状态同步回 store**（store 是显隐的单一真源）：
   * - 右上角关闭按钮 → `ImageViewer.onClose` → `remove(IMAGE_VIEWER)`，由状态驱动模态收起；
   * - 系统返回 / 侧滑返回 → 全屏模态优先消费返回事件（`onWillDismiss` 注册后，返回键不会立即关闭模态，
   *   见 `ContentCoverOptions.onWillDismiss` 声明），`MainPage.onBackPress` 在这一步不会被调用，
   *   所以必须在回调里自己清状态。
   *
   * 只调 `action.dismiss()` 而不同步状态的后果：模态视觉上收起了，但 `floating.top` 仍是 `IMAGE_VIEWER`，
   * `FloatingLayerComponent` 根 `Stack` 的 `hitTestBehavior` 保持 `HitTestMode.Default`——该模式自身参与命中
   * 测试并**阻塞兄弟节点**，于是全屏的浮层容器把下方页面的触摸全部吞掉：表现为「返回关闭后界面点不动，
   * 要再按一次系统返回（这次才轮到 `onBackPress` 弹栈）才恢复」。同时 `isShow` 表达式与真实显隐脱钩，
   * 下次 push 同一浮层时表达式值未发生变化，还可能不再弹出。
   *
   * @returns 全屏模态选项
   */
  private imageCoverOptions(): ContentCoverOptions {
    const options: ContentCoverOptions = {
      modalTransition: ModalTransition.DEFAULT,
      onWillDismiss: (action: DismissContentCoverAction) => {
        action.dismiss()
        this.floating.remove(FloatingPage.IMAGE_VIEWER)
      },
      // 兜底：任何关闭路径（含状态驱动关闭与系统关闭动画收尾）结束后都不残留浮层状态。
      onDisappear: () => {
        if (this.floating.top === FloatingPage.IMAGE_VIEWER) {
          this.floating.remove(FloatingPage.IMAGE_VIEWER)
        }
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
      bottom: (this.currentBreakpoint === 'sm' ? 8 : 24) + this.keyboardHeightVp
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
      bottom: (this.currentBreakpoint === 'sm' ? 8 : 24) + this.keyboardHeightVp
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
