/**
 * NGA 附件 / 图片 URL 解析统一工具
 *
 * 项目内有两类附件 URL 解析需求，语义不同，此处集中导出避免重复：
 * - `resolveAttachUrl`：解析 ThreadApi 返回的附件对象 `attachurl` 字段。
 *   NGA 该字段为相对路径（如 `mon_202xxx/xxx`），需要拼到 CDN 根；纯数字或无斜杠视为非法返回空。
 * - `resolveImgTag`：按官方 `ubbcode.imgGen` 链路解析 BBCode `[img]` 标签内容，
 *   判定官方是否会把它渲染成图片；不会时返回官方退化出的纯文本。
 */

import { stripImageSuffix } from '../../common/utils/Utils'
import { decodeHtmlEntities } from './HtmlEntityCodec'
import { NGA_IMG_BASE, NGA_ATTACH_HOSTS, NGA_IMG_URL_WHITELIST } from '../../common/constants/NgaDomains'

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
 * 图片分支的附件判定正则（官方 `ubbcode.imgGen` 的 `a.self == 2` 语义）。
 *
 * 与 `[attach]` 用的 `NGA_ATTACH_URL_RE` **不同**：官方 `commonui.ifUrlAttach`
 * 命中 `/attachments/` 段返回 2、只命中附件域返回 1；渲染 `[img]` 时只有 self==2
 * 才直接进图片分支，self==1 会落到外链白名单（`checkOtherImg`）判定，而白名单不含
 * `user-file.nga.178.com` / `ngaimg.178.com` / `img.nga.bnbsky.com` / `img.nga.donews.com`
 * 等域 → 这些域的**非 attachments 路径**官方一律退化为文本（`img*.nga.cn` 与
 * `img*.nga.178.com` 则由白名单兜住，仍是图片）。`[attach]` 只要 `ifUrlAttach != 0`
 * 即算合法附件，两条链路语义不同，故各用一个正则。
 */
const NGA_ATTACH_IMG_URL_RE: RegExp = new RegExp(
  `^https?:\\/\\/(${NGA_ATTACH_HOSTS.join('|')})\\/attachments\\/`
)

/**
 * 外链图床白名单判定正则（官方 `commonui.checkOtherImg` 移植）。
 *
 * 与官方一致要求整段以 `http(s)://<白名单主机>/` 开头（白名单项可自带路径段）。
 */
const NGA_OTHER_IMG_URL_RE: RegExp = new RegExp(
  '^https?:\\/\\/(' + NGA_IMG_URL_WHITELIST.join('|') + ')\\/'
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
 * NGA 附件图片绝对 URL 归一化正则（官方 commonui.correctAttachUrl 移植）。
 *
 * 匹配 `http(s)://img<7>.<附件域>/` 的旧域图片 URL（nga.178.com / ngacn.cc 等
 * 历史附件域，其中 img.nga.178.com 已不可解析），官方渲染 [img] 时统一替换为
 * 当前附件基域（img.nga.cn），此处同构。`img7?` 与官方逐字一致：只匹配
 * `img` 与 `img7`，其余子域（如 img4.nga.178.com）官方不动，此处也不动。
 */
const NGA_ATTACH_IMG_RE: RegExp = /^https?:\/\/img7?\.(?:nga\.cn|ngacn\.cc|nga\.178\.com|nga\.donews\.com|ngabbs\.com)\//

/**
 * 判断 URL 是否为官方会渲染成图片的地址（官方 `ubbcode.imgGen` 图片分支判定）。
 *
 * 官方判定 = 附件的 `/attachments/` 形态（`commonui.ifUrlAttach` 返回 2，即 `a.self == 2`）
 * 或外链白名单（`commonui.checkOtherImg`）命中，二者都不满足时官方把整个 `[img]` 标签
 * 退化为纯文本。
 *
 * **有意偏离（客户端已知差异）**：白名单外链图官方网页渲染的是「显示图片」点击加载按钮，
 * 不是 `<img>`——`srcSelect` 对非附件（`a.self == 0`）**无条件**置 `a.btn = -3`，
 * `imgGen` 的 `if(!a.btn)` 因此走按钮分支（`js_bbscode_core.js:2103-2110`，与是否开启
 * 自动加载图片无关）。客户端没有等价的按钮形态，按 App 体验直接渲染为图片；判定"是不是
 * 图片"仍然与官方一致。
 *
 * @param url 已补全协议、已归一化附件域的绝对地址
 * @returns 是否渲染为图片
 */
export function isRenderableImgUrl(url: string): boolean {
  if (NGA_ATTACH_IMG_URL_RE.test(url)) return true
  return NGA_OTHER_IMG_URL_RE.test(url)
}

/**
 * `[img]` 标签内容的解析结果（官方 `ubbcode.imgGen` 语义）。
 *
 * 官方对图片内容与非法内容返回不同东西：图片返回 `<img>` 元素，非法内容
 * 把**整个 `[img]...[/img]` 标签**替换成一段纯文本，故此处两种结果二选一。
 */
export class ImgTagResolution {
  /** 是否渲染为图片。 */
  renderable: boolean = false
  /** 图片地址（renderable=true）或官方退化出的纯文本（renderable=false）。 */
  text: string = ''
}

/**
 * 按官方 `ubbcode.imgGen` 链路解析 `[img]` 标签内容。
 *
 * 官方处理顺序（逐条对齐，改动前请核对 `js_bbscode_core.js` 的 `imgGen`）：
 * 1. 内容含非 ASCII 字符：直接按错误标签处理，原样回吐并前后包上官方错误标记
 *    （`bbscode img error` 的注释形式文本，见函数体）；
 * 2. `.` 开头的 NGA 附件相对路径（`./mon_xxx`、`.1/mon_xxx`）拼附件 CDN 根；
 * 3. 无 `http(s)://` 前缀的一律补 `https://`（官方此处大小写敏感，保持同语义）；
 * 4. `img7?.<附件域>` 旧附件域归一化到当前 CDN 根（官方 `correctAttachUrl`）；
 * 5. 判定是否图片：附件的 `/attachments/` 形态或外链白名单 → 图片；否则**退化为纯文本**
 *    （补协议后的地址）；
 *
 * 线上实例：tid=47560793 主楼 `[img]mon_202609/15/xxx.jpg[/img]`（楼主漏写 `./`），
 * 官方网页渲染为文本 `https://mon_202609/15/xxx.jpg`；旧实现一律当图片，客户端
 * 用相对路径加载必然失败，表现为 3 个空白图片块。
 *
 * @param raw `[img]` 标签原始内容（未 trim，与官方一致）
 * @returns 图片地址或退化文本
 */
export function resolveImgTag(raw: string): ImgTagResolution {
  const resolution = new ImgTagResolution()

  if (!/^[\x00-\x7F]+$/.test(raw)) {
    resolution.text = '/* bbscode img error */' + raw + '/* bbscode img error */'
    return resolution
  }

  let src: string = raw
  if (/^\.\d*\//.test(src)) {
    src = NGA_CDN_BASE + '/' + src.replace(/^\.\d*\//, '')
  }

  if (!/^https?:\/\//.test(src)) {
    src = 'https://' + src
  }

  src = src.replace(NGA_ATTACH_IMG_RE, NGA_IMG_BASE + '/')

  if (!isRenderableImgUrl(src)) {
    resolution.text = src
    return resolution
  }

  resolution.renderable = true
  /*
   * 官方把地址写进 HTML 属性（`data-srclazy="…"`），浏览器解析属性时会把 `&amp;`
   * 还原成 `&`，请求用的是解码后的地址；客户端把 src 直接交给 Image 组件，必须在此
   * 自行解码，否则 `…a.jpg?x=1&amp;y=2` 会带着实体字面量发出去（参数错、可能 404）。
   */
  resolution.text = stripImageSuffix(decodeHtmlEntities(src))
  return resolution
}
