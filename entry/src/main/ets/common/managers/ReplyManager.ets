import type { PostInfo } from '../../model/PostInfo'
import { PostAuthResult, PostReplyResult } from '../../model/ThreadResult'
import { getPostAuth, postReply, postComment, uploadAttachment } from '../../service/api/ThreadWriteApi'
import type { UploadAttachmentResult } from '../../model/NgaApiResults'
import { appStore } from '../../store/AppStore'
import { Logger, DOMAIN_MANAGER } from '../utils/Logger'

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
  private pendingAttachments: string = ''
  private pendingAttachmentsCheck: string = ''

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

  // 构建引用前缀 — 对应 Java ArticleListAdapter.getReplyIntent()
  // 清洗 post.content 中的已有引用，避免多层嵌套
  // [quote][pid={pid},{tid},{page}]Reply[/pid] [b]Post by [uid={authorId}]{author}[/uid] ({postDate}):[/b]\n{cleanedContent}[/quote]\n
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

  startThreadReply(tid: number, fid: number): void {
    this.ctx.type = ReplyType.THREAD
    this.ctx.tid = tid
    this.ctx.fid = fid
    this.ctx.page = 0
    this.ctx.targetPost = null
    this.ctx.quotePrefix = ''
  }

  startFloorReply(post: PostInfo, tid: number, fid: number, page: number): void {
    this.ctx.type = ReplyType.FLOOR
    this.ctx.tid = tid
    this.ctx.fid = fid
    this.ctx.page = page
    this.ctx.targetPost = post
    this.ctx.quotePrefix = this.buildQuotePrefix(post, tid, page)
  }

  startComment(post: PostInfo, tid: number, fid: number): void {
    this.ctx.type = ReplyType.COMMENT
    this.ctx.tid = tid
    this.ctx.fid = fid
    this.ctx.page = 0
    this.ctx.targetPost = post
    this.ctx.quotePrefix = ''
  }

  startEdit(post: PostInfo, tid: number, fid: number): void {
    this.ctx.type = ReplyType.EDIT
    this.ctx.tid = tid
    this.ctx.fid = fid
    this.ctx.page = 0
    this.ctx.targetPost = post
    this.ctx.quotePrefix = ''
    this.cachedAuth = null
    this.pendingAttachments = ''
    this.pendingAttachmentsCheck = ''
  }

  reset(): void {
    this.ctx.type = ReplyType.THREAD
    this.ctx.tid = 0
    this.ctx.fid = 0
    this.ctx.page = 0
    this.ctx.targetPost = null
    this.ctx.quotePrefix = ''
    this.cachedAuth = null
    this.pendingAttachments = ''
    this.pendingAttachmentsCheck = ''
  }

  // 获取完整正文: 引用楼层时 content = quotePrefix + userText，否则 = userText
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
    if (this.cachedAuth && this.cachedAuth.ok) {
      return this.cachedAuth
    }
    const actionParam: string = this.ctx.type === ReplyType.EDIT ? 'modify' : 'reply'
    const authResult: PostAuthResult = await getPostAuth(
      appStore.auth.token, this.ctx.fid, actionParam,
      this.ctx.tid, this.ctx.targetPost ? this.ctx.targetPost.pid : 0,
      this.ctx.type === ReplyType.COMMENT ? 1 : 0
    )
    if (authResult.ok) {
      this.cachedAuth = authResult
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
      appStore.auth.token, authResult.auth, this.ctx.fid,
      compressed, fileName
    )
    logger.verbose('[IMGUP] uploadAttachment ok: %{public}s url: %{public}s err: %{public}s', String(uploadResult.ok), String(uploadResult.url), String(uploadResult.error))
    if (!uploadResult.ok) {
      throw new Error(uploadResult.error || '上传图片失败')
    }
    // 累积附件参数（对应 Java PostParam.appendAttachment）
    if (this.pendingAttachments.length > 0) {
      this.pendingAttachments += '\t' + uploadResult.attachments
      this.pendingAttachmentsCheck += '\t' + uploadResult.attachmentsCheck
    } else {
      this.pendingAttachments = uploadResult.attachments
      this.pendingAttachmentsCheck = uploadResult.attachmentsCheck
    }
    return uploadResult.url
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

    let result: PostReplyResult
    if (this.ctx.type === ReplyType.EDIT) {
      result = await this.sendEdit(userText, isAnonymous)
    } else if (this.ctx.type === ReplyType.COMMENT) {
      result = await this.sendComment(userText, isAnonymous)
    } else {
      result = await this.sendReply(userText, isAnonymous)
    }
    return result
  }

  private async sendReply(userText: string, isAnonymous: boolean): Promise<PostReplyResult> {
    const content: string = this.buildContent(userText)
    const pid: number = this.ctx.targetPost ? this.ctx.targetPost.pid : 0
    return postReply(
      appStore.auth.token, this.ctx.tid, this.ctx.fid,
      content,
      isAnonymous ? 1 : 0,
      this.pendingAttachments, this.pendingAttachmentsCheck,
      0, 'reply', pid, ''
    )
  }

  private async sendEdit(userText: string, isAnonymous: boolean): Promise<PostReplyResult> {
    if (!this.ctx.targetPost) {
      const err: PostReplyResult = new PostReplyResult()
      err.error = '未指定目标楼层'
      return err
    }
    return postReply(
      appStore.auth.token, this.ctx.tid, this.ctx.fid,
      userText, isAnonymous ? 1 : 0,
      this.pendingAttachments, this.pendingAttachmentsCheck,
      0, 'modify', this.ctx.targetPost.pid, ''
    )
  }

  private async sendComment(userText: string, isAnonymous: boolean): Promise<PostReplyResult> {
    if (!this.ctx.targetPost) {
      const err: PostReplyResult = new PostReplyResult()
      err.error = '未指定目标楼层'
      return err
    }
    return postComment(
      appStore.auth.token, this.ctx.tid, this.ctx.targetPost.pid,
      this.ctx.fid, userText,
      isAnonymous ? 1 : 0
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
