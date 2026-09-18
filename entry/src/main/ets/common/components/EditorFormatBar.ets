/**
 * 编辑器格式工具行（回复 / 贴条 / 发新主题共用）。
 *
 * 布局契约：
 * - **第一行**：常显「表情 / 图片 / 超链接」+ 折叠按钮，整体**左对齐**、超出宽度时横向滑动；
 *   右端固定「匿名 / 预览」两个开关，**右对齐**且不随格式区滚动；中间一条极淡分隔线。
 * - **第二行**：展开后另起一行显示「粗体 / 斜体 / 下划线 / 删除线 / 引用 / @」，
 *   同样左对齐，窄屏才触发横滑——避免一进来就要滑动找工具。
 *
 * 视觉契约（docs/IMMERSIVE_LIGHT_DESIGN.md §12）：本组件位于系统材质背板之上的**内容层**，
 * 不叠任何背景模糊；激活态靠颜色区分（主题色图标 + 极淡琥珀底），未激活态保持透明，
 * 把材质背板让出来——图标按钮不占填充，避免整行被压成一排骨块。
 *
 * 状态归属：匿名与预览属于宿主编辑器的语义状态（`@Link` / `@Prop` + 回调），格式插入与
 * 表情面板、预览切换同样回调宿主——本组件只管工具行自身的「折叠 / 展开」。
 */

import { AppColors } from '../constants/Constants'
import { appStore } from '../../store/AppStore'
import { UIMaterialManager } from '../managers/UIMaterialManager'

/**
 * 工具行按钮宽度（vp）、高度（vp）、按钮间距（vp）与图标边长（vp）。
 *
 * 按钮宽 32、间距 2：每个图标仍保有 32×32 的点击区，但图标之间的视觉留白收到约 14vp
 * （32 − 18）—— 折叠态只有四个按钮时不会显得空旷，展开态也更省横向空间。
 */
const TOOL_BUTTON_W: number = 32
const TOOL_BUTTON_H: number = 32
const TOOL_BUTTON_GAP: number = 2
const TOOL_ICON_SIZE: number = 18

/** 编辑器格式操作。 */
export interface FormatAction {
  /** 无障碍标签：图标按钮没有可读文案，语义靠它表达。 */
  label: string

  /** 操作标识：BBCode 标签，或 `emoticon` / `anony` 这类编辑器动作。 */
  tag: string

  /** 工具行图标。 */
  icon: Resource
}

/**
 * 常显工具操作：表情、图片、超链接。
 *
 * 三项都属于「往正文里插入内容」的高频操作，折叠态下也保持可见——窄屏手机不滑动
 * 即可触达全部常显项。
 *
 * 「图片」**只有一个入口**：选中动态照片就按动态照片的规则发，否则按普通图片发，
 * 判断与分流都在 `MovingPhotoExport.pickImage`（详见其文件头）。这里不再单列
 * 「动态照片」按钮——同一件事两个入口会让用户在点选前就得先想清楚自己选的是哪种。
 */
const PRIMARY_ACTIONS: FormatAction[] = [
  { label: '表情', tag: 'emoticon', icon: $r('app.media.icon_emoticon') },
  { label: '图片', tag: 'img', icon: $r('app.media.icon_image') },
  { label: '超链接', tag: 'url', icon: $r('app.media.icon_link') },
]

/**
 * 折叠工具操作：粗体、斜体、下划线、删除线、引用、@。
 *
 * 都在「选中文字后加格式」的次高频路径上，默认收在折叠按钮之后，展开时另起一行显示。
 */
const SECONDARY_ACTIONS: FormatAction[] = [
  { label: '粗体', tag: 'b', icon: $r('app.media.icon_format_bold') },
  { label: '斜体', tag: 'i', icon: $r('app.media.icon_format_italic') },
  { label: '下划线', tag: 'u', icon: $r('app.media.icon_format_underline') },
  { label: '删除线', tag: 'del', icon: $r('app.media.icon_format_strike') },
  { label: '引用', tag: 'quote', icon: $r('app.media.icon_format_quote') },
  { label: '@', tag: 'at', icon: $r('app.media.icon_at') },
]

/**
 * 匿名发布开关。
 *
 * 语义上它不是「插入一段格式」，但同属发布前的编辑决策，因此并入工具行；
 * 固定在右端（滑动区之外）保证可见性，与格式项之间用一条极淡分隔线区分。
 */
const ANONY_ACTION: FormatAction = {
  label: '匿名发布',
  tag: 'anony',
  icon: $r('app.media.icon_shield')
}

/** 使用沉浸光感材质承载回复、贴条与发新主题的格式工具行。 */
@Component
export struct EditorFormatBar {
  /** 匿名发布开关（双向：工具行直接切换状态并给出 Toast 反馈）。 */
  @Link isAnonymous: boolean

  /** 是否处于发布预览模式：预览态下格式区收起，只留「返回编辑」入口。 */
  @Prop previewMode: boolean

  /** 表情面板是否展开，决定「表情」按钮的激活态。 */
  @Prop emojiPanelOpen: boolean

  /** 是否展开高级格式行。 */
  @State formatExpanded: boolean = false

  /** 格式动作回调（tag 见 `PRIMARY_ACTIONS` / `SECONDARY_ACTIONS`；匿名不在其中，由工具行内部处理）。 */
  onFormat?: (tag: string) => void

  /** 预览 / 返回编辑回调。 */
  onTogglePreview?: () => void

  /**
   * 判断工具按钮是否处于激活态。
   *
   * 只有「开关型」动作（表情面板、匿名发布）有激活态；插入型格式（粗体、链接等）
   * 是一次性动作，不驻留状态，因此统一返回未激活。
   */
  private isFormatActive(tag: string): boolean {
    if (tag === 'emoticon') {
      return this.emojiPanelOpen
    }
    if (tag === 'anony') {
      return this.isAnonymous
    }
    return false
  }

  /** 切换匿名发布。原「隐藏账号信息」副文案的说明改由 Toast 承载。 */
  private toggleAnonymous(): void {
    this.isAnonymous = !this.isAnonymous
    appStore.showToast(this.isAnonymous ? '匿名发布已开启，将隐藏账号信息' : '匿名发布已关闭')
  }

  /** 分发工具行动作：匿名在本组件内处理，其余交给宿主编辑器插入。 */
  private handleAction(action: FormatAction): void {
    if (action.tag === 'anony') {
      this.toggleAnonymous()
      return
    }
    if (this.onFormat !== undefined) {
      this.onFormat(action.tag)
    }
  }

  /** 预览 / 返回编辑。 */
  private handlePreview(): void {
    if (this.onTogglePreview !== undefined) {
      this.onTogglePreview()
    }
  }

  /**
   * 解析工具按钮的无障碍文案。
   *
   * 开关型动作必须把**当前状态**说出来：匿名开关在图标化后只剩颜色差异，读屏用户
   * 无法从「匿名发布」四个字判断它是否已开启；表情按钮同理需要表达面板是否展开。
   */
  private resolveAccessibilityLabel(action: FormatAction): string {
    if (action.tag === 'anony') {
      return this.isAnonymous ? '匿名发布，已开启' : '匿名发布，未开启'
    }
    if (action.tag === 'emoticon') {
      return this.emojiPanelOpen ? '表情，面板已展开' : '表情'
    }
    return action.label
  }

  /**
   * 工具行图标按钮。
   *
   * 激活态只用颜色区分（主题色图标 + 极淡琥珀底），尺寸与位置恒定，避免同一行内因状态
   * 切换产生位移；未激活态保持完全透明——图标按钮不占填充，让面板材质背板尽可能透出来。
   * （§12.8 的「描边 + 极淡填充」针对的是输入区与中性按钮这类需要明确边界的元素；工具行
   * 图标若逐个加填充，整行会被压成一排骨块，反而丢掉材质。）状态一律经 `this` 读取，
   * 保证 `@Prop` / `@State` 变化能刷新到 `@Builder` 内部。
   */
  @Builder
  FormatButton(action: FormatAction) {
    Column() {
      Image(action.icon)
        .width(TOOL_ICON_SIZE)
        .height(TOOL_ICON_SIZE)
        .fillColor(this.isFormatActive(action.tag)
          ? AppColors.primary
          : UIMaterialManager.adaptiveIcon)
    }
    .width(TOOL_BUTTON_W)
    .height(TOOL_BUTTON_H)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(10)
    .backgroundColor(this.isFormatActive(action.tag) ? AppColors.selectionTint : Color.Transparent)
    .accessibilityText(this.resolveAccessibilityLabel(action))
    .onClick(() => { this.handleAction(action) })
  }

  /** 构建格式工具行（第一行 + 可折叠的第二行）。 */
  build() {
    Column() {
      // 第一行：左对齐格式区（可横滑）+ 右对齐开关区
      Row() {
        if (this.previewMode) {
          Text('发布预览')
            .fontSize(12)
            .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
            .margin({ left: 10 })
          Blank().layoutWeight(1)
        } else {
          Scroll() {
            Row({ space: TOOL_BUTTON_GAP }) {
              ForEach(PRIMARY_ACTIONS, (action: FormatAction) => {
                this.FormatButton(action)
              }, (action: FormatAction) => action.tag)

              // 折叠 / 展开控制：紧随常显格式之后。高级格式在**下一行**展开，
              // 因此折叠态箭头朝下（提示下方还有内容），展开态翻转朝上（点击收回）。
              Column() {
                Image($r('app.media.icon_chevron_down'))
                  .width(TOOL_ICON_SIZE)
                  .height(TOOL_ICON_SIZE)
                  .fillColor(UIMaterialManager.adaptiveIcon)
                  .rotate({ angle: this.formatExpanded ? 180 : 0 })
              }
              .width(TOOL_BUTTON_W)
              .height(TOOL_BUTTON_H)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .borderRadius(10)
              .backgroundColor(Color.Transparent)
              .accessibilityText(this.formatExpanded ? '收起高级格式' : '展开高级格式')
              .onClick(() => { this.formatExpanded = !this.formatExpanded })
            }
            // Scroll 在内容窄于容器时会把子组件居中摆放，折叠态下格式区就会看着像居中；
            // 撑满最小宽度 + 显式起端对齐后，内容必然从左侧起排，展开态仍由内容撑开。
            .constraintSize({ minWidth: '100%' })
            .justifyContent(FlexAlign.Start)
          }
          .layoutWeight(1)
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)

          Divider()
            .vertical(true)
            .height(16)
            .color($r('app.color.glass_field_stroke'))
            .margin({ left: 4, right: 4 })
        }

        // 匿名发布常显在滑动区之外，且**不受预览模式影响**：改造前它是底部操作行里的一个开关、
        // 不在预览分支内，预览态随时可切换；搬进工具行后必须保持同样的可达性，否则「预览时
        // 才发现要匿名」就只能先退出预览（属功能净减少）。
        this.FormatButton(ANONY_ACTION)

        Column() {
          Image(this.previewMode ? $r('app.media.icon_compose') : $r('app.media.icon_preview'))
            .width(TOOL_ICON_SIZE)
            .height(TOOL_ICON_SIZE)
            .fillColor(this.previewMode
              ? AppColors.primary
              : UIMaterialManager.adaptiveIcon)
        }
        .width(TOOL_BUTTON_W)
        .height(TOOL_BUTTON_H)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(10)
        .backgroundColor(this.previewMode ? AppColors.selectionTint : Color.Transparent)
        .margin({ left: TOOL_BUTTON_GAP })
        .accessibilityText(this.previewMode ? '返回编辑' : '发布预览')
        .onClick(() => { this.handlePreview() })
      }
      .width('100%')
      .padding({ top: 8 })
      .alignItems(VerticalAlign.Center)

      // 第二行：折叠格式独占一行，六个插入型格式一次排开，不再挤进第一行抢宽度
      if (this.formatExpanded && !this.previewMode) {
        Scroll() {
          Row({ space: TOOL_BUTTON_GAP }) {
            ForEach(SECONDARY_ACTIONS, (action: FormatAction) => {
              this.FormatButton(action)
            }, (action: FormatAction) => action.tag)
          }
          .constraintSize({ minWidth: '100%' })
          .justifyContent(FlexAlign.Start)
        }
        .width('100%')
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .padding({ top: 4 })
      }
    }
    .width('100%')
  }
}
