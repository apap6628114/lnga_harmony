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

/** 引用区内的 pid 引用头正则。 */
const P_QUOTE_HEADER: RegExp = /\[pid=(\d+),(\d+),(\d+)\]/i

/**
 * 清理被引用楼层的原文为可注入正文。
 *
 * 规则（与官方 Reply to 补全语义一致）：
 * 1. 去掉被引用楼自身的 Reply to 头（[b]Reply to ...[/b]）；
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
  return raw
    .replace(/\[b\]Reply to \[pid=.*?\[\/pid\]\s*\[\/b\]/s, '')
    .replace(/\[quote\][\s\S]*?\[\/quote\]/g, '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/\n{2,}/g, '\n')
    .trim()
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
   * [/b] 从引用头位置起查找，避免前缀中的 [/b] 干扰正文边界。 */
  const prefix: string = targetContent.substring(0, headerMatch.index ?? 0)
  const closeBIdx: number = targetContent.indexOf('[/b]', headerMatch.index)
  const replyText: string = closeBIdx >= 0 ? targetContent.substring(closeBIdx + 4) : ''
  return `${prefix}[quote][pid=${headerMatch[1]},${headerMatch[2]},${headerMatch[3]}]Reply[/pid] [b]Post by [uid=${headerMatch[4]}]${headerMatch[5]}[/uid] (${headerMatch[6]}):[/b]\n${cleaned}[/quote]\n<br/><br/>${replyText}`
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
