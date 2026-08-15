import { common, Context } from '@kit.AbilityKit'
import { routerStore, Screen, ThreadSource } from '../../store/RouterStore'
import { floatingLayerStore, FloatingPage } from '../../store/FloatingLayerStore'
import { appStore } from '../../store/AppStore'
import { resolveUidByUsername } from '../../service/api/UserApi'
import { locatePidPage } from '../../service/api/ThreadApi'
import { KEY_USE_INTERNAL_WEBVIEW } from '../constants/AppStorageKeys'
import { NGA_HOSTS } from '../constants/NgaDomains'

/**
 * 从 URL 中提取主机名。
 * 例：'https://nga.178.com/read.php?tid=1' → 'nga.178.com'
 */
function extractHostname(url: string): string {
  const start: number = url.indexOf('://') + 3
  const end: number = url.indexOf('/', start)
  return end >= 0 ? url.substring(start, end) : url.substring(start)
}

/**
 * 从 URL 中提取路径部分。
 * 例：'https://nga.178.com/read.php?tid=1' → '/read.php'
 */
function extractPath(url: string): string {
  const start: number = url.indexOf('://') + 3
  const pathStart: number = url.indexOf('/', start)
  if (pathStart < 0) return '/'
  const qsStart: number = url.indexOf('?', pathStart)
  return qsStart >= 0 ? url.substring(pathStart, qsStart) : url.substring(pathStart)
}

/**
 * 从 URL 中提取查询字符串（剥离片段标识符 #...）。
 * 例：'https://nga.178.com/read.php?tid=1&pid=2' → 'tid=1&pid=2'
 *      'https://nga.178.com/read.php?tid=1#pid123' → 'tid=1'
 */
function extractQueryString(url: string): string {
  const qsStart: number = url.indexOf('?')
  if (qsStart < 0) return ''
  const fragmentStart: number = url.indexOf('#', qsStart)
  const end: number = fragmentStart >= 0 ? fragmentStart : url.length
  return url.substring(qsStart + 1, end)
}

/**
 * 解析查询字符串为键值 Map。
 */
function parseQueryString(qs: string): Map<string, string> {
  const params: Map<string, string> = new Map()
  const parts: string[] = qs.split('&')
  for (let i = 0; i < parts.length; i++) {
    const kv: string[] = parts[i].split('=')
    if (kv.length === 2) params.set(kv[0], kv[1])
  }
  return params
}

/**
 * 判断主机名是否属于 NGA 域名（单一实现，WebViewPanel 等复用）。
 *
 * @param hostname - 主机名（不含协议）
 * @returns 是否属于 NGA 域名
 */
export function isNgaDomain(hostname: string): boolean {
  const lower: string = hostname.toLowerCase()
  for (let i = 0; i < NGA_HOSTS.length; i++) {
    if (lower === NGA_HOSTS[i] || lower.endsWith('.' + NGA_HOSTS[i])) {
      return true
    }
  }
  return false
}

export function openImageViewer(urls: string[], index: number): void {
  floatingLayerStore.imageViewerUrls = urls
  floatingLayerStore.imageViewerIndex = index
  floatingLayerStore.push(FloatingPage.IMAGE_VIEWER)
}

/**
 * 仅尝试通过有效的 App Linking 打开已安装应用，失败时执行调用方提供的兜底逻辑。
 *
 * @param href - 待打开的 HTTP(S) 链接
 * @param context - UIAbility 上下文
 * @param onUnavailable - 没有匹配应用或打开失败时的兜底回调
 */
export function openAppLinkOrFallback(
  href: string,
  context: common.UIAbilityContext,
  onUnavailable: () => void
): void {
  try {
    context.openLink(href, {
      appLinkingOnly: true,
      hideFailureTipDialog: true
    }).catch((): void => {
      onUnavailable()
    })
  } catch (e) {
    onUnavailable()
  }
}

/**
 * 将链接直接交给系统处理，由系统选择关联应用或浏览器。
 *
 * @param href - 待打开的链接
 * @param context - UIAbility 上下文
 */
export function openSystemLink(href: string, context: common.UIAbilityContext): void {
  try {
    context.openLink(href).catch((): void => {})
  } catch (e) {}
}

/**
 * 按用户名解析 UID 后弹资料卡（[@用户名] 链接点击，与帖子内作者信息区同一条弹出链路）。
 *
 * 官方 [@用户名] 链接语义为按用户名查用户主页，客户端资料卡只认 uid：
 * 解析成功 → onProfileClick(uid)；用户不存在或网络失败 → 提示。
 *
 * @param name - 解码后的用户名称
 * @param onProfileClick - 资料卡弹出回调
 */
async function openProfileCardByUsername(name: string, onProfileClick: (uid: string) => void): Promise<void> {
  try {
    const uid: string = await resolveUidByUsername(appStore.auth.token, name)
    if (uid.length > 0) {
      onProfileClick(uid)
    } else {
      appStore.showToast('找不到该用户')
    }
  } catch (e) {
    appStore.showToast('找不到该用户')
  }
}

/**
 * 处理论坛链接点击，识别 NGA 链接并执行应用内跳转。
 *
 * @param href - 链接地址
 * @param context - UIAbility 上下文，用于调用 openLink
 * @param onProfileClick - 用户头像/主页点击回调，用于弹窗显示资料卡
 */
export function handleForumLink(
  href: string,
  context: Context,
  onProfileClick?: (uid: string) => void
): void {
  if (href.startsWith('#/thread?')) {
    // 应用内帖子链接 → 导航到帖子详情
    const params: Map<string, string> = parseQueryString(href.substring(href.indexOf('?') + 1))
    const tid: string = params.get('tid') || ''
    const rawPage: string = params.get('page') || ''
    const pid: string = params.get('pid') || ''
    if (tid.length > 0) {
      openThreadLink(tid, rawPage, pid)
    }
  } else if (href.startsWith('#/profile?')) {
    // 应用内用户链接 → 弹窗资料卡：uid 直查；[username] 先按用户名解析 uid
    const params: Map<string, string> = parseQueryString(href.substring(href.indexOf('?') + 1))
    const uidStr: string = params.get('uid') || ''
    if (uidStr.length > 0) {
      if (onProfileClick) {
        onProfileClick(uidStr)
      }
      return
    }
    const rawName: string = params.get('username') || ''
    if (rawName.length > 0 && onProfileClick) {
      let name: string = rawName
      try {
        name = decodeURIComponent(rawName)
      } catch (e) {
        name = rawName
      }
      openProfileCardByUsername(name, onProfileClick)
    }
  } else if (href.startsWith('http://') || href.startsWith('https://')) {
    // 外部链接 → 判断是否为 NGA 链接
    const hostname: string = extractHostname(href)
    if (isNgaDomain(hostname)) {
      // NGA 链接：按路径分发
      const path: string = extractPath(href)
      const qs: string = extractQueryString(href)
      const params: Map<string, string> = parseQueryString(qs)

      if (path === '/read.php') {
        // NGA 帖子链接 → 应用内跳转
        const tid: string = params.get('tid') || ''
        if (tid.length > 0) {
          const rawPage: string = params.get('page') || ''
          const pid: string = params.get('pid') || ''
          openThreadLink(tid, rawPage, pid)
          return
        }
      } else if (path === '/nuke.php' && params.get('func') === 'ucp') {
        // NGA 用户主页链接 → 弹窗资料卡
        const uid: string = params.get('uid') || ''
        if (uid.length > 0 && onProfileClick) {
          onProfileClick(uid)
          return
        }
      }

      // 其他 NGA 链接 → WebView 打开
      routerStore.navigateActivity(Screen.webview(href))
    } else {
      const abilityContext: common.UIAbilityContext = context as common.UIAbilityContext
      const useInternalWebView: boolean = AppStorage.get<boolean>(KEY_USE_INTERNAL_WEBVIEW) ?? true
      if (useInternalWebView) {
        openAppLinkOrFallback(href, abilityContext, (): void => {
          routerStore.navigateActivity(Screen.webview(href))
        })
      } else {
        openSystemLink(href, abilityContext)
      }
    }
  }
}

/**
 * 打开链接来源的帖子。
 *
 * 显式携带页码时直接打开；仅携带 pid（无 page 参数）时，先完成 pid→页码
 * 数据查找（locatePidPage）再以正确页码打开——查找失败（楼层已删除/请求
 * 异常）时退化为不带定位意图地打开第 1 页。打开时统一标注 LINK 来源。
 *
 * @param tid - 主题 ID
 * @param rawPage - URL 中的页码参数（可能为空串）
 * @param pid - 目标楼层 pid（可能为空串）
 */
function openThreadLink(tid: string, rawPage: string, pid: string): void {
  const hasPage: boolean = rawPage.length > 0
  const page: number = hasPage ? (parseInt(rawPage, 10) || 1) : 1
  // '0' 是 NGA 的"主楼/无楼层"哨兵值（主楼 pid 即为 0），视为无定位意图，
  // 不做无谓的 pid 预查找（Screen.thread 也会做同样归一）
  const realPid: string = pid === '0' ? '' : pid
  if (realPid.length > 0 && !hasPage) {
    openThreadAfterPidLookup(tid, realPid)
  } else {
    routerStore.navigateActivity(Screen.thread(tid, page, realPid, ThreadSource.LINK))
  }
}

/**
 * pid→页码预查找的模块级代际计数：快速连点多个链接时，只执行最新一次查找的跳转，
 * 避免后完成的旧查找覆盖新意图。
 */
let linkLookupGeneration: number = 0

/**
 * 仅携带 pid 的链接：先完成 pid→页码数据查找，再打开帖子。
 *
 * @param tid - 主题 ID
 * @param pid - 目标楼层 pid
 */
async function openThreadAfterPidLookup(tid: string, pid: string): Promise<void> {
  const generation: number = ++linkLookupGeneration
  const page: number = await locatePidPage(appStore.auth.token, tid, parseInt(pid, 10))
  if (generation !== linkLookupGeneration) {
    // 已有更新的链接点击：丢弃过期结果
    return
  }
  if (page > 0) {
    routerStore.navigateActivity(Screen.thread(tid, page, pid, ThreadSource.LINK))
  } else {
    routerStore.navigateActivity(Screen.thread(tid, 1, '', ThreadSource.LINK))
  }
}
