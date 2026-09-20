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

/**
 * 「编辑目标标题」的获取结果（见 {@link ReplyManagerClass.ensureEditSubject}）。
 *
 * 分开表达"没有标题"与"取标题这一步失败了"：前者是服务端确实没回传（可继续提交，让服务端
 * 给出真实原因），后者是网络/鉴权失败（提交注定带着空标题，报错文案会指向错误的方向）。
 */
class EditSubjectResult {
  /** 拿到的标题；没拿到时为空串。 */
  title: string = ''
  /** 取标题过程中的失败原因；成功或"服务端没给"时为空串。 */
  error: string = ''
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

  /**
   * 编辑目标的**帖子标题**（modify 提交必带，见 {@link ensureEditSubject}）。
   *
   * 生命周期与会话同边界：`beginSession` 清空、`getOrFetchAuth` 在 modify 场景回填。
   * 它是 manager 的会话状态而非渲染数据，因此不放进 `ReplyContext`。
   */
  private editSubject: string = ''

  /**
   * 编辑器会话代数（每次 `beginSession` 自增）。
   *
   * 用来丢弃**跨会话迟到的异步结果**：`startEdit` 会异步预取 post/check，用户完全可能
   * 在这一往返期间关掉编辑器、又打开另一个帖子的编辑器（本类是进程级单例，两次会话共用
   * 同一份字段）。没有这道守卫时，帖子 A 迟到的响应会把 A 的标题写进帖子 B 的会话，
   * modify 提交就带上**别的帖子的标题**。
   */
  private sessionGeneration: number = 0

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
    // 上一个会话的媒体清单与编辑标题不能带入新会话：它们属于另一份草稿键 / 另一个帖子
    this.sessionMedia = []
    this.editSubject = ''
    this.sessionGeneration++
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
    /*
     * 预取 post/check：编辑提交**必须**带回帖子标题（见 `ensureEditSubject`），标题只在
     * check 响应里（`ActionCheck.subject`）。在打开编辑器时就把这次请求发出去，等用户改完
     * 正文点保存时标题早已就位——提交路径因此不必再为标题多等一次往返。
     *
     * 顺带把服务端既有附件的回填（`attachArray`）提前到打开时刻，与官方
     * `PostActivity.newIntent` → 每次进编辑器重新取 `ActionCheck` 同构；失败不影响编辑
     * （提交时 `sendEdit` 会再取一次并记录真实原因），故这里只记日志、不改 UI 状态。
     *
     * 注意**两种失败都要记**：`getPostAuth` 内部自己 try/catch，网络/鉴权失败是
     * **返回 `ok=false` 而不是抛异常**，只挂 `.catch` 会让这类失败彻底静默。
     */
    this.ensureEditSubject().then((result: EditSubjectResult): void => {
      if (result.title.length === 0) {
        logger.warn('[REPLY] edit subject prefetch: %{public}s', result.error)
      }
    }).catch((error: Object) => {
      // 预取是"顺手"的一步：意外异常不该影响打开编辑器，提交路径会重新取并给出结论
      logger.warn('[REPLY] edit subject prefetch threw: %{public}s', String(error))
    })
  }

  /**
   * 确保「编辑目标标题」已就位（modify 提交必带）。
   *
   * **为什么必须带**：官方 `NetRequestWrapper.L0/K0` 只在 tietiao 分支
   * `hashMap.remove(ft.k.X)`（X=`subject`），**modify 分支保留 subject**；官方编辑页把
   * `ActionCheck.subject`（post/check 回传的帖子标题）回填进标题框（旧版 `PostFragment`
   * 的 modify 分支），并在提交时原样带回。早先这里对 modify 无条件提交空 `subject`
   * （`postReply(..., '', ...)`），与官方参数形态不一致。
   *
   * **标题只有一个来源：服务端 post/check 回传值**。刻意**不做本地兜底**（不用本页
   * `PostInfo.subject`、也不用 `threadSubject`）：官方 `ActionCheck.fromDraft` 的兜底源是
   * 本地**草稿**库里存过的标题，而不是当前页面数据；拿页面数据兜底意味着"服务端这次没给
   * 标题"时会用一个可能陈旧的本地值去覆盖服务端标题（版主改过标题、页面停留很久都会陈旧），
   * 这是整条链路上唯一可能**改坏服务端数据**的分支。没拿到就保持空串，与官方旧版
   * "modify 无 subject 时隐藏标题框、照样提交"的形态一致，并让真实原因留在日志里。
   *
   * @returns 标题与（若失败的）失败原因，供调用方决定是"继续提交"还是"报真实原因"
   */
  private async ensureEditSubject(): Promise<EditSubjectResult> {
    const out: EditSubjectResult = new EditSubjectResult()
    if (this.editSubject.length > 0) {
      out.title = this.editSubject
      return out
    }
    const generation: number = this.sessionGeneration
    const authResult: PostAuthResult = await this.getOrFetchAuth()
    // 迟到结果一律丢弃：这一往返期间用户可能已经换了编辑目标（见 sessionGeneration）
    if (this.sessionGeneration !== generation) {
      out.error = '编辑器会话已切换'
      return out
    }
    if (authResult.ok && authResult.subject.length > 0) {
      this.editSubject = authResult.subject
      out.title = this.editSubject
      return out
    }
    // 保留真实原因：早先只记 verbose 日志就继续提交空标题，用户看到的是服务端那句报错，
    // 而真正的原因（鉴权失败 / 服务端未回传）在任何地方都没留下痕迹。
    // 注意这里**必须**与 title 一起返回，不能被任何兜底分支清空（否则 `sendEdit` 的
    // "没拿到标题"告警会因为 title 被兜底填上而永远不打印）。
    if (!authResult.ok) {
      out.error = authResult.error.length > 0 ? authResult.error : '获取帖子标题失败'
    } else {
      out.error = 'server-returned-none'
    }
    return out
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
    this.editSubject = ''
    this.clearSession()
    draftStore.endAllSessions()
    /*
     * 代数必须自增：`reset()` 是"整体作废会话状态"的出口（登出、换号等场景会用它），
     * 而此刻可能有 post/check 在途——不作废它们，迟到的结果会通过代际校验，把**上一个
     * 账号/上一个帖子**的标题（乃至凭证）写回已经清空的会话。当前主代码没有调用 `reset()`，
     * 但它是唯一"清空全部会话状态"的公开出口，这个不变量必须在它自己身上成立。
     */
    this.sessionGeneration++
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
    // 记下发起时的会话代数：本次请求可能跨过一次会话切换（用户关掉编辑器又开了另一个
    // 帖子的编辑器），那样结果属于**上一个会话**，回填进缓存会让新会话拿到别的帖子的
    // auth/标题（见 sessionGeneration）。
    const generation: number = this.sessionGeneration
    const authResult: PostAuthResult = await getPostAuth(
      appStore.auth.token, this.ctx.fid, actionParam,
      this.ctx.tid, this.ctx.targetPost ? this.ctx.targetPost.pid : 0,
      0
    )
    /*
     * 代际失配 = 这一往返期间编辑器会话已经换过（用户关掉这个编辑器又打开了另一个帖子的），
     * 这份结果属于**上一个会话**，必须整个丢掉——**包括返回值**。
     *
     * 只跳过回填是不够的：调用方拿到它就会用「A 帖的 auth/attach_url + B 帖的 fid」去上传，
     * 并把 A 的附件凭证追加进 B 的 `pendingAttachments`（`uploadImage` 拿到结果后立刻
     * `appendPendingAttachment`），提交时就成了跨帖的脏附件参数（§7.2 那类"附件确认错误"）。
     * 因此这里返回一个**显式失败**的结果，让调用方走各自既有的失败分支（上传抛错、提交报错），
     * 而不是继续拿着上辈子的凭证干活。
     */
    if (this.sessionGeneration !== generation) {
      logger.verbose('[REPLY] drop stale check result (session switched)')
      const stale: PostAuthResult = new PostAuthResult()
      stale.error = '编辑器会话已切换，请重试'
      return stale
    }
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
      // 编辑场景记下帖子标题（modify 提交必带，见 `ensureEditSubject`）：
      // 服务端未回传时保留已取到的值，避免把已知标题覆盖成空串
      if (this.ctx.type === ReplyType.EDIT && authResult.subject.length > 0) {
        this.editSubject = authResult.subject
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
    // 本方法的两个 await（check + 上传）都可能跨过一次会话切换，快照代数用于最后的登记判定
    const generation: number = this.sessionGeneration
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
    /*
     * 会计数失配时**不登记**这条凭证：会话已换到另一个帖子，把它追加进 `pendingAttachments`
     * 会让新会话的 `pendingUrls` 混入上一帖的地址（提交时靠正文引用过滤兜住，但这一族状态
     * 本就不该跨会话）。图已上传、URL 仍返回给调用方，由调用方按自己的 disposed 判定处理。
     */
    if (this.sessionGeneration !== generation) {
      logger.verbose('[IMGUP] session switched, skip attachment registration')
      return uploadResult.url
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
    const generation: number = this.sessionGeneration
    const draftKey: string = this.draftKey()
    const imageUrl: string = await this.uploadImage(imageData, fileName)
    /*
     * 落副本与登记**必须过代际**：`uploadImage` 里含 post/check + 上传两个往返，用户完全可能
     * 在这期间关掉本编辑器、又打开另一个帖子的编辑器。用快照 key 之外的"当前"状态去落盘，
     * A 帖的图片字节会写进 **B 帖的草稿媒体目录**、幽灵记录会 push 进 B 的 `sessionMedia`，
     * 之后 B 提交时那条副本还会被当成"正文引用着、但没凭证"的媒体去重传。
     * 会话已切换时本次上传的结果已无用武之地，直接返回 URL（不落副本、不登记）。
     */
    if (this.sessionGeneration !== generation) {
      logger.verbose('[DRAFT] skip media copy, session switched')
      return imageUrl
    }
    const localPath: string = await draftMediaStore.saveCopy(draftKey, imageData, fileName)
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
    const generation: number = this.sessionGeneration
    const draftKey: string = this.draftKey()
    const tag: string = await this.uploadMovingPhoto(coverData, videoData)
    // 与 `uploadImageWithDraft` 同一把尺：会话已切换就不落副本、不登记（见该方法的说明）
    if (this.sessionGeneration !== generation) {
      logger.verbose('[DRAFT] skip media copy, session switched')
      return tag
    }
    const coverLocal: string = await draftMediaStore.saveCopy(draftKey, coverData,
      MOVING_PHOTO_COVER_NAME)
    const videoLocal: string = coverLocal.length === 0 ? ''
      : await draftMediaStore.saveCopy(draftKey, videoData, MOVING_PHOTO_VIDEO_NAME)
    // 第二次落盘后**再复查一次**代数：两半是两次独立 IO，期间同样可能换会话。
    // 不复查就会把"封面已落进 A 的目录、视频落进 B 的目录、记录 push 进 B"这种劈叉态写出来
    if (this.sessionGeneration !== generation) {
      logger.verbose('[DRAFT] skip moving photo record, session switched')
      return tag
    }
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
    // 本次提交要清理的草稿键：提交是长往返，期间会话可能已被换成另一个编辑器，
    // 成功后必须清**这一份**而不是"当时的那一份"（见下面的 clearDraft 注释）
    const draftKey: string = this.draftKey()

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
      /*
       * 提交成功 = 这份草稿已经变成帖子：草稿 JSON 与媒体副本目录一起回收。
       *
       * **必须按提交前快照的键清，不能用"当前"键**：提交期间用户可能已经关掉这个编辑器、
       * 又打开了另一个帖子的编辑器（`draftKey()` 随后指向那一份草稿），用当前键清理会删掉
       * **别人**的草稿 JSON 与媒体副本目录——而那个会话的 `sessionMedia` 仍指向被删的文件，
       * 它提交时会撞上「本地副本已不存在」的硬失败。
       */
      this.clearDraft(draftKey)
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
    // 标题必须在提交前就位（见 `ensureEditSubject`）：它只来自 post/check 响应，正常路径下
    // `startEdit` 已预取；这里再确保一次，覆盖「预取失败 / 编辑器开了很久」两种情形。
    const subjectResult: EditSubjectResult = await this.ensureEditSubject()
    if (subjectResult.title.length === 0) {
      /*
       * 没拿到标题仍然提交（与官方旧版 modify "无 subject 就隐藏标题框、照样提交"同形态，
       * 也让服务端给出真实结论），但**必须把原因记到 warn 级**：Release 下
       * `logger.verbose` 会被 `VERBOSE` 开关整体静默掉，而这条正是真机排查
       * 「编辑还是失败」时唯一能区分各根因的线索——
       * `server-returned-none` = 服务端确实没回传；`编辑器会话已切换` = 结果被代数守卫丢弃；
       * 其余文案 = check 本身失败（注意提交路径上的"未登录"已被 `send` 的鉴权门禁拦下，
       * 这里能看到的多半是服务端拒绝或网络异常）。
       */
      logger.warn('[REPLY] modify without subject target=%{public}s authErr=%{public}s',
        this.sessionTarget, subjectResult.error)
    }
    const attachParams: AttachmentParams = this.collectAttachmentParams(userText)
    logger.verbose('[REPLY] modify attachments kept=%{public}d', attachParams.kept)
    // 用 `subjectResult.title` 而不是 `this.editSubject`：两者当前恒等，但直接消费刚拿到的
    // 返回值，就不依赖"这个字段一定被回填过"的隐式耦合
    return postReply(
      appStore.auth.token, this.ctx.tid, this.ctx.fid,
      userText, isAnonymous ? 1 : 0,
      attachParams.attachments, attachParams.attachmentsCheck,
      0, 'modify', this.ctx.targetPost.pid, subjectResult.title
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
   * 当前会话的草稿键（公开只读视图）。
   *
   * 调用方在发起提交**之前**取一份快照，成功后用它清理草稿：提交是长往返，期间用户可能
   * 已经打开另一个帖子的编辑器，那时"当前键"已经指向那一份草稿，拿它去清会删错东西
   * （见 `send` 成功分支与 `clearDraft` 的说明）。
   */
  get draftKeySnapshot(): string {
    return this.draftKey()
  }

  /**
   * 删除草稿（连同媒体副本目录），并注销会话登记。
   *
   * 提交成功、用户明确放弃草稿、"内容为空时关闭"三处调用；"清除缓存"走
   * `SettingsPanel.clearCache` 的目录清单（整目录删除）+ `draftStore.reloadAfterClear`。
   *
   * @param key - 要清理的草稿键；省略时取当前会话的键。**异步提交成功后必须传"提交前
   *   快照的键"**：那时 `ctx` 可能已经指向另一个编辑器，用当前键会删掉别人的草稿与媒体副本
   *   （见 `send` 成功分支的说明）。
   */
  clearDraft(key?: string): void {
    const target: string = key === undefined ? this.draftKey() : key
    // clearDraft 内部会 endSession(key)；这里补一次是为了覆盖"键在会话开始后变化"的异常路径
    draftStore.clearDraft(target)
    draftStore.endSession(target)
    draftMediaStore.removeDraftMedia(target)
    // 只有清的是**当前**会话的草稿时才动本地媒体清单：清了别的键却清空当前清单，
    // 会让当前会话已上传的媒体失去重传能力
    if (target === this.draftKey()) {
      this.sessionMedia = []
    }
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
