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

  /**
   * `CHANGE` 操作要赋给该行的**新键**（与 LazyForEach 的 keyGenerator 一致）。
   *
   * 树行的键含内容版本号：内容变化时键必须跟着变，否则框架按「键没变」复用旧组件，
   * 计数/正文的 `CHANGE` 会被静默丢弃（详见 `ThreadTreePanel.rowKey` 注释）。
   * 空串表示不指定（框架沿用原键）。正常路径不会为空：{@link computeTreeRowDiff}
   * 的 `keyOf` 已改为必填；空键分支只保留给数据源的兼容调用。
   */
  key: string = ''

  constructor(kind: number = RowOpKind.ADD, index: number = 0, count: number = 1,
    key: string = '') {
    this.kind = kind
    this.index = index
    this.count = count
    this.key = key
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
 * 身份相同（`kind + pid + rev`）只说明"同一行"，内容仍可能变化：折叠行计数、正文
 * 剥离结果、回复关系、高亮态、以及楼层的**内容版本**（`post.uiRev`：回复/编辑后
 * 局部合并会替换 `PostInfo`，评论数、标题、附件等字段不在正文里，只能靠版本号
 * 感知）。这些变化必须产出 CHANGE，否则 LazyForEach 复用组件时不会刷新。
 *
 * @param a - 旧行
 * @param b - 新行
 * @returns 内容一致时为 true
 */
export function isSameRowContent(a: ThreadTreeRow, b: ThreadTreeRow): boolean {
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
  const aPostRev: number = a.post !== null ? a.post.uiRev : -1
  const bPostRev: number = b.post !== null ? b.post.uiRev : -1
  if (aPostRev !== bPostRev) {
    return false
  }
  return true
}

/**
 * 把「旧行序列 → 新行序列」换算成增量操作。
 *
 * **匹配键与展示键必须分开**：`idOf` 只含行的身份（类型 + pid + 展开代际），用来判断
 * 「新序列是否旧序列的超序列」；`keyOf` 是交给 LazyForEach 的实际键（身份 + 内容版本）。
 * 若用 `keyOf` 匹配，内容一变化键就变，旧行匹配不上 → 退化成整表 RELOAD，视口跳动。
 *
 * `keyOf` 刻意**不设可选**：省略它会让 CHANGE 丢掉新键，静默退化为「内容更新不刷新」，
 * 而这种回归在编译期完全看不出来（上一版就踩过）。
 *
 * @param oldRows - 旧的行序列（可为空）
 * @param newRows - 新的行序列
 * @param idOf - 行身份键（diff 匹配用，内容变化时必须保持一致）
 * @param keyOf - 行展示键（LazyForEach keyGenerator；`CHANGE` 会把它带给数据源）
 * @returns diff 结果；无法用增量表达时 `needReload = true`
 */
export function computeTreeRowDiff(oldRows: ThreadTreeRow[], newRows: ThreadTreeRow[],
  idOf: (row: ThreadTreeRow) => string,
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
    if (j < oldRows.length && idOf(newRow) === idOf(oldRows[j])) {
      if (!isSameRowContent(oldRows[j], newRow)) {
        if (addIndexes.has(j)) {
          return buildReloadResult()
        }
        const newKey: string = keyOf(newRow)
        result.ops.push(new RowOp(RowOpKind.CHANGE, j, 1, newKey))
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

/**
 * 树行身份键：行类型 + 楼层 pid + 所属根展开代际。
 *
 * 专供行 diff 匹配（{@link computeTreeRowDiff} 的 `idOf`）。内容版本不能进身份键：
 * 否则内容一变化就匹配不上旧行，增量 diff 会退化成整表 RELOAD。
 * `MORE` 行没有楼层，用所属根 pid 作为行标识（每个根至多一行）。
 *
 * @param row - 树行
 * @returns 身份键
 */
export function buildRowId(row: ThreadTreeRow): string {
  const pid: number = row.post !== null ? row.post.pid : row.rootPid
  return String(row.kind) + '_' + String(pid) + '_' + String(row.rev)
}

/**
 * 树行展示键（LazyForEach keyGenerator）：身份键 + 内容版本 + 高亮标记。
 *
 * 键是 LazyForEach 判断「需要重建组件」的唯一依据：内容变了但键不变时，框架会
 * 复用旧子组件，`CHANGE` 等于没发。因此增量合并改变折叠计数、正文或楼层内容
 * 版本（`post.uiRev`：评论数/标题/附件等）时，必须让行的 `uiRev` 变化。
 *
 * @param row - 树行
 * @returns 展示键
 */
export function buildRowKey(row: ThreadTreeRow): string {
  const highlight: string = row.highlighted ? '_h' : ''
  return buildRowId(row) + '_u' + String(row.uiRev) + highlight
}

/**
 * 结算一批新可见行的内容版本号（就地写 `uiRev`）。
 *
 * 规则：
 * - 与 `previous` 中同身份（{@link buildRowId}）的行比较：内容一致 → 继承旧版本；
 *   内容变化 → `旧版本 + 1`；
 * - `previous` 里找不到（首屏、或行从不可见状态重现）：用楼层内容版本
 *   `post.uiRev` 兜底。编辑/合并过的楼层版本已递增，重现时不会回退到旧键；
 * - 新行且楼层版本为 0 时保持 0。
 *
 * 为什么放在这里而不是 `buildThreadTree` / `flattenThreadTree`：它们是纯函数，
 * 不持有上一版行序列；版本号是「渲染层快照比较」的产物。
 *
 * @param previous - 上一版可见行（可为空）
 * @param next - 本次重建得到的可见行（就地写入 `uiRev`）
 */
export function stampRowContentRev(previous: ThreadTreeRow[], next: ThreadTreeRow[]): void {
  if (previous.length === 0) {
    for (let i: number = 0; i < next.length; i++) {
      const row: ThreadTreeRow = next[i]
      const post = row.post
      if (post !== null) {
        row.uiRev = post.uiRev
      }
    }
    return
  }
  const previousById: Map<string, ThreadTreeRow> = new Map<string, ThreadTreeRow>()
  for (let i: number = 0; i < previous.length; i++) {
    const old: ThreadTreeRow = previous[i]
    previousById.set(buildRowId(old), old)
  }
  for (let i: number = 0; i < next.length; i++) {
    const row: ThreadTreeRow = next[i]
    const old: ThreadTreeRow | undefined = previousById.get(buildRowId(row))
    if (old === undefined) {
      const post = row.post
      if (post !== null) {
        row.uiRev = post.uiRev
      }
      continue
    }
    row.uiRev = old.uiRev
    if (!isSameRowContent(old, row)) {
      row.uiRev = old.uiRev + 1
    }
  }
}
