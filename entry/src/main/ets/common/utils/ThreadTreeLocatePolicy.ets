/**
 * 递进树「定位目标」与「进度胶囊」的纯逻辑策略（无 UI / 无网络 / 无全局状态，可直接单测）。
 *
 * 对应设计：`docs/THREAD_TREE_INCREMENTAL_LOAD_DESIGN.md` §3.6。
 *
 * 三条规则被固化为纯函数：
 * 1. **目标是否就绪**：先看模型（READY），再看全量楼层（FILTERED），最后才判缺失；
 * 2. **未就绪不给动作**：只有 READY / FILTERED 才有可执行动作；
 * 3. **胶囊状态**：页面阶段（加载中/完成/停止/失败）与目标状态正交组合。
 */

import {
  LocateSource,
  LocateState,
  TreeBannerMode,
  TreePagePhase
} from '../../model/ThreadTreeLocate'

/**
 * 目标状态判定。
 *
 * 顺序不能换（否则只看楼主下会把"被过滤"误判成"已删除"）：
 * 1. 在树模型里 → READY；
 * 2. 在全量楼层里（但被只看楼主过滤） → FILTERED；
 * 3. 目标页已提交仍找不到 → MISSING；
 * 4. 页码未知时只有在全帖到齐后才判 MISSING；
 * 5. 其余 → WAITING。
 *
 * @param inAllPosts - 全量楼层（未过滤）里是否有该 pid
 * @param inTreeModel - 当前树模型里是否有该 pid
 * @param targetPage - 目标页码（未知为 -1）
 * @param committedPages - 已提交页数（连续前缀）
 * @param complete - 是否已完成全部页
 * @returns 目标状态（见 `LocateState`）
 */
export function decideTargetState(inAllPosts: boolean, inTreeModel: boolean,
  targetPage: number, committedPages: number, complete: boolean): number {
  if (inTreeModel) {
    return LocateState.READY
  }
  if (inAllPosts) {
    return LocateState.FILTERED
  }
  if (targetPage > 0) {
    return targetPage <= committedPages ? LocateState.MISSING : LocateState.WAITING
  }
  return complete ? LocateState.MISSING : LocateState.WAITING
}

/**
 * 新登记的目标能否覆盖当前目标。
 *
 * 规则：路由/用户点击总是覆盖（后者代表用户当下的意图）；恢复进度只在没有目标时生效，
 * 否则「上次读到哪」会把用户刚点的引用跳转顶掉。
 *
 * @param incoming - 新目标来源（`LocateSource`）
 * @param current - 当前目标来源（空串表示没有目标）
 * @returns 可以覆盖时为 true
 */
export function canOverrideTarget(incoming: string, current: string): boolean {
  if (current.length === 0) {
    return true
  }
  return incoming !== LocateSource.RESUME
}

/**
 * 当前状态是否提供可执行动作。
 *
 * 只有 READY（前往）与 FILTERED（查看全部）有动作；WAITING 阶段**不提供**
 * 灰态的「前往」——明确"还没有这个动作"比"有但不能点"更不容易误导。
 *
 * @param state - 目标状态
 * @returns 可操作时为 true
 */
export function canActivateTarget(state: number): boolean {
  return state === LocateState.READY || state === LocateState.FILTERED
}

/**
 * 计算胶囊状态。
 *
 * 胶囊**只承载加载进度与「停止」**，不承载定位动作（「前往」由 Toast 承担）。
 * 目标未就绪时额外显示「载入到哪」，就绪后立刻回到普通进度；加载一结束
 * （完成/停止）胶囊即消失。
 *
 * @param phase - 页面阶段（`TreePagePhase`）
 * @param targetState - 目标状态（无目标时传 `LocateState.NONE`）
 * @param stopping - 是否正在停止
 * @returns 胶囊状态（`TreeBannerMode`）
 */
export function resolveBannerMode(phase: number, targetState: number, stopping: boolean): number {
  if (stopping) {
    return TreeBannerMode.STOPPING
  }
  if (phase === TreePagePhase.FAILED) {
    return TreeBannerMode.ERROR
  }
  // 只在加载中显示：COMPLETE / STOPPED / ENTERING 一律隐藏（完成后消失）
  if (phase !== TreePagePhase.STREAMING) {
    return TreeBannerMode.HIDDEN
  }
  // 目标未就绪时给「还差多少」的感知；就绪后由 Toast 提示，胶囊回到纯进度
  if (targetState === LocateState.WAITING) {
    return TreeBannerMode.LOADING_WAIT
  }
  return TreeBannerMode.LOADING
}

/**
 * 胶囊是否应该出现（防闪烁门禁）。
 *
 * @param mode - 胶囊状态
 * @param totalPages - 服务端总页数（0 表示未知）
 * @param hasTarget - 是否有待处理目标
 * @param delayElapsed - 加载态 300ms 延迟是否已到
 * @returns 应显示时为 true
 */
export function shouldShowBanner(mode: number, totalPages: number, hasTarget: boolean,
  delayElapsed: boolean): boolean {
  if (mode === TreeBannerMode.HIDDEN) {
    return false
  }
  // 错误与停止是瞬时/需被看见的状态，不受延迟门禁影响
  if (mode === TreeBannerMode.ERROR || mode === TreeBannerMode.STOPPING) {
    return true
  }
  // 纯加载态：短帖（<=2 页）抓取在一秒内结束，胶囊只会闪一下，不显示
  if (!hasTarget && totalPages > 0 && totalPages <= 2) {
    return false
  }
  return delayElapsed
}

/**
 * 目标刻度在进度条上的比例。
 *
 * @param targetPage - 目标页码
 * @param totalPages - 总页数
 * @returns [0,1] 内的比例；页码或总页数未知时返回 -1（不画刻度）
 */
export function targetPageRatio(targetPage: number, totalPages: number): number {
  if (targetPage <= 0 || totalPages <= 0) {
    return -1
  }
  // 页码越界说明记录已过期（帖子被合并/删页）：画在 100% 会误导，按未知处理
  if (targetPage > totalPages) {
    return -1
  }
  return targetPage / totalPages
}

/**
 * 「已加载 n/N 页」文案。口径固定为**已提交页**（用户看到的内容）。
 *
 * @param committedPages - 已提交页数
 * @param totalPages - 总页数
 * @returns 文案
 */
export function formatLoadingText(committedPages: number, totalPages: number): string {
  return '已加载 ' + String(committedPages) + '/' + String(totalPages) + ' 页'
}

/**
 * 等待定位目标的文案（「还差多少」的核心表达）。
 *
 * @param label - 目标标签（「上次阅读位置」/「第 812 楼」）
 * @param committedPages - 已提交页数
 * @param totalPages - 总页数
 * @returns 文案
 */
export function formatWaitTargetText(label: string, committedPages: number,
  totalPages: number): string {
  return '载入到' + label + ' ' + String(committedPages) + '/' + String(totalPages) + ' 页'
}

/**
 * 目标就绪文案。
 *
 * @param label - 目标标签
 * @returns 文案
 */
export function formatReadyText(label: string): string {
  return '已到' + label
}

/**
 * 目标就绪但仍在加载的文案。
 *
 * @param label - 目标标签
 * @param committedPages - 已提交页数
 * @param totalPages - 总页数
 * @returns 文案
 */
export function formatReadyLoadingText(label: string, committedPages: number,
  totalPages: number): string {
  return '已到' + label + ' · ' + String(committedPages) + '/' + String(totalPages) + ' 页'
}

/**
 * 目标被只看楼主过滤的文案。
 *
 * @param label - 目标标签
 * @returns 文案
 */
export function formatFilteredText(label: string): string {
  return label + '在只看楼主视图外'
}

/**
 * 目标不可用的文案。
 *
 * @param label - 目标标签
 * @param committedPages - 已提交页数
 * @param totalPages - 总页数
 * @returns 文案
 */
export function formatMissingText(label: string, committedPages: number, totalPages: number): string {
  return label + '未加载（' + String(committedPages) + '/' + String(totalPages) + ' 页）'
}

/**
 * 目标标签（展示用）。
 *
 * @param source - 目标来源
 * @param lou - 目标楼层号（未知为 -1）
 * @returns 「上次阅读位置」/「第 812 楼」/「目标楼层」
 */
export function formatTargetLabel(source: string, lou: number): string {
  if (source === LocateSource.RESUME) {
    return '上次阅读位置'
  }
  if (lou >= 0) {
    return '第 ' + String(lou) + ' 楼'
  }
  return '目标楼层'
}
