import { webview } from '@kit.ArkWeb'
import { Logger, DOMAIN_UI, formatError } from './Logger'

const logger = new Logger(DOMAIN_UI, 'WebViewCookieUtils')

/**
 * 清除隐私模式（网页登录层使用）WebView 的内存 Cookie。
 *
 * 网页登录层是一条**一次性**的登录通道：用户要么输账号密码、要么扫码，登录成功后
 * 凭证由 `handleWebLoginResult` 交给 App 自己的 token 体系（`appStore.setAuth`），
 * 页面里的 Cookie 不应被后续任何一次登录复用。因此：
 *
 * - 打开登录层**之前**清一次：即使隐私分区（内存 Cookie）里还留着上一次会话的
 *   `ngaPassportUid` / `ngaPassportCid`，NGA 登录页也不会把当前会话判成"已登录"，
 *   从而不会跳过账号密码/扫码直接回包登录成功；
 * - 关闭登录层 / 登录流程结束时清一次：不让一份**服务端仍然认账**的凭证留在内存里
 *   等着被下一次打开读到。
 *
 * 隐私模式的数据不落盘、与普通模式（`WebViewPanel` 浏览网页版）的 Cookie 存储互相隔离，
 * 所以这里清的范围只影响登录层自身，不会波及 App 内其它网页会话。
 */
export function clearIncognitoWebCookies(): void {
  try {
    // 参数必须显式传 true：官方文档写明 incognito 省略/传 undefined 时**不清除**任何 Cookie
    webview.WebCookieManager.clearAllCookiesSync(true)
  } catch (e) {
    logger.warn('清除网页登录层隐私 Cookie 失败: %{public}s', formatError(e))
  }
}

/**
 * 清除 WebView 中可能残留的登录凭证 Cookie（退出登录时调用）。
 *
 * ## 为什么退出登录必须清 WebView Cookie
 *
 * ArkWeb 的 Cookie 存储是**应用级共享且持久化落盘**的，与 App 自己的 token 存储完全独立：
 *
 * 1. 「网页登录」在 LoginPage 的 WebView 里登录成功后，NGA 服务端下发的
 *    `ngaPassportUid` / `ngaPassportCid` 会写进 WebView 的 Cookie 存储；
 * 2. `WebViewPanel` 浏览网页版时，还会用 `configCookieSync` 主动把当前会话的
 *    同一对 Cookie 注入进去（`injectCookies`）；
 * 3. 而 `appStore.clearAuth()` 只清 App 内部会话，**碰不到** WebView 的 Cookie 存储。
 *
 * 于是退出登录后（即使重启 App），WebView 里依然带着一份服务端认账的凭证：
 * 再次打开「网页登录」时 NGA 登录页认为当前已是登录态，两条回包通道（LoginPage 的 Cookie
 * 轮询与 `loginSuccess` console 消息）会在页面加载后立刻取回凭证——用户没有任何输入机会，
 * 表现为"没输密码、没扫码就登录成功"。
 *
 * ## 清理范围与代价
 *
 * - 非隐私模式的**持久化** Cookie：`clearAllCookiesSync(false)`。传 `false` 是硬要求——
 *   该参数省略/传 undefined 时官方实现**不清除**任何 Cookie；`false` 才是文档描述的
 *   "清除正常非隐私模式下的持久化 cookies"；
 * - 非隐私模式的会话 Cookie：`clearSessionCookieSync()`；
 * - 隐私模式的内存 Cookie：`clearIncognitoWebCookies()`。
 *
 * ⚠️ 副作用：ArkWeb **没有**按域名或按 Cookie 名删除的接口，非隐私模式的 Cookie 又是
 * 所有站点共用的，所以本函数会一并清掉用户在内置 WebView 里登录过的其它站点。
 * 这与"退出登录 = 不再保留任何网页登录态"的语义一致，也是彻底消除残留凭证的唯一可靠手段。
 */
export function clearWebViewAuthCookies(): void {
  clearIncognitoWebCookies()
  try {
    webview.WebCookieManager.clearAllCookiesSync(false)
    webview.WebCookieManager.clearSessionCookieSync()
  } catch (e) {
    logger.warn('清除 WebView 凭证 Cookie 失败: %{public}s', formatError(e))
  }
}
