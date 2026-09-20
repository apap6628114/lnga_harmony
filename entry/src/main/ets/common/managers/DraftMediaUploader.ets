/**
 * 草稿媒体懒重传：把「本地副本 → 新凭证 → 正文标签替换」这一段抽成**单一实现**，
 * 由 `ReplyManager`（回复/引用/贴条）与 `NewTopicManager`（发新主题）共用。
 *
 * 这一段在两个 manager 里是逐字相同的（都要取鉴权、都要传封面/视频、都要改正文标签），
 * 抄两份的代价不是行数而是**漂移**：任何一次修只落到其中一条链路，另一条就在线上继续旧行为。
 *
 * ## 为什么是"提交前"重传，而不是"打开草稿时"
 * 打开草稿看一眼又关掉很常见，没必要让用户等一次上传（附件上限 10，官方错误码表里
 * 没有任何频次/频率类错误，所以收益是**流量与等待**，不是"避免触发频控"）。
 * 失败发生在"用户正要发送"的语境里，提示也更自然。
 *
 * ## 幂等与失败口径
 * - 已经在本会话拿到凭证的项直接跳过（判据是**该项的媒体地址**已在本会话累积的凭证里；
 *   B5 之前拿"完整标签出现在正文里"当判据，同一 URL 被登记两次时会把没凭证的那项误判为已有）；
 * - 本地副本缺失**且凭证也没了** → **明确失败**，不静默跳过。跳过会让正文的 `[img]`
 *   变成未声明附件，正是本方案要消灭的那类不一致；
 * - 失败原因必须可操作：区分「该重试」（网络/服务端）与「重试无用」（副本没了，得重新插图；
 *   或服务端返回的是"条件不满足"类错误码），并带上文件名——用户在正文里可能有好几张图，
 *   只说"草稿图片失败"等于没说。
 *
 * ## 正文替换为什么返回"替换对"而不是整串正文（A4）
 * 早先的形态是 `prepareDraftMedia(...) → prepared.content`，调用方拿到后
 * `this.replyText = prepared.content` **整串覆盖**。重传一张大图（动态照片视频可达数十 MB）
 * 期间用户完全可能继续打字、继续插图，覆盖会把这段输入静默丢掉；重传期间新插入的图片标签
 * 也被回退，而它的凭证已经进了 `pendingAttachments`（随后被正文引用过滤丢弃）= 白传一张图。
 *
 * 现在的契约是：**只回报"哪个 URL 片段变成了哪个 URL 片段"**，由调用方把替换对逐条应用到
 * **当前的**正文状态上（{@link applyContentReplacements}），只改动标签本身，其余原样保留。
 * 标签已经不在当前正文里（用户删/改了它）→ 该条替换对跳过，不报错、不回滚。
 *
 * ## 两半各自的判定（B7）
 * 动态照片在服务端是两个普通附件，正文里是"封面标签 + `[flash=video]` 标记"两段。
 * 早先用**一个** `replaced` 布尔同时代表两半：用户只删掉视频标记时，封面已成功的替换
 * 被判成失败，`item.tag` 永不更新，于是每次重试都重复上传一次视频（几十 MB），
 * warn 文案还说"标签被用户手改"（与事实相反）。现在两半各自判定、各自记录。
 */

import { PostAuthResult } from '../../model/ThreadResult'
import { UploadAttachmentResult } from '../../model/NgaApiResults'
import { DraftMedia } from './DraftStore'
import { readDraftMediaFile, DraftMediaFile } from '../media/DraftMediaStore'
import { buildMovingPhotoTag } from '../../service/api/NgaUploader'
import { Logger, DOMAIN_MANAGER } from '../utils/Logger'

const logger = new Logger(DOMAIN_MANAGER, 'DraftMediaUploader')

/** 动态照片视频半边在正文里的标记前缀（与 `buildMovingPhotoTag` 逐字对齐）。 */
const VIDEO_TAG_PREFIX: string = '[flash=video]./'

/** 动态照片视频半边在正文里的标记后缀。 */
const VIDEO_TAG_SUFFIX: string = '[/flash]'

/**
 * 一条正文替换：把 `oldText` 换成 `newText`。
 *
 * 语义是「旧 URL 片段 → 新 URL 片段」，不是"整个标签串"——官方客户端
 * （`PostFragment.handleUploadComplete`）就是按 `indexOf(去掉前缀的 url)` 定位的，
 * 标签的前后缀格式（`.medium.jpg`、`[flash=video]`）不参与匹配。
 * 好处：用户手改过标签的外围（例如把 `[img]` 换成 `[img=1,1]`）时 URL 仍在，替换照样命中。
 */
export class ContentReplacement {
  /** 旧文本（重传前的 URL 片段）。 */
  oldText: string = ''

  /** 新文本（重传后的 URL 片段）。 */
  newText: string = ''
}

/**
 * 一次"提交前媒体准备"的结果。
 *
 * 调用方必须把这些替换对应用到**当前**的编辑器正文上再提交，否则 UI 与请求体不一致
 * （正文里是旧地址、附件参数却是新地址的凭证）。
 */
export class PreparedContent {
  /** 需要应用到正文的替换对（按处理顺序；未发生重传时为空数组）。 */
  replacements: ContentReplacement[] = []

  /** 是否发生了重传（正文需要改写）。 */
  changed: boolean = false

  /** 失败原因；空串表示成功或无需处理。 */
  error: string = ''

  /** 本次重传的媒体条数（诊断用）。 */
  reuploaded: number = 0
}

/**
 * 懒重传需要宿主（manager）提供的上下文与上传能力。
 *
 * 用接口注入而不是把两个 manager 的公共父类抽出来：两个 manager 的其余职责差别很大
 * （版块分类、会话目标、草稿键……），共同点只有这一小段；接口把耦合面压到最小。
 *
 * 两个宿主都必须显式 `implements DraftUploadHost`（本工程不支持结构化类型，
 * 见 `entry/src/AGENTS.md`），不要靠"形状相同"把 `this` 传进来。
 *
 * 注意**不要**在这里声明与宿主类私有字段同名的成员（例如 `pendingAttachments`）：
 * ArkTS 会按"重复标识符"报错，而不是把它当作接口实现。
 */
export interface DraftUploadHost {
  /** 本会话已累积的凭证地址（按累积顺序；用于判断某项是否已有凭证）。 */
  pendingUrls: string[]

  /**
   * 取得（或返回缓存的）post/check 鉴权结果。
   *
   * @returns 鉴权结果；失败时 `error` 非空
   */
  getOrFetchAuth(): Promise<PostAuthResult>

  /**
   * 追加一条本次重传拿到的凭证。
   *
   * 由宿主实现（它持有 `PendingAttachment[]`），上传器因此不必触碰宿主的内部结构。
   *
   * @param cover - 本次上传结果
   * @returns 是否真的记下了（`attachments` 为空时**不会**记下，调用方必须据此判失败——
   *          B6 之前这条静默 return 会让正文有 url、请求无凭证）
   */
  appendPending(cover: UploadAttachmentResult): boolean

  /**
   * 「马上要用本地副本重传了」的通知。
   *
   * 宿主据此给用户一个可见反馈（本工程两个编辑器都是 Toast）：重传要等一次真实上传，
   * 动态照片的视频半边可达数十 MB，没有反馈用户会以为按钮没响应。
   */
  onReuploadStart(): void

  /**
   * 上传一份图片数据。
   *
   * @param data - 二进制数据
   * @param fileName - 原始文件名
   * @param auth - post/check 返回的附件鉴权码
   * @param attachUrl - post/check 返回的上传地址
   * @returns 上传结果
   */
  uploadImageData(data: ArrayBuffer, fileName: string, auth: string,
    attachUrl: string): Promise<UploadAttachmentResult>

  /**
   * 上传动态照片的视频半边。
   *
   * @param data - 视频二进制数据
   * @param fileName - 视频文件名
   * @param auth - post/check 返回的附件鉴权码
   * @param attachUrl - post/check 返回的上传地址
   * @returns 上传结果
   */
  uploadVideoData(data: ArrayBuffer, fileName: string, auth: string,
    attachUrl: string): Promise<UploadAttachmentResult>
}

/**
 * 一次单项重传的结果。
 *
 * 把「失败原因」与「替换对」打包返回，取代早先"往累积结果里就地改 `prepared.content`、
 * 再用返回的字符串表示失败"的双通道写法：那种写法下调用方必须自己保证"部分成功也要把
 * 替换带回去"，而 A3 的缺陷正是漏在了这里——`reuploadOne` 先改了 `item.url/tag`，
 * 失败分支却不回写正文；用户随手再关一次面板，磁盘草稿就记下"新 URL + 正文旧标签"，
 * 重启后 `isMediaReferenced` 三项全不匹配 → 静默跳过 → 正文 `[img]` 变成未声明附件。
 */
class ReuploadOutcome {
  /** 失败原因；空串表示成功或无需处理。 */
  error: string = ''

  /** 本条产生的替换对（失败时也可能非空：已成功的那半边必须回写）。 */
  replacements: ContentReplacement[] = []

  /** 本条是否真的重传了（至少成功上传了一半）。 */
  reuploaded: boolean = false
}

/**
 * 判断某个媒体地址是否已经拿到**本会话**签发的凭证。
 *
 * 判据是 **url 相等**，不是"完整标签出现在正文里"：`PendingAttachment` 只存服务端返回的
 * 地址，而同一个地址可能被用户复制成两个标签（同一张图插两次）——那时第二份标签的项其实
 * 没有独立凭证，按标签判会漏掉一次必要上传。
 *
 * @param urls - 已累积的凭证地址
 * @param url - 该媒体的地址
 * @returns 是否已有可用凭证
 */
function isUrlPending(urls: string[], url: string): boolean {
  if (url.length === 0) {
    return false
  }
  for (let i: number = 0; i < urls.length; i++) {
    if (urls[i].length > 0 && urls[i] === url) {
      return true
    }
  }
  return false
}

/**
 * 从标签里取出 URL 片段（标签格式：`[img]./<url>.medium.jpg[/img]`、
 * `[flash=video]./<url>[/flash]`、动态照片三元组里的封面/视频段）。
 *
 * 解析不出来时返回空串：调用方据此放弃这一半的替换（只在日志里说明），
 * 而不是拿整串标签去 `indexOf`（B4 之前的做法，用户手改过前后缀就落空）。
 *
 * @param tag - 完整标签
 * @returns `.` 之后的地址片段；不含 `./` 时为空串
 */
export function extractUrlFragment(tag: string): string {
  const marker: string = './'
  const start: number = tag.indexOf(marker)
  if (start < 0) {
    return ''
  }
  let end: number = tag.indexOf('[/', start)
  if (end < 0) {
    end = tag.length
  }
  return tag.substring(start + marker.length, end)
}

/**
 * 取某个媒体用于定位正文的地址片段。
 *
 * 优先用已记录的 `url` / `videoUrl`（重传后它们仍指向正文里的实际内容），
 * 没有记录时才回退到从标签里解析。
 *
 * @param url - 已记录的地址
 * @param tag - 标签
 * @returns 地址片段；都取不到时为空串
 */
function targetFragment(url: string, tag: string): string {
  return url.length > 0 ? url : extractUrlFragment(tag)
}

/**
 * 判断草稿媒体是否仍被正文引用。
 *
 * 判据是**地址片段**是否还在正文里（与替换的定位口径一致）：静态图看封面地址，
 * 动态照片看封面地址与视频地址任一——用户可能只删掉三元组里的半边，
 * 只要还有半边在正文里，这条媒体的凭证就仍然是需要的。
 *
 * 不用"完整标签"判引用：用户手改标签前后缀（`[img=1,1]`、去掉 `.medium.jpg`）时，
 * 整串匹配会落空而地址仍在正文里，于是这次必要的重传被误判成"用户已删除"。
 *
 * @param content - 正文
 * @param item - 草稿媒体
 * @returns 是否仍被引用
 */
function isMediaReferenced(content: string, item: DraftMedia): boolean {
  const coverFragment: string = targetFragment(item.url, item.tag)
  if (coverFragment.length > 0 && content.indexOf(coverFragment) >= 0) {
    return true
  }
  const videoFragment: string = targetFragment(item.videoUrl, item.videoTag)
  return videoFragment.length > 0 && content.indexOf(videoFragment) >= 0
}

/**
 * 把一段文本里的**所有** `needle` 替换成 `replacement`。
 *
 * 两条硬要求：
 * 1. **全部替换**，不只第一处（B4）：同一张图的 URL 可能在正文里出现多次，
 *    只换第一处会让第二处仍指向旧凭证；
 * 2. 手动扫描而不是 `String.replace`：后者在**替换串**里对 `$&`、`$'`、`` $` `` 有特殊含义
 *    （地址里出现 `$` 会把匹配片段复制进结果）。`split/join` 没有这个问题，
 *    但它会创建整个数组；手动扫描只分配结果串，且不会把替换结果自己当成下一轮的匹配目标。
 *
 * @param text - 待处理文本
 * @param needle - 要被替换掉的片段（空串时原样返回）
 * @param replacement - 替换成的片段
 * @returns 处理后的文本
 */
export function replaceAllText(text: string, needle: string, replacement: string): string {
  if (needle.length === 0 || text.length === 0) {
    return text
  }
  let out: string = ''
  let cursor: number = 0
  const lastStart: number = text.length - needle.length
  while (cursor <= lastStart) {
    let matched: boolean = true
    for (let i: number = 0; i < needle.length; i++) {
      if (text.charAt(cursor + i) !== needle.charAt(i)) {
        matched = false
        break
      }
    }
    if (matched) {
      out += replacement
      cursor += needle.length
    } else {
      out += text.charAt(cursor)
      cursor++
    }
  }
  if (cursor < text.length) {
    out += text.substring(cursor)
  }
  return out
}

/**
 * 把重传产生的替换对**逐条应用到当前正文**上（A4）。
 *
 * 调用方在拿到结果后调它，而不是整串覆盖：`text` 是**当前**（用户可能又打了字、
 * 又插了图）的正文，只有标签里的 URL 片段被改动，其余输入原样保留。
 * 替换对里的旧片段已经不在正文里（用户删掉/改掉了那段标签）→ 跳过该条。
 *
 * 返回新字符串而不是就地改，是为了让调用方（`@State`）显式赋一次值：
 * ArkUI 的刷新靠赋值触发，改内部状态不会重绘。
 *
 * @param text - 当前正文
 * @param replacements - 替换对
 * @returns 应用后的正文；`replacements` 为空时原样返回 `text`
 */
export function applyContentReplacements(text: string, replacements: ContentReplacement[]): string {
  let out: string = text
  if (replacements.length === 0) {
    return out
  }
  for (let i: number = 0; i < replacements.length; i++) {
    const pair: ContentReplacement = replacements[i]
    if (pair.oldText.length === 0 || out.indexOf(pair.oldText) < 0) {
      // 标签已被用户删掉/改成别的形态：这条替换对无事可做
      logger.info('replacement target already gone, skip old=%{public}s', pair.oldText)
      continue
    }
    out = replaceAllText(out, pair.oldText, pair.newText)
  }
  return out
}

/**
 * 提交前的媒体准备：对**正文仍然引用、且本会话已无凭证**的媒体，用本地副本重新上传，
 * 并把"哪段地址变成哪段地址"作为替换对返回给调用方。
 *
 * 失败**不回滚已完成的项**：前面几条已经拿到新凭证、正文里也已经换成新地址，
 * 调用方必须把已产生的替换对应用上去（否则磁盘草稿会记下"新 URL + 正文旧标签"的劈叉态，
 * 见 {@link ReuploadOutcome} 的注释）。
 *
 * @param host - 宿主提供的鉴权与上传能力
 * @param media - 草稿媒体清单
 * @param content - 待提交的正文（只用于判定引用关系，不再被整串改写）
 * @returns 准备结果；失败时以 `result.error` 说明，同时 `replacements` 里带着已完成的替换
 */
export async function prepareDraftMedia(host: DraftUploadHost, media: DraftMedia[],
  content: string): Promise<PreparedContent> {
  const prepared: PreparedContent = new PreparedContent()
  if (content.length === 0 || media.length === 0) {
    return prepared
  }
  let notified: boolean = false
  for (let i: number = 0; i < media.length; i++) {
    const item: DraftMedia = media[i]
    if (!isMediaReferenced(content, item)) {
      // 用户已把这张图的标签从正文删掉：不该再为它花一次上传
      continue
    }
    if (!notified) {
      // 提示只在真正要重传时出现一次：用户点「发送」后可能要多等几秒（动态照片视频可达
      // 数十 MB），没有反馈会让他以为按钮没响应而反复点击
      host.onReuploadStart()
      notified = true
    }
    const outcome: ReuploadOutcome = await reuploadOne(host, item)
    for (let k: number = 0; k < outcome.replacements.length; k++) {
      prepared.replacements.push(outcome.replacements[k])
    }
    if (outcome.reuploaded) {
      prepared.reuploaded++
    }
    if (outcome.error.length > 0) {
      prepared.error = outcome.error
      prepared.changed = prepared.replacements.length > 0
      return prepared
    }
  }
  prepared.changed = prepared.replacements.length > 0
  if (prepared.changed) {
    logger.info('media re-uploaded count=%{public}d replacements=%{public}d',
      prepared.reuploaded, prepared.replacements.length)
  }
  return prepared
}

/**
 * 重传一条草稿媒体（必要时连视频半边），并产出正文替换对。
 *
 * ## 先验后改（A3）
 * 早先的实现在第一步 `appendPending` 之后就**立刻**改写 `item.url` / `item.tag`，之后才可能
 * 失败；失败时 `item` 已经变了。现在把 `item` 的改写推迟到**两半都处理完**之后，
 * 且只有真正成功的半边才写进 `item`——这样"用户随手再关一次面板"落盘的就是
 * 「磁盘草稿记下的 URL」与「正文实际标签」一致的状态。
 *
 * 动态照片的 `item.tag` 只在**两半都成功**时重建：只成功半边时 `item.tag` 保持原值，
 * 它仍然是正文里那段完整标记的准确描述（`videoUrl` 也不会被改成新值），
 * 于是下一次重试不会出现"草稿说视频已换、正文还是旧的"。
 *
 * ## 失败也要回写（A3）
 * 已经成功的那一半（拿到了新凭证、正文里的地址已失效）必须把替换对带回给调用方：
 * `item` 与正文都更新到已完成的半边，失败的那一半保持原样并给出原因。
 *
 * @param host - 宿主
 * @param item - 草稿媒体（**只在成功后**更新 url / tag / videoUrl / videoTag）
 * @returns 单项结果（失败原因 + 替换对 + 是否重传过）
 */
async function reuploadOne(host: DraftUploadHost, item: DraftMedia): Promise<ReuploadOutcome> {
  const outcome: ReuploadOutcome = new ReuploadOutcome()
  const isMovingPhoto: boolean = item.videoLocalPath.length > 0
  const urls: string[] = host.pendingUrls
  const coverFragment: string = targetFragment(item.url, item.tag)
  const videoFragment: string = targetFragment(item.videoUrl, item.videoTag)
  const needCover: boolean = coverFragment.length > 0 && !isUrlPending(urls, coverFragment)
  // 视频标记被用户整段删掉时（videoFragment 为空）不需要传：凭证按"正文未引用"丢弃，
  // 传了也没有正文位置可指
  const needVideo: boolean = isMovingPhoto && videoFragment.length > 0 &&
    !isUrlPending(urls, videoFragment)
  if (!needCover && !needVideo) {
    return outcome
  }

  const authResult: PostAuthResult = await host.getOrFetchAuth()
  if (!authResult.ok) {
    outcome.error = failMessage(item, '鉴权', authResult.error || '获取上传权限失败')
    return outcome
  }

  let newCoverFragment: string = ''
  let coverDone: boolean = false

  if (needCover) {
    const coverFile: DraftMediaFile = readDraftMediaFile(item.localPath)
    if (!coverFile.usable) {
      outcome.error = failMessage(item, '封面', '本地副本已不存在')
      return outcome
    }
    const coverResult: UploadAttachmentResult = await host.uploadImageData(
      coverFile.data, item.fileName, authResult.auth, authResult.attachUrl
    )
    if (!coverResult.ok) {
      outcome.error = failMessage(item, '封面', coverResult.error || '服务端未说明原因')
      return outcome
    }
    if (coverResult.url.length === 0) {
      outcome.error = failMessage(item, '封面', '服务端未返回图片地址')
      return outcome
    }
    if (!host.appendPending(coverResult)) {
      // B6：`attachments` 为空时宿主记不下这条凭证。若继续按成功处理，正文会拿到一个新地址，
      // 而提交请求里没有对应附件参数 = 正文有 url、请求无凭证（图片在帖子里丢失）
      outcome.error = failMessage(item, '封面', '服务端未签发附件参数（attachments 为空）')
      return outcome
    }
    newCoverFragment = coverResult.url
    coverDone = true
  }

  if (needVideo) {
    const videoFile: DraftMediaFile = readDraftMediaFile(item.videoLocalPath)
    if (!videoFile.usable) {
      outcome.error = failMessage(item, '视频', '本地副本已不存在')
      return carryCoverOnly(outcome, item, coverDone, coverFragment, newCoverFragment)
    }
    const videoResult: UploadAttachmentResult = await host.uploadVideoData(
      videoFile.data, item.videoFileName, authResult.auth, authResult.attachUrl
    )
    if (!videoResult.ok) {
      outcome.error = failMessage(item, '视频', videoResult.error || '服务端未说明原因')
      return carryCoverOnly(outcome, item, coverDone, coverFragment, newCoverFragment)
    }
    if (videoResult.url.length === 0) {
      outcome.error = failMessage(item, '视频', '服务端未返回视频地址')
      return carryCoverOnly(outcome, item, coverDone, coverFragment, newCoverFragment)
    }
    if (!host.appendPending(videoResult)) {
      outcome.error = failMessage(item, '视频', '服务端未签发附件参数（attachments 为空）')
      return carryCoverOnly(outcome, item, coverDone, coverFragment, newCoverFragment)
    }
    // 视频成功 + 封面（若有）成功：到这里才改写 item 的两半与标签
    item.videoUrl = videoResult.url
    item.videoTag = VIDEO_TAG_PREFIX + videoResult.url + VIDEO_TAG_SUFFIX
    appendReplacement(outcome, videoFragment, videoResult.url)
    if (coverDone) {
      item.url = newCoverFragment
      item.tag = buildMovingPhotoTag(newCoverFragment, videoResult.url)
      appendReplacement(outcome, coverFragment, newCoverFragment)
    }
    outcome.reuploaded = true
    logger.info('reupload ok file=%{public}s kind=moving cover=%{public}s video=true',
      item.fileName, String(coverDone))
    return outcome
  }

  // 静态图（或动态照片只需要封面半边）
  if (coverDone) {
    item.url = newCoverFragment
    if (isMovingPhoto) {
      // 只有封面需要重传，但正文里是三元组：用**旧**视频地址重建整段标记，
      // 保证正文找到的 `item.tag` 与磁盘记录一致
      item.tag = buildMovingPhotoTag(newCoverFragment, item.videoUrl)
    } else {
      item.tag = '[img]./' + newCoverFragment + '.medium.jpg[/img]'
    }
    appendReplacement(outcome, coverFragment, newCoverFragment)
  }
  outcome.reuploaded = coverDone
  if (coverDone) {
    logger.info('reupload ok file=%{public}s kind=%{public}s cover=true video=false',
      item.fileName, isMovingPhoto ? 'moving' : 'still')
  }
  return outcome
}

/**
 * 视频半边失败时把**已成功封面**的结果带回（A3 的"部分失败也要回写"）。
 *
 * 只改 `item.url`，**不重建 `item.tag`**：动态照片的 `tag` 是整段三元组，
 * 视频地址还是旧的，重建出来的标记与正文不符。保持原 `tag` 后，
 * 下一次重试仍能从 `videoUrl` 认出"视频这半还没换"，不会重复上传封面。
 *
 * @param outcome - 累积结果
 * @param item - 草稿媒体
 * @param coverDone - 封面是否已成功
 * @param oldFragment - 封面旧地址片段
 * @param newFragment - 封面新地址片段
 * @returns 原样返回 `outcome`（便于在失败分支里 `return`）
 */
function carryCoverOnly(outcome: ReuploadOutcome, item: DraftMedia, coverDone: boolean,
  oldFragment: string, newFragment: string): ReuploadOutcome {
  if (!coverDone) {
    return outcome
  }
  item.url = newFragment
  appendReplacement(outcome, oldFragment, newFragment)
  outcome.reuploaded = true
  return outcome
}

/**
 * 追加一条替换对（旧片段为空、或新旧相同时不追加）。
 *
 * @param outcome - 累积结果
 * @param oldFragment - 旧地址片段
 * @param newFragment - 新地址片段
 */
function appendReplacement(outcome: ReuploadOutcome, oldFragment: string, newFragment: string): void {
  if (oldFragment.length === 0 || oldFragment === newFragment) {
    return
  }
  const pair: ContentReplacement = new ContentReplacement()
  pair.oldText = oldFragment
  pair.newText = newFragment
  outcome.replacements.push(pair)
}

/**
 * 拼一条可操作的失败文案，并记 warn 日志（B8）。
 *
 * 日志要能回答"哪个媒体、哪一半、什么原因、要不要重传"：带上 `key` 语义的
 * 文件名与 `retryable` 判定，真机日志里就能直接判断。
 *
 * 文案要能回答"为什么失败、要不要重试、我该做什么"：
 * - 可重试（网络/服务端临时问题）→ 「请重试」；
 * - 不可重试 → 明说**哪一张**需要重新插入，或者说明这是账号/版块条件问题（重试无用）。
 *   用户正文里可能有好几张图，只说"草稿图片处理失败"等于没说。
 *
 * @param item - 出问题的草稿媒体
 * @param half - 哪一半（封面 / 视频 / 鉴权）
 * @param reason - 具体原因
 * @returns 面向用户的文案
 */
function failMessage(item: DraftMedia, half: string, reason: string): string {
  const kind: string = item.videoLocalPath.length > 0 ? '动态照片' : '图片'
  const copyMissing: boolean = reason.indexOf('本地副本已不存在') >= 0
  const conditionBlocked: boolean = !copyMissing && !isRetryableReason(reason)
  logger.warn('reupload failed half=%{public}s kind=%{public}s file=%{public}s retryable=%{public}s reason=%{public}s',
    half, kind, item.fileName, String(!copyMissing && !conditionBlocked), reason)
  if (copyMissing) {
    const what: string = half === '视频' ? '动态照片' : '图片'
    return '草稿中的' + what + '需要重新插入：「' + item.fileName + '」的本地副本已不在本机，请重新选择'
  }
  if (conditionBlocked) {
    return '草稿中的' + kind + '重新上传被服务端拒绝（' + half + '）：' + reason + '（重试无法解决）'
  }
  return '草稿中的' + kind + '重新上传失败（' + half + '）：' + reason + '，请重试'
}

/**
 * 判断一条上传失败原因是否属于"重试有用"。
 *
 * 官方上传错误码里有几项是**条件不满足**，与网络抖动无关，重试一万次也一样：
 * 1 附件上传已关闭 / 2 该版面不允许上传附件 / 5 没有可上传的文件 / 6 文件类型错误 /
 * 7 附件名过长 / 8 附件说明过长 / 9 附件过大 / 13 发帖数超过 5 方可上传附件
 * （见 `DRAFT_MEDIA_PLAN.md` §5 的订正表与 `ErrorParser.formatUploadErrorCode`）。
 * 这些必须翻译成"重试无用"，否则用户会一直点发送。
 *
 * 标记串与 `ErrorParser.formatUploadErrorCode` 的文案**逐字对齐**：
 * 这里匹配的是已经翻译过的人话，文案一改这里就会失效，因此两边必须一起改。
 *
 * @param reason - 失败原因文本
 * @returns 重试是否有用
 */
function isRetryableReason(reason: string): boolean {
  const markers: string[] = ['发帖数超过 5', '附件上传已关闭', '不允许上传附件',
    '没有可上传的文件', '文件类型错误', '附件名过长', '附件说明过长', '附件过大']
  for (let i: number = 0; i < markers.length; i++) {
    if (reason.indexOf(markers[i]) >= 0) {
      return false
    }
  }
  return true
}

/**
 * 从宿主已累积的凭证地址里取倒数第 n 个（动态照片登记时用来回填封面/视频地址）。
 *
 * 不用标签反解 URL：标签格式一旦调整，反解会静默取到空值。
 *
 * @param urls - 凭证地址数组（按累积顺序）
 * @param fromEnd - 距末尾的偏移（1 = 最后一项，2 = 倒数第二项）
 * @returns 地址；越界时为空串
 */
export function pendingUrlFromEnd(urls: string[], fromEnd: number): string {
  const index: number = urls.length - fromEnd
  if (index < 0 || index >= urls.length) {
    return ''
  }
  return urls[index]
}
