/**
 * 离线存档 → 递进树的纯逻辑策略（无 UI / 无网络 / 无全局状态，可直接单测）。
 *
 * 覆盖两件事：
 * 1. **覆盖范围提示**：存档允许只保存部分页（保存弹窗可选页范围），树只按存档页
 *    构建；缺页处的引用目标会按 `buildThreadTree` 的既有语义（目标不在树内 →
 *    提升为顶层根）呈现。这**不是**帖子真实的讨论结构，而是存档边界，必须让用户
 *    知道，否则残缺的树形会被误读；
 * 2. **跨页楼层合并**：按 pid 去重、按 `lou` 升序，与在线全帖抓取
 *    （`ThreadTreeFetchService.mergePosts`）同一口径，保证离线树的父/子关系与
 *    在线一致。
 *
 * 页码口径：`SavedThread.rawPages` 是「保存范围的连续页」，数组下标 = 存档页序 - 1。
 * 存档页序（1..savedPages）与线上页码（`startPage..startPage+savedPages-1`）
 * 是两套编号——树内胶囊与尾部文案用存档页序，覆盖范围提示用线上页码区间。
 */

import type { PostInfo } from '../../model/PostInfo'

/**
 * 把任意来源的页数字段规整为非负整数。
 *
 * 存档文件是外部可控输入（导入 / 旧版本 / 手工编辑）：字段可能是字符串、负数、
 * 小数或 `Infinity`（`1e999` 这类 JSON 数字会解析成 Infinity）。页数参与区间
 * 文案与算术，必须先落到有限整数。
 *
 * @param value - 原始字段值
 * @returns 非负整数；无法解析或非有限值时返回 0
 */
function normalizePageCount(value: number): number {
  const parsed: number = Math.floor(Number(value))
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0
}

/**
 * 把存档的 `startPage` 规整为合法页码。
 *
 * 存档文件是外部可控输入（导入 / 旧版本 / 手工编辑），字段可能缺失、为负数、
 * 为小数、为 `Infinity` 甚至是字符串。**必须转成 number 再用**：`startPage` 会参与
 * `startPage + 存档页序 - 1` 的算术，字符串会让它变成拼接（`'5' + 1 - 1` 得 50）。
 *
 * @param startPage - 原始字段值（运行时可能是任意类型）
 * @returns 合法起始页（1 起）；无法解析时返回 1
 */
export function resolveArchiveStartPage(startPage: number): number {
  const parsed: number = Math.floor(Number(startPage))
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 1
}

/**
 * 生成离线存档树的覆盖范围提示。
 *
 * 返回空串表示「全帖存档」（从第 1 页起、且覆盖到保存时刻的总页数），此时不需要
 * 任何额外提示——标题上的 `[离线]` 前缀已经说明数据来源。
 *
 * @param savedPages - 实际保存的页数（`SavedThread.savedPages`）
 * @param startPage - 保存范围起始页（1 起；0 / 负数按 1 处理，兼容旧存档）
 * @param totalPages - 保存时刻服务端总页数（≤0 时按 `savedPages` 处理）
 * @returns 提示文案；全帖存档为空串
 */
export function buildArchiveCoverageHint(savedPages: number, startPage: number,
  totalPages: number): string {
  const pages: number = normalizePageCount(savedPages)
  if (pages === 0) {
    return ''
  }
  const start: number = resolveArchiveStartPage(startPage)
  const totalCount: number = normalizePageCount(totalPages)
  const total: number = totalCount > 0 ? totalCount : pages
  const endRaw: number = start + pages - 1
  const end: number = endRaw < total ? endRaw : total
  // 从第 1 页起且覆盖到总页数：全帖存档，不提示
  if (start <= 1 && end >= total) {
    return ''
  }
  // 异常存档（起始页超过总页数）时区间会倒挂：钳到起始页，避免出现「第 10-8 页」
  const safeEnd: number = end < start ? start : end
  let range: string = ''
  if (start <= 1) {
    range = '前 ' + String(pages) + ' 页'
  } else if (safeEnd > start) {
    range = '第 ' + String(start) + '-' + String(safeEnd) + ' 页'
  } else {
    range = '第 ' + String(start) + ' 页'
  }
  // 走到这里必然缺页（不是前 N 页不全就是起点不是第 1 页）：跨页引用目标不在存档里，
  // 会按「目标不在树内」显示为顶层楼层，必须一并说明
  const base: string = '离线存档仅含' + range + '（原帖共 ' + String(total) + ' 页）'
  return base + '，未保存页里的引用会显示为顶层楼层'
}

/**
 * 把一页存档楼层合并进累积数组（按 pid 去重、按 `lou` 升序）。
 *
 * 按页序调用时绝大多数楼层落在末尾（NGA 的 `lou` 单调递增），因此插入点通常就是
 * 数组末尾；只有存档页之间出现重排/重复时才需要线性找位置。已存在的 pid 直接跳过
 * （增量翻页期间楼层漂移会在两页里出现同一楼）。
 *
 * @param collected - 累积楼层（原地修改，作为树页增量提交的同一引用）
 * @param incoming - 本页解析出的楼层（按页内顺序）
 * @returns 新增楼层数（0 表示整页都是重复内容）
 */
export function mergeSavedThreadPage(collected: PostInfo[], incoming: PostInfo[]): number {
  let added: number = 0
  for (let i: number = 0; i < incoming.length; i++) {
    const post: PostInfo = incoming[i]
    let duplicated: boolean = false
    for (let j: number = 0; j < collected.length; j++) {
      if (collected[j].pid === post.pid) {
        duplicated = true
        break
      }
    }
    if (duplicated) {
      continue
    }
    let insertAt: number = collected.length
    for (let k: number = 0; k < collected.length; k++) {
      if (collected[k].lou > post.lou) {
        insertAt = k
        break
      }
    }
    collected.splice(insertAt, 0, post)
    added++
  }
  return added
}
