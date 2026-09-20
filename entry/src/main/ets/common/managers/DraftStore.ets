/**
 * 编辑器草稿持久化存储（回复 / 引用 / 贴条 / 发新主题共用）。
 *
 * ## 为什么需要它
 * 迁移前草稿走 `AppStorage.setOrCreate<string>(key, text)`——**内存态**，进程结束即丢。
 * 也就是说草稿连正文都跨不了重启，更谈不上"草稿里的图片"（那需要媒体副本清单）。
 * 本模块把草稿落成结构化文件，为懒重传（见 `DRAFT_MEDIA_PLAN.md` 阶段 3）提供对应物。
 *
 * ## 落盘形态
 * `filesDir/drafts/<草稿键>.json`，内容为 {@link EditorDraft} 的 JSON 序列化。
 * 采用 `SavedThreadStore` 已验证的「临时文件 + 重命名」原子替换：写失败不会截断旧草稿。
 *
 * ## 为什么不用 PersistentStorage
 * 媒体清单是结构化数组；`PersistentStorage` 只适合标量/简单对象。文件形态还便于按 key
 * 增量清理与统计容量。
 *
 * ## 键与账号
 * 草稿键由调用方（`ReplyManager.draftKey` / `NewTopicManager.draftKey`）给出，形态为
 * `draft_<tid>_p<pid>_<uidHash>` 一类；调用方已把 **uid 短哈希**并入键（见
 * {@link draftUidPart}），因此换账号不会读到上一个账号的草稿（草稿文件不按账号分目录，
 * 靠键隔离）。键的**唯一性判据是"编辑器目标"**，与编辑器的模式开关（回复 / 贴条）
 * 无关——模式开关不改变草稿归属，若把模式并进键，一次编辑会话会在两个键之间漂移，
 * 而媒体副本目录是绑在键上的（见 `DRAFT_MEDIA_PLAN.md` §9.1）。
 *
 * ## 读写都是同步的
 * 草稿体积小（正文 + 媒体清单，KB 级），且在编辑器构建期（`aboutToAppear`）与关闭期
 * 各读写一次，同步 IO 的量级可忽略；换来的是调用方无需把 `loadDraft` 改成异步。
 * 但**只有被访问到的那一份**才会被读进内存（见 `loadDraft`）：`init` 不做全量预热，
 * 冷启动主路径只剩两次 `accessSync` 与一次 `listFileSync`（见 `cleanupStale`）。
 */

import { fileIo } from '@kit.CoreFileKit'
import { Context } from '@kit.AbilityKit'
import { Logger, DOMAIN_STORE, formatError } from '../utils/Logger'

const logger = new Logger(DOMAIN_STORE, 'DraftStore')

/** 草稿目录名（位于应用 `filesDir` 下，持久区，系统不回收）。 */
export const DRAFT_DIR_NAME: string = 'drafts'

/**
 * 草稿 JSON 的保留期（天）。**这是 `maxAgeDays` 的唯一语义**。
 *
 * 名字里刻意不带 `MEDIA`：早先它叫 `DRAFT_MEDIA_MAX_AGE_DAYS` 并被同时当成"媒体兜底阈值"，
 * 而实际生效的是"草稿自身的保留期"——媒体的寿命绑定草稿（见 `DraftMediaStore` 文件头），
 * 从来没有独立的按天淘汰。名字与用途不一致会让下一个人照名字去改媒体语义。
 *
 * 保持 7 天不变（用户确认过这是想要的行为）。
 */
export const DRAFT_RETENTION_DAYS: number = 7

/** 草稿文件后缀。 */
const DRAFT_FILE_SUFFIX: string = '.json'

/** 原子写的临时文件后缀（临时文件不是草稿，扫描时必须排除）。 */
const DRAFT_TMP_SUFFIX: string = '.json.tmp'

/** 草稿键的最大长度（文件名安全的上界）。 */
const MAX_DRAFT_KEY_LENGTH: number = 96

/**
 * 校验草稿键是否可安全用于文件名（与 `DraftMediaStore` 的目录名校验**同一份实现**）。
 *
 * 键是内部生成的（`draft_` + 数字 + 动作 + uid 哈希），必须拒绝路径分隔符与 `..`，
 * 防止任何上游改动把路径穿越带进存档目录。
 *
 * @param key - 待校验的草稿键
 * @returns 是否合法
 */
export function isValidDraftKey(key: string): boolean {
  if (key.length === 0 || key.length > MAX_DRAFT_KEY_LENGTH) {
    return false
  }
  for (let i: number = 0; i < key.length; i++) {
    const c: string = key.charAt(i)
    const isDigit: boolean = c >= '0' && c <= '9'
    const isLower: boolean = c >= 'a' && c <= 'z'
    const isUpper: boolean = c >= 'A' && c <= 'Z'
    if (!isDigit && !isLower && !isUpper && c !== '_') {
      return false
    }
  }
  return true
}

/**
 * 计算字符串的 FNV-1a 32 位短哈希（36 进制）。
 *
 * 用于把登录 uid 带进草稿键：草稿文件不按账号分目录，键里没有 uid 时"换账号后在同一个
 * 帖子回复"会读到上一个账号的草稿。与官方 `ActionCheck.buildActionId = uid + "/" + fid + ...`
 * 同构，取哈希只是为了不让 uid 明文出现在文件名里。
 *
 * 结果用 **`>>> 0` 转无符号**再转 36 进制。不要写 `if (hash < 0) hash = -hash`：符号位为 1
 * 时取绝对值会把 `0x80000000` 映射到 `0`（标准 `Math.abs` 陷阱），两个不同 uid 撞到同一个
 * 键就绕过了账号隔离——而账号隔离是这条链路上唯一的防线（键是唯一的隔离维度）。
 *
 * @param value - 待哈希字符串
 * @returns 36 进制短哈希（非负）
 */
export function shortHash36(value: string): string {
  let hash: number = 0x811c9dc5
  for (let i: number = 0; i < value.length; i++) {
    hash = hash ^ value.charCodeAt(i)
    hash = (hash * 0x01000193) | 0
  }
  return (hash >>> 0).toString(36)
}

/**
 * 草稿键里的账号片段（登录用 uid 短哈希，未登录用 `anon`）。
 *
 * @param uid - 当前登录 uid（空串表示未登录）
 * @returns 文件名安全的账号片段
 */
export function draftUidPart(uid: string): string {
  return uid.length > 0 ? shortHash36(uid) : 'anon'
}

/**
 * 草稿里的一条媒体：本地副本 + 它在正文中的标签。
 *
 * `localPath` / `videoLocalPath` 是**沙箱持久区副本**的绝对路径（`filesDir/draft_media/...`）。
 * 必须复制一份的原因**不是**"Picker URI 不可用"（`photoUris` 其实带持久授权，早期文档里的
 * 那个说法不成立），而是：动态照片的**视频半边根本没有持久 URI**（只由 `requestContent`
 * 落在 `cacheDir`，上传结束后整目录删除），且媒体资产可能被用户删除或改名。
 */
export class DraftMedia {
  /** 静态图（或动态照片封面）的沙箱副本绝对路径。 */
  localPath: string = ''

  /** 该媒体当前插入正文的 URL 片段（重传后据此定位并原地替换标签）。 */
  tag: string = ''

  /** 动态照片的视频半边副本路径；静态图为空串。 */
  videoLocalPath: string = ''

  /** 动态照片的视频半边 URL 片段；静态图为空串。 */
  videoTag: string = ''

  /** 上传得到的 URL（重传后覆盖）。 */
  url: string = ''

  /** 动态照片视频半边的上传 URL；静态图为空串。 */
  videoUrl: string = ''

  /** 上传时使用的原始文件名。 */
  fileName: string = ''

  /** 视频半边上传时使用的原始文件名（动态照片固定 `video.mp4`）。 */
  videoFileName: string = ''
}

/** 一份编辑器草稿（持久化形态）。 */
export class EditorDraft {
  /** 草稿键（沿用现有 draftKey 形态，文件名安全）。 */
  key: string = ''

  /** 正文（发帖另存标题）。 */
  content: string = ''

  /** 标题（仅发新主题使用）。 */
  subject: string = ''

  /** 媒体清单。 */
  media: DraftMedia[] = []

  /** 最后更新时间（epoch ms）。 */
  updatedAt: number = 0
}

/** 一份草稿文件的清理批次结果。 */
export class DraftCleanupBatch {
  /** 本批被删除的草稿键（供调用方级联清理媒体目录）。 */
  removed: string[] = []

  /** 是否还有未被检查的草稿文件（true 表示可以再跑一批）。 */
  hasMore: boolean = false
}

/**
 * 草稿存储（进程级单例，随 `AppStore.init` 初始化）。
 */
export class DraftStore {
  /** 应用上下文；未初始化时为空。 */
  private context: Context | null = null

  /** 草稿目录绝对路径。 */
  private dirPath: string = ''

  /**
   * 内存缓存（key → 草稿）。
   *
   * **按需填充**：`init` 不扫描目录内容（冷启动只做两次 `accessSync`），第一次
   * `loadDraft(key)` 时才把那一份读进来；`saveDraft` 写入后同步更新。
   * 编辑器构建期需要**同步**读草稿（`loadDraft` 的既有签名），所以缓存不能省，但预热可以省。
   */
  private items: Map<string, EditorDraft> = new Map<string, EditorDraft>()

  /**
   * 正在编辑的草稿键（**活跃键登记**）。
   *
   * 编辑器开启会话时登记（`beginSession`），`clearDraft` / 提交成功时注销。它是
   * `DraftMediaStore.cleanupStale` 的**硬豁免名单**：活跃会话的草稿 JSON 可能还没落盘
   * （用户正在打字、媒体副本却已经写好了），此时该键既不在 `listKeys()` 里、
   * 也不该被判为孤儿删掉——副本是唯一来源，删了用户发送时就撞硬失败。
   *
   * 用数组而不是 `Map`：编辑器会话最多一两个，线性查找的常数比哈希小，
   * 且数组形态在 ArkTS 里没有 `Record` 索引返回 `undefined` 那类麻烦。
   */
  private activeKeys: string[] = []

  /**
   * 分批清理的游标（上一批处理到的文件名）。
   *
   * A8：早先的实现每批都从 `names[0]` 重新开始，前几个草稿都没超期时每批重复检查同一批、
   * `hasMore` 恒为 true，4 轮用尽即结束——**第 9 个之后的超期草稿永远清不掉**。
   * 游标保证逐批**向前推进**；跑完一整趟后重置，下次启动从干净的一趟重新开始。
   */
  private cleanupCursor: string = ''

  /**
   * 初始化：建立目录。
   *
   * **不做全量预热**：草稿数量理论上无上限，冷启动逐份 `readTextSync` + `JSON.parse`
   * 是纯浪费（绝大多数草稿本次启动根本不会被打开）。目录内容在首次访问时按需读取。
   *
   * @param context 应用上下文（提供 `filesDir`）
   */
  async init(context: Context): Promise<void> {
    this.context = context
    this.dirPath = context.filesDir + '/' + DRAFT_DIR_NAME
    try {
      if (!fileIo.accessSync(this.dirPath)) {
        fileIo.mkdirSync(this.dirPath, true)
      }
    } catch (e) {
      logger.error('init mkdir failed: %{public}s', formatError(e))
    }
    this.items = new Map<string, EditorDraft>()
    this.activeKeys = []
    this.cleanupCursor = ''
  }

  /** 返回草稿目录绝对路径（清理接线用；未初始化时为空串）。 */
  get directory(): string {
    return this.dirPath
  }

  /**
   * 返回草稿键对应的文件绝对路径。
   *
   * @param key - 草稿键
   * @returns 文件绝对路径
   */
  private filePathOf(key: string): string {
    return this.dirPath + '/' + key + DRAFT_FILE_SUFFIX
  }

  /**
   * 读取一份草稿。
   *
   * 读到的那一份会做**元素级**字段补全（见 {@link normalizeMedia}）：磁盘上的 JSON 可能是
   * 旧版本写的、也可能被外部工具改坏，缺字段的元素留在清单里会让后续的 `.length` /
   * `indexOf` 抛 TypeError，并被上层吞成"草稿图片处理失败"——草稿还在，却永远发不出去。
   * 补不了关键字段（清单不是数组）的文件按损坏处理：记 warn 并删掉，不让它每次都被重读。
   *
   * @param key - 草稿键
   * @returns 草稿；不存在或损坏时返回 null
   */
  loadDraft(key: string): EditorDraft | null {
    if (!isValidDraftKey(key)) {
      return null
    }
    const cached: EditorDraft | undefined = this.items.get(key)
    if (cached !== undefined) {
      return cached
    }
    // 未命中即从磁盘读这一份（`init` 不做全量预热，见其注释）
    if (this.context === null) {
      return null
    }
    const path: string = this.filePathOf(key)
    try {
      if (!fileIo.accessSync(path)) {
        return null
      }
      const parsed: EditorDraft = JSON.parse(fileIo.readTextSync(path)) as EditorDraft
      if (parsed === null || parsed === undefined) {
        this.discardCorrupt(key, 'json is null')
        return null
      }
      const media: DraftMedia[] | null = normalizeMedia(key, parsed.media)
      if (media === null) {
        this.discardCorrupt(key, 'media is not an array')
        return null
      }
      parsed.key = key
      parsed.media = media
      if (typeof parsed.content !== 'string') {
        // 正文缺失/类型不符：补成空串（老版本或半截文件），不因为一个字段丢掉整份草稿
        logger.warn('loadDraft content not a string key=%{public}s, treated as empty', key)
        parsed.content = ''
      }
      if (typeof parsed.subject !== 'string') {
        parsed.subject = ''
      }
      this.items.set(key, parsed)
      return parsed
    } catch (e) {
      logger.warn('loadDraft failed key=%{public}s: %{public}s', key, formatError(e))
    }
    return null
  }

  /**
   * 处理一份读不出来的草稿：记 warn 并删除文件。
   *
   * 不删就会每次打开编辑器都重读一遍同一份坏文件（且每次都只记一条同样的日志），
   * 用户永远看不到内容、也永远清不掉它。
   *
   * @param key - 草稿键
   * @param reason - 损坏原因（写进日志）
   */
  private discardCorrupt(key: string, reason: string): void {
    logger.warn('draft file corrupt, removing key=%{public}s reason=%{public}s', key, reason)
    this.clearDraft(key)
  }

  /**
   * 写入（覆盖）一份草稿。
   *
   * 原子写：先写 `<key>.json.tmp`，成功后再重命名替换目标文件；写失败时旧草稿保持完整。
   * 写盘是同步的（见文件头「读写都是同步的」）。
   *
   * @param draft - 待保存的草稿
   * @returns 是否写入成功
   */
  saveDraft(draft: EditorDraft): boolean {
    if (this.context === null || !isValidDraftKey(draft.key)) {
      return false
    }
    draft.updatedAt = Date.now()
    const path: string = this.filePathOf(draft.key)
    const tmpPath: string = path + '.tmp'
    try {
      const file: fileIo.File = fileIo.openSync(tmpPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC)
      try {
        fileIo.writeSync(file.fd, JSON.stringify(draft))
      } finally {
        fileIo.closeSync(file)
      }
      fileIo.renameSync(tmpPath, path)
    } catch (e) {
      logger.error('saveDraft failed key=%{public}s: %{public}s', draft.key, formatError(e))
      try {
        if (fileIo.accessSync(tmpPath)) {
          fileIo.unlinkSync(tmpPath)
        }
      } catch (cleanupError) {
        logger.verbose('saveDraft cleanup failed: %{public}s', formatError(cleanupError))
      }
      return false
    }
    // 缓存存**深拷贝**：调用方（manager）会继续持有并原地改自己那份（重传会改 url/tag），
    // 缓存若共享同一批 DraftMedia 对象，就会被它带着变——下次 `loadDraft` 命中的是"未来态"，
    // 而不是磁盘上的实际内容。
    const cached: EditorDraft = new EditorDraft()
    cached.key = draft.key
    cached.content = draft.content
    cached.subject = draft.subject
    cached.media = cloneMedia(draft.media)
    cached.updatedAt = draft.updatedAt
    this.items.set(draft.key, cached)
    return true
  }

  /**
   * 删除一份草稿（连同内存缓存），并注销它的活跃登记。
   *
   * @param key - 草稿键
   */
  clearDraft(key: string): void {
    if (!isValidDraftKey(key)) {
      return
    }
    try {
      const path: string = this.filePathOf(key)
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path)
      }
    } catch (e) {
      logger.error('clearDraft failed key=%{public}s: %{public}s', key, formatError(e))
    }
    this.items.delete(key)
    this.endSession(key)
  }

  // ============== 活跃键登记（DraftMediaStore 的删除豁免名单） ==============

  /**
   * 登记一个正在编辑的草稿键。
   *
   * 由编辑器会话起点调用（`ReplyManager.beginSession` / `NewTopicManager.start`）。
   * 重复登记同一个键是幂等的（会话来回复用同一个键是正常的）。
   *
   * @param key - 草稿键
   */
  beginSession(key: string): void {
    if (!isValidDraftKey(key) || this.isActive(key)) {
      return
    }
    this.activeKeys.push(key)
    logger.verbose('beginSession key=%{public}s active=%{public}d', key, this.activeKeys.length)
  }

  /**
   * 注销一个草稿键的活跃登记。
   *
   * @param key - 草稿键
   */
  endSession(key: string): void {
    const index: number = this.activeKeys.indexOf(key)
    if (index >= 0) {
      this.activeKeys.splice(index, 1)
    }
  }

  /** 注销全部活跃登记（清缓存 / 重置时用，避免登记表残留已不存在的键）。 */
  endAllSessions(): void {
    this.activeKeys = []
  }

  /**
   * 判断某个键当前是否有编辑器会话。
   *
   * @param key - 草稿键
   * @returns 是否正在编辑
   */
  isActive(key: string): boolean {
    return this.activeKeys.indexOf(key) >= 0
  }

  /**
   * 返回当前全部活跃键（`DraftMediaStore.cleanupStale` 的豁免输入）。
   *
   * @returns 活跃键数组（副本，调用方改它不影响登记表）
   */
  activeKeyList(): string[] {
    return this.activeKeys.slice()
  }

  /**
   * 返回草稿目录里**全部**草稿键。
   *
   * 走目录扫描而不是内存缓存：缓存是**按需填充**的（见 `items` 的注释），
   * 只信缓存会把"还没被打开过的草稿"漏掉，进而让 `DraftMediaStore.cleanupStale`
   * 把它们当作孤儿媒体目录删掉。
   *
   * @returns 草稿键数组
   */
  listKeys(): string[] {
    const keys: string[] = []
    if (this.context === null) {
      return keys
    }
    try {
      const names: string[] = fileIo.listFileSync(this.dirPath)
      for (let i: number = 0; i < names.length; i++) {
        const key: string = draftKeyOfFileName(names[i])
        if (key.length > 0 && !containsString(keys, key)) {
          keys.push(key)
        }
      }
    } catch (e) {
      logger.verbose('listKeys failed: %{public}s', formatError(e))
    }
    return keys
  }

  /**
   * 判断某个键是否还有草稿文件（`DraftMediaStore` 删除副本前的**当次确认**）。
   *
   * 不能用启动时算出的 `listKeys()` 快照代替：清理跑在启动后 800ms，期间用户完全可能
   * 打开编辑器并落下一份新草稿——快照里没有它，它的媒体目录就会被当孤儿删掉。
   *
   * @param key - 草稿键
   * @returns 文件是否存在
   */
  hasDraftFile(key: string): boolean {
    if (this.context === null || !isValidDraftKey(key)) {
      return false
    }
    try {
      return fileIo.accessSync(this.filePathOf(key))
    } catch (e) {
      return false
    }
  }

  /**
   * **一批**超期草稿的清理。
   *
   * 分批是为了冷启动：清理跑在应用启动路径上，逐文件 `statSync` + `unlinkSync` 全是主线程
   * 同步 IO。正常情况下草稿数是 0 到几个、一次就清完；只有在异常路径把目录撑大时才会分批
   * 消化（与 `MovingPhotoExport.pruneStaleExports` 的 `MAX_PRUNE_PER_RUN` 同一考虑）。
   *
   * 游标语义（A8）：本批从上一批的**下一个**文件名继续，逐批向前推进；文件名由
   * `listFileSync` 给出（同一目录内容下顺序稳定），因此不会漏也不会重。
   * `hasMore` 只按「本批是否因为 `maxPerRun` 提前收手」判定——早先的实现拿
   * `names.length > examined` 当分母，把目录与 `.json.tmp` 也算进去，于是空跑好几批。
   *
   * @param maxAgeDays - 最长保留天数（<=0 表示不清理；正常调用传 `DRAFT_RETENTION_DAYS`）
   * @param maxPerRun - 本次最多检查的**草稿**文件数
   * @returns 本批结果：删除的草稿键 + 是否还有未检查的条目
   */
  cleanupStale(maxAgeDays: number, maxPerRun: number): DraftCleanupBatch {
    const batch: DraftCleanupBatch = new DraftCleanupBatch()
    if (this.context === null || maxAgeDays <= 0 || maxPerRun <= 0) {
      return batch
    }
    this.sweepTempFiles()
    const cutoffSeconds: number = Date.now() / 1000 - maxAgeDays * 86400
    try {
      const names: string[] = fileIo.listFileSync(this.dirPath)
      names.sort()
      let start: number = 0
      if (this.cleanupCursor.length > 0) {
        start = names.length
        for (let i: number = 0; i < names.length; i++) {
          if (names[i] > this.cleanupCursor) {
            start = i
            break
          }
        }
      }
      let examined: number = 0
      // 游标注到**扫过的**最后一个名字（含目录/`.tmp`/非法键），否则一批以非草稿项收尾时
      // 游标不动、下一批会从头重来——那正是 A8 要消灭的"原地打转"
      let lastScanned: string = this.cleanupCursor
      let index: number = start
      while (index < names.length && examined < maxPerRun) {
        const name: string = names[index]
        index++
        lastScanned = name
        const key: string = draftKeyOfFileName(name)
        if (key.length === 0) {
          // 目录 / `.json.tmp` / 非法键：不是草稿，不占配额
          continue
        }
        examined++
        const path: string = this.dirPath + '/' + name
        try {
          if (fileIo.statSync(path).mtime < cutoffSeconds) {
            fileIo.unlinkSync(path)
            this.items.delete(key)
            this.endSession(key)
            batch.removed.push(key)
          }
        } catch (e) {
          logger.verbose('cleanupStale entry failed: %{public}s', formatError(e))
        }
      }
      if (examined >= maxPerRun && index < names.length) {
        batch.hasMore = true
        this.cleanupCursor = lastScanned
      } else {
        // 本趟走完：重置游标，下次启动从干净的一趟重新开始（新生草稿因此必被检查一次）
        this.cleanupCursor = ''
      }
    } catch (e) {
      logger.error('cleanupStale failed: %{public}s', formatError(e))
    }
    if (batch.removed.length > 0) {
      logger.info('cleanupStale removed %{public}d draft(s)', batch.removed.length)
    }
    return batch
  }

  /**
   * 回收原子写留下的 `.json.tmp` 残渣。
   *
   * `saveDraft` 的失败分支会删自己的临时文件，但**进程在写盘途中被杀**时它没机会跑，
   * 于是留下一个永远不会被读、也永远不会被清的 `.json.tmp`（旧实现的 `clearAll` 只按
   * `.json` 后缀匹配，`listKeys` 同样跳过它）。清理跑在启动路径上，顺手扫掉。
   */
  private sweepTempFiles(): void {
    try {
      const names: string[] = fileIo.listFileSync(this.dirPath)
      for (let i: number = 0; i < names.length; i++) {
        if (names[i].endsWith(DRAFT_TMP_SUFFIX)) {
          const path: string = this.dirPath + '/' + names[i]
          try {
            fileIo.unlinkSync(path)
            logger.info('removed stale temp draft file %{public}s', names[i])
          } catch (e) {
            logger.verbose('temp cleanup failed: %{public}s', formatError(e))
          }
        }
      }
    } catch (e) {
      logger.verbose('sweepTempFiles failed: %{public}s', formatError(e))
    }
  }

  /**
   * 目录被外部整目录删除后，重置内存缓存。
   *
   * `SettingsPanel.clearCache` 直接递归删目录（不经过本类），缓存里的草稿副本仍在，
   * 不清就会在本次进程内"复活"已经被删掉的草稿。重建目录以免后续 `saveDraft` 失败；
   * 活跃键登记同时清空（那些键已经没有任何文件了）。
   */
  reloadAfterClear(): void {
    this.items = new Map<string, EditorDraft>()
    this.endAllSessions()
    this.cleanupCursor = ''
    if (this.context === null) {
      return
    }
    try {
      if (!fileIo.accessSync(this.dirPath)) {
        fileIo.mkdirSync(this.dirPath, true)
      }
    } catch (e) {
      logger.error('reloadAfterClear mkdir failed: %{public}s', formatError(e))
    }
  }

  /**
   * 返回草稿目录占用的总字节数。
   *
   * 「清除缓存」的容量徽标用它（`bundleStats.cacheSize` **只统计 `cacheDir`**，
   * 而草稿在 `filesDir` 下，不并进来用户就看不到这块占用）。
   *
   * @returns 总字节数（目录不可用时为 0）
   */
  totalBytes(): number {
    let total: number = 0
    if (this.context === null) {
      return total
    }
    try {
      const names: string[] = fileIo.listFileSync(this.dirPath)
      for (let i: number = 0; i < names.length; i++) {
        try {
          const stat: fileIo.Stat = fileIo.statSync(this.dirPath + '/' + names[i])
          if (!stat.isDirectory()) {
            total += stat.size
          }
        } catch (e) {
          /* 单个文件 stat 失败不影响统计（可能正被并发删除） */
        }
      }
    } catch (e) {
      logger.verbose('totalBytes failed: %{public}s', formatError(e))
    }
    return total
  }
}

/**
 * 从目录项名解析草稿键。
 *
 * 只接受 `<合法键>.json`：目录、`.json.tmp`（原子写残渣）与非法键一律返回空串，
 * 让调用方能把"不是草稿的东西"排除在计数与清理之外。
 *
 * @param name - `listFileSync` 给出的目录项名
 * @returns 草稿键；不是草稿时为空串
 */
function draftKeyOfFileName(name: string): string {
  if (!name.endsWith(DRAFT_FILE_SUFFIX) || name.endsWith(DRAFT_TMP_SUFFIX)) {
    return ''
  }
  const key: string = name.substring(0, name.length - DRAFT_FILE_SUFFIX.length)
  return isValidDraftKey(key) ? key : ''
}

/**
 * 判断字符串是否在数组中（不用 `Array.prototype.includes`，与工程其它模块风格一致）。
 *
 * @param values - 数组
 * @param value - 待查值
 * @returns 是否存在
 */
function containsString(values: string[], value: string): boolean {
  for (let i: number = 0; i < values.length; i++) {
    if (values[i] === value) {
      return true
    }
  }
  return false
}

/**
 * 元素级校验草稿媒体清单。
 *
 * 每个元素逐字段补全（缺字段/类型不符 → 空串）；元素本身不是对象则丢弃该元素并记 warn，
 * 而不是让整份草稿失效——丢掉一条媒体的后果是"这张图失去懒重传能力"，
 * 丢掉整份草稿的后果是"用户写的正文没了"。
 *
 * @param key - 草稿键（仅用于日志）
 * @param raw - 从 JSON 里读出来的 `media` 字段
 * @returns 归一化后的清单；`raw` 不是数组时返回 null（调用方按损坏处理）
 */
function normalizeMedia(key: string, raw: DraftMedia[] | null | undefined): DraftMedia[] | null {
  if (raw === null || raw === undefined) {
    // 老版本草稿可能根本没有 media 字段：按"没有媒体"处理（不是损坏，文件保留），
    // 但要留一条 warn —— 正常写盘路径永远会带上 media（哪怕是空数组），
    // 这里命中说明文件来自旧版本或被外部改过，排查草稿问题时需要这个线索。
    logger.warn('draft has no media field, treated as empty (key=%{public}s)', key)
    return []
  }
  if (!Array.isArray(raw)) {
    return null
  }
  const out: DraftMedia[] = []
  for (let i: number = 0; i < raw.length; i++) {
    const item: DraftMedia = raw[i]
    if (item === null || item === undefined || typeof item !== 'object') {
      logger.warn('draft media[%{public}d] is not an object, dropped (key=%{public}s)', i, key)
      continue
    }
    out.push(normalizeMediaItem(item))
  }
  return out
}

/**
 * 归一条草稿媒体：逐字段保证是字符串。
 *
 * @param item - 磁盘上读出的元素
 * @returns 字段齐备的媒体
 */
function normalizeMediaItem(item: DraftMedia): DraftMedia {
  const media: DraftMedia = new DraftMedia()
  media.localPath = asString(item.localPath)
  media.tag = asString(item.tag)
  media.videoLocalPath = asString(item.videoLocalPath)
  media.videoTag = asString(item.videoTag)
  media.url = asString(item.url)
  media.videoUrl = asString(item.videoUrl)
  media.fileName = asString(item.fileName)
  media.videoFileName = asString(item.videoFileName)
  return media
}

/**
 * 逐项深拷贝草稿媒体清单（缓存与调用方各持一份，见 `saveDraft` 的注释）。
 *
 * @param media - 源清单
 * @returns 新清单（元素也是新对象）
 */
function cloneMedia(media: DraftMedia[]): DraftMedia[] {
  const out: DraftMedia[] = []
  for (let i: number = 0; i < media.length; i++) {
    const source: DraftMedia = media[i]
    const copy: DraftMedia = new DraftMedia()
    copy.localPath = source.localPath
    copy.tag = source.tag
    copy.videoLocalPath = source.videoLocalPath
    copy.videoTag = source.videoTag
    copy.url = source.url
    copy.videoUrl = source.videoUrl
    copy.fileName = source.fileName
    copy.videoFileName = source.videoFileName
    out.push(copy)
  }
  return out
}

/**
 * 把任意值收敛成字符串（缺字段/类型不符 → 空串）。
 *
 * @param value - 待收敛的值
 * @returns 字符串
 */
function asString(value: string | null | undefined): string {
  return typeof value === 'string' ? value : ''
}

/** 草稿存储单例（与 `replyManager` / `newTopicManager` 同级共享）。 */
export const draftStore = new DraftStore()
