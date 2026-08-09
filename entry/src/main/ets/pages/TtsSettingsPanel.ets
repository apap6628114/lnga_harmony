import { textToSpeech } from '@kit.CoreSpeechKit'
import { BusinessError, Callback, ErrorCallback } from '@kit.BasicServicesKit'
import { appStore } from '../store/AppStore'
import { AppColors } from '../common/constants/Constants'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { TtsPlayer } from '../common/media/TtsPlayer'
import { PageScope } from '../common/concurrency/PageScope'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'

const VOICE_OPTIONS: VoiceOption[] = [
  { person: 13, label: '聆小珊', lang: '中文' },
  { person: 21, label: '凌飞哲', lang: '中文' },
  { person: 8, label: '劳拉', lang: '英文' },
]

interface VoiceOption {
  person: number
  label: string
  lang: string
}

@Component
export struct TtsSettingsPanel {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @State currentPerson: number = appStore.settings.ttsPerson
  @State currentSpeed: number = appStore.settings.ttsSpeed
  @State currentVolume: number = appStore.settings.ttsVolume
  @State currentPitch: number = appStore.settings.ttsPitch
  @State installedSet: number[] = []
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 滚动容器当前视口高度。 */
  @State scrollViewportHeight: number = 1
  private previousPerson: number = appStore.settings.ttsPerson
  /** 页面出现会话作用域，驱动异步回调的存活与代际校验。 */
  private scope: PageScope = new PageScope()
  /** 语音设置页滚动控制器。 */
  private scroller: Scroller = new Scroller()

  /** 按滚动容器绝对偏移同步标题栏视觉效果。 */
  private syncTitleScrollEffect(): void {
    const progress: number = TitleScrollEffect.getProgress(
      this.scroller.currentOffset().yOffset,
      this.statusBarHeight
    )
    if (TitleScrollEffect.shouldUpdateProgress(this.titleScrollEffectProgress, progress)) {
      this.titleScrollEffectProgress = progress
    }
  }

  aboutToAppear(): void {
    this.scope.begin()
    this.queryInstalledVoices()
  }

  aboutToDisappear(): void {
    this.scope.end()
    if (TtsPlayer.isSpeaking(-2)) {
      TtsPlayer.stop()
    }
  }

  private queryInstalledVoices(): void {
    const gen: number = this.scope.begin()
    const query: textToSpeech.VoiceQuery = {
      requestId: 'qry_' + Date.now(),
      online: 1
    }
    textToSpeech.listVoices(query).then((voices: textToSpeech.VoiceInfo[]) => {
      if (!this.scope.isActive(gen)) {
        return
      }
      const installed: number[] = []
      for (let i = 0; i < voices.length; i++) {
        if (voices[i].status === 'INSTALLED') {
          installed.push(voices[i].person)
        }
      }
      this.installedSet = installed
    }).catch(() => {
      if (!this.scope.isActive(gen)) {
        return
      }
      this.installedSet = [13]
    })
  }

  private markInstalled(person: number): void {
    if (this.installedSet.indexOf(person) === -1) {
      this.installedSet = [...this.installedSet, person]
    }
  }

  private isInstalled(person: number): boolean {
    return this.installedSet.indexOf(person) !== -1
  }

  private getDesc(person: number): string {
    if (person === 13) {
      return '推荐'
    }
    if (this.isInstalled(person)) {
      return '已安装'
    }
    return '需下载'
  }

  private downloadVoice(person: number, label: string): void {
    const lang: string = person === 8 ? 'en-US' : 'zh-CN'
    const downloadParams: textToSpeech.VoiceDownload = {
      requestId: 'dl_' + person + '_' + Date.now(),
      language: lang,
      person: person,
      style: 'interaction-broadcast'
    }
    appStore.showToast('正在下载' + label + '...')
    textToSpeech.downloadVoice(downloadParams,
      (err: BusinessError, downloadResponse: textToSpeech.DownloadResponse) => {
        if (!this.scope.isAlive()) {
          return
        }
        if (err) {
          if (err.code === 1002300010) {
            this.markInstalled(person)
            appStore.showToast(label + '已安装')
            return
          }
          appStore.showToast('当前设备不支持下载此音色')
          this.currentPerson = this.previousPerson
          appStore.settingsStore.setTtsPerson(this.previousPerson)
          return
        }
        downloadResponse.on('complete', (voiceInfo: textToSpeech.VoiceInfo) => {
          if (!this.scope.isAlive()) {
            return
          }
          this.markInstalled(person)
          appStore.showToast(label + '下载完成')
        })
        let errorCallback: ErrorCallback<BusinessError> = (error: BusinessError) => {
          if (!this.scope.isAlive()) {
            return
          }
          appStore.showToast('当前设备不支持下载此音色')
          this.currentPerson = this.previousPerson
          appStore.settingsStore.setTtsPerson(this.previousPerson)
        }
        downloadResponse.on('error', errorCallback)
      })
  }

  build() {
    Stack() {
      Column() {
        Scroll(this.scroller) {
          Column() {
            // ---- 音色选择 ----
            Column() {
              Text('音色').fontSize(15).fontColor(AppColors.textSecondary)
                .width('100%').padding({ bottom: 10 })

              Row() {
                ForEach(VOICE_OPTIONS, (opt: VoiceOption) => {
                  this.VoiceCard(opt)
                }, (opt: VoiceOption) => String(opt.person))
              }
              .width('100%')
            }
            .width('92%')
            .backgroundColor(AppColors.bgTertiary)
            .borderRadius(12)
            .padding(12)
            .margin({ top: 16 })

            // ---- 参数调节 ----
            Column() {
              Row() {
                Text('语速').fontSize(16).fontColor(AppColors.textPrimary).width(48)
                Slider({
                  value: this.currentSpeed,
                  min: 0.5,
                  max: 2,
                  step: 0.1,
                  style: SliderStyle.InSet
                })
                  .onChange((v: number, mode: SliderChangeMode) => {
                    this.currentSpeed = v
                    appStore.settingsStore.setTtsSpeed(v)
                  })
                  .layoutWeight(1)
                  .height(40)
                Text(`${this.currentSpeed.toFixed(1)}x`).fontSize(14)
                  .fontColor(AppColors.textSecondary).width(48).textAlign(TextAlign.End)
              }
              .width('100%').height(48).padding({ left: 16, right: 16 }).alignItems(VerticalAlign.Center)

              Divider().margin({ left: 16 }).color(AppColors.separator)

              Row() {
                Text('音量').fontSize(16).fontColor(AppColors.textPrimary).width(48)
                Slider({
                  value: this.currentVolume,
                  min: 0,
                  max: 2,
                  step: 0.1,
                  style: SliderStyle.InSet
                })
                  .onChange((v: number, mode: SliderChangeMode) => {
                    this.currentVolume = v
                    appStore.settingsStore.setTtsVolume(v)
                  })
                  .layoutWeight(1)
                  .height(40)
                Text(`${this.currentVolume.toFixed(1)}x`).fontSize(14)
                  .fontColor(AppColors.textSecondary).width(48).textAlign(TextAlign.End)
              }
              .width('100%').height(48).padding({ left: 16, right: 16 }).alignItems(VerticalAlign.Center)

              Divider().margin({ left: 16 }).color(AppColors.separator)

              Row() {
                Text('音调').fontSize(16).fontColor(AppColors.textPrimary).width(48)
                Slider({
                  value: this.currentPitch,
                  min: 0.5,
                  max: 2,
                  step: 0.1,
                  style: SliderStyle.InSet
                })
                  .onChange((v: number, mode: SliderChangeMode) => {
                    this.currentPitch = v
                    appStore.settingsStore.setTtsPitch(v)
                  })
                  .layoutWeight(1)
                  .height(40)
                Text(`${this.currentPitch.toFixed(1)}x`).fontSize(14)
                  .fontColor(AppColors.textSecondary).width(48).textAlign(TextAlign.End)
              }
              .width('100%').height(48).padding({ left: 16, right: 16 }).alignItems(VerticalAlign.Center)
            }
            .width('92%')
            .backgroundColor(AppColors.bgTertiary)
            .borderRadius(12)
            .padding({ top: 8, bottom: 8 })
            .margin({ top: 12 })

            // ---- 试听 ----
            Row() {
              Text('试听当前设置').fontSize(16).fontColor(AppColors.primary)
                .fontWeight(FontWeight.Medium).layoutWeight(1).textAlign(TextAlign.Center)
            }
            .width('92%')
            .height(44)
            .backgroundColor(AppColors.bgTertiary)
            .borderRadius(12)
            .margin({ top: 12 })
            .onClick(() => {
              TtsPlayer.speak('语音朗读设置已更新，这是当前音色、语速、音量和音调的效果。', -2)
            })
          }
          .width('100%').alignItems(HorizontalAlign.Center).padding({ bottom: 32 })
        }
        .layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
        .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
        .linearGradientBlur(
          TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),
          {
            fractionStops: TitleScrollEffect.getBlurStops(this.scrollViewportHeight, this.statusBarHeight),
            direction: GradientDirection.Bottom
          }
        )
        .onAreaChange((oldValue: Area, newValue: Area): void => {
          if (typeof newValue.height === 'number' && newValue.height !== this.scrollViewportHeight) {
            this.scrollViewportHeight = newValue.height
          }
        })
        .onDidScroll((): void => {
          this.syncTitleScrollEffect()
        })
        .onAppear((): void => {
          this.syncTitleScrollEffect()
        })
      }
      .width('100%').height('100%').backgroundColor(AppColors.bg)

      PanelNavBar({ title: '语音朗读', scrollEffectProgress: this.titleScrollEffectProgress })
        .width('100%').position({ x: 0, y: 0 })
    }
    .width('100%').height('100%')
  }

  @Builder
  VoiceCard(opt: VoiceOption) {
    Column() {
      Text(opt.label).fontSize(15).fontColor(AppColors.textPrimary).fontWeight(FontWeight.Medium)
      Text(opt.lang).fontSize(12).fontColor(AppColors.textTertiary).margin({ top: 4 })
      Text(this.getDesc(opt.person)).fontSize(11).fontColor(AppColors.primary).margin({ top: 2 })
    }
    .layoutWeight(1)
    .margin({ left: 4, right: 4 })
    .padding({ top: 12, bottom: 12 })
    .backgroundColor(this.currentPerson === opt.person ? AppColors.primaryLight : AppColors.bgSecondary)
    .borderRadius(10)
    .border({
      width: this.currentPerson === opt.person ? 1.5 : 1,
      color: this.currentPerson === opt.person ? AppColors.primary : AppColors.separator
    })
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      if (this.currentPerson !== opt.person) {
        this.previousPerson = this.currentPerson
        if (!this.isInstalled(opt.person) && opt.person !== 13) {
          this.downloadVoice(opt.person, opt.label)
        }
        this.currentPerson = opt.person
        appStore.settingsStore.setTtsPerson(opt.person)
      }
    })
  }
}
