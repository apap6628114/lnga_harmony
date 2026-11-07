/**
 * 泛型懒加载 DataSource 基类。
 *
 * 封装 ArkUI `IDataSource` 的共性实现：维护元素列表 `dataList` 与
 * 监听器集合 `listeners`，提供 `totalCount` / `getData` /
 * `registerDataChangeListener` / `unregisterDataChangeListener` /
 * `replaceAll` / `clear` / `appendAll` / `prependAll` / `updateAt` /
 * `length` 及内部通知助手 `notifyReload` / `notifyAdd`。
 *
 * 各业务子类仅需 `extends BaseLazyDataSource<XxxInfo>` 即可复用全部共性逻辑，
 * 再按需追加特有的查询或写入方法。
 */
export class BaseLazyDataSource<T> implements IDataSource {
  /** 元素列表。子类特有方法（如 indexOf）可直接读写。 */
  protected dataList: T[] = []

  /** 已注册的数据变更监听器。 */
  private listeners: DataChangeListener[] = []

  /** 返回当前元素总数。 */
  totalCount(): number {
    return this.dataList.length
  }

  /** 返回指定下标的元素。 */
  getData(index: number): T {
    return this.dataList[index]
  }

  /**
   * 注册数据变更监听器，已注册的不会重复添加。
   *
   * @param listener - 监听器实例
   */
  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener)
    }
  }

  /**
   * 注销数据变更监听器。
   *
   * @param listener - 监听器实例
   */
  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener)
    if (pos >= 0) {
      this.listeners.splice(pos, 1)
    }
  }

  /**
   * 用新列表整体替换当前元素，替换后通知整体刷新。
   *
   * @param list - 新元素列表
   */
  replaceAll(list: T[]): void {
    this.dataList = []
    for (let i = 0; i < list.length; i++) {
      this.dataList.push(list[i])
    }
    this.notifyReload()
  }

  /**
   * 在末尾追加元素，逐项触发增量新增通知。
   *
   * @param list - 待追加元素列表
   */
  appendAll(list: T[]): void {
    const start: number = this.dataList.length
    for (let i = 0; i < list.length; i++) {
      this.dataList.push(list[i])
      this.notifyAdd(start + i)
    }
  }

  /**
   * 在头部插入元素，逐项触发增量新增通知。
   *
   * @param list - 待插入元素列表
   */
  prependAll(list: T[]): void {
    this.dataList = list.concat(this.dataList)
    for (let i = 0; i < list.length; i++) {
      this.notifyAdd(i)
    }
  }

  /** 清空所有元素并通知整体刷新。 */
  clear(): void {
    this.dataList = []
    this.notifyReload()
  }

  /**
   * 更新指定下标的元素并触发该位置的数据变更通知。
   * 越界下标将被忽略。
   *
   * @param index - 目标下标
   * @param item - 新元素
   */
  updateAt(index: number, item: T): void {
    if (index < 0 || index >= this.dataList.length) {
      return
    }
    this.dataList[index] = item
    this.notifyDataChange(index)
  }

  /** 返回当前元素数量，与 `totalCount` 等价。 */
  length(): number {
    return this.dataList.length
  }

  /** 通知所有监听器整体数据已刷新。 */
  protected notifyReload(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded()
    }
  }

  /**
   * 通知所有监听器执行一批增量操作（`DataChangeListener.onDatasetChange`）。
   *
   * **官方约束（API 12+）**：同一个 LazyForEach 上，`onDatasetChange` 不能与
   * `onDataAdd` / `onDataChange` / `onDataReloaded` 混用；一次批量里若含 RELOAD
   * 操作，其余操作都不生效。因此一旦某个数据源改用本方法，它的**所有**通知
   * 都必须走这里（全量替换用一条 `{ type: RELOAD }`）。
   *
   * 典型用途：`List` 的 `maintainVisibleContentPosition(true)` 只对 LazyForEach
   * 的**增量插入/删除**生效，对 `onDataReloaded` 不生效。
   *
   * @param operations - 操作列表（索引均相对**修改前**的数据序列）
   */
  protected notifyDatasetChange(operations: DataOperation[]): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDatasetChange(operations)
    }
  }

  /**
   * 通知所有监听器在指定下标处发生了增量新增。
   *
   * @param index - 新增元素下标
   */
  protected notifyAdd(index: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataAdd(index)
    }
  }

  /**
   * 通知所有监听器指定下标的数据发生了变更。
   *
   * @param index - 变更下标
   */
  protected notifyDataChange(index: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataChange(index)
    }
  }
}
