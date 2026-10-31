import { draftUidPart, rewriteDraftKeyUidPart } from '../utils/DraftKeyUtils'

/**
 * 草稿导出「可移植化」：清空草稿里的媒体副本引用。
 *
 * ## 为什么需要它
 * `draft_media` 域（草稿图片/视频的沙箱副本）按设计**永不导出**（体积大、路径不可移植），
 * 但草稿 JSON 里带着 `media[].localPath` / `videoLocalPath` 这些**导出设备上的沙箱绝对路径**。
 * 如果原样写进备份，导入到另一台设备后：
 * - 编辑器检测到 media 条目 → 发送时尝试读取本地副本 → 报「本地副本已不存在」；
 * - 用户需要手工逐条删除/重选，体验差且容易被误判为"草稿损坏"。
 *
 * 因此导出时把 `media` 清空（正文与其余字段保留）。草稿重新打开后按"没有媒体"处理，
 * 用户重新选图即可正常发送（`DraftStore` 的 `normalizeMedia` 接受空数组）。
 *
 * ## 边界
 * - 只清空 `media` 数组，不修改其它字段，也不修改入参对象（重建返回），保证导出快照与内存态隔离；
 * - 非数组载荷（异常数据）原样返回、计数为 0；
 * - 纯函数（无 IO），便于单测。
 */

/** 草稿媒体字段名（与 `EditorDraft.media` 一致）。 */
const MEDIA_FIELD: string = 'media'

/** 草稿键字段名（与 `EditorDraft.key` 一致）。 */
const KEY_FIELD: string = 'key'

/**
 * 可移植化结果。
 */
export class DraftPortabilityResult {
  /** 处理后的载荷（草稿条数不变，来源条目已清除媒体引用）。 */
  payload: Object = new Object()
  /** 被清除媒体引用的草稿条数。 */
  strippedDrafts: number = 0
  /** 被清除的媒体条目总数。 */
  strippedMedia: number = 0
}

/**
 * 清空草稿载荷里的媒体引用（导出前调用）。
 *
 * @param payload - 草稿域载荷（文件域导出恒为数组）
 * @returns 可移植化结果（不修改入参）
 */
export function makeDraftsPortable(payload: Object): DraftPortabilityResult {
  const result: DraftPortabilityResult = new DraftPortabilityResult()
  if (!Array.isArray(payload)) {
    result.payload = payload
    return result
  }
  const items: Object[] = payload as Object[]
  const portable: Object[] = []
  for (let i: number = 0; i < items.length; i++) {
    const item: Object = items[i]
    if (item === null || item === undefined || Array.isArray(item) || typeof item !== 'object') {
      portable.push(item)
      continue
    }
    const record: Record<string, Object> = item as Record<string, Object>
    const media: Object | undefined = record[MEDIA_FIELD]
    let mediaCount: number = 0
    if (media !== undefined && media !== null && Array.isArray(media)) {
      mediaCount = (media as Object[]).length
    }
    /*
     * 重建对象时**保持原字段顺序**（`media` 在原位置替换为空数组）：合并器用 `JSON.stringify`
     * 判等，若把 media 挪到末尾，"本机无媒体 + 导入无媒体但字段顺序不同"的同一份草稿会被
     * 误判为已变化（评审 R-C05），导致计划显示"更新"并触发无意义写盘。
     * 旧版草稿可能没有 media 字段：此时补一个空数组（与 DraftStore 读写形态一致）。
     */
    const next: Record<string, Object> = {}
    const keys: string[] = Object.keys(record)
    let hasMedia: boolean = false
    for (let k: number = 0; k < keys.length; k++) {
      const field: string = keys[k]
      if (field === MEDIA_FIELD) {
        next[field] = []
        hasMedia = true
      } else {
        next[field] = record[field]
      }
    }
    if (!hasMedia) {
      next[MEDIA_FIELD] = []
    }
    if (mediaCount > 0) {
      result.strippedDrafts++
      result.strippedMedia += mediaCount
    }
    portable.push(next)
  }
  result.payload = portable
  return result
}

/**
 * 草稿按账号过滤结果。
 */
export class DraftFilterResult {
  /** 过滤后的载荷（非数组时与入参相同）。 */
  payload: Object = new Object()
  /** 被过滤掉（键尾不属于当前账号）的草稿条数。 */
  filtered: number = 0
}

/**
 * 只保留属于当前账号的草稿（按键尾账号片段判断）。
 *
 * 背景（评审 R-A01）：草稿目录是**设备级**的，同一设备上多个账号的草稿文件共存；导出原本
 * 读取整个目录（会把其他账号的草稿正文带进备份），导入计划读取本机载荷也用整目录
 * （合并后又被统一改键写盘 → 把其他账号草稿复制给当前账号）。两处都必须先按当前账号过滤：
 * - 导出：备份只包含当前账号的草稿（跨账号"找回"仍成立：备份来自哪个账号就恢复哪个账号的草稿）；
 * - 导入：本机其他账号的草稿不参与合并，也不会被改键复制。
 *
 * 未登录时账号片段为 `anon`，与编辑器生成草稿键的规则一致。
 *
 * @param payload - 草稿域载荷（文件域导出恒为数组）
 * @param uid - 当前登录 uid
 * @returns 过滤结果（不修改入参；非数组原样返回）
 */
export function filterDraftsForAccount(payload: Object, uid: string): DraftFilterResult {
  const result: DraftFilterResult = new DraftFilterResult()
  if (!Array.isArray(payload)) {
    result.payload = payload
    return result
  }
  const uidPart: string = draftUidPart(uid)
  const items: Object[] = payload as Object[]
  const kept: Object[] = []
  for (let i: number = 0; i < items.length; i++) {
    const item: Object = items[i]
    if (item === null || item === undefined || Array.isArray(item) || typeof item !== 'object') {
      // 非对象条目交由写入阶段校验（这里不因无法判断而误过滤）
      kept.push(item)
      continue
    }
    const record: Record<string, Object> = item as Record<string, Object>
    const rawKey: Object | undefined = record[KEY_FIELD]
    const key: string = typeof rawKey === 'string' ? rawKey as string : ''
    if (key.length === 0) {
      kept.push(item)
      continue
    }
    const index: number = key.lastIndexOf('_')
    const tail: string = index >= 0 && index + 1 < key.length ? key.substring(index + 1) : ''
    if (tail === uidPart) {
      kept.push(item)
    } else {
      result.filtered++
    }
  }
  result.payload = kept
  return result
}

/**
 * 草稿键归一化结果。
 */
export class DraftKeyNormalizeResult {
  /** 归一化后的载荷（非数组时与入参相同）。 */
  payload: Object = new Object()
  /** 实际改写了键尾的草稿条数。 */
  rewritten: number = 0
}

/**
 * 把导入草稿的键尾账号片段归一化为当前账号（导入计划阶段与写入阶段共用同一规则）。
 *
 * 背景（审计 DES-19）：导入计划原先直接用备份里的键（导出账号的短哈希）与本机草稿比较，
 * 同一条目标草稿会被误算成「新增」；真正写入时键尾又被改写为当前账号 → 实际语义是「覆盖/更新」。
 * 计划阶段先归一化后：
 * - 计数与实际写盘一致（同目标草稿按 REPLACE_BY_KEY 计 updated / 无变化 skipped）；
 * - 内容完全相同的草稿能被识别为「无变化」，从而不触发无意义写盘。
 *
 * @param payload - 草稿域载荷（文件域导出恒为数组）
 * @param uid - 当前登录 uid（空串按 `anon` 处理；导入计划已拒绝未登录时的草稿域）
 * @returns 归一化结果（不修改入参）
 */
export function normalizeDraftKeysForAccount(payload: Object, uid: string): DraftKeyNormalizeResult {
  const result: DraftKeyNormalizeResult = new DraftKeyNormalizeResult()
  if (!Array.isArray(payload)) {
    result.payload = payload
    return result
  }
  const uidPart: string = draftUidPart(uid)
  const items: Object[] = payload as Object[]
  const normalized: Object[] = []
  for (let i: number = 0; i < items.length; i++) {
    const item: Object = items[i]
    if (item === null || item === undefined || Array.isArray(item) || typeof item !== 'object') {
      normalized.push(item)
      continue
    }
    const record: Record<string, Object> = item as Record<string, Object>
    const rawKey: Object | undefined = record[KEY_FIELD]
    const key: string = typeof rawKey === 'string' ? rawKey as string : ''
    if (key.length === 0) {
      normalized.push(item)
      continue
    }
    const rewrittenKey: string = rewriteDraftKeyUidPart(key, uidPart)
    if (rewrittenKey === key) {
      normalized.push(item)
      continue
    }
    /*
     * 重建对象时**保持原字段顺序**（`key` 在原位置替换值）：合并器用 `JSON.stringify` 判等，
     * 字段顺序变化会把"内容完全相同的草稿"误判为已变化 → 计划显示"更新"并触发无意义写盘。
     */
    const next: Record<string, Object> = {}
    const keys: string[] = Object.keys(record)
    for (let k: number = 0; k < keys.length; k++) {
      const field: string = keys[k]
      next[field] = field === KEY_FIELD ? rewrittenKey : record[field]
    }
    normalized.push(next)
    result.rewritten++
  }
  result.payload = normalized
  return result
}
