import type { PostInfo } from '../../model/PostInfo'
import { PostAuthResult, PostReplyResult } from '../../model/ThreadResult'
import { getPostAuth, postReply, postComment, uploadAttachment, uploadVideoAttachment } from '../../service/api/ThreadWriteApi'
import { MOVING_PHOTO_COVER_NAME, MOVING_PHOTO_VIDEO_NAME, buildMovingPhotoTag } from '../../service/api/NgaUploader'
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
export class ReplyManagerClass {
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
  /**
   * 当前编辑器会话目标（`action|fid|tid|pid`）。
   *
   * 附件参数与鉴权缓存只在该目标内复用，目标一变即作废（见 `beginSession`）。
   */
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
   * 同一目标内保留（不改动）：用户在编辑器里上传图片后放弃、稍后重新打开同一个
   * 回复框时，正文草稿里的图片仍靠这份参数绑定，清了会让草稿图片失效。
   * 编辑（modify）例外——服务端每次 check 都会重新签发 attachArray/attachCheckArray，
   * 必须每次重新拉取（见 `getOrFetchAuth` 的 EDIT 回填），不能复用上一次的参数。
   *
   * @param action - 本次会话的 post/check action
   */
  private beginSession(action: string): void {
    const pid: number = this.ctx.targetPost ? this.ctx.targetPost.pid : 0
    // uid 也进目标串：登出/换账号走的是 `appStore.clearAuth()`（只重置各 Store 与
    // WebView Cookie），碰不到本单例——上一个账号的 `auth` 与附件码会原样留下，
    // 换账号后在同一个帖子回复时目标串若不含 uid 就判为「同一会话」而被复用。
    const target: string = action + '|' + appStore.auth.uid + '|' + String(this.ctx.fid) + '|' +
      String(this.ctx.tid) + '|' + String(pid)
    if (action === 'modify' || target !== this.sessionTarget) {
      this.clearSession()
    }
    this.sessionTarget = target
  }

  /** 丢弃当前会话的鉴权缓存与附件参数。 */
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
    this.clearSession()
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
    appendPendingAttachment(this.pendingAttachments, uploadResult)
    return uploadResult.url
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
    appendPendingAttachment(this.pendingAttachments, coverResult)
    appendPendingAttachment(this.pendingAttachments, videoResult)
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

  // 草稿保存/恢复
  private draftKey(): string {
    if (this.ctx.type === ReplyType.EDIT && this.ctx.targetPost) {
      return 'draft_' + String(this.ctx.tid) + '_edit_' + String(this.ctx.targetPost.pid)
    }
    if (this.ctx.type === ReplyType.COMMENT) {
      return 'draft_' + String(this.ctx.tid) + '_comment'
    }
    if (this.ctx.type === ReplyType.FLOOR) {
      return 'draft_' + String(this.ctx.tid) + '_floor'
    }
    return 'draft_' + String(this.ctx.tid) + '_reply'
  }

  saveDraft(text: string): void {
    if (text.length > 0) {
      AppStorage.setOrCreate<string>(this.draftKey(), text)
    }
  }

  loadDraft(): string {
    const key: string = this.draftKey()
    const stored: string = AppStorage.get<string>(key) ?? ''
    return stored
  }

  clearDraft(): void {
    AppStorage.delete(this.draftKey())
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
