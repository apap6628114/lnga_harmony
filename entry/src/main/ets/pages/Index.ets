/**
 * Index 页面 - 应用启动页
 * 等待 AppStore 初始化完成后，根据认证状态跳转到 LoginPage 或 MainPage
 *
 * **只有"本地没有凭证"才去登录页**。本地有凭证、但服务端校验明确拒绝时，按降级处理：
 * 照常进主界面并挂上顶部横幅（`CredentialBanner`），不清登录态、不要求重新输入密码。
 * 依据：NGA 各接口的会话校验强度并不一致，服务端局部异常期间完全可能「帖子能读、
 * iflogin 报失效」；此时把用户踢回登录页，既没有解决任何问题，又抹掉了他正在看的内容。
 */

import { appStore } from '../store/AppStore'
import { AppColors } from '../common/constants/Constants'
import { SessionVerdict } from '../service/api/AuthErrors'
import { Logger, DOMAIN_UI } from '../common/utils/Logger'

const logger = new Logger(DOMAIN_UI, 'IndexPage')


@Entry
@Component
struct Index {
  /** AppStore 初始化是否失败。 */
  @State initializationFailed: boolean = false

  aboutToAppear(): void {
    this.waitAndRoute().catch((e: Error): void => {
      logger.error('startup routing failed: %{public}s', (e as Error).message)
    })
  }

  private async waitAndRoute(): Promise<void> {
    if (!appStore.isInitializationFinished) {
      setTimeout(() => this.waitAndRoute(), 50)
      return
    }
    if (!appStore.isInitialized || !appStore.auth.initialized) {
      this.initializationFailed = true
      return
    }
    if (appStore.auth.isAuthenticated) {
      // 三态校验（5s 超时）：服务端**明确**判失效时也不清态，只标记降级。
      // 无法判定（离线/服务端异常）时同样保留登录态 —— 这是"状态不会因一次网络抖动丢失"的关键。
      const verdict: SessionVerdict = await appStore.sessionGuard.verify()
      if (verdict === SessionVerdict.INVALID) {
        // 自愈成功但凭证已被服务端判失效：不再提示"已恢复"
        appStore.auth.sessionRestored = false
        // 降级而不是清态：本地凭证与全部 Store 原样保留，照常进主界面。
        // 写操作会被门禁拦下；服务端恢复后，后台探针会让横幅自行消失。
        appStore.markCredentialDegraded('启动校验未通过')
        if (!appStore.auth.isAuthenticated) {
          // 异常分支：凭证与账号错配时 `markCredentialDegraded` 会直接清态，
          // 此时不能进主界面 —— 继续用会以别人的身份读数据。
          try { this.getUIContext().getRouter().replaceUrl({ url: 'pages/LoginPage' }) } catch (e) { logger.error('route to LoginPage failed: %{public}s', (e as Error).message) }
          return
        }
        try { this.getUIContext().getRouter().replaceUrl({ url: 'pages/MainPage' }) } catch (e) { logger.error('route to MainPage failed: %{public}s', (e as Error).message) }
        return
      }
      // 本地会话被自愈（token 悬空但 uid/cid 仍在）时明确告知一次：用户不需要重新输入，
      // 但"状态曾丢失并被修复"这件事必须可见。只在确认未失效后提示，避免"已恢复 + 已失效"连弹。
      if (appStore.auth.sessionRestored) {
        appStore.auth.sessionRestored = false
        appStore.showToast('登录状态已恢复')
      }
      if (verdict === SessionVerdict.UNKNOWN) {
        logger.warn('启动会话校验无法判定，保留登录态')
      }
      try { this.getUIContext().getRouter().replaceUrl({ url: 'pages/MainPage' }) } catch (e) { logger.error('route to MainPage failed: %{public}s', (e as Error).message) }
    } else {
      try { this.getUIContext().getRouter().replaceUrl({ url: 'pages/LoginPage' }) } catch (e) { logger.error('route to LoginPage failed: %{public}s', (e as Error).message) }
    }
  }

  build() {
    Column() {
      if (this.initializationFailed) {
        Text('应用初始化失败，请重新启动')
          .fontSize(15)
          .fontColor(AppColors.textSecondary)
      } else {
        LoadingProgress()
          .width(40)
          .height(40)
          .color(AppColors.primary)
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(AppColors.bg)
  }
}
