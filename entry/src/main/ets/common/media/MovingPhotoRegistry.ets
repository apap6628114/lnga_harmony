/**
 * 动态照片（NGA `[b]MPHOTO[/b]`）封面 → 动态视频地址注册表。
 *
 * 解析层已把「封面图 + `[b]MPHOTO[/b]` + 视频」三元组折叠为单个 IMAGE 节点
 * （`src` = 封面、`videoSrc` = 视频）。查看器只拿到图片地址列表，无法知道
 * 其中哪些是动态照片，因此在渲染正文时顺手把 `封面 → 视频` 关系登记到这里，
 * 查看器按当前封面地址反查即可，避免给 `onImageClick` 回调链层层加参数。
 *
 * 纯数据、无 UI；进程内生命周期，容量达到上限时按插入顺序淘汰最早一项。
 */

/** 注册表容量上限（每条目仅两个 URL 字符串，取足够大的保守值）。 */
const MAX_ENTRIES: number = 800

const registry: Map<string, string> = new Map<string, string>()

/**
 * 登记动态照片的封面与视频地址。
 *
 * @param coverUrl 封面图地址（解析节点 src）
 * @param videoUrl 动态视频地址（解析节点 videoSrc）
 */
export function registerMovingPhoto(coverUrl: string, videoUrl: string): void {
  if (coverUrl.length === 0 || videoUrl.length === 0) {
    return
  }
  if (registry.size >= MAX_ENTRIES) {
    /* Map 保序：forEach 首次回调拿到的即最早插入的键。 */
    let oldest: string = ''
    registry.forEach((_value: string, key: string): void => {
      if (oldest.length === 0) {
        oldest = key
      }
    })
    if (oldest.length > 0) {
      registry.delete(oldest)
    }
  }
  registry.set(coverUrl, videoUrl)
}

/**
 * 查询封面地址对应的动态视频地址。
 *
 * @param coverUrl 封面图地址
 * @returns 动态视频地址；不是动态照片时返回空串
 */
export function getMovingPhotoVideo(coverUrl: string): string {
  const value: string | undefined = registry.get(coverUrl)
  return value === undefined ? '' : value
}
