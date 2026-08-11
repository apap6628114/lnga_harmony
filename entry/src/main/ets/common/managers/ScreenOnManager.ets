/**
 * 屏幕常亮管理器
 *
 * 应用主页面（登录进入后）保持屏幕不息屏，基于 window.setWindowKeepScreenOn 实现
 * （API 9+，无需权限，窗口位于前台时生效）。
 *
 * 主窗口由 EntryAbility 在 onWindowStageCreate 阶段注入，用法与 StatusBarManager 一致；
 * 按官方约束，仅在应用主界面常驻场景开启，退出主页面（aboutToDisappear）时关闭。
 */

import { window } from '@kit.ArkUI';
import { Logger, DOMAIN_MANAGER, formatError } from '../utils/Logger';

const logger = new Logger(DOMAIN_MANAGER, 'ScreenOnManager')

/** 主窗口引用，由 initScreenOnManager 注入。 */
let mainWindow: window.Window | null = null

/**
 * 注入主窗口，应在 EntryAbility.onWindowStageCreate 中与状态栏初始化一并调用。
 * @param win 应用主窗口
 */
export function initScreenOnManager(win: window.Window): void {
  mainWindow = win
}

/**
 * 开启屏幕常亮：主窗口位于前台时设备屏幕保持不息屏。
 * 仅在应用主页面（登录进入后）调用；退出主页面时应调用 disableKeepScreenOn 恢复自动息屏。
 */
export function enableKeepScreenOn(): void {
  if (!mainWindow) {
    logger.warn('main window not initialized, skip keep screen on')
    return
  }
  mainWindow.setWindowKeepScreenOn(true).catch((err: Error) => {
    logger.error('enable keep screen on failed: %{public}s', formatError(err))
  })
}

/**
 * 关闭屏幕常亮：恢复系统自动息屏策略。
 */
export function disableKeepScreenOn(): void {
  if (!mainWindow) {
    return
  }
  mainWindow.setWindowKeepScreenOn(false).catch((err: Error) => {
    logger.error('disable keep screen on failed: %{public}s', formatError(err))
  })
}
