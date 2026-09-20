import { UIContext } from '@ohos.arkui.UIContext'
import { appStore } from '../store/AppStore'
import { invalidateServerSession } from './api/AuthApi'
import { Logger, DOMAIN_SERVICE, formatError } from '../common/utils/Logger'
import { clearWebViewAuthCookies } from '../common/utils/WebViewCookieUtils'
import { replyManager } from '../common/managers/ReplyManager'

const logger = new Logger(DOMAIN_SERVICE, 'LogoutOrchestrator')

/**
 * 退出登录流程编排器。
 *
 * 集中编排"服务端登出 → 本地清理 → WebView 凭证清理 → 导航跳转"完整流程。
 * 调用方（@Component）传入 UIContext 用于导航。
 * 服务端登出失败不阻塞本地清理。
 */
export class LogoutOrchestrator {
  async logout(context: UIContext): Promise<void> {
    const token = appStore.auth.token
    // 1. 服务端登出（纯 API，不碰 Store，失败不阻塞）
    if (token) {
      try {
        await invalidateServerSession(token)
      } catch (e) {
        logger.warn('服务端登出失败: %{public}s', formatError(e))
      }
    }
    // 2. 本地清理（AppStore.clearAuth 内部编排全部 Store reset）
    appStore.clearAuth()
    // 2.1 编辑器管理器也要清：`replyManager` 是进程级单例，持有服务端签发的临时凭证
    //     （post/check 的 auth/attach_url 与附件参数）与会话标题，`clearAuth` 碰不到它。
    //     不清的话，换账号后在同一个帖子打开编辑器可能命中上一个账号的凭证与标题；
    //     `reset()` 同时自增会话代数，作废在途的 post/check（迟到的结果不会再写回状态）。
    replyManager.reset()
    // 3. WebView 凭证清理：WebView 的 Cookie 是应用级持久化存储，clearAuth 碰不到它。
    //    不清理的话，网页登录/浏览网页版留下的 ngaPassportUid+ngaPassportCid 会一直有效，
    //    再次打开「网页登录」会被 NGA 登录页判定为已登录，直接回包登录成功（详见 WebViewCookieUtils）
    clearWebViewAuthCookies()
    // 4. 导航到登录页
    try {
      context.getRouter().replaceUrl({ url: 'pages/LoginPage' })
    } catch (e) {
      logger.error('导航到登录页失败: %{public}s', formatError(e))
    }
  }
}

export const logoutOrchestrator = new LogoutOrchestrator()
