import { LruCache } from '../cache/LruCache';

/**
 * 图片尺寸缓存工具。
 *
 * 原「预热图片尺寸」功能已移除（预热 = 每图额外一次 Range 请求，请求数翻倍
 * 更易触发服务端节流）。本文件精简为纯内存缓存：图片实际加载完成后由
 * BBCodeContentView.onImageLoaded 回填尺寸，同会话内再次渲染同一图片时
 * 直接复用缓存尺寸做占位比例，零额外网络请求。
 *
 * 注意：ImageSize 类同时被 VideoSizeUtil（视频尺寸，独立功能）引用，不得删除。
 */

export class ImageSize {
  width: number = 0;
  height: number = 0;
}

const cache: LruCache<ImageSize> = new LruCache<ImageSize>(500);

/**
 * 查询图片尺寸缓存。
 *
 * @param url 图片地址
 * @returns 缓存的尺寸；未命中时返回 null
 */
export function getCachedImageSize(url: string): ImageSize | null {
  const r: ImageSize | undefined = cache.get(url);
  if (r) {
    return r;
  }
  return null;
}

/**
 * 写入图片尺寸缓存（图片加载完成后由渲染层回填）。
 *
 * @param url 图片地址
 * @param size 图片尺寸
 */
export function setCachedImageSize(url: string, size: ImageSize): void {
  cache.set(url, size);
}
