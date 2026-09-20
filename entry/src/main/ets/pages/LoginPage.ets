/**
 * 登录页面
 * 支持两步登录：密码 → 验证码，以及凭据文件导入
 */

import { loginStep1, loginStep2, injectCredentials } from '../service/api/AuthApi'
import { getActiveDomain } from '../service/api/MiscApi'
import { appStore } from '../store/AppStore'
import { AppColors } from '../common/constants/Constants'
import { CustomContentDialog } from '@kit.ArkUI'
import { CredentialPasswordContent } from '../common/dialogs/Dialogs'
import { deserializeCredentialExport, isEncryptedCredentialExport } from '../common/security/CredentialExportCrypto'
import { picker, fileIo } from '@kit.CoreFileKit'
import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { util } from '@kit.ArkTS'
import { webview } from '@kit.ArkWeb'
import { PageScope } from '../common/concurrency/PageScope'
import { UIMaterialManager } from '../common/managers/UIMaterialManager'
import { Logger, DOMAIN_UI, formatError } from '../common/utils/Logger'
import { clearIncognitoWebCookies } from '../common/utils/WebViewCookieUtils'
import {
  resolveKeyboardAppearance,
  resolveWebKeyboardAppearance
} from '../common/utils/KeyboardAppearanceUtils'

const logger = new Logger(DOMAIN_UI, 'LoginPage')


/**
 * 提供账号密码、凭据文件和网页三种登录方式的响应式页面。
 */
@Entry
@Component
struct LoginPage {
  /** 用户名。 */
  @State username: string = ''
  /** 密码。 */
  @State password: string = ''
  /** 图形验证码。 */
  @State captcha: string = ''
  /** 账号密码登录是否正在进行。 */
  @State loading: boolean = false
  /** 凭据文件是否正在导入。 */
  @State importing: boolean = false
  /** 当前需要展示的错误信息。 */
  @State error: string = ''
  /** 两步登录令牌。 */
  @State loginToken: string = ''
  /** 图形验证码标识。 */
  @State captchaId: string = ''
  /** 图形验证码图片。 */
  @State captchaImage: string = ''
  /** 系统状态栏安全区高度。 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 系统导航栏安全区高度。 */
  @StorageProp('navBarHeight') navBarHeight: number = 0
  /** 当前响应式断点。 */
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'
  /**
   * 当前生效明暗色模式。
   *
   * 登录输入框（用户名 / 密码 / 验证码）与网页登录层 WebView 的键盘沉浸样式都须跟随
   * **应用主题**而非系统模式，否则应用固定主题与系统模式相反时键盘配色错配
   * （见 `KeyboardAppearanceUtils` 文件头）。
   */
  @StorageProp('effectiveColorMode') effectiveColorMode: string = 'light'

  /** 网页登录 WebView 控制器。 */
  private webController: webview.WebviewController = new webview.WebviewController()
  /** 是否展示网页登录层。 */
  @State showWebLogin: boolean = false
  /** 是否正在处理网页登录结果。 */
  @State webLoginLoading: boolean = false
  /** 网页登录使用的 NGA 域名。 */
  private loginDomain: string = ''
  /** 网页登录 Cookie 轮询定时器。 */
  private cookiePollTimer: number = -1
  /** Cookie 轮询是否处于活动状态。 */
  private pollingActive: boolean = false
  /** 网页认证结果是否已经触发处理。 */
  private authTriggered: boolean = false
  /** 待解密的凭据文件内容。 */
  private pendingCredentialContent: string = ''
  /** 凭据文件密码弹窗控制器。 */
  private importCredentialDialogController?: CustomDialogController

  /** 凭证导入弹窗的密码输入（供 CustomContentDialog 内容构件双向绑定）。 */
  @State importPassword: string = ''

  /** 凭证导入弹窗的自定义内容（按钮随密码位数切换激活态，故自绘在内容区）。 */
  @Builder
  importPasswordContent() {
    CredentialPasswordContent({
      password: this.importPassword,
      minLength: 8,
      confirmLabel: '导入',
      onPasswordChange: (value: string): void => { this.importPassword = value },
      onConfirm: (password: string): void => {
        this.importCredentialDialogController?.close()
        this.importEncryptedCredential(password)
      },
      onCancel: (): void => { this.importCredentialDialogController?.close() }
    })
  }
  /** 页面出现会话作用域，驱动异步回调的存活与代际校验。 */
  private scope: PageScope = new PageScope()

  /** 开始当前页面的异步会话。 */
  aboutToAppear(): void {
    this.scope.begin()
  }

  /**
   * 构建支持旋转、窄屏和大屏的登录界面。
   */
  build() {
    Stack() {
      Scroll() {
        Column() {
          Text('L N G A')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .letterSpacing(12)
            .margin({
              top: this.currentBreakpoint === 'sm' ? 96 : 48,
              bottom: this.currentBreakpoint === 'sm' ? 48 : 32
            })

          Column() {
            TextInput({ placeholder: '用户名', text: this.username })
              .width('100%')
              .height(48)
              .fontSize(17)
              .fontColor(UIMaterialManager.inputForeground)
              .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
              .caretColor(UIMaterialManager.inputForeground)
              .attributeModifier(UIMaterialManager.inputMaterial)
              .borderRadius(10)
              .padding({ left: 16, right: 16 })
              .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
              .onChange((value: string) => {
                this.username = value
              })

            TextInput({ placeholder: '密码', text: this.password })
              .type(InputType.Password)
              .width('100%')
              .height(48)
              .fontSize(17)
              .fontColor(UIMaterialManager.inputForeground)
              .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
              .caretColor(UIMaterialManager.inputForeground)
              .attributeModifier(UIMaterialManager.inputMaterial)
              .borderRadius(10)
              .padding({ left: 16, right: 16 })
              .margin({ top: 12 })
              .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
              .onChange((value: string) => {
                this.password = value
              })

            if (this.loginToken) {
              Text('输入图形验证码(6字符)')
                .width('100%')
                .fontSize(13)
                .fontColor(AppColors.textTertiary)
                .margin({ top: 16 })

              Row() {
                TextInput({ placeholder: '验证码', text: this.captcha })
                  .layoutWeight(1)
                  .height(46)
                  .fontSize(17)
                  .fontColor(UIMaterialManager.inputForeground)
                  .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
                  .caretColor(UIMaterialManager.inputForeground)
                  .attributeModifier(UIMaterialManager.inputMaterial)
                  .borderRadius(10)
                  .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
                  .padding({ left: 16, right: 16 })
                  .maxLength(6)
                  .onChange((value: string) => {
                    this.captcha = value
                  })

                if (this.captchaImage) {
                  Image(this.captchaImage)
                    .width(120)
                    .height(46)
                    .borderRadius(10)
                    .backgroundColor(AppColors.bgSecondary)
                    .objectFit(ImageFit.Contain)
                    .margin({ left: 8 })
                    .onClick(() => {
                      this.refreshCaptcha()
                    })
                }
              }
              .width('100%')
              .margin({ top: 12 })
            }

            if (this.error) {
              Text(this.error)
                .width('100%')
                .fontSize(13)
                .fontColor(AppColors.destructive)
                .margin({ top: 12 })
                .textAlign(TextAlign.Center)
            }

            Button(this.loading ? '...' : (this.loginToken ? '继 续' : '登 录'))
              .width('100%')
              .height(50)
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.white)
              .backgroundColor(AppColors.primary)
              .borderRadius(12)
              .margin({ top: 20 })
              .enabled(!this.loading && !this.importing)
              .onClick(() => {
                this.handleLogin()
              })

            Row() {
              Divider().layoutWeight(1).color(AppColors.separator)
              Text('或').fontSize(11).fontColor(AppColors.textTertiary).padding({ left: 8, right: 8 })
              Divider().layoutWeight(1).color(AppColors.separator)
            }
            .width('100%')
            .margin({ top: 24, bottom: 24 })

            Button(this.importing ? '...' : '导入凭据文件')
              .width('100%')
              .height(50)
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.primary)
              .backgroundColor(Color.Transparent)
              .borderRadius(12)
              .borderWidth(1.5)
              .borderColor(AppColors.primary)
              .enabled(!this.loading && !this.importing)
              .onClick(() => {
                this.handleImport()
              })

            Button('通过网页登录')
              .width('100%')
              .height(50)
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.primary)
              .backgroundColor(Color.Transparent)
              .borderRadius(12)
              .borderWidth(1.5)
              .borderColor(AppColors.primary)
              .enabled(!this.loading && !this.importing && !this.webLoginLoading)
              .onClick(() => {
                this.openWebLogin()
              })
              .margin({ top: 12 })
          }
          .width('100%')
          .constraintSize({ maxWidth: 480 })
          .padding({ left: 24, right: 24 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ bottom: 32 + this.navBarHeight })
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.statusBarHeight })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .backgroundColor(AppColors.bg)

      if (this.showWebLogin) {
        Stack() {
          Column() {
            Row() {
              Text('NGA网页登录').fontSize(17).fontWeight(FontWeight.Bold)
              Blank()
              Button('取消').fontSize(15).fontColor(AppColors.primary)
                .backgroundColor(Color.Transparent)
                .onClick(() => { this.closeWebLogin() })
            }
            .width('100%')
            .height(48 + this.statusBarHeight)
            .padding({ left: 16, right: 16, top: this.statusBarHeight })

            /**
             * 网页登录层必须跑在**隐私模式**（`incognitoMode: true`）下。
             *
             * 非隐私模式的 WebView Cookie 是**应用级持久化存储**，与 App 的 token 存储互不相干：
             * 上一次网页登录留下的 `ngaPassportUid` / `ngaPassportCid`，或 `WebViewPanel` 浏览
             * 网页版时由 `injectCookies` 注入的同一对 Cookie，都会一直留在磁盘上——退出登录
             * （`appStore.clearAuth()`）并不会碰它们。
             *
             * 于是再次打开本层时，NGA 登录页在**没有任何用户输入**的情况下就已经是登录态，
             * 两条回包通道（`onPageEnd` 起的 Cookie 轮询 / `onConsole` 的 `loginSuccess`）
             * 会在页面加载后立刻取回凭证，表现为"没输密码、没扫码就登录成功"。
             *
             * 隐私模式既不读取也不写入磁盘上的普通 Cookie，每次打开都是全新会话；
             * 进入前再配合 `clearIncognitoWebCookies()` 清一次内存 Cookie，双保险。
             * ⚠️ 本属性是这条链路的**第一道防线**，不要移除。
             */
            Web({
              src: this.loginDomain + '/nuke.php?__lib=login&__act=account&login',
              controller: this.webController,
              incognitoMode: true
            })
              .width('100%')
              .layoutWeight(1)
              .javaScriptAccess(true)
              .domStorageAccess(true)
              .metaViewport(true)
              .overviewModeAccess(true)
              /**
               * H5 输入框的键盘沉浸样式。
               *
               * Web 组件承载的网页登录层里有账号 / 密码 / 扫码确认等输入框，它们**不受** ArkUI
               * `TextInput` 那套 `KeyboardAppearance` 约束，须走 Web 侧独立枚举
               * `WebKeyboardAppearanceMode`（API 26 新增）。同样按**应用主题**取色，
               * 保证与小艺等输入法的沉浸样式和应用界面一致。
               */
              .keyboardAppearance(resolveWebKeyboardAppearance(this.effectiveColorMode))
              .onControllerAttached(() => {
                // 时机：Web 组件已创建（隐私分区已就绪）、页面尚未加载——此时清空内存 Cookie
                // 可保证登录页首帧请求就不带任何历史凭证，不依赖隐私分区是否随组件销毁而清空
                clearIncognitoWebCookies()
                this.webController.setCustomUserAgent(
                  'Mozilla/5.0 (Linux; Android 10; HarmonyOS) AppleWebKit/537.36 Mobile Safari/537.36'
                )
              })
              .onPageEnd(() => { this.startCookiePolling() })
              /**
               * 登录回包通道之二（另一条是 Cookie 轮询）：NGA 登录页的内联桥接脚本在用户
               * 输完账号密码 / 完成扫码后输出 `loginSuccess:{uid, token}`，宿主从 console 取回凭证。
               *
               * 与轮询一样，它反映的是"WebView 里当前是不是登录态"——所以 WebView 里一旦残留
               * 有效凭证，本层就会跳过账号密码/扫码直接完成登录（见上面 Web 的 `incognitoMode` 说明）。
               */
              .onConsole((event) => {
                const msg: string = event.message.getMessage()
                if (msg.indexOf('loginSuccess') >= 0 && !this.authTriggered) {
                  const colonIdx: number = msg.indexOf(':')
                  if (colonIdx >= 0) {
                    try {
                      const jsonStr: string = msg.substring(colonIdx + 1).trim()
                      const data: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>
                      if (data['uid'] && data['token']) {
                        this.authTriggered = true
                        this.handleWebLoginResult(String(data['uid']), String(data['token']))
                      }
                    } catch (_error) {
                      // 回包 JSON 片段含 uid/token，不输出 formatError 详情以防凭据进入日志
                      logger.warn('网页登录回包解析失败')
                    }
                  }
                }
                return false
              })
          }
          .width('100%')
          .height('100%')
          .padding({ bottom: this.navBarHeight })

          if (this.webLoginLoading) {
            Column() {
              LoadingProgress().width(32).height(32).color(AppColors.primary)
              Text('正在获取登录信息...').fontSize(14).margin({ top: 12 })
            }
            .width('100%').height('100%')
            .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
          }
        }
        .backgroundColor(Color.White)
        .width('100%')
        .height('100%')
      }
    }
    .width('100%').height('100%')
  }

  /** 使用账号密码或验证码继续登录。 */
  private async handleLogin(): Promise<void> {
    this.error = ''

    if (!this.username || !this.password) {
      this.error = '请输入用户名和密码'
      return
    }

    this.loading = true

    try {
      if (this.loginToken) {
        if (!this.captcha) {
          this.error = '请输入验证码'
          this.loading = false
          return
        }

        const result = await loginStep2(this.loginToken, this.captchaId, this.captcha)

        if (result.ok && result.token) {
          const user = result.user!
          await appStore.setAuth(result.token, user.uid, user.nickName, user.avatarUrl)
          this.getUIContext().getRouter().replaceUrl({ url: 'pages/MainPage' })
        } else if (result.needCaptcha) {
          this.loginToken = result.loginToken
          this.captchaId = result.captchaId
          this.captchaImage = result.captchaImage
          this.error = result.error
          this.captcha = ''
        } else {
          this.error = result.error || '登录失败'
        }
      } else {
        const result = await loginStep1(this.username, this.password)

        if (result.ok && result.needCaptcha) {
          this.loginToken = result.loginToken
          this.captchaId = result.captchaId
          this.captchaImage = result.captchaImage
        } else if (result.ok) {
          this.error = result.error || '登录失败'
        } else {
          this.error = result.error || '登录失败'
        }
      }
    } catch (e) {
      this.error = (e as Error).message || '网络错误'
    } finally {
      this.loading = false
    }
  }

  /** 选择并导入加密凭据文件。 */
  private async handleImport(): Promise<void> {
    this.error = ''

    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext
      const documentSelectOptions = new picker.DocumentSelectOptions()
      documentSelectOptions.maxSelectNumber = 1
      documentSelectOptions.fileSuffixFilters = ['.ngacred']

      const documentViewPicker = new picker.DocumentViewPicker(context)
      const uris: string[] = await documentViewPicker.select(documentSelectOptions)

      if (uris.length === 0) {
        return
      }

      this.importing = true

      const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY)
      const stat = fileIo.statSync(uris[0])
      const buffer = new ArrayBuffer(stat.size)
      const readLen = fileIo.readSync(file.fd, buffer)
      fileIo.closeSync(file)

      const textDecoder = util.TextDecoder.create('utf-8')
      const content = textDecoder.decodeToString(new Uint8Array(buffer, 0, readLen))

      if (!isEncryptedCredentialExport(content)) {
        this.error = '文件格式无效，请导入 .ngacred 加密凭证文件'
        return
      }

      this.pendingCredentialContent = content
      this.importPassword = ''
      this.importCredentialDialogController = new CustomDialogController({
        backgroundColor: Color.Transparent,
        systemMaterial: UIMaterialManager.dialogMaterial,
        maskColor: UIMaterialManager.scrim,
        builder: CustomContentDialog({
          primaryTitle: '导入加密凭证',
          secondaryTitle: '请输入导出时设置的加密密码（至少 8 位）。',
          contentBuilder: (): void => { this.importPasswordContent() }
          // 不传 buttons：官方按钮区不支持动态激活态（见 CredentialPasswordContent 说明），
          // 「取消 / 导入」由内容区自绘。
        }),
        autoCancel: true
      })
      this.importCredentialDialogController?.open()
    } catch (e) {
      this.error = (e as Error).message || '导入失败'
    } finally {
      this.importing = false
    }
  }

  /** 解密并验证已经选择的凭据文件。 */
  private async importEncryptedCredential(password: string): Promise<void> {
    this.error = ''
    this.importing = true
    try {
      const credential = await deserializeCredentialExport(this.pendingCredentialContent, password)
      const result = await injectCredentials(credential.uid, credential.cid)

      if (result.ok && result.token && result.user) {
        const user = result.user
        await appStore.setAuth(result.token, user.uid, user.nickName, user.avatarUrl)
        this.pendingCredentialContent = ''
        this.getUIContext().getRouter().replaceUrl({ url: 'pages/MainPage' })
      } else {
        this.error = result.error || '凭证验证失败'
      }
    } catch (e) {
      this.error = '解密失败，请检查密码或文件是否正确'
    } finally {
      this.importing = false
    }
  }

  /** 刷新图形验证码。 */
  private async refreshCaptcha(): Promise<void> {
    const gen: number = this.scope.begin()
    try {
      const result = await loginStep1(this.username, this.password)
      if (!this.scope.isActive(gen)) {
        return
      }
      if (result.ok) {
        this.loginToken = result.loginToken
        this.captchaId = result.captchaId
        this.captchaImage = result.captchaImage
        this.captcha = ''
      }
    } catch (_error) {
      logger.warn('获取验证码失败: %{public}s', formatError(_error))
    }
  }

  /** 打开响应式网页登录层。 */
  private openWebLogin(): void {
    this.error = ''
    this.loginDomain = getActiveDomain()
    this.authTriggered = false
    // 打开前先清空登录层的隐私 Cookie：确保本次登录一定从"未登录"开始
    // （清理点与原因见 WebViewCookieUtils 文件头）
    clearIncognitoWebCookies()
    this.showWebLogin = true
  }

  /** 关闭网页登录层并停止 Cookie 轮询。 */
  private closeWebLogin(): void {
    this.stopCookiePolling()
    // 登录层关闭即丢弃其中的登录态，不让有效凭证留在内存里被下一次打开复用
    clearIncognitoWebCookies()
    this.showWebLogin = false
  }

  /**
   * 开始轮询网页登录 Cookie（登录回包通道之一，另一条是 `onConsole` 的 `loginSuccess`）。
   *
   * ⚠️ 本通道只看**当前 WebView 的登录态**：页面加载完成后，只要 WebView 里带着有效凭证，
   * `document.cookie` 里就会出现 `ngaPassportUid` + `ngaPassportCid`，1.5s 内的第一次轮询
   * 就会取回凭证并完成登录，用户没有任何输入机会——这正是网页登录层必须走隐私模式、
   * 且进入前清空 Cookie 的原因（见 build 中 `incognitoMode` 的说明）。
   */
  private startCookiePolling(): void {
    if (this.pollingActive) {
      return
    }
    this.pollingActive = true
    this.scheduleCookieCheck()
  }

  /** 安排下一次网页登录 Cookie 检查。 */
  private scheduleCookieCheck(): void {
    if (!this.pollingActive || !this.showWebLogin || this.authTriggered) {
      return
    }
    try {
      this.webController.runJavaScript('document.cookie', (err: BusinessError, result: string) => {
        if (this.authTriggered) {
          return
        }
        if (!err && result && result.indexOf('ngaPassportUid') >= 0 && result.indexOf('ngaPassportCid') >= 0) {
          const parts: string[] = result.split(';')
          let uid: string = ''
          let cid: string = ''
          for (let j: number = 0; j < parts.length; j++) {
            const part: string = parts[j].trim()
            if (part.startsWith('ngaPassportUid=')) {
              uid = part.substring('ngaPassportUid='.length)
            } else if (part.startsWith('ngaPassportCid=')) {
              cid = part.substring('ngaPassportCid='.length)
            }
          }
          if (uid.length > 0 && cid.length > 0) {
            this.authTriggered = true
            this.pollingActive = false
            this.handleWebLoginResult(uid, cid)
            return
          }
        }
        if (this.pollingActive && this.showWebLogin && !this.authTriggered) {
          this.cookiePollTimer = setTimeout((): void => {
            this.scheduleCookieCheck()
          }, 1500)
        }
      })
    } catch (e) {
      if (!this.authTriggered) {
        this.cookiePollTimer = setTimeout((): void => {
          this.scheduleCookieCheck()
        }, 1500)
      }
    }
  }

  /** 停止网页登录 Cookie 轮询。 */
  private stopCookiePolling(): void {
    this.pollingActive = false
    if (this.cookiePollTimer !== -1) {
      clearTimeout(this.cookiePollTimer)
      this.cookiePollTimer = -1
    }
  }

  /** 验证网页登录凭据并进入主页面。 */
  private async handleWebLoginResult(uid: string, cid: string): Promise<void> {
    this.webLoginLoading = true
    try {
      const result = await injectCredentials(uid, cid)
      if (result.ok && result.token && result.user) {
        const user = result.user
        await appStore.setAuth(result.token, user.uid, user.nickName, user.avatarUrl)
        this.showWebLogin = false
        this.webLoginLoading = false
        this.getUIContext().getRouter().replaceUrl({ url: 'pages/MainPage' })
      } else {
        this.error = result.error || '凭据验证失败'
        this.webLoginLoading = false
        this.showWebLogin = false
      }
    } catch (e) {
      this.error = (e as Error).message || '处理失败'
      this.webLoginLoading = false
      this.showWebLogin = false
    } finally {
      // 凭证已交给 App 的 token 体系，登录层里的 Cookie 无论成败都不再需要
      clearIncognitoWebCookies()
    }
  }

  /** 结束页面异步会话并释放登录过程资源。 */
  aboutToDisappear(): void {
    this.scope.end()
    this.stopCookiePolling()
    this.importCredentialDialogController = undefined
    this.pendingCredentialContent = ''
  }
}
