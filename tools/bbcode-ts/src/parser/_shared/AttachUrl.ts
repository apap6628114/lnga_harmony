/**
 * NGA 附件 / 图片 URL 解析统一工具
 *
 * 项目内有两类附件 URL 解析需求，语义不同，此处集中导出避免重复：
 * - `resolveAttachUrl`：解析 ThreadApi 返回的附件对象 `attachurl` 字段。
 *   NGA 该字段为相对路径（如 `mon_202xxx/xxx`），需要拼到 CDN 根；纯数字或无斜杠视为非法返回空。
 * - `resolveImgUrl`：解析 BBCode `[img]` 标签内的图片地址。
 *   支持 `http(s)` 绝对地址、`./mon_` / `/mon_` NGA 内部图、`/` 开头相对路径，并去除图片后缀杂讯。
 */

import { stripImageSuffix } from '../../common/utils/Utils'
import { NGA_IMG_BASE, NGA_ATTACH_HOSTS } from '../../common/constants/NgaDomains'

/** NGA 论坛附件 CDN 根路径 */
export const NGA_CDN_BASE: string = NGA_IMG_BASE + '/attachments'

/**
 * [attach] 标签 URL 合法性校验正则（官方 commonui.ifUrlAttach 白名单移植）。
 *
 * 匹配 `http(s)://<附件域>/attachments/...` 或 `http(s)://<附件域>/...`
 * （`/attachments/` 前缀可选，语义与官方一致）。
 */
const NGA_ATTACH_URL_RE: RegExp = new RegExp(
  `^https?:\\/\\/(${NGA_ATTACH_HOSTS.join('|')})\\/(attachments\\/)?`
)

/**
 * 解析 NGA 附件对象 attachurl 字段为可访问 URL。
 * 纯数字或不含 `/` 的值视为非法，返回空字符串。
 *
 * @param attachurl NGA 返回的原始 attachurl 字段
 * @returns 完整可访问 URL；非法时返回空串
 */
export function resolveAttachUrl(attachurl: string): string {
  if (!attachurl) return ''
  if (attachurl.startsWith('http')) return attachurl
  if (/^[\d]+$/.test(attachurl) || !attachurl.includes('/')) return ''
  return `${NGA_CDN_BASE}/${attachurl}`
}

/**
 * 解析 BBCode `[attach]` 标签内的附件地址（官方 ubbcode.js [attach] 替换语义）。
 *
 * `./` 前缀拼 CDN 根（与官方 getAttachBase 拼接一致），再按 NGA 附件域白名单
 * 校验；非法时返回空串，调用方应保留 `[attach]...[/attach]` 原文（官方行为）。
 * 不做 trim：官方正则 `.` 不匹配换行、`./` 检查针对原文首字符，内容前后含
 * 空白（含换行）时官方整体不识别，此处保持同一语义。
 *
 * @param raw `[attach]` 标签原始内容
 * @returns 完整可访问的附件 URL；非法时返回空字符串
 */
export function resolveAttachBBCodeUrl(raw: string): string {
  if (raw.length === 0) return ''
  let url: string = raw
  if (url.startsWith('./')) {
    url = NGA_CDN_BASE + url.substring(1)
  }
  if (!NGA_ATTACH_URL_RE.test(url)) return ''
  return url
}

/**
 * 解析 BBCode `[img]` 标签内的图片地址为可访问 URL，并去除后缀杂讯。
 *
 * @param raw `[img]` 标签原始内容
 * @returns 完整可访问 URL（已 strip 后缀）
 */
export function resolveImgUrl(raw: string): string {
  if (raw.startsWith('http')) return stripImageSuffix(raw)
  if (raw.startsWith('/mon_') || raw.startsWith('./mon_')) {
    const path = raw.startsWith('./') ? raw.substring(1) : raw
    return NGA_CDN_BASE + stripImageSuffix(path)
  }
  if (raw.startsWith('/')) return NGA_CDN_BASE + stripImageSuffix(raw)
  return stripImageSuffix(raw)
}
