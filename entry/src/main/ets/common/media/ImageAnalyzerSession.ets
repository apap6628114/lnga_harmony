/**
 * 正文图「识图选取态」会话登记表 —— 系统 AI 图像分析的取消通道。
 *
 * 背景：`Image` 的 AI 图像分析只有开关（`enableAnalyzer`），系统**没有**提供"清除选取态"
 * 的接口——`startImageAnalyzer` / `stopImageAnalyzer` 只存在于 `XComponentController` 与
 * `CanvasRenderingContext2D`，Vision Kit 的 `VisionImageAnalyzerController` 也只有 AIButton
 * 可见性（`setImageAnalyzerVisibility`）与只读的界面状态查询（`getImageAnalyzerUIStatus`），
 * 没有任何"收起文本菜单 / 清空选区"的能力。
 *
 * 于是用户长按正文图选字后，选取态会一直留在图上：单击图片直接进查看器、滚动列表时系统
 * 文本菜单只是临时隐藏（松手又出现）、点正文文字也不会收掉它——三处都不符合"点别处即取消
 * 选中"的通用直觉。系统侧唯一可用的杠杆是**把 `enableAnalyzer` 关掉一次**：组件不再支持
 * AI 分析 ⇒ 分析器整体拆除 ⇒ 选取态与系统文本菜单一并消失；稍后再打开即恢复长按识图。
 *
 * 本工程据此把"取消选取态"实现为「会话登记 + 集中拆除」：
 *
 *  - 长按判定成立时（见 `BBCodeContentView.onImageTouch`）登记一个会话，拆除回调由**会话
 *    归属的那个** `BBCodeContentView` 提供：关一次分析器开关、复位自身会话标记、稍后重新武装；
 *  - 任何"非识图"交互（点击正文、点击正文内可点元素、宿主列表滚动）调用
 *    {@link dismissAnalyzerSessions}，一次收掉当前所有会话。
 *
 * 登记必须跨组件：触发取消的交互很可能发生在**别的**楼层（甚至列表空白处的滚动），而选取态
 * 归产生它的那个正文组件所有，组件内自查覆盖不到。
 *
 * 纯数据、无 UI；进程内生命周期（不跨进程、不落盘）。句柄 0 表示无效句柄。
 */

/** 会话项：拆除回调 + 注销句柄。 */
class AnalyzerSessionEntry {
  /** 注销句柄。 */
  token: number
  /** 拆除回调（由会话归属的正文组件提供）。 */
  dismiss: () => void

  /**
   * 创建会话项。
   *
   * @param token 注销句柄
   * @param dismiss 拆除回调
   */
  constructor(token: number, dismiss: () => void) {
    this.token = token
    this.dismiss = dismiss
  }
}

/** 当前存活的会话（正常只有 0 / 1 个：同一时刻只有一张图处于选取态）。 */
let sessions: AnalyzerSessionEntry[] = []

/** 下一个会话句柄（从 1 起，0 留作"无句柄"）。 */
let nextToken: number = 1

/**
 * 登记一个"识图选取态可能存活"的会话。
 *
 * @param dismiss 拆除回调：关一次分析器开关并复位归属组件的会话标记
 * @returns 会话句柄，供 {@link unregisterAnalyzerSession} 注销
 */
export function registerAnalyzerSession(dismiss: () => void): number {
  const token: number = nextToken
  nextToken++
  sessions.push(new AnalyzerSessionEntry(token, dismiss))
  return token
}

/**
 * 注销会话（会话已自行结束，或归属组件即将销毁）。
 *
 * @param token 会话句柄；传 0 或已注销的句柄均为无操作
 */
export function unregisterAnalyzerSession(token: number): void {
  for (let i = 0; i < sessions.length; i++) {
    if (sessions[i].token === token) {
      sessions.splice(i, 1)
      return
    }
  }
}

/**
 * 拆除全部识图会话：任一"非识图"交互的入口（点击正文、点击正文内可点元素、宿主列表滚动）。
 *
 * 先把登记表整体换成空表、再逐个回调：回调内部会注销自己，换表之后注销即无操作，
 * 因此不存在"边遍历边改表"的时序问题；回调里若又登记了新会话也不会被这次拆除吞掉。
 */
export function dismissAnalyzerSessions(): void {
  if (sessions.length === 0) {
    return
  }
  const pending: AnalyzerSessionEntry[] = sessions
  sessions = []
  for (let i = 0; i < pending.length; i++) {
    pending[i].dismiss()
  }
}
