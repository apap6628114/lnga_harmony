/**
 * 引用注入核心 — 字符串级纯函数（TS 镜像真源）。
 *
 * NGA 的快速回复（Reply to）正文只携带被引用楼层的 pid 与作者信息，
 * 不含正文；服务端返回的引用正文也可能被截断。本模块在已加载楼层
 * 集合（经 lookup 回调）中查找原文并注入/修复，保证引用楼层展示完整内容。
 *
 * 与官方客户端语义对齐：注入的引用区只包含被回复楼层的正文，被回复楼层
 * 自身的引用区（[quote]...[/quote] 区块）整块丢弃，原正文的换行（<br/>）
 * 保留为 \n，不做标签剥离式的无缝拼接。
 *
 * 不依赖任何页面模型（PostInfo 等），entry 侧仅负责楼层集合装配
 * （见 entry QuoteInjection.ets），真实数据测试在 Node 侧进行。
 */

/** Reply to 引用头正则（[b]Reply to [pid=..,..,..]Reply[/pid] Post by [uid=..]..[/uid] (..)）。 */
const P_REPLY_HEADER: RegExp = /\[b\]Reply to \[pid=(\d+),(\d+),(\d+)\]Reply\[\/pid\] Post by \[uid=(\d+)\](.*?)\[\/uid\] \(([^)]+)\)/i

/**
 * 通用 Reply to 头（数字 uid 与匿名 `[uid]…[/uid]` 都接受，pid/tid 两种内嵌头）。
 *
 * 结构约束（防止把用户正文误当头部）：必须是 `[b]Reply to [pid=…]/[tid=…]` +
 * `Post by [uid…]…[/uid]`，头部尾部只允许「一个日期/楼号括号（可被 `[color=…]` 包裹）」
 * 与一个冒号；正文里出现的 `[uid=…]`、`(…)` 不会被当成头部延伸。
 */
const P_REPLY_HEADER_ANY: RegExp =
  /^\[b\]\s*Reply\s+to\s*\[(?:pid|tid)=[^\]]*\]\s*(?:Reply|Topic)\s*\[\/(?:pid|tid)\]\s*Post by\s*\[uid[^\]]*\][\s\S]*?\[\/uid\]\s*(?:\[color=[^\]]*\]\s*\(\d+楼\)\s*\[\/color\]\s*)?(?:\(\d{4}-\d{2}-\d{2}[0-9:\s-]*\)|\(\d+楼\))?\s*:?/i

/** 引用区内的 pid 引用头正则。 */
const P_QUOTE_HEADER: RegExp = /\[pid=(\d+),(\d+),(\d+)\]/i

/** Reply to 头与 `[/b]` 之间允许出现的字符：只有空白/冒号时 `[/b]` 才是头部闭合。 */
const HEADER_TAIL_BLANK: RegExp = /^[\s:]*$/

/** `[/b]` 之后允许出现的字符：只有空白/换行时该 `[/b]` 才可能是头部闭合。 */
const TRAILING_BLANK: RegExp = /^(?:\s|<br\s*\/?>)*$/i

/** 粘连形态正文末尾的头部闭合标签（只去末尾这一个）。 */
const TRAILING_BOLD_TAG: RegExp = /\s*\[\/b\]\s*$/i

/** 标准形态：头后紧跟 `[/b]`（允许中间有空白）。 */
const LEADING_BOLD_TAG: RegExp = /^\s*\[\/b\]/i

/**
 * 判断下标处是否匹配 ASCII 标签（大小写不敏感）。
 *
 * 逐字符比较只针对 ASCII，下标始终对应原串；不做整串 `toLowerCase`，
 * 避免 `İ` 等字符小写化变长导致下标错位。
 *
 * @param content 楼层正文
 * @param at 待判断下标
 * @param tag 小写标签（如 `[/b]`）
 * @returns 匹配时为 true
 */
function matchAsciiTagAt(content: string, at: number, tag: string): boolean {
  if (at < 0 || at + tag.length > content.length) {
    return false
  }
  for (let i = 0; i < tag.length; i++) {
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
 * 从后往前查找 ASCII 子串（大小写不敏感）。
 *
 * @param content 楼层正文
 * @param needle 小写目标子串
 * @param from 扫描起点（含）
 * @returns 命中下标；未命中返回 -1
 */
function lastIndexOfAsciiIgnoreCase(content: string, needle: string, from: number): number {
  for (let at = content.length - needle.length; at >= from; at--) {
    if (matchAsciiTagAt(content, at, needle)) {
      return at
    }
  }
  return -1
}

/**
 * 查找粘连形态正文末尾的头部闭合 `[/b]`。
 *
 * 判定条件：该 `[/b]` 位于正文末尾（之后只有空白/换行），且正文里 `[/b]` 数量
 * 恰比 `[b]` 多一个（多出来的那个属于头部的 `[b]`）。
 *
 * @param content 楼层正文
 * @param from 起始下标（头结束处）
 * @returns 末尾 `[/b]` 下标；不满足条件返回 -1
 */
function findTrailingHeaderBold(content: string, from: number): number {
  const lastClose: number = lastIndexOfAsciiIgnoreCase(content, '[/b]', from)
  if (lastClose < 0) {
    return -1
  }
  if (!TRAILING_BLANK.test(content.substring(lastClose + 4))) {
    return -1
  }
  let openCount: number = 0
  let closeCount: number = 0
  let index: number = from
  while (index < content.length) {
    if (matchAsciiTagAt(content, index, '[b]')) {
      openCount++
      index += 3
      continue
    }
    if (matchAsciiTagAt(content, index, '[/b]')) {
      closeCount++
      index += 4
      continue
    }
    index++
  }
  return closeCount === openCount + 1 ? lastClose : -1
}

/** Reply to 头切分结果。 */
class ReplyHeaderSplit {
  /** 头结束下标（作者段 + 日期括号之后）。 */
  headerEnd: number = 0

  /** 头之后的正文（已按标准/粘连形态去掉头部 `[/b]`）。 */
  replyText: string = ''
}

/**
 * 从 Reply to 头切出「头」与「头之后的正文」。
 *
 * 关键：头的结束点是**作者段 + 日期括号**（正则 `P_REPLY_HEADER` 的匹配末尾），
 * 不是 `[/b]`。真实数据存在粘连形态 `[b]Reply to … (日期)正文[/b]`——正文与头
 * 共用同一个 `[b]` 块，以 `[/b]` 为界会把正文整段丢掉（列表模式表现为整层只剩引用块）。
 *
 * @param content 楼层正文
 * @param headerMatch `P_REPLY_HEADER` 的匹配结果（含 index）
 * @returns 头结束下标与头之后的正文；结构无法判断时正文取头后全部（不丢字）
 */
function splitReplyHeader(content: string, headerMatch: RegExpMatchArray): ReplyHeaderSplit {
  const headerStart: number = headerMatch.index ?? 0
  const headerEnd: number = headerStart + headerMatch[0].length
  const split: ReplyHeaderSplit = new ReplyHeaderSplit()
  split.headerEnd = headerEnd
  const firstClose: number = content.indexOf('[/b]', headerEnd)
  if (firstClose >= 0 && HEADER_TAIL_BLANK.test(content.substring(headerEnd, firstClose))) {
    /** 标准形态：头后紧跟 `[/b]`，正文在 `[/b]` 之后 */
    split.replyText = content.substring(firstClose + 4)
    return split
  }
  const trailingClose: number = findTrailingHeaderBold(content, headerEnd)
  if (trailingClose >= 0) {
    /** 粘连形态：`[/b]` 在正文末尾，正文夹在头与 `[/b]` 之间 */
    split.replyText = content.substring(headerEnd, trailingClose)
    return split
  }
  /** 无法判断 `[/b]` 归属：只去头，其余全部保留（文字不被吞优先） */
  split.replyText = content.substring(headerEnd)
  return split
}

/**
 * 清理被引用楼层的原文为可注入正文。
 *
 * 规则（与官方 Reply to 补全语义一致）：
 * 1. 去掉被引用楼自身的 Reply to 头（标准形态与粘连形态都只去头、保留正文）；
 * 2. 整块删除被引用楼的引用区（[quote]...[/quote]），引用链内容不注入；
 *    注意：当前真实 NGA 数据中引用链由服务端平铺为扁平单层 [quote]，
 *    非贪婪匹配即可整块删除；若未来遇到嵌套 [quote] 会留下孤立 [/quote]，
 *    需要时改为最外层块平衡扫描；
 * 3. <br/> 转为 \n 保留段落分隔，连续空行折叠为一个换行。
 *
 * @param raw 被引用楼层的原始 content
 * @returns 清理后的正文；无可注入内容时为空串
 */
function cleanReferencedContent(raw: string): string {
  let body: string = raw
  const headerMatch: RegExpMatchArray | null = body.match(P_REPLY_HEADER)
  if (headerMatch !== null && (headerMatch.index ?? 0) <= 2) {
    const split: ReplyHeaderSplit = splitReplyHeader(body, headerMatch)
    body = split.replyText
  }
  return body
    .replace(/\[quote\][\s\S]*?\[\/quote\]/g, '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/\n{2,}/g, '\n')
    .trim()
}

/**
 * 去掉正文开头的 Reply to 头，返回头之后的正文（不 trim、不折叠换行）。
 *
 * 供「只展示内容、不重复回复头」的场景使用（楼中楼评论、回复编辑器的引用预览清洗）。
 * 头边界与 {@link buildReplyQuoteContent} 一致：结束于「作者段 + 日期/楼号括号」；
 * 标准形态去掉紧跟的 `[/b]`，粘连形态去掉正文末尾的 `[/b]`（仅当它在末尾）。
 * 非 Reply to 开头、或头前有正文前缀时原样返回（不误吞）。
 *
 * @param content 楼层/评论正文
 * @returns 去掉回复头后的正文；不满足条件时返回原正文
 */
export function stripReplyToHeader(content: string): string {
  if (content.length === 0) {
    return content
  }
  const match: RegExpExecArray | null = P_REPLY_HEADER_ANY.exec(content)
  if (match === null || (match.index ?? 0) > 2) {
    return content
  }
  const rest: string = content.substring(match[0].length)
  if (LEADING_BOLD_TAG.test(rest)) {
    return rest.replace(LEADING_BOLD_TAG, '')
  }
  return rest.replace(TRAILING_BOLD_TAG, '')
}

/**
 * 为快速回复（Reply to）格式的正文注入被引用楼层的正文。
 *
 * 目标正文形如 `[b]Reply to [pid=..,..,..]Reply[/pid] Post by [uid=..]..[/uid] (..)[/b]<正文>`，
 * 注入后变为 `[quote][pid=..]Reply[/pid] [b]Post by ...[/b]\n<被引用楼正文>[/quote]\n<br/><br/><正文>`。
 * 目标正文已以 [quote] 开头、非 Reply to 格式、或找不到被引用楼原文时原样返回。
 *
 * @param targetContent 需要处理的楼层正文
 * @param lookup 按 pid 查找被引用楼原文的回调（返回 undefined 表示未加载）
 * @returns 注入后的正文；不满足注入条件时返回原正文
 */
export function buildReplyQuoteContent(targetContent: string,
  lookup: (pid: number) => string | undefined): string {
  if (targetContent.startsWith('[quote]')) {
    return targetContent
  }
  const headerMatch: RegExpMatchArray | null = targetContent.match(P_REPLY_HEADER)
  if (!headerMatch) {
    return targetContent
  }
  const refPid: number = parseInt(headerMatch[1], 10)
  const rawContent: string | undefined = lookup(refPid)
  if (!rawContent) {
    return targetContent
  }
  const cleaned: string = cleanReferencedContent(rawContent)
  if (cleaned.length === 0) {
    return targetContent
  }
  /* Reply to 头之前的前缀文本必须保留（容错非标准数据，遵循文字不被吞原则）；
   * 头与正文的切分按「作者段 + 日期括号」定位：粘连形态下正文夹在头与 `[/b]` 之间，
   * 绝不能按 `[/b]` 截取——否则正文会被整段丢掉（列表模式整层只剩引用块）。 */
  const prefix: string = targetContent.substring(0, headerMatch.index ?? 0)
  const split: ReplyHeaderSplit = splitReplyHeader(targetContent, headerMatch)
  return `${prefix}[quote][pid=${headerMatch[1]},${headerMatch[2]},${headerMatch[3]}]Reply[/pid] [b]Post by [uid=${headerMatch[4]}]${headerMatch[5]}[/uid] (${headerMatch[6]}):[/b]\n${cleaned}[/quote]\n<br/><br/>${split.replyText}`
}

/**
 * 用已加载的完整原文修复服务端截断的引用正文。
 *
 * 仅当现有引用正文是完整原文的前缀时替换（防止截断点不明确时误改），
 * 替换保留段落换行。非 [quote] 开头、无 pid、原文缺失或前缀不匹配时原样返回。
 *
 * @param targetContent 需要处理的楼层正文（[quote] 开头）
 * @param lookup 按 pid 查找被引用楼原文的回调（返回 undefined 表示未加载）
 * @returns 修复后的正文；不满足修复条件时返回原正文
 */
export function fixTruncatedQuoteContent(targetContent: string,
  lookup: (pid: number) => string | undefined): string {
  if (!targetContent.startsWith('[quote]')) {
    return targetContent
  }
  const pidInQuote: RegExpMatchArray | null = targetContent.match(P_QUOTE_HEADER)
  if (!pidInQuote) {
    return targetContent
  }
  const refPid: number = parseInt(pidInQuote[1], 10)
  const fullContent: string | undefined = lookup(refPid)
  if (!fullContent) {
    return targetContent
  }
  const afterQuote: number = targetContent.indexOf('[quote]') + 7
  const headerEnd: number = targetContent.indexOf('[/b]', afterQuote)
  const quoteEnd: number = targetContent.indexOf('[/quote]', afterQuote)
  if (headerEnd < 0 || quoteEnd < 0) {
    return targetContent
  }
  const existingBody: string = targetContent.substring(headerEnd + 4, quoteEnd)
    .replace(/<br\s*\/?>/gi, '\n').replace(/\n{2,}/g, '\n').trim()
  const cleanedFull: string = cleanReferencedContent(fullContent)
  if (cleanedFull.length === 0) {
    return targetContent
  }
  if (existingBody === cleanedFull) {
    return targetContent
  }
  if (!cleanedFull.startsWith(existingBody)) {
    return targetContent
  }
  return targetContent.substring(0, headerEnd + 4) + '\n' + cleanedFull + targetContent.substring(quoteEnd)
}
