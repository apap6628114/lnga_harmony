import { PostInfo } from '../../model/PostInfo'
import {
  ThreadTreeChild,
  ThreadTreeModel,
  ThreadTreeQuoteRef,
  ThreadTreeRoot,
  ThreadTreeRow,
  ThreadTreeRowKind
} from '../../model/ThreadTree'

/**
 * 帖子两层递进树的纯逻辑构建器（无 UI / 无网络 / 无全局状态，可直接单测）。
 *
 * 职责分三块：
 * 1. `extractPrimaryQuoteRef`：从楼层 BBCode 正文中提取「本层回复了哪一层」的主引用头；
 * 2. `buildThreadTree`：按引用关系建两层有限树（第一层根 + 第二层任意深度后代平铺）；
 * 3. `flattenThreadTree` / `expandRoot` / 查找函数：按折叠状态生成可见扁平行并支持定位。
 *
 * 数据契约与不变量见 `docs/THREAD_TREE_DESIGN.md` §2，模型见 `model/ThreadTree.ets`。
 * 真实引用头的统计依据（本工程样本 tid 44191387 / 47762778 / 44681192）：
 * - `[quote][pid=A,B,C]Reply[/pid] [b]Post by [uid=U]name[/uid] (date):[/b]…[/quote]`
 * - `[b]Reply to [pid=A,B,C]Reply[/pid] Post by [uid=U]name[/uid] (date)[/b]…`
 * - `[quote][tid=T]Topic[/tid] [b]Post by [uid=U]name[/uid] (date):[/b]…[/quote]`
 * 其中 U 可能是数字 uid，也可能是匿名的 `[uid]#anony_<32hex>[/uid]`（真实数据是**无等号**
 * 的 `[uid]…[/uid]` 形态，`[uid=#anony_…]` 只作兼容），作者段也可能带
 * `[color=gray](224楼)[/color]`、`(31楼)` 之类楼号提示而不是纯日期，因此作者段解析
 * 只以 `[/uid]` 为界，不强制日期格式。
 */

/** 引用头类型：无匹配。 */
const QUOTE_KIND_NONE: number = 0
/** 引用头类型：`[quote][pid=…]` 引用块头。 */
const QUOTE_KIND_PID: number = 1
/** 引用头类型：`[quote][tid=…]Topic` 主楼引用头。 */
const QUOTE_KIND_TID: number = 2
/** 引用头类型：`[b]Reply to [pid=…]` 回复头。 */
const QUOTE_KIND_REPLY: number = 3

/** 引用头的扫描窗口上限（字符）：足以覆盖完整头部与作者段。 */
const HEADER_SCAN_MAX: number = 400

/** `rawHeader` 诊断字段的截断上限（字符）。 */
const RAW_HEADER_MAX: number = 200

/** 折叠阈值：某根后代总数大于该值时默认只显示前两条。 */
const FOLD_CHILD_THRESHOLD: number = 3

/** 折叠时默认显示的子树条数。 */
const COLLAPSED_VISIBLE_CHILD_COUNT: number = 2

/** 引用块 pid 头：`[quote][pid=A,B,C]Reply[/pid]`（Reply 容错缺省）。 */
const RE_QUOTE_PID: RegExp = /\[quote\]\s*\[pid=([^\]]*)\]\s*(?:Reply\s*)?\[\/pid\]/i

/** 主楼引用头：`[quote][tid=T]Topic[/tid]`。 */
const RE_QUOTE_TID: RegExp = /\[quote\]\s*\[tid=([^\]]*)\]\s*Topic\s*\[\/tid\]/i

/** 回复头：`[b]Reply to [pid=A,B,C]Reply[/pid]`。 */
const RE_REPLY_PID: RegExp = /\[b\]\s*Reply to\s*\[pid=([^\]]*)\]\s*(?:Reply\s*)?\[\/pid\]/i

/** 带属性 uid：`[uid=123]name[/uid]` / `[uid=#anony_x]name[/uid]`（名字可为空）。 */
const RE_UID_ATTR: RegExp = /\[uid=([^\]]*)\]([\s\S]*?)\[\/uid\]/

/** 无属性 uid：`[uid]#anony_<32hex>[/uid]`（真实匿名引用头的实际形态）。 */
const RE_UID_BARE: RegExp = /\[uid\]([\s\S]*?)\[\/uid\]/

/** 纯整数 token（允许负号，兼容异常 uid / 局部楼号）。 */
const RE_INT_TOKEN: RegExp = /^-?\d+$/

/**
 * 按逗号切分 pid 头的原始参数并去除各项两端空白。
 *
 * @param raw - 方括号内的原始内容（如 `824931876,44191387,1`）
 * @returns 切片数组（保留空项以维持 A/B/C 位置语义）
 */
function splitPidParts(raw: string): string[] {
  const parts: string[] = raw.split(',')
  for (let i: number = 0; i < parts.length; i++) {
    parts[i] = parts[i].trim()
  }
  return parts
}

/**
 * 把纯整数字符串解析为数字。
 *
 * @param raw - 待解析字符串
 * @returns 解析结果；非整数 token 或空串返回 -1
 */
function parseIntegerToken(raw: string): number {
  if (raw.length === 0 || !RE_INT_TOKEN.test(raw)) {
    return -1
  }
  return parseInt(raw, 10)
}

/**
 * 截取引用头窗口：从匹配起点到 `[/b]`（头部结束）或第一处 `<br`（异常头兜底）。
 *
 * @param content - 楼层正文
 * @param start - 引用头匹配起点
 * @returns 头部窗口文本（不含正文）
 */
function buildHeaderWindow(content: string, start: number): string {
  const hardEnd: number = Math.min(content.length, start + HEADER_SCAN_MAX)
  const boldClose: number = content.indexOf('[/b]', start)
  if (boldClose >= 0 && boldClose + 4 <= hardEnd) {
    return content.substring(start, boldClose + 4)
  }
  const brIndex: number = content.indexOf('<br', start)
  if (brIndex >= 0 && brIndex < hardEnd) {
    return content.substring(start, brIndex)
  }
  return content.substring(start, hardEnd)
}

/**
 * 从引用头窗口中解析被引用作者 uid 与显示名。
 *
 * @param header - 引用头窗口文本
 * @returns 长度 2 的数组：[uid 原文, 作者名原文]；解析不到时对应位置为空串
 */
function parseQuotedAuthor(header: string): string[] {
  const result: string[] = ['', '']
  const attrMatch: RegExpExecArray | null = RE_UID_ATTR.exec(header)
  if (attrMatch !== null) {
    result[0] = attrMatch[1].trim()
    result[1] = attrMatch[2].trim()
    return result
  }
  const bareMatch: RegExpExecArray | null = RE_UID_BARE.exec(header)
  if (bareMatch !== null) {
    result[0] = bareMatch[1].trim()
  }
  return result
}

/**
 * 从楼层正文中提取主引用关系（本层回复了哪一层）。
 *
 * 同时匹配三种真实头形态，取**匹配位置最靠前**的一个；一条楼层只取最外层第一个有效头，
 * 不递归嵌套引用。各种变体的兼容规则：
 * - `[uid=…]` 段用宽松匹配，兼容数字 uid、`[uid]#anony_<32hex>[/uid]` 与 `[uid=#anony_…]`；
 * - 作者段允许 `(日期 时间)`、`[color=gray](224楼)[/color]`、`(31楼)` 等变体，只解析到
 *   `[/uid]` 为止，不强制 `(date):` 结尾；
 * - pid 头 B 段为**被引用楼层所属主题 tid**，与传入 `tid` 不同即标记 `external = true`
 *   （跨帖引用，建树时按根处理）；B 段缺失或当前 tid 未知（<=0）时不判跨帖；
 * - A 段为 0（`[pid=0,<tid>,1]` 主楼哨兵）与 `[tid=T]Topic` 形态都判定为主楼引用
 *   `isTopicRef = true`、`targetPid = 0`；
 * - C 段页码照原样记录到 `targetPage`，但**不可信、不用于定位**（定位一律用抓取页映射）。
 *
 * @param content - 楼层 BBCode 正文
 * @param tid - 当前帖子 tid（用于跨帖判定；未知时传 0）
 * @returns 引用关系；无有效引用头时返回 null
 */
export function extractPrimaryQuoteRef(content: string, tid: number): ThreadTreeQuoteRef | null {
  if (content.length === 0) {
    return null
  }
  let bestKind: number = QUOTE_KIND_NONE
  let bestIndex: number = -1
  let bestPidRaw: string = ''
  let bestTidRaw: string = ''

  const pidMatch: RegExpExecArray | null = RE_QUOTE_PID.exec(content)
  if (pidMatch !== null) {
    bestKind = QUOTE_KIND_PID
    bestIndex = pidMatch.index
    bestPidRaw = pidMatch[1]
  }
  const tidMatch: RegExpExecArray | null = RE_QUOTE_TID.exec(content)
  if (tidMatch !== null && (bestIndex < 0 || tidMatch.index < bestIndex)) {
    bestKind = QUOTE_KIND_TID
    bestIndex = tidMatch.index
    bestTidRaw = tidMatch[1]
  }
  const replyMatch: RegExpExecArray | null = RE_REPLY_PID.exec(content)
  if (replyMatch !== null && (bestIndex < 0 || replyMatch.index < bestIndex)) {
    bestKind = QUOTE_KIND_REPLY
    bestIndex = replyMatch.index
    bestPidRaw = replyMatch[1]
  }
  if (bestKind === QUOTE_KIND_NONE) {
    return null
  }

  const header: string = buildHeaderWindow(content, bestIndex)
  const authorParts: string[] = parseQuotedAuthor(header)
  const ref: ThreadTreeQuoteRef = new ThreadTreeQuoteRef()
  ref.targetUid = authorParts[0]
  ref.targetAuthor = authorParts[1]
  ref.rawHeader = header.length > RAW_HEADER_MAX ? header.substring(0, RAW_HEADER_MAX) : header

  if (bestKind === QUOTE_KIND_TID) {
    const topicTid: number = parseIntegerToken(bestTidRaw)
    ref.targetPid = 0
    ref.targetPage = -1
    ref.external = tid > 0 && topicTid >= 0 && topicTid !== tid
    ref.isTopicRef = !ref.external
    return ref
  }

  const parts: string[] = splitPidParts(bestPidRaw)
  if (parts.length === 0) {
    return null
  }
  const targetPid: number = parseIntegerToken(parts[0])
  if (targetPid < 0) {
    return null
  }
  ref.targetPid = targetPid
  if (parts.length >= 2) {
    const targetTid: number = parseIntegerToken(parts[1])
    if (targetTid > 0 && tid > 0 && targetTid !== tid) {
      ref.external = true
    }
  }
  if (parts.length >= 3) {
    const targetPage: number = parseIntegerToken(parts[2])
    if (targetPage > 0) {
      ref.targetPage = targetPage
    }
  }
  if (targetPid === 0) {
    ref.isTopicRef = !ref.external
  }
  return ref
}

/**
 * 解析单个非主楼楼层的直接父楼层 pid。
 *
 * @param post - 当前楼层
 * @param ref - 当前楼层的主引用关系
 * @param model - 树模型（此时 `postByPid` 已填充）
 * @param mainPid - 主楼 pid（HTML 通道可能为 0）
 * @returns 父楼层 pid；0 表示该楼层是顶层根
 */
function resolveParentPid(post: PostInfo, ref: ThreadTreeQuoteRef | null,
  model: ThreadTreeModel, mainPid: number): number {
  if (ref === null) {
    return 0
  }
  if (ref.isTopicRef) {
    return 0
  }
  if (ref.external) {
    return 0
  }
  if (mainPid > 0 && ref.targetPid === mainPid) {
    return 0
  }
  const target: PostInfo | undefined = model.postByPid.get(ref.targetPid)
  if (target === undefined) {
    return 0
  }
  if (target.lou >= post.lou) {
    return 0
  }
  return ref.targetPid
}

/**
 * 沿父链回溯到顶层根 pid（带路径记忆化，整体 O(n)）。
 *
 * 父链要么终止于 `parentPid == 0` 的根，要么在防御 guard 内无法回溯（说明数据异常，
 * 调用方会按环处理）。正常情况下每条链只走一次。
 *
 * @param startPid - 起点楼层 pid
 * @param parentOfPid - 楼层 pid → 直接父 pid（0 表示根）
 * @param memo - 已解析根 pid 的记忆表
 * @param guard - 最大回溯步数（防止异常数据死循环）
 * @returns 顶层根楼层 pid
 */
function resolveTopRootPid(startPid: number, parentOfPid: Map<number, number>,
  memo: Map<number, number>, guard: number): number {
  const cached: number | undefined = memo.get(startPid)
  if (cached !== undefined) {
    return cached
  }
  const path: number[] = []
  let cursor: number = startPid
  let top: number = startPid
  let steps: number = 0
  let resolved: boolean = false
  while (steps <= guard) {
    path.push(cursor)
    const parent: number | undefined = parentOfPid.get(cursor)
    if (parent === undefined || parent === 0) {
      top = cursor
      resolved = true
      break
    }
    cursor = parent
    steps++
  }
  if (!resolved) {
    top = cursor
  }
  for (let i: number = 0; i < path.length; i++) {
    memo.set(path[i], top)
  }
  return top
}

/**
 * 按引用关系构建两层递进树。
 *
 * 建树规则（`docs/THREAD_TREE_DESIGN.md` §2.2）：
 * 1. 主楼 = 第一个 `lou === 0` 的楼层，是第一个根且**无子节点**（主楼 pid 在 HTML 通道为 0）；
 * 2. 非主楼楼层的父楼层 pid 解析：无引用 / 引用主楼 / 跨帖 / 目标不存在 / 目标不更早
 *    （含自引用，防止环）→ 根（0）；其余 → 被引用楼层 pid；
 * 3. 根的任意深度后代统一平铺到该根之下，按楼层号升序（一次全局升序遍历 + 父链记忆化，
 *    复杂度 O(n)，无嵌套扫描）；
 * 4. 环防御：父链无法回溯到已注册根的楼层提升为根，保证不丢楼（真实数据不可能出现，
 *    因为父边恒指向更小楼号）。
 *
 * @param posts - 全帖楼层（顺序不限，内部按 `lou` 升序处理；调用方应已按 pid 去重）
 * @param totalPages - 帖子总页数（仅记录到模型，供展示/诊断）
 * @returns 已构建好 `roots` 与 `rows` 的两层树模型
 */
export function buildThreadTree(posts: PostInfo[], totalPages: number): ThreadTreeModel {
  const model: ThreadTreeModel = new ThreadTreeModel()
  model.totalPages = totalPages > 0 ? totalPages : 0
  if (posts.length === 0) {
    return model
  }
  const sorted: PostInfo[] = []
  for (let i: number = 0; i < posts.length; i++) {
    sorted.push(posts[i])
  }
  sorted.sort((a: PostInfo, b: PostInfo): number => a.lou - b.lou)
  model.totalPosts = sorted.length

  let mainIndex: number = -1
  for (let i: number = 0; i < sorted.length; i++) {
    if (sorted[i].lou === 0) {
      mainIndex = i
      break
    }
  }
  const mainPost: PostInfo | null = mainIndex >= 0 ? sorted[mainIndex] : null
  model.mainPid = mainPost !== null ? mainPost.pid : 0

  let currentTid: number = 0
  for (let i: number = 0; i < sorted.length; i++) {
    if (sorted[i].tid > 0) {
      currentTid = sorted[i].tid
      break
    }
  }

  for (let i: number = 0; i < sorted.length; i++) {
    model.postByPid.set(sorted[i].pid, sorted[i])
  }

  const parentOfPid: Map<number, number> = new Map<number, number>()
  const refOfPid: Map<number, ThreadTreeQuoteRef> = new Map<number, ThreadTreeQuoteRef>()
  for (let i: number = 0; i < sorted.length; i++) {
    if (i === mainIndex) {
      continue
    }
    const post: PostInfo = sorted[i]
    const ref: ThreadTreeQuoteRef | null = extractPrimaryQuoteRef(post.content, currentTid)
    if (ref !== null) {
      refOfPid.set(post.pid, ref)
      model.quoteCount++
    }
    parentOfPid.set(post.pid, resolveParentPid(post, ref, model, model.mainPid))
  }

  const rootList: ThreadTreeRoot[] = []
  const rootByPid: Map<number, ThreadTreeRoot> = new Map<number, ThreadTreeRoot>()
  if (mainPost !== null) {
    const mainRoot: ThreadTreeRoot = new ThreadTreeRoot()
    mainRoot.post = mainPost
    mainRoot.displayContent = stripQuoteArea(mainPost.content)
    mainRoot.ref = null
    rootList.push(mainRoot)
    rootByPid.set(mainPost.pid, mainRoot)
    model.rootPidOfPid.set(mainPost.pid, mainPost.pid)
  }
  for (let i: number = 0; i < sorted.length; i++) {
    if (i === mainIndex) {
      continue
    }
    const post: PostInfo = sorted[i]
    const parentPid: number = parentOfPid.get(post.pid) ?? 0
    if (parentPid !== 0) {
      continue
    }
    const root: ThreadTreeRoot = new ThreadTreeRoot()
    root.post = post
    root.displayContent = stripQuoteArea(post.content)
    const rootRef: ThreadTreeQuoteRef | undefined = refOfPid.get(post.pid)
    root.ref = rootRef !== undefined ? rootRef : null
    rootList.push(root)
    rootByPid.set(post.pid, root)
    model.rootPidOfPid.set(post.pid, post.pid)
  }
  rootList.sort((a: ThreadTreeRoot, b: ThreadTreeRoot): number => a.post.lou - b.post.lou)
  model.roots = rootList

  const promotedRoots: ThreadTreeRoot[] = []
  const topRootMemo: Map<number, number> = new Map<number, number>()
  const guard: number = sorted.length + 1
  for (let i: number = 0; i < sorted.length; i++) {
    if (i === mainIndex) {
      continue
    }
    const post: PostInfo = sorted[i]
    const parentPid: number = parentOfPid.get(post.pid) ?? 0
    if (parentPid === 0) {
      continue
    }
    const topRootPid: number = resolveTopRootPid(post.pid, parentOfPid, topRootMemo, guard)
    const root: ThreadTreeRoot | undefined = rootByPid.get(topRootPid)
    if (root === undefined) {
      const promoted: ThreadTreeRoot = new ThreadTreeRoot()
      promoted.post = post
      promoted.displayContent = stripQuoteArea(post.content)
      const promotedRef: ThreadTreeQuoteRef | undefined = refOfPid.get(post.pid)
      promoted.ref = promotedRef !== undefined ? promotedRef : null
      promotedRoots.push(promoted)
      rootByPid.set(post.pid, promoted)
      model.rootPidOfPid.set(post.pid, post.pid)
      continue
    }
    const child: ThreadTreeChild = new ThreadTreeChild()
    child.post = post
    child.displayContent = stripQuoteArea(post.content)
    child.parentPid = parentPid
    const childRef: ThreadTreeQuoteRef | undefined = refOfPid.get(post.pid)
    child.ref = childRef !== undefined ? childRef : new ThreadTreeQuoteRef()
    root.children.push(child)
    model.rootPidOfPid.set(post.pid, topRootPid)
  }

  if (promotedRoots.length > 0) {
    for (let i: number = 0; i < promotedRoots.length; i++) {
      rootList.push(promotedRoots[i])
    }
    rootList.sort((a: ThreadTreeRoot, b: ThreadTreeRoot): number => a.post.lou - b.post.lou)
    model.roots = rootList
  }

  flattenThreadTree(model)
  return model
}

/**
 * 按当前 `roots[].expanded` 状态重算可见扁平行 `model.rows`。
 *
 * 行序：`[主楼根行] [根 1 行, 根 1 可见子行…, 根 1 MORE?] [根 2 行, …]`。
 * 折叠规则：某根后代总数 > 3 且未展开时只显示前 2 条，追加一行 `MORE`
 * （`totalCount` = 后代总数、`hiddenCount` = 总数 - 2）；后代 <= 3 或已展开时全部显示。
 * 主楼根 `children` 恒为空，不产生 MORE 行。行的 `rev` 取所属根的 `rev`，
 * 展开/折叠后该根所有行键值同步变化；未变化行的楼层 pid 保持不变。
 *
 * @param model - 两层树模型（就地更新 `rows`）
 */
export function flattenThreadTree(model: ThreadTreeModel): void {
  const rows: ThreadTreeRow[] = []
  for (let r: number = 0; r < model.roots.length; r++) {
    const root: ThreadTreeRoot = model.roots[r]
    const rootPid: number = root.post.pid
    const rootRow: ThreadTreeRow = new ThreadTreeRow()
    rootRow.kind = ThreadTreeRowKind.ROOT
    rootRow.post = root.post
    rootRow.displayContent = root.displayContent
    rootRow.rootPid = rootPid
    rootRow.childIndex = -1
    rootRow.ref = root.ref
    rootRow.highlighted = false
    rootRow.rev = root.rev
    rows.push(rootRow)

    const children: ThreadTreeChild[] = root.children
    const childCount: number = children.length
    const collapsed: boolean = !root.expanded && childCount > FOLD_CHILD_THRESHOLD
    const visibleCount: number = collapsed ? COLLAPSED_VISIBLE_CHILD_COUNT : childCount
    for (let i: number = 0; i < visibleCount; i++) {
      const child: ThreadTreeChild = children[i]
      const childRow: ThreadTreeRow = new ThreadTreeRow()
      childRow.kind = ThreadTreeRowKind.CHILD
      childRow.post = child.post
      childRow.displayContent = child.displayContent
      childRow.rootPid = rootPid
      childRow.childIndex = i
      childRow.ref = child.ref
      childRow.highlighted = child.highlighted
      childRow.rev = root.rev
      rows.push(childRow)
    }
    if (collapsed) {
      const moreRow: ThreadTreeRow = new ThreadTreeRow()
      moreRow.kind = ThreadTreeRowKind.MORE
      moreRow.post = null
      moreRow.rootPid = rootPid
      moreRow.childIndex = -1
      moreRow.ref = null
      moreRow.hiddenCount = childCount - COLLAPSED_VISIBLE_CHILD_COUNT
      moreRow.totalCount = childCount
      moreRow.highlighted = false
      moreRow.rev = root.rev
      rows.push(moreRow)
    }
  }
  model.rows = rows
}

/**
 * 展开指定根的全部子节点（只改模型状态，不重算 rows、不通知数据源）。
 *
 * @param model - 两层树模型
 * @param rootPid - 目标根节点 pid
 * @returns 本次确实由「收起」变为「展开」返回 true；已展开 / 根不存在 / 主楼根（无子节点）返回 false
 */
export function expandRoot(model: ThreadTreeModel, rootPid: number): boolean {
  for (let i: number = 0; i < model.roots.length; i++) {
    const root: ThreadTreeRoot = model.roots[i]
    if (root.post.pid !== rootPid) {
      continue
    }
    if (root.children.length === 0 || root.expanded) {
      return false
    }
    root.expanded = true
    root.rev++
    return true
  }
  return false
}

/**
 * 在可见行中按楼层 pid 查找行下标。
 *
 * @param rows - 可见扁平行（通常为 `model.rows` / 数据源当前内容）
 * @param pid - 目标楼层 pid
 * @returns 行下标；MORE 行与未命中返回 -1
 */
export function findRowIndexByPid(rows: ThreadTreeRow[], pid: number): number {
  for (let i: number = 0; i < rows.length; i++) {
    const post: PostInfo | null = rows[i].post
    if (post !== null && post.pid === pid) {
      return i
    }
  }
  return -1
}

/**
 * 查询楼层 pid 在两层树中的归属根 pid。
 *
 * @param model - 两层树模型
 * @param pid - 目标楼层 pid
 * @returns 根节点自身返回其 pid；第二层子节点返回所属根 pid；不在模型中返回 -1
 */
export function findRootPidByPid(model: ThreadTreeModel, pid: number): number {
  const mapped: number | undefined = model.rootPidOfPid.get(pid)
  if (mapped !== undefined) {
    return mapped
  }
  for (let i: number = 0; i < model.roots.length; i++) {
    if (model.roots[i].post.pid === pid) {
      return pid
    }
  }
  return -1
}

/** 正文开头允许出现的空白与换行标签（剥离引用区后一并清理）。 */
const LEADING_BREAK_PATTERN: RegExp = /^(?:\s|<br\s*\/?>|\u00a0)+/i

/**
 * 去掉正文开头的引用区，返回树模式要显示的正文。
 *
 * 树的两层父子关系 + 子节点「回复 @作者 →」已经表达「这层回复了谁」，
 * 正文里再显示一遍引用块既冗余又占屏幕，故树模式渲染前统一剥离：
 *
 * 1. `[b]Reply to [pid=…]…[/b]` 回复头（快速回复自动生成的头）；
 * 2. `[quote]…[/quote]` 引用块（支持嵌套 `[quote]`，按标签深度平衡扫描，
 *    不会像非贪婪正则那样在嵌套时截断）；
 * 3. 两者可连续出现（循环剥离，最多 8 轮防御异常数据）；
 * 4. 剥离后清理开头的空白、`<br/>`，其余正文格式原样保留。
 *
 * 只剥离**正文开头**的引用区：NGA 的引用由服务端生成在正文首部，正文中部
 * 出现的 `[quote]` 字样视为用户正文内容，不做删除（文字不被吞原则）。
 *
 * @param content - 楼层原始 BBCode 正文
 * @returns 剥离引用区后的正文；引用区后没有正文时返回空串
 */
export function stripQuoteArea(content: string): string {
  if (content.length === 0) {
    return content
  }
  let current: string = content
  let guard: number = 0
  while (guard < 8) {
    guard++
    const stripped: string | null = stripOneLeadingArea(current)
    if (stripped === null) {
      break
    }
    current = stripped
  }
  return current.replace(LEADING_BREAK_PATTERN, '')
}

/**
 * 剥离一个开头的引用区（`[b]Reply to …[/b]` 或平衡的 `[quote]…[/quote]`）。
 *
 * @param content - 待处理正文
 * @returns 剥离后的剩余正文；开头不是引用区时返回 null
 */
function stripOneLeadingArea(content: string): string | null {
  const leading: RegExpMatchArray | null = content.match(/^\s*/)
  const offset: number = leading !== null ? leading[0].length : 0
  const rest: string = content.substring(offset)
  const lower: string = rest.toLowerCase()
  if (lower.startsWith('[b]reply to')) {
    const close: number = lower.indexOf('[/b]')
    if (close < 0) {
      return null
    }
    return rest.substring(close + 4)
  }
  if (lower.startsWith('[quote]')) {
    const end: number = findBalancedQuoteEnd(lower)
    if (end < 0) {
      return null
    }
    return rest.substring(end)
  }
  return null
}

/**
 * 查找从 0 开始的 `[quote]` 块的闭合位置（标签深度平衡扫描）。
 *
 * @param lower - 小写化后的正文（保证从 0 开始就是 `[quote]`）
 * @returns 闭合标签之后的下标；未闭合返回 -1
 */
function findBalancedQuoteEnd(lower: string): number {
  const openTag: string = '[quote]'
  const closeTag: string = '[/quote]'
  let depth: number = 0
  let index: number = 0
  while (index < lower.length) {
    if (lower.startsWith(openTag, index)) {
      depth++
      index += openTag.length
      continue
    }
    if (lower.startsWith(closeTag, index)) {
      depth--
      index += closeTag.length
      if (depth === 0) {
        return index
      }
      continue
    }
    index++
  }
  return -1
}
