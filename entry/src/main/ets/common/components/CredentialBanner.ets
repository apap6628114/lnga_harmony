import { appStore } from '../../store/AppStore'
import { logoutOrchestrator } from '../../service/LogoutOrchestrator'
import { AppColors } from '../constants/Constants'
import { Logger, DOMAIN_UI, formatError } from '../utils/Logger'

const logger = new Logger(DOMAIN_UI, 'CredentialBanner')

/** 横幅高度（vp）。 */
const BANNER_H: number = 38

/** 横幅与屏幕边缘的距离（vp）。 */
const BANNER_MARGIN: number = 8

/** 操作槽位：重试（复验凭证）。 */
const ACTION_RETRY: number = 0

/** 操作槽位：重新登录（走用户主动退出语义）。 */
const ACTION_RELOGIN: number = 1

/** 操作槽位：收起横幅。 */
const ACTION_DISMISS: number = 2

/**
 * 文案要件：必须同时说明「哪里出了问题」与「哪些事做不了」。
 *
 * 只写"登录状态异常"会让用户以为整个应用不可用而退出；而实际读帖通常仍然可用
 * （NGA 各接口的会话校验强度不一致，`read.php` 弱于 `nuke.php`），真正被拦下的是写操作。
 */
const BANNER_TEXT: string = '登录状态异常，发帖回复等操作已暂停'

/**
 * 凭证降级横幅（屏幕底部浮动条）。
 *
 * ## 为什么在底部，而不是标题栏下方
 *
 * 曾经放在 `statusBarHeight + NAV_BAR_H`。但本工程的**左栏（`SidebarComponent`）与
 * sm 断点下的社区列都没有标题栏**，它们的头像块从 `statusBarHeight + 14` 就开始了
 * （`Avatar` 36 + 间距 8 + 昵称），那条 38vp 的横幅正好压住头像下缘与昵称；而板块列 /
 * 活动列的标题栏又确实在 `statusBarHeight + NAV_BAR_H`。同一个 y 在一个断点下同时遮挡
 * 两种列，没有任何位置能同时避开。
 *
 * 底部是唯一不会与"账号区 / 分类头 / 排序条"争夺的位置：它只可能盖住列表末尾，用户
 * 滚动即可避开。样式做成带圆角的浮动条而不是通栏，尽量少压内容。
 *
 * ## 触摸策略
 *
 * 外层 `Column` 铺满全屏（用 `justifyContent(End)` 把浮动条压到底部），
 * 必须标 `HitTestMode.Transparent`：它自己不参与命中、但也不阻塞下方兄弟节点，
 * 否则整块不可见的全屏容器会吞掉列表的滚动与点击。浮动条内的文字/按钮照常可点。
 *
 * ## 响应式
 *
 * 用 `@StorageProp('credentialDegraded')` 而不是观察 `AuthState.credentialState`：
 * `AuthState` 虽被 `@Observed` 装饰，但组件用 `@State` 持有它时**嵌套属性变化不驱动刷新**
 * （V1 状态管理），横幅会固化为首次渲染值。AppStorage 键由 `AppStore.publishCredentialState`
 * 统一维护。
 */
@Component
export struct CredentialBanner {
  /** 是否处于降级态（由 AppStore 写入 AppStorage）。 */
  @StorageProp('credentialDegraded') @Watch('onDegradedChanged') degraded: boolean = false
  /** 系统底部导航条高度（vp）：浮动条要避开手势条。 */
  @StorageProp('navBarHeight') navBarHeight: number = 0
  /** 用户是否已手动收起本次横幅（每次重新进入降级态时复位）。 */
  @State private dismissed: boolean = false
  /** 是否正在复验：防止连点重复发请求。 */
  @State private retrying: boolean = false

  /**
   * 降级态发生变化：重新出现时必须复位"已收起"。
   *
   * 只复位进入方向（true），不改退出方向：恢复时横幅本来就该消失，
   * 此时把 `dismissed` 保留为 false 可以让下一次降级立刻可见。
   */
  private onDegradedChanged(): void {
    if (this.degraded) {
      this.dismissed = false
    }
  }

  build() {
    Column() {
      Row({ space: 6 }) {
        Text(BANNER_TEXT)
          .fontSize(12)
          .fontColor(AppColors.warnText)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        this.BannerAction(ACTION_RETRY)
        this.BannerAction(ACTION_RELOGIN)
        this.BannerAction(ACTION_DISMISS)
      }
      .width('100%')
      .height(BANNER_H)
      .padding({ left: 12, right: 4 })
      .backgroundColor(AppColors.warnBg)
      .borderRadius(10)
      .border({ width: 1, color: AppColors.warnBorder })
      .shadow({ radius: 8, color: AppColors.shadowLight, offsetX: 0, offsetY: 2 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .padding({
      left: BANNER_MARGIN,
      right: BANNER_MARGIN,
      bottom: this.navBarHeight + BANNER_MARGIN
    })
    // 关键：铺满全屏的容器不得吞掉下方列表的触摸与滚动
    .hitTestBehavior(HitTestMode.Transparent)
    .visibility(this.isVisible() ? Visibility.Visible : Visibility.None)
  }

  /**
   * 横幅当前是否可见。
   *
   * @returns 降级且未被用户收起时为 true
   */
  private isVisible(): boolean {
    return this.degraded && !this.dismissed
  }

  /**
   * 横幅上的一个文字操作。
   *
   * `kind` 是按值传入的**编译期字面量**（`ACTION_*`），不参与响应式依赖；
   * 文案 / 可点性一律由 `this` 上的方法读取状态，符合「@Builder 按值传参不建立响应式依赖」
   * 的约定（见 entry/src/AGENTS.md）。
   */
  @Builder
  BannerAction(kind: number) {
    Text(this.actionLabel(kind))
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(AppColors.warnText)
      // 触达高度按内容撑开（约 30vp）：12sp 文字单靠 padding 很难达到可点面积
      .padding({ left: this.actionPadding(kind), right: this.actionPadding(kind), top: 7, bottom: 7 })
      .borderRadius(6)
      .border({ width: this.actionBorderWidth(kind), color: AppColors.warnBorder })
      .opacity(this.actionEnabled(kind) ? 1 : 0.5)
      .accessibilityText(this.actionLabel(kind))
      .onClick(() => {
        this.handleAction(kind)
      })
  }

  /**
   * 操作文案。
   *
   * 重试期间把按钮文案改成"重试中"，让用户知道点已经收到了。
   * 重新登录后的横幅很快消失，不需要额外的确认文案。
   */
  private actionLabel(kind: number): string {
    if (kind === ACTION_RETRY) {
      return this.retrying ? '重试中' : '重试'
    }
    if (kind === ACTION_RELOGIN) {
      return '重新登录'
    }
    return '收起'
  }

  /** 收起按钮不描边，避免三个等重按钮抢注意力。 */
  private actionBorderWidth(kind: number): number {
    return kind === ACTION_DISMISS ? 0 : 1
  }

  /** 收起按钮的左右内边距更小，节省窄屏宽度。 */
  private actionPadding(kind: number): number {
    return kind === ACTION_DISMISS ? 6 : 9
  }

  /** 操作当前是否可点（复验在途时禁止连点；其余始终可点）。 */
  private actionEnabled(kind: number): boolean {
    if (kind === ACTION_RETRY) {
      return !this.retrying
    }
    return true
  }

  /**
   * 处理操作点击。
   *
   * @param kind - 操作槽位（`ACTION_*`）
   */
  private handleAction(kind: number): void {
    if (kind === ACTION_RETRY) {
      this.retryCredential()
      return
    }
    if (kind === ACTION_RELOGIN) {
      this.relogin()
      return
    }
    this.dismissed = true
  }

  /**
   * 强制复验凭证。
   *
   * 成功时 `SessionGuard` 会经恢复回调清掉降级态，横幅随之消失；失败必须给出反馈 ——
   * 否则按钮只是闪一下"重试中"再变回"重试"，用户看不出到底有没有生效。
   */
  private retryCredential(): void {
    if (this.retrying) {
      return
    }
    this.retrying = true
    appStore.retryCredential().then((): void => {
      this.retrying = false
      if (this.degraded) {
        appStore.showToast('仍未通过校验，可稍后再试或重新登录')
      }
    }).catch((e: Error): void => {
      this.retrying = false
      appStore.showToast('校验请求失败，请检查网络后重试')
      logger.warn('凭证复验失败: %{public}s', formatError(e))
    })
  }

  /**
   * 重新登录：走用户主动退出语义。
   *
   * 这条路径会清掉内存态（当前帖子/列表位置），但磁盘上的历史、收藏与离线存档不受影响，
   * 重新登录同一账号后都还在。`LoginPage` 没有返回路径，这是唯一干净的做法。
   */
  private relogin(): void {
    logoutOrchestrator.logout(this.getUIContext()).catch((e: Error): void => {
      logger.error('重新登录流程失败: %{public}s', formatError(e))
    })
  }
}
