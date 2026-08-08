import { http } from '@kit.NetworkKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { appStore } from '../../store/AppStore';
import { AppColors } from '../constants/Constants';
import { KEY_IMMERSIVE_MATERIAL_ENABLED } from '../constants/AppStorageKeys';
import { UIMaterialManager } from '../managers/UIMaterialManager';
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
  @StorageProp(KEY_IMMERSIVE_MATERIAL_ENABLED) materialEnabled: boolean = true
  @State saving: boolean = false
  @State sharing: boolean = false

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

  private async saveCurrentImage(): Promise<void> {
    if (this.saving) return
    this.saving = true
    try {
      let url: string = this.urls[this.currentIndex]
      let ext: string = this.getExtension(url)
      let ctx: Context = this.getUIContext().getHostContext() as Context
      let sandboxDir: string = ctx.filesDir
      let fileName: string = `temp_${Date.now()}.${ext}`
      let sandboxFileUri: string = `file://${sandboxDir}/${fileName}`

      let httpRequest: http.HttpRequest = http.createHttp()
      let response: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.GET
      })
      httpRequest.destroy()

      let result: ArrayBuffer = response.result as ArrayBuffer
      let file: fileIo.File = await fileIo.open(sandboxFileUri,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE)
      await fileIo.write(file.fd, result)
      fileIo.close(file)

      let phAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx)
      let assetChangeRequest = photoAccessHelper.MediaAssetChangeRequest.createImageAssetRequest(
        ctx, sandboxFileUri)
      await phAccessHelper.applyChanges(assetChangeRequest)
      appStore.showToast('已保存到相册')
    } catch (err) {
      logger.error('[ImageViewer] save failed: %{public}s', formatError(err))
      appStore.showToast('保存失败')
    } finally {
      this.saving = false
    }
  }

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

      let result: ArrayBuffer = response.result as ArrayBuffer
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

          Image(this.urls[this.currentIndex])
            .objectFit(ImageFit.Contain)
            .width('100%').height('100%')
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
                if (this.isPageAnimating) return
                this.pinchBaseScale = this.zoomScale
                this.pinchBaseOffsetX = this.zoomOffsetX
                this.pinchBaseOffsetY = this.zoomOffsetY
                this.pinchCenterX = event.pinchCenterX
                this.pinchCenterY = event.pinchCenterY
                this.resetPanTracking()
              })
              .onActionUpdate((event: GestureEvent) => {
                if (this.isPageAnimating) return
                let newScale: number = this.pinchBaseScale * event.scale
                newScale = Math.max(this.ZOOM_MIN, Math.min(newScale, this.ZOOM_MAX))
                let imgX: number = (this.pinchCenterX - this.pinchBaseOffsetX) / this.pinchBaseScale
                let imgY: number = (this.pinchCenterY - this.pinchBaseOffsetY) / this.pinchBaseScale
                this.zoomScale = newScale
                this.zoomOffsetX = this.pinchCenterX - imgX * newScale
                this.zoomOffsetY = this.pinchCenterY - imgY * newScale
              })
              .onActionEnd(() => {
                if (this.isPageAnimating) return
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
                if (this.isPageAnimating) return
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

        Image($r('app.media.icon_close'))
          .width(38).height(38)
          .fillColor(AppColors.white)
          .position({ top: 4, right: 16 })
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
          .fontSize(14).fontColor(AppColors.white)
          .backgroundColor(this.materialEnabled ? Color.Transparent : AppColors.imageViewerButtonBg)
          .systemMaterial(this.materialEnabled ? UIMaterialManager.fabMaterial : undefined)
          .borderRadius(16)
          .height(32)
          .type(ButtonType.Capsule)
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
