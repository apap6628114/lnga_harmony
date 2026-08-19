/**
 * 保存的帖子（离线存档）数据模型。
 *
 * 保存的帖子不按账号区分：SavedThreadStore 的存档目录全局唯一，与登录 uid 无关。
 *
 * 存档内容为「与 NGA 官方接口同形状的原始 JSON」（rawPages，每页一项）：
 * - JSON 主通道保存响应对象本身；HTML 降级通道保存 parseHtmlTask 的同形状产物，
 *   两通道产物形状一致，打开时统一由 fillThreadResult 按当前解析器解释；
 * - 只要官方协议形状不变，存档可被任意后续版本的解析器重新解释与渲染，
 *   在线/离线表现一致（同一 ThreadPanel 渲染管线），且不依赖任何持久化 UI 快照。
 */

/**
 * 保存帖子存档的 schema 版本，导入时校验。
 * v2：由持久化 PostInfo[] 快照改为持久化同形状原始 JSON（rawPages）。
 */
export const SAVED_THREAD_SCHEMA_VERSION: number = 2

/**
 * 单帖离线存档快照。
 */
export class SavedThread {
  /** NGA 主题 ID。 */
  tid: string = ''
  /** 版块 ID。 */
  fid: number = 0
  /** 主题标题。 */
  subject: string = ''
  /** 楼主昵称。 */
  author: string = ''
  /** 楼主用户 ID。 */
  authorid: number = 0
  /** 版块名。 */
  forumName: string = ''
  /** 服务端总页数（保存时刻）。 */
  totalPages: number = 0
  /** 实际保存的页数。 */
  savedPages: number = 0
  /**
   * 最后保存楼层的楼号（lou，保存的最后一页最后一个楼层）。
   *
   * 楼层提示口径以此为准：NGA 删除楼层不重编号，lou 存在空洞，
   * 若按楼层计数会与离线阅读看到的楼号不一致。
   */
  lastLou: number = 0
  /** 保存时间戳（毫秒），查看页按此降序排列。 */
  savedAt: number = 0
  /** 每页的同形状原始 JSON（数组下标 = 页号 - 1）。 */
  rawPages: Object[] = []
}

/**
 * 导出/导入文件根结构（不加密，纯 JSON 文本）。
 */
export class SavedThreadExportFile {
  /** 结构版本，与 SAVED_THREAD_SCHEMA_VERSION 比对。 */
  schemaVersion: number = SAVED_THREAD_SCHEMA_VERSION
  /** 导出时间戳（毫秒）。 */
  exportedAt: number = 0
  /** 导出的帖子列表。 */
  threads: SavedThread[] = []
}
