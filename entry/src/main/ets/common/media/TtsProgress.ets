/**
 * TTS 合成进度状态发布器。
 *
 * TTS 合成接口不提供逐段进度回调，进度由协调层按能力估算：
 * 按已接收 PCM 字节数 / 估算总字节数实时估算，每段合成完成后按实际比例校准。
 *
 * 指示组件通过轮询读取状态，避免与播放回调线程产生状态绑定耦合。
 */

/**
 * 全局朗读合成进度状态，由 TtsPlayer 发布、进度指示组件轮询读取。
 */
export class TtsProgressState {
  /** 是否正在合成语音。 */
  visible: boolean = false
  /** 0~100 的进度百分比。 */
  percent: number = -1
}

/**
 * 管理全局朗读合成进度的发布。
 */
export class TtsProgressManager {
  readonly state: TtsProgressState = new TtsProgressState()

  /**
   * 发布合成阶段的估算进度。
   *
   * @param percent 0~100 的估算进度；小于 0 表示不确定。
   */
  showSynthesizing(percent: number): void {
    this.state.percent = Math.max(0, Math.min(100, Math.round(percent)))
    this.state.visible = true
  }

  /**
   * 隐藏合成进度指示。
   */
  hide(): void {
    this.state.visible = false
    this.state.percent = -1
  }
}

/** 全局朗读合成进度发布器单例。 */
export const ttsProgress: TtsProgressManager = new TtsProgressManager()
