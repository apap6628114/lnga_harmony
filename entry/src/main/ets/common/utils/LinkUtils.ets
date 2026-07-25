import { common, Context } from '@kit.AbilityKit'
import { routerStore, Screen } from '../../store/RouterStore'
import { floatingLayerStore, FloatingPage } from '../../store/FloatingLayerStore'
import { KEY_USE_INTERNAL_WEBVIEW } from '../constants/AppStorageKeys'

/** NGA 域名列表 */
const NGA_DOMAINS: string[] = [
  'bbs.nga.cn',
  'ngabbs.com',
  'nga.178.com',
]

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

/** 判断主机名是否属于 NGA 域名 */
function isNgaDomain(hostname: string): boolean {
  const lower: string = hostname.toLowerCase()
  for (let i = 0; i < NGA_DOMAINS.length; i++) {
    if (lower === NGA_DOMAINS[i] || lower.endsWith('.' + NGA_DOMAINS[i])) {
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
    const pageStr: string = params.get('page') || '1'
    const pid: string = params.get('pid') || ''
    const page: number = parseInt(pageStr, 10) || 1
    if (tid.length > 0) {
      routerStore.navigateActivity(Screen.thread(tid, page, pid))
    }
  } else if (href.startsWith('#/profile?')) {
    // 应用内用户链接 → 弹窗资料卡
    const uidStr: string = href.split('uid=')[1]
    if (uidStr) {
      const uid: string = uidStr.split('&')[0]
      if (onProfileClick) {
        onProfileClick(uid)
      }
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
          const pageStr: string = params.get('page') || '1'
          const pid: string = params.get('pid') || ''
          const page: number = parseInt(pageStr, 10) || 1
          routerStore.navigateActivity(Screen.thread(tid, page, pid))
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
