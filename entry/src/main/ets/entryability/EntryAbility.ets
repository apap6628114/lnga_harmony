import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { Logger, DOMAIN_APP, formatError } from '../common/utils/Logger'
import { display, window } from '@kit.ArkUI';
import { appStore } from '../store/AppStore';
import { initStatusBarManager, updateStatusBarStyle } from '../common/managers/StatusBarManager';
import { startNetworkMonitor } from '../common/managers/NetworkMonitor';
import {
  KEY_THEME_NAME,
  KEY_EFFECTIVE_COLOR_MODE,
  KEY_STATUS_BAR_HEIGHT,
  KEY_NAV_BAR_HEIGHT,
  KEY_CURRENT_BREAKPOINT,
} from '../common/constants/AppStorageKeys';

const logger = new Logger(DOMAIN_APP, 'EntryAbility')

export default class EntryAbility extends UIAbility {
  private curBp: string = 'sm'

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 在 loadContent 前尽可能早地应用用户保存的主题，减少主题切换闪烁
    // 注意：此时 appStore 尚未 init，直接使用默认主题；appStore.init 完成后会通过 applyCurrentTheme 修正
    try {
      const appContext = this.context.getApplicationContext()
      appContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET)
      AppStorage.setOrCreate(KEY_THEME_NAME, 'light')
      AppStorage.setOrCreate(KEY_EFFECTIVE_COLOR_MODE, 'light')
    } catch (err) {
      logger.error( 'Failed to set colorMode. Cause: %{public}s', formatError(err));
    }

    // 初始化 AppStore（异步，Index 页面会等待 initialized 标志）
    appStore.init(this.context)
      .then(() => {
        logger.info( 'AppStore initialized');
        if (appStore.isInitialized && appStore.auth.isAuthenticated) {
          appStore.refreshNotifications(false);
        }
      })
      .catch((e: Error) => {
        logger.error( 'AppStore init failed: %{public}s', formatError(e));
      });

    startNetworkMonitor();

    logger.info( '%{public}s', 'Ability onCreate');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    const themeName = AppStorage.get<string>(KEY_THEME_NAME) ?? 'light'
    if (themeName === 'system') {
      const isDark = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      const effective = isDark ? 'dark' : 'light'
      AppStorage.setOrCreate(KEY_EFFECTIVE_COLOR_MODE, effective)
      updateStatusBarStyle(isDark)
    }
  }

  onDestroy(): void {
    logger.info( '%{public}s', 'Ability onDestroy');
  }

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

        initStatusBarManager(mainWindow)
        const isDark: boolean = (AppStorage.get<string>(KEY_EFFECTIVE_COLOR_MODE) ?? 'light') === 'dark'
        updateStatusBarStyle(isDark)

        const avoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM)
        const density = display.getDefaultDisplaySync().densityPixels
        const topInset = avoidArea.topRect.height / density
        const bottomInset = avoidArea.bottomRect.height / density
        AppStorage.setOrCreate(KEY_STATUS_BAR_HEIGHT, topInset)
        AppStorage.setOrCreate(KEY_NAV_BAR_HEIGHT, bottomInset)

        this.updateBreakpoint(mainWindow.getWindowProperties().windowRect.width)
        mainWindow.on('windowSizeChange', (size: window.Size) => {
          this.updateBreakpoint(size.width)
        })
      } catch (e) {
        logger.error( 'Failed to setup immersive mode. Cause: %{public}s', formatError(e))
      }
    });
  }

  onWindowStageDestroy(): void {
    logger.info( '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    if (appStore.isInitialized) {
      appStore.autoCheckinIfNeeded();
      appStore.refreshNotifications(false);
    }
    logger.info( '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // 应用进入后台时持久化所有数据，防止被系统杀死后丢失
    appStore.flushAll();
    logger.info( '%{public}s', 'Ability onBackground');
  }

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
}
