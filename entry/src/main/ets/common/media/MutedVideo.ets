import { BusinessError } from '@kit.BasicServicesKit'
import { appStore } from '../../store/AppStore'
import { AppColors, ImageLoadStrategy } from '../constants/Constants'
import { shouldUsePassive } from '../utils/NetworkUtil'
import { Logger, DOMAIN_MEDIA, formatError } from '../utils/Logger'

const logger = new Logger(DOMAIN_MEDIA, 'MutedVideo')

/** GIF 动图模式：请求起播后等待 `onPrepared` 的兜底上限（超时只告警，排队标记保留给后续回调消费）。 */
const GIF_PREPARE_FALLBACK_MS: number = 4000

/** GIF 动图模式：发出 `start()` 后等待 `onStart` 确认的上限（超时视为打空，允许再次点击）。 */
const GIF_START_TIMEOUT_MS: number = 2500

/**
 * 视频播放组件（带全局静音切换）。
 *
 * 同一个内置 `Video` 承载两种语义，由调用方通过 `isAnimatedGif` 选择；不传时行为与旧版完全一致。
 *
 * ## 普通视频（`isAnimatedGif = false`，默认）
 * 在画面右上角叠加一个静音切换按钮：静音状态读取全局设置 videoMuted（@StorageProp 响应式读取），
 * 点击经 appStore.setVideoMuted 切换并持久化，所有 MutedVideo 实例同步生效。
 * 通过 posterOptions.showFirstFrame 控制首帧送显（API 18+）：挂载后解码并显示视频真实首帧
 * （替代默认黑屏），autoPlay(false) 不自动播放，等待用户点击播放键。是否送显首帧跟随图片
 * 加载策略，与图片主动加载条件一致——ALWAYS 或 WIFI_ONLY+WiFi 时启用首帧，MANUAL 或
 * WIFI_ONLY+非WiFi 时保持黑屏（见 shouldShowFirstFrame）。开启首帧送显后 previewUri 不生效
 * （本组件未使用）。
 *
 * ## GIF 动图（`isAnimatedGif = true`，NGA `*.gif.mp4`「动图转视频」）
 * 官方网页对 `att.ext == 'gif.mp4'` 走动图语义（静音 + 循环 + 自动播放 + 无常驻控件），
 * 本组件据此实现：
 * - 强制 `.muted(true)`、`.loop(true)`、`.controls(false)`、`.autoPlay(false)`；
 * - 不渲染右上角静音按钮（GIF 无音频，不参与全局静音设置）；
 * - 主动加载策略（ALWAYS / WIFI_ONLY+WiFi）下可见即自动播放；被动策略（MANUAL /
 *   WIFI_ONLY+蜂窝）下不自动起播，点击画面才播（首帧送显同样跟随该策略，见 shouldShowFirstFrame）；
 * - 不可见即 `controller.pause()`（避免离屏 AVPlayer 累积，官方建议同时不超过 3 个）；
 * - 点击画面 = 播放/暂停切换；未播放时显示居中播放图标，播放中隐藏；
 * - 用户手动暂停后滚回可见不自动恢复（`manualPaused` 记录意图）；
 * - 起播只在 `onPrepared` 之后（`pendingAutoPlay` 排队 + 兜底定时器 + `onStart` 看门狗，
 *   避免 `start()` 打空——同 `MovingPhotoPlayer` 的时序契约）；
 * - `aboutToDisappear` 调 `controller.stop()` 释放；
 * - 失败时显示「灰块 + 提示图标」占位，不再静默地留一块不能播的播放器。
 */
@Component
export struct MutedVideo {
  /** 视频源地址 */
  @Prop @Watch('onSrcChanged') src: string = ''
  /** 视频宽高比（width / height），由调用方按已有尺寸缓存计算后传入 */
  @Prop videoAspectRatio: number = 1.78
  /**
   * 是否为 NGA「动图转视频」（`*.gif.mp4`）。
   *
   * 由调用方用 `isAnimatedGifMediaUrl()` 判定后传入：true 走上面的动图语义，
   * false（默认）走普通视频语义，既有调用点不传时行为完全不变。
   */
  @Prop isAnimatedGif: boolean = false
  /** 全局视频静音状态：false=有声，true=静音（普通视频模式使用；GIF 模式恒静音） */
  @StorageProp('videoMuted') videoMuted: boolean = false
  /** 图片加载策略，订阅 AppStorage，决定首帧送显是否启用（与图片主动加载条件一致） */
  @StorageProp('imageLoadStrategy') imageLoadStrategy: string = ImageLoadStrategy.ALWAYS
  /** 网络变化版本号，订阅 AppStorage，WiFi/蜂窝切换时触发首帧送显重算 */
  @StorageProp('networkChangeVersion') networkChangeVersion: number = 0

  /** GIF 模式播放控制器（普通视频模式不使用，Video 构造也不接 controller，保持原行为）。 */
  private controller: VideoController = new VideoController()
  /** GIF 模式是否已就绪（`onPrepared` 到达后才能安全 `start()`）。 */
  @State private isPrepared: boolean = false
  /** GIF 模式是否正在播放（`onStart`/`onPause` 驱动中央播放图标显隐）。 */
  @State private isPlaying: boolean = false
  /** GIF 模式是否加载失败（失败时显示可辨识占位）。 */
  @State private hasFailed: boolean = false
  /** 组件当前是否可见（`onVisibleAreaChange` 维护；挂载即可见，与图片主动加载语义一致）。 */
  private isVisible: boolean = true
  /** 用户手动暂停意图：为 true 时滚回可见不自动恢复播放。 */
  private manualPaused: boolean = false
  /** 待播放标记：自动播放/点击请求先排队，`onPrepared` 后消费。 */
  private pendingAutoPlay: boolean = false
  /** 已发出 `start()`、尚未收到 `onStart` 确认（用于识别打空）。 */
  private startRequested: boolean = false
  /** 等待 `onPrepared` 的兜底定时器（-1 表示未在计时）。 */
  private prepareTimer: number = -1
  /** 等待 `onStart` 确认的看门狗（-1 表示未在计时）。 */
  private startWatcher: number = -1

  /** 组件消失：清掉所有定时器并释放 GIF 播放器。 */
  aboutToDisappear(): void {
    this.clearGifTimers()
    if (this.isAnimatedGif) {
      this.safeStop()
    }
  }

  /**
   * 源变化（列表复用/换源）：重置 GIF 状态机，避免继承上一个源的播放/失败状态。
   *
   * 普通视频模式只清定时器，不触碰 Video（src 变化由内置 Video 自行重载）。
   */
  private onSrcChanged(): void {
    this.clearGifTimers()
    /* 先停旧源（可能正播或已就绪），再重置状态；普通视频从未准备过，不会误调未绑定的控制器。 */
    if (this.isPlaying || this.isPrepared) {
      this.safeStop()
    }
    this.isPrepared = false
    this.isPlaying = false
    this.hasFailed = false
    this.manualPaused = false
    this.pendingAutoPlay = false
    this.startRequested = false
  }

  /**
   * 首帧送显是否启用：与图片主动加载条件一致（即 shouldUsePassive 的反面）。
   *
   * @returns true=播放前送显首帧，false=保持黑屏（不主动联网取帧）
   */
  private shouldShowFirstFrame(): boolean {
    return !shouldUsePassive(this.imageLoadStrategy)
  }

  /**
   * GIF 模式是否允许自动播放：与图片主动加载条件一致（ALWAYS / WIFI_ONLY+WiFi）。
   *
   * @returns true=可见即自动播放，false=只等用户点击
   */
  private canAutoPlay(): boolean {
    return !shouldUsePassive(this.imageLoadStrategy)
  }

  /**
   * 请求「就绪后播放」（自动播放与点击排队共用）。
   *
   * 已就绪时立即起播；未就绪时挂兜底定时器，超时只告警、排队标记保留，
   * 由后续 `onPrepared` 或可见性变化消费（源真坏时 `onError` 会清掉排队）。
   */
  private requestPlayWhenPrepared(): void {
    /* 已在播放、或已发出 start() 等待 onStart 确认时不重复排队（可见性回调可能反复触发）。 */
    if (this.isPlaying || this.startRequested) {
      return
    }
    this.pendingAutoPlay = true
    this.clearPrepareTimer()
    if (this.isPrepared) {
      this.flushPendingPlay()
      return
    }
    this.prepareTimer = setTimeout((): void => {
      this.prepareTimer = -1
      logger.warn('[MutedVideo] gif prepare timeout, keep pending: %{public}s', this.src)
    }, GIF_PREPARE_FALLBACK_MS)
  }

  /**
   * 消费「待播放」标记（`onPrepared` 或请求时立即调用）。
   *
   * 不可见/用户手动暂停/已失败/已在播放时丢弃这一次排队，避免重复 `start()` 与看不见的播放器。
   */
  private flushPendingPlay(): void {
    if (!this.pendingAutoPlay) {
      return
    }
    this.pendingAutoPlay = false
    this.clearPrepareTimer()
    if (!this.isPrepared || !this.isVisible || this.manualPaused || this.hasFailed || this.isPlaying) {
      return
    }
    this.startPlayback()
  }

  /**
   * 起播：`start()` 后等 `onStart` 确认，超时视为打空并复位图标（允许用户再点）。
   */
  private startPlayback(): void {
    this.startRequested = true
    try {
      this.controller.start()
    } catch (err) {
      this.startRequested = false
      logger.warn('[MutedVideo] gif start failed: %{public}s', formatError(err))
      return
    }
    this.clearStartWatcher()
    this.startWatcher = setTimeout((): void => {
      this.startWatcher = -1
      if (this.startRequested) {
        this.startRequested = false
        this.isPlaying = false
        logger.warn('[MutedVideo] gif start watchdog fired: %{public}s', this.src)
      }
    }, GIF_START_TIMEOUT_MS)
  }

  /** 暂停（用户点击或离屏自动暂停）。 */
  private pausePlayback(): void {
    try {
      this.controller.pause()
    } catch (err) {
      logger.warn('[MutedVideo] gif pause failed: %{public}s', formatError(err))
    }
  }

  /** 停止并释放播放器（组件销毁/换源时调用；SDK 未声明异常，防御性包一层）。 */
  private safeStop(): void {
    try {
      this.controller.stop()
    } catch (err) {
      logger.warn('[MutedVideo] gif stop failed: %{public}s', formatError(err))
    }
  }

  /** 点击画面：播放/暂停切换。 */
  private togglePlayback(): void {
    if (this.hasFailed) {
      return
    }
    if (this.isPlaying) {
      this.manualPaused = true
      this.pausePlayback()
      return
    }
    this.manualPaused = false
    if (!this.isPrepared) {
      /* 被动加载策略下只有点击才真正起播：先排队，等 onPrepared。 */
      this.requestPlayWhenPrepared()
      return
    }
    this.startPlayback()
  }

  /**
   * 可见性变化（仅 GIF 模式有行为）。
   *
   * @param isVisible 是否可见
   * @param ratio 可见比例
   */
  private onGifVisibleChange(isVisible: boolean, ratio: number): void {
    if (!this.isAnimatedGif || this.hasFailed) {
      return
    }
    this.isVisible = ratio > 0
    if (!this.isVisible) {
      if (this.isPlaying) {
        this.pausePlayback()
      }
      return
    }
    if (this.manualPaused) {
      return
    }
    if (this.canAutoPlay()) {
      this.requestPlayWhenPrepared()
    }
  }

  /** 清除等待 `onPrepared` 的兜底定时器。 */
  private clearPrepareTimer(): void {
    if (this.prepareTimer !== -1) {
      clearTimeout(this.prepareTimer)
      this.prepareTimer = -1
    }
  }

  /** 清除等待 `onStart` 确认的看门狗。 */
  private clearStartWatcher(): void {
    if (this.startWatcher !== -1) {
      clearTimeout(this.startWatcher)
      this.startWatcher = -1
    }
  }

  /** 清除 GIF 模式全部定时器。 */
  private clearGifTimers(): void {
    this.clearPrepareTimer()
    this.clearStartWatcher()
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      if (this.isAnimatedGif) {
        /* GIF 动图：静音 + 循环 + 无系统控件 + 不自动播放（起播由本组件统一控制）。 */
        Video({
          src: this.src,
          controller: this.controller,
          posterOptions: { showFirstFrame: this.shouldShowFirstFrame() }
        })
          .width('100%')
          .aspectRatio(this.videoAspectRatio)
          .objectFit(ImageFit.Contain)
          .muted(true)
          .loop(true)
          .controls(false)
          .autoPlay(false)
          .borderRadius(8)
          .backgroundColor(AppColors.bgSecondary)
          .onPrepared((): void => {
            this.isPrepared = true
            this.flushPendingPlay()
            /*
             * 列表复用换源时可见性没有变化，`onVisibleAreaChange` 不会再触发：就绪后按策略补一次
             * 自动播放，避免复用后的 GIF 停在首帧不动。手动暂停/被动加载策略下不补。
             */
            if (!this.startRequested && !this.isPlaying && !this.manualPaused &&
              this.isVisible && this.canAutoPlay()) {
              this.requestPlayWhenPrepared()
            }
          })
          .onStart((): void => {
            this.isPlaying = true
            this.startRequested = false
            this.clearStartWatcher()
          })
          .onPause((): void => {
            this.isPlaying = false
            this.startRequested = false
            this.clearStartWatcher()
          })
          .onFinish((): void => {
            /* loop(true) 下不应触发；若触发则复位图标，等用户再次点击。 */
            this.isPlaying = false
            this.startRequested = false
            this.clearStartWatcher()
          })
          .onError((err: BusinessError): void => {
            this.hasFailed = true
            this.isPlaying = false
            this.isPrepared = false
            this.pendingAutoPlay = false
            this.clearGifTimers()
            logger.error('[MutedVideo] gif video error: %{public}s : %{public}s', this.src, formatError(err))
          })

        if (this.hasFailed) {
          /* 失败占位：灰块 + 提示图标，替代「无提示的坏播放器」。 */
          Column() {
            Image($r('app.media.icon_video_failed'))
              .width(28).height(28).fillColor(AppColors.textTertiary)
            Text('动图加载失败').fontSize(12).fontColor(AppColors.textTertiary).margin({ top: 6 })
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(AppColors.bgSecondary)
        } else {
          /* 点击层覆盖全画面：播放/暂停切换；未播放时居中播放图标（播放中隐藏）。 */
          Stack() {
            if (!this.isPlaying) {
              Stack() {
                Image($r('app.media.icon_play'))
                  .width(22).height(22).fillColor(AppColors.white)
              }
              .width(44).height(44).borderRadius(22)
              .backgroundColor('rgba(0, 0, 0, 0.5)')
            }
          }
          .width('100%').height('100%')
          .alignContent(Alignment.Center)
          .onClick((): void => {
            this.togglePlayback()
          })
        }
      } else {
        /* 普通视频：行为与旧版完全一致（controls + 手动播放 + 全局静音按钮），仅补错误日志。 */
        Video({
          src: this.src,
          posterOptions: { showFirstFrame: this.shouldShowFirstFrame() }
        })
          .width('100%')
          .aspectRatio(this.videoAspectRatio)
          .objectFit(ImageFit.Contain)
          .controls(true)
          .autoPlay(false)
          .muted(this.videoMuted)
          .borderRadius(8)
          .backgroundColor(AppColors.bgSecondary)
          .onError((err: BusinessError): void => {
            logger.error('[MutedVideo] video error: %{public}s : %{public}s', this.src, formatError(err))
          })

        // 右上角静音切换按钮：静音态显示 icon_volume_off，有声态显示 icon_volume_up
        Stack() {
          Image(this.videoMuted ? $r('app.media.icon_volume_off') : $r('app.media.icon_volume_up'))
            .width(16).height(16).fillColor(AppColors.white)
        }
        .width(30).height(30).borderRadius(15)
        .backgroundColor('rgba(0, 0, 0, 0.5)')
        .margin({ top: 8, right: 8 })
        .onClick(() => {
          appStore.settingsStore.setVideoMuted(!this.videoMuted)
        })
      }
    }
    /* 可见性只服务 GIF 模式；普通视频分支在回调里直接返回，行为不变。 */
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, ratio: number): void => {
      this.onGifVisibleChange(isVisible, ratio)
    })
  }
}
