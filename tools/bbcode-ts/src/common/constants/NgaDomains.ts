/**
 * NGA 域名集中配置（唯一事实源）
 *
 * 所有 NGA 相关域名在此定义，各模块一律从此处引用，禁止散落硬编码。
 * NGA 切换域名时只需修改本文件。
 */

/** NGA 站点 host 列表（链接识别用，唯一事实源）。`nga.178.com` 目前 301 仍存活，保留兼容旧链接 */
export const NGA_HOSTS: string[] = [
  'bbs.nga.cn',
  'ngabbs.com',
  'nga.178.com',
]

/** NGA API 站点域（带协议，请求轮换用，由 NGA_HOSTS 派生） */
export const NGA_API_DOMAINS: string[] = NGA_HOSTS.map((host: string): string => 'https://' + host)

/** 附件图片 CDN 根（img.nga.cn，2026-08-05 从 img.nga.178.com 切换） */
export const NGA_IMG_BASE: string = 'https://img.nga.cn'

/**
 * 附件 URL 合法主机列表（官方 commonui.ifUrlAttach 白名单，正则片段）。
 *
 * 用于 [attach] 标签内容校验：仅 NGA 附件域（含旧域，部分仍 301 存活）的
 * http(s) URL 视为合法附件地址，与官方 ubbcode.js 替换规则一致。
 */
export const NGA_ATTACH_HOSTS: string[] = [
  'img\\d?\\.ngacn\\.cc',
  'img\\d?\\.nga\\.cn',
  'ngaimg\\.178\\.com',
  'img\\d?\\.nga\\.178\\.com',
  'img\\.nga\\.donews\\.com',
  'img\\.nga\\.bnbsky\\.com',
  'user-file\\.nga\\.178\\.com',
]

/** 静态资源 CDN 根（img4.nga.cn：版块图标/表情/徽章等） */
export const NGA_IMG4_BASE: string = 'https://img4.nga.cn'

/** 附件上传地址（img8.nga.cn/attach.php） */
export const NGA_UPLOAD_URL: string = 'https://img8.nga.cn/attach.php'

/** 头像兜底根路径（新域下部分 404，已有 imgError 色块降级，不崩） */
export const NGA_AVATAR_BASE: string = 'https://img4.nga.cn/ngabbs/nga_classic/avatar/'
