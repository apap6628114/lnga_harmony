import { window } from '@kit.ArkUI';
import { Logger, DOMAIN_MANAGER } from '../utils/Logger'

const logger = new Logger(DOMAIN_MANAGER, 'StatusBarManager')

let mainWindow: window.Window | null = null;

export function initStatusBarManager(win: window.Window): void {
  mainWindow = win;
}

export function updateStatusBarStyle(isDark: boolean): void {
  if (!mainWindow) {
    return;
  }
  try {
    // 注意：statusBarContentColor 设置后 isStatusBarLightIcon 即失效（SDK 语义），
    // 这里只设置 contentColor，避免两套字段冗余、后续维护时改一处漏一处。
    const sysBarProps: window.SystemBarProperties = {
      statusBarColor: '#00000000',
      statusBarContentColor: isDark ? '#ffffff' : '#000000',
      navigationBarColor: '#00000000',
      navigationBarContentColor: isDark ? '#ffffff' : '#000000'
    };
    mainWindow.setWindowSystemBarProperties(sysBarProps).catch((e: Error) => {
      logger.error('setWindowSystemBarProperties failed: %{public}s', (e as Error).message)
    });
  } catch (e) {
    logger.error('updateStatusBarStyle failed: %{public}s', (e as Error).message)
  }
}
