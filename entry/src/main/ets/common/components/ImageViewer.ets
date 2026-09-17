import { http } from '@kit.NetworkKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { appStore } from '../../store/AppStore';
import { AppColors } from '../constants/Constants';
import { UIMaterialManager } from '../managers/UIMaterialManager';
import { MovingPhotoPlayer } from '../media/MovingPhotoPlayer';
import { ensureMovingPhotoFiles, releaseMovingPhotoFiles, MovingPhotoPair } from '../media/MovingPhotoCache';
import { getMovingPhotoVideo } from '../media/MovingPhotoRegistry';
import { Logger, DOMAIN_UI, formatError } from '../utils/Logger';

const logger = new Logger(DOMAIN_UI, 'ImageViewer');

@Component
export struct ImageViewer {
  @Prop urls: string[]
  @Prop initialIndex: number = 0
  onClose: () => void = () => {}

  @State currentIndex: number = 0
  @State zoomScale: number = 1
  @State zoomOffsetX: number = 0
  @State zoomOffsetY: number = 0
  @State swipeTranslateX: number = 0
  @State containerW: number = 0
  @State containerH: number = 0
  @State imgNaturalW: number = 0
  @State imgNaturalH: number = 0
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @StorageProp('navBarHeight') navBarHeight: number = 0
  @State saving: boolean = false
  @State sharing: boolean = false
  /**
   * 当前页准备失败的动态照片封面地址（仅对当前页有效，换页即清空）。
   *
   * 失败页要立刻回落成普通图片：否则既不能播（图标已隐藏）也不能缩放
   * （捏合/双击守卫按"是不是动态照片"提前返回），变成一张永久卡住的图。
   */
  @State private failedMovingPhotoUrl: string = ''

  private isPageAnimating: boolean = false

  private pinchBaseScale: number = 1
  private pinchBaseOffsetX: number = 0
  private pinchBaseOffsetY: number = 0
  private pinchCenterX: number = 0
  private pinchCenterY: number = 0

  private panBaseOffsetX: number = 0
  private panBaseOffsetY: number = 0
  private panBaseSwipeX: number = 0
  private velX: number = 0
  private velY: number = 0
  private prevVelX: number = 0
  private prevVelY: number = 0
  private prevPanX: number = 0
  private prevPanY: number = 0
  private prevSampleTime: number = 0

  private panToastShown: boolean = false

  private lastTouchX: number = 0
  private lastTouchY: number = 0
  private panStartOffsetX: number = 0
  private panStartOffsetY: number = 0

  private readonly ZOOM_MAX: number = 8
  private readonly ZOOM_MIN: number = 1
  private readonly SWIPE_THRESHOLD: number = 80
  private readonly SWIPE_DISTANCE: number = 15
  private readonly DOUBLE_TAP_SCALE: number = 2.5

  aboutToAppear(): void {
    this.currentIndex = this.initialIndex
  }

  /**
   * 当前页**可播放**的动态视频地址；非动态照片、或本页已准备失败时返回空串。
   *
   * 正文渲染时已把「动态照片封面 → 动态视频」登记到 `MovingPhotoRegistry`，
   * 查看器按当前封面地址反查即可，无需给点击回调链层层加参数。
   *
   * 失败页返回空串是渲染分支与手势守卫共用的判据：渲染回落到普通 `Image`，
   * 捏合/双击随之放行。
   *
   * @returns 动态视频地址或空串
   */
  private currentMovingPhotoVideo(): string {
    if (this.currentIndex < 0 || this.currentIndex >= this.urls.length) {
      return ''
    }
    const url: string = this.urls[this.currentIndex]
    if (this.failedMovingPhotoUrl === url) {
      return ''
    }
    return getMovingPhotoVideo(url)
  }

  /**
   * 当前页的动态视频地址（不做过失败过滤，供「保存动态照片」使用）。
   *
   * 播放准备失败不等于文件取不到：保存走同一份沙箱缓存，仍有机会成功。
   *
   * @returns 动态视频地址或空串
   */
  private rawMovingPhotoVideo(): string {
    if (this.currentIndex < 0 || this.currentIndex >= this.urls.length) {
      return ''
    }
    return getMovingPhotoVideo(this.urls[this.currentIndex])
  }

  private getExtension(url: string): string {
    let match: RegExpMatchArray | null = url.match(/\.(\w+)(?:[?#]|$)/)
    if (match) {
      let ext: string = match[1].toLowerCase()
      if (ext === 'jpeg') {
        return 'jpg'
      }
      if (ext === 'png' || ext === 'gif' || ext === 'webp' || ext === 'bmp') {
        return ext
      }
    }
    return 'jpg'
  }

  /**
   * 保存当前页到相册。
   *
   * 动态照片优先按「封面 + 视频」两条资源写入媒体库（保留动态效果），
   * 任一步失败则降级为保存静态封面（与普通图片同路径）。
   */
  private async saveCurrentImage(): Promise<void> {
    if (this.saving) return
    this.saving = true
    try {
      const url: string = this.urls[this.currentIndex]
      const videoUrl: string = this.rawMovingPhotoVideo()
      if (videoUrl.length > 0 && await this.saveMovingPhotoToAlbum(url, videoUrl)) {
        appStore.showToast('已保存到相册')
        return
      }
      await this.saveStillToAlbum(url)
      appStore.showToast('已保存到相册')
    } catch (err) {
      logger.error('[ImageViewer] save failed: %{public}s', formatError(err))
      appStore.showToast('保存失败')
    } finally {
      this.saving = false
    }
  }

  /**
   * 按动态照片写入相册（`subtype: MOVING_PHOTO` + 图片/视频两条资源）。
   *
   * 复用播放器同一份沙箱缓存（见 `MovingPhotoCache`），不重复下载视频；
   * 该缓存可能已被淘汰、也可能因播放失败而缺失，此时直接返回 false 交给调用方降级。
   *
   * @param coverUrl 封面地址
   * @param videoUrl 动态视频地址
   * @returns 是否保存成功
   */
  private async saveMovingPhotoToAlbum(coverUrl: string, videoUrl: string): Promise<boolean> {
    const ctx: Context = this.getUIContext().getHostContext() as Context
    let pair: MovingPhotoPair | null = null
    try {
      pair = await ensureMovingPhotoFiles(ctx, coverUrl, videoUrl)
      if (pair === null) {
        return false
      }
      const options: photoAccessHelper.CreateOptions = {
        title: `nga_mphoto_${Date.now()}`,
        subtype: photoAccessHelper.PhotoSubtype.MOVING_PHOTO
      }
      const assetChangeRequest: photoAccessHelper.MediaAssetChangeRequest =
        photoAccessHelper.MediaAssetChangeRequest.createAssetRequest(
          ctx, photoAccessHelper.PhotoType.IMAGE, this.getExtension(coverUrl), options)
      /* 动态照片的固定写法：图片与视频各 addResource 一次（官方注释原文）。 */
      assetChangeRequest.addResource(photoAccessHelper.ResourceType.IMAGE_RESOURCE,
        fileUri.getUriFromPath(pair.coverPath))
      assetChangeRequest.addResource(photoAccessHelper.ResourceType.VIDEO_RESOURCE,
        fileUri.getUriFromPath(pair.videoPath))
      const phAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx)
      await phAccessHelper.applyChanges(assetChangeRequest)
      return true
    } catch (err) {
      logger.warn('[ImageViewer] save moving photo failed, fallback to still: %{public}s', formatError(err))
      return false
    } finally {
      if (pair !== null) {
        releaseMovingPhotoFiles(pair)
      }
    }
  }

  /**
   * 保存静态图片到相册（普通图片路径，也是动态照片保存失败时的降级路径）。
   *
   * 必须校验响应：`http.request` 对 4xx/5xx 同样成功 resolve，不判状态码会把错误页
   * 当成照片存进相册。
   *
   * @param url 图片地址
   */
  private async saveStillToAlbum(url: string): Promise<void> {
    const ext: string = this.getExtension(url)
    const ctx: Context = this.getUIContext().getHostContext() as Context
    const sandboxDir: string = ctx.filesDir
    const fileName: string = `temp_${Date.now()}.${ext}`
    const sandboxFileUri: string = `file://${sandboxDir}/${fileName}`
    const httpRequest: http.HttpRequest = http.createHttp()
    try {
      const response: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.GET
      })
      if (response.responseCode !== http.ResponseCode.OK) {
        throw new Error(`download failed with http ${response.responseCode}`)
      }
      const result: ArrayBuffer = response.result as ArrayBuffer
      if (result.byteLength === 0) {
        throw new Error('download failed with empty body')
      }
      const file: fileIo.File = await fileIo.open(sandboxFileUri,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE)
      await fileIo.write(file.fd, result)
      fileIo.close(file)
      const phAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx)
      const assetChangeRequest = photoAccessHelper.MediaAssetChangeRequest.createImageAssetRequest(
        ctx, sandboxFileUri)
      await phAccessHelper.applyChanges(assetChangeRequest)
    } finally {
      httpRequest.destroy()
    }
  }

  /**
   * 分享当前页。
   *
   * **动态照片分享的是静态封面**：系统分享只吃「一个 uri + 一个 utd」，
   * 而动态照片是「图片 + 视频」两个文件，本 SDK 也没有动态照片的 utd 与分享通路
   * （`image/movingPhoto` 仅作为媒体库选择器的过滤 MIME 存在）。要完整分享动态照片
   * 需先落到相册再分享媒体库资产，本工程不做。保存走 {@link saveMovingPhotoToAlbum}，
   * 动态效果不丢。
   */
  private async shareCurrentImage(): Promise<void> {
    if (this.sharing) return
    this.sharing = true
    try {
      let url: string = this.urls[this.currentIndex]
      let ext: string = this.getExtension(url)
      let ctx: Context = this.getUIContext().getHostContext() as Context
      let sandboxDir: string = ctx.filesDir
      let fileName: string = `share_${Date.now()}.${ext}`
      let sandboxFileUri: string = `${sandboxDir}/${fileName}`

      let httpRequest: http.HttpRequest = http.createHttp()
      let response: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.GET
      })
      httpRequest.destroy()
      if (response.responseCode !== http.ResponseCode.OK) {
        throw new Error(`download failed with http ${response.responseCode}`)
      }

      let result: ArrayBuffer = response.result as ArrayBuffer
      if (result.byteLength === 0) {
        throw new Error('download failed with empty body')
      }
      let file: fileIo.File = await fileIo.open(sandboxFileUri,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE)
      await fileIo.write(file.fd, result)
      fileIo.close(file)

      let fileUriStr: string = fileUri.getUriFromPath(sandboxFileUri)
      let utdType: string = utd.getUniformDataTypeByFilenameExtension(`.${ext}`,
        utd.UniformDataType.IMAGE)

      let shareData: systemShare.SharedData = new systemShare.SharedData({
        utd: utdType,
        uri: fileUriStr,
        title: fileName
      })

      let controller: systemShare.ShareController = new systemShare.ShareController(shareData)
      controller.on('dismiss', () => {
        logger.verbose('[ImageViewer] share panel dismissed')
      })
      await controller.show(ctx as common.UIAbilityContext, {
        previewMode: systemShare.SharePreviewMode.DETAIL,
        selectionMode: systemShare.SelectionMode.SINGLE
      })
    } catch (err) {
      logger.error('[ImageViewer] share failed: %{public}s', formatError(err))
      appStore.showToast('分享失败')
    } finally {
      this.sharing = false
    }
  }

  private calcImgContainedW(): number {
    if (this.imgNaturalW <= 0 || this.imgNaturalH <= 0) return 0
    if (this.containerW <= 0 || this.containerH <= 0) return 0
    let ratio: number = this.imgNaturalW / this.imgNaturalH
    let cRatio: number = this.containerW / this.containerH
    if (ratio > cRatio) {
      return this.containerW
    } else {
      return this.containerH * ratio
    }
  }

  private calcImgContainedH(): number {
    if (this.imgNaturalW <= 0 || this.imgNaturalH <= 0) return 0
    if (this.containerW <= 0 || this.containerH <= 0) return 0
    let ratio: number = this.imgNaturalW / this.imgNaturalH
    let cRatio: number = this.containerW / this.containerH
    if (ratio > cRatio) {
      return this.containerW / ratio
    } else {
      return this.containerH
    }
  }

  private clampOffsetX(targetScale: number, targetOffsetX: number): number {
    let imgW: number = this.calcImgContainedW()
    let imgH: number = this.calcImgContainedH()
    if (imgW <= 0 || imgH <= 0) return targetOffsetX
    let cw: number = imgW * targetScale
    let cbx: number = (this.containerW - imgW) / 2
    if (cw <= this.containerW) {
      return (this.containerW - cw) / 2 - cbx * targetScale
    }
    let visualX: number = cbx * targetScale + targetOffsetX
    if (visualX > 0) {
      return -cbx * targetScale
    }
    if (visualX + cw < this.containerW) {
      return this.containerW - cw - cbx * targetScale
    }
    return targetOffsetX
  }

  private clampOffsetY(targetScale: number, targetOffsetY: number): number {
    let imgW: number = this.calcImgContainedW()
    let imgH: number = this.calcImgContainedH()
    if (imgW <= 0 || imgH <= 0) return targetOffsetY
    let ch: number = imgH * targetScale
    let cby: number = (this.containerH - imgH) / 2
    if (ch <= this.containerH) {
      return (this.containerH - ch) / 2 - cby * targetScale
    }
    let visualY: number = cby * targetScale + targetOffsetY
    if (visualY > 0) {
      return -cby * targetScale
    }
    if (visualY + ch < this.containerH) {
      return this.containerH - ch - cby * targetScale
    }
    return targetOffsetY
  }

  private trackVelocity(x: number, y: number, time: number): void {
    let dt: number = time - this.prevSampleTime
    if (dt > 1) {
      let dx: number = x - this.prevPanX
      let dy: number = y - this.prevPanY
      let vx: number = dx / dt * 1000
      let vy: number = dy / dt * 1000
      this.velX = this.prevVelX * 0.3 + vx * 0.7
      this.velY = this.prevVelY * 0.3 + vy * 0.7
      this.prevVelX = this.velX
      this.prevVelY = this.velY
      this.prevPanX = x
      this.prevPanY = y
      this.prevSampleTime = time
    }
  }

  private resetPanTracking(): void {
    this.velX = 0
    this.velY = 0
    this.prevVelX = 0
    this.prevVelY = 0
    this.prevSampleTime = 0
  }

  private doSwipeTo(targetIndex: number): void {
    this.isPageAnimating = true
    let dir: number = targetIndex > this.currentIndex ? 1 : -1
    let oldSwipeX: number = this.swipeTranslateX
    this.currentIndex = targetIndex
    /* 换页清空失败标记：回到该页会重建播放器并重下一次（瞬时失败不至于被判死刑）。 */
    this.failedMovingPhotoUrl = ''
    this.zoomScale = 1
    this.zoomOffsetX = 0
    this.zoomOffsetY = 0
    this.swipeTranslateX = oldSwipeX + dir * this.containerW
    this.imgNaturalW = 0
    this.imgNaturalH = 0
    this.getUIContext()?.animateTo({
      duration: 250,
      curve: Curve.FastOutSlowIn,
      onFinish: () => {
        this.isPageAnimating = false
      }
    }, () => {
      this.swipeTranslateX = 0
    })
  }

  private doSwipeBounceBack(): void {
    this.getUIContext()?.animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
      this.swipeTranslateX = 0
    })
  }

  build() {
    Column() {
      Stack() {
        Stack() {
          if (this.currentIndex > 0) {
            Image(this.urls[this.currentIndex - 1])
              .objectFit(ImageFit.Contain)
              .width('100%').height('100%')
              .translate({ x: -this.containerW + this.swipeTranslateX })
              .onError(() => {
              })
          }

          if (this.currentMovingPhotoVideo().length > 0) {
            /* 动态照片（NGA [b]MPHOTO[/b]）：交给系统动态照片组件播放（点击播放/停止）。
               MovingPhotoView 不支持缩放类动态属性，因此本页不参与捏合/双击缩放。 */
            MovingPhotoPlayer({
              coverUrl: this.urls[this.currentIndex],
              videoUrl: this.currentMovingPhotoVideo(),
              /* 不自动播放：播放全部由左上角图标触发；图标固定在内容区左上角
                 （不随图片位置/尺寸变化），图片本体点击/长按不注册操作。 */
              iconTop: 12,
              iconLeft: 16,
              iconSize: 44,
              onPrepareFailed: (coverUrl: string): void => {
                /* 只认当前页的失败：回调到达时当前页可能已经翻走（切图会复用播放器实例），
                   否则会把别的页误标成失败。标记后本页回落到普通图片分支（可缩放）。 */
                if (this.currentIndex >= 0 && this.currentIndex < this.urls.length &&
                  this.urls[this.currentIndex] === coverUrl) {
                  this.failedMovingPhotoUrl = coverUrl
                }
              }
            })
              .width('100%').height('100%')
              .translate({ x: this.swipeTranslateX })
          } else {
            Image(this.urls[this.currentIndex])
              .objectFit(ImageFit.Contain)
              .width('100%').height('100%')
              /* 长按不注册操作：Image 自 API 10 起 draggable 默认 true，长按会被当成拖拽图片。 */
              .draggable(false)
              .scale({ x: this.zoomScale, y: this.zoomScale, centerX: 0, centerY: 0 })
              .translate({ x: this.zoomOffsetX + this.swipeTranslateX, y: this.zoomOffsetY })
              .onComplete((event) => {
                if (event && event.loadingStatus === 1) {
                  this.imgNaturalW = event.width
                  this.imgNaturalH = event.height
                }
              })
              .onError(() => {
              })
          }

          if (this.currentIndex < this.urls.length - 1) {
            Image(this.urls[this.currentIndex + 1])
              .objectFit(ImageFit.Contain)
              .width('100%').height('100%')
              .translate({ x: this.containerW + this.swipeTranslateX })
              .onError(() => {
              })
          }
        }
        .width('100%').height('100%')
        .clip(true)
        .gesture(
          GestureGroup(GestureMode.Exclusive,
            PinchGesture({ fingers: 2 })
              .onActionStart((event: GestureEvent) => {
                if (this.isPageAnimating || this.currentMovingPhotoVideo().length > 0) return
                this.pinchBaseScale = this.zoomScale
                this.pinchBaseOffsetX = this.zoomOffsetX
                this.pinchBaseOffsetY = this.zoomOffsetY
                this.pinchCenterX = event.pinchCenterX
                this.pinchCenterY = event.pinchCenterY
                this.resetPanTracking()
              })
              .onActionUpdate((event: GestureEvent) => {
                if (this.isPageAnimating || this.currentMovingPhotoVideo().length > 0) return
                let newScale: number = this.pinchBaseScale * event.scale
                newScale = Math.max(this.ZOOM_MIN, Math.min(newScale, this.ZOOM_MAX))
                let imgX: number = (this.pinchCenterX - this.pinchBaseOffsetX) / this.pinchBaseScale
                let imgY: number = (this.pinchCenterY - this.pinchBaseOffsetY) / this.pinchBaseScale
                this.zoomScale = newScale
                this.zoomOffsetX = this.pinchCenterX - imgX * newScale
                this.zoomOffsetY = this.pinchCenterY - imgY * newScale
              })
              .onActionEnd(() => {
                if (this.isPageAnimating || this.currentMovingPhotoVideo().length > 0) return
                if (this.zoomScale <= 1) {
                  this.zoomScale = 1
                  this.zoomOffsetX = 0
                  this.zoomOffsetY = 0
                } else {
                  this.zoomOffsetX = this.clampOffsetX(this.zoomScale, this.zoomOffsetX)
                  this.zoomOffsetY = this.clampOffsetY(this.zoomScale, this.zoomOffsetY)
                }
              }),
            TapGesture({ count: 2 })
              .onAction((event: GestureEvent) => {
                if (this.isPageAnimating || this.currentMovingPhotoVideo().length > 0) return
                if (this.zoomScale > 1.01) {
                  this.getUIContext()?.animateTo({ duration: 250, curve: Curve.FastOutSlowIn }, () => {
                    this.zoomScale = 1
                    this.zoomOffsetX = 0
                    this.zoomOffsetY = 0
                  })
                } else {
                  let tapX: number = 0
                  let tapY: number = 0
                  if (event.fingerList && event.fingerList.length > 0) {
                    tapX = event.fingerList[0].localX
                    tapY = event.fingerList[0].localY
                  }
                  let imgW: number = this.calcImgContainedW()
                  let imgH: number = this.calcImgContainedH()
                  let cbx: number = (this.containerW - imgW) / 2
                  let cby: number = (this.containerH - imgH) / 2
                  let newScale: number = this.DOUBLE_TAP_SCALE
                  let oldScale: number = this.zoomScale
                  let imgX: number = (tapX - cbx * oldScale - this.zoomOffsetX) / oldScale
                  let imgY: number = (tapY - cby * oldScale - this.zoomOffsetY) / oldScale
                  let rawOX: number = tapX - cbx * newScale - imgX * newScale
                  let rawOY: number = tapY - cby * newScale - imgY * newScale
                  let clampedOX: number = this.clampOffsetX(newScale, rawOX)
                  let clampedOY: number = this.clampOffsetY(newScale, rawOY)
                  this.getUIContext()?.animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
                    this.zoomScale = newScale
                    this.zoomOffsetX = clampedOX
                    this.zoomOffsetY = clampedOY
                  })
                }
              }),
            PanGesture({ fingers: 1, direction: PanDirection.All, distance: this.SWIPE_DISTANCE })
              .onActionStart((event: GestureEvent) => {
                let isZoomed: boolean = this.zoomScale > 1.01
                if (this.isPageAnimating) return
                this.panToastShown = false
                if (event.fingerList && event.fingerList.length > 0) {
                  this.lastTouchX = event.fingerList[0].localX
                  this.lastTouchY = event.fingerList[0].localY
                }
                this.panStartOffsetX = event.offsetX
                this.panStartOffsetY = event.offsetY
                if (isZoomed) {
                  this.panBaseOffsetX = this.zoomOffsetX
                  this.panBaseOffsetY = this.zoomOffsetY
                } else {
                  this.panBaseSwipeX = this.swipeTranslateX
                }
                this.prevPanX = event.offsetX
                this.prevPanY = event.offsetY
                this.prevSampleTime = event.timestamp
                this.velX = 0
                this.velY = 0
                this.prevVelX = 0
                this.prevVelY = 0
              })
              .onActionUpdate((event: GestureEvent) => {
                if (this.isPageAnimating) return
                if (this.zoomScale > 1.01) {
                  this.zoomOffsetX = this.panBaseOffsetX + event.offsetX
                  this.zoomOffsetY = this.panBaseOffsetY + event.offsetY
                  if (!this.panToastShown) {
                    let dx: number = Math.abs(event.offsetX - this.panStartOffsetX)
                    let dy: number = Math.abs(event.offsetY - this.panStartOffsetY)
                    if (dx > dy && dx > this.SWIPE_THRESHOLD) {
                      this.panToastShown = true
                      appStore.showToast('请先双击恢复缩放，再左右滑动切换图片')
                    }
                  }
                } else {
                  this.swipeTranslateX = this.panBaseSwipeX + event.offsetX
                }
                this.trackVelocity(event.offsetX, event.offsetY, event.timestamp)
              })
              .onActionEnd((event: GestureEvent) => {
                if (this.isPageAnimating) return
                let isZoomed: boolean = this.zoomScale > 1.01
                if (isZoomed) {
                  let flickX: number = this.velX * 0.3
                  let flickY: number = this.velY * 0.3
                  let targetX: number = this.clampOffsetX(this.zoomScale,
                    this.zoomOffsetX + flickX)
                  let targetY: number = this.clampOffsetY(this.zoomScale,
                    this.zoomOffsetY + flickY)
                  this.getUIContext()?.animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
                    this.zoomOffsetX = targetX
                    this.zoomOffsetY = targetY
                  })
                  this.resetPanTracking()
                } else {
                  let dx: number = Math.abs(event.offsetX - this.panStartOffsetX)
                  let dy: number = Math.abs(event.offsetY - this.panStartOffsetY)
                  let hasPrev: boolean = this.currentIndex > 0
                  let hasNext: boolean = this.currentIndex < this.urls.length - 1
                  let swipeAbs: number = Math.abs(this.swipeTranslateX)
                  let isHorizontal: boolean = dx > dy
                  if (isHorizontal && swipeAbs > this.SWIPE_THRESHOLD) {
                    if (this.swipeTranslateX > 0 && hasPrev) {
                      this.doSwipeTo(this.currentIndex - 1)
                    } else if (this.swipeTranslateX < 0 && hasNext) {
                      this.doSwipeTo(this.currentIndex + 1)
                    } else {
                      this.doSwipeBounceBack()
                    }
                  } else {
                    this.doSwipeBounceBack()
                  }
                  this.resetPanTracking()
                }
              })
          )
        )
        .onAreaChange((oldValue: Area, newValue: Area) => {
          if ((newValue.width as number) > 0) this.containerW = newValue.width as number
          if ((newValue.height as number) > 0) this.containerH = newValue.height as number
        })

        Stack() {
          Image($r('app.media.icon_close'))
            .width(20).height(20)
            .fillColor(UIMaterialManager.onDarkForeground)
            // Image 的 draggable 自 API 10 起默认为 true：长按会被系统当成"拖拽图片"（见 §12.9）
            .draggable(false)
        }
        .width(38).height(38).borderRadius(19)
        .position({ top: 4, right: 16 })
        .accessibilityText('关闭图片预览')
        .attributeModifier(UIMaterialManager.closeButtonMaterial)
        .onClick(() => {
          this.onClose()
        })
      }
      .layoutWeight(1)
      .width('100%')

      Row() {
        Text(`${this.currentIndex + 1} / ${this.urls.length}`)
          .fontSize(15).fontColor(AppColors.white)
        Blank().layoutWeight(1)
        Button(this.sharing ? '分享中...' : '分享')
          .fontSize(14).fontColor(UIMaterialManager.onDarkForeground)
          .borderRadius(16)
          .height(32)
          .type(ButtonType.Capsule)
          .attributeModifier(UIMaterialManager.darkOverlayMaterial)
          .enabled(!this.sharing)
          .onClick(async () => {
            await this.shareCurrentImage()
          })
        Stack() {
          SaveButton({ text: SaveDescription.SAVE, buttonType: ButtonType.Normal })
            .fontSize(14)
            .fontColor(AppColors.white)
            .backgroundColor(AppColors.imageViewerButtonBg)
            .borderRadius(16)
            .height(32)
            .padding({ left: 20, right: 20 })
            .onClick(async (_event: ClickEvent, result: SaveButtonOnClickResult) => {
              if (result === SaveButtonOnClickResult.SUCCESS) {
                await this.saveCurrentImage()
              }
            })
        }
          .margin({ left: 12 })
      }
      .width('100%')
      .padding({ top: 6, bottom: 15 + this.navBarHeight, left: 16, right: 16 })
    }
    .width('100%').height('100%')
    .padding({ top: this.statusBarHeight })
    .backgroundColor(AppColors.imageViewerBg)
  }
}
