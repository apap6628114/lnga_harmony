import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { Logger, DOMAIN_APP, formatError } from '../common/utils/Logger'
import { display, window } from '@kit.ArkUI';
import { appStore } from '../store/AppStore';
import { initStatusBarManager, updateStatusBarStyle } from '../common/managers/StatusBarManager';
import { initScreenOnManager } from '../common/managers/ScreenOnManager';
import { startNetworkMonitor } from '../common/managers/NetworkMonitor';
import {
  KEY_THEME_NAME,
  KEY_EFFECTIVE_COLOR_MODE,
  KEY_STATUS_BAR_HEIGHT,
  KEY_NAV_BAR_HEIGHT,
  KEY_CURRENT_BREAKPOINT,
} from '../common/constants/AppStorageKeys';
import { TtsPlayer } from '../common/media/TtsPlayer';

/** EntryAbility 日志记录器。 */
const logger = new Logger(DOMAIN_APP, 'EntryAbility')

/**
 * 应用主 Ability，负责窗口、主题和全局服务初始化。
 */
export default class EntryAbility extends UIAbility {
  /** 当前窗口宽度对应的响应式断点。 */
  private curBp: string = ''

  /** 创建 Ability 并初始化全局服务。 */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    TtsPlayer.initialize(this.context)

    try {
      const appContext = this.context.getApplicationContext()
      appContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET)
      AppStorage.setOrCreate(KEY_THEME_NAME, 'light')
      AppStorage.setOrCreate(KEY_EFFECTIVE_COLOR_MODE, 'light')
    } catch (err) {
      logger.error( 'Failed to set colorMode. Cause: %{public}s', formatError(err));
    }

    appStore.init(this.context)
      .then(() => {
        logger.info( 'AppStore initialized');
      })
      .catch((e: Error) => {
        logger.error( 'AppStore init failed: %{public}s', formatError(e));
      });

    startNetworkMonitor();

    logger.info( '%{public}s', 'Ability onCreate');
  }

  /** 响应系统配置变化并同步主题状态。 */
  onConfigurationUpdate(newConfig: Configuration): void {
    const themeName = AppStorage.get<string>(KEY_THEME_NAME) ?? 'light'
    if (themeName === 'system') {
      const isDark = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      const effective = isDark ? 'dark' : 'light'
      AppStorage.setOrCreate(KEY_EFFECTIVE_COLOR_MODE, effective)
      updateStatusBarStyle(isDark)
    }
  }

  /** 销毁 Ability 并释放全局服务。 */
  onDestroy(): void {
    appStore.setNotificationForegroundActive(false)
    TtsPlayer.shutdown()
    logger.info( '%{public}s', 'Ability onDestroy');
  }

  /** 创建主窗口并配置沉浸式布局、自动旋转和响应式状态。 */
  onWindowStageCreate(windowStage: window.WindowStage): void {
    logger.info( '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        logger.error( 'Failed to load the content. Cause: %{public}s', formatError(err));
        return;
      }

      try {
        const mainWindow = windowStage.getMainWindowSync()

        mainWindow.setWindowLayoutFullScreen(true)
        mainWindow.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED)
          .catch((error: Error) => {
            logger.error('Failed to enable auto rotation. Cause: %{public}s', formatError(error))
          })

        initStatusBarManager(mainWindow)
        initScreenOnManager(mainWindow)
        const isDark: boolean = (AppStorage.get<string>(KEY_EFFECTIVE_COLOR_MODE) ?? 'light') === 'dark'
        updateStatusBarStyle(isDark)

        this.updateSafeArea(mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM))

        this.updateBreakpoint(mainWindow.getWindowProperties().windowRect.width)
        mainWindow.on('windowSizeChange', (size: window.Size) => {
          this.updateBreakpoint(size.width)
          this.updateSafeArea(mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM))
        })
        mainWindow.on('avoidAreaChange', (options: window.AvoidAreaOptions) => {
          if (options.type === window.AvoidAreaType.TYPE_SYSTEM) {
            this.updateSafeArea(options.area)
          }
        })
      } catch (e) {
        logger.error( 'Failed to setup immersive mode. Cause: %{public}s', formatError(e))
      }
    });
  }

  /** 记录窗口舞台销毁事件。 */
  onWindowStageDestroy(): void {
    logger.info( '%{public}s', 'Ability onWindowStageDestroy');
  }

  /** 应用进入前台时恢复前台服务。 */
  onForeground(): void {
    appStore.setNotificationForegroundActive(true)
    if (appStore.isInitialized) {
      appStore.autoCheckinIfNeeded();
    }
    logger.info( '%{public}s', 'Ability onForeground');
  }

  /** 应用进入后台时持久化当前状态。 */
  onBackground(): void {
    appStore.setNotificationForegroundActive(false)
    appStore.flushAll();
    logger.info( '%{public}s', 'Ability onBackground');
  }

  /** 根据当前窗口宽度更新全局响应式断点。 */
  private updateBreakpoint(windowWidth: number): void {
    let densityPixels: number = 1
    try {
      densityPixels = display.getDefaultDisplaySync().densityPixels
    } catch (e) {
      logger.error( 'getDefaultDisplaySync failed')
    }
    const widthVp = windowWidth / densityPixels
    let newBp: string = 'sm'
    if (widthVp < 600) {
      newBp = 'sm'
    } else if (widthVp < 840) {
      newBp = 'md'
    } else {
      newBp = 'lg'
    }
    if (this.curBp !== newBp) {
      this.curBp = newBp
      AppStorage.setOrCreate(KEY_CURRENT_BREAKPOINT, newBp)
      logger.info( 'Breakpoint changed to: %{public}s (%{public}f vp)', newBp, widthVp)
    }
  }

  /** 将系统安全区转换为 vp 并同步到页面共享状态。 */
  private updateSafeArea(avoidArea: window.AvoidArea): void {
    try {
      const density: number = display.getDefaultDisplaySync().densityPixels
      const topInset: number = avoidArea.topRect.height / density
      const bottomInset: number = avoidArea.bottomRect.height / density
      AppStorage.setOrCreate(KEY_STATUS_BAR_HEIGHT, topInset)
      AppStorage.setOrCreate(KEY_NAV_BAR_HEIGHT, bottomInset)
    } catch (error) {
      logger.error('Failed to update safe area. Cause: %{public}s', formatError(error))
    }
  }
}
