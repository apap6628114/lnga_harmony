import { SettingsContext } from '../SettingsContext'
import { SettingsState } from '../SettingsState'
import {
  KEY_IMAGE_LOAD_STRATEGY,
  KEY_NETWORK_CHANGE_VERSION,
  KEY_SHOW_TOPIC_PREVIEW,
  KEY_VIDEO_MUTED,
} from '../../../common/constants/AppStorageKeys'
import { bumpAppStorageVersion } from '../../../common/utils/AppStorageVersion'

/**
 * 媒体设置域子 store。
 *
 * 承载图片加载策略 / 视频静音 / TTS（人声语速音量音调）字段及其 setter。
 */
export class MediaSettings {
  private ctx: SettingsContext

  constructor(ctx: SettingsContext) {
    this.ctx = ctx
  }

  setImageLoadStrategy(v: string): void {
    this.ctx.state.imageLoadStrategy = v
    AppStorage.setOrCreate(KEY_IMAGE_LOAD_STRATEGY, v)
    bumpAppStorageVersion(KEY_NETWORK_CHANGE_VERSION)
    this.ctx.persist()
  }

  /**
   * 设置是否在主题列表卡片显示帖子预览图。
   *
   * 同步 AppStorage 供列表卡片以 `@StorageProp` 响应式读取（开关本身不需要 bump
   * networkChangeVersion——那是网络语义的版本号），并持久化。
   *
   * @param enabled - 是否显示预览图
   */
  setShowTopicPreview(enabled: boolean): void {
    this.ctx.state.showTopicPreview = enabled
    AppStorage.setOrCreate(KEY_SHOW_TOPIC_PREVIEW, enabled)
    this.ctx.persist()
  }

  /** 设置视频全局静音开关（同步 AppStorage 供 UI 响应式读取，并持久化） */
  setVideoMuted(enabled: boolean): void {
    this.ctx.state.videoMuted = enabled
    AppStorage.setOrCreate(KEY_VIDEO_MUTED, enabled)
    this.ctx.persist()
  }

  setTtsPerson(v: number): void {
    this.ctx.state.ttsPerson = v
    this.ctx.persist()
  }

  setTtsSpeed(v: number): void {
    this.ctx.state.ttsSpeed = v
    this.ctx.persist()
  }

  setTtsVolume(v: number): void {
    this.ctx.state.ttsVolume = v
    this.ctx.persist()
  }

  setTtsPitch(v: number): void {
    this.ctx.state.ttsPitch = v
    this.ctx.persist()
  }

  /** 从持久化对象加载媒体字段 */
  load(saved: SettingsState): void {
    if (saved.imageLoadStrategy !== undefined) {
      this.ctx.state.imageLoadStrategy = saved.imageLoadStrategy
    }
    if (saved.showTopicPreview !== undefined) {
      this.ctx.state.showTopicPreview = saved.showTopicPreview
    }
    if (saved.videoMuted !== undefined) this.ctx.state.videoMuted = saved.videoMuted
    if (saved.ttsPerson !== undefined) this.ctx.state.ttsPerson = saved.ttsPerson
    if (saved.ttsSpeed !== undefined) this.ctx.state.ttsSpeed = saved.ttsSpeed
    if (saved.ttsVolume !== undefined) this.ctx.state.ttsVolume = saved.ttsVolume
    if (saved.ttsPitch !== undefined) this.ctx.state.ttsPitch = saved.ttsPitch
  }
}
