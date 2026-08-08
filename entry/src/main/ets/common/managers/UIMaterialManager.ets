import { uiMaterial } from '@kit.ArkUI'
import { KEY_IMMERSIVE_MATERIAL_ENABLED } from '../constants/AppStorageKeys'

/**
 * 沉浸光感材质工厂。
 *
 * 提供按用途分类的沉浸式系统材质单例，统一收敛材质参数，
 * 降低 Beta API 变更与多组件参数漂移风险。
 *
 * 说明：
 * - 材质对象为纯配置对象，可跨组件共享复用；
 * - 全部材质 applyShadow 均为 false，保留组件自定义 shadow 的生效；
 * - 组件侧统一通过 @StorageProp(KEY_IMMERSIVE_MATERIAL_ENABLED) 读取开关，
 *   开启时背景透明 + systemMaterial(对应材质)，关闭时 systemMaterial(undefined) 恢复原背景。
 */
export class UIMaterialManager {
  /** 标题栏材质：薄样式 + 智能反色（资源色文字/图标可自动反色）。 */
  static readonly titleBarMaterial: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    colorInvert: true,
    applyShadow: false
  })

  /** 悬浮按钮材质：超薄 + 按压交互形变 + 光感流光反馈。 */
  static readonly fabMaterial: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    interactive: true,
    lightEffect: { color: undefined },
    applyShadow: false
  })

  /** 浮层/面板/弹窗容器材质：常规厚度，保证可读性。 */
  static readonly surfaceMaterial: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.REGULAR,
    applyShadow: false
  })

  /** 输入框材质：超薄，不反色不形变，保证占位符/光标稳定可读。 */
  static readonly inputMaterial: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    applyShadow: false
  })

  /** 沉浸光感开关当前是否开启（读 AppStorage，配合 @StorageProp 响应式使用）。 */
  static isEnabled(): boolean {
    return AppStorage.get<boolean>(KEY_IMMERSIVE_MATERIAL_ENABLED) ?? true
  }
}
