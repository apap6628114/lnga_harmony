import type { PostInfo } from '../../model/PostInfo'
import { PostAuthResult, PostReplyResult } from '../../model/ThreadResult'
import { getPostAuth, postReply, postComment, uploadAttachment, uploadVideoAttachment } from '../../service/api/ThreadWriteApi'
import {
  MOVING_PHOTO_COVER_NAME,
  MOVING_PHOTO_VIDEO_NAME,
  buildMovingPhotoTag
} from '../../service/api/NgaUploader'
import type { UploadAttachmentResult } from '../../model/NgaApiResults'
import { appStore } from '../../store/AppStore'
import { Logger, DOMAIN_MANAGER } from '../utils/Logger'
import { decodeHtmlEntities } from '../utils/CodecUtils'
import {
  PendingAttachment,
  AttachmentParams,
  appendPendingAttachment,
  restoreServerAttachments,
  buildAttachmentParams
} from './PostAttachments'
import { draftStore, draftUidPart, DraftMedia, EditorDraft } from './DraftStore'
import { draftMediaStore } from '../media/DraftMediaStore'
import {
  DraftUploadHost,
  PreparedContent,
  prepareDraftMedia,
  applyContentReplacements,
  pendingUrlFromEnd
} from './DraftMediaUploader'

const logger = new Logger(DOMAIN_MANAGER, 'ReplyManager')


export enum ReplyType {
  THREAD = 'reply',
  FLOOR = 'quote',
  COMMENT = 'comment',
  EDIT = 'modify'
}

@Observed
export class ReplyContext {
  type: ReplyType = ReplyType.THREAD
  tid: number = 0
  fid: number = 0
  page: number = 0
  targetPost: PostInfo | null = null
  quotePrefix: string = ''
}

@Observed
export class ReplyManagerClass implements DraftUploadHost {
  private ctx: ReplyContext = new ReplyContext()
  private cachedAuth: PostAuthResult | null = null
  /** cachedAuth 对应的 post/check action（reply/quote/tietiao/modify），action 变化时缓存失效。 */
  private cachedAuthAction: string = ''
  /**
   * 待提交的附件（按上传顺序累积）。
   *
   * 挂在单例上、跨编辑器会话存活，因此会话边界由 `beginSession` 划（见其注释）；
   * 提交前还会按正文引用再过滤一次（见 `buildAttachmentParams`）。
   */
  private pendingAttachments: PendingAttachment[] = []
  /** 当前编辑器会话目标（`action|uid|fid|tid|pid`；仅用于诊断日志）。 */
  private sessionTarget: string = ''

  get type(): ReplyType {
    return this.ctx.type
  }

  get tid(): number {
    return this.ctx.tid
  }

  get fid(): number {
    return this.ctx.fid
  }

  get page(): number {
    return this.ctx.page
  }

  get targetPost(): PostInfo | null {
    return this.ctx.targetPost
  }

  get quotePrefix(): string {
    return this.ctx.quotePrefix
  }

  get isReplyToFloor(): boolean {
    return this.ctx.type === ReplyType.FLOOR || this.ctx.type === ReplyType.COMMENT
  }

  get targetLou(): number {
    if (this.ctx.targetPost) {
      return this.ctx.targetPost.lou
    }
    return 0
  }

  get dialogTitle(): string {
    if (this.ctx.type === ReplyType.EDIT) {
      return '编辑帖子'
    }
    if (this.ctx.type === ReplyType.COMMENT) {
      return '贴条评论'
    }
    if (this.isReplyToFloor && this.ctx.targetPost) {
      return `回复 #${this.ctx.targetPost.lou}`
    }
    return '写回复'
  }

  get placeholder(): string {
    if (this.ctx.type === ReplyType.EDIT) {
      return '修改帖子内容...'
    }
    if (this.ctx.type === ReplyType.COMMENT) {
      return '输入贴条内容(6~650字节)...'
    }
    if (this.isReplyToFloor && this.ctx.targetPost) {
      return `回复 #${this.ctx.targetPost.lou}...`
    }
    return '写回复...'
  }

  get shouldQuote(): boolean {
    return this.ctx.type === ReplyType.FLOOR
  }

  get isEditMode(): boolean {
    return this.ctx.type === ReplyType.EDIT
  }

  get canToggleComment(): boolean {
    return this.ctx.targetPost !== null && this.ctx.type !== ReplyType.EDIT
  }

  toggleMode(): void {
    if (this.ctx.type === ReplyType.FLOOR) {
      this.ctx.type = ReplyType.COMMENT
      this.ctx.quotePrefix = ''
    } else if (this.ctx.type === ReplyType.COMMENT) {
      this.ctx.type = ReplyType.FLOOR
      if (this.ctx.targetPost && this.ctx.tid) {
        this.ctx.quotePrefix = this.buildQuotePrefix(this.ctx.targetPost, this.ctx.tid, this.ctx.page)
      }
    }
  }

  // 构建引用预览块（仅本地预览/草稿用，不随提交发送）— 对应 Java ArticleListAdapter.getReplyIntent()
  // 清洗 post.content 中的已有引用，避免多层嵌套
  // [quote][pid={pid},{tid},{page}]Reply[/pid] [b]Post by [uid={authorId}]{author}[/uid] ({postDate}):[/b]\n{cleanedContent}[/quote]\n
  // 官方协议（nga-hack 卡片 8 §3.3）：客户端提交 quote 不构造 [quote] 块，content 仅为用户输入，
  // 服务端按 pid 自动生成引用块（真实帖子格式：[quote][pid=..,..,1]Reply[/pid] <b>Post by ...</b>...[/quote]）
  buildQuotePrefix(post: PostInfo, tid: number, page: number): string {
    const uid: string = post.authorid < 0 ? '-1' : String(post.authorid)
    let cleanContent: string = post.content
    cleanContent = cleanContent.replace(/\[quote\]([\s\S])*\[\/quote\]/g, '')
    cleanContent = cleanContent.replace(/\[b\]Reply to \[pid=\d+,\d+,\d+\]Reply\[\/pid\] Post by .+?\[\/b\]/g, '')
    cleanContent = cleanContent.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ')
    cleanContent = cleanContent.replace(/&#(\d+);/g, (_s: string, c: string): string => {
      const code: number = parseInt(c, 10)
      if (code <= 0xFFFF) return String.fromCharCode(code)
      const hi: number = 0xD800 + ((code - 0x10000) >> 10)
      const lo: number = 0xDC00 + ((code - 0x10000) & 0x3FF)
      return String.fromCharCode(hi) + String.fromCharCode(lo)
    })
    cleanContent = cleanContent.replace(/<br\s*\/?>/gi, '\n').trim()
    if (cleanContent.length > 100) {
      cleanContent = cleanContent.substring(0, 100) + '...'
    }
    const result: string =
      '[quote][pid=' + String(post.pid) + ',' + String(tid) + ',' + String(page) +
      ']Reply[/pid] [b]Post by [uid=' + uid + ']' +
      post.author + '[/uid] (' + post.postdate + '):[/b]\n' +
      cleanContent + '[/quote]\n'
    return result
  }

  /**
   * 当前编辑器会话的媒体清单（草稿媒体：本地副本 + 正文标签 + 上传凭证地址）。
   *
   * 与 `pendingAttachments` 的分工：后者是**服务端凭证**（提交参数），寿命由会话边界决定；
   * 本清单是**本地记录**（副本路径 + 标签），跨会话存活（随草稿落盘），供懒重传重建凭证。
   */
  private sessionMedia: DraftMedia[] = []

  /**
   * 开启一次新的编辑器会话。
   *
   * `auth` / `attach_url` 与 `attachments` / `attachments_check` 都是**服务端按某一次
   * post/check 会话签发**的临时凭证，只在签发它的那次提交里有效，因此它们只能与
   * 「同一个编辑器目标」（action + fid + tid + pid）绑定复用：
   *   - 跨帖 / 跨目标复用：拿 A 帖的 auth 上传、把 A 帖的附件码提交给 B 帖，
   *     服务端校验不通过 → 「附件确认错误，请回报管理员」；
   *   - 已提交过的参数再次提交（同帖连续两次回复）：同样被拒。
   *
   * 官方客户端把这两项状态挂在发帖页上（`PostFragment.mAttachArray` /
   * `mAttachCheckArray`，随页面生灭），本类是**进程级单例**，必须自己划会话边界——否则
   * 一次带图回复之后，后续每一次「没插图」的回复都会带着旧附件参数提交。
   *
   * **每次进入编辑器都无条件作废**（不再保留"同一目标内复用"的例外）：这个例外当初的
   * 唯一作用是让"上传图片 → 放弃 → 重开同一回复框"时草稿里的图片仍能绑定，而该能力现已
   * 由**草稿媒体副本 + 提交前懒重传**（{@link ReplyManagerClass.ensureDraftMedia}）接管，
   * 例外只剩下"延长凭证寿命"这一个作用——那正是 7.2 那条间歇性「附件确认错误」的成因之一。
   *
   * @param action - 本次会话的 post/check action
   */
  private beginSession(action: string): void {
    this.sessionTarget = action + '|' + appStore.auth.uid + '|' + String(this.ctx.fid) + '|' +
      String(this.ctx.tid) + '|' + String(this.ctx.targetPost ? this.ctx.targetPost.pid : 0)
    // 会话目标只用于日志：附件凭证与鉴权缓存**每次都无条件作废**（见上面的注释），
    // 不做"同目标复用"。真机上排查「附件确认错误」时要能一眼看到这次提交属于哪个目标。
    logger.verbose('[REPLY] session begin target=%{public}s', this.sessionTarget)
    this.clearSession()
    // 上一个会话的媒体清单不能带入新会话：它属于另一份草稿键
    this.sessionMedia = []
    // 本类同时只有一个编辑器会话：先清掉上一个会话的活跃登记，避免异常关闭路径
    // （组件销毁时没走 clearDraft）在 `DraftStore` 里留下永久豁免的僵尸键
    draftStore.endAllSessions()
    const key: string = this.draftKey()
    /*
     * 活跃键登记（A7）：草稿 JSON 此刻可能还不存在（用户还没关闭过编辑器），
     * 但媒体副本已经写在 `draft_media/<key>/` 下了。不登记的话，启动清理会把这个
     * **没有 JSON 认领**的目录当孤儿即时删掉，用户发送时撞"副本已不存在"的硬失败。
     */
    draftStore.beginSession(key)
    /*
     * 把**草稿里记录的媒体**装回会话：凭证已丢，但本地副本还在，提交时由
     * `ensureDraftMedia` 用副本重传。
     *
     * 编辑（EDIT）同样装回（B3）：编辑模式的图片按钮照常可用、`uploadImageWithDraft` 照常
     * 把副本登记进 `sessionMedia`，不装回就会出现"编辑里插的图重开后无凭证"。
     * 编辑正文里**原本就有**的服务端既有附件没有本地副本，它们既不在草稿媒体清单里、
     * 也不会被懒重传触碰，`attachArray` 回填语义不受影响。
     */
    const draft: EditorDraft | null = draftStore.loadDraft(key)
    if (draft !== null && draft.media.length > 0) {
      this.sessionMedia = draft.media
    }
  }

  /** 丢弃当前会话的鉴权缓存与附件参数（不动本地媒体清单）。 */
  private clearSession(): void {
    this.cachedAuth = null
    this.cachedAuthAction = ''
    this.pendingAttachments = []
  }

  startThreadReply(tid: number, fid: number): void {
    this.ctx.type = ReplyType.THREAD
    this.ctx.tid = tid
    this.ctx.fid = fid
    this.ctx.page = 0
    this.ctx.targetPost = null
    this.ctx.quotePrefix = ''
    this.beginSession('reply')
  }

  startFloorReply(post: PostInfo, tid: number, fid: number, page: number): void {
    this.ctx.type = ReplyType.FLOOR
    this.ctx.tid = tid
    this.ctx.fid = fid
    this.ctx.page = page
    this.ctx.targetPost = post
    this.ctx.quotePrefix = this.buildQuotePrefix(post, tid, page)
    this.beginSession('quote')
  }

  startComment(post: PostInfo, tid: number, fid: number): void {
    this.ctx.type = ReplyType.COMMENT
    this.ctx.tid = tid
    this.ctx.fid = fid
    this.ctx.page = 0
    this.ctx.targetPost = post
    this.ctx.quotePrefix = ''
    this.beginSession('tietiao')
  }

  startEdit(post: PostInfo, tid: number, fid: number): void {
    this.ctx.type = ReplyType.EDIT
    this.ctx.tid = tid
    this.ctx.fid = fid
    this.ctx.page = 0
    this.ctx.targetPost = post
    this.ctx.quotePrefix = ''
    this.beginSession('modify')
  }

  reset(): void {
    this.ctx.type = ReplyType.THREAD
    this.ctx.tid = 0
    this.ctx.fid = 0
    this.ctx.page = 0
    this.ctx.targetPost = null
    this.ctx.quotePrefix = ''
    this.sessionTarget = ''
    this.sessionMedia = []
    this.clearSession()
    draftStore.endAllSessions()
  }

  // 预览内容：引用楼层时展示 quotePrefix + 用户输入（仅编辑器预览用）
  // 注意：提交时不再拼接 quotePrefix——官方客户端 quote 提交 content 仅为用户输入，
  // 引用块由服务端按 pid 生成（见 buildQuotePrefix 注释）
  buildContent(userText: string): string {
    if (this.ctx.quotePrefix && this.ctx.type === ReplyType.FLOOR) {
      return this.ctx.quotePrefix + userText
    }
    return userText
  }

  // BBCode 包装辅助 (纯文本插入)
  static wrapSelectedText(text: string, selStart: number, selEnd: number, tag: string): string {
    const before: string = text.substring(0, selStart)
    const selected: string = text.substring(selStart, selEnd)
    const after: string = text.substring(selEnd)
    if (selStart !== selEnd) {
      return before + '[' + tag + ']' + selected + '[/' + tag + ']' + after
    }
    return before + '[' + tag + '][/' + tag + ']' + after
  }

  static insertUrl(text: string, selStart: number, selEnd: number): string {
    const before: string = text.substring(0, selStart)
    const selected: string = text.substring(selStart, selEnd)
    const after: string = text.substring(selEnd)
    if (selStart !== selEnd) {
      return before + '[url=' + selected + ']' + selected + '[/url]' + after
    }
    return before + '[url][/url]' + after
  }

  static insertAtTag(text: string, selStart: number, selEnd: number): string {
    const before: string = text.substring(0, selStart)
    const after: string = text.substring(selEnd)
    return before + '[@]' + after
  }

  static insertImg(text: string, selStart: number, selEnd: number, imgTag: string): string {
    const before: string = text.substring(0, selStart)
    const after: string = text.substring(selEnd)
    return before + imgTag + after
  }

  static insertEmoticon(text: string, selStart: number, selEnd: number, code: string): string {
    const before: string = text.substring(0, selStart)
    const after: string = text.substring(selEnd)
    return before + code + after
  }

  async getOrFetchAuth(): Promise<PostAuthResult> {
    const actionParam: string = this.ctx.type === ReplyType.EDIT ? 'modify' :
      (this.ctx.type === ReplyType.COMMENT ? 'tietiao' :
        (this.ctx.type === ReplyType.FLOOR ? 'quote' : 'reply'))
    // 缓存按 action 区分：quote 的 check 响应携带引用块 content（提交时必须带回），
    // 复用其它 action 的 check 结果会导致引用块丢失；action 变化即重新请求。
    if (this.cachedAuth && this.cachedAuth.ok && this.cachedAuthAction === actionParam) {
      return this.cachedAuth
    }
    const authResult: PostAuthResult = await getPostAuth(
      appStore.auth.token, this.ctx.fid, actionParam,
      this.ctx.tid, this.ctx.targetPost ? this.ctx.targetPost.pid : 0,
      0
    )
    if (authResult.ok) {
      this.cachedAuth = authResult
      this.cachedAuthAction = actionParam
      // 编辑场景回填服务端返回的既有附件：修改带附件帖子时保留原有附件，
      // 新上传附件在此基础上累积（与官方 `PostFragment` 对 `ActionCheck.attachArray` 的
      // 回填一致）。仅在本地尚无附件时回填，避免覆盖上传累积结果。
      //
      // 注意**不要**在这里按 `auth` 变化清空已累积的附件：提交请求根本不含 `auth`
      // 字段（见 `ThreadWriteApi.postReply` 的字段集），服务端无从按 auth 校验附件码，
      // 「换 auth 即作废」是没有依据的推断；而在编辑器里切换「回复/贴条」恰好会换 action、
      // 换 auth，那样做会把正文里已经插好的图片附件码清掉（正文有 `[img]`、参数为空）。
      if (this.ctx.type === ReplyType.EDIT && this.pendingAttachments.length === 0 &&
        authResult.attachments.length > 0) {
        restoreServerAttachments(this.pendingAttachments, authResult.attachments,
          authResult.attachmentsCheck)
      }
    }
    return authResult
  }

  /** 压缩图片（当前未实现，直接透传原数据） */
  async compressImage(data: ArrayBuffer): Promise<ArrayBuffer> {
    return data
  }

  // 上传图片：pick → compress → upload → 插入 [img] → 记录附件参数
  async uploadImage(imageData: ArrayBuffer, fileName: string): Promise<string> {
    logger.verbose('[IMGUP] getOrFetchAuth start')
    const authResult: PostAuthResult = await this.getOrFetchAuth()
    logger.verbose('[IMGUP] getOrFetchAuth ok: %{public}s', String(authResult.ok))
    if (!authResult.ok) {
      throw new Error(authResult.error || '获取上传权限失败')
    }
    const compressed: ArrayBuffer = await this.compressImage(imageData)
    logger.verbose('[IMGUP] compressed size: %{public}s', String(compressed.byteLength))
    const uploadResult: UploadAttachmentResult = await uploadAttachment(
      appStore.auth.token, authResult.auth, this.ctx.fid, authResult.attachUrl,
      compressed, fileName
    )
    logger.verbose('[IMGUP] uploadAttachment ok: %{public}s url: %{public}s err: %{public}s', String(uploadResult.ok), String(uploadResult.url), String(uploadResult.error))
    if (!uploadResult.ok) {
      throw new Error(uploadResult.error || '上传图片失败')
    }
    if (!appendPendingAttachment(this.pendingAttachments, uploadResult)) {
      // 服务端没回 `attachments`（提交参数）：正文会拿到一个地址，而请求里没有对应附件参数
      // ——图片在帖子里丢失且无提示。按失败处理，让编辑器不要插入这个标签（B6）。
      throw new Error('服务端未签发附件参数，图片上传失败，请重试')
    }
    return uploadResult.url
  }

  /**
   * 上传一张草稿图片：**上传完成后立刻把本地副本写进草稿媒体目录**，并登记为草稿媒体。
   *
   * 副本字节就用本次上传用的那一份 `imageData`（调用方已经把它读进内存了），
   * 不再回头去读 Picker URI：一来省一次 IO，二来避开 URI 与路径的语义差异（见
   * `DraftMediaStore` 文件头的复制 API 契约说明）。
   *
   * @param imageData - 图片二进制数据（既用于上传，也用于落副本）
   * @param fileName - 上传用的原始文件名
   * @returns 上传后的图片 URL（用于拼 `[img]` 标签）
   */
  async uploadImageWithDraft(imageData: ArrayBuffer, fileName: string): Promise<string> {
    const imageUrl: string = await this.uploadImage(imageData, fileName)
    const localPath: string = await draftMediaStore.saveCopy(this.draftKey(), imageData, fileName)
    if (localPath.length === 0) {
      // 副本失败不阻断本次上传：本次发送仍然有效，只是这条媒体失去懒重传能力
      logger.warn('[DRAFT] copy still image failed, re-upload unavailable')
      return imageUrl
    }
    const media: DraftMedia = new DraftMedia()
    media.localPath = localPath
    media.fileName = fileName
    media.url = imageUrl
    media.tag = '[img]./' + imageUrl + '.medium.jpg[/img]'
    this.recordDraftMedia(media)
    return imageUrl
  }

  /**
   * 上传一张草稿动态照片：**上传完成后立刻把封面与视频两半都复制进草稿媒体目录**。
   *
   * 两半一起复制、一起登记（服务端把它存成两个普通附件，只留一半会重传出半个动态照片）；
   * 封面复制失败就不登记这条媒体——留着一个没有封面的登记项会让懒重传走到"副本缺失"的
   * 硬失败上，用户反而发不出去。
   *
   * @param coverData - 封面（静态图）二进制数据
   * @param videoData - 视频二进制数据
   * @returns 可插入正文的 BBCode 三元组
   */
  async uploadMovingPhotoWithDraft(coverData: ArrayBuffer, videoData: ArrayBuffer): Promise<string> {
    const tag: string = await this.uploadMovingPhoto(coverData, videoData)
    const coverLocal: string = await draftMediaStore.saveCopy(this.draftKey(), coverData,
      MOVING_PHOTO_COVER_NAME)
    const videoLocal: string = coverLocal.length === 0 ? ''
      : await draftMediaStore.saveCopy(this.draftKey(), videoData, MOVING_PHOTO_VIDEO_NAME)
    if (coverLocal.length === 0 || videoLocal.length === 0) {
      logger.warn('[DRAFT] copy moving photo failed, re-upload unavailable')
      return tag
    }
    // 两半的 URL 从**刚上传的那两个凭证**里取（`pendingAttachments` 末尾两项），
    // 不做标签反解：标签格式一旦调整，反解会静默取到空值
    const urls: string[] = this.pendingUrls
    const coverUrl: string = pendingUrlFromEnd(urls, 2)
    const videoUrl: string = pendingUrlFromEnd(urls, 1)
    if (coverUrl.length === 0 || videoUrl.length === 0) {
      logger.warn('[DRAFT] moving photo urls missing, skip draft media record')
      return tag
    }
    const media: DraftMedia = new DraftMedia()
    media.localPath = coverLocal
    media.fileName = MOVING_PHOTO_COVER_NAME
    media.url = coverUrl
    media.tag = tag
    media.videoLocalPath = videoLocal
    media.videoFileName = MOVING_PHOTO_VIDEO_NAME
    media.videoUrl = videoUrl
    media.videoTag = '[flash=video]./' + videoUrl + '[/flash]'
    this.recordDraftMedia(media)
    return tag
  }

  /**
   * 按正文引用过滤并拼出提交用的附件参数（实现见 `PostAttachments.buildAttachmentParams`）。
   *
   * @param content - 本次提交的正文（FLOOR 场景含服务端引用块）
   * @returns 过滤后的附件参数对
   */
  private collectAttachmentParams(content: string): AttachmentParams {
    const params: AttachmentParams = buildAttachmentParams(this.pendingAttachments, content)
    if (params.dropped > 0) {
      logger.verbose('[REPLY] dropped %{public}d attachment(s) not referenced by content',
        params.dropped)
    }
    return params
  }

  /**
   * 上传一张动态照片（封面 + 视频），返回可直接插入正文的 BBCode 三元组。
   *
   * 协议形态有实证（见 `MOVING_PHOTO_PLAN.md` §9）：动态照片在服务端就是**两个普通附件**
   * （封面 `type:'img'`、视频 `type:'app_video'`）加上正文里的一段固定标记，
   * 因此这里要做的事就是「传两半 → 各累积一次附件参数 → 拼三元组」。
   *
   * @param coverData 封面（静态图）二进制数据
   * @param videoData 视频二进制数据
   * @returns 可插入正文的 BBCode 三元组
   */
  async uploadMovingPhoto(coverData: ArrayBuffer, videoData: ArrayBuffer): Promise<string> {
    const authResult: PostAuthResult = await this.getOrFetchAuth()
    if (!authResult.ok) {
      throw new Error(authResult.error || '获取上传权限失败')
    }
    const coverResult: UploadAttachmentResult = await uploadAttachment(
      appStore.auth.token, authResult.auth, this.ctx.fid, authResult.attachUrl,
      await this.compressImage(coverData), MOVING_PHOTO_COVER_NAME
    )
    logger.verbose('[MPUP] cover ok: %{public}s url: %{public}s err: %{public}s',
      String(coverResult.ok), String(coverResult.url), String(coverResult.error))
    if (!coverResult.ok) {
      throw new Error(coverResult.error || '上传动态照片封面失败')
    }
    const videoResult: UploadAttachmentResult = await uploadVideoAttachment(
      appStore.auth.token, authResult.auth, this.ctx.fid, authResult.attachUrl,
      videoData, MOVING_PHOTO_VIDEO_NAME
    )
    logger.verbose('[MPUP] video ok: %{public}s url: %{public}s err: %{public}s',
      String(videoResult.ok), String(videoResult.url), String(videoResult.error))
    if (!videoResult.ok) {
      throw new Error(videoResult.error || '上传动态照片视频失败')
    }
    // 两半都必须真的记下（B6）：只记了一半就返回标签，正文会引用没有凭证的那一半
    const coverTracked: boolean = appendPendingAttachment(this.pendingAttachments, coverResult)
    const videoTracked: boolean = appendPendingAttachment(this.pendingAttachments, videoResult)
    if (!coverTracked || !videoTracked) {
      throw new Error('服务端未签发附件参数，动态照片上传失败，请重试')
    }
    return buildMovingPhotoTag(coverResult.url, videoResult.url)
  }

  // 发送回复/编辑
  async send(userText: string, isAnonymous: boolean): Promise<PostReplyResult> {
    if (!userText && this.ctx.type !== ReplyType.EDIT) {
      const empty: PostReplyResult = new PostReplyResult()
      empty.error = '内容不能为空'
      return empty
    }
    if (this.ctx.type === ReplyType.COMMENT) {
      const byteLen: number = this.getStringByteLength(userText)
      if (byteLen < 6) {
        const short: PostReplyResult = new PostReplyResult()
        short.error = '贴条内容至少需要6字节'
        return short
      }
      if (byteLen > 650) {
        const long: PostReplyResult = new PostReplyResult()
        long.error = '贴条内容不能超过650字节'
        return long
      }
    }

    const authResult: PostAuthResult = await this.getOrFetchAuth()
    if (!authResult.ok) {
      const err: PostReplyResult = new PostReplyResult()
      err.error = authResult.error || '无权回复'
      return err
    }

    // 附件参数不在发送层再设闸门：官方 `L0` 对 `attachments` / `attachments_check`
    // 是各自跳过空元素拼接的（长度允许不等），本地按"两侧数量必须相等"拦截会误杀
    // 合法形态；真正要防的「正文没引用这张图」在 `buildAttachmentParams` 里按引用过滤。
    logger.verbose('[REPLY] submit type=%{public}s pending=%{public}d',
      String(this.ctx.type), this.pendingAttachments.length)

    let result: PostReplyResult
    if (this.ctx.type === ReplyType.EDIT) {
      result = await this.sendEdit(userText, isAnonymous)
    } else if (this.ctx.type === ReplyType.COMMENT) {
      result = await this.sendComment(userText, isAnonymous)
    } else {
      result = await this.sendReply(userText, isAnonymous)
    }
    if (result.ok) {
      // 附件参数随本次提交被服务端消费，成功后必须立刻丢弃：本类是进程级单例，
      // 留着会让下一次「没插图」的回复带着旧参数提交（服务端报附件确认错误）。
      this.pendingAttachments = []
      // 提交成功 = 这份草稿已经变成帖子：草稿 JSON 与媒体副本目录一起回收
      this.clearDraft()
    }
    return result
  }

  private async sendReply(userText: string, isAnonymous: boolean): Promise<PostReplyResult> {
    // 引用（FLOOR）提交对齐官方 K0：content = post/check 响应引用块 + 用户输入。
    // 官方 post/check（action=quote, pid=被引用楼层）在响应 content 字段返回服务端
    // 预生成的引用块（[quote][pid=..,..,1]Reply[/pid] <b>Post by ...</b>...[/quote]），
    // K0 提交时经 d1.r(d1.w())（实体解码 + <br/>→\n）拼到用户输入前随 action=quote
    // 一起提交，服务端据此生成正式引用——仅靠 pid 参数不生效（迁移期曾丢弃该字段
    // 导致引用失效）。响应缺失引用块时回退本地构造（[quote][pid=..] 标记，
    // 与网页端引用同款格式），保证引用标记必然随 content 提交。
    let content: string = userText
    if (this.ctx.type === ReplyType.FLOOR) {
      let quoteBlock: string = ''
      const checkContent: string = this.cachedAuth !== null && this.cachedAuthAction === 'quote'
        ? this.cachedAuth.content : ''
      if (checkContent.length > 0) {
        quoteBlock = decodeHtmlEntities(checkContent).replace(/<br\s*\/?>/gi, '\n')
      } else if (this.ctx.targetPost !== null) {
        quoteBlock = this.buildQuotePrefix(this.ctx.targetPost, this.ctx.tid, 1)
      }
      content = quoteBlock + userText
    }
    const pid: number = this.ctx.targetPost ? this.ctx.targetPost.pid : 0
    const attachParams: AttachmentParams = this.collectAttachmentParams(content)
    logger.verbose('[REPLY] reply attachments kept=%{public}d', attachParams.kept)
    return postReply(
      appStore.auth.token, this.ctx.tid, this.ctx.fid,
      content,
      isAnonymous ? 1 : 0,
      attachParams.attachments, attachParams.attachmentsCheck,
      0, this.ctx.type === ReplyType.FLOOR ? 'quote' : 'reply', pid, ''
    )
  }

  private async sendEdit(userText: string, isAnonymous: boolean): Promise<PostReplyResult> {
    if (!this.ctx.targetPost) {
      const err: PostReplyResult = new PostReplyResult()
      err.error = '未指定目标楼层'
      return err
    }
    const attachParams: AttachmentParams = this.collectAttachmentParams(userText)
    logger.verbose('[REPLY] modify attachments kept=%{public}d', attachParams.kept)
    return postReply(
      appStore.auth.token, this.ctx.tid, this.ctx.fid,
      userText, isAnonymous ? 1 : 0,
      attachParams.attachments, attachParams.attachmentsCheck,
      0, 'modify', this.ctx.targetPost.pid, ''
    )
  }

  private async sendComment(userText: string, isAnonymous: boolean): Promise<PostReplyResult> {
    if (!this.ctx.targetPost) {
      const err: PostReplyResult = new PostReplyResult()
      err.error = '未指定目标楼层'
      return err
    }
    // 贴条同样提交附件（官方 tietiao 只是去掉 subject/address，附件参数照发）：
    // 贴条模式下图片按钮仍可用，丢了附件参数就会让正文的 `[img]` 变成未声明附件。
    const attachParams: AttachmentParams = this.collectAttachmentParams(userText)
    logger.verbose('[REPLY] tietiao attachments kept=%{public}d', attachParams.kept)
    return postComment(
      appStore.auth.token, this.ctx.tid, this.ctx.targetPost.pid,
      this.ctx.fid, userText,
      isAnonymous ? 1 : 0,
      attachParams.attachments, attachParams.attachmentsCheck
    )
  }

  // ============== 草稿媒体（本地副本 + 懒重传） ==============

  /**
   * 给当前草稿登记一条媒体（本地副本已复制完成后调用）。
   *
   * 只登记、不落盘：落盘发生在关闭编辑器时（`saveDraft`）。这样"用户还在编辑器里"期间
   * 不会反复写文件，而"关闭 → 杀掉进程"这条路径由 `saveDraft` 一次性写全。
   *
   * @param media - 待登记的媒体（本地副本路径由调用方先经 `draftMediaStore.saveCopy` 取得）
   */
  recordDraftMedia(media: DraftMedia): void {
    this.sessionMedia.push(media)
    logger.verbose('[DRAFT] media recorded kind=%{public}s total=%{public}d',
      media.videoLocalPath.length > 0 ? 'moving' : 'still', this.sessionMedia.length)
  }

  /**
   * 判断**当前正文里是否还引用着某个草稿媒体**（B12）。
   *
   * 编辑器用它决定"只有图片、没有文字"的草稿要不要留住。早先的判据是
   * `draftMediaCount > 0`，那只是数组长度：用户把 `[img]` 标签从正文删掉再清空正文后，
   * 关闭编辑器照样弹确认框并保存一份空草稿，之后每次开关都弹一次。
   * 判据换成"正文里是否真的还有某个媒体的地址"后，这类空壳草稿自然不再保留
   * （清理由 `clearDraft` 负责，副本目录一并回收）。
   *
   * @param content - 待判定的正文
   * @returns 是否仍引用着至少一个已登记的媒体
   */
  hasReferencedMedia(content: string): boolean {
    if (content.length === 0) {
      return false
    }
    for (let i: number = 0; i < this.sessionMedia.length; i++) {
      const item: DraftMedia = this.sessionMedia[i]
      const cover: string = item.url.length > 0 ? item.url : item.tag
      if (cover.length > 0 && content.indexOf(cover) >= 0) {
        return true
      }
      const video: string = item.videoUrl.length > 0 ? item.videoUrl : item.videoTag
      if (video.length > 0 && content.indexOf(video) >= 0) {
        return true
      }
    }
    return false
  }

  /**
   * 提交前的媒体准备：对**正文仍然引用、且本会话已无凭证**的媒体，用本地副本重新上传，
   * 并把替换对交给调用方（见 `DRAFT_MEDIA_PLAN.md` 阶段 3）。
   *
   * 为什么是"提交前"而不是"打开草稿时"：打开草稿看一眼又关掉很常见，没必要消耗流量与
   * NGA 上传配额（上传有门槛与频次限制，错误码 13 = 发帖数不足）。
   *
   * 边界：
   * - 本地副本缺失，但**本会话凭证仍在**（用户上传后没关过编辑器）：直接用凭证，不报错；
   * - 本地副本缺失且凭证也没了（清了缓存 / 文件被删）：**明确失败**，不静默跳过——跳过会让
   *   正文的 `[img]` 变成未声明附件，正是本次要消灭的那类不一致；
   * - 编辑（EDIT）也参与：编辑里新插入的图有本地副本（见 `beginSession` 的说明），
   *   服务端既有附件的凭证由 `attachArray` 回填、不走这条路径。
   *
   * @param content - 待提交的正文
   * @returns 准备结果；失败时以 `result.error` 说明，`replacements` 里带着已完成的替换
   */
  async ensureDraftMedia(content: string): Promise<PreparedContent> {
    const prepared: PreparedContent = await prepareDraftMedia(this, this.sessionMedia, content)
    if (prepared.changed) {
      logger.info('[REPLY] draft media re-uploaded count=%{public}d', prepared.reuploaded)
    }
    return prepared
  }

  /**
   * 把重传得到的替换对应用到**当前**正文上（A4）。
   *
   * 调用方必须传"此刻编辑器里的正文"，而不是发起重传时的那份快照：
   * 重传期间用户可能又打了字、又插了图，整串覆盖会把这些输入静默丢掉。
   *
   * @param currentText - 当前正文
   * @param prepared - `ensureDraftMedia` 的结果
   * @returns 应用替换后的正文
   */
  applyMediaReplacements(currentText: string, prepared: PreparedContent): string {
    return applyContentReplacements(currentText, prepared.replacements)
  }

  // ============== DraftUploadHost 实现（懒重传的宿主能力） ==============

  /**
   * 懒重传使用的凭证地址列表（见 `DraftUploadHost.pendingUrls`）。
   *
   * 动态照片登记时也用它回填封面/视频地址，避免从标签反解 URL（标签格式一变就取到空值）。
   */
  get pendingUrls(): string[] {
    const urls: string[] = []
    for (let i: number = 0; i < this.pendingAttachments.length; i++) {
      urls.push(this.pendingAttachments[i].url)
    }
    return urls
  }

  /**
   * 追加一条懒重传拿到的凭证（见 `DraftUploadHost.appendPending`）。
   *
   * @param result - 本次上传结果
   * @returns 是否真的记下了（`attachments` 为空时记不下，调用方据此判失败）
   */
  appendPending(result: UploadAttachmentResult): boolean {
    return appendPendingAttachment(this.pendingAttachments, result)
  }

  /**
   * 懒重传开始前的用户可见反馈（见 `DraftUploadHost.onReuploadStart`）。
   *
   * manager 层不直接弹提示（它不是 UI 层），但这里是最清楚"要重传"的位置，
   * 因此复用 `appStore` 的全局 Toast——与编辑器的上传提示同一通路。
   */
  onReuploadStart(): void {
    appStore.showToast('正在重新上传草稿中的图片...')
  }

  /**
   * 上传一份图片数据（懒重传用；与 `uploadImage` 同路径，但不登记草稿媒体——
   * 重传的这条已经登记过了）。
   *
   * @param data - 二进制数据
   * @param fileName - 原始文件名
   * @param auth - post/check 返回的附件鉴权码
   * @param attachUrl - post/check 返回的上传地址
   * @returns 上传结果
   */
  async uploadImageData(data: ArrayBuffer, fileName: string, auth: string,
    attachUrl: string): Promise<UploadAttachmentResult> {
    return uploadAttachment(appStore.auth.token, auth, this.ctx.fid, attachUrl,
      await this.compressImage(data), fileName)
  }

  /**
   * 上传动态照片的视频半边（懒重传用）。
   *
   * @param data - 视频二进制数据
   * @param fileName - 视频文件名
   * @param auth - post/check 返回的附件鉴权码
   * @param attachUrl - post/check 返回的上传地址
   * @returns 上传结果
   */
  async uploadVideoData(data: ArrayBuffer, fileName: string, auth: string,
    attachUrl: string): Promise<UploadAttachmentResult> {
    return uploadVideoAttachment(appStore.auth.token, auth, this.ctx.fid, attachUrl,
      data, fileName)
  }

  // ============== 草稿保存/恢复（文件持久化） ==============

  /**
   * 草稿键：**按"目标"划分，不含模式**（A5，见 `DRAFT_MEDIA_PLAN.md` §9.5）。
   *
   * 含 **uid 短哈希**：草稿文件不按账号分目录，键里不带 uid 时"换账号后在同一个帖子回复"
   * 会读到上一个账号的草稿内容与媒体清单（与官方 `ActionCheck.buildActionId` 的 uid 维度同构）。
   *
   * 三种目标（**模式开关不再参与**）：
   * - 编辑某楼层：`draft_<tid>_edit_<pid>_<uid>` —— 编辑与回复是不同操作，保持独立；
   * - 楼层回复 / 贴条：`draft_<tid>_p<pid>_<uid>` —— 两者都是"针对某楼层的内容"，
   *   共用同一个键；
   * - 主题级回复：`draft_<tid>_<uid>`。
   *
   * 为什么把模式移出键：`toggleMode()` 只改 `ctx.type`、不重划会话，而**媒体副本目录是绑在
   * 键上的**。模式参与键时，一次编辑会话会在 `draft_..._floor_...` 与 `draft_..._comment_...`
   * 之间漂移——草稿正文与媒体清单落在两个键里、副本目录要么共享要么被对方整目录删掉、
   * 旧键还会留下没有任何引用者的孤儿目录。移出模式后 `toggleMode()` 前后 `draftKey()`
   * 恒定不变，`clearDraft()` 也只可能删到当前这个键的目录。
   *
   * 旧键（含 `_floor_` / `_comment_` / `_reply_`）不兼容、不做迁移：用户明确不要旧草稿数据。
   *
   * @returns 文件名安全的草稿键
   */
  private draftKey(): string {
    const uidPart: string = draftUidPart(appStore.auth.uid)
    const tidPart: string = String(this.ctx.tid)
    const pid: number = this.ctx.targetPost ? this.ctx.targetPost.pid : 0
    if (this.ctx.type === ReplyType.EDIT && pid > 0) {
      return 'draft_' + tidPart + '_edit_' + String(pid) + '_' + uidPart
    }
    if (pid > 0) {
      // FLOOR（引用回复）与 COMMENT（贴条）共用：都是"针对某楼层的内容"
      return 'draft_' + tidPart + '_p' + String(pid) + '_' + uidPart
    }
    return 'draft_' + tidPart + '_' + uidPart
  }

  /**
   * 保存草稿（正文 + 媒体清单）。
   *
   * 正文为空但存在媒体时**同样保存**：图片已经上传、副本已经复制，"只有图片的草稿"必须留住。
   * 媒体是否"算数"由调用方按 `hasReferencedMedia` 判定（B12）。
   *
   * @param text - 正文
   */
  saveDraft(text: string): void {
    if (text.length === 0 && this.sessionMedia.length === 0) {
      return
    }
    const draft: EditorDraft = new EditorDraft()
    draft.key = this.draftKey()
    draft.content = text
    draft.media = this.sessionMedia
    if (!draftStore.saveDraft(draft)) {
      logger.warn('[DRAFT] save failed key=%{public}s', draft.key)
    }
  }

  /**
   * 读取草稿正文。
   *
   * @returns 正文；无草稿时为空串
   */
  loadDraft(): string {
    const draft: EditorDraft | null = draftStore.loadDraft(this.draftKey())
    return draft === null ? '' : draft.content
  }

  /**
   * 删除草稿（连同媒体副本目录），并注销会话登记。
   *
   * 提交成功、用户明确放弃草稿、"内容为空时关闭"三处调用；"清除缓存"走
   * `SettingsPanel.clearCache` 的目录清单（整目录删除）+ `draftStore.reloadAfterClear`。
   */
  clearDraft(): void {
    const key: string = this.draftKey()
    // clearDraft 内部会 endSession(key)；这里补一次是为了覆盖"键在会话开始后变化"的异常路径
    draftStore.clearDraft(key)
    draftStore.endSession(key)
    draftMediaStore.removeDraftMedia(key)
    this.sessionMedia = []
  }

  private getStringByteLength(str: string): number {
    let len: number = 0
    for (let i: number = 0; i < str.length; i++) {
      const code: number = str.charCodeAt(i)
      if (code <= 0x7f) {
        len++
      } else if (code <= 0x7ff) {
        len += 2
      } else if (code <= 0xffff) {
        len += 3
      } else {
        len += 4
      }
    }
    return len
  }
}

export const replyManager = new ReplyManagerClass()
