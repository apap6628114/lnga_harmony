/**
 * 动态照片沙箱缓存路径（单源）。
 *
 * 动态照片播放需要把「封面图 + 视频」两份资源落到应用沙箱后交给
 * `MediaAssetManager.loadMovingPhoto`，缓存目录因此被两处共用：
 * - `MovingPhotoPlayer`：写入与复用；
 * - `SettingsPanel.clearCache`：清理（该目录位于持久目录 `filesDir` 下，
 *   不在系统 `cacheDir` 范围内，不显式清理会一直残留）。
 */

/** 缓存目录名（位于应用 `filesDir` 下）。 */
export const MOVING_PHOTO_CACHE_DIR: string = 'mphoto'

/**
 * 计算动态照片缓存目录的绝对路径。
 *
 * @param filesDir 应用持久目录（`Context.filesDir`）
 * @returns 缓存目录绝对路径
 */
export function movingPhotoCacheDir(filesDir: string): string {
  return `${filesDir}/${MOVING_PHOTO_CACHE_DIR}`
}
