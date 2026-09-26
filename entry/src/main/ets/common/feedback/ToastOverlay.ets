/**
 * Toast 浮层内容组件（系统弹窗层承载）
 *
 * ## 为什么不再挂在页面根 Stack 里
 *
 * ArkUI 有两棵互不相交的渲染树（官方《弹窗概述》《设置浮层（OverlayManager）》）：
 *
 * - **Page 页面树**：MainPage 及其全部子组件。`bindSheet` / `bindContentCover` 的**锚点**
 *   虽然写在这棵树里，但面板本体被系统搬到了 Root 下的浮层树。
 * - **Root 浮层树**：OverlayManager / Dialog / Popup / Menu / Toast，以及全部模态
 *   （`bindSheet` / `bindContentCover`）。这棵树整体位于 Page 页面树**之上**。
 *
 * 旧实现在 MainPage 根 Stack 里渲染（页面树），因此只要回复面板（`bindSheet`）或图片查看器
 * （`bindContentCover`）开着，Toast 就被压在下面完全不可见——`zIndex` 与声明顺序都救不了，
 * 因为两者不在同一棵树里。
 *
 * 现在改由 `PromptAction.openCustomDialog` 承载：内容通过 {@link ComponentContent} 提交给
 * 系统，节点落在 **Dialog 层**——与 `bindSheet` / `bindContentCover` 的 `SheetMode.OVERLAY`
 * 属于**同一层**（SDK 对 `SheetMode.OVERLAY` 的注释原文："displayed at the same level as
 * dialog boxes"），而不再是被压在页面树之下。
 *
 * ## 关键参数（改动前请先读 `ToastManager.openImpl`）
 *
 * - `isModal: false`：非模态、无蒙层，官方明确"可以与弹窗周围其他控件进行交互"。
 *   但**它只管蒙层**——事件能否透传由 `maskRect` 决定，见下条。官方默认 `true`，必须显式关掉。
 * - `maskRect`：官方定义是"**遮蔽层区域内的事件不透传，在遮蔽层区域外的事件透传**"，
 *   默认值却是整屏（`{x:0, y:0, width:'100%', height:'100%'}`）。不显式收紧它，
 *   Toast 显示期间**整屏点击都会被吞掉**（实测现象）。本工程收到 0 尺寸，让命中行为
 *   只由气泡自身的 `hitTestBehavior` 决定。
 * - `alignment: DialogAlignment.Bottom` + `offset`：**位置由系统算**。初版照搬旧实现的
 *   "全屏 Stack + `alignContent(Bottom)` + `margin(bottom)`"，但 dialog 对内容节点的约束与
 *   页面树不同，margin 不生效，表现为 Toast 紧贴屏幕底边。
 * - `autoCancel: false`：无蒙层可点，仍显式关闭"点击消失"语义。
 * - `focusable: false`：不抢焦点，避免扰动下层输入与软键盘。
 * - `levelOrder: LevelOrder.clamp(100000)`：仅对**参与 levelOrder 排序的弹窗**有效
 *   （openCustomDialog / CustomDialog / AlertDialog / ActionSheet / showDialog）。
 *   **对 `bindSheet` / `bindContentCover` 无约束力**——它们没有 levelOrder 字段，
 *   层级由 `SheetOptions.mode` 决定。同层内的先后关系官方未明确，属待实测项
 *   （见 `docs/UI_COMPONENT_MIGRATION.md` §7.9）。
 *
 * ## 责任边界
 *
 * - 本组件只负责**渲染与计时**：拿到文案后显示，到时/点击动作后回调并自行隐藏；
 *   **不参与定位**（垂直位置由系统 alignment + offset 决定），也不持有任何全屏容器。
 * - 节点创建、打开、关闭、释放全部在 {@link ToastManager}，因此这里不引用任何 store
 *   （循环依赖也由此避免）。
 * - 文案与按钮走 `@Prop`（单向数据）；**行为**（点击动作、超时通知）走模块级钩子
 *   `toastOverlayHooks`——ArkTS 的 `@Prop` 不用于承接函数成员（官方《@Prop装饰器》
 *   支持类型表不含 Function，本工程 API 26 下是编译期报错），这是唯一可行方案的代价。
 *   **同一条约束的另一半**：`ComponentContent` 节点**绝不复用**。官方 FAQ 明确弹窗关闭**不**触发
 *   内部组件树的 `aboutToDisappear`，而本组件的显示与计时挂在 `aboutToAppear` 上——一旦有人
 *   为省内存改成"复用节点 + `update()` 换文案"，`aboutToAppear` 不会重跑，`visible` 会停在
 *   `false`、计时器不启动，表现为**静默不显示**（不报错）。每次展示必须 `new` 节点。
 * - 气泡命中策略：带动作按钮时 `Block`（独占拦截、防误触），纯文本时 `Transparent`（穿透），
 *   与旧实现一致。
 */

import { AppColors } from '../constants/Constants'

/**
 * `ComponentContent` 构造参数。
 *
 * 用 `class` 而非 `interface`：`ComponentContent<T extends Object>` 要求 Object，
 * 而 ArkTS 对结构化类型支持有限（`@Prop` 官方支持类型表列的是 Object/class/基本类型，
 * 全部官方示例一律用 class）。构造时必须 `new`，不能传对象字面量。
 */
export class ToastOverlayParam {
  /** 主文案 */
  message: string = ''
  /** 动作按钮文案；空串表示纯文本 Toast */
  actionText: string = ''
  /** 展示时长（ms），由 manager 按是否带动作按钮下发 */
  durationMs: number = 0
  /**
   * 距屏幕底部的偏移量（vp），由 manager 算好后经 `BaseDialogOptions.offset.dy` 下发。
   *
   * **位置由系统 alignment + offset 决定，不由本组件布局决定**：初版照搬旧实现的
   * 「全屏 Stack + `alignContent(Bottom)` + `margin(bottom)`」，但系统 dialog 对内容节点的
   * 布局约束与页面树不同，margin 不生效，表现为 Toast 紧贴屏幕底边。改用系统定位后，
   * 本组件只负责气泡自身尺寸（wrapContent），不再持有任何全屏容器。
   *
   * 同理，**底部屏障值不能在本组件内读 AppStorage**：本组件构建在 `ComponentContent`
   * （BuilderNode 体系）里，实测 `@StorageProp` 在其中不生效（`navBarHeight` 恒为 0）。
   */
  bottomOffset: number = 0

  constructor(message: string, actionText: string, durationMs: number, bottomOffset: number) {
    this.message = message
    this.actionText = actionText
    this.durationMs = durationMs
    this.bottomOffset = bottomOffset
  }
}

/**
 * 浮层行为钩子（模块级单例，由 {@link ToastManager} 在每次展示前登记）。
 *
 * 存在的理由：`ComponentContent` 的构建函数是全局 `@Builder`，回调无法经 `@Prop`
 * 传入（工程约定禁止 `@Prop` 承接函数）。钩子只在**运行时**读取，因此每次展示
 * 都可以换成新闭包，不受"节点只构建一次"的限制。
 */
class ToastOverlayHooksClass {
  /** 动作按钮点击回调；纯文本 Toast 时为 null */
  onAction: (() => void) | null = null
  /** 超时通知；由 manager 登记为"关闭并释放节点" */
  onTimeout: () => void = (): void => {}
}

/** 全局唯一浮层钩子实例。 */
export const toastOverlayHooks: ToastOverlayHooksClass = new ToastOverlayHooksClass()

@Component
export struct ToastOverlay {
  /** 文案与按钮：构造时一次性传入（每次展示都新建节点，不做增量刷新） */
  @Prop message: string = ''
  @Prop actionText: string = ''
  @Prop durationMs: number = 0
  /** 距底部偏移（vp）：已含导航条高度，由系统 `offset.dy` 生效，见 {@link ToastOverlayParam.bottomOffset} */
  @Prop bottomOffset: number = 0
  @State private visible: boolean = false

  private hideTimer: number = -1

  aboutToAppear(): void {
    this.visible = true
    this.hideTimer = setTimeout((): void => {
      // 先自行隐藏再回调，避免关闭动画期间动作按钮仍可点击
      this.visible = false
      toastOverlayHooks.onTimeout()
    }, this.durationMs)
  }

  aboutToDisappear(): void {
    clearTimeout(this.hideTimer)
  }

  /**
   * 触发动作按钮回调并立即隐藏。
   *
   * 先取出回调并隐藏，再执行回调：回调内可能再次弹出 Toast，不能被清空状态干扰。
   * 回调闭包只允许捕获值（如 pid），不得依赖已销毁的页面组件实例。
   */
  private triggerAction(): void {
    const action: (() => void) | null = toastOverlayHooks.onAction
    this.visible = false
    clearTimeout(this.hideTimer)
    if (action !== null) {
      action()
    }
  }

  build() {
    if (this.visible) {
      // 外层 Column 只负责"占满宽度并把气泡水平居中"（让系统 alignment/offset 的底部居中有
      // 明确的水平基准）；**没有高度、没有 margin、没有 hitTest 设置**：垂直位置完全交给
      // 系统 alignment + offset，本组件不再参与定位——初版的全屏 Stack 正是错在这里。
      Column() {
        Row() {
          Text(this.message)
            .fontSize(14)
            .fontColor(AppColors.white)
          if (this.actionText.length > 0) {
            Text(this.actionText)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColors.primary)
              .margin({ left: 12 })
          }
        }
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .borderRadius(20)
        .backgroundColor(AppColors.toastBg)
        .onClick((): void => {
          // 点击热区挂在 Row 自身：Block 会阻止子节点接收点击，
          // 若挂在内部 Text 上按钮将永远无法触发
          if (this.actionText.length > 0) {
            this.triggerAction()
          }
        })
        // 有动作按钮时 Block：整条 Toast 可点且独占拦截，事件不穿透到下层列表（防误触）；
        // 纯文本时 Transparent：保持穿透，不拦截帖子交互
        .hitTestBehavior(this.actionText.length > 0 ? HitTestMode.Block : HitTestMode.Transparent)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
  }
}

/**
 * `ComponentContent` 用的全局构建函数。
 *
 * 必须写成全局 `@Builder` 并经 `wrapBuilder` 包成 `WrappedBuilder`（ArkTS 不支持把
 * 组件内 builder 作为值传出）。
 */
@Builder
export function toastOverlayBuilder(param: ToastOverlayParam) {
  ToastOverlay({
    message: param.message,
    actionText: param.actionText,
    durationMs: param.durationMs,
    bottomOffset: param.bottomOffset
  })
}

/** 全局唯一 `WrappedBuilder`：`ComponentContent` 构造需要。 */
export const toastOverlayWrappedBuilder: WrappedBuilder<[ToastOverlayParam]> =
  wrapBuilder<[ToastOverlayParam]>(toastOverlayBuilder)
