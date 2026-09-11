/**
 * 磨砂玻璃材质工厂。
 *
 * 背景：API 26 Release 收紧了沉浸光感（`systemMaterial` / `ImmersiveMaterial`）的生效范围，
 * 页面内容区的普通组件静默失效——组件背景透明、材质消失。本工程不再依赖沉浸光感，
 * 改用自绘磨砂玻璃层：`backgroundEffect` 背景模糊（半径、饱和度、亮度可控）+ 半透明填充 +
 * 厚度渐变（仅大容器）+ 统一描边 + 柔和投影。
 *
 * 说明：
 * - 材质对象是稳定的只读配置（`AttributeModifier`），可跨组件共享复用；
 *   调用点通过 `.attributeModifier(UIMaterialManager.xxx)` 绑定，不要再写 `.systemMaterial(...)`。
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
    // 模糊只负责“磨砂”，不再叠加颜色，避免与上面的填充重复着色
    instance.backgroundEffect({
      radius: this.spec.blurRadius,
      saturation: this.spec.saturation,
      brightness: this.spec.brightness
    })
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
