import { AppColors, ImageLoadStrategy } from '../../constants/Constants'
import { PostInfo, PostAttachInfo } from '../../../model/PostInfo'
import { AudioPlayer } from '../../media/AudioPlayer'
import { MutedVideo } from '../../media/MutedVideo'
import { ImageSize } from '../../media/ImageSizeUtil'
import { fetchVideoSize, getCachedVideoSize } from '../../media/VideoSizeUtil'
import { shouldUsePassive } from '../../utils/NetworkUtil'
import { PageScope } from '../../concurrency/PageScope'

/** 视频附件扩展名集合 */
const VIDEO_EXTS: string[] = ['mp4', 'webm', 'ogg', 'mov', '3gp']

/** 音频附件扩展名集合 */
const AUDIO_EXTS: string[] = ['mp3', 'wav', 'flac', 'aac', 'm4a']

/**
 * 帖子附件区子组件。
 *
 * 负责渲染帖子附件（视频/音频/图片），可折叠展开。展开时会按需异步拉取
 * 视频尺寸以计算宽高比。自持 attachsExpanded（展开状态）与 videoSizes（视频尺寸缓存），
 * 在组件复用时（aboutToReuse）重置为初始值，避免列表复用泄漏上一条的展开状态。
 */
@Component
export struct PostAttachments {
  /** 所属帖子信息（@Prop 值拷贝），附件来自 post.attachs */
  @Prop post: PostInfo = new PostInfo()
  /** 图片加载策略，订阅 AppStorage，决定附件图片是否走被动占位 */
  @StorageProp('imageLoadStrategy') imageLoadStrategy: string = ImageLoadStrategy.ALWAYS
  /** 网络变化版本号，订阅 AppStorage，用于触发 shouldUsePassive 重算 */
  @StorageProp('networkChangeVersion') networkChangeVersion: number = 0
  /** 附件展开状态 */
  @State private attachsExpanded: boolean = false
  /** 已拉取的视频尺寸缓存（url -> 宽高） */
  @State private videoSizes: Map<string, ImageSize> = new Map()
  /** 图片点击回调，传入图片 url 列表与点击项索引 */
  onImageClick: (urls: string[], index: number) => void = (_urls: string[], _index: number) => {}
  /** 组件存活会话作用域，驱动异步回调的存活校验。 */
  private scope: PageScope = new PageScope()

  aboutToAppear(): void {
    this.scope.begin()
  }

  /** 组件消失时结束会话，使未完成的异步回调失效。 */
  aboutToDisappear(): void {
    this.scope.end()
  }

  aboutToReuse(params: Record<string, Object>): void {
    this.attachsExpanded = false
    this.videoSizes = new Map()
  }

  build() {
    Column() {
      Row() {
        Row() {
          if (!this.attachsExpanded) {
            Image($r('app.media.icon_attachment')).width(13).height(13).fillColor(AppColors.textTertiary).margin({ right: 4 })
          }
          Text(this.attachsExpanded ? '收起附件' : `附件 (${this.post.attachs.length})`).fontSize(13).fontColor(AppColors.textTertiary)
        }
          .onClick(() => {
            this.attachsExpanded = !this.attachsExpanded
            if (this.attachsExpanded) {
              this.fetchAttachVideoSizes()
            }
          })
        }.margin({ top: 12 })
        if (this.attachsExpanded) {
        Column() {
          ForEach(this.post.attachs, (att: PostAttachInfo) => {
            this.renderVideoAttach(att)
          })
          ForEach(this.post.attachs, (att: PostAttachInfo) => {
            this.renderAudioAttach(att)
          })
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.post.attachs, (att: PostAttachInfo) => {
              this.renderImageAttach(att)
            })
          }
        }.margin({ top: 4 })
      }
    }
  }

  @Builder
  renderVideoAttach(att: PostAttachInfo) {
    if (VIDEO_EXTS.indexOf(att.ext.toLowerCase()) >= 0) {
      MutedVideo({ src: att.attachurl, videoAspectRatio: this.getAttachVideoAspectRatio(att.attachurl) })
        .margin({ bottom: 6 })
    }
  }

  @Builder
  renderAudioAttach(att: PostAttachInfo) {
    if (AUDIO_EXTS.indexOf(att.ext.toLowerCase()) >= 0) {
      AudioPlayer({ src: att.attachurl })
        .margin({ bottom: 6 })
    }
  }

  @Builder
  renderImageAttach(att: PostAttachInfo) {
    if (VIDEO_EXTS.indexOf(att.ext.toLowerCase()) < 0 && AUDIO_EXTS.indexOf(att.ext.toLowerCase()) < 0) {
      if (shouldUsePassive(this.imageLoadStrategy)) {
        Stack() {
          Image($r('app.media.icon_image'))
            .width(20).height(20)
            .fillColor(AppColors.textTertiary)
            .opacity(0.45)
        }
        .width(100).height(100).borderRadius(8)
        .backgroundColor(AppColors.bgSecondary)
        .margin({ right: 6, top: 6 })
        .onClick(() => { this.dispatchAttachClick(att.attachurl) })
      } else {
        Image(att.attachurl).width(100).height(100).borderRadius(8)
          .objectFit(ImageFit.Cover).backgroundColor(AppColors.bgSecondary)
          .margin({ right: 6, top: 6 }).onError(() => {})
          .onClick(() => { this.dispatchAttachClick(att.attachurl) })
      }
    }
  }

  private getAttachVideoAspectRatio(url: string): number {
    const size: ImageSize | undefined = this.videoSizes.get(url)
    if (size && size.width > 0 && size.height > 0) {
      return size.width / size.height
    }
    return 16 / 9
  }

  private setAttachVideoSize(url: string, size: ImageSize): void {
    const m: Map<string, ImageSize> = new Map()
    this.videoSizes.forEach((v: ImageSize, k: string) => { m.set(k, v) })
    m.set(url, size)
    this.videoSizes = m
  }

  private dispatchAttachClick(targetUrl: string): void {
    const urls: string[] = []
    for (let i = 0; i < this.post.attachs.length; i++) {
      const url = this.post.attachs[i].attachurl
      if (url && url.length > 0) {
        urls.push(url)
      }
    }
    if (urls.length > 0) {
      let idx = 0
      for (let i = 0; i < urls.length; i++) {
        if (urls[i] === targetUrl) {
          idx = i
          break
        }
      }
      this.onImageClick(urls, idx)
    }
  }

  private fetchAttachVideoSizes(): void {
    for (let i = 0; i < this.post.attachs.length; i++) {
      const att: PostAttachInfo = this.post.attachs[i]
      if (VIDEO_EXTS.indexOf(att.ext.toLowerCase()) >= 0 && att.attachurl.length > 0) {
        const cached: ImageSize | null = getCachedVideoSize(att.attachurl)
        if (cached) {
          this.setAttachVideoSize(att.attachurl, cached)
        } else if (!this.videoSizes.has(att.attachurl)) {
          fetchVideoSize(att.attachurl).then((size: ImageSize | null) => {
            if (!this.scope.isAlive()) {
              return
            }
            if (size) {
              this.setAttachVideoSize(att.attachurl, size)
            }
          })
        }
      }
    }
  }
}
