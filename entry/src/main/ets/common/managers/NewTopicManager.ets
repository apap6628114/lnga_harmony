/**
 * 发新主题编排 - 对应官方客户端 TopicPostModel + MNGA post_reply(action=new) 流程。
 * 负责 auth 预检缓存、主题分类加载、图片上传与附件参数累积、草稿与发送分发。
 */

import { PostAuthResult, PostReplyResult, TopicCategoriesResult } from '../../model/ThreadResult'
import { getTopicCategories } from '../../service/api/ThreadApi'
import { getPostAuth, postNewTopic, uploadAttachment } from '../../service/api/ThreadWriteApi'
import type { UploadAttachmentResult } from '../../model/NgaApiResults'
import { appStore } from '../../store/AppStore'
import { Logger, DOMAIN_MANAGER } from '../utils/Logger'

const logger = new Logger(DOMAIN_MANAGER, 'NewTopicManager')

/** 发新主题的上下文（目标版块与子版块）。 */
@Observed
export class NewTopicContext {
  /** 版块 ID。 */
  fid: number = 0
  /** 子版块 ID（0 表示发在父版块）。 */
  stid: number = 0
  /** 版块名（用于编辑器标题展示）。 */
  boardName: string = ''
}

/** 发帖草稿数据。 */
@Observed
export class NewTopicDraft {
  /** 草稿标题。 */
  subject: string = ''
  /** 草稿正文。 */
  content: string = ''
}

/**
 * 发新主题编排器。
 *
 * 与 ReplyManager 同构：预检 auth 供附件上传与发送前权限校验使用，
 * 上传成功的附件参数累积后随发送请求一并提交。
 */
@Observed
export class NewTopicManagerClass {
  /** 当前发帖上下文。 */
  private ctx: NewTopicContext = new NewTopicContext()
  /** 缓存的发帖鉴权结果（start 时失效）。 */
  private cachedAuth: PostAuthResult | null = null
  /** 已上传附件的累积参数（tab 分隔）。 */
  private pendingAttachments: string = ''
  /** 已上传附件的累积校验参数（tab 分隔）。 */
  private pendingAttachmentsCheck: string = ''
  /** 缓存的版块主题分类结果。 */
  private cachedCategories: TopicCategoriesResult | null = null
  /** 分类缓存所属的版块 ID（0 表示未缓存）。 */
  private cachedCategoriesFid: number = 0

  /** 目标版块 ID。 */
  get fid(): number {
    return this.ctx.fid
  }

  /** 目标子版块 ID。 */
  get stid(): number {
    return this.ctx.stid
  }

  /** 目标版块名。 */
  get boardName(): string {
    return this.ctx.boardName
  }

  /** 初始化发帖上下文并清空缓存附件。 */
  start(fid: number, stid: number, boardName: string): void {
    this.ctx.fid = fid
    this.ctx.stid = stid
    this.ctx.boardName = boardName
    this.cachedAuth = null
    this.pendingAttachments = ''
    this.pendingAttachmentsCheck = ''
  }

  /**
   * 获取（或返回缓存的）发帖鉴权信息。
   *
   * @returns 鉴权结果；失败时 error 非空
   */
  async getOrFetchAuth(): Promise<PostAuthResult> {
    if (this.cachedAuth && this.cachedAuth.ok) {
      return this.cachedAuth
    }
    const authResult: PostAuthResult = await getPostAuth(
      appStore.auth.token, this.ctx.fid, 'new', 0, 0, 0, this.ctx.stid
    )
    if (authResult.ok) {
      this.cachedAuth = authResult
    }
    return authResult
  }

  /**
   * 加载版块的主题分类标签（按版块缓存，跨版块不串用）。
   *
   * @returns 分类名列表；接口失败时返回空列表（分类为可选能力）
   */
  async loadCategories(): Promise<string[]> {
    if (this.cachedCategories && this.cachedCategories.ok &&
      this.cachedCategoriesFid === this.ctx.fid) {
      return this.cachedCategories.categories
    }
    const result: TopicCategoriesResult = await getTopicCategories(appStore.auth.token, this.ctx.fid)
    if (result.ok) {
      this.cachedCategories = result
      this.cachedCategoriesFid = this.ctx.fid
      return result.categories
    }
    return []
  }

  /**
   * 压缩图片（当前未实现，直接透传原数据）。
   *
   * @param data - 原始图片数据
   * @returns 待上传图片数据
   */
  async compressImage(data: ArrayBuffer): Promise<ArrayBuffer> {
    return data
  }

  /**
   * 上传图片并累积附件参数（对应官方客户端 PostParam.appendAttachment）。
   *
   * @param imageData - 图片二进制数据
   * @param fileName - 文件名
   * @returns 上传后的图片 URL（用于拼 [img] 标签）
   */
  async uploadImage(imageData: ArrayBuffer, fileName: string): Promise<string> {
    logger.verbose('[NTPIC] getOrFetchAuth start')
    const authResult: PostAuthResult = await this.getOrFetchAuth()
    if (!authResult.ok) {
      throw new Error(authResult.error || '获取上传权限失败')
    }
    const compressed: ArrayBuffer = await this.compressImage(imageData)
    const uploadResult: UploadAttachmentResult = await uploadAttachment(
      appStore.auth.token, authResult.auth, this.ctx.fid, authResult.attachUrl,
      compressed, fileName
    )
    logger.verbose('[NTPIC] uploadAttachment ok: %{public}s url: %{public}s err: %{public}s',
      String(uploadResult.ok), String(uploadResult.url), String(uploadResult.error))
    if (!uploadResult.ok) {
      throw new Error(uploadResult.error || '上传图片失败')
    }
    // 累积附件参数（对应 Java PostParam.appendAttachment / L0 拼接：每个非空元素后追加 \t，
    // 最终串含尾 \t；多次上传形如 "a1\ta2\t"）
    if (uploadResult.attachments.length > 0) {
      this.pendingAttachments += uploadResult.attachments + '\t'
      this.pendingAttachmentsCheck += uploadResult.attachmentsCheck + '\t'
    }
    return uploadResult.url
  }

  /**
   * 发布新主题。
   *
   * @param subject - 标题
   * @param content - 正文（BBCode）
   * @param isAnonymous - 是否匿名发布
   * @returns 提交结果；成功时 tid 为新主题 ID（用于跳转）
   */
  async send(subject: string, content: string, isAnonymous: boolean): Promise<PostReplyResult> {
    const trimmedSubject: string = subject.trim()
    if (trimmedSubject.length === 0) {
      const empty: PostReplyResult = new PostReplyResult()
      empty.error = '标题不能为空'
      return empty
    }
    if (content.trim().length === 0) {
      const empty: PostReplyResult = new PostReplyResult()
      empty.error = '正文不能为空'
      return empty
    }

    const authResult: PostAuthResult = await this.getOrFetchAuth()
    if (!authResult.ok) {
      const err: PostReplyResult = new PostReplyResult()
      err.error = authResult.error || '无权发帖'
      return err
    }

    const result: PostReplyResult = await postNewTopic(
      appStore.auth.token, this.ctx.fid, this.ctx.stid,
      trimmedSubject, content,
      isAnonymous ? 1 : 0,
      this.pendingAttachments, this.pendingAttachmentsCheck
    )
    return result
  }

  /** 草稿标题存储键（按版块/子版块区分）。 */
  private draftSubjectKey(): string {
    if (this.ctx.stid !== 0) {
      return 'draft_newtopic_' + String(this.ctx.fid) + '_stid' + String(this.ctx.stid) + '_subject'
    }
    return 'draft_newtopic_' + String(this.ctx.fid) + '_subject'
  }

  /** 草稿正文存储键（按版块/子版块区分）。 */
  private draftContentKey(): string {
    if (this.ctx.stid !== 0) {
      return 'draft_newtopic_' + String(this.ctx.fid) + '_stid' + String(this.ctx.stid) + '_content'
    }
    return 'draft_newtopic_' + String(this.ctx.fid) + '_content'
  }

  /** 保存发帖草稿（标题与正文分开存储）。 */
  saveDraft(subject: string, content: string): void {
    if (subject.trim().length > 0) {
      AppStorage.setOrCreate<string>(this.draftSubjectKey(), subject)
    }
    if (content.trim().length > 0) {
      AppStorage.setOrCreate<string>(this.draftContentKey(), content)
    }
  }

  /** 读取发帖草稿。 */
  loadDraft(): NewTopicDraft {
    const draft: NewTopicDraft = new NewTopicDraft()
    draft.subject = AppStorage.get<string>(this.draftSubjectKey()) ?? ''
    draft.content = AppStorage.get<string>(this.draftContentKey()) ?? ''
    return draft
  }

  /** 清除发帖草稿。 */
  clearDraft(): void {
    AppStorage.delete(this.draftSubjectKey())
    AppStorage.delete(this.draftContentKey())
  }
}

export const newTopicManager = new NewTopicManagerClass()
