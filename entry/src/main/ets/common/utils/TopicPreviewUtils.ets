/**
 * 主题列表帖子预览图工具（纯函数，可独立测试）。
 *
 * 数据来源：官方 subject 系列表条目的 `attachs` 数组 + 响应的 `attachPrefix`
 * （实测形状与覆盖率见 docs/TOPIC_PREVIEW_DESIGN.md §2）。
 *
 * **只产出原图绝对 URL**：列表预览与图片查看器同源同质量（见设计文档 §5.3 / K22）。
 * 服务端缩略档位（`.thumb.jpg` / `.thumb_s.jpg` / `.medium.jpg` …）的实测规则与"一键切档"
 * 的实现要点记录在设计文档 §5，**当前生产路径不启用**——需要时按那里实现即可，
 * 本模块保持最小表面积（不保留无调用方的函数）。
 *
 * 不依赖 AppStore / 网络，只做纯字符串变换。
 */

import { NGA_CDN_BASE } from '../../parser/_shared/AttachUrl'

/**
 * 可作为预览图的扩展名白名单。
 *
 * 与官方 `AttachsBean.parseUrlSubject()` 一致（jpg/jpeg/png/gif/webp）并补 bmp；
 * 实测 attachs 中混有 mp4（108 个附件里 1 个），不过滤会把视频当封面。
 * 注意：`.gif.mp4` 的 `.thumb.jpg` 实测是**可用封面**（见设计文档 §5.3）——若产品希望
 * "视频帖也有预览图"，可把 mp4 放入白名单，并接受列表里显示静帧。
 */
const PREVIEW_IMAGE_EXTS: string[] = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp']

/** 附件前缀缺失时的兜底根（换域时改 NgaDomains.NGA_IMG_BASE 即可）。 */
const FALLBACK_PREFIX: string = NGA_CDN_BASE + '/'

/**
 * 归一化附件前缀为「带协议、以 / 结尾」的形态。
 *
 * @param prefix - 响应 attachPrefix（可能为空；thread.php 的 _ATTACH_BASE_VIEW 无协议）
 * @returns 可拼接的前缀
 */
export function normalizeAttachPrefix(prefix: string): string {
  let p: string = prefix.trim()
  if (p.length === 0) {
    return FALLBACK_PREFIX
  }
  /* 协议判定不区分大小写：`HTTPS://…` 不能再补一次协议（否则拼出 `https://HTTPS://…`） */
  if (!/^https?:\/\//i.test(p)) {
    p = 'https://' + p
  }
  if (!p.endsWith('/')) {
    p = p + '/'
  }
  return p
}

/**
 * 判断 attachurl 是否为可作预览图的图片。
 *
 * @param attachurl - 官方附件相对路径
 * @returns 是否可作预览图
 */
export function isPreviewImage(attachurl: string): boolean {
  /* 先剥离 query/fragment：`a.jpg?x=1` 直接 lastIndexOf('.') 会取到 `jpg?x=1` 而误判为非图片 */
  let path: string = attachurl
  const query: number = path.indexOf('?')
  if (query >= 0) {
    path = path.substring(0, query)
  }
  const hash: number = path.indexOf('#')
  if (hash >= 0) {
    path = path.substring(0, hash)
  }
  const dot: number = path.lastIndexOf('.')
  if (dot < 0 || dot === path.length - 1) {
    return false
  }
  const ext: string = path.substring(dot + 1).toLowerCase()
  return PREVIEW_IMAGE_EXTS.indexOf(ext) >= 0
}

/**
 * 把 attachurl 拼成可加载的绝对 URL。
 *
 * @param prefix - 响应 attachPrefix（空串时回退 NGA_CDN_BASE）
 * @param attachurl - 官方附件相对路径（已是 http 开头则原样返回）
 * @returns 绝对 URL；非法值返回空串
 */
export function buildPreviewUrl(prefix: string, attachurl: string): string {
  if (attachurl.length === 0) {
    return ''
  }
  if (/^https?:\/\//i.test(attachurl)) {
    return attachurl
  }
  /* 剥前导 `./` 与前导 `/`：否则会拼出 `…/attachments/./mon_x/a.jpg` 或双斜杠 `…//mon_x/a.jpg` */
  let path: string = attachurl
  while (path.startsWith('./')) {
    path = path.substring(2)
  }
  while (path.startsWith('/')) {
    path = path.substring(1)
  }
  if (path.indexOf('/') < 0) {
    return ''
  }
  return normalizeAttachPrefix(prefix) + path
}

/**
 * 把官方 attachs 字段解析为预览图 URL 列表。
 *
 * @param rawAttachs - 原始 attachs 值（实测为对象数组；归一化层可能写入空串，JSON 可能为 null）
 * @param prefix - 响应 attachPrefix
 * @returns 预览图绝对 URL 列表（保序、已过滤非图片；无有效项时为空数组）
 */
export function parsePreviewImages(rawAttachs: Object | null | undefined, prefix: string): string[] {
  if (rawAttachs === undefined || rawAttachs === null || !Array.isArray(rawAttachs)) {
    return []
  }
  const urls: string[] = []
  const arr: Object[] = rawAttachs as Object[]
  for (let i = 0; i < arr.length; i++) {
    const item: Object = arr[i]
    if (item === undefined || item === null || typeof item !== 'object' || Array.isArray(item)) {
      continue
    }
    const attachurl: string = String((item as Record<string, Object>)['attachurl'] ?? '')
    if (!isPreviewImage(attachurl)) {
      continue
    }
    const url: string = buildPreviewUrl(prefix, attachurl)
    if (url.length > 0) {
      urls.push(url)
    }
  }
  return urls
}
