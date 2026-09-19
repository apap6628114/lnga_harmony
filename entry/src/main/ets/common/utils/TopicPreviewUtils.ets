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
 * 另含**响应式布局纯函数**（§6.2 起）：从 `attachurl` 文件名解出真实像素尺寸、由图片比例
 * 与容器宽度算出预览区高度、判定 Cover / Contain。这些函数是"图片比例多样 × 设备形态多样"
 * 的唯一算法出口，UI 层只消费结果，不得内联同样的算式（测试覆盖见 §6.7）。
 *
 * 不依赖 AppStore / 网络，只做纯字符串变换与算术。
 */

import { NGA_CDN_BASE } from '../../parser/_shared/AttachUrl'
import { ImageSize } from '../media/ImageSizeUtil'

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

// ============== 预览图响应式布局（§6.2 起） ==============

/**
 * 尺寸段解码的合法边界。
 *
 * NGA 附件文件名形如 `mon_202608/19/7Q68-jpq0ZtT3cS1uo-11i.jpeg`，其中 `S{base36宽}-{base36高}`
 * 是**真实像素尺寸**（实测：596 张真实列表附件里 589 张带该段，解码宽高比与逐张 Range 请求
 * 取回的真实宽高比 **589/589 完全一致**，见设计文档 §6.2.1）。
 *
 * 边界用于挡住两类脏数据：
 * - 恶意的超长 base36（如 `Szzzz-zzzz` = 1679615×1679615）→ 超出 `MAX_PIXELS`；
 * - 比例极端到不可能作为缩略图预览的编码 → 超出 `MIN/MAX_ASPECT`（这会与 §6.3 的
 *   "长图/超宽图"分支重合，但那是**已确认的真实比例**，此处拦的是明显荒谬值）。
 */
const MIN_PIXELS: number = 16
const MAX_PIXELS: number = 20000
const MIN_ASPECT: number = 1 / 24
const MAX_ASPECT: number = 24

/**
 * 预览区容器高度参数（vp）——实测标定，改值前先读设计文档 §6.2.2。
 *
 * - `MIN_HEIGHT` 112：超宽全景图的落点。再矮会让 3.5:1 以上的图退化成"一条线"，
 *   而这类图在列表里的信息量（总览、战报长图）本就靠整体轮廓传达。
 * - `MAX_HEIGHT` 240：竖图的封顶。取值约束来自"一屏可读条数"：卡片文字区约 180vp，
 *   图片区 240vp 时整卡 ≈ 420vp，在 640~800vp 的列表可视高度下仍能露出近 2 条。
 *   240 而非 200 的理由：竖图走 `Contain` 完整显示，其**显示宽度**完全由这个上限决定
 *   （宽度 = 高度 × 比例），200 → 240 让 3:4 竖拍的显示宽度从 150vp 提到 180vp（+20%）。
 * - `WIDTH_FACTOR` 0.90：容器高度按"宽度 × 0.90 / 比例"取，即**留 10% 裁切余量**，
 *   使横图在 Cover 下既不顶到卡片上沿、也不至于把主体裁掉。
 *
 * 实测（582 个真实附件、sm 360vp 窗口、图片区 328vp）：固定 120vp 高度平均只能看到
 * 39.7% 的画面，本参数下提升到约 59%，且 16:9 / 3:2 这类常见横图的裁切从 35~45% 降到 10%。
 */
const MIN_PREVIEW_HEIGHT: number = 112
const MAX_PREVIEW_HEIGHT: number = 240
const PREVIEW_HEIGHT_WIDTH_FACTOR: number = 0.9

/**
 * 竖图阈值（图片宽高比低于此值改用 `Contain`：完整显示、两侧留底色）。
 *
 * 取 0.9 而非 1.0：容器比例恒有下限（sm 下约 1.64），任何竖图在 `Cover` 下都只能看到中段
 * 横带（1:1 方图剩 37%、3:4 竖拍剩 27%、9:16 剩 21%）。改 `Contain` 后图片按宽度完整显示，
 * 代价是容器内出现底色——实测列表附件里竖图占 **46%**，这个代价换来的是"看得到整张图"。
 */
const CONTAIN_ASPECT_THRESHOLD: number = 0.9

/**
 * 角标阈值：比例低于/高于此值时标「长图」，提示用户"列表里看不全"。
 *
 * **必须与 `CONTAIN_ASPECT_THRESHOLD` 分开取值**：`Contain` 是 0.9 以下的所有竖图
 * （完整显示、不裁切），而那已经足够表达"这是一张竖图"；若角标也用 0.9，实测 46% 的
 * 条目都会挂上角标，提示立刻失去信息量。
 *
 * 更关键的是**角标的语义**：它说的是"列表里看不全，点开才是完整的"，因此只对真正看不全的
 * 两种极端比例出现——超宽图被 `Cover` 裁掉两端（3.5:1 以上裁掉约 16%），极端长图被
 * `MaxHeight` 压到很窄的一条（0.4 以下只剩约 1/3 宽度）。介于其间的竖图是**完整**显示的，
 * 标角标反而误导。
 */
const TALL_IMAGE_ASPECT: number = 0.4
const WIDE_IMAGE_ASPECT: number = 3.5

/**
 * 图片区宽度未知（首帧尚未测得列表宽度）时的兜底值。
 *
 * 取 328 = sm 360vp 窗口的实测列表宽度 360 − 条目左右内边距 32（见 `TopicListPanel` 的
 * `ITEM_HORIZONTAL_PADDING`；列表自身没有左右 padding）。首帧用它算出的高度与真实值
 * 只差几个 vp，且在列表完成首次布局后立即被真实宽度替换。
 */
export const FALLBACK_PREVIEW_AREA_WIDTH: number = 328

/**
 * 尺寸段解码：文件名末尾的 `S{base36宽}-{base36高}` + 扩展名。
 *
 * **不能要求尺寸段前面有分隔符**（曾经的错误写法是 `[.\-]S…`）：真实文件名形如
 * `…-jpq0ZtT3cS1uo-11i.jpeg`，`S` 前面是 `c`（`T3c` 标记的末字符），没有任何分隔符。
 * 锚定 `$` 保证取的是**紧贴扩展名的最后一段**（文件名可含多个尺寸段，见 K23）。
 */
const SIZE_SEGMENT_PATTERN: RegExp = /S([0-9a-z]{1,4})-([0-9a-z]{1,4})\.[a-z0-9]+$/i

/**
 * 从 `attachurl` 解出真实像素尺寸。
 *
 * 只认文件名（先剥 query / fragment），且要求尺寸段**紧贴扩展名**（`…T3cS1uo-11i.jpeg`）——
 * 该形态与实测样本一致；`7Q5-b75pZbT1kSb4-68.png` 这类"多个尺寸段"的文件名取最后一个，
 * 它同样是真实尺寸（实测 400×224 = base36('b4')×base36('68')）。
 *
 * @param attachurl - 官方附件相对路径或绝对 URL（空串/无尺寸段返回 null）
 * @returns 真实像素尺寸；无法确定时返回 null（调用方走兜底比例）
 */
export function parsePreviewSize(attachurl: string): ImageSize | null {
  if (attachurl.length === 0) {
    return null
  }
  /* 剥 query / fragment：与 isPreviewImage 同一套守卫（`a.jpg?x=1` 不能干扰尾部匹配） */
  let path: string = attachurl
  const query: number = path.indexOf('?')
  if (query >= 0) {
    path = path.substring(0, query)
  }
  const hash: number = path.indexOf('#')
  if (hash >= 0) {
    path = path.substring(0, hash)
  }
  const matched: RegExpMatchArray | null = path.match(SIZE_SEGMENT_PATTERN)
  if (matched === null) {
    return null
  }
  const width: number = parseInt(matched[1], 36)
  const height: number = parseInt(matched[2], 36)
  if (!Number.isFinite(width) || !Number.isFinite(height)) {
    return null
  }
  if (width < MIN_PIXELS || height < MIN_PIXELS || width > MAX_PIXELS || height > MAX_PIXELS) {
    return null
  }
  const aspect: number = width / height
  if (aspect < MIN_ASPECT || aspect > MAX_ASPECT) {
    return null
  }
  const size: ImageSize = new ImageSize()
  size.width = width
  size.height = height
  return size
}

/**
 * 解析预览图布局（图片区宽度已知后调用）。
 *
 * 纯算术，无副作用：`aspect` 由 `parsePreviewSize` 给出，缺失时用 16:9 兜底（与
 * `BBCodeContentView.getImageAspectRatio` 同一档占位比例，项目内保持一致）。
 *
 * 同时给出 `aspect`、`useContain` 与 `displayWidth`，因为**单图竖图要收窄容器**
 * （见 `PreviewLayout.displayWidth`）：`Contain` 下图片按高度等比放缩，容器若仍撑满图片区
 * 宽度，图片两侧就会各留一条空白。收窄到 `height × aspect` 后图片贴左、且**没有任何多余留白**。
 *
 * 收窄不会溢出：`Contain` 只在 `aspect < CONTAIN_ASPECT_THRESHOLD (0.9)` 时启用，此时
 * `displayWidth = 0.90 × areaWidth < areaWidth`；`aspect ≥ 0.9` 走 `Cover`，方框恒为整宽。
 *
 * @param size - 真实像素尺寸（null 表示尺寸未知，走兜底比例）
 * @param areaWidth - 图片区宽度（vp）
 * @returns 布局结果（高度 / 填充方式 / 比例 / 建议显示宽度）
 */
export function resolvePreviewLayout(size: ImageSize | null, areaWidth: number): PreviewLayout {
  const width: number = areaWidth > 0 ? areaWidth : FALLBACK_PREVIEW_AREA_WIDTH
  let aspect: number = 16 / 9
  if (size !== null && size.width > 0 && size.height > 0) {
    aspect = size.width / size.height
  }
  const ideal: number = PREVIEW_HEIGHT_WIDTH_FACTOR * width / aspect
  const height: number = Math.max(MIN_PREVIEW_HEIGHT, Math.min(MAX_PREVIEW_HEIGHT, ideal))
  const useContain: boolean = aspect < CONTAIN_ASPECT_THRESHOLD
  const layout: PreviewLayout = new PreviewLayout()
  layout.height = height
  layout.aspect = aspect
  layout.useContain = useContain
  layout.displayWidth = useContain ? height * aspect : width
  return layout
}

/**
 * 该比例是否值得标「长图」角标（列表中必然看不全的极端比例）。
 *
 * @param size - 真实像素尺寸（null → 不标）
 * @returns 是否标角标
 */
export function isTallPreview(size: ImageSize | null): boolean {
  if (size === null || size.width <= 0 || size.height <= 0) {
    return false
  }
  const aspect: number = size.width / size.height
  return aspect < TALL_IMAGE_ASPECT || aspect > WIDE_IMAGE_ASPECT
}

/**
 * 预览图区布局结果（{@link resolvePreviewLayout} 的返回值）。
 *
 * 用类而非对象字面量：ArkTS 不允许无类型标注的对象字面量（见 entry/src/AGENTS.md）。
 */
export class PreviewLayout {
  /** 预览区高度（vp）。 */
  height: number = MIN_PREVIEW_HEIGHT
  /**
   * 是否使用 `ImageFit.Contain`（竖图完整显示）。
   * false 时用 `ImageFit.Cover`（横图填满容器，按 10% 余量裁切）。
   */
  useContain: boolean = false
  /** 图片宽高比（尺寸未知时为 16:9 兜底值）。 */
  aspect: number = 16 / 9
  /**
   * 建议的**单张图片显示宽度**（vp）：`Contain` 时为 `height × aspect`（贴合图片实际显示宽度），
   * 否则等于传入的分区宽度。
   *
   * UI 侧必须用它而不是恒 `width('100%')`：`Contain` 下图片按高度等比放缩，容器撑满分区
   * 会让图片两侧各留一条空白；收窄到该值后图片贴左、且**没有多余留白**。
   *
   * 该值**天然不会溢出**：它由传入的分区宽度算出（`0.90 × 分区宽 < 分区宽`），多图横排时
   * 分区宽度本身就是"单张可用宽度"，因此每张仍能等分排下。
   */
  displayWidth: number = 0
}
