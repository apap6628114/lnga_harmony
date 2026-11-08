import { ThreadRenderMode } from '../constants/Constants'

/**
 * 帖子「递进树」一次性引导的触发策略（纯逻辑，无 UI / 无全局状态，可直接单测）。
 *
 * 引导只在**首次以列表样式打开在线帖子**时出现一次：
 * - 设备上已提示过（meta 中的持久化标记 `treeGuideAcknowledged`）→ 不再出现；
 * - 离线存档来源是**回看**场景（存档树走本地数据源，入口已在更多菜单里）
 *   → 不提示，也**不写标记**：用户下次以在线来源打开帖子时仍会看到唯一一次引导；
 * - 默认阅读样式已是递进树 → 用户打开帖子直接进树页，由树页侧静默置位，不再打扰。
 *
 * 判定与标记写入由调用方分开完成（先 `shouldShow` 再置位再弹窗），
 * 多列 / 多实例同时到达首屏时不会叠出多个引导弹窗。
 */
export class ThreadTreeGuidePolicy {
  /**
   * 当前帖子页是否应弹出「递进树」引导。
   *
   * @param alreadyShown - 是否已提示过（设置域中的持久化标记）
   * @param savedSource - 当前是否离线存档来源
   * @param renderMode - 帖子默认阅读样式（`ThreadRenderMode.LIST` / `ThreadRenderMode.TREE`）
   * @returns 是否弹出
   */
  static shouldShow(alreadyShown: boolean, savedSource: boolean, renderMode: string): boolean {
    if (alreadyShown) {
      return false
    }
    if (savedSource) {
      return false
    }
    if (renderMode === ThreadRenderMode.TREE) {
      return false
    }
    return true
  }
}
