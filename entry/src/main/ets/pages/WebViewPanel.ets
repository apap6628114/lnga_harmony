import { webview } from '@kit.ArkWeb'
import { common } from '@kit.AbilityKit'
import { BusinessError, pasteboard } from '@kit.BasicServicesKit'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { routerStore } from '../store/RouterStore'
import { getSession } from '../service/api/AuthApi'
import { getActiveDomain } from '../service/api/MiscApi'
import { appStore } from '../store/AppStore'
import { Logger, DOMAIN_UI, formatError } from '../common/utils/Logger'
import { KEY_USE_INTERNAL_WEBVIEW } from '../common/constants/AppStorageKeys'
import { handleForumLink, isNgaDomain, openAppLinkOrFallback, openSystemLink } from '../common/utils/LinkUtils'
import { extractHostname } from '../common/utils/UrlUtils'
import { AppColors } from '../common/constants/Constants'
import { PageScope } from '../common/concurrency/PageScope'
import { UIMaterialManager } from '../common/managers/UIMaterialManager'

const logger = new Logger(DOMAIN_UI, 'WebViewPanel')
/** 标题栏高度。 */
const NAV_BAR_H: number = 44

@Component
export struct WebViewPanel {
  @Prop url: string = ''
  @StorageProp('navBarHeight') navBarHeight: number = 0
  private controller: webview.WebviewController = new webview.WebviewController()
  /** 系统状态栏高度。 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 是否显示标题栏"更多"下拉菜单。 */
  @State showMoreMenu: boolean = false
  @State pageTitle: string = ''
  @State isLoading: boolean = true
  @State progress: number = 0
  @State canGoBackward: boolean = false
  @State canGoForward: boolean = false
  /** 初始 URL 为 NGA 域名时进入 NGA 会话模式，允许 WebView 内自由浏览 NGA 页面而不被拦截回原生 */
  private ngaSession: boolean = false
  /** 已确认没有关联应用、下一次应直接由 WebView 加载的 URL */
  private internalFallbackUrl: string = ''
  /** 页面出现会话作用域，驱动异步回调的存活校验。 */
  private scope: PageScope = new PageScope()

  aboutToAppear(): void {
    this.scope.begin()
    this.injectCookies()
    this.ngaSession = isNgaDomain(extractHostname(this.url))
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
    const baseUrl: string = getActiveDomain()
    try {
      webview.WebCookieManager.configCookieSync(baseUrl, 'ngaPassportUid=' + session.uid + '; Path=/')
      webview.WebCookieManager.configCookieSync(baseUrl, 'ngaPassportCid=' + session.cid + '; Path=/')
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
   * 构建标题栏"更多"下拉菜单（与帖子页右上角菜单同款样式）。
   */
  @Builder
  moreMenu() {
    Stack() {
      Column() {}.width('100%').height('100%').onClick(() => { this.showMoreMenu = false })

      Column() {
        Column() {
          Text('浏览器打开').fontSize(15)
            .fontColor(AppColors.textPrimary)
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .width('100%')
            .onClick(() => {
              this.showMoreMenu = false
              this.openInBrowser()
            })
        }
        .width('100%')

        Divider().width('100%').color(AppColors.separator)

        Column() {
          Text('复制URL').fontSize(15)
            .fontColor(AppColors.textPrimary)
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .width('100%')
            .onClick(() => {
              this.showMoreMenu = false
              this.copyCurrentUrl()
            })
        }
        .width('100%')
      }
      .width(150)
      .backgroundColor(Color.Transparent)
      .borderRadius(10)
      .shadow({ radius: 16, color: AppColors.shadowLight, offsetY: 4 })
      .systemMaterial(UIMaterialManager.surfaceMaterial)
      .position({ top: this.statusBarHeight + NAV_BAR_H + 6, right: 16 })
    }
    .width('100%').height('100%')
    .transition(TransitionEffect.OPACITY.animation({ duration: 150 }))
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
          onRightClick: (): void => {
            this.showMoreMenu = !this.showMoreMenu
          }
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
          .onControllerAttached(() => {
            try {
              this.controller.setCustomUserAgent('Mozilla/5.0 (Linux; Android 10; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.144 Mobile Safari/537.36')
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

      Row({ space: 12 }) {
        Stack() {
          Image($r('app.media.icon_back'))
            .width(22).height(22)
            .fillColor(UIMaterialManager.adaptiveForeground)
        }
        .width(44).height(44).borderRadius(22)
        .backgroundColor(Color.Transparent)
        .shadow({ radius: 16, color: AppColors.shadow, offsetY: 4 })
        .systemMaterial(UIMaterialManager.fabMaterial)
        .opacity(this.canGoBackward ? 1 : 0.45)
        .enabled(this.canGoBackward)
        .accessibilityText('网页后退')
        .onClick(() => {
          this.navigateHistory(-1)
        })

        Stack() {
          Image($r('app.media.icon_back'))
            .width(22).height(22)
            .fillColor(UIMaterialManager.adaptiveForeground)
            .rotate({ angle: 180 })
        }
        .width(44).height(44).borderRadius(22)
        .backgroundColor(Color.Transparent)
        .shadow({ radius: 16, color: AppColors.shadow, offsetY: 4 })
        .systemMaterial(UIMaterialManager.fabMaterial)
        .opacity(this.canGoForward ? 1 : 0.45)
        .enabled(this.canGoForward)
        .accessibilityText('网页前进')
        .onClick(() => {
          this.navigateHistory(1)
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .padding({ right: 16, bottom: 16 + this.navBarHeight })

      if (this.showMoreMenu) {
        this.moreMenu()
      }
    }
    .width('100%').height('100%')
    .alignContent(Alignment.BottomEnd)
    .backgroundColor(AppColors.bg)
  }
}
