/**
 * 帖子页「更多菜单」的装配器（自然列表 `ThreadPanel` 与递进树 `ThreadTreePanel` 共用）。
 *
 * 负责「有哪些项、什么顺序、文案与激活态」，以及三种**纯路由**动作的落地
 * （收藏入口 / 「从网页打开」/「在线模式打开」）。其余每一项做什么，由调用方的回调决定。
 *
 * ## 边界：哪些下沉、哪些留在页面
 *
 * **留在页面的**（本文件只保存回调）：
 * - 「只看楼主」：列表页要先判 `hasAuthorFilterIdentity` 并 toast「楼主身份尚未加载」，
 *   再清空待定位状态、重载分页窗口；树页判 `hasThreadAuthorKey`、toast「无法识别楼主」，
 *   然后重建树并保持中心楼层。判据、文案、重载路径三者都不同。
 * - 「离线保存」「跟踪帖子更新」：要 `new CustomDialogController`，且 `contentBuilder` 必须是
 *   页面自己的 `@Builder`（工程已有踩坑记录），无法搬到装配器。
 * - 「切换阅读方式」：两页互为反向入口，文案与目标页面都不同。
 * - 「分享帖子」：`getUIContext().getHostContext()` 的取值时机留在页面（点击时取）。
 *
 * **下沉到装配器的**（纯路由、无页面状态，两页逐字相同）：
 * - 收藏入口：空 tid 守卫 + `Screen.favoriteFolders`；
 * - 「从网页打开」：`threadWebUrl` + `Screen.webview`；
 * - 离线「在线模式打开」：`Screen.thread`。列表页不必强制替换（`navigateActivity` 对 thread
 *   类型本身会替换栈顶），树页必须传 `true`——这条路由语义差异由调用方用
 *   `replaceEntryOnOpenOnline` 声明。
 *
 * 本文件不依赖 ArkUI 上下文，菜单本体仍在 `PanelNavBar` 内部渲染。
 */

import { routerStore, Screen } from '../../../store/RouterStore'
import { threadWebUrl } from '../../utils/ThreadPostUtils'
import { NavBarMenuItem } from '../PanelNavBar'

/**
 * 菜单装配所需的数据与回调。
 *
 * 字段由调用方在 `moreMenuItems()` 里按**当前**状态赋值：菜单项在 `PanelNavBar` 的
 * `bindMenu` builder 里构建时求值，赋值时机与原来的内联构造一致
 * （`active` 与文案都能取到最新值）。
 */
export class ThreadMenuHost {
  /** 当前主题 ID（收藏入口与网页入口使用）。 */
  threadTid: string = ''

  /** 是否离线存档来源：决定整组菜单的裁剪。 */
  savedSource: boolean = false

  /** 收藏项文案（由收藏关系状态推导，见 `ThreadPostUtils.favoriteMenuLabel`）。 */
  favoriteLabel: string = ''

  /** 「跟踪帖子更新」是否为激活态。 */
  trackingActive: boolean = false

  /** 「只看楼主」是否为激活态。 */
  authorOnlyActive: boolean = false

  /** 「切换阅读方式」的文案（两页互为反向入口，由调用方给）。 */
  switchReadingLabel: string = ''

  /**
   * 离线来源「在线模式打开」是否强制替换栈顶条目。
   *
   * 列表页传 false（`navigateActivity` 对 `thread` 类型本身会替换栈顶 thread）；
   * 树页传 true（当前栈顶就是树页条目）。保留这个差异，不替调用方决定。
   */
  replaceEntryOnOpenOnline: boolean = false

  /** 打开离线保存对话框（两页各自构造 `CustomDialogController`）。 */
  onOpenSave: () => void = (): void => {}

  /** 打开跟踪帖子更新对话框。 */
  onOpenTrack: () => void = (): void => {}

  /** 切换只看楼主（前置检查、重载/重建都在调用方）。 */
  onToggleAuthorOnly: () => void = (): void => {}

  /** 切换阅读方式（目标页面由调用方决定）。 */
  onSwitchReading: () => void = (): void => {}

  /** 分享帖子（UIContext 取值时机留在调用方）。 */
  onShare: () => void = (): void => {}
}

/**
 * 构造更多菜单项。
 *
 * 顺序与设计文档一致：订阅三项 → 阅读视图两项 → 外部动作两项；
 * 离线存档只保留「在线模式打开 / 只看楼主 / 切换阅读 / 网页 / 分享」。
 *
 * @param host - 数据与回调
 * @returns 菜单项
 */
export function buildThreadMenuItems(host: ThreadMenuHost): NavBarMenuItem[] {
  const items: NavBarMenuItem[] = []
  if (host.savedSource) {
    // 离线存档：收藏 / 离线保存 / 跟踪都依赖在线通道，整组裁掉
    items.push({
      label: '在线模式打开',
      action: (): void => {
        // 不预检帖子是否失效：直接以在线模式打开，失效由目标页的错误态呈现
        routerStore.navigateActivity(Screen.thread(host.threadTid), host.replaceEntryOnOpenOnline)
      }
    })
    items.push({
      label: '只看楼主',
      active: host.authorOnlyActive,
      action: (): void => {
        host.onToggleAuthorOnly()
      }
    })
    items.push({
      label: host.switchReadingLabel,
      action: (): void => {
        host.onSwitchReading()
      }
    })
    items.push({
      label: '从网页打开',
      action: (): void => {
        routerStore.navigateActivity(Screen.webview(threadWebUrl(host.threadTid)))
      }
    })
    items.push({
      label: '分享帖子',
      action: (): void => {
        host.onShare()
      }
    })
    return items
  }

  items.push({
    label: host.favoriteLabel,
    action: (): void => {
      if (host.threadTid.length === 0) {
        return
      }
      routerStore.navigateActivity(Screen.favoriteFolders(host.threadTid))
    }
  })
  items.push({
    label: '离线保存帖子',
    action: (): void => {
      host.onOpenSave()
    }
  })
  // 激活态用文字色表达（`active`），与「只看楼主」同一模式：已跟踪时主色提示
  items.push({
    label: '跟踪帖子更新',
    active: host.trackingActive,
    action: (): void => {
      host.onOpenTrack()
    }
  })
  // 「只看楼主」对两种来源都成立（离线存档也能重新过滤已保存楼层），是视图组首项
  // 激活态用文字色表达（`active`），不用系统菜单的选中图标：后者会为该菜单项单独预留一块
  // 左侧图标位，本菜单只有这一项带它时会显得"像多了几个空格"（实机反馈）。
  items.push({
    label: '只看楼主',
    active: host.authorOnlyActive,
    action: (): void => {
      host.onToggleAuthorOnly()
    }
  })
  // 两种阅读样式互斥：切换一律由调用方原地替换当前栈条目
  items.push({
    label: host.switchReadingLabel,
    action: (): void => {
      host.onSwitchReading()
    }
  })
  items.push({
    label: '从网页打开',
    action: (): void => {
      routerStore.navigateActivity(Screen.webview(threadWebUrl(host.threadTid)))
    }
  })
  items.push({
    label: '分享帖子',
    action: (): void => {
      host.onShare()
    }
  })
  return items
}
