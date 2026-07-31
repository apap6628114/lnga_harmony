import { webview } from '@kit.ArkWeb'
import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { routerStore } from '../store/RouterStore'
import { getSession } from '../service/api/AuthApi'
import { getActiveDomain } from '../service/api/MiscApi'
import { appStore } from '../store/AppStore'
import { Logger, DOMAIN_UI, formatError } from '../common/utils/Logger'
import { KEY_USE_INTERNAL_WEBVIEW } from '../common/constants/AppStorageKeys'
import { handleForumLink, openAppLinkOrFallback, openSystemLink } from '../common/utils/LinkUtils'
import { AppColors } from '../common/constants/Constants'
import { PageScope } from '../common/concurrency/PageScope'

const logger = new Logger(DOMAIN_UI, 'WebViewPanel')

/** NGA 域名列表（与 LinkUtils 保持同步） */
const NGA_DOMAINS: string[] = [
  'bbs.nga.cn',
  'ngabbs.com',
  'nga.178.com',
]

@Component
export struct WebViewPanel {
  @Prop url: string = ''
  @StorageProp('navBarHeight') navBarHeight: number = 0
  private controller: webview.WebviewController = new webview.WebviewController()
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
    this.ngaSession = this.isNgaDomain(this.extractHostname(this.url))
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
   * 从 URL 中提取主机名。
   */
  private extractHostname(url: string): string {
    const match = url.match(/^https?:\/\/([^/]+)/)
    return match ? match[1] : url
  }

  /**
   * 判断主机名是否属于 NGA 域名。
   */
  private isNgaDomain(hostname: string): boolean {
    const lower: string = hostname.toLowerCase()
    for (let i = 0; i < NGA_DOMAINS.length; i++) {
      if (lower === NGA_DOMAINS[i] || lower.endsWith('.' + NGA_DOMAINS[i])) {
        return true
      }
    }
    return false
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
    if (!targetUrl.startsWith('http://') && !targetUrl.startsWith('https://')) {
      return false
    }

    if (targetUrl === this.internalFallbackUrl) {
      this.internalFallbackUrl = ''
      return false
    }

    const hostname: string = this.extractHostname(targetUrl)
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext

    // ─── NGA 会话模式：用户显式选择了浏览 NGA 网页版，放行所有 NGA 域名链接 ───
    if (this.ngaSession && this.isNgaDomain(hostname)) {
      return false
    }

    // ─── 第一优先级：NGA 链接 → 回归原生页面 ───
    if (this.isNgaDomain(hostname)) {
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

  build() {
    Stack() {
      Column() {
        // ─── 导航栏（标题 + 右侧"浏览器打开"按钮） ───
        PanelNavBar({
          title: this.pageTitle || 'NGA网页版',
          onBack: (): void => {
            routerStore.back()
          },
          rightLabel: '浏览器打开',
          rightLabelColor: '#007AFF',
          onRightClick: (): void => {
            this.openInBrowser()
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
            .fillColor(this.canGoBackward ? AppColors.primary : AppColors.textTertiary)
        }
        .width(44).height(44).borderRadius(22)
        .backgroundColor(Color.Transparent)
        .shadow({ radius: 16, color: AppColors.shadow, offsetY: 4 })
        .backgroundEffect({
          radius: 10,
          saturation: 1.15,
          brightness: 1.08,
          color: AppColors.frostGlass
        })
        .opacity(this.canGoBackward ? 1 : 0.45)
        .enabled(this.canGoBackward)
        .accessibilityText('网页后退')
        .onClick(() => {
          this.navigateHistory(-1)
        })

        Stack() {
          Image($r('app.media.icon_back'))
            .width(22).height(22)
            .fillColor(this.canGoForward ? AppColors.primary : AppColors.textTertiary)
            .rotate({ angle: 180 })
        }
        .width(44).height(44).borderRadius(22)
        .backgroundColor(Color.Transparent)
        .shadow({ radius: 16, color: AppColors.shadow, offsetY: 4 })
        .backgroundEffect({
          radius: 10,
          saturation: 1.15,
          brightness: 1.08,
          color: AppColors.frostGlass
        })
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
    }
    .width('100%').height('100%').alignContent(Alignment.BottomEnd)
  }
}
