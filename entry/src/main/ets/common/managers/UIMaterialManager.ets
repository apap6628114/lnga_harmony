import { uiMaterial } from '@kit.ArkUI'

/**
 * 沉浸光感材质工厂。
 *
 * 提供按用途分类的沉浸式系统材质单例，统一收敛材质参数，
 * 降低 Beta API 变更与多组件参数漂移风险。
 *
 * 说明：
 * - 材质对象为纯配置对象，可跨组件共享复用；
 * - 全部材质 applyShadow 均为 false，保留组件自定义 shadow 的生效；
 * - 组件背景保持透明，由 `systemMaterial` 统一承载材质表现。
 */
export class UIMaterialManager {
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
    applyShadow: false
  })

  /**
   * 浮层/面板/弹窗容器材质：常规通透玻璃，兼顾可读性与光感。
   */
  static readonly surfaceMaterial: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
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
    materialColor: '#33C08A4A',
    interactive: true,
    lightEffect: { color: '#66FFE9C9' },
    applyShadow: true
  })

  /** 输入框材质：超薄，不反色不形变，保证占位符/光标稳定可读。 */
  static readonly inputMaterial: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    applyShadow: false
  })
}
