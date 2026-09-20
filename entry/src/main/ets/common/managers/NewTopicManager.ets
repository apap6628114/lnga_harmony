/**
 * 发新主题编排 - 对应官方客户端 TopicPostModel + MNGA post_reply(action=new) 流程。
 * 负责 auth 预检缓存、主题分类加载、图片上传与附件参数累积、草稿与发送分发。
 *
 * 草稿与附件链路与 `ReplyManager` 同构：
 * - 草稿落盘走 `DraftStore`（`filesDir/drafts/<key>.json`），媒体副本走 `DraftMediaStore`；
 * - 提交前的懒重传走共享实现 `DraftMediaUploader.prepareDraftMedia`（本类实现其
 *   `DraftUploadHost` 接口提供鉴权与上传能力）。
 */

import { PostAuthResult, PostReplyResult, TopicCategoriesResult } from '../../model/ThreadResult'
import { getTopicCategories } from '../../service/api/ThreadApi'
import { getPostAuth, postNewTopic, uploadAttachment, uploadVideoAttachment } from '../../service/api/ThreadWriteApi'
import {
  MOVING_PHOTO_COVER_NAME,
  MOVING_PHOTO_VIDEO_NAME,
  buildMovingPhotoTag
} from '../../service/api/NgaUploader'
import type { UploadAttachmentResult } from '../../model/NgaApiResults'
import { appStore } from '../../store/AppStore'
import { Logger, DOMAIN_MANAGER } from '../utils/Logger'
import {
  PendingAttachment,
  AttachmentParams,
  appendPendingAttachment,
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

/** 发帖草稿数据（编辑器 `loadDraft` 的返回形态；媒体清单随会话装回，见 `start`）。 */
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
export class NewTopicManagerClass implements DraftUploadHost {
  /** 当前发帖上下文。 */
  private ctx: NewTopicContext = new NewTopicContext()
  /** 缓存的发帖鉴权结果（start 时失效）。 */
  private cachedAuth: PostAuthResult | null = null
  /** 待提交的附件（按上传顺序累积；`start` 清空，提交前按正文引用过滤）。 */
  private pendingAttachments: PendingAttachment[] = []
  /** 当前草稿的媒体清单（本地副本 + 正文标签；随草稿落盘，供懒重传重建凭证）。 */
  private sessionMedia: DraftMedia[] = []
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
    this.pendingAttachments = []
    // 与 ReplyManager.beginSession 同一理由：每次进入编辑器都重新划会话边界，
    // 凭证一并作废（懒重传会用本地副本重建），草稿媒体清单则从草稿里装回
    this.sessionMedia = []
    // 本类同时只有一个编辑器会话：先清掉上一个会话的活跃登记（见 ReplyManager 同名注释）
    draftStore.endAllSessions()
    const key: string = this.draftKey()
    // 活跃键登记（A7）：草稿 JSON 此刻可能还不存在，而媒体副本已经写在
    // `draft_media/<key>/` 下——不登记就会被启动清理当孤儿即时删掉
    draftStore.beginSession(key)
    const draft: EditorDraft | null = draftStore.loadDraft(key)
    if (draft !== null && draft.media.length > 0) {
      this.sessionMedia = draft.media
    }
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
   * 不再回头去读 Picker URI（见 `DraftMediaStore` 文件头的复制 API 契约说明）。
   *
   * @param imageData - 图片二进制数据（既用于上传，也用于落副本）
   * @param fileName - 上传用的原始文件名
   * @returns 上传后的图片 URL
   */
  async uploadImageWithDraft(imageData: ArrayBuffer, fileName: string): Promise<string> {
    const imageUrl: string = await this.uploadImage(imageData, fileName)
    const localPath: string = await draftMediaStore.saveCopy(this.draftKey(), imageData, fileName)
    if (localPath.length === 0) {
      logger.warn('[DRAFT] copy still image failed, re-upload unavailable')
      return imageUrl
    }
    const media: DraftMedia = new DraftMedia()
    media.localPath = localPath
    media.fileName = fileName
    media.url = imageUrl
    media.tag = '[img]./' + imageUrl + '.medium.jpg[/img]'
    this.sessionMedia.push(media)
    return imageUrl
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

  /**
   * 上传一张草稿动态照片：**上传完成后立刻把封面与视频两半都复制进草稿媒体目录**。
   *
   * 复制必须发生在调用方 `finally` 删除导出目录**之前**——那个目录在 `cacheDir` 下，
   * 删掉之后副本来源就没了。
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
    this.sessionMedia.push(media)
    return tag
  }

  /**
   * 判断**当前正文里是否还引用着某个草稿媒体**（B12，与 `ReplyManager` 同构）。
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
   * 并把替换对交给调用方（实现见 `DraftMediaUploader.prepareDraftMedia`）。
   *
   * @param content - 待提交的正文
   * @returns 准备结果；失败时以 `result.error` 说明，`replacements` 里带着已完成的替换
   */
  async ensureDraftMedia(content: string): Promise<PreparedContent> {
    const prepared: PreparedContent = await prepareDraftMedia(this, this.sessionMedia, content)
    if (prepared.changed) {
      logger.info('[NEWTOPIC] draft media re-uploaded count=%{public}d', prepared.reuploaded)
    }
    return prepared
  }

  /**
   * 把重传得到的替换对应用到**当前**正文上（A4；与 `ReplyManager` 同构）。
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
   * 动态照片登记时也用它回填封面/视频地址。
   *
   * @returns 地址数组（按累积顺序）
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
   * 上传一份图片数据（懒重传用）。
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

    // 附件参数按正文引用过滤后拼接（`PostAttachments.buildAttachmentParams`）。
    // 这里不再按"两侧元素个数必须相等"设闸：官方 `L0` 对 `attachments` /
    // `attachments_check` 是各自跳过空元素拼接的（长度允许不等），本地硬拦会误杀
    // 合法形态；真正要防的「正文没引用这张图」在过滤阶段处理。
    const attachParams: AttachmentParams = buildAttachmentParams(this.pendingAttachments, content)
    if (attachParams.dropped > 0) {
      logger.verbose('[NEWTOPIC] dropped %{public}d attachment(s) not referenced by content',
        attachParams.dropped)
    }
    logger.verbose('[NEWTOPIC] submit fid=%{public}d keepAttachments=%{public}d',
      this.ctx.fid, attachParams.kept)

    const result: PostReplyResult = await postNewTopic(
      appStore.auth.token, this.ctx.fid, this.ctx.stid,
      trimmedSubject, content,
      isAnonymous ? 1 : 0,
      attachParams.attachments, attachParams.attachmentsCheck
    )
    if (result.ok) {
      // 附件参数随本次提交被服务端消费，成功后立即丢弃：本类是进程级单例，
      // 留着会让「同一个对话框里重复点发布」这类异常路径把已消费的凭证再提交一次。
      this.pendingAttachments = []
      // 提交成功 = 这份草稿已经变成帖子：草稿 JSON 与媒体副本目录一起回收
      this.clearDraft()
    }
    return result
  }

  /**
   * 保存发帖草稿（标题 + 正文 + 媒体清单）。
   *
   * 标题与正文任一非空、或存在媒体时保存——"只有图片的草稿"与"只有标题的草稿"都必须留住。
   * 媒体是否"算数"由调用方按 `hasReferencedMedia` 判定（B12）。
   *
   * @param subject - 标题
   * @param content - 正文
   */
  saveDraft(subject: string, content: string): void {
    if (subject.trim().length === 0 && content.trim().length === 0 && this.sessionMedia.length === 0) {
      return
    }
    const draft: EditorDraft = new EditorDraft()
    draft.key = this.draftKey()
    draft.subject = subject
    draft.content = content
    draft.media = this.sessionMedia
    if (!draftStore.saveDraft(draft)) {
      logger.warn('[DRAFT] save failed key=%{public}s', draft.key)
    }
  }

  /**
   * 读取发帖草稿。
   *
   * 只回标题与正文：媒体清单不由这里回传，它在 `start()` 里直接装进会话
   * （避免同一份清单存在两条装回路径）。
   *
   * @returns 草稿（标题 + 正文）；无草稿时各字段为空
   */
  loadDraft(): NewTopicDraft {
    const draft: NewTopicDraft = new NewTopicDraft()
    const stored: EditorDraft | null = draftStore.loadDraft(this.draftKey())
    if (stored !== null) {
      draft.subject = stored.subject
      draft.content = stored.content
    }
    return draft
  }

  /**
   * 清除发帖草稿（连同媒体副本目录），并注销会话登记。
   */
  clearDraft(): void {
    const key: string = this.draftKey()
    draftStore.clearDraft(key)
    draftStore.endSession(key)
    draftMediaStore.removeDraftMedia(key)
    this.sessionMedia = []
  }

  /**
   * 发新主题的草稿键（按版块/子版块 + 账号区分；本类没有模式开关，键自然稳定）。
   *
   * 含 **uid 短哈希**：草稿文件不按账号分目录，键里没有 uid 时"换账号后在同一个版块发帖"
   * 会读到上一个账号的草稿与媒体清单。
   *
   * @returns 文件名安全的草稿键
   */
  private draftKey(): string {
    const uidPart: string = draftUidPart(appStore.auth.uid)
    if (this.ctx.stid !== 0) {
      return 'draft_newtopic_' + String(this.ctx.fid) + '_stid' + String(this.ctx.stid) + '_' + uidPart
    }
    return 'draft_newtopic_' + String(this.ctx.fid) + '_' + uidPart
  }
}

export const newTopicManager = new NewTopicManagerClass()
