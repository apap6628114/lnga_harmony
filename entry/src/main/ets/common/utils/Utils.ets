import { BBNode, BBNodeType } from '../../model/BBCodeNode'
import { unescapeHtml } from '../../parser/_shared/HtmlEntityCodec'
import { NGA_IMG_BASE, NGA_AVATAR_BASE } from '../constants/NgaDomains'

/**
 * 通用工具函数
 */

export function parseAlterinfoTs(alterinfo: string): number | null {
  if (!alterinfo) return null
  const m: RegExpExecArray | null = /\[E(\d+)/.exec(alterinfo)
  if (m) {
    const n: number = Number(m[1])
    if (!isNaN(n) && n > 0) return n
  }
  return null
}

export function formatTimestampCST(ts: number): string {
  if (!ts) return ''
  const d: Date = new Date(ts * 1000)
  const cst: Date = new Date(d.getTime() + d.getTimezoneOffset() * 60000 + 8 * 3600000)
  const y: number = cst.getFullYear()
  const M: string = String(cst.getMonth() + 1).padStart(2, '0')
  const D: string = String(cst.getDate()).padStart(2, '0')
  const h: string = String(cst.getHours()).padStart(2, '0')
  const m: string = String(cst.getMinutes()).padStart(2, '0')
  return `${y}-${M}-${D} ${h}:${m}`
}

/**
 * 相对/绝对时间展示（统一口径）：
 * - 60 秒内「刚刚」，其后依次为 N分钟前 / N小时前 / N天前（相对差值与本地时区无关）；
 * - 超过 30 天显示绝对日期，一律按 NGA 服务器时间（东八区）计算，与
 *   formatTimestampCST 口径一致、补零风格一致（当年 "MM-DD HH:mm"，跨年 "YYYY-MM-DD"）。
 */
export function formatTime(ts: number | string): string {
  if (!ts) return ''
  const numTs = typeof ts === 'string' ? Number(ts) : ts
  if (isNaN(numTs)) return String(ts)
  const d = new Date(numTs > 1e12 ? numTs : numTs * 1000)
  if (isNaN(d.getTime())) return String(ts)
  const diff = Date.now() - d.getTime()
  if (diff < 60000) return '刚刚'
  if (diff < 3600000) return `${Math.floor(diff / 60000)}分钟前`
  if (diff < 86400000) return `${Math.floor(diff / 3600000)}小时前`
  if (diff < 2592000000) return `${Math.floor(diff / 86400000)}天前`
  const cst: Date = new Date(d.getTime() + d.getTimezoneOffset() * 60000 + 8 * 3600000)
  const nowCst: Date = new Date(Date.now() + new Date().getTimezoneOffset() * 60000 + 8 * 3600000)
  const isThisYear: boolean = cst.getFullYear() === nowCst.getFullYear()
  if (isThisYear) {
    return `${String(cst.getMonth() + 1).padStart(2, '0')}-${String(cst.getDate()).padStart(2, '0')} ${String(cst.getHours()).padStart(2, '0')}:${String(cst.getMinutes()).padStart(2, '0')}`
  }
  return `${cst.getFullYear()}-${String(cst.getMonth() + 1).padStart(2, '0')}-${String(cst.getDate()).padStart(2, '0')}`
}

/**
 * 今天日期（东八区，NGA 服务器日），格式 "YYYY-MM-DD"。
 * 用于签到等按服务器日去重的逻辑；与 formatTimestampCST 同为服务器时间口径。
 */
export function formatTodayCST(): string {
  const now: Date = new Date()
  const cst: Date = new Date(now.getTime() + now.getTimezoneOffset() * 60000 + 8 * 3600000)
  const y: number = cst.getFullYear()
  const M: string = String(cst.getMonth() + 1).padStart(2, '0')
  const D: string = String(cst.getDate()).padStart(2, '0')
  return `${y}-${M}-${D}`
}

export function fmtNum(n: string | number): string {
  const num = Number(n)
  if (isNaN(num)) return String(n)
  if (num >= 10000) return (num / 10000).toFixed(1) + 'w'
  if (num >= 1000) return (num / 1000).toFixed(1) + 'k'
  return String(num)
}

/**
 * NGA 金钱格式化（金/银/铜三段制，对应官方 commonui.calc_money 的 title 文本）：
 * 1 金 = 10000 铜，1 银 = 100 铜；如 600 → "6银币"。
 * 与官方展示口径一致（官方 ucp 页面 money=600 显示为 6 银币）。
 */
export function formatMoney(raw: string | number): string {
  const c = Number(raw)
  if (isNaN(c) || c <= 0) return '0'
  const g = Math.floor(c / 10000)
  const s = Math.floor(c / 100) - g * 100
  const t = c - g * 10000 - s * 100
  let out: string = ''
  if (g > 0) out += g + '金币 '
  if (s > 0) out += s + '银币 '
  if (t > 0) out += t + '铜币 '
  return out.trim()
}

export function escHtml(s: string): string {
  if (!s) return ''
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

export function getAvatarUrl(avatar: string, uid?: number | string): string {
  if (!avatar) return ''
  if (avatar.startsWith('http')) return avatar
  if (avatar.startsWith('/')) return NGA_IMG_BASE + avatar
  return NGA_AVATAR_BASE + avatar
}

/**
 * NGA CDN 图片 URL 后缀处理
 *
 * NGA 对同一张图片提供多种分辨率，通过文件名后缀区分：
 *   xxx.jpg         → 原始全尺寸
 *   xxx.thumb_s.jpg → 小缩略图 (≤56px)
 *   xxx.thumb_m.jpg → 中缩略图 (≤120px)
 *   xxx.medium.jpg  → 中等尺寸 (>120px)
 *   xxx.thumb.jpg   → 旧式缩略图
 *
 * stripImageSuffix(url)  → 去掉所有后缀，返回原始尺寸 URL
 * applyImageSuffix(url, suffix) → 在原始尺寸 URL 上添加指定后缀
 */

function doStripSuffix(url: string): string {
  let r: string = url
    .replace(/\.thumb_s(\.\w+)$/i, '$1')
    .replace(/\.thumb_m(\.\w+)$/i, '$1')
    .replace(/\.medium(\.\w+)$/i, '$1')
    .replace(/\.thumb(\.\w+)$/i, '$1')
  const knownExts: string[] = ['webp', 'png', 'gif', 'bmp', 'jpg', 'jpeg']
  const lastDot: number = r.lastIndexOf('.')
  if (lastDot > 0) {
    const prev: string = r.substring(0, lastDot)
    const secondDot: number = prev.lastIndexOf('.')
    if (secondDot > 0) {
      const firstExt: string = prev.substring(secondDot + 1).toLowerCase()
      if (knownExts.indexOf(firstExt) >= 0) {
        r = prev
      }
    }
  }
  return r
}

export function stripImageSuffix(url: string): string {
  if (!url) return url
  return doStripSuffix(url)
}

export function applyImageSuffix(url: string, suffix: string): string {
  if (!url) return url
  const base: string = doStripSuffix(url)
  const dot: number = base.lastIndexOf('.')
  if (dot < 0) return base
  return base.substring(0, dot) + '.' + suffix + base.substring(dot)
}

/**
 * 根据 name 生成 HSL 色相值（用于头像背景色）
 */
export function nameToHue(name: string): number {
  const n = name || '?'
  let acc = 0
  for (let i = 0; i < n.length; i++) {
    acc += n.charCodeAt(i)
  }
  return acc % 360
}

/**
 * HSL 转 HEX 颜色（ArkUI 不支持 hsl() 字符串，需转换为 #RRGGBB）
 */
export function hslToHex(h: number, s: number, l: number): string {
  const sNorm = s / 100
  const lNorm = l / 100
  const a = sNorm * Math.min(lNorm, 1 - lNorm)
  const f = (n: number): string => {
    const k = (n + h / 30) % 12
    const color = lNorm - a * Math.max(Math.min(k - 3, 9 - k, 1), -1)
    return Math.round(255 * Math.max(0, Math.min(1, color))).toString(16).padStart(2, '0')
  }
  return `#${f(0)}${f(8)}${f(4)}`
}

/**
 * 获取名称首字母
 */
export function getInitial(name: string): string {
  const ch = (name || '?').charAt(0).toUpperCase()
  return ch || '?'
}

function collectNodeText(nodes: BBNode[]): string {
  let result: string = ''
  for (let i = 0; i < nodes.length; i++) {
    const node: BBNode = nodes[i]
    switch (node.type) {
      case BBNodeType.TEXT:
        result += node.text
        break
      case BBNodeType.IMAGE:
      case BBNodeType.ALBUM:
        result += ' [图片] '
        break
      case BBNodeType.VIDEO:
      case BBNodeType.FLASH:
        result += ' [视频] '
        break
      case BBNodeType.AUDIO:
        result += ' [音频] '
        break
      case BBNodeType.EMOTION:
        result += ' [表情] '
        break
      case BBNodeType.QUOTE:
        result += '\n【引用】\n' + collectNodeText(node.children) + '\n【/引用】\n'
        break
      case BBNodeType.COLLAPSE:
        if (node.title.length > 0) {
          result += node.title + '\n'
        }
        result += collectNodeText(node.children)
        break
      case BBNodeType.CODE:
        result += '\n代码:\n' + node.text + '\n'
        break
      case BBNodeType.LIST:
        for (let j = 0; j < node.children.length; j++) {
          result += '- ' + collectNodeText(node.children[j].children)
          if (j < node.children.length - 1) result += '\n'
        }
        result += '\n'
        break
      case BBNodeType.TABLE: {
        for (let r = 0; r < node.children.length; r++) {
          const row: BBNode = node.children[r]
          for (let c = 0; c < row.children.length; c++) {
            result += collectNodeText(row.children[c].children)
            if (c < row.children.length - 1) result += ' | '
          }
          if (r < node.children.length - 1) result += '\n'
        }
        result += '\n'
        break
      }
      case BBNodeType.HR:
        result += '\n---\n'
        break
      case BBNodeType.PARAGRAPH:
      case BBNodeType.HEADING:
        result += collectNodeText(node.children)
        if (i < nodes.length - 1) result += '\n'
        break
      case BBNodeType.POST_BY:
        result += '—— ' + collectNodeText(node.children)
        break
      case BBNodeType.URL:
      case BBNodeType.PID_LINK:
      case BBNodeType.UID_LINK:
      case BBNodeType.TID_LINK:
        if (node.children.length > 0) {
          result += collectNodeText(node.children)
        } else if (node.href.length > 0) {
          result += node.href
        }
        break
      default:
        if (node.children.length > 0) {
          result += collectNodeText(node.children)
        } else if (node.text.length > 0) {
          result += node.text
        }
        break
    }
  }
  return result
}

export function bbNodesToPlainText(nodes: BBNode[]): string {
  let result: string = ''
  for (let i = 0; i < nodes.length; i++) {
    const node: BBNode = nodes[i]
    switch (node.type) {
      case BBNodeType.TEXT:
        result += node.text
        break
      case BBNodeType.IMAGE:
      case BBNodeType.ALBUM:
      case BBNodeType.VIDEO:
      case BBNodeType.FLASH:
      case BBNodeType.AUDIO:
      case BBNodeType.EMOTION:
      case BBNodeType.HR:
        break
      case BBNodeType.QUOTE:
        result += bbNodesToPlainText(node.children) + '\n'
        break
      case BBNodeType.PARAGRAPH:
      case BBNodeType.HEADING:
        result += bbNodesToPlainText(node.children)
        if (i < nodes.length - 1) result += '\n'
        break
      default:
        if (node.children.length > 0) {
          result += bbNodesToPlainText(node.children)
        } else if (node.text.length > 0) {
          result += node.text
        }
        break
    }
  }
  return unescapeHtml(result).replace(/\n{3,}/g, '\n\n').trim()
}

