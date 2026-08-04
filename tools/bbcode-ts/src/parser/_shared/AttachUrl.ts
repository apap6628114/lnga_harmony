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

/** NGA 论坛附件 CDN 根路径 */
export const NGA_CDN_BASE: string = 'https://img.nga.178.com/attachments'

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
