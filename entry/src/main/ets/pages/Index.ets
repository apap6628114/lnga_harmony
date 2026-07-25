/**
 * Index 页面 - 应用启动页
 * 等待 AppStore 初始化完成后，根据认证状态跳转到 LoginPage 或 MainPage
 */

import { appStore } from '../store/AppStore'
import { AppColors } from '../common/constants/Constants'
import { verifyToken } from '../service/api/AuthApi'
import { Logger, DOMAIN_UI } from '../common/utils/Logger'

const logger = new Logger(DOMAIN_UI, 'IndexPage')


@Entry
@Component
struct Index {
  @StorageProp('themeName') themeName: string = 'original'
  /** AppStore 初始化是否失败。 */
  @State initializationFailed: boolean = false

  aboutToAppear(): void {
    this.waitAndRoute()
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
      const valid = await verifyToken(appStore.auth.token)
      if (valid) {
        try { this.getUIContext().getRouter().replaceUrl({ url: 'pages/MainPage' }) } catch (e) { logger.error('route to MainPage failed: %{public}s', (e as Error).message) }
      } else {
        appStore.clearAuth()
        try { this.getUIContext().getRouter().replaceUrl({ url: 'pages/LoginPage' }) } catch (e) { logger.error('route to LoginPage failed: %{public}s', (e as Error).message) }
      }
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
