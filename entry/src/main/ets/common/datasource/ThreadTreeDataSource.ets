import { BaseLazyDataSource } from './BaseLazyDataSource'
import { PostInfo } from '../../model/PostInfo'
import { ThreadTreeRow } from '../../model/ThreadTree'
import { RowOp, RowOpKind } from '../utils/ThreadTreeRowDiff'

/**
 * 帖子两层递进树的数据源：树 List 的 LazyForEach 数据来源。
 *
 * 只镜像 `ThreadTreeModel.rows`（由 `flattenThreadTree` 重算后的可见扁平行），
 * 不持有任何业务状态。
 *
 * ## 通知通路（重要）
 *
 * 本数据源**全部**通过 `onDatasetChange` 通知（`replaceAll` 发一条 RELOAD，
 * 增量发 ADD/CHANGE），**不再使用** `onDataReloaded` / `onDataAdd` / `onDataChange`：
 * 官方约束同一个 LazyForEach 上两者不能混用；而 `List.maintainVisibleContentPosition`
 * 只对 LazyForEach 的增量插入/删除生效（对 `onDataReloaded` 不生效）。
 */
export class ThreadTreeDataSource extends BaseLazyDataSource<ThreadTreeRow> {
  /**
   * 按楼层 pid 查找行下标（MORE 行 `post` 为 null，不参与匹配）。
   *
   * @param pid - 目标楼层 pid
   * @returns 行下标；未命中返回 -1
   */
  findIndexByPid(pid: number): number {
    for (let i: number = 0; i < this.dataList.length; i++) {
      const row: ThreadTreeRow = this.dataList[i]
      const rowPost: PostInfo | null = row.post
      if (rowPost !== null && rowPost.pid === pid) {
        return i
      }
    }
    return -1
  }

  /**
   * 按楼层 pid 查找行对象。
   *
   * @param pid - 目标楼层 pid
   * @returns 行对象引用；MORE 行/未命中返回 null
   */
  findRowByPid(pid: number): ThreadTreeRow | null {
    const index: number = this.findIndexByPid(pid)
    if (index < 0) {
      return null
    }
    return this.dataList[index]
  }

  /**
   * 当前行序列（只读快照，用于 diff）。
   *
   * @returns 行数组引用
   */
  rows(): ThreadTreeRow[] {
    return this.dataList
  }

  /**
   * 整体替换（折叠/展开、只看楼主切换、刷新替换）。
   *
   * 用 RELOAD 操作而不是 `onDataReloaded`：保证本数据源始终只走
   * `onDatasetChange` 一条通路。
   *
   * @param list - 新的可见行
   */
  replaceAll(list: ThreadTreeRow[]): void {
    this.dataList = []
    for (let i = 0; i < list.length; i++) {
      this.dataList.push(list[i])
    }
    const reload: DataReloadOperation = { type: DataOperationType.RELOAD }
    this.notifyDatasetChange([reload])
  }

  /** 清空并整表重载。 */
  clear(): void {
    this.dataList = []
    const reload: DataReloadOperation = { type: DataOperationType.RELOAD }
    this.notifyDatasetChange([reload])
  }

  /**
   * 追加行（树页不使用：增量统一走 {@link applyRowOps}）。
   *
   * 覆盖基类实现的原因：基类走 `onDataAdd`，一旦被调用就与 `onDatasetChange`
   * 混用，违反 LazyForEach 的官方约束。这里保守地退化为整表重载。
   *
   * @param list - 追加的行
   */
  appendAll(list: ThreadTreeRow[]): void {
    const merged: ThreadTreeRow[] = this.dataList.slice()
    for (let i: number = 0; i < list.length; i++) {
      merged.push(list[i])
    }
    this.replaceAll(merged)
  }

  /**
   * 头部插入行（树页不使用，理由同 {@link appendAll}）。
   *
   * @param list - 插入的行
   */
  prependAll(list: ThreadTreeRow[]): void {
    const merged: ThreadTreeRow[] = list.slice()
    for (let i: number = 0; i < this.dataList.length; i++) {
      merged.push(this.dataList[i])
    }
    this.replaceAll(merged)
  }

  /**
   * 替换指定下标的行（内容变化，行数不变）。
   *
   * 必须带上新键：树页的 `rowKey` 含内容版本 `uiRev` 与高亮后缀，内容变化时键会变；
   * 不传 key 时框架沿用旧键并按「键没变」复用旧组件，这次 CHANGE 会被静默丢弃。
   *
   * @param index - 目标下标
   * @param item - 新行
   * @param key - 该行的新键（与 LazyForEach 的 keyGenerator 一致）
   */
  updateAt(index: number, item: ThreadTreeRow, key: string = ''): void {
    if (index < 0 || index >= this.dataList.length) {
      return
    }
    this.dataList[index] = item
    if (key.length > 0) {
      const changed: DataChangeOperation = {
        type: DataOperationType.CHANGE,
        index: index,
        key: key
      }
      this.notifyDatasetChange([changed])
      return
    }
    const change: DataChangeOperation = { type: DataOperationType.CHANGE, index: index }
    this.notifyDatasetChange([change])
  }

  /**
   * 按 diff 结果增量更新行序列。
   *
   * `ops` 的索引全部相对**旧序列**（`RowOp.index`），与 LazyForEach 的
   * `DataOperation` 语义一致；**本方法自己负责**把 `dataList` 换成 `nextRows`
   * （先换数据再通知，和 LazyForEach 取数时机一致）。
   *
   * @param nextRows - 新的完整行序列
   * @param ops - diff 产出的操作（可含 RELOAD）
   */
  applyRowOps(nextRows: ThreadTreeRow[], ops: RowOp[]): void {
    this.dataList = []
    for (let i = 0; i < nextRows.length; i++) {
      this.dataList.push(nextRows[i])
    }
    const operations: DataOperation[] = []
    for (let i = 0; i < ops.length; i++) {
      const op: RowOp = ops[i]
      if (op.kind === RowOpKind.ADD) {
        const add: DataAddOperation = {
          type: DataOperationType.ADD,
          index: op.index,
          count: op.count
        }
        operations.push(add)
      } else if (op.kind === RowOpKind.CHANGE) {
        if (op.key.length > 0) {
          /*
           * 必须带新键：树行的键含内容版本号，内容变化时键会变；不传键框架会沿用
           * 旧键并复用旧组件，计数/正文的更新会被静默丢弃（与 updateAt 同一约束）。
           */
          const change: DataChangeOperation = {
            type: DataOperationType.CHANGE,
            index: op.index,
            key: op.key
          }
          operations.push(change)
        } else {
          const change: DataChangeOperation = { type: DataOperationType.CHANGE, index: op.index }
          operations.push(change)
        }
      } else if (op.kind === RowOpKind.DELETE) {
        const del: DataDeleteOperation = {
          type: DataOperationType.DELETE,
          index: op.index,
          count: op.count
        }
        operations.push(del)
      } else {
        const reload: DataReloadOperation = { type: DataOperationType.RELOAD }
        operations.push(reload)
      }
    }
    if (operations.length === 0) {
      return
    }
    this.notifyDatasetChange(operations)
  }
}
