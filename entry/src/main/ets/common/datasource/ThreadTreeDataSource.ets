import { BaseLazyDataSource } from './BaseLazyDataSource'
import { PostInfo } from '../../model/PostInfo'
import { ThreadTreeRow } from '../../model/ThreadTree'

/**
 * 帖子两层递进树的数据源：树 List 的 LazyForEach 数据来源。
 *
 * 只镜像 `ThreadTreeModel.rows`（由 `flattenThreadTree` 重算后的可见扁平行），
 * 不持有任何业务状态；展开/折叠、高亮、内容刷新统一走基类的
 * `replaceAll` / `updateAt` 通知。`getData` 由基类实现，返回行对象**引用本身**
 * （ThreadPanel 会对行就地 `highlighted = true; rev++` 后 `updateAt`，必须共享引用）。
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
}
