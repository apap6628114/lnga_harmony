/**
 * TTS 引擎错误码翻译层。
 *
 * 收纳 TtsPlaybackCoordinator 中散落的引擎错误码魔法数字与对应文案/行为，
 * 全部为纯函数，可安全独立测试。
 */

/** 音色数据未下载的错误码（引擎创建失败场景）。 */
export const TTS_ERROR_VOICE_NOT_DOWNLOADED_1: number = 1002300003
/** 音色数据未下载的错误码（引擎创建失败场景）。 */
export const TTS_ERROR_VOICE_NOT_DOWNLOADED_2: number = 1002300005
/** 合成中断错误码：需要释放引擎实例的场景。 */
export const TTS_ERROR_SYNTHESIS_ENGINE_RELEASE: number = 1002300007

/**
 * 判断引擎创建错误码是否表示"音色未下载"。
 *
 * @param code 引擎创建错误码。
 * @returns 是否应在 Toast 提示先下载音色。
 */
export function isVoiceNotDownloadedError(code: number): boolean {
  return code === TTS_ERROR_VOICE_NOT_DOWNLOADED_1 || code === TTS_ERROR_VOICE_NOT_DOWNLOADED_2
}

/**
 * 判断合成错误码是否表示引擎需要释放（引擎损坏/重启场景）。
 *
 * @param code 合成错误码。
 * @returns 是否应释放当前引擎实例。
 */
export function shouldReleaseEngineOnError(code: number): boolean {
  return code === TTS_ERROR_SYNTHESIS_ENGINE_RELEASE
}
