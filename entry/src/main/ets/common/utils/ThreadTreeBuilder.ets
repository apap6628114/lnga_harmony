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
 * 1. `extractPrimaryQuoteRef`：从楼层 BBCode 正文**开头**的服务端引用区提取「本层回复了哪一层」；
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
 *
 * **引用区的位置约束（精准识别与区分的核心）**：服务端只把回复/引用头生成在正文最前面，
 * 因此引用关系只从**正文开头**提取；正文中部出现的 `[quote]` / `[pid=…]` 是用户自己写的
 * 内容（复制、排版、手打标签），不建边、不剥离，原样展示。`stripQuoteArea` 与
 * `extractPrimaryQuoteRef` 共用同一次「头部引用区扫描」，避免两边判定不一致产生
 * 「建了边却留着引用块」或「没建边却把用户正文吃掉」。
 */

/** 头部扫描窗口上限（字符）：足以覆盖完整引用头、作者段与日期段。 */
const HEADER_SCAN_MAX: number = 400

/** `rawHeader` 诊断字段的截断上限（字符）。 */
const RAW_HEADER_MAX: number = 200

/** 折叠阈值：某根后代总数大于该值时默认只显示前两条。 */
const FOLD_CHILD_THRESHOLD: number = 3

/** 折叠时默认显示的子树条数。 */
const COLLAPSED_VISIBLE_CHILD_COUNT: number = 2

/**
 * 引用块内 pid 头：必须**紧贴块首**（`[quote]` 之后），且以 `Reply` 收尾。
 *
 * 这是「服务端生成的引用块」的结构特征。只认块首：正文中部（用户正文里）出现的
 * `[pid=…]` 一律不构成引用关系，避免把用户手写的引用样式误当成回复对象。
 */
const RE_QUOTE_PID_HEAD: RegExp = /^\[pid=([^\]]*)\]\s*(?:Reply\s*)?\[\/pid\]/i

/** 引用块内主楼头：`[tid=T]Topic[/tid]`，同样必须紧贴块首。 */
const RE_QUOTE_TID_HEAD: RegExp = /^\[tid=([^\]]*)\]\s*Topic\s*\[\/tid\]/i

/** 回复头的楼层形态：`[b]Reply to [pid=A,B,C]Reply[/pid]`，必须紧贴正文开头。 */
const RE_REPLY_TO_HEAD: RegExp = /^\[b\]\s*Reply to\s*\[pid=([^\]]*)\]\s*(?:Reply\s*)?\[\/pid\]/i

/** 回复头的主楼形态：`[b]Reply to [tid=T]Topic[/tid]`（回复楼主时真实出现）。 */
const RE_REPLY_TO_TID_HEAD: RegExp = /^\[b\]\s*Reply to\s*\[tid=([^\]]*)\]\s*Topic\s*\[\/tid\]/i

/** 带属性 uid：`[uid=123]name[/uid]` / `[uid=#anony_x]name[/uid]`（名字可为空）。 */
const RE_UID_ATTR: RegExp = /\[uid=([^\]]*)\]([\s\S]*?)\[\/uid\]/

/** 无属性 uid：`[uid]#anony_<32hex>[/uid]`（真实匿名引用头的实际形态）。 */
const RE_UID_BARE: RegExp = /\[uid\]([\s\S]*?)\[\/uid\]/

/** 纯整数 token（允许负号，兼容异常 uid / 局部楼号）。 */
const RE_INT_TOKEN: RegExp = /^-?\d+$/

/** 前导噪音字符（空白、不间断空格）：引用区之前只允许这些。 */
const LEADING_NOISE_CHARS: string = ' \t\r\n\u00a0'

/** 引用块开标签（精确匹配，`[quote=…]` 不算，NGA 只产出 `[quote]`）。 */
const QUOTE_OPEN_TAG: string = '[quote]'

/** 引用块闭标签。 */
const QUOTE_CLOSE_TAG: string = '[/quote]'

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
 * 跳过正文开头的前导噪音（空白、`&nbsp;`、`<br>`/`<br/>` 换行标签）。
 *
 * 引用区只可能出现在**正文开头**：服务端生成引用块时把它放在正文最前面，
 * 允许的差异只有空白与换行标签。前导出现任何实体正文（文字、图片、格式标签）
 * 时扫描立即停止——那说明后面的 `[quote]` 属于用户正文排版，不是回复关系。
 *
 * @param content - 楼层正文
 * @param from - 起始下标
 * @returns 第一个非噪音字符的下标
 */
function skipLeadingNoise(content: string, from: number): number {
  let cursor: number = from
  while (cursor < content.length) {
    const ch: string = content.charAt(cursor)
    if (LEADING_NOISE_CHARS.indexOf(ch) >= 0) {
      cursor++
      continue
    }
    const tagEnd: number = matchBlankTag(content, cursor)
    if (tagEnd > 0) {
      cursor = tagEnd
      continue
    }
    break
  }
  return cursor
}

/**
 * 匹配一个前导空白类标签（`<br>` 系列或 `&nbsp;`）。
 *
 * @param content - 楼层正文
 * @param at - 待匹配下标
 * @returns 标签之后的下标；不匹配返回 -1
 */
function matchBlankTag(content: string, at: number): number {
  const probe: string = content.substring(at, Math.min(content.length, at + 8)).toLowerCase()
  if (probe.indexOf('<br/>') === 0) {
    return at + 5
  }
  if (probe.indexOf('<br>') === 0) {
    return at + 4
  }
  if (probe.indexOf('<br />') === 0) {
    return at + 6
  }
  if (probe.indexOf('&nbsp;') === 0) {
    return at + 6
  }
  return -1
}

/**
 * 判断给定下标处是否匹配一个 BBCode 标签（ASCII 大小写不敏感、无字符串分配）。
 *
 * 不用「整串 toLowerCase 后用 lower 的下标切原串」：Unicode 里有些字符（如 `İ`）
 * 小写化后长度会变，lower 串的下标与原串错位，剥离位置会切在字符中间。
 * 逐字符比较只针对 ASCII，下标始终对应原串；同时保持 O(tag 长度) 的常数开销，
 * 这是 `findQuoteBlockEnd` 能维持 O(n) 的关键（`indexOf` 在未命中时才扫到串尾，
 * 放在逐字符循环里会退化成 O(n²)）。
 *
 * @param content - 楼层正文
 * @param at - 待判断下标
 * @param tag - 小写标签（如 `[quote]`）
 * @returns 匹配时为 true
 */
function matchTagAt(content: string, at: number, tag: string): boolean {
  if (at < 0 || at + tag.length > content.length) {
    return false
  }
  for (let i: number = 0; i < tag.length; i++) {
    let code: number = content.charCodeAt(at + i)
    if (code >= 65 && code <= 90) {
      code += 32
    }
    if (code !== tag.charCodeAt(i)) {
      return false
    }
  }
  return true
}

/**
 * 查找从指定下标开始的 `[quote]` 块的闭合位置（标签深度平衡扫描）。
 *
 * 支持嵌套 `[quote]`（防御异常数据），不做非贪婪截断；逐字符比较标签，
 * 单遍扫描 O(n)。
 *
 * @param content - 楼层正文
 * @param start - 块起始下标（必须是 `[quote]`）
 * @returns 闭合标签之后的下标；未闭合或括号不平衡时返回 -1
 */
function findQuoteBlockEnd(content: string, start: number): number {
  let depth: number = 0
  let index: number = start
  while (index < content.length) {
    if (matchTagAt(content, index, QUOTE_OPEN_TAG)) {
      depth++
      index += QUOTE_OPEN_TAG.length
      continue
    }
    if (matchTagAt(content, index, QUOTE_CLOSE_TAG)) {
      depth--
      index += QUOTE_CLOSE_TAG.length
      if (depth === 0) {
        return index
      }
      if (depth < 0) {
        return -1
      }
      continue
    }
    index++
  }
  return -1
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
 * 头部引用区扫描结果。
 *
 * `ref` 与 `bodyStart` 由**同一次扫描**产出，保证「提取引用关系」与「剥离引用区」
 * 使用完全一致的判定：不会出现「建了边却把正文里的引用块留下」或
 * 「没建边却把用户自己写的引用块吃掉」的不一致。
 */
class LeadingQuoteScan {
  /** 正文开头的服务端引用关系；没有引用区时为 null。 */
  ref: ThreadTreeQuoteRef | null = null

  /** 正文起点：跳过引用区后的下标；无引用区时为 0。 */
  bodyStart: number = 0
}

/** 一个已识别的引用区片段（引用关系 + 区段结束位置）。 */
class QuoteAreaMatch {
  /** 该片段表达的引用关系。 */
  ref: ThreadTreeQuoteRef = new ThreadTreeQuoteRef()

  /** 片段结束位置（`[/quote]` 或 `[/b]` 之后的下标）。 */
  end: number = 0
}

/**
 * 填充被引用作者 uid / 显示名与诊断原文。
 *
 * @param ref - 目标引用关系
 * @param headerText - 引用头原文（从引用区起点截取）
 */
function fillQuotedAuthor(ref: ThreadTreeQuoteRef, headerText: string): void {
  const authorParts: string[] = parseQuotedAuthor(headerText)
  ref.targetUid = authorParts[0]
  ref.targetAuthor = authorParts[1]
  ref.rawHeader = headerText.length > RAW_HEADER_MAX
    ? headerText.substring(0, RAW_HEADER_MAX) : headerText
}

/**
 * 由 `[pid=A,B,C]Reply[/pid]` 头构造引用关系。
 *
 * B 段为被引用楼层所属主题 tid，与当前 tid 不同即标记 `external`（跨帖引用）；
 * B 段缺失或当前 tid 未知（<=0）时不判跨帖。C 段仅记录、不可信。
 *
 * @param pidRaw - 方括号内原始参数
 * @param headerText - 引用头原文
 * @param tid - 当前帖子 tid
 * @returns 引用关系；A 段不是有效整数时返回 null
 */
function buildPidRef(pidRaw: string, headerText: string, tid: number): ThreadTreeQuoteRef | null {
  const parts: string[] = splitPidParts(pidRaw)
  if (parts.length === 0) {
    return null
  }
  const targetPid: number = parseIntegerToken(parts[0])
  if (targetPid < 0) {
    return null
  }
  const ref: ThreadTreeQuoteRef = new ThreadTreeQuoteRef()
  ref.targetPid = targetPid
  fillQuotedAuthor(ref, headerText)
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
 * 由 `[tid=T]Topic[/tid]` 主楼头构造引用关系。
 *
 * @param topicTidRaw - 方括号内主题 id 原文
 * @param headerText - 引用头原文
 * @param tid - 当前帖子 tid
 * @returns 引用关系；主题 id 不是有效整数时返回 null
 */
function buildTopicRef(topicTidRaw: string, headerText: string, tid: number): ThreadTreeQuoteRef | null {
  const topicTid: number = parseIntegerToken(topicTidRaw)
  if (topicTid < 0) {
    return null
  }
  const ref: ThreadTreeQuoteRef = new ThreadTreeQuoteRef()
  ref.targetPid = 0
  ref.targetPage = -1
  ref.external = tid > 0 && topicTid !== tid
  ref.isTopicRef = !ref.external
  fillQuotedAuthor(ref, headerText)
  return ref
}

/**
 * 构造作者段解析窗口：从引用区起点到 `[/b]` 或第一处 `<br`（取先到者）。
 *
 * 不能用整个引用块的前 400 字符当作者窗口：被引正文里出现的 `[uid=…]` 提及
 * 会被误当成被引用作者。作者段一定在头部的 `[b]Post by …[/b]` 内，按 `[/b]`/`<br`
 * 截断即可。
 *
 * @param content - 楼层正文
 * @param start - 引用区起点
 * @param hardEnd - 引用区硬结束位置（块闭合处或正文末尾）
 * @returns 作者段解析窗口
 */
function buildAuthorWindow(content: string, start: number, hardEnd: number): string {
  let end: number = Math.min(hardEnd, start + HEADER_SCAN_MAX)
  const boldClose: number = content.indexOf('[/b]', start)
  if (boldClose >= 0 && boldClose + 4 < end) {
    end = boldClose + 4
  }
  const brIndex: number = content.indexOf('<br', start)
  if (brIndex >= 0 && brIndex < end) {
    end = brIndex
  }
  return content.substring(start, end)
}

/**
 * 匹配「[quote] 块首就是链接头」的服务端引用块。
 *
 * 判定必须同时满足：
 * 1. 块从 `start` 处开始；
 * 2. 块内第一个有效元素（跳过空白/换行）就是 `[pid=…]Reply[/pid]` 或 `[tid=…]Topic[/tid]`；
 * 3. 链接头可解析出有效目标。
 *
 * 只认块首：`[quote]用户正文…[pid=…]` 或块中部出现的链接头属于用户正文排版，
 * 不是回复关系。
 *
 * 块**未闭合**时仍然提取引用关系（关系不丢），但 `end` 置为起点表示不剥离——
 * 无法确定块在哪里结束，剥离会把后面的正文一起吃掉。
 *
 * @param content - 楼层正文
 * @param start - 待匹配下标
 * @param tid - 当前帖子 tid
 * @returns 匹配结果；不是服务端引用块时返回 null
 */
function matchServiceQuoteBlock(content: string, start: number,
  tid: number): QuoteAreaMatch | null {
  if (!matchTagAt(content, start, QUOTE_OPEN_TAG)) {
    return null
  }
  const blockEnd: number = findQuoteBlockEnd(content, start)
  const limit: number = blockEnd >= 0 ? blockEnd : content.length
  const headPos: number = skipLeadingNoise(content, start + QUOTE_OPEN_TAG.length)
  if (headPos >= limit) {
    return null
  }
  const headWindow: string = content.substring(headPos,
    Math.min(limit, headPos + HEADER_SCAN_MAX))
  const authorWindow: string = buildAuthorWindow(content, start, limit)
  let ref: ThreadTreeQuoteRef | null = null
  const pidMatch: RegExpExecArray | null = RE_QUOTE_PID_HEAD.exec(headWindow)
  if (pidMatch !== null) {
    ref = buildPidRef(pidMatch[1], authorWindow, tid)
  } else {
    const tidMatch: RegExpExecArray | null = RE_QUOTE_TID_HEAD.exec(headWindow)
    if (tidMatch !== null) {
      ref = buildTopicRef(tidMatch[1], authorWindow, tid)
    }
  }
  if (ref === null) {
    return null
  }
  const match: QuoteAreaMatch = new QuoteAreaMatch()
  match.ref = ref
  match.end = blockEnd >= 0 ? blockEnd : start
  return match
}

/**
 * 判断回复头的 `[/b]` 是否真的属于头部结构。
 *
 * 头缺 `[/b]` 时，正文里后面的 `[b]…[/b]` 会提供一个「看起来在 400 字符内」的
 * `[/b]`；直接拿它当头部结束会把中间正文整段吃掉。头部内部不可能出现 `<br` 或
 * 第二个 `[b]`，出现任一即判定这个 `[/b]` 不属于头。
 *
 * @param content - 楼层正文
 * @param start - 头起始下标
 * @param boldClose - 候选 `[/b]` 下标
 * @returns `[/b]` 属于头部时为 true
 */
function isSafeReplyHeaderClose(content: string, start: number, boldClose: number): boolean {
  if (boldClose <= start + 3) {
    return false
  }
  const body: string = content.substring(start + 3, boldClose).toLowerCase()
  return body.indexOf('<br') < 0 && body.indexOf('[b]') < 0
}

/**
 * 匹配正文开头的 `[b]Reply to …[/b]` 回复头（pid 形态与主楼 tid 形态）。
 *
 * 头必须紧贴正文开头（允许前导空白/换行）。真实数据里 `[/b]` 偶尔缺失，或正文
 * 在窗口内含 `[b]`：此时仍提取引用关系（关系不丢），但把 `end` 置为起点表示
 * **不剥离**——无法确定头在哪里结束，剥离会把后面的正文一起吃进「引用区」。
 *
 * @param content - 楼层正文
 * @param start - 待匹配下标
 * @param tid - 当前帖子 tid
 * @returns 匹配结果；不是回复头时返回 null
 */
function matchReplyToHeader(content: string, start: number, tid: number): QuoteAreaMatch | null {
  const headWindow: string = content.substring(start,
    Math.min(content.length, start + HEADER_SCAN_MAX))
  const pidMatch: RegExpExecArray | null = RE_REPLY_TO_HEAD.exec(headWindow)
  const tidMatch: RegExpExecArray | null = pidMatch === null
    ? RE_REPLY_TO_TID_HEAD.exec(headWindow) : null
  let ref: ThreadTreeQuoteRef | null = null
  if (pidMatch !== null) {
    ref = buildPidRef(pidMatch[1], headWindow, tid)
  } else if (tidMatch !== null) {
    ref = buildTopicRef(tidMatch[1], headWindow, tid)
  }
  if (ref === null) {
    return null
  }
  const boldClose: number = content.indexOf('[/b]', start)
  const closed: boolean = boldClose >= 0 && boldClose + 4 <= start + HEADER_SCAN_MAX &&
    isSafeReplyHeaderClose(content, start, boldClose)
  const match: QuoteAreaMatch = new QuoteAreaMatch()
  match.ref = ref
  match.end = closed ? boldClose + 4 : start
  return match
}

/**
 * 扫描正文开头的服务端引用区（`[b]Reply to …[/b]` 或 `[quote]` + 链接头）。
 *
 * **只扫正文开头**：NGA 的引用/回复头由服务端生成在正文最前面。正文中部出现的
 * `[quote]` 块、`[pid=…]`/`[b]Reply to` 字样都是用户自己写的正文（复制、排版、
 * 手打标签），既不能建回复关系，也不能从显示内容里删掉——否则会出现「树里挂错
 * 父楼层」或「用户正文被吞」两类意外表现。
 *
 * 最多剥离一个引用区：`[Reply to 头]` 或 `[quote] 块`，以及 Reply to 头后紧跟的
 * 一个引用块（防御组合形态）。再往后的内容一律视为正文。
 *
 * @param content - 楼层 BBCode 正文
 * @param tid - 当前帖子 tid（用于跨帖判定；未知时传 0）
 * @returns 引用关系与正文起点
 */
function scanLeadingQuoteArea(content: string, tid: number): LeadingQuoteScan {
  const scan: LeadingQuoteScan = new LeadingQuoteScan()
  if (content.length === 0) {
    return scan
  }
  const cursor: number = skipLeadingNoise(content, 0)
  if (cursor >= content.length) {
    scan.bodyStart = cursor
    return scan
  }
  /** 快速路径：开头不是 `[quote` 或 `[b]` 时不可能有引用区 */
  const probe: string = content.substring(cursor, Math.min(content.length, cursor + 7)).toLowerCase()
  if (probe.indexOf('[quote') !== 0 && probe.indexOf('[b]') !== 0) {
    return scan
  }
  const reply: QuoteAreaMatch | null = matchReplyToHeader(content, cursor, tid)
  if (reply !== null) {
    scan.ref = reply.ref
    if (reply.end <= cursor) {
      /** 回复头未安全闭合：关系保留，但正文一律不剥离（避免吞掉头后面的内容） */
      return scan
    }
    let bodyStart: number = skipLeadingNoise(content, reply.end)
    const quote: QuoteAreaMatch | null = matchServiceQuoteBlock(content, bodyStart, tid)
    if (quote !== null && quote.end > bodyStart) {
      bodyStart = skipLeadingNoise(content, quote.end)
    }
    scan.bodyStart = bodyStart
    return scan
  }
  const quote: QuoteAreaMatch | null = matchServiceQuoteBlock(content, cursor, tid)
  if (quote !== null) {
    scan.ref = quote.ref
    if (quote.end > cursor) {
      scan.bodyStart = skipLeadingNoise(content, quote.end)
    }
  }
  return scan
}

/**
 * 从楼层正文中提取主引用关系（本层回复了哪一层）。
 *
 * **只认正文开头的服务端引用区**（`docs/THREAD_TREE_DESIGN.md` §2.1）：
 * - 引用块头：`[quote][pid=A,B,C]Reply[/pid] [b]Post by [uid=U]name[/uid] …:[/b]…[/quote]`；
 * - 回复头：`[b]Reply to [pid=A,B,C]Reply[/pid] Post by [uid=U]name[/uid] …[/b]`；
 * - 主楼引用头：`[quote][tid=T]Topic[/tid] [b]Post by …[/b]` 或 `[pid=0,T,1]`。
 *
 * 正文中部出现的任何引用样式（用户手打的 `[quote]`、复制的 `[pid=…]` 片段）
 * **不构成回复关系**，只作为正文内容展示。
 *
 * 字段规则：
 * - `[uid=…]` 段宽松匹配，兼容数字 uid、`[uid]#anony_<32hex>[/uid]` 与 `[uid=#anony_…]`；
 * - 作者段允许 `(日期 时间)`、`[color=gray](224楼)[/color]`、`(31楼)` 等变体，只解析到
 *   `[/uid]` 为止，不强制 `(date):` 结尾；
 * - B 段与当前 tid 不同 → `external = true`（跨帖引用，建树时按根处理）；
 * - A 段为 0、`[tid=T]Topic` 块头、`[b]Reply to [tid=T]Topic[/tid]` 回复头均判定为主楼引用
 *   `isTopicRef = true`、`targetPid = 0`；
 * - C 段页码照原样记录到 `targetPage`，但**不可信、不用于定位**。
 *
 * @param content - 楼层 BBCode 正文
 * @param tid - 当前帖子 tid（用于跨帖判定；未知时传 0）
 * @returns 引用关系；正文开头没有服务端引用区时返回 null
 */
export function extractPrimaryQuoteRef(content: string, tid: number): ThreadTreeQuoteRef | null {
  return scanLeadingQuoteArea(content, tid).ref
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
  const displayContentOfPid: Map<number, string> = new Map<number, string>()
  for (let i: number = 0; i < sorted.length; i++) {
    const post: PostInfo = sorted[i]
    /** 一次扫描同时得到「引用关系」与「剥离引用区后的正文」，两者判定完全一致 */
    const scan: LeadingQuoteScan = scanLeadingQuoteArea(post.content, currentTid)
    displayContentOfPid.set(post.pid, stripScannedBody(post.content, scan))
    if (i === mainIndex) {
      continue
    }
    if (scan.ref !== null) {
      refOfPid.set(post.pid, scan.ref)
      model.quoteCount++
    }
    parentOfPid.set(post.pid, resolveParentPid(post, scan.ref, model, model.mainPid))
  }

  const rootList: ThreadTreeRoot[] = []
  const rootByPid: Map<number, ThreadTreeRoot> = new Map<number, ThreadTreeRoot>()
  if (mainPost !== null) {
    const mainRoot: ThreadTreeRoot = new ThreadTreeRoot()
    mainRoot.post = mainPost
    mainRoot.displayContent = displayContentOfPid.get(mainPost.pid) ?? mainPost.content
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
    root.displayContent = displayContentOfPid.get(post.pid) ?? post.content
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
      promoted.displayContent = displayContentOfPid.get(post.pid) ?? post.content
      const promotedRef: ThreadTreeQuoteRef | undefined = refOfPid.get(post.pid)
      promoted.ref = promotedRef !== undefined ? promotedRef : null
      promotedRoots.push(promoted)
      rootByPid.set(post.pid, promoted)
      model.rootPidOfPid.set(post.pid, post.pid)
      continue
    }
    const child: ThreadTreeChild = new ThreadTreeChild()
    child.post = post
    child.displayContent = displayContentOfPid.get(post.pid) ?? post.content
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
      childRow.showReplyTo = child.parentPid !== rootPid && child.parentPid !== 0
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
 * 按扫描结果截取树模式正文（跳过引用区并清理前导换行）。
 *
 * @param content - 楼层原始 BBCode 正文
 * @param scan - 头部引用区扫描结果
 * @returns 树模式要显示的正文
 */
function stripScannedBody(content: string, scan: LeadingQuoteScan): string {
  const body: string = scan.bodyStart > 0 ? content.substring(scan.bodyStart) : content
  return body.replace(LEADING_BREAK_PATTERN, '')
}

/**
 * 去掉正文开头的服务端引用区，返回树模式要显示的正文。
 *
 * 树的两层父子关系 + 子节点「回复 @作者 →」已经表达「这层回复了谁」，
 * 正文里再显示一遍引用块既冗余又占屏幕，故树模式渲染前统一剥离。
 *
 * **只剥离服务端引用区**（与 {@link extractPrimaryQuoteRef} 同一套判定）：
 * - `[b]Reply to [pid=…]…[/b]` 回复头（快速回复自动生成的头）；
 * - `[quote][pid=…]Reply[/pid]…[/quote]` / `[quote][tid=…]Topic[/tid]…[/quote]`
 *   引用块（块首必须是链接头；`[quote]` 支持嵌套，按标签深度平衡扫描，不会截断）。
 *
 * 不剥离的情况（保留原文，文字不被吞原则）：
 * - 正文中部的 `[quote]` 块（用户正文里复制/排版的引用样式）；
 * - 正文开头**没有链接头**的 `[quote]` 块（用户把 `[quote]` 当排版容器）；
 * - 未闭合的 `[quote]` 块（数据异常，宁可原样展示）。
 *
 * @param content - 楼层原始 BBCode 正文
 * @returns 剥离引用区后的正文；引用区后没有正文时返回空串
 */
export function stripQuoteArea(content: string): string {
  if (content.length === 0) {
    return content
  }
  return stripScannedBody(content, scanLeadingQuoteArea(content, 0))
}
