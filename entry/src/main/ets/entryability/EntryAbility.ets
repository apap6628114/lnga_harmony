import {
  AbilityConstant,
  Configuration,
  ConfigurationConstant,
  UIAbility,
  Want,
  systemConfiguration
} from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { Logger, DOMAIN_APP, formatError } from '../common/utils/Logger'
import { display, window } from '@kit.ArkUI';
import { UIContext } from '@ohos.arkui.UIContext'
import { appStore } from '../store/AppStore';
import { initStatusBarManager, updateStatusBarStyle } from '../common/managers/StatusBarManager';
import { initScreenOnManager } from '../common/managers/ScreenOnManager';
import { startNetworkMonitor } from '../common/managers/NetworkMonitor';
import {
  KEY_THEME_NAME,
  KEY_EFFECTIVE_COLOR_MODE,
  KEY_SYSTEM_COLOR_MODE,
  KEY_STATUS_BAR_HEIGHT,
  KEY_NAV_BAR_HEIGHT,
  KEY_CURRENT_BREAKPOINT,
  KEY_WINDOW_WIDTH_VP,
} from '../common/constants/AppStorageKeys';
import { TtsPlayer } from '../common/media/TtsPlayer';
import { markPageLoaded } from '../common/infra/PageLifecycle';

/** EntryAbility 日志记录器。 */
const logger = new Logger(DOMAIN_APP, 'EntryAbility')

/**
 * 解码后位图的内存缓存张数上限。
 *
 * `UIContext.setImageCacheCount` 的 SDK 声明写明 **if not set, the application will not
 * cache any decoded image**——不设就是 0、完全不缓存。缓存关闭时，打开图片查看器要同时
 * 解码当前图与左右相邻两张全屏大图，正文里已解码的位图被挤掉；退出查看器后正文 `Image`
 * 需要**重新解码**，那一两帧空白就是"进出查看器后帖子图片闪一下"。
 *
 * 取 20（真机验证"进出查看器不再闪屏"时的实测值），理由有两条：
 * 1. 缓存是 **LRU**，被挤掉的总是"最久没用"的，而我们只关心"刚看过的那几张"
 *    （正文可见图 + 查看器相邻三张）——它们始终处于最近使用端。20 张足够覆盖
 *    「查看器三张 + 正文一屏可见图」并留出余量，再大只对"滚回去看很早以前的图"有帮助。
 * 2. 正文图片的 `autoResize` 默认为 **false**（按原图尺寸解码，见图片链路盘点 G6），
 *    单张解码后位图可能到十几 MB——这也是**不能**取更大值的原因。
 *
 * **这是"内存 ↔ 闪烁"的取舍旋钮**：真机上若发现内存压力优先下调（如 10），
 * 若仍偶发闪烁再上调；改值请同步 `docs/research/IMAGE_PIPELINE_AUDIT.md` §6.2 的记录。
 */
const IMAGE_CACHE_COUNT: number = 20

/**
 * 解码前图片原始数据的内存缓存上限（字节）。
 *
 * 与 `IMAGE_CACHE_COUNT` 配套：命中原始数据缓存时不必重新走网络/磁盘即可重新解码，
 * 是"位图被挤出缓存后快速补回"的兜底。NGA 图片多为几百 KB 量级，64MB 足够容纳大量条目。
 */
const IMAGE_RAW_CACHE_BYTES: number = 64 * 1024 * 1024

/**
 * 应用主 Ability，负责窗口、主题和全局服务初始化。
 */
export default class EntryAbility extends UIAbility {
  /** 当前窗口宽度对应的响应式断点。 */
  private curBp: string = ''

  /**
   * 系统配置更新回调（API 24+，系统级订阅）。
   *
   * 与 onConfigurationUpdate 的区别：onSystemConfigurationUpdated 传的是
   * **系统真实**颜色模式，且与应用是否主动 setColorMode 无关——应用固定
   * light/dark 主题期间系统切换深浅色同样回调，保证 KEY_SYSTEM_COLOR_MODE
   * 缓存始终新鲜（供主题切回"跟随系统"时使用）。
   *
   * 注：appStore.init 完成前 KEY_THEME_NAME 尚未写入（onCreate 不写），
   * 此时按 'light' 处理无害——init 完成后 applyCurrentTheme 会校正。
   */
  private sysConfigUpdatedCallback: systemConfiguration.UpdatedCallback = {
    onColorModeUpdated: (colorMode: ConfigurationConstant.ColorMode): void => {
      const sysMode: string = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ? 'dark' : 'light'
      AppStorage.setOrCreate(KEY_SYSTEM_COLOR_MODE, sysMode)
      const themeName = AppStorage.get<string>(KEY_THEME_NAME) ?? 'light'
      if (themeName === 'system') {
        AppStorage.setOrCreate(KEY_EFFECTIVE_COLOR_MODE, sysMode)
        updateStatusBarStyle(sysMode === 'dark')
      }
    }
  }

  /** 创建 Ability 并初始化全局服务。 */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    TtsPlayer.initialize(this.context)

    // 冷启动（进程重建）时应用颜色模式为默认跟随系统，此时
    // resourceManager.getConfigurationSync() 返回的即系统真实颜色模式：
    // - 写入 KEY_SYSTEM_COLOR_MODE 缓存（供"跟随系统"主题使用，此后由
    //   onSystemConfigurationUpdated 系统级订阅实时维护，固定主题期间也不过时）；
    // - 同时初始化 KEY_EFFECTIVE_COLOR_MODE（持久化主题尚未加载，以系统模式
    //   近似，保证冷启动状态栏图标与页面资源一致——不得硬编码 'light'）。
    // 真实主题（system/light/dark）由 appStore.init → applyCurrentTheme() 接管。
    try {
      const sysColorMode: number = this.context.resourceManager.getConfigurationSync().colorMode
      const sysMode: string = sysColorMode === resourceManager.ColorMode.DARK ? 'dark' : 'light'
      AppStorage.setOrCreate(KEY_SYSTEM_COLOR_MODE, sysMode)
      AppStorage.setOrCreate(KEY_EFFECTIVE_COLOR_MODE, sysMode)
    } catch (err) {
      logger.error('Failed to read system colorMode. Cause: %{public}s', formatError(err))
      AppStorage.setOrCreate(KEY_SYSTEM_COLOR_MODE, 'light')
      AppStorage.setOrCreate(KEY_EFFECTIVE_COLOR_MODE, 'light')
    }
    // 订阅注册独立于初始化 try：即使初始化读取失败也必须建立系统级订阅，
    // 依赖回调在系统切换时校正 KEY_SYSTEM_COLOR_MODE（否则降级值将冻结）。
    try {
      this.context.getApplicationContext().onSystemConfigurationUpdated(this.sysConfigUpdatedCallback)
    } catch (err) {
      logger.error('Failed to register system configuration listener. Cause: %{public}s', formatError(err))
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

  /**
   * 响应系统配置变化：深浅色同步统一走 onSystemConfigurationUpdated 系统级订阅。
   *
   * 不使用 onConfigurationUpdate 判定深浅色的原因：
   * - 应用主动 setColorMode 后官方语义下不再收到该回调；
   * - 应用从固定模式切回跟随系统（LIGHT→NOT_SET）的切换事件中 colorMode
   *   可能为 NOT_SET，直接按 DARK/LIGHT 判定会得出错误结果。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    logger.info('Configuration updated, colorMode=%{public}d',
      newConfig.colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET)
  }

  /** 销毁 Ability 并释放全局服务。 */
  onDestroy(): void {
    appStore.setForegroundActive(false)
    TtsPlayer.shutdown()
    try {
      this.context.getApplicationContext().offSystemConfigurationUpdated(this.sysConfigUpdatedCallback)
    } catch (err) {
      logger.error('offSystemConfigurationUpdated failed: %{public}s', formatError(err))
    }
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

      // 页面已加载完成：此后 setColorMode 满足官方 NOTE 调用时机
      //（applyCurrentTheme 依据本标志决定是否执行 setColorMode）
      markPageLoaded()

      try {
        const mainWindow = windowStage.getMainWindowSync()

        // Toast 浮层经 PromptAction.openCustomDialog + ComponentContent 承载，内容节点
        // 必须由 UI 上下文创建。页面加载完成是唯一可靠的注入点：早于此前产生的提示由
        // ToastManager 暂存，注入时补播。
        appStore.toastManager.attachUIContext(mainWindow.getUIContext())

        this.enableImageDecodeCache(mainWindow)

        mainWindow.setWindowLayoutFullScreen(true)
        mainWindow.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED)
          .catch((error: Error) => {
            logger.error('Failed to enable auto rotation. Cause: %{public}s', formatError(error))
          })

        initStatusBarManager(mainWindow)
        initScreenOnManager(mainWindow)
        // 官方 NOTE：setColorMode 须在窗口创建且页面加载完成后调用。
        // appStore.init 可能先于页面加载完成（此时 init 尾部的 applyCurrentTheme
        // 调 setColorMode 不满足调用时机），此处兜底：已初始化则重放 applyCurrentTheme，
        // 未初始化则先按 onCreate 初始化的系统模式缓存值刷新状态栏，之后由
        // init 完成的 applyCurrentTheme 接管（此时页面必然已加载）。
        if (appStore.isInitialized) {
          appStore.settingsStore.applyCurrentTheme()
        } else {
          const isDark: boolean = (AppStorage.get<string>(KEY_EFFECTIVE_COLOR_MODE) ?? 'light') === 'dark'
          updateStatusBarStyle(isDark)
        }

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

  /**
   * 开启系统图片解码缓存（全局，只需在窗口创建后设置一次）。
   *
   * 两个接口的默认值都是 **不缓存**（SDK 原文：if not set, the application will not cache
   * any decoded image / any raw image data）。不开启时，图片离开视野或被内存压力挤掉后
   * 再次显示必须**重新解码**，解码完成前的那一两帧就是可见的闪烁——典型触发场景是打开
   * 图片查看器（要同时解码全屏大图）再退出，正文图片被挤出缓存后重新解码。
   *
   * 拿不到 UIContext 时只记录日志：这只是体验优化，不应影响窗口初始化主流程。
   *
   * @param mainWindow - 主窗口（提供承载页面 UI 的 UIContext）
   */
  private enableImageDecodeCache(mainWindow: window.Window): void {
    try {
      const uiContext: UIContext = mainWindow.getUIContext()
      uiContext.setImageCacheCount(IMAGE_CACHE_COUNT)
      uiContext.setImageRawDataCacheSize(IMAGE_RAW_CACHE_BYTES)
      logger.info('Image decode cache enabled: count=%{public}d rawBytes=%{public}d',
        IMAGE_CACHE_COUNT, IMAGE_RAW_CACHE_BYTES)
    } catch (e) {
      logger.error('Failed to enable image decode cache. Cause: %{public}s', formatError(e))
    }
  }

  /** 应用进入前台时恢复前台服务。 */
  onForeground(): void {
    appStore.setForegroundActive(true)
    if (appStore.isInitialized) {
      appStore.autoCheckinIfNeeded();
    }
    logger.info( '%{public}s', 'Ability onForeground');
  }

  /** 应用进入后台时持久化当前状态。 */
  onBackground(): void {
    appStore.setForegroundActive(false)
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
    // 窗口宽度（vp，取整）随断点一并缓存：半模态面板宽度需要按窗口收敛
    // （见 `SheetWidthConstants`）。取整 + 值变化才写，避免拖拽窗口时按帧触发全量刷新。
    const windowWidthVp: number = Math.round(widthVp)
    if (AppStorage.get<number>(KEY_WINDOW_WIDTH_VP) !== windowWidthVp) {
      AppStorage.setOrCreate(KEY_WINDOW_WIDTH_VP, windowWidthVp)
    }
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
