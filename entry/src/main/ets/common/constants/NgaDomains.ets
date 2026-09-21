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

/**
 * 站点基准根（站内相对链接补全用）。
 *
 * 官方 `ubbcode.urlToAry` 对同域链接（`checklink` 返回 3）以浏览器
 * `location.host` 为基准补全 `协议//host + path`；客户端没有页面 location，
 * 固定以主站 bbs.nga.cn 为基准（应用内跳转只按 host 判定是否 NGA 域，
 * 不依赖具体域名，补全结果仅需是绝对地址）。
 */
export const NGA_SITE_BASE: string = 'https://' + NGA_HOSTS[0]

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

/**
 * 外链图片主机白名单（官方 `commonui.checkOtherImg` 正则逐项移植，正则片段）。
 *
 * 官方 `ubbcode.imgGen` 渲染 `[img]` 时，非本站附件（既不是 `.` 开头的 NGA
 * 相对附件路径，也不属于 `NGA_ATTACH_HOSTS`）还要再过这道白名单；**不在名单里的
 * 外链一律退化为纯文本**（`[img]https://i.example.com/a.jpg[/img]` 在官方网页上
 * 显示为一行文本而不是图片）。因此本名单必须与官方逐项一致，多一项会渲染出
 * 官方不显示的图片，少一项会把官方能显示的图片变成文字。
 *
 * 顺序与官方正则完全一致（含官方原样的重复项 `pic\.imgdb\.cn`），便于与
 * `js_default.js` 的 `commonui.checkOtherImg` 逐项核对；
 * 部分项自带路径段（如 `clan\.akamai\.steamstatic\.com\/images`），拼接后仍与官方同义。
 */
export const NGA_IMG_URL_WHITELIST: string[] = [
  'img[0-9]?\\.nga\\.178\\.com',
  'img[0-9]?\\.nga\\.cn',
  'img[0-9]?\\.ngabbs\\.com',
  'pic[0-9]?\\.178\\.com',
  'img\\.db\\.178\\.com',
  'db1?\\.178\\.com',
  'imgs\\.aixifan\\.com',
  'pic[0-9]+\\.zhimg\\.com',
  '[a-z0-9]+\\.sinaimg\\.cn',
  'image\\.sinajs\\.cn',
  'pic-bucket\\.ws\\.126\\.net',
  'nimg\\.ws\\.126\\.net',
  'steampipe\\.steamcontent\\.tnkjmec\\.com',
  'st\\.dl\\.eccdnx\\.com',
  'st\\.dl\\.bscstorage\\.net',
  'st\\.dl\\.pinyuncloud\\.com',
  'dl\\.steam\\.ksyna\\.com',
  'cdn\\.mileweb\\.cs\\.steampowered\\.com\\.8686c\\.com',
  'cdn-ws\\.content\\.steamchina\\.com',
  'cdn-qc\\.content\\.steamchina\\.com',
  'cdn-ali\\.content\\.steamchina\\.com',
  '[a-z0-9]+\\.csgo\\.wmsj\\.cn',
  '[a-z0-9]+\\.dota2\\.wmsj\\.cn',
  'cdn\\.cloudflare\\.steamstatic\\.com',
  'pic\\.imgdb\\.cn',
  'liquipedia\\.net',
  'clan\\.akamai\\.steamstatic\\.com\\/images',
  'dota2\\.fandom\\.com',
  'redive\\.estertion\\.win',
  'bestdori\\.com',
  'imgbb\\.com',
  'i\\.ibb\\.co',
  'shp\\.qpic\\.cn',
  'docimg[0-9]+\\.docs\\.qq\\.com',
  'ricochet\\.cn',
  'dragalialost\\.akamaized\\.net',
  'sh0wer1ee\\.gitee\\.io',
  'shadowverse\\.com',
  'shadowverse\\.jp',
  'sv\\.163\\.com',
  'sv\\.res\\.netease\\.com',
  'shadowverse-portal\\.com',
  'imgchr\\.com',
  'img\\.vim-cn\\.com',
  '[a-z0-9]+\\.hypergryph\\.com',
  'web\\.hycdn\\.cn',
  'prts\\.wiki',
  'news\\.fate-go\\.jp',
  'game\\.bilibili\\.com',
  'i0\\.hdslb\\.com',
  'fgo\\.wiki',
  'm\\.qpic\\.cn',
  'upload-bbs\\.mihoyo\\.com',
  'pic\\.imgdb\\.cn',
  'images\\.contentstack\\.io',
  'ossweb-img\\.qq\\.com\\/upload\\/webplat\\/info\\/lol',
  'img\\.expreview\\.com',
  'techpowerup\\.com',
  'hearthstone\\.nosdn\\.127\\.net',
  'nie\\.res\\.netease\\.com',
  'smhtv-pic\\.tga\\.qq\\.com',
  'img\\.crawler\\.qq\\.com\\/cfwebcap',
  'static\\.gametalk\\.qq\\.com\\/image',
  'upload-bbs\\.miyoushe\\.com',
  'sbwsz\\.com',
  'xyoss\\.g\\.com\\.cn',
  'shadowverse-wb\\.com',
  'webview11\\.shadowverse-wb\\.jp',
  'hs\\.res\\.netease\\.com',
]

/** 静态资源 CDN 根（img4.nga.cn：版块图标/表情/徽章等） */
export const NGA_IMG4_BASE: string = 'https://img4.nga.cn'

/** 附件上传地址（img8.nga.cn/attach.php） */
export const NGA_UPLOAD_URL: string = 'https://img8.nga.cn/attach.php'

/** 头像兜底根路径（新域下部分 404，已有 imgError 色块降级，不崩） */
export const NGA_AVATAR_BASE: string = 'https://img4.nga.cn/ngabbs/nga_classic/avatar/'
