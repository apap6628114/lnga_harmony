import { window } from '@kit.ArkUI'
import { DOMAIN_MANAGER, formatError, Logger } from '../utils/Logger'

const logger = new Logger(DOMAIN_MANAGER, 'WindowOrientationManager')

/**
 * 应用级（窗口级）旋转策略：跟随桌面。
 *
 * 直板机桌面固定竖屏 → 应用固定竖屏、不跟随传感器；平板与折叠屏展开态桌面可旋转 →
 * 应用跟随传感器自动旋转，且切换折叠状态时策略自动更新，应用无需按设备形态分别判断。
 *
 * 这是官方《窗口方向》最佳实践「应用首页案例」对内容型应用的推荐值：类直板机上横屏
 * 体验不佳，应固定竖屏；非类直板机（平板、双折叠展开态、三折叠 M/G 态）才开放旋转。
 *
 * 配置值同时写在 module.json5 的 `orientation` 字段（它决定启动方向，且不在启动瞬间
 * 触发旋转动画）。本常量用于"临时覆盖后恢复"，两处必须保持一致。
 *
 * 注意 2in1（电脑形态）上系统不允许应用配置窗口旋转策略（官方《窗口方向》「为多设备
 * 配置旋转策略」表格），该值在电脑上会被忽略，调用本身不报错。
 */
export const APP_ORIENTATION: window.Orientation = window.Orientation.FOLLOW_DESKTOP

/**
 * 全屏媒体浮层（图片查看器）的旋转策略：跟随传感器旋转，但不强制方向。
 *
 * 查看器里横图与长截图都常见，强制横屏会把竖图挤成一条；`AUTO_ROTATION_UNSPECIFIED`
 * 让用户自由转动（直板机上系统会排除反向竖屏，平板/折叠上四向）。官方图库类场景推荐
 * 的同样是该策略。
 */
export const MEDIA_OVERLAY_ORIENTATION: window.Orientation = window.Orientation.AUTO_ROTATION_UNSPECIFIED

/**
 * 应用主窗口。
 *
 * 由 EntryAbility 在 onWindowStageCreate 里注入，**不用 `window.getLastWindow`**：
 * 官方明确该接口需要查找实例、有性能损耗，可能出现"已经横竖屏切换、状态栏还没切换"，
 * 推荐改用 `windowStage.getMainWindowSync()` 同步获取（《窗口方向》「常见问题」）。
 * 且旋转策略只对主窗口生效，子窗口调用无效。
 */
let mainWindow: window.Window | null = null

/**
 * 进入全屏媒体浮层前的旋转策略快照。
 *
 * 用快照而不是硬编码 {@link APP_ORIENTATION} 恢复：应用级策略可能来自配置文件而被
 * 系统改写（折叠态切换、2in1 忽略该策略），配置与常量也可能漂移——恢复"进入前的实际
 * 值"才与官方示例（先 `getPreferredOrientation()` 再设回）一致。
 */
let savedOrientation: window.Orientation | null = null

/**
 * 注入应用主窗口（由 EntryAbility 在窗口创建后调用一次）。
 *
 * @param win - 主窗口实例
 */
export function initWindowOrientationManager(win: window.Window): void {
  mainWindow = win
}

/**
 * 设置主窗口的旋转策略。
 *
 * 失败只记日志：旋转策略是体验优化，不中断业务流程（分屏、悬浮窗、自由多窗、后台等
 * 场景系统会忽略策略，接口仍正常返回）。
 *
 * @param orientation - 旋转策略
 */
export function applyOrientation(orientation: window.Orientation): void {
  if (mainWindow === null) {
    return
  }
  // setPreferredOrientation 声明了 @throws（窗口已销毁等），ArkTS 要求同步异常也要处理；
  // 异步拒绝（2in1 等不支持配置旋转策略的形态）走 catch，属预期行为，不按 error 记录。
  try {
    mainWindow.setPreferredOrientation(orientation).catch((error: Error) => {
      logger.warn('setPreferredOrientation failed: %{public}s', formatError(error))
    })
  } catch (error) {
    logger.warn('setPreferredOrientation threw: %{public}s', formatError(error))
  }
}

/**
 * 进入全屏媒体浮层：先快照当前策略，再放开旋转。
 *
 * **快照只在没有快照时拍**（首次进入）：若关闭动画尚未结束就重新打开查看器，
 * 此刻窗口策略已经是 {@link MEDIA_OVERLAY_ORIENTATION}，再拍一次会把"已放开的值"
 * 记成恢复值，导致最终停在可旋转状态。已有快照说明上一个查看器还没收尾，沿用即可。
 *
 * 快照失败（窗口已销毁等）时置空，退出时回落到 {@link APP_ORIENTATION}。
 */
export function enterMediaOverlayOrientation(): void {
  if (mainWindow === null) {
    return
  }
  if (savedOrientation === null) {
    try {
      savedOrientation = mainWindow.getPreferredOrientation()
    } catch (error) {
      savedOrientation = null
      logger.warn('getPreferredOrientation failed: %{public}s', formatError(error))
    }
  }
  applyOrientation(MEDIA_OVERLAY_ORIENTATION)
}

/**
 * 恢复为进入媒体浮层前的策略，并清空快照。
 *
 * 只由"查看器确实已关闭"的路径调用——若在关闭动画期间重新打开了查看器，旧实例的收尾
 * 回调不能把策略降回去（见 FloatingLayerComponent 的核对逻辑）。
 */
export function exitMediaOverlayOrientation(): void {
  const restore: window.Orientation = savedOrientation === null ? APP_ORIENTATION : savedOrientation
  savedOrientation = null
  applyOrientation(restore)
}

/**
 * 校正回应用级策略（不依赖快照）。
 *
 * 供浮层宿主重建、后台回前台等"状态可能漂移"的时机做幂等校正：这些场景下模态的
 * onDisappear 不保证补发，不校正会停留在"查看器已关但仍可旋转"。
 */
export function restoreAppOrientation(): void {
  savedOrientation = null
  applyOrientation(APP_ORIENTATION)
}

/**
 * 仅设置媒体浮层策略、不改动快照。
 *
 * 供宿主重建时按"查看器仍在显示"的状态补一次设置：此时不能重新快照，否则会把
 * 已经放开的策略记成恢复值。
 */
export function applyMediaOverlayOrientation(): void {
  applyOrientation(MEDIA_OVERLAY_ORIENTATION)
}
