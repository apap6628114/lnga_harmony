import { http } from '@kit.NetworkKit'
import { fileIo } from '@kit.CoreFileKit'
import { photoAccessHelper, MovingPhotoView, MovingPhotoViewController } from '@kit.MediaLibraryKit'
import { AppColors } from '../constants/Constants'
import { UIMaterialManager } from '../managers/UIMaterialManager'
import { Logger, DOMAIN_UI, formatError } from '../utils/Logger'
import { PageScope } from '../concurrency/PageScope'
import { movingPhotoCacheDir } from './MovingPhotoCache'

const logger = new Logger(DOMAIN_UI, 'MovingPhotoPlayer')

/** 缓存文件数上限：超过后按修改时间淘汰最旧的一半（不是全清空）。 */
const MAX_CACHE_FILES: number = 120

/** 发出 `startPlayback()` 后等待 `onStart` 的上限：超时视为播放器未就绪（打空），复位图标。 */
const PLAYBACK_START_TIMEOUT_MS: number = 2500

/** `onStart` 之后等待结束事件的上限：官方限动态照片视频 ≤10s，留足余量后兜底复位。 */
const PLAYBACK_TIMEOUT_MS: number = 15000

/** 就绪后自动播放/排队播放的兜底延迟（`onPrepared` 通常在 200ms 内到达）。 */
const AUTO_PLAY_FALLBACK_MS: number = 1200

/** 准备中：正在下载封面/视频并构造 MovingPhoto。 */
const PHASE_LOADING: string = 'loading'
/** 就绪：停在静态封面，图标常态，可点击播放。 */
const PHASE_READY: string = 'ready'
/** 播放中：图标高亮，点击不响应（不重播、不终止）。 */
const PHASE_PLAYING: string = 'playing'
/** 失败：保持静态封面且不显示图标（不误导用户可播放）。 */
const PHASE_FAILED: string = 'failed'

/**
 * 计算 URL 的稳定短哈希，用于沙箱缓存文件名。
 *
 * FNV-1a 32 位 + URL 长度前缀：只用哈希不用原 URL 作文件名（NGA 附件名可能带
 * 查询串与特殊字符，直接落盘有非法字符与超长风险），长度前缀进一步降低不同 URL
 * 命中同一缓存文件的概率（纯 32 位截断哈希存在静默串图风险）。
 *
 * @param url 资源地址
 * @returns 36 进制哈希字符串
 */
function hashUrl(url: string): string {
  let hash: number = 0x811c9dc5
  for (let i: number = 0; i < url.length; i++) {
    hash = hash ^ url.charCodeAt(i)
    hash = (hash * 0x01000193) | 0
  }
  if (hash < 0) {
    hash = -hash
  }
  return `${url.length.toString(36)}${hash.toString(36)}`
}

/**
 * 取 URL 的扩展名（小写、不含点）。
 *
 * @param url 资源地址
 * @param fallback 无法识别时的回退扩展名
 * @returns 扩展名
 */
function extensionOf(url: string, fallback: string): string {
  const match: RegExpMatchArray | null = url.match(/\.(\w{2,5})(?:[?#]|$)/)
  if (match === null) {
    return fallback
  }
  const ext: string = match[1].toLowerCase()
  if (ext === 'jpeg') {
    return 'jpg'
  }
  return ext
}

/**
 * 进行中的下载表（目标文件路径 → 下载 Promise）。
 *
 * 同一资源可能被多个组件同时需要（查看器相邻两张都是动态照片时 `@Watch` 会触发两次；
 * 正文就地播放下载中又打开查看器），若各自以目标文件名直接写，后到者会读到**尚未写完**
 * 的文件并把坏文件永久留在缓存里，失败分支还会删掉别人正在用的文件。
 */
const inFlightDownloads: Map<string, Promise<boolean>> = new Map<string, Promise<boolean>>()

/** 缓存淘汰项（文件路径 + 修改时间）。 */
class CacheEntry {
  /** 文件绝对路径。 */
  path: string = ''
  /** 修改时间（秒，`fileIo.Stat.mtime`）。 */
  mtime: number = 0

  /**
   * @param path 文件绝对路径
   * @param mtime 修改时间（秒）
   */
  constructor(path: string, mtime: number) {
    this.path = path
    this.mtime = mtime
  }
}

/**
 * 全局播放仲裁器。
 *
 * `MovingPhotoView` 内部使用 AVPlayer，官方不建议同时开启超过 3 个；而楼层列表是
 * `LazyForEach` + `cachedCount`，滚出屏幕但在缓存窗口内的组件不会销毁 —— 逐个点开
 * 多个楼层的动态照片就会累积播放器实例。这里收紧到"同一时刻只有一个持有者"：
 * 新持有者出现时，前一个立即停播并收起（正文回到静态封面）。
 */
class PlaybackArbiter {
  /** 当前持有者标识。 */
  private ownerId: string = ''
  /** 当前持有者的停止回调。 */
  private stopHandler: (() => void) | null = null

  /**
   * 申请播放权（会先让上一个持有者停止）。
   *
   * @param ownerId 持有者标识（用封面地址即可：同一资源天然互斥）
   * @param stop 持有者被抢占时的停止回调
   */
  acquire(ownerId: string, stop: () => void): void {
    if (this.ownerId.length > 0 && this.ownerId !== ownerId) {
      const previous: (() => void) | null = this.stopHandler
      this.ownerId = ''
      this.stopHandler = null
      if (previous !== null) {
        previous()
      }
    }
    this.ownerId = ownerId
    this.stopHandler = stop
  }

  /**
   * 释放播放权（仅当自己仍是持有者时生效）。
   *
   * @param ownerId 持有者标识
   */
  release(ownerId: string): void {
    if (this.ownerId === ownerId) {
      this.ownerId = ''
      this.stopHandler = null
    }
  }
}

const arbiter: PlaybackArbiter = new PlaybackArbiter()

/**
 * 鸿蒙动态照片播放器（NGA `[b]MPHOTO[/b]` 动态照片）。
 *
 * ## 数据来源
 * NGA 动态照片在正文里是成对出现的「封面图 + 短视频」两个资源；
 * `MovingPhotoView` 只接收 `MediaAssetManager.loadMovingPhoto` 构造的
 * `MovingPhoto`（**仅支持应用沙箱内成对的两个文件，不接受网络 URL**），因此本组件：
 * 下载两份资源到 `filesDir/mphoto/` → `loadMovingPhoto` → `MovingPhotoView`。
 *
 * ## 播放状态机（UI 契约）
 * ```
 * loading ──成功──▶ ready ──onPrepared 后播放──▶ playing ──播完──▶ ready
 *    └──失败──▶ failed（只留静态封面，不显示图标）
 * ```
 * **关键时序**：`onComplete`（图片就绪）→ `onPrepared`（播放器就绪）→ 才能 `startPlayback()`；
 * 真机实测两者相差约 150ms，在 `onComplete` 里播放会静默打空（详见 `pendingAutoPlay` 注释）。
 * 且 `startPlayback()` 之后必须等 `onStart` 才算真的在播（见 `playRequested`）。
 *
 * ## 交互契约
 * - **静态封面常驻、播放器叠层**（本组件与正文渲染层共同遵守的防闪烁契约）：封面 `Image`
 *   自挂载起一直在树上，`MovingPhotoView` 只在就绪后**叠**上去，绝不用 `if/else` 在两者
 *   之间换枝。换枝会销毁并重建封面节点，重新解码期间出现空白帧——这正是"播放态 ↔ 未播放态
 *   切换闪一下"的成因。本体（`build`）与正文（`BBCodeContentView.RenderImageContent`）
 *   两处都按此写法，改动其一时另一处必须同步。
 * - **图标常驻**左上角（由父组件用 `iconLeft/iconTop` 决定贴图片还是贴内容区）：
 *   loading 半透明、ready 常态白、playing 高亮主题色、failed 不显示。
 * - **图标带圆形底板**（半透明黑 + 1vp 细描边）：图标叠在图片内容上，没有底板时图形直接
 *   和画面纹理混在一起、读不出"这是个按钮"；底板参数与正文静态角标完全一致（见 7.3）。
 * - **图标是唯一的播放入口**：图片本体的**长按**不注册操作（`hitTestBehavior(None)`
 *   同时屏蔽了 `MovingPhotoView` 自带的长按播放）；图片**点击**由根节点透传给父组件的
 *   `onBodyClick`（帖子内用于打开查看器；查看器内不传回调即点击无操作）。
 * - **只有 ready 响应图标点击**：playing 期间点击一律忽略——既不重播也不终止。
 * - **播放一次**：`autoPlay(false)` + `repeatPlay(false)` 下 `startPlayback()`
 *   即"播放一遍后回到静态封面"（官方语义），不会循环。
 *
 * ## 已知约束（官方声明）
 * `MovingPhotoView` 不支持预览器与 `expandSafeArea`，内部使用 AVPlayer 且同时开启
 * 不建议超过 3 个；事件回调不带参数（拿不到错误码，只能靠 Promise rejection 定位）；
 * `MovingPhoto` 接口没有 `release`，重复构造的 native 资源依赖 GC。
 */
@Component
export struct MovingPhotoPlayer {
  /** 封面图地址。 */
  @Prop @Watch('onSourceChanged') coverUrl: string = ''
  /** 动态视频地址。 */
  @Prop @Watch('onSourceChanged') videoUrl: string = ''
  /** 图标按钮边长（vp）。 */
  @Prop iconSize: number = 40
  /** 图标距容器顶部距离（vp）。 */
  @Prop iconTop: number = 10
  /** 图标距容器左侧距离（vp）。 */
  @Prop iconLeft: number = 10
  /** 就绪后是否自动播放一次（帖子内点图标展开播放器时用）。 */
  @Prop autoPlayOnce: boolean = false

  /** 播放结束/被抢占回调（帖子内用于收起就地播放器、回到静态封面）。 */
  onPlaybackFinish: () => void = () => {}

  /** 图片本体点击回调（帖子内用于打开查看器；查看器内不传，点击即无操作）。 */
  onBodyClick: () => void = () => {}

  /** 当前播放阶段（loading / ready / playing / failed）。 */
  @State private phase: string = PHASE_LOADING
  /** 构造完成的动态照片对象；为空表示尚未准备就绪。 */
  @State private movingPhoto: photoAccessHelper.MovingPhoto | undefined = undefined

  /** 播放控制器（一个控制器对应一个组件）。 */
  private controller: MovingPhotoViewController = new MovingPhotoViewController()
  /** 组件存活会话作用域（代际校验，防止快速切图时旧结果覆盖新源）。 */
  private scope: PageScope = new PageScope()
  /**
   * 待播放标记（自动播放或加载中点击排队）。
   *
   * 播放**只能**在 `onPrepared`（播放器就绪）之后触发：真机实测 `onComplete`
   * （图片就绪）比 `onPrepared` 早约 150ms，在 `onComplete` 里调用
   * `controller.startPlayback()` 会打空——图标进入"播放中"但画面不动、`onFinish`
   * 永不触发。因此这里只做标记，由 `onPrepared` 消费，并配兜底定时器。
   */
  private pendingAutoPlay: boolean = false
  /** 已发出 `startPlayback()`、尚未收到 `onStart` 确认（用于识别"打空"）。 */
  private playRequested: boolean = false
  /** 播放/启动看门狗。 */
  private playWatchdog: number = -1
  /** 待播放兜底定时器。 */
  private pendingTimer: number = -1

  /** 组件出现时开始准备动态照片。 */
  aboutToAppear(): void {
    this.scope.begin()
    this.prepare()
  }

  /** 组件消失时结束会话、释放播放权并停止播放。 */
  aboutToDisappear(): void {
    this.scope.end()
    arbiter.release(this.coverUrl)
    this.pendingAutoPlay = false
    this.clearPendingTimer()
    this.clearWatchdog()
    this.safeStop()
  }

  /**
   * 资源地址变化时重置并重新准备（查看器左右滑动切换图片会复用本组件实例）。
   *
   * 这里必须推进代际：两次 `prepare()` 交错时，只有最新一次的结果可以落到 UI 上，
   * 否则可能出现"显示 B 页却绑定 A 的动态照片"。
   */
  private onSourceChanged(): void {
    this.scope.begin()
    this.pendingAutoPlay = false
    this.playRequested = false
    this.clearPendingTimer()
    this.clearWatchdog()
    this.safeStop()
    this.movingPhoto = undefined
    this.phase = PHASE_LOADING
    this.prepare()
  }

  /**
   * 下载封面与视频到沙箱并构造 `MovingPhoto`。
   */
  private async prepare(): Promise<void> {
    if (this.coverUrl.length === 0 || this.videoUrl.length === 0) {
      this.phase = PHASE_FAILED
      return
    }
    const generation: number = this.scope.begin()
    try {
      const hostContext = this.getUIContext().getHostContext()
      if (hostContext === undefined) {
        this.phase = PHASE_FAILED
        return
      }
      const ctx: Context = hostContext as Context
      const dir: string = movingPhotoCacheDir(ctx.filesDir)
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true)
      }
      this.pruneCache(dir)
      const coverPath: string = `${dir}/${hashUrl(this.coverUrl)}.${extensionOf(this.coverUrl, 'jpg')}`
      const videoPath: string = `${dir}/${hashUrl(this.videoUrl)}.${extensionOf(this.videoUrl, 'mp4')}`
      const coverReady: boolean = await this.ensureFile(this.coverUrl, coverPath)
      const videoReady: boolean = await this.ensureFile(this.videoUrl, videoPath)
      if (!coverReady || !videoReady || !this.scope.isActive(generation)) {
        if (this.scope.isActive(generation)) {
          this.phase = PHASE_FAILED
        }
        return
      }
      const photo: photoAccessHelper.MovingPhoto =
        await photoAccessHelper.MediaAssetManager.loadMovingPhoto(ctx, `file://${coverPath}`, `file://${videoPath}`)
      if (!this.scope.isActive(generation)) {
        return
      }
      this.movingPhoto = photo
      this.phase = PHASE_READY
      logger.verbose('[MovingPhotoPlayer] ready cover=%{public}s', this.coverUrl)
      /* 申请全局播放权：抢占前一个实例（同一时刻只保留一个播放器实例）。 */
      arbiter.acquire(this.coverUrl, (): void => {
        this.handleInterrupted()
      })
      if (this.autoPlayOnce) {
        this.requestPendingAutoPlay()
      }
    } catch (err) {
      if (this.scope.isActive(generation)) {
        logger.warn('[MovingPhotoPlayer] prepare failed: %{public}s', formatError(err))
        this.phase = PHASE_FAILED
      }
    }
  }

  /**
   * 缓存目录容量保护：超过上限时按修改时间淘汰最旧的一半。
   *
   * 不做"全清空"：全清会让已有的动态照片全部需要重新下载（流量与等待），
   * 且删除瞬间可能删掉另一个组件正在使用/播放的文件。
   *
   * @param dir 缓存目录绝对路径
   */
  private pruneCache(dir: string): void {
    try {
      const names: string[] = fileIo.listFileSync(dir)
      if (names.length <= MAX_CACHE_FILES) {
        return
      }
      const entries: CacheEntry[] = []
      for (let i: number = 0; i < names.length; i++) {
        try {
          const stat: fileIo.Stat = fileIo.statSync(`${dir}/${names[i]}`)
          entries.push(new CacheEntry(`${dir}/${names[i]}`, stat.mtime))
        } catch (statErr) {
          /* 单个文件 stat 失败（可能正被删除）不影响其它条目。 */
        }
      }
      entries.sort((a: CacheEntry, b: CacheEntry): number => a.mtime - b.mtime)
      const removeCount: number = names.length - Math.floor(MAX_CACHE_FILES / 2)
      for (let i: number = 0; i < removeCount && i < entries.length; i++) {
        if (inFlightDownloads.has(entries[i].path)) {
          continue
        }
        try {
          fileIo.unlinkSync(entries[i].path)
        } catch (unlinkErr) {
          /* 已被其它路径删除则忽略。 */
        }
      }
    } catch (err) {
      logger.verbose('[MovingPhotoPlayer] prune failed: %{public}s', formatError(err))
    }
  }

  /**
   * 确保沙箱内已有可用的目标文件（无则下载，同一文件并发请求会复用同一次下载）。
   *
   * @param url 资源地址
   * @param filePath 沙箱目标路径
   * @returns 文件是否可用
   */
  private async ensureFile(url: string, filePath: string): Promise<boolean> {
    if (this.cachedFileUsable(filePath)) {
      return true
    }
    const pending: Promise<boolean> | undefined = inFlightDownloads.get(filePath)
    if (pending !== undefined) {
      return pending
    }
    const task: Promise<boolean> = this.downloadToFile(url, filePath)
    inFlightDownloads.set(filePath, task)
    try {
      return await task
    } finally {
      inFlightDownloads.delete(filePath)
    }
  }

  /**
   * 判断缓存文件是否可用（存在且非空）。
   *
   * 只判断存在会踩到"半成品文件"：并发写入期间或写入中断后，文件存在但内容不完整。
   *
   * @param filePath 沙箱文件路径
   * @returns 是否可直接复用
   */
  private cachedFileUsable(filePath: string): boolean {
    try {
      if (!fileIo.accessSync(filePath)) {
        return false
      }
      return fileIo.statSync(filePath).size > 0
    } catch (err) {
      return false
    }
  }

  /**
   * 下载到临时文件后原子替换目标文件。
   *
   * 先写 `xxx.part` 再 rename：写入过程对其它组件不可见，杜绝"读到半个文件"；
   * 失败时只清理自己的临时文件，绝不删除目标文件（那可能是别的组件正在用的）。
   *
   * @param url 资源地址
   * @param filePath 沙箱目标路径
   * @returns 是否下载成功
   */
  private async downloadToFile(url: string, filePath: string): Promise<boolean> {
    const tempPath: string = `${filePath}.part`
    const httpRequest: http.HttpRequest = http.createHttp()
    let file: fileIo.File | undefined = undefined
    try {
      const response: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      })
      const data: ArrayBuffer = response.result as ArrayBuffer
      file = await fileIo.open(tempPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC)
      await fileIo.write(file.fd, data)
      fileIo.closeSync(file)
      file = undefined
      if (fileIo.accessSync(filePath)) {
        fileIo.unlinkSync(filePath)
      }
      fileIo.renameSync(tempPath, filePath)
      return true
    } catch (err) {
      logger.warn('[MovingPhotoPlayer] download failed: %{public}s', formatError(err))
      return false
    } finally {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file)
        } catch (closeErr) {
          logger.verbose('[MovingPhotoPlayer] close failed: %{public}s', formatError(closeErr))
        }
      }
      try {
        if (fileIo.accessSync(tempPath)) {
          fileIo.unlinkSync(tempPath)
        }
      } catch (cleanupErr) {
        logger.verbose('[MovingPhotoPlayer] cleanup failed: %{public}s', formatError(cleanupErr))
      }
      httpRequest.destroy()
    }
  }

  /**
   * 播放一次动态照片。
   *
   * **只有就绪态响应**：加载中点击改为排队、播放中点击忽略，因此播放期间点击
   * 既不会重播也不会终止（UI 契约见类注释）。
   */
  private playOnce(): void {
    if (this.phase === PHASE_LOADING) {
      /* 加载中点击：排队到就绪后自动播放，避免"点了没反应"。 */
      this.requestPendingAutoPlay()
      return
    }
    if (this.phase !== PHASE_READY || this.playRequested) {
      return
    }
    logger.verbose('[MovingPhotoPlayer] playOnce')
    this.playRequested = true
    this.controller.startPlayback()
    /* `startPlayback()` 可能静默打空（播放器未就绪）：等 onStart 确认，超时即复位图标。 */
    this.startWatchdog(PLAYBACK_START_TIMEOUT_MS)
  }

  /**
   * 请求"就绪后自动播放"（自动播放与加载中点击排队共用）。
   *
   * 必须注册兜底定时器：若 `onPrepared` 因实例复用等原因不再到达，
   * 没有任何超时能救，点击将永久失效。
   */
  private requestPendingAutoPlay(): void {
    this.pendingAutoPlay = true
    this.clearPendingTimer()
    this.pendingTimer = setTimeout((): void => {
      this.pendingTimer = -1
      this.flushPendingAutoPlay()
    }, AUTO_PLAY_FALLBACK_MS)
  }

  /**
   * 消费"待播放"标记（`onPrepared` 或兜底定时器调用）。
   */
  private flushPendingAutoPlay(): void {
    if (!this.pendingAutoPlay) {
      return
    }
    this.pendingAutoPlay = false
    this.clearPendingTimer()
    this.playOnce()
  }

  /**
   * 启动看门狗：既覆盖"等 onStart 确认"阶段，也覆盖"播放中未收到结束事件"阶段。
   *
   * @param timeoutMs 超时时长（ms）
   */
  private startWatchdog(timeoutMs: number): void {
    this.clearWatchdog()
    this.playWatchdog = setTimeout((): void => {
      this.playWatchdog = -1
      if (this.playRequested) {
        logger.warn('[MovingPhotoPlayer] start watchdog fired, playback never started')
        this.playRequested = false
        this.phase = PHASE_READY
        return
      }
      if (this.phase === PHASE_PLAYING) {
        logger.warn('[MovingPhotoPlayer] playback watchdog fired, reset to ready')
        this.phase = PHASE_READY
        this.onPlaybackFinish()
      }
    }, timeoutMs)
  }

  /** 清除看门狗。 */
  private clearWatchdog(): void {
    if (this.playWatchdog !== -1) {
      clearTimeout(this.playWatchdog)
      this.playWatchdog = -1
    }
  }

  /** 清除待播放兜底定时器。 */
  private clearPendingTimer(): void {
    if (this.pendingTimer !== -1) {
      clearTimeout(this.pendingTimer)
      this.pendingTimer = -1
    }
  }

  /** 停止播放（未绑定组件时 SDK 行为未声明，故包一层防御）。 */
  private safeStop(): void {
    try {
      this.controller.stopPlayback()
    } catch (err) {
      logger.verbose('[MovingPhotoPlayer] stopPlayback failed: %{public}s', formatError(err))
    }
  }

  /**
   * 播放被外部打断（被新实例抢占 / 组件不可见）：停播、复位图标并通知父组件收起。
   */
  private handleInterrupted(): void {
    this.pendingAutoPlay = false
    this.playRequested = false
    this.clearPendingTimer()
    this.clearWatchdog()
    this.safeStop()
    if (this.phase === PHASE_PLAYING) {
      this.phase = PHASE_READY
      this.onPlaybackFinish()
    }
  }

  /** 图标是否应显示（失败态不显示，避免误导）。 */
  private iconVisible(): boolean {
    return this.phase !== PHASE_FAILED
  }

  /** 图标前景色：播放中用主题色高亮，其余用固定暗场景前景色。 */
  private iconColor(): ResourceColor {
    return this.phase === PHASE_PLAYING ? AppColors.primary : UIMaterialManager.onDarkForeground
  }

  build() {
    Stack() {
      /* 静态封面**常驻**：它就绪后一直挂在树上，播放器只叠在它之上。
         不用 if/else 在「封面 ↔ MovingPhotoView」之间换枝——换枝会销毁并重建封面
         `Image` 节点，重新解码期间是空白的（正文里点角标播放/播完收起看到的闪烁就在
         这一层）。两者都是 `ImageFit.Contain`、覆盖同一块区域，因此播放时画面被完全
         盖住；播放器尚未出帧时露出的正是下面这张已解码好的封面，视觉上无空窗。 */
      Image(this.coverUrl)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Contain)
        .draggable(false)
        .hitTestBehavior(HitTestMode.None)

      if (this.movingPhoto !== undefined) {
        MovingPhotoView({ movingPhoto: this.movingPhoto, controller: this.controller })
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .muted(true)
          .autoPlay(false)
          .repeatPlay(false)
          .onPrepared(() => {
            logger.verbose('[MovingPhotoPlayer] event onPrepared')
            /* 播放器就绪：此刻 startPlayback 才真正生效（见 pendingAutoPlay 注释）。 */
            this.flushPendingAutoPlay()
          })
          .onComplete(() => {
            logger.verbose('[MovingPhotoPlayer] event onComplete')
          })
          .onStart(() => {
            logger.verbose('[MovingPhotoPlayer] event onStart')
            this.playRequested = false
            this.phase = PHASE_PLAYING
            this.startWatchdog(PLAYBACK_TIMEOUT_MS)
          })
          .onFinish(() => {
            logger.verbose('[MovingPhotoPlayer] event onFinish')
            this.clearWatchdog()
            this.playRequested = false
            this.phase = PHASE_READY
            this.onPlaybackFinish()
          })
          .onStop(() => {
            logger.verbose('[MovingPhotoPlayer] event onStop')
            this.clearWatchdog()
            this.playRequested = false
            this.phase = PHASE_READY
            this.onPlaybackFinish()
          })
          .onPause(() => {
            logger.verbose('[MovingPhotoPlayer] event onPause')
            this.clearWatchdog()
            this.playRequested = false
            this.phase = PHASE_READY
            this.onPlaybackFinish()
          })
          .onError(() => {
            logger.warn('[MovingPhotoPlayer] event onError')
            this.clearWatchdog()
            this.playRequested = false
            this.phase = PHASE_READY
            this.onPlaybackFinish()
          })
          /* 点击与长按都不注册操作：播放全部由左上角图标触发。
             MovingPhotoView 自带「长按播放」，用 hitTestBehavior(None) 屏蔽组件自身手势，
             事件穿透给父容器（查看器左右滑动切图不受影响）。 */
          .hitTestBehavior(HitTestMode.None)
      }

      /* 图标常驻左上角（位置由父组件参数决定）：加载中半透明、就绪常态、播放中高亮。 */
      if (this.iconVisible()) {
        Stack() {
          Image($r('app.media.icon_live_photo'))
            .width(this.iconSize * 0.62)
            .height(this.iconSize * 0.62)
            .fillColor(this.iconColor())
            .draggable(false)
        }
        .width(this.iconSize)
        .height(this.iconSize)
        .borderRadius(this.iconSize / 2)
        /* 实色半透明底 + 一圈细描边（按钮底板形态）：与正文里的静态图标完全同款，
           播放器接管前后无视觉跳动；底板半透明，压在暗色/杂乱画面上边界会糊掉，
           细白线负责在任何底图上都框出按钮轮廓。 */
        .backgroundColor(AppColors.movingPhotoBadgeBg)
        .border({ width: 1, color: AppColors.movingPhotoBadgeBorder })
        .opacity(this.phase === PHASE_LOADING ? 0.55 : 1)
        /* 绝对定位：不受父 Stack 对齐规则影响，始终落在容器左上角指定偏移。 */
        .position({ x: this.iconLeft, y: this.iconTop })
        .accessibilityText(this.phase === PHASE_PLAYING ? '动态照片播放中' : '播放动态照片')
        .onClick(() => {
          this.playOnce()
        })
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
    /* 图片本体点击：内部 MovingPhotoView / 封面 Image 均为 hitTestBehavior(None)，
       事件穿透到这里统一处理（帖子内打开查看器；查看器内不传回调即无操作）。 */
    .onClick(() => {
      this.onBodyClick()
    })
    /* 离屏即停：楼层列表用 LazyForEach + cachedCount，滚出屏幕的组件不会销毁，
       不主动停播会让 AVPlayer 实例持续累积（官方建议同时不超过 3 个）。 */
    .onVisibleAreaChange([0.0, 1.0], (_isVisible: boolean, ratio: number) => {
      if (ratio <= 0) {
        this.handleInterrupted()
      }
    })
  }
}
