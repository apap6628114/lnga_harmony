import { SettingsContext } from '../SettingsContext'
import { SettingsState } from '../SettingsState'
import { KEY_IMMERSIVE_MATERIAL_ENABLED } from '../../../common/constants/AppStorageKeys'

/**
 * 沉浸光感设置域子 store。
 *
 * 承载 immersiveMaterial 字段及其 setter。
 * 开启后应用沉浸式系统材质（systemMaterial / ImmersiveMaterial），
 * 视觉表现由系统光感档位与设备算力自动分级。
 */
export class MaterialSettings {
  private ctx: SettingsContext

  constructor(ctx: SettingsContext) {
    this.ctx = ctx
  }

  /** 设置沉浸光感开关（同步 AppStorage 供 UI 响应式读取，并持久化） */
  setEnabled(enabled: boolean): void {
    this.ctx.state.immersiveMaterial = enabled
    AppStorage.setOrCreate(KEY_IMMERSIVE_MATERIAL_ENABLED, enabled)
    this.ctx.persist()
  }

  /** 从持久化对象加载沉浸光感字段 */
  load(saved: SettingsState): void {
    if (saved.immersiveMaterial !== undefined) {
      this.ctx.state.immersiveMaterial = saved.immersiveMaterial
    }
    AppStorage.setOrCreate(KEY_IMMERSIVE_MATERIAL_ENABLED, this.ctx.state.immersiveMaterial)
  }
}
