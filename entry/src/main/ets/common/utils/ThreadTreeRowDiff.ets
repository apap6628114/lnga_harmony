/**
 * 递进树行序列的增量 diff（纯函数，可单测）。
 *
 * 目的：把「旧的可见行序列 → 新的可见行序列」换算成 LazyForEach 的增量操作，
 * 让 `maintainVisibleContentPosition` 真正生效（官方约束：只有 LazyForEach
 * **增量插入/删除**时该属性才保持可见内容位置，`onDataReloaded` 不生效）。
 *
 * 适用前提来自增量方案的不变量（`docs/THREAD_TREE_INCREMENTAL_LOAD_DESIGN.md` §2）：
 * 按页顺序提交时，新行只会**插入**到旧序列里，不会搬动已有行。
 * 因此这里用双指针做「新序列是否为旧序列的超序列」判定：
 * - 是 → 产出若干 ADD + 必要的 CHANGE；
 * - 否（出现删除/移动/重排）→ 退回 RELOAD，由调用方配合锚点事务兜底。
 */

import { ThreadTreeRow } from '../../model/ThreadTree'

/** 行操作类型。 */
export class RowOpKind {
  /** 在 `index` 处插入 `count` 行。 */
  static readonly ADD: number = 0
  /** 把 `index` 处的行内容替换为新行（行数不变）。 */
  static readonly CHANGE: number = 1
  /** 从 `index` 处删除 `count` 行。 */
  static readonly DELETE: number = 2
  /** 整表重载（无法用增量表达时的兜底）。 */
  static readonly RELOAD: number = 3
}

/** 一条行操作。 */
export class RowOp {
  kind: number = RowOpKind.ADD
  index: number = 0
  count: number = 1

  constructor(kind: number = RowOpKind.ADD, index: number = 0, count: number = 1) {
    this.kind = kind
    this.index = index
    this.count = count
  }
}

/** diff 结果。 */
export class RowDiffResult {
  /** 增量操作（顺序即执行顺序；索引全部相对**旧序列**）。 */
  ops: RowOp[] = []

  /** 是否退化为整表重载（此时 `ops` 只含一条 RELOAD）。 */
  needReload: boolean = false
}

/**
 * 判断两行的可见内容是否一致。
 *
 * 行键（`kind + pid + rev + highlight`）相同只说明"同一行"，内容仍可能变化：
 * 折叠行计数、正文剥离结果、回复关系行、高亮态都会变。这些变化必须产出 CHANGE，
 * 否则 LazyForEach 复用组件时不会刷新。
 *
 * @param a - 旧行
 * @param b - 新行
 * @returns 内容一致时为 true
 */
function sameRowContent(a: ThreadTreeRow, b: ThreadTreeRow): boolean {
  if (a.kind !== b.kind) {
    return false
  }
  if (a.displayContent !== b.displayContent) {
    return false
  }
  if (a.totalCount !== b.totalCount || a.hiddenCount !== b.hiddenCount) {
    return false
  }
  if (a.showReplyTo !== b.showReplyTo || a.highlighted !== b.highlighted) {
    return false
  }
  const aRefPid: number = a.ref !== null ? a.ref.targetPid : -1
  const bRefPid: number = b.ref !== null ? b.ref.targetPid : -1
  if (aRefPid !== bRefPid) {
    return false
  }
  return true
}

/**
 * 把「旧行序列 → 新行序列」换算成增量操作。
 *
 * @param oldRows - 旧的行序列（可为空）
 * @param newRows - 新的行序列
 * @param keyOf - 行键生成函数（与 LazyForEach 的键生成器一致）
 * @returns diff 结果；无法用增量表达时 `needReload = true`
 */
export function computeTreeRowDiff(oldRows: ThreadTreeRow[], newRows: ThreadTreeRow[],
  keyOf: (row: ThreadTreeRow) => string): RowDiffResult {
  const result: RowDiffResult = new RowDiffResult()
  if (newRows.length === 0) {
    if (oldRows.length === 0) {
      return result
    }
    result.needReload = true
    result.ops.push(new RowOp(RowOpKind.RELOAD, 0, 0))
    return result
  }
  if (oldRows.length === 0) {
    result.ops.push(new RowOp(RowOpKind.ADD, 0, newRows.length))
    return result
  }

  let i: number = 0
  let j: number = 0
  // 同一批操作里，一个 ADD 的 index 不能再出现 CHANGE：
  // LazyForEach 规定「多个操作指向同一 index 只有第一个生效」，CHANGE 会被静默丢弃。
  const addIndexes: Set<number> = new Set<number>()
  while (i < newRows.length) {
    const newRow: ThreadTreeRow = newRows[i]
    if (j < oldRows.length && keyOf(newRow) === keyOf(oldRows[j])) {
      if (!sameRowContent(oldRows[j], newRow)) {
        if (addIndexes.has(j)) {
          return buildReloadResult()
        }
        result.ops.push(new RowOp(RowOpKind.CHANGE, j, 1))
      }
      i++
      j++
      continue
    }
    // 新行在旧序列的当前位置没有对应项：按「在旧索引 j 处插入」记录
    addIndexes.add(j)
    const ops: RowOp[] = result.ops
    const last: RowOp | undefined = ops.length > 0 ? ops[ops.length - 1] : undefined
    if (last !== undefined && last.kind === RowOpKind.ADD && last.index === j) {
      last.count++
    } else {
      ops.push(new RowOp(RowOpKind.ADD, j, 1))
    }
    i++
  }

  if (j !== oldRows.length) {
    // 旧序列有行在新序列里找不到（删除/移动/重排）：保守退回整表重载。
    // 单调增量下不应出现，只有展开/折叠、只看楼主切换等显式动作才会走到这里。
    return buildReloadResult()
  }
  return result
}

/**
 * 构造「整表重载」结果。
 *
 * @returns 只含一条 RELOAD 的 diff 结果
 */
function buildReloadResult(): RowDiffResult {
  const reload: RowDiffResult = new RowDiffResult()
  reload.needReload = true
  reload.ops.push(new RowOp(RowOpKind.RELOAD, 0, 0))
  return reload
}
