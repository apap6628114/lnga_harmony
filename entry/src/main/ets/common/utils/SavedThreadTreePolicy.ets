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
import { normalizePageCount, resolveArchiveStartPage } from './SavedThreadPageUtils'

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
 * 按页序调用时绝大多数楼层落在末尾（NGA 的 `lou` 单调递增），因此先走 O(1) 的
 * 「追加到末尾」快速路径；只有存档页之间出现重排时才线性找插入位置。已存在的 pid
 * 直接跳过（增量翻页期间楼层漂移会在两页里出现同一楼）。
 *
 * 每页调用一次，`collected` 的 pid 集合在本次调用内建一次（O(n)），避免逐楼扫描
 * 整个累积数组（长帖下是 O(pages × posts²)）。
 *
 * @param collected - 累积楼层（原地修改，作为树页增量提交的同一引用）
 * @param incoming - 本页解析出的楼层（按页内顺序）
 * @returns 新增楼层数（0 表示整页都是重复内容）
 */
export function mergeSavedThreadPage(collected: PostInfo[], incoming: PostInfo[]): number {
  if (incoming.length === 0) {
    return 0
  }
  const existing: Set<number> = new Set<number>()
  for (let i: number = 0; i < collected.length; i++) {
    existing.add(collected[i].pid)
  }
  let added: number = 0
  for (let i: number = 0; i < incoming.length; i++) {
    const post: PostInfo = incoming[i]
    if (existing.has(post.pid)) {
      continue
    }
    existing.add(post.pid)
    const last: PostInfo | undefined = collected.length > 0 ? collected[collected.length - 1] : undefined
    if (last === undefined || last.lou <= post.lou) {
      // 常规路径：页内楼号递增、页间楼号更大，直接追加
      collected.push(post)
      added++
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
