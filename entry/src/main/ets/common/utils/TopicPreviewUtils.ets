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
 * 本模块承担两件事，UI 侧只消费结果、不做任何算术：
 *
 *  1. **附件 → 预览图**（`parsePreviewAttachments`）：拼前缀、过滤非图片，并**从文件名尺寸段
 *     解出每一张图的真实像素尺寸**（`PreviewImage.size`）。尺寸与 URL 在解析期一起产出——
 *     图片尚未下载，分辨率、比例就已经确定，卡片高度因此是静态值（§6.2）。
 *  2. **区域 → 布局**（`resolvePreviewArea` / `resolvePreviewRowLayout`）：把"条目内可用宽度"
 *     折算成**预览图区域的最大宽高**（这正是"ListCell 分配给预览图的区域"的显式表达），
 *     再让区域内每一张图各自做**最优适配**（完整显示优先，见 §6.2 / §6.8）。
 *
 * **尺寸段解码（`parsePreviewSize`）是全工程唯一的出口**，服务三处调用方，不得各自复制正则：
 *  1. 列表预览图（`TopicParser` 解析期 → `PreviewImage.size`）；
 *  2. 正文图片（`BBCodeContentView` 的 `imageSizes` 预填与比例兜底）；
 *  3. 视频附件（`BBCodeContentView` / `PostAttachments` 的 `videoAspectRatio`）。
 *
 * 后两处原先依赖运行时回填（`onComplete` / `AVMetadataExtractor`），首帧只能用 16:9 兜底、
 * 尺寸到位后再改高度，因而产生布局跳变；尺寸段是**同步**可得的，改用后跳变消失，
 * 且视频侧的元数据请求从"每个视频必经"降为"无尺寸段老附件的兜底"。
 * 视频尺寸段与图片同规则，编码的是**旋转后的显示尺寸**（实测 6/6：编码 1280×720 + rotate 90°
 * 的文件尺寸段为 720×1280），与 `AVMetadataExtractor` + `applyOrientation` 语义一致。
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

// ============== 预览图模型：URL + 解析期算定的真实像素尺寸 ==============

/**
 * 一张可作预览图的附件：**绝对 URL** + **解析期算定的真实像素尺寸**。
 *
 * 两者必须同行产出（`parsePreviewAttachments` 一次遍历同时给出），否则极易出现
 * "卡片渲染的是 A 图的 URL、尺寸却取了 B 图"的错位——旧实现里 `previewImages`（URL 数组）
 * 与 `previewSize`（首图尺寸）就是从两次独立遍历里分别取出的。
 */
export class PreviewImage {
  /** 可加载的绝对 URL（原图；见设计文档 §5.3）。 */
  url: string = ''
  /**
   * 真实像素尺寸（由文件名尺寸段解出，**与下载无关**）。
   *
   * 宽高为 0 表示尺寸段缺失或不可解（老附件、档位 URL）——布局侧据此走 16:9 兜底比例，
   * 不会因此退回固定高度。
   */
  size: ImageSize = new ImageSize()
}

/**
 * 尺寸段解码的合法边界。
 *
 * NGA 附件文件名形如 `mon_202608/19/7Q68-jpq0ZtT3cS1uo-11i.jpeg`，其中 `S{base36宽}-{base36高}`
 * 是**真实像素尺寸**（实测：596 张真实列表附件里 589 张带该段，解码宽高比与逐张 Range 请求
 * 取回的真实宽高比 **589/589 完全一致**，见设计文档 §6.2.1）。
 *
 * 边界用于挡住两类脏数据：
 * - 恶意的超长 base36（如 `Szzzz-zzzz` = 1679615×1679615）→ 超出 `MAX_PIXELS`；
 * - 比例极端到不可能作为缩略图预览的编码 → 超出 `MIN/MAX_ASPECT`（这会与 §6.2 的
 *   "极端比例（超宽 / 长截图）"说明重合，但那是**已确认的真实比例**，此处拦的是明显荒谬值）。
 */
const MIN_PIXELS: number = 16
const MAX_PIXELS: number = 20000
const MIN_ASPECT: number = 1 / 24
const MAX_ASPECT: number = 24

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
 * **图片与视频共用**（视频见文件头说明）。注意对**服务端缩略档位 URL 会失配**：
 * `xxx.mp4.thumb.jpg` 的尺寸段后面还跟着 `.thumb`，不满足"紧贴扩展名"，故返回 null ——
 * 这是刻意的：档位图的真实尺寸与源图不同，要拿源图尺寸必须传**裸名原图 URL**。
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
 * 把官方 attachs 字段解析为预览图列表（URL 与真实尺寸**一次遍历同时产出**）。
 *
 * 每一张图的尺寸都在这里解定：URL 与尺寸成对进模型后，UI 侧不再有"按索引从另一个数组取尺寸"
 * 的对齐风险，也不需要等图片下载完成才知道分辨率（见设计文档 §6.2.2）。
 *
 * 尺寸在**原始 attachurl** 上解而不是在拼好的绝对 URL 上解：后者虽同为文件名匹配，
 * 但原始值永远没有 query / fragment 干扰，少一层守卫。
 *
 * @param rawAttachs - 原始 attachs 值（实测为对象数组；归一化层可能写入空串，JSON 可能为 null）
 * @param prefix - 响应 attachPrefix
 * @returns 预览图列表（保序、已过滤非图片；无有效项时为空数组）
 */
export function parsePreviewAttachments(rawAttachs: Object | null | undefined,
  prefix: string): PreviewImage[] {
  if (rawAttachs === undefined || rawAttachs === null || !Array.isArray(rawAttachs)) {
    return []
  }
  const images: PreviewImage[] = []
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
    if (url.length === 0) {
      continue
    }
    const image: PreviewImage = new PreviewImage()
    image.url = url
    const size: ImageSize | null = parsePreviewSize(attachurl)
    if (size !== null) {
      image.size = size
    }
    images.push(image)
  }
  return images
}

// ============== 预览图区域与最优适配（§6.2 / §6.8） ==============

/**
 * 预览区高度参数（vp）——实测标定，改值前先读设计文档 §6.2 的参数依据与 §6.2.1 的实测数据。
 *
 * - `MIN_PREVIEW_HEIGHT` 112：**单图**区域的绝对高度下限（超宽全景图的落点）。再矮会让
 *   3.5:1 以上的图退化成"一条线"，而这类图在列表里的信息量（总览、战报长图）本就靠整体轮廓传达。
 *   它是**基准宽度（328vp）下的取值**：区域更窄时按比例放宽（见 `MAX_AREA_ASPECT`）。
 * - `MAX_PREVIEW_HEIGHT` 240：竖图的封顶，也是**整块预览图区域的高度上限**（多图整行同样受它约束）。
 *   取值约束来自"一屏可读条数"：卡片文字区约 180vp，图片区 240vp 时整卡 ≈ 420vp，
 *   在 640~800vp 的列表可视高度下仍能露出近 2 条。240 而非 200 的理由：竖图走完整显示，
 *   其**显示宽度**完全由这个上限决定（宽度 = 高度 × 比例），200 → 240 让 3:4 竖拍的显示宽度
 *   从 150vp 提到 180vp（+20%）。
 *
 * 实测（582 个真实附件、sm 360vp 窗口、图片区 328vp）：固定 120vp 高度平均只能看到
 * 39.7% 的画面，"区域内完整显示"（本模块当前算法）提升到约 90% 以上（§6.2.1）。
 */
const MIN_PREVIEW_HEIGHT: number = 112
const MAX_PREVIEW_HEIGHT: number = 240

/**
 * 图片区宽度未知（首帧尚未测得列表宽度）时的兜底值。
 *
 * 取 328 = sm 360vp 窗口的实测列表宽度 360 − 条目左右内边距 32（见 `TopicListPanel` 的
 * `ITEM_HORIZONTAL_PADDING`；列表自身没有左右 padding）。首帧用它算出的高度与真实值
 * 只差几个 vp，且在列表完成首次布局后立即被真实宽度替换。
 *
 * 它同时是**区域最小高度的标定基准**（见 `MAX_AREA_ASPECT`）。
 */
export const FALLBACK_PREVIEW_AREA_WIDTH: number = 328

/**
 * 多图横排的图间距（vp）。
 *
 * 取 6 而非整行级别的 16：一行内的缩略图是**同一组内容**，间距只需区分边界、不需表达层级，
 * 过大会让每张图显著变窄。图片区总宽 = 内容宽 − 间距 ×（张数 − 1）——**区域求解与 Row 的
 * `space` 必须共用这一个值**，否则单张分区宽与实际排布会错位。
 */
export const PREVIEW_IMAGE_GAP: number = 6

/**
 * 区域允许的**最扁比例**（区域宽 ÷ 区域高），由基准标定值反推：328 / 112 ≈ 2.93。
 *
 * 它是"最小高度"的比例化表达：区域高度低于 `区域宽 ÷ 2.93` 时不再压缩图片
 * （再压就成一条线），改为按区域宽度裁切填满。基准宽度及以上取绝对下限 112vp——
 * 单图（区域宽 ≥ 328vp）因此与改造前**完全一致**；多图分区窄（约 100vp），下限随之降到
 * 约 36vp，这是"多图每张都要看得见"的必要前提（否则 105vp 宽的 16:9 小图会被抬到 112vp 高，
 * 在格子里裁掉近一半，见 §6.8）。
 */
const MAX_AREA_ASPECT: number = FALLBACK_PREVIEW_AREA_WIDTH / MIN_PREVIEW_HEIGHT

/** 尺寸未知（老附件）时的兜底比例，与 `BBCodeContentView.getImageAspectRatio` 同档。 */
const FALLBACK_ASPECT: number = 16 / 9

/**
 * 浮点余量（vp）：判定"按比例算出的宽度是否等于区域宽度"时用。
 *
 * `区域宽 ÷ 比例 × 比例` 在浮点下可能得到 328.00000000000006，直接比较会把本该
 * 完整显示的图误判成需要裁切。半 vp 的余量在视觉上不可辨，足以吸收这类误差。
 */
const LAYOUT_EPSILON: number = 0.5

/**
 * 预览图区域（vp）：条目内分配给**单张**预览图的最大宽高。
 *
 * 这是"ListCell 分配给预览图的区域"的显式表达——此前它只以散落的算式存在
 * （图片区宽度 − 内边距、按张数均分、240 封顶）。区域一经算出，单图与多图走**同一条**
 * 适配算法，区别只在 `maxWidth` 是整宽还是单张分区宽。
 */
export class PreviewArea {
  /** 区域最大宽度（vp）：单图 = 图片区整宽；多图 = 均分并扣掉间距后的单张可用宽。 */
  maxWidth: number = FALLBACK_PREVIEW_AREA_WIDTH
  /** 区域最大高度（vp）：恒为 `MAX_PREVIEW_HEIGHT`，多图整行也不超过它。 */
  maxHeight: number = MAX_PREVIEW_HEIGHT
  /** 区域最小高度（vp）：图片完整显示低于它时不再压缩，改为裁切填满。 */
  minHeight: number = MIN_PREVIEW_HEIGHT
}

/**
 * 解析预览图区域：把"条目内可用宽度"折算成**单张**预览图的最大宽高。
 *
 * 宽度来源是列表自身的实测宽度（`onAreaChange` 采集后下传）而不是断点：`sm` 是整窗、
 * `md` 是"窗口 − 侧边栏 180"、`lg` 双列时还要再乘 40%，任何按断点写死的宽度都会在
 * 其中一种形态下失配（K24）。
 *
 * @param areaWidth - 条目内图片区总宽（vp；≤0 时回落 `FALLBACK_PREVIEW_AREA_WIDTH`）
 * @param count - 区域内横排的图片张数（≤1 时按整宽处理）
 * @returns 单张预览图可用区域
 */
export function resolvePreviewArea(areaWidth: number, count: number): PreviewArea {
  const total: number = areaWidth > 0 ? areaWidth : FALLBACK_PREVIEW_AREA_WIDTH
  const n: number = count > 0 ? count : 1
  /* 多图按张数均分并扣掉图间距；除零与负值都在这里收口，UI 侧不再重复这两条守卫 */
  const maxWidth: number = n <= 1
    ? total
    : Math.max((total - PREVIEW_IMAGE_GAP * (n - 1)) / n, 1)
  const area: PreviewArea = new PreviewArea()
  area.maxWidth = maxWidth
  area.maxHeight = MAX_PREVIEW_HEIGHT
  area.minHeight = Math.min(MIN_PREVIEW_HEIGHT, maxWidth / MAX_AREA_ASPECT)
  return area
}

/**
 * 区域内**单张**图片的显示布局。
 *
 * 用类而非对象字面量：ArkTS 不允许无类型标注的对象字面量（见 entry/src/AGENTS.md）。
 */
export class PreviewTileLayout {
  /** 显示宽度（vp；恒 ≤ `PreviewArea.maxWidth`）。 */
  width: number = 0
  /** 显示高度（vp；恒 ≤ `PreviewArea.maxHeight`）。 */
  height: number = 0
  /**
   * 是否完整显示（`ImageFit.Contain`）。
   *
   * `true`：容器贴合图片实际显示尺寸——**既不裁切、也不留白**（图片自带比例即容器比例）。
   * `false`：图片比区域更"扁"（超宽全景），高度被最小高度抬起后按比例算出的宽度超过区域宽度，
   * 只能按 `ImageFit.Cover` 裁掉两端。
   */
  useContain: boolean = true
  /** 图片宽高比（尺寸未知时为 16:9 兜底值）。 */
  aspect: number = FALLBACK_ASPECT
}

/**
 * 预览图**整行**布局（单图时行内只有一张）。
 */
export class PreviewRowLayout {
  /** 整行高度（vp）：单图 = 该图显示高度；多图 = 各张显示高度的最大值。 */
  height: number = MIN_PREVIEW_HEIGHT
  /** 单张可用区域（多图时已扣间距并按张数均分）。 */
  area: PreviewArea = new PreviewArea()
  /** 每张图的显示布局（保序，与传入的图片数组等长）。 */
  tiles: PreviewTileLayout[] = []
}

/**
 * 单张图片在区域内的**最优适配**：区域内能放下的最大完整显示尺寸。
 *
 * 三步（这就是"单图按最优适配"的全部内容）：
 *
 *  1. **完整显示优先**：`containHeight = min(区域宽 ÷ 比例, 区域高)`——等比缩放到刚好放进区域，
 *     至少有一个方向贴边（宽图贴满宽、竖图贴满高），另一个方向按比例，**不裁切**；
 *  2. **最小高度兜底**：结果低于区域最小高度时抬到下限（超宽全景图，见 `MAX_AREA_ASPECT`）；
 *  3. **宽度收口**：显示宽度 = `min(区域宽, 比例 × 高度)`。第 2 步抬起高度后，按比例算出的宽度
 *     可能超过区域宽度——此时容器只能是"区域宽 × 最小高"，图片改按 `Cover` 裁两端（`useContain=false`）。
 *
 * 与改造前的差别（旧算法：`h = clamp(0.90 × 区域宽 ÷ 比例, 112, 240)` + 比例 <0.9 才 Contain）：
 * 旧算法对**比例 ≥ 0.9 的图一律 Cover**，靠 0.9 系数"少裁一点"，实测 16:9 截掉约 10%、
 * 方图被 240 封顶后裁掉约 19%；新算法下这些图全部完整显示，且显示尺寸更大
 * （16:9 由 166vp 高提到 184vp 高）——"不改变最大宽高限制"的前提因此没有被破坏，
 * 反而在同一区域内用得更满（详见 §6.2.1 的实测对比）。
 *
 * @param size - 真实像素尺寸（宽高为 0 表示未知，走 16:9 兜底）
 * @param area - 单张可用区域
 * @returns 单张显示布局
 */
function resolveTileLayout(size: ImageSize, area: PreviewArea): PreviewTileLayout {
  let aspect: number = FALLBACK_ASPECT
  if (size.width > 0 && size.height > 0) {
    aspect = size.width / size.height
  }
  const containHeight: number = Math.min(area.maxWidth / aspect, area.maxHeight)
  const height: number = Math.max(containHeight, area.minHeight)
  const width: number = Math.min(area.maxWidth, aspect * height)
  const tile: PreviewTileLayout = new PreviewTileLayout()
  tile.aspect = aspect
  tile.height = height
  tile.width = width
  tile.useContain = aspect * height <= area.maxWidth + LAYOUT_EPSILON
  return tile
}

/**
 * 解析预览图整行布局：区域内**每一张图各自**做最优适配，行高取各张显示高度的最大值。
 *
 * 多图不再共用首图的布局（旧实现的缺陷）：一行里"首图是横图、第二张是竖图"时，
 * 第二张也会被套上横图的容器，完整显示与裁切两种语义被强行统一到首图上——
 * 于是要么所有图都被裁、要么所有图都被塞进一个与自身比例无关的盒子。
 * 现在每张图按**自己的**比例在**自己的**分区里适配：
 *
 * - 宽度各自按比例（≤ 分区宽），**每张都完整显示**，因此横向会有"宽窄不一"——那是真实比例的
 *   忠实反映；
 * - 高度各自不同，整行高度取最大值（**不是逐张撑高行高**）：行内其余图在该高度里垂直居中，
 *   纵向节奏仍然是整齐的一行（见 K29 的取舍记录）；
 * - 总宽 = Σ 各张宽度（≤ 张数 × 分区宽）+ 间距 ≤ 图片区总宽，总高 ≤ `maxHeight` —— 区域约束
 *   在数学上不可突破。
 *
 * @param images - 区域内横排的预览图（保序；空数组时给出仅含最小高度的空行）
 * @param areaWidth - 条目内图片区总宽（vp）
 * @returns 整行布局（行高 + 每张显示尺寸）
 */
export function resolvePreviewRowLayout(images: PreviewImage[], areaWidth: number): PreviewRowLayout {
  const area: PreviewArea = resolvePreviewArea(areaWidth, images.length)
  const row: PreviewRowLayout = new PreviewRowLayout()
  row.area = area
  let rowHeight: number = 0
  for (let i = 0; i < images.length; i++) {
    const tile: PreviewTileLayout = resolveTileLayout(images[i].size, area)
    row.tiles.push(tile)
    if (tile.height > rowHeight) {
      rowHeight = tile.height
    }
  }
  /* 无图时不该被调用（UI 侧先判 shouldRenderPreview），兜底给一个不小于区域下限的高度，
     避免调用方拿到 0 高容器 */
  row.height = rowHeight > 0 ? rowHeight : area.minHeight
  return row
}
