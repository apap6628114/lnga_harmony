import { BBNode, BBNodeType } from '../../model/BBCodeNode'

/**
 * NGA 动态照片（MovingPhoto）标记折叠。
 *
 * 官方正文形态（2026-09 现网实证，tid=47553967）：
 *
 * ```
 * [img]封面.jpg[/img][b]MPHOTO[/b][flash=video]视频.mp4[/flash]
 * ```
 *
 * 官方网页把它渲染为「`<img>` + 粗体 `MPHOTO` 文字 + `<video>`」三个并列元素，
 * 官方 App 则渲染为一体化的动态照片控件。本工程按 App 语义在解析阶段折叠：
 * 封面 IMAGE 节点保留（`src` 不变），视频地址写入其 `videoSrc`，
 * `MPHOTO` 标记与视频节点从节点序列中移除。
 *
 * 折叠是**容错**的：三元组不完整（缺封面、缺标记或缺视频）时原样保留全部节点，
 * 解析结果退化为折叠前的行为（封面图 + 文字 + 视频播放器）。
 */

/** 动态照片标记文字（`[b]MPHOTO[/b]`，大小写不敏感）。 */
const MPHOTO_MARKER: string = 'mphoto'

/**
 * 判断节点是否为可跳过的空白文字节点。
 *
 * 动态照片三元组之间可能存在空白文本（`<br/>` 预处理后的换行、多余空格）。
 *
 * @param node 待判定节点
 * @returns 是否为纯空白 TEXT 节点
 */
function isBlankTextNode(node: BBNode): boolean {
  return node.type === BBNodeType.TEXT && node.text.trim().length === 0
}

/**
 * 判断节点是否为动态照片标记 `[b]MPHOTO[/b]`。
 *
 * 仅接受「BOLD 节点且其唯一子节点为纯文本 MPHOTO」这一形态，避免把正文里
 * 恰好加粗的 MPHOTO 字样之外的内容误判。
 *
 * @param node 待判定节点
 * @returns 是否为动态照片标记
 */
function isMovingPhotoMarker(node: BBNode): boolean {
  if (node.type !== BBNodeType.BOLD) return false
  if (node.children.length !== 1) return false
  const child: BBNode = node.children[0]
  return child.type === BBNodeType.TEXT && child.text.trim().toLowerCase() === MPHOTO_MARKER
}

/**
 * 取出媒体节点的地址（VIDEO 用 src；FLASH 兜底用 href）。
 *
 * `[flash=video]` / `[flash]x.mp4[/flash]` 产出 VIDEO；非视频扩展名的无类型
 * `[flash]` 产出 FLASH（地址在 href）。两者都视为动态照片的动态部分。
 *
 * @param node 媒体节点
 * @returns 媒体地址；非视频类媒体返回空串
 */
function mediaUrlOf(node: BBNode): string {
  if (node.type === BBNodeType.VIDEO) return node.src
  if (node.type === BBNodeType.FLASH) return node.href
  return ''
}

/**
 * 折叠节点序列中的动态照片三元组（就地修改封面节点，返回新数组）。
 *
 * 保留封面节点位置与其之间的空白文本节点（维持文本零丢失），仅移除
 * `MPHOTO` 标记节点与视频节点。
 *
 * 调用点（两处，缺一会漏折叠）：
 * - `parser.ts::parseBlockNodes` —— 顶层与 quote/collapse/format/album/style 等嵌套层的公共出口；
 * - `parser.ts::parseListItems` —— 列表项正文直连 `parseBlockNodesUntil`，必须显式调用。
 *
 * @param nodes 当前层解析出的语义节点
 * @returns 折叠后的语义节点
 */
export function foldMovingPhotos(nodes: BBNode[]): BBNode[] {
  if (nodes.length < 3) return nodes
  const folded: BBNode[] = []
  let index: number = 0
  while (index < nodes.length) {
    const cover: BBNode = nodes[index]
    if (cover.type === BBNodeType.IMAGE && cover.src.length > 0) {
      let markerIndex: number = index + 1
      while (markerIndex < nodes.length && isBlankTextNode(nodes[markerIndex])) markerIndex++
      if (markerIndex < nodes.length && isMovingPhotoMarker(nodes[markerIndex])) {
        let mediaIndex: number = markerIndex + 1
        while (mediaIndex < nodes.length && isBlankTextNode(nodes[mediaIndex])) mediaIndex++
        if (mediaIndex < nodes.length) {
          const mediaUrl: string = mediaUrlOf(nodes[mediaIndex])
          if (mediaUrl.length > 0) {
            cover.videoSrc = mediaUrl
            folded.push(cover)
            /* 三元组之间的空白文本按原顺序补回（标记与视频节点本身不再保留）。 */
            for (let i: number = index + 1; i < mediaIndex; i++) {
              if (i !== markerIndex) folded.push(nodes[i])
            }
            index = mediaIndex + 1
            continue
          }
        }
      }
    }
    folded.push(cover)
    index++
  }
  return folded
}
