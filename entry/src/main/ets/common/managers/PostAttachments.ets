/**
 * 发帖 / 回帖提交用的附件参数容器（`ReplyManager` 与 `NewTopicManager` 共用）。
 *
 * 上传接口按「一次上传」签发一对参数：`attachments`（提交参数）与 `attachments_check`
 * （校验参数），必须随提交一起发给 `post` 接口。客户端这一侧最容易出的错是**参数与正文
 * 失去同步**——用户上传后把正文里的 `[img]` 删掉、或清空正文放弃编辑，附件码却继续随
 * 提交发出，于是服务端收到「正文与附件不匹配」的请求。
 *
 * 官方客户端的等价物是 `PostFragment.mAttachArray` / `mAttachCheckArray`：上传成功
 * `handleUploadComplete` 成对 `add`、删除媒体 `removeFromUploadedList` 成对 `remove`、
 * 编辑时从 `ActionCheck.getAttachArray()` 成对回填，天生与正文标签一一对应。
 * 本工程的正文是自由文本框（用户可随手改），只能在提交时按正文反查一次。
 */

import type { UploadAttachmentResult } from '../../model/NgaApiResults'

/**
 * 一项待提交的附件：服务端签发的提交参数 + 这张图的落地地址。
 *
 * `url` 单独留着，是为了在提交前核对「正文是否真的引用了这个附件」。
 */
export class PendingAttachment {
  /** 服务端附件提交参数（上传响应的 `attachments`）。 */
  attachment: string = ''

  /** 服务端附件校验参数（上传响应的 `attachments_check`）。 */
  check: string = ''

  /** 图片地址（正文 `[img]./<url>[/img]` 里的那一段）；空串表示不参与正文核对。 */
  url: string = ''
}

/** 提交用的附件参数对（`post` 接口的 `attachments` / `attachments_check` 字段）。 */
export class AttachmentParams {
  /** 过滤后的 `attachments` 参数（tab 拼接，含尾 `\t`）。 */
  attachments: string = ''

  /** 过滤后的 `attachments_check` 参数（同上）。 */
  attachmentsCheck: string = ''

  /** 本次实际保留的附件项数。 */
  kept: number = 0

  /** 因正文未引用而被丢弃的附件项数。 */
  dropped: number = 0
}

/**
 * 按 tab 拆出非空元素。
 *
 * 与官方 `L0` 的拼接语义对称：两个参数各自跳过空元素，长度允许不等。
 *
 * @param joined - tab 拼接串
 * @returns 非空元素数组
 */
export function splitNonEmpty(joined: string): string[] {
  const parts: string[] = joined.split('\t')
  const result: string[] = []
  for (let i: number = 0; i < parts.length; i++) {
    if (parts[i].length > 0) {
      result.push(parts[i])
    }
  }
  return result
}

/**
 * 累积一次上传的附件。
 *
 * 这里**不因为 `attachments_check` 为空而判定失败**：官方 `L0` 对
 * `mAttachArray` / `mAttachCheckArray` 是各自独立跳过空元素拼接的（两个列表长度允许
 * 不等），上传响应只回一半属于服务端形态差异；客户端据此判失败，会让「这种响应形态下
 * 所有插图都发不出去」，比间歇性报错更重。
 *
 * 但 `attachments`（**提交参数**）为空是另一回事：没有它这条上传就不会随提交发出，
 * 而正文里的 `[img]` 已经指向这次上传的地址 —— 服务端收到的是"正文引用了不存在的附件"。
 * 早先这里**静默 `return`**（B6）：调用方（含懒重传）以为记下了，正文拿到新地址、
 * 请求里却没有对应参数，图片在帖子里丢失且没有任何提示。
 * 现在把「是否真的记下」回报给调用方，由它决定按失败处理。
 *
 * @param items - 累积列表
 * @param uploadResult - 单次上传结果
 * @returns 是否记下了（`attachments` 为空时返回 false，调用方必须据此判失败）
 */
export function appendPendingAttachment(items: PendingAttachment[],
  uploadResult: UploadAttachmentResult): boolean {
  if (uploadResult.attachments.length === 0) {
    return false
  }
  const item: PendingAttachment = new PendingAttachment()
  item.attachment = uploadResult.attachments
  item.check = uploadResult.attachmentsCheck
  item.url = uploadResult.url
  items.push(item)
  return true
}

/**
 * 回填服务端 `post/check` 返回的既有附件（编辑场景）。
 *
 * 每一项的 `url` 留空：这些附件是帖子已存在的，客户端没有它们的图片地址，
 * 无法参与「正文是否引用」的核对，因此一律保留（与官方 `ActionCheck.attachArray`
 * 的回填语义一致）。两个数组按下标配对，`attachments_check` 缺位时留空串，
 * 拼接阶段按官方语义跳过空元素。
 *
 * @param items - 累积列表
 * @param attachments - `attachArray` 解析后的 tab 拼接串
 * @param checks - `attachCheckArray` 解析后的 tab 拼接串
 */
export function restoreServerAttachments(items: PendingAttachment[], attachments: string,
  checks: string): void {
  const attachParts: string[] = splitNonEmpty(attachments)
  const checkParts: string[] = splitNonEmpty(checks)
  for (let i: number = 0; i < attachParts.length; i++) {
    const item: PendingAttachment = new PendingAttachment()
    item.attachment = attachParts[i]
    item.check = i < checkParts.length ? checkParts[i] : ''
    items.push(item)
  }
}

/**
 * 按正文实际引用拼出提交用的附件参数。
 *
 * 只保留「正文里确实引用了该附件地址」的项；`url` 为空的项（编辑回填的服务端既有附件）
 * 无从核对，一律保留。拼接按官方 `L0` 语义：每个非空元素后追加 `\t`（含尾 `\t`），
 * 空元素跳过。
 *
 * @param items - 累积列表
 * @param content - 本次提交的正文（引用场景含服务端引用块）
 * @returns 过滤后的附件参数对
 */
export function buildAttachmentParams(items: PendingAttachment[], content: string): AttachmentParams {
  const params: AttachmentParams = new AttachmentParams()
  for (let i: number = 0; i < items.length; i++) {
    const item: PendingAttachment = items[i]
    if (item.url.length > 0 && content.indexOf(item.url) < 0) {
      params.dropped++
      continue
    }
    if (item.attachment.length > 0) {
      params.attachments += item.attachment + '\t'
    }
    if (item.check.length > 0) {
      params.attachmentsCheck += item.check + '\t'
    }
    params.kept++
  }
  return params
}
