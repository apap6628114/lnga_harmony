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
   * 替换指定下标的行（内容变化，行数不变）。
   *
   * @param index - 目标下标
   * @param item - 新行
   */
  updateAt(index: number, item: ThreadTreeRow): void {
    if (index < 0 || index >= this.dataList.length) {
      return
    }
    this.dataList[index] = item
    const change: DataChangeOperation = { type: DataOperationType.CHANGE, index: index }
    this.notifyDatasetChange([change])
  }

  /**
   * 按 diff 结果增量更新行序列。
   *
   * `ops` 的索引全部相对**旧序列**（`RowOp.index`），与 LazyForEach 的
   * `DataOperation` 语义一致；调用方负责先把 `dataList` 换成新序列。
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
        const change: DataChangeOperation = { type: DataOperationType.CHANGE, index: op.index }
        operations.push(change)
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
