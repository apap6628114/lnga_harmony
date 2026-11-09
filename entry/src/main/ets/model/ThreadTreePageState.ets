/**
 * 递进树页面的行状态与提交上下文类型。
 *
 * 从 `ThreadTreePanel.ets` 顶部迁出：这些类型不带 UI 依赖，放在 model 层后可以被
 * 单元测试复用；页面只保留与界面相关的状态。
 *
 * 注意 `TreeSubmitKind` 仍用「类静态 number 常量」而不是 enum——这是迁移前的既有写法，
 * 本文件只做位置搬移，不改变类型语义（改成 enum 会改动 `TreeSubmitContext.kind` 的
 * 类型标注，留待单独评估）。
 */

/** 根节点跨重建保留的状态（展开态与展开代际）。 */
export class RootState {
  /** 是否展开。 */
  expanded: boolean = false

  /** 展开代际（用于判断展开态是否被新的重建覆盖）。 */
  rev: number = 0
}

/** 增量提交前的视口锚点（插入到锚点之前时用于补偿）。 */
export class RowAnchor {
  /** 锚点是否有效。 */
  valid: boolean = false

  /** 锚点行对应的楼层 pid。 */
  pid: number = -1

  /** 锚点行在提交前的扁平行下标。 */
  oldIndex: number = -1

  /** 锚点行相对视口顶部的偏移。 */
  offset: number = 0
}

/** 提交类型：决定回复/编辑成功后局部刷新抓哪一页。 */
export class TreeSubmitKind {
  /** 楼层回复 / 主题回复：新楼层必在末页 */
  static readonly REPLY: number = 0

  /** 编辑：被编辑楼层在其所属页 */
  static readonly EDIT: number = 1
}

/**
 * 一次「提交成功」的上下文（回复与编辑共用同一套局部刷新流程）。
 *
 * 只承载**已有的事实**（服务端返回的新 pid、编辑目标 pid、提交正文），
 * 不含任何对楼层号/正文的猜测——局部合并的数据一律来自服务端那一页。
 */
export class TreeSubmitContext {
  /** 提交类型，见 {@link TreeSubmitKind} */
  kind: number = TreeSubmitKind.REPLY

  /** 服务端返回的新楼层 pid（回复；响应未携带时为 0） */
  newPid: number = 0

  /** 编辑目标楼层 pid（编辑；回复为 0） */
  editPid: number = 0

  /** 用户提交的正文（编辑的旧缓存保护用；其余场景空串） */
  text: string = ''

  /** 成功提示文案 */
  toast: string = ''
}
