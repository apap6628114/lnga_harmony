import { webview } from '@kit.ArkWeb'
import { common } from '@kit.AbilityKit'
import { BusinessError, pasteboard } from '@kit.BasicServicesKit'
import { PanelNavBar, NavBarMenuItem } from '../common/components/PanelNavBar'
import { HdsMaterialHost } from '../common/components/HdsMaterialHost'
import { routerStore } from '../store/RouterStore'
import { getSession } from '../service/api/AuthApi'
import { getActiveDomain } from '../service/api/MiscApi'
import { appStore } from '../store/AppStore'
import { Logger, DOMAIN_UI, formatError } from '../common/utils/Logger'
import { KEY_USE_INTERNAL_WEBVIEW } from '../common/constants/AppStorageKeys'
import { handleForumLink, isNgaDomain, openAppLinkOrFallback, openSystemLink } from '../common/utils/LinkUtils'
import { extractHostname } from '../common/utils/UrlUtils'
import { isNgaQrLoginUrl } from '../common/utils/NgaQrLoginUtils'
import { AppColors } from '../common/constants/Constants'
import { PageScope } from '../common/concurrency/PageScope'
import { UIMaterialManager } from '../common/managers/UIMaterialManager'
import { resolveWebKeyboardAppearance } from '../common/utils/KeyboardAppearanceUtils'

const logger = new Logger(DOMAIN_UI, 'WebViewPanel')
/** NGA 官方鸿蒙客户端 WebView 标识，供 H5 选择 app Cookie 分支。 */
const NGA_HARMONY_USER_AGENT_SUFFIX: string = ' NGA_Harmony/1.0.0'
/** 普通网页使用的 WebView User-Agent。 */
const DEFAULT_WEBVIEW_USER_AGENT: string =
  'Mozilla/5.0 (Linux; Android 10; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.144 Mobile Safari/537.36'
/** 右下角浮动按钮（前进 / 后退）的材质块尺寸（vp），与迁移前的自绘玻璃按钮逐像素一致。 */
const FAB_SIZE: number = 44

@Component
export struct WebViewPanel {
  @Prop url: string = ''
  @StorageProp('navBarHeight') navBarHeight: number = 0
  /**
   * 当前生效明暗色模式。
   *
   * 供 WebView 内 H5 输入框的键盘沉浸样式取色——H5 输入框不受 ArkUI `TextInput` 的
   * `KeyboardAppearance` 约束，走 Web 侧独立枚举（见 `KeyboardAppearanceUtils` 文件头）。
   */
  @StorageProp('effectiveColorMode') effectiveColorMode: string = 'light'
  private controller: webview.WebviewController = new webview.WebviewController()
  @State pageTitle: string = ''
  @State isLoading: boolean = true
  @State progress: number = 0
  @State canGoBackward: boolean = false
  @State canGoForward: boolean = false
  /** 初始 URL 为 NGA 域名时进入 NGA 会话模式，允许 WebView 内自由浏览 NGA 页面而不被拦截回原生 */
  private ngaSession: boolean = false
  /** 当前 WebView 是否专门用于 NGA 扫码授权。 */
  private isQrLoginWebView: boolean = false
  /** 已确认没有关联应用、下一次应直接由 WebView 加载的 URL */
  private internalFallbackUrl: string = ''
  /** 页面出现会话作用域，驱动异步回调的存活校验。 */
  private scope: PageScope = new PageScope()

  aboutToAppear(): void {
    this.scope.begin()
    this.ngaSession = isNgaDomain(extractHostname(this.url))
    this.isQrLoginWebView = isNgaQrLoginUrl(this.url)
    this.injectCookies()
    this.internalFallbackUrl = this.url
  }

  /** 结束页面出现会话，使未完成的异步回调失效。 */
  aboutToDisappear(): void {
    this.scope.end()
  }

  private injectCookies(): void {
    if (!appStore.auth.isAuthenticated) {
      return
    }
    const session = getSession(appStore.auth.token)
    if (!session) {
      return
    }
    try {
      if (this.isQrLoginWebView) {
        const hostname: string = extractHostname(this.url)
        const baseUrl: string = 'https://' + hostname
        webview.WebCookieManager.configCookieSync(baseUrl, 'access_uid=' + session.uid + '; Path=/')
        webview.WebCookieManager.configCookieSync(baseUrl, 'access_token=' + session.cid + '; Path=/')
      } else {
        const baseUrl: string = getActiveDomain()
        webview.WebCookieManager.configCookieSync(baseUrl, 'ngaPassportUid=' + session.uid + '; Path=/')
        webview.WebCookieManager.configCookieSync(baseUrl, 'ngaPassportCid=' + session.cid + '; Path=/')
      }
    } catch (e) {
      logger.error('[WebViewPanel] setCookie failed: %{public}s', formatError(e))
    }
  }

  /**
   * 将已确认没有关联应用的 URL 交给当前 WebView 加载。
   *
   * @param targetUrl - 待加载的 HTTP(S) 链接
   */
  private loadInternalFallback(targetUrl: string): void {
    this.internalFallbackUrl = targetUrl
    try {
      this.controller.loadUrl(targetUrl)
    } catch (e) {
      this.internalFallbackUrl = ''
      logger.error('[WebViewPanel] internal fallback failed: %{public}s', formatError(e))
    }
  }

  /**
   * 刷新当前网页历史栈的前进和后退可用状态。
   */
  private updateHistoryState(): void {
    try {
      this.canGoBackward = this.controller.accessBackward()
      this.canGoForward = this.controller.accessForward()
    } catch (e) {
      this.canGoBackward = false
      this.canGoForward = false
      logger.error('[WebViewPanel] update history state failed: %{public}s', formatError(e))
    }
  }

  /**
   * 在 WebView 历史栈中前进或后退一步。
   *
   * @param step - -1 表示后退，1 表示前进
   */
  private navigateHistory(step: number): void {
    const available: boolean = step < 0 ? this.canGoBackward : this.canGoForward
    if (!available) {
      return
    }
    try {
      const entries: webview.BackForwardList = this.controller.getBackForwardEntries()
      const targetIndex: number = entries.currentIndex + step
      if (targetIndex >= 0 && targetIndex < entries.size) {
        const targetEntry: webview.HistoryItem = entries.getItemAtIndex(targetIndex)
        this.internalFallbackUrl =
          targetEntry.historyUrl.length > 0 ? targetEntry.historyUrl : targetEntry.historyRawUrl
      }
      if (step < 0) {
        this.controller.backward()
      } else {
        this.controller.forward()
      }
    } catch (e) {
      this.internalFallbackUrl = ''
      logger.error('[WebViewPanel] navigate history failed: %{public}s', formatError(e))
      this.updateHistoryState()
    }
  }

  /**
   * URL 路由分发。
   * 返回值 true=已拦截（WebView 不应加载），false=继续加载。
   */
  private handleUrlIntercept(targetUrl: string): boolean {
    // ─── 非 HTTP(S) 协议 ───
    // WebView 原生可处理的内部协议（about:、data:）继续放行
    if (!targetUrl.startsWith('http://') && !targetUrl.startsWith('https://')) {
      if (targetUrl.startsWith('about:') || targetUrl.startsWith('data:')) {
        return false
      }
      // intent:// 是 Android 专属的 App 唤起格式（如新浪财经加载后自动触发的
      // scheme=sinafinance;package=cn.com.sina.finance），鸿蒙系统无法解析，直接拦截，
      // 避免页面异常跳转并破坏历史栈（内置网页的前进/后退失效）。
      if (targetUrl.startsWith('intent:')) {
        return true
      }
      // 其它自定义 scheme（weixin:// 等）：拦截后用系统隐式匹配拉起已安装的鸿蒙原生
      // 应用，找不到匹配应用时静默留在原页面，不交给 WebView 加载（避免白屏）。
      const schemeContext: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext
      try {
        schemeContext.openLink(targetUrl, { hideFailureTipDialog: true }).catch((): void => {})
      } catch (e) {
        logger.error('[WebViewPanel] open scheme link failed: %{public}s', formatError(e))
      }
      return true
    }

    if (targetUrl === this.internalFallbackUrl) {
      this.internalFallbackUrl = ''
      return false
    }

    const hostname: string = extractHostname(targetUrl)
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext

    // ─── NGA 会话模式：用户显式选择了浏览 NGA 网页版，放行所有 NGA 域名链接 ───
    if (this.ngaSession && isNgaDomain(hostname)) {
      return false
    }

    // ─── 第一优先级：NGA 链接 → 回归原生页面 ───
    if (isNgaDomain(hostname)) {
      // 委托 handleForumLink 做原生路由（帖子详情 / 用户主页 / WebView 兜底）
      handleForumLink(targetUrl, context)
      return true
    }

    const useInternalWebView: boolean = AppStorage.get<boolean>(KEY_USE_INTERNAL_WEBVIEW) ?? true
    if (!useInternalWebView) {
      openSystemLink(targetUrl, context)
      return true
    }

    openAppLinkOrFallback(targetUrl, context, (): void => {
      this.loadInternalFallback(targetUrl)
    })
    return true
  }

  /** 在系统浏览器中打开当前页面 */
  private openInBrowser(): void {
    try {
      const currentUrl: string = this.controller.getUrl()
      if (!currentUrl) {
        return
      }
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext
      context.openLink(currentUrl, { hideFailureTipDialog: true }).catch((e: BusinessError): void => {
        logger.error('[WebViewPanel] openInBrowser failed: %{public}s', formatError(e))
      })
    } catch (e) {
      logger.error('[WebViewPanel] openInBrowser failed: %{public}s', formatError(e))
    }
  }

  /**
   * 将当前页面 URL 复制到系统剪贴板。
   */
  private async copyCurrentUrl(): Promise<void> {
    try {
      const currentUrl: string = this.controller.getUrl()
      if (!currentUrl) {
        return
      }
      const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard()
      const pasteData: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, currentUrl)
      await systemPasteboard.setData(pasteData)
      appStore.showToast('链接已复制')
    } catch (e) {
      logger.error('[WebViewPanel] copy url failed: %{public}s', formatError(e))
    }
  }

  /**
   * 更多菜单项（菜单本体在 `PanelNavBar` **内部**渲染，锚点是那颗 more 按钮）。
   *
   * 材质由 `MenuOptions.systemMaterial` 的系统沉浸材质承担（**菜单控制**属 Release 允许
   * 「页面内全部区域」生效的弹窗类接口）。回调写成**箭头函数**以捕获本组件的 `this`
   * （见 `NavBarMenuItem` 说明）。
   *
   * @returns 菜单项
   */
  private moreMenuItems(): NavBarMenuItem[] {
    const items: NavBarMenuItem[] = []
    items.push({
      label: '浏览器打开',
      action: (): void => {
        this.openInBrowser()
      }
    })
    items.push({
      label: '复制URL',
      action: (): void => {
        this.copyCurrentUrl()
      }
    })
    return items
  }

  /**
   * 右下角前进 / 后退浮动按钮：**HDS 材质宿主**背板 + 一颗承载动作的内容节点。
   *
   * ## 为什么换成 HDS 材质
   *
   * 背板原为 `UIMaterialManager.fabMaterial`（自绘磨砂玻璃）。API 26 Release 收紧了
   * `systemMaterial` 的生效范围：**内容区的普通组件拿不到系统沉浸材质**，而本工程没有
   * `Navigation` / `Tabs` 可借位（详见 `HdsMaterialHost` 文件头与
   * `docs/IMMERSIVE_LIGHT_DESIGN.md` §12.9）。HDS 材质由 `HdsTabs` 悬浮页签栏自身渲染、
   * 不受那条门禁约束，是这里唯一能拿到**真材质**（折射、高光、系统阴影、深浅色自适应色调）
   * 的通道——与 `TopicListPanel` 发帖 / 刷新、`ThreadPanel` 回复按钮同构。
   * 材质块尺寸沿用新旧一致的 `FAB_SIZE`（44×44），宿主默认与材质块逐像素重合，
   * 外层 `Row` 的 `space` 与 `padding` 落点不变。
   *
   * ## 三条约定（与既有接入点一致）
   *
   * 1. **内容容器写 `'100%'`，不写 `FAB_SIZE` 的显式尺寸**：HDS 页签项的内容区比 `barHeight`
   *    矮，容器高于内容区时超出部分按顶部溢出对齐（真机现象：图标整体偏下）；写成 `'100%'`
   *    后容器高度 = 内容区高度，图标由 `alignContent(Center)` 居中即与材质块同心。
   * 2. **不传宿主 `onTap`**，动作与无障碍名称都挂在内容节点上——与迁移前的
   *    `.onClick` / `.accessibilityText` 逐条等价（可聚焦性与无障碍语义都留在原节点），
   *    也避免"宿主 `onTabBarClick` + 子元素 `onClick`"双触发。
   * 3. **`draggable(false)` 必须显式写**：`Image` 自 API 10 起 `draggable` 默认为 `true`，
   *    长按会被系统当成"拖拽图片"（§12.9）。
   *
   * ## 状态一律经 `this` 读取
   *
   * 参数只传**静态字面量**（方向 `step` 与无障碍名称）；`canGoBackward` / `canGoForward`
   * 会随 WebView 历史栈刷新，必须在 `@Builder` 内用 `this` 读取——`@Builder` 按值传参
   * **不建立响应式依赖**，传参会静默固化为首帧值（按钮永远不变淡、永远可点，且不报错）。
   *
   * 禁用态的变淡写在**外层固定尺寸容器**上（材质块与图标一起变淡，与迁移前的自绘玻璃一致）：
   * 自定义组件的**尾随闭包之后不能跟属性链**，`.opacity(...)` / `.enabled(...)` 无法直接挂在
   * `HdsMaterialHost` 上（会报 `Declaration or statement expected`，同类记录见 §12.9）。
   *
   * @param step - -1 表示后退，1 表示前进（静态字面量）
   * @param accessibilityText - 无障碍名称
   */
  @Builder
  historyButton(step: number, accessibilityText: string) {
    Stack() {
      HdsMaterialHost({ barWidth: FAB_SIZE, barHeight: FAB_SIZE }) {
        Stack() {
          Image($r('app.media.icon_back'))
            .width(22).height(22)
            .fillColor(UIMaterialManager.adaptiveForeground)
            .rotate({ angle: step < 0 ? 0 : 180 })
            // Image 的 draggable 自 API 10 起默认为 true：长按会被系统当成"拖拽图片"（见 §12.9）
            .draggable(false)
        }
        .width('100%').height('100%').alignContent(Alignment.Center)
        .accessibilityText(accessibilityText)
        .onClick((): void => {
          this.navigateHistory(step)
        })
      }
    }
    .width(FAB_SIZE).height(FAB_SIZE)
    .opacity((step < 0 ? this.canGoBackward : this.canGoForward) ? 1 : 0.45)
    .enabled(step < 0 ? this.canGoBackward : this.canGoForward)
  }

  build() {
    Stack() {
      Column() {
        // ─── 导航栏（标题 + 右侧"更多"操作按钮） ───
        PanelNavBar({
          title: this.pageTitle || 'NGA网页版',
          onBack: (): void => {
            routerStore.back()
          },
          rightIcon: $r('app.media.icon_more'),
          // 菜单在 PanelNavBar **内部**渲染、锚定这颗 more 按钮；两参 bindMenu 下开合由系统持有，
          // 本组件不再持有显隐状态，按钮的 onClick 也因此不需要
          hasMenu: true,
          menuItemsProvider: (): NavBarMenuItem[] => this.moreMenuItems()
        })

        // ─── 加载进度条 ───
        if (this.isLoading) {
          Progress({ value: this.progress, total: 100 })
            .width('100%')
            .height(2)
            .color('#007AFF')
        }

        // ─── WebView ───
        Web({ src: this.url, controller: this.controller })
          .layoutWeight(1).width('100%')
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .geolocationAccess(true)
          .zoomAccess(true)
          .overviewModeAccess(true)
          /**
           * 网页内 H5 输入框的键盘沉浸样式。
           *
           * 本面板承载 App 内浏览网页版，页面里的搜索框 / 回复框等都是 H5 输入框，
           * 不受 ArkUI `TextInput` 那套 `KeyboardAppearance` 约束，须走 Web 侧独立枚举
           * `WebKeyboardAppearanceMode`（API 26 新增）。与原生输入框同源取色（应用主题），
           * 避免网页层与原生层键盘样式不一致。
           */
          .keyboardAppearance(resolveWebKeyboardAppearance(this.effectiveColorMode))
          .onControllerAttached(() => {
            try {
              const userAgent: string = this.isQrLoginWebView
                ? DEFAULT_WEBVIEW_USER_AGENT + NGA_HARMONY_USER_AGENT_SUFFIX
                : DEFAULT_WEBVIEW_USER_AGENT
              this.controller.setCustomUserAgent(userAgent)
            } catch (e) {
              logger.error('setCustomUserAgent failed: %{public}s', formatError(e))
            }
            try {
              this.controller.enableAdsBlock(true)
            } catch (e) {
              logger.error('[WebViewPanel] enable ads block failed: %{public}s', formatError(e))
            }
          })
          .onTitleReceive((event: Object): void => {
            const evt = event as Record<string, Object>
            this.pageTitle = String(evt['title'] ?? '')
          })
          // 页面加载进度
          .onProgressChange((event): void => {
            if (event) {
              this.progress = event.newProgress
              if (event.newProgress >= 100) {
                setTimeout(() => {
                  if (!this.scope.isAlive()) {
                    return
                  }
                  this.isLoading = false
                }, 300)
              }
            }
          })
          .onPageBegin((): void => {
            this.isLoading = true
            this.progress = 0
          })
          .onPageEnd((): void => {
            this.updateHistoryState()
          })
          .onRefreshAccessedHistory((): void => {
            this.updateHistoryState()
          })
          .onNavigationEntryCommitted((): void => {
            this.internalFallbackUrl = ''
            this.updateHistoryState()
          })
          // 拦截页面内所有链接跳转，走三段式路由
          .onLoadIntercept((event): boolean => {
            const targetUrl: string = event.data.getRequestUrl()
            return this.handleUrlIntercept(targetUrl)
          })
          // 加载失败处理
          .onErrorReceive((event): void => {
            if (event?.request) {
              logger.error('[WebViewPanel] load error: %{public}s', event.request.getRequestUrl())
            }
          })
      }
      .width('100%').height('100%')

      // ─── 右下角浮动操作：前进 / 后退（背板为 HDS 材质宿主，见 historyButton） ───
      Row({ space: 12 }) {
        this.historyButton(-1, '网页后退')
        this.historyButton(1, '网页前进')
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .padding({ right: 16, bottom: 16 + this.navBarHeight })
    }
    .width('100%').height('100%')
    .alignContent(Alignment.BottomEnd)
    .backgroundColor(AppColors.bg)
  }
}
