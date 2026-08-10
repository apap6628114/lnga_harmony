import { uiMaterial } from '@kit.ArkUI'

/**
 * 沉浸光感材质工厂。
 *
 * 提供按用途分类的沉浸式系统材质单例，统一收敛材质参数，
 * 降低 Beta API 变更与多组件参数漂移风险。
 *
 * 说明：
 * - 材质对象为纯配置对象，可跨组件共享复用；
 * - 悬浮、表面、栏位与输入材质关闭系统阴影，主按钮保留材质阴影；
 * - 组件背景保持透明，由 `systemMaterial` 统一承载材质表现。
 * - 自动反色（colorInvert）仅对官方"特殊资源值"表内的系统颜色资源生效，
 *   薄材质前景必须使用 `sys.color.font_*` / `sys.color.icon_*` 系列资源，
 *   使用 `ohos_id_color_*` 系列资源不会触发反色。
 */
export class UIMaterialManager {
  /** 薄材质上的自适应主前景色（特殊资源，可参与自动反色）。 */
  static readonly adaptiveForeground: ResourceColor = $r('sys.color.font_primary')

  /** 薄材质上的自适应次要前景色与禁用态前景色（特殊资源，可参与自动反色）。 */
  static readonly adaptiveSecondaryForeground: ResourceColor = $r('sys.color.font_secondary')

  /** 输入控件的主题自适应正文色（特殊资源，可参与自动反色）。 */
  static readonly inputForeground: ResourceColor = $r('sys.color.font_primary')

  /**
   * 悬浮按钮材质：超薄通透玻璃球 + 按压交互形变 + 强光感流光反馈。
   *
   * ULTRA_THIN 几乎完全透明，按压时按钮整体形变并泛起白色光波，
   * 呈现"捏一块水润玻璃球"的通透光感。
   */
  static readonly fabMaterial: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    interactive: true,
    lightEffect: { color: '#66FFFFFF' },
    colorInvert: true,
    applyShadow: false
  })

  /**
   * 浮层/面板/弹窗容器材质：常规通透玻璃，兼顾可读性与光感。
   */
  static readonly surfaceMaterial: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.REGULAR,
    materialColor: $r('app.color.material_surface_tint'),
    applyShadow: false
  })

  /** 顶部或底部栏材质：保留常规材质本身的通透感，避免形成整块色带。 */
  static readonly barMaterial: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.REGULAR,
    applyShadow: false
  })

  /**
   * 主操作按钮材质：通透琥珀玻璃 + 按压形变 + 光感流光 + 材质高光。
   *
   * materialColor 仅以低透明度着入主题主色，背后内容仍能透出；
   * interactive + lightEffect 使按压时按钮形变并泛起暖色光波；
   * applyShadow 打开材质自带阴影，让按钮像悬浮的玻璃透镜。
   */
  static readonly buttonMaterial: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    materialColor: $r('app.color.material_accent_tint'),
    interactive: true,
    lightEffect: { color: '#66FFE9C9' },
    colorInvert: true,
    applyShadow: true
  })

  /**
   * 中性主操作材质：不添加主题色染色，以自适应前景和白色流光保证明暗背景下的纯净对比。
   */
  static readonly neutralActionMaterial: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    interactive: true,
    lightEffect: { color: '#66FFFFFF' },
    colorInvert: true,
    applyShadow: true
  })

  /** 输入框材质：薄材质叠加主题透明偏色，并由系统前景色保证正文、占位符与光标可读。 */
  static readonly inputMaterial: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    materialColor: $r('app.color.material_input_tint'),
    colorInvert: true,
    applyShadow: false
  })

  /**
   * 关闭按钮材质：超薄玻璃 + 自动反色。
   *
   * 严格对齐官方 colorInvert 示例（ULTRA_THIN + colorInvert），
   * 不叠加 interactive、lightEffect、阴影与边框，保证反色触发条件最简。
   */
  static readonly closeButtonMaterial: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    colorInvert: true
  })
}
