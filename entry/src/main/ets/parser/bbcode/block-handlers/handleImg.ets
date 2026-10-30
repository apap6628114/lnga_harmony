import { BBNode, BBNodeType } from '../../../model/BBCodeNode'
import { ImgTagResolution, resolveImgTag } from '../../_shared/AttachUrl'
import { createBBNode, pushTextNode, ParseState } from '../lexer'
import { guessMediaTypeFromExt } from '../inline-parser'

/**
 * [img]图片块处理器。
 *
 * 地址处理与「图片 / 纯文本」判定按官方 `ubbcode.imgGen`（见 `resolveImgTag`）：
 * `./mon_...`（及 `.1/mon_...`）附件相对路径、附件的 `/attachments/` 形态、外链白名单
 * 三类才渲染为图片，其余内容官方**把整个 `[img]...[/img]` 标签替换成纯文本**（如楼主漏写
 * `./` 的 `[img]mon_202609/15/xxx.jpg[/img]`，官方网页渲染成 `https://mon_202609/15/xxx.jpg`
 * 一行文字），此处同语义。
 *
 * 本工程在官方判定之外保留的两处既有差异（改动前即存在，非本次引入）：
 * 1. 命中图片后按扩展名推测媒体类型：`[img]xxx.mp4` 产出 VIDEO、`xxx.mp3` 产出 AUDIO。
 *    官方对该类内容走 `a.type != 'img'` 分支 `return src`（退化为文本），只有 `a.ext`
 *    形如 `mp.mp4` / `gif.mp4` 才转成 `[flash=video]`；保留扩展是为了让 `[img]` 里的
 *    视频/音频仍可播放。媒体节点使用 `resolution.normalizedText`（**不做**图片档位
 *    归一化）：官方对 `a.ext == 'gif.mp4'` 的 app_video 返回 `[flash=video]` + 完整地址，
 *    `stripImageSuffix` 把 `xxx.gif.mp4` 剥成 `xxx.gif` 会让播放器拿到 404 地址
 *    （实测 `.gif` 返回 404、`.gif.mp4` 返回 video/mp4），表现为「有时长的播放器变成 0:00」；
 * 2. `[imgN]`（官方宽度百分比 / 二维码变体，官方正则 `\[img(-?\d{0,3})\]`）不支持，
 *    保持原文显示。
 *
 * @param state 解析游标
 * @param result 当前块级节点输出数组
 * @returns 是否匹配并消费了 `[img]` 标签
 */
/** 普通 [img]URL[/img] 标签正则（内容至少 1 字符，与官方 `(.+?)` 一致）。 */
const P_IMG: RegExp = /\[img\](.+?)\[\/img\]/iy

export const handleImg = (state: ParseState, result: BBNode[]): boolean => {
  P_IMG.lastIndex = state.pos
  const match: RegExpExecArray | null = P_IMG.exec(state.content)
  if (match === null || match.index !== state.pos) return false

  const rawUrl: string = match[1]
  state.pos = P_IMG.lastIndex

  const resolution: ImgTagResolution = resolveImgTag(rawUrl)
  if (!resolution.renderable) {
    pushTextNode(result, resolution.text)
    return true
  }

  const node = createBBNode()
  const guessedType: BBNodeType = guessMediaTypeFromExt(rawUrl)
  /*
   * 媒体地址不做图片档位归一化（用 normalizedText 而非 text）：`stripImageSuffix` 会把
   * `xxx.gif.mp4` 剥成 `xxx.gif`（`.gif` 命中 knownExts），而官方 `imgGen` 对
   * `a.ext == 'gif.mp4'` 的 app_video 返回 `[flash=video]` + 完整地址。图片节点仍用
   * `resolution.text`（必须还原到裸名原图）。
   */
  if (guessedType === BBNodeType.VIDEO || guessedType === BBNodeType.AUDIO) {
    node.type = guessedType
    node.src = resolution.normalizedText
  } else {
    node.type = BBNodeType.IMAGE
    node.src = resolution.text
  }
  result.push(node)
  return true
}
