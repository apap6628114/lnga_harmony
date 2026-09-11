import { uiMaterial } from '@kit.ArkUI'

/**
 * 材质工厂：**系统沉浸材质**（官方合规区域）+ **自绘磨砂玻璃**（不合规区域）。
 *
 * 背景：API 26 Release 收紧了沉浸光感（`systemMaterial` / `ImmersiveMaterial`）的生效范围，
 * 页面内容区的普通组件静默失效——组件背景透明、材质消失。因此材质按**生效区域**分成两条通路：
 *
 * 1. **系统沉浸材质**（`dialogMaterial` / `sheetMaterial` / `controlMaterial`）：
 *    用于 Release 允许「页面内全部区域」生效的组件与接口——弹窗类组件（`CustomDialog`、
 *    `AlertDialog`、各 Picker 弹窗）、弹窗类接口（`PromptAction`、Popup/Tips/菜单控制、
 *    **半模态转场**）、以及按钮与选择类组件（`Slider`、`Toggle`、`Select`）。这些位置由系统
 *    接管材质滤镜、折射、高光、阴影与空间动效，视觉上限最高，**优先使用**。
 *    接入点：`CustomDialogControllerOptions.systemMaterial`、`SheetOptions.systemMaterial`、
 *    通用属性 `.systemMaterial(...)`。
 * 2. **自绘磨砂玻璃**（`GlassModifier` 系列）：用于系统材质不生效的区域——页面内容区的普通
 *    组件（本工程无 `Navigation`/`Tabs`，内容区没有标题栏或底部 TabBar 可借位）。由
 *    `backgroundEffect` 背景模糊（半径、饱和度、亮度可控）+ 半透明填充 + 厚度渐变（仅大容器）
 *    + 统一描边 + 柔和投影自绘，不受 Release 生效范围门禁约束。
 *    接入点：`.attributeModifier(UIMaterialManager.xxx)`。
 *
 * 两条通路的边界（官方 FAQ 的层级模型）：**同一个视觉层不要叠加两种材质**。系统材质渲染在
 * **背板层**，而 `backgroundColor` 等属性渲染在**内容层**，内容层会盖住背板层——所以接了系统
 * 材质的弹窗/面板**内部**一律改用 `dialogFieldMaterial`（只给半透明填充与描边、不做背景模糊），
 * 不要再叠 `GlassModifier` 的模糊玻璃；同理，接了系统材质的位置不要再写 `backgroundColor`。
 *
 * 说明：
 * - 材质对象都是稳定的只读配置，跨组件共享复用，渲染期不新建、不修改。
 * - 玻璃的“透”和“可读”靠三者协同，不能只调其中一个：
 *   ① 填充够透（32%~55%）→ 背后内容能透出来；
 *   ② 模糊半径够大（24vp~72vp）→ 透出来的是柔和色块而不是干扰阅读的字迹；
 *   ③ 饱和度增益（1.3~1.5）→ 透出的颜色透亮，玻璃才有“vibrancy”而不是灰蒙蒙。
 * - **边缘一律使用统一描边**。不要按边分色（顶部亮线/底部暗线）：玻璃组件大多是圆角或正圆，
 *   分边描边在圆弧上会渲染成一道突兀的白色弧线（尤其在按钮顶部），这是本工程踩过的坑。
 *   玻璃的厚度感由纵向渐变承担，描边只负责极淡的轮廓。
 * - **纵向渐变只用在足够高的容器上**（面板、栏位）。胶囊按钮、圆形按钮高度小，
 *   矩形渐变会被压成一条“顶部亮带/底部暗带”，因此这些小控件不设渐变，只靠模糊 + 描边 + 投影。
 * - `AttributeModifier` 的应用顺序早于组件自身的属性方法，局部需要偏离默认玻璃时
 *   直接在该组件上写 `.backgroundColor(...)` / `.border(...)` / `.shadow(...)` 覆盖即可；
 *   但**不要为了“透明”再写 `Color.Transparent`**，它会把整层玻璃填充抹掉。
 * - 深浅色由 `$r('app.color.glass_*')` 资源限定词自动切换（base=亮色，dark=暗色）。
 * - 图片查看器等固定暗场景使用 `glass_dark_*`（两套主题同值）配合白色前景。
 * - 前景色统一使用 `sys.color.font_*`（跟随系统深浅色），保证玻璃层上的对比度；
 *   禁止在玻璃层上使用硬编码黑/白文字色，否则深浅色主题切换后不可读。
 * - 主操作按钮不使用玻璃层：确认、保存、发送、退出等承担明确操作语义的按钮保持
 *   实底主题色 + 高对比文字（实底按钮在低算力和复杂背景上更可靠）。
 */

/** 单层磨砂玻璃的视觉参数。 */
export interface GlassSpec {
  /** 玻璃填充色（半透明；由 `backgroundColor` 承载，顺带覆盖组件系统默认底色）。 */
  fill: Resource
  /** 背景模糊半径（vp）：面板要糊得住内容用大值，轻量控件用小值。 */
  blurRadius: number
  /** 背景饱和度增益（>1 让玻璃下的内容颜色更透亮，磨砂玻璃的关键手感）。 */
  saturation: number
  /** 背景亮度增益。 */
  brightness: number
  /** 统一描边色（低对比：亮色主题为暖棕细线，暗色主题为低透明度白线）。 */
  stroke: Resource
  /** 描边宽度（vp），0 表示不描边。 */
  strokeWidth: number
  /** 投影色。 */
  shadowColor: Resource
  /** 投影半径（vp），0 表示不投影。 */
  shadowRadius: number
  /** 投影纵向偏移（vp），正值让玻璃浮起。 */
  shadowOffsetY: number
  /** 厚度渐变的顶部受光色；只给高度足够的容器传，小控件不传。 */
  highlight?: Resource
  /** 厚度渐变的中部收尾色（同色全透明）。 */
  highlightFade?: Resource
  /** 厚度渐变底部暗调色，与 highlight 配合形成玻璃厚度。 */
  shade?: Resource
}

/**
 * 磨砂玻璃通用属性修改器。
 *
 * 一个实例对应一种玻璃用途，跨组件共享；参数在构造时确定，渲染期不再变更，
 * 因此不会引入额外的重复绘制或状态刷新。
 */
export class GlassModifier implements AttributeModifier<CommonAttribute> {
  private readonly spec: GlassSpec

  constructor(spec: GlassSpec) {
    this.spec = spec
  }

  /** 应用玻璃层：半透明填充 + 背景模糊 + 厚度渐变 + 统一描边 + 投影。 */
  applyNormalAttribute(instance: CommonAttribute): void {
    // 填充必须走 backgroundColor：它同时负责覆盖 Button/TextInput 等组件的系统默认底色
    instance.backgroundColor(this.spec.fill)
    if (this.spec.blurRadius > 0) {
      // 模糊只负责“磨砂”，不再叠加颜色，避免与上面的填充重复着色；
      // 系统材质背板之上（blurRadius 为 0）不设模糊，避免二次糊化同一层背景
      instance.backgroundEffect({
        radius: this.spec.blurRadius,
        saturation: this.spec.saturation,
        brightness: this.spec.brightness
      })
    }
    const highlight: Resource | undefined = this.spec.highlight
    const highlightFade: Resource | undefined = this.spec.highlightFade
    const shade: Resource | undefined = this.spec.shade
    if (highlight !== undefined && highlightFade !== undefined && shade !== undefined) {
      // 玻璃厚度：顶部受光高光 → 中部透明 → 底部微暗（仅大容器，见文件头约束）
      instance.linearGradient({
        angle: 180,
        colors: [[highlight, 0.0], [highlightFade, 0.45], [shade, 1.0]]
      })
    }
    if (this.spec.strokeWidth > 0) {
      // 统一描边：圆角/正圆上不会出现分边着色导致的弧线色差
      instance.border({ width: this.spec.strokeWidth, color: this.spec.stroke })
    }
    if (this.spec.shadowRadius > 0) {
      instance.shadow({
        radius: this.spec.shadowRadius,
        color: this.spec.shadowColor,
        offsetY: this.spec.shadowOffsetY
      })
    }
  }
}

export class UIMaterialManager {
  // ==================== 一、系统沉浸材质（官方合规区域，优先使用） ====================

  /**
   * 弹窗背板材质：官方 `CustomDialog` 类弹窗（`AlertDialog` / `TipsDialog` / `SelectDialog` /
   * `CustomContentDialog` 都经 `CustomDialogController` 承载）。
   *
   * 参数是 **API 26 Beta1 时期实测有效的原始配方**（git `0df06e94`）：`REGULAR` + 45% 主题暖白
   * tint + **关闭材质自带阴影**（`applyShadow: false`，浮起感交给组件自定义 `shadow`，否则材质
   * 阴影会盖掉自绘阴影）。Beta1 时同一套参数在自绘浮层上呈现「背景可见 + 柔和模糊」的高透玻璃，
   * 正是本工程要复刻的观感。
   *
   * 用法：`new CustomDialogController({ backgroundColor: Color.Transparent, builder: ...,
   * systemMaterial: UIMaterialManager.dialogMaterial })`——`backgroundColor` 必须显式置透明：
   * 它默认不透明，会作为**内容层**盖住背板层的材质（实测：不置透明时弹窗就是一块白板）。
   *
   * 反例（实测不要走）：把 `style` 提到 `ULTRA_THICK` 并不能得到高透玻璃——那一档本身就是
   * 接近不透明的白板，与背景是否透明无关（两张不同配置的截图逐像素相同）。
   */
  static readonly dialogMaterial: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.REGULAR,
    materialColor: $r('app.color.material_surface_tint'),
    applyShadow: false
  })

  /**
   * 半模态面板背板材质：`SheetOptions.systemMaterial`（半模态转场属弹窗类接口，页面内全区域生效），
   * 参数与 `dialogMaterial` 相同（Beta1 原配方）。
   *
   * **面板本体这一层是 Release 下唯一能拿到材质的位置**：真机逐轮截图实测证明，浮层**内部**的
   * 普通组件写 `.systemMaterial(...)` 不生效——输入框设了材质后完全没有背景、只剩文字。
   * 所以面板内部的工具条 / 输入框 / 中性按钮一律走自绘内容层材质
   * （`dialogFieldMaterial` / `dialogActionMaterial`），不要再给它们接系统材质。
   */
  static readonly sheetMaterial: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.REGULAR,
    materialColor: $r('app.color.material_surface_tint'),
    applyShadow: false
  })

  /**
   * 交互控件材质：官方推荐的「薄材质 + 交互形变 + 点光源反馈」组合，
   * 用于 `Slider` / `Toggle` 等按钮与选择类组件（同样页面内全区域生效）。
   *
   * `interactive` 提供按压形变、`lightEffect` 提供触点流光，二者会**替代**组件默认的点击态与
   * 悬浮态反馈——不要再给同一个控件叠一套含义重复的自定义按压动画。
   * `ToggleType.Checkbox` 官方尚未适配沉浸光感，设置后无效果，不要接入。
   */
  static readonly controlMaterial: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    interactive: true,
    lightEffect: { color: $r('sys.color.font_on_primary') }
  })

  /**
   * 当前设备是否支持沉浸式系统材质（官方兼容性接口）。
   *
   * 返回 `false` 时，`systemMaterial` 上的 `ImmersiveMaterial` **完全不产生视觉效果**
   * （官方声明原文：setting the ImmersiveMaterial object in the systemMaterial attribute will
   * not take effect）。低算力设备不属于此类：它们由系统降级为背景色 / 边框 / 阴影表现。
   */
  static readonly immersiveMaterialSupported: boolean = uiMaterial.isImmersiveMaterialSupported()

  /**
   * 半模态面板的**内容层背景**（`SheetOptions.backgroundColor`）。
   *
   * 设备支持材质时置 `Color.Transparent`，把背景完全让给背板材质；
   * 设备不支持材质时 `Transparent` 会让面板内容直接浮在蒙层上、失去可读背景，
   * 因此回退成半透明玻璃填充兜底。
   */
  static readonly sheetContentBackdrop: ResourceColor =
    uiMaterial.isImmersiveMaterialSupported() ? Color.Transparent : $r('app.color.glass_surface_fill')

  /** 玻璃层上的主前景色（跟随系统深浅色）。 */
  static readonly adaptiveForeground: ResourceColor = $r('sys.color.font_primary')

  /** 玻璃层上的次要前景色与禁用态前景色（跟随系统深浅色）。 */
  static readonly adaptiveSecondaryForeground: ResourceColor = $r('sys.color.font_secondary')

  /** 输入控件的正文色（跟随系统深浅色）。 */
  static readonly inputForeground: ResourceColor = $r('sys.color.font_primary')

  /** 固定暗场景（图片查看器深色玻璃）上的高对比前景色。 */
  static readonly onDarkForeground: ResourceColor = $r('app.color.white')

  /**
   * 浮动操作按钮玻璃：圆形/胶囊轻量磨砂，底下内容透出并提色。
   * 高度小、边缘是圆弧，因此不设纵向渐变，只保留极淡描边 + 投影形成浮起感。
   */
  static readonly fabMaterial: GlassModifier = new GlassModifier({
    fill: $r('app.color.glass_fab_fill'),
    blurRadius: 36,
    saturation: 1.4,
    brightness: 1.03,
    stroke: $r('app.color.glass_fab_stroke'),
    strokeWidth: 1,
    shadowColor: $r('app.color.glass_shadow'),
    shadowRadius: 20,
    shadowOffsetY: 7
  })

  /**
   * 浮层/面板/弹窗容器玻璃：最大半径磨砂，底层内容糊成柔和色块但仍保留色相。
   * 容器高度足够，用三段渐变表达玻璃厚度（顶亮 → 透明 → 底暗）。
   */
  static readonly surfaceMaterial: GlassModifier = new GlassModifier({
    fill: $r('app.color.glass_surface_fill'),
    blurRadius: 72,
    saturation: 1.5,
    brightness: 1.02,
    stroke: $r('app.color.glass_surface_stroke'),
    strokeWidth: 1,
    shadowColor: $r('app.color.glass_shadow_strong'),
    shadowRadius: 40,
    shadowOffsetY: 16,
    highlight: $r('app.color.glass_highlight'),
    highlightFade: $r('app.color.glass_highlight_fade'),
    shade: $r('app.color.glass_shade')
  })

  /**
   * 栏位玻璃（标题栏、消息页栏位）：大半径磨砂 + 厚度渐变，只描边不投影，
   * 避免整条栏位在内容上形成色带或悬浮感的割裂。
   */
  static readonly barMaterial: GlassModifier = new GlassModifier({
    fill: $r('app.color.glass_bar_fill'),
    blurRadius: 56,
    saturation: 1.4,
    brightness: 1.02,
    stroke: $r('app.color.glass_surface_stroke'),
    strokeWidth: 1,
    shadowColor: $r('app.color.glass_shadow'),
    shadowRadius: 0,
    shadowOffsetY: 0,
    highlight: $r('app.color.glass_highlight'),
    highlightFade: $r('app.color.glass_highlight_fade'),
    shade: $r('app.color.glass_shade')
  })

  /**
   * 中性操作玻璃（弹窗内的次要操作、轻量工具栏按钮）：
   * 胶囊按钮高度小，不设渐变；中等半径磨砂 + 极淡描边，不投影，避免按钮之间互相压影。
   */
  static readonly neutralActionMaterial: GlassModifier = new GlassModifier({
    fill: $r('app.color.glass_neutral_fill'),
    blurRadius: 32,
    saturation: 1.4,
    brightness: 1.02,
    stroke: $r('app.color.glass_neutral_stroke'),
    strokeWidth: 1,
    shadowColor: $r('app.color.glass_shadow'),
    shadowRadius: 0,
    shadowOffsetY: 0
  })

  /**
   * 输入框玻璃：中小半径磨砂 + 暖调浅底 + 低透明描边，在面板上呈内嵌感；
   * 不设渐变也不投影，与可点击的玻璃按钮明确区分。
   */
  static readonly inputMaterial: GlassModifier = new GlassModifier({
    fill: $r('app.color.glass_input_fill'),
    blurRadius: 24,
    saturation: 1.3,
    brightness: 1.0,
    stroke: $r('app.color.glass_input_stroke'),
    strokeWidth: 1,
    shadowColor: $r('app.color.glass_shadow'),
    shadowRadius: 0,
    shadowOffsetY: 0
  })

  /**
   * 弹窗 / 半模态面板的**内容层**（不做背景模糊）：用于已经接入系统材质的弹窗与面板内部。
   *
   * 系统材质已经完成了背景模糊，内容层若再叠 `backgroundEffect`，等于对同一层背景二次糊化：
   * 视觉发灰、语义重复、还要多付一次采样。因此这里只给半透明填充与极淡描边，让层级保持
   * 「系统材质（背板层）→ 半透明内容色（内容层）」这种官方两段式。
   *
   * 用法与 `inputMaterial` 相同（`.attributeModifier(...)`），区别只在**用在材质背板之上**。
   */
  static readonly dialogFieldMaterial: GlassModifier = new GlassModifier({
    fill: $r('app.color.glass_field_fill'),
    blurRadius: 0,
    saturation: 1.0,
    brightness: 1.0,
    stroke: $r('app.color.glass_field_stroke'),
    strokeWidth: 1,
    shadowColor: $r('app.color.glass_shadow'),
    shadowRadius: 0,
    shadowOffsetY: 0
  })

  /**
   * 弹窗 / 半模态面板内容层的**中性操作**按钮（不做背景模糊）。
   *
   * 与 `dialogFieldMaterial` 同属内容层，只用更实的填充把「可点击」与「输入区」区分开：
   * 输入框是淡底（12%），中性按钮是实一点的胶囊（32% 暖白/暖灰）+ 一圈描边。
   * 主操作按钮仍按工程契约走实底主题色（见 §12.5），不套这一层。
   */
  static readonly dialogActionMaterial: GlassModifier = new GlassModifier({
    fill: $r('app.color.glass_neutral_fill'),
    blurRadius: 0,
    saturation: 1.0,
    brightness: 1.0,
    stroke: $r('app.color.glass_neutral_stroke'),
    strokeWidth: 1,
    shadowColor: $r('app.color.glass_shadow'),
    shadowRadius: 0,
    shadowOffsetY: 0
  })

  /**
   * 暗场景玻璃：固定深色半透明填充（不随主题变化），用于图片查看器这类
   * 始终处于深色背景上的浮层控件，配合 `onDarkForeground` 保证可读性。
   */
  static readonly darkOverlayMaterial: GlassModifier = new GlassModifier({
    fill: $r('app.color.glass_dark_fill'),
    blurRadius: 48,
    saturation: 1.2,
    brightness: 1.0,
    stroke: $r('app.color.glass_dark_stroke'),
    strokeWidth: 1,
    shadowColor: $r('app.color.glass_shadow'),
    shadowRadius: 0,
    shadowOffsetY: 0
  })

  /** 图片查看器关闭按钮玻璃：与暗场景玻璃同底，额外给一点投影从图片上浮起。 */
  static readonly closeButtonMaterial: GlassModifier = new GlassModifier({
    fill: $r('app.color.glass_dark_fill'),
    blurRadius: 48,
    saturation: 1.2,
    brightness: 1.0,
    stroke: $r('app.color.glass_dark_stroke'),
    strokeWidth: 1,
    shadowColor: $r('app.color.glass_shadow'),
    shadowRadius: 14,
    shadowOffsetY: 5
  })
}
