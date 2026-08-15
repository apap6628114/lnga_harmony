import type { PostInfo } from '../../model/PostInfo'

/**
 * 为快速回复和被截断的引用补全原楼层内容。
 *
 * NGA 的快速回复（Reply to）正文只携带被引用楼层的 pid 与作者信息，
 * 不含正文；服务端返回的引用正文也可能被截断。本工具在已加载的楼层
 * 集合中查找原文并注入/修复，保证引用楼层展示完整内容。
 *
 * 纯函数：不依赖组件状态，输入输出均为 PostInfo 数组，可安全独立测试。
 *
 * @param posts - 需要处理的页面帖子
 * @param currentPosts - 当前已加载窗口内的帖子（用于查找引用原文）
 * @param prevPosts - 替换前的帖子（用于查找跨页引用原文）
 */
export function injectQuoteContent(posts: PostInfo[], currentPosts: PostInfo[], prevPosts?: PostInfo[]): void {
  const origByPid: Map<number, string> = new Map()
  /** 收集楼层与贴条的原始正文。 */
  const collectToMap = (arr: PostInfo[]): void => {
    for (const p of arr) {
      origByPid.set(p.pid, p.content)
      if (p.comments) {
        for (const c of p.comments) {
          origByPid.set(c.pid, c.content)
        }
      }
    }
  }
  collectToMap(posts)
  collectToMap(currentPosts)
  if (prevPosts) {
    collectToMap(prevPosts)
  }
  /** 为快速回复格式注入被引用楼层的正文。 */
  const injectReplyQuote = (target: PostInfo): void => {
    if (target.content.startsWith('[quote]')) return
    const headerRegex: RegExp = /\[b\]Reply to \[pid=(\d+),(\d+),(\d+)\]Reply\[\/pid\] Post by \[uid=(\d+)\](.*?)\[\/uid\] \(([^)]+)\)/i
    const headerMatch: RegExpMatchArray | null = target.content.match(headerRegex)
    if (!headerMatch) return
    const refPid: number = parseInt(headerMatch[1], 10)
    const rawContent: string | undefined = origByPid.get(refPid)
    if (!rawContent) return
    let cleaned: string = rawContent
      .replace(/\[b\]Reply to \[pid=.*?\[\/pid\]\s*\[\/b\]/s, '')
      .replace(/\[pid=.*?Reply\[\/pid\]\s*\[b\]Post by.*?\(.*?\):\[\/b\]/s, '')
      .replace(/\[quote\]/g, '')
      .replace(/\[\/quote\]/g, '')
      .replace(/<br\s*\/?>/gi, '')
      .trim()
    if (cleaned.length === 0) return
    const closeBIdx: number = target.content.indexOf('[/b]')
    const replyText: string = closeBIdx >= 0 ? target.content.substring(closeBIdx + 4) : ''
    target.content = `[quote][pid=${headerMatch[1]},${headerMatch[2]},${headerMatch[3]}]Reply[/pid] [b]Post by [uid=${headerMatch[4]}]${headerMatch[5]}[/uid] (${headerMatch[6]}):[/b]\n${cleaned}[/quote]\n<br/><br/>${replyText}`
  }
  /** 用已加载的完整原文修复服务端截断的引用正文。 */
  const fixTruncatedQuote = (target: PostInfo): void => {
    if (!target.content.startsWith('[quote]')) return
    const pidInQuote: RegExpMatchArray | null = target.content.match(/\[pid=(\d+),(\d+),(\d+)\]/)
    if (!pidInQuote) return
    const refPid: number = parseInt(pidInQuote[1], 10)
    const fullContent: string | undefined = origByPid.get(refPid)
    if (!fullContent) return
    const afterQuote: number = target.content.indexOf('[quote]') + 7
    const headerEnd: number = target.content.indexOf('[/b]', afterQuote)
    const quoteEnd: number = target.content.indexOf('[/quote]', afterQuote)
    if (headerEnd < 0 || quoteEnd < 0) return
    const existingBody: string = target.content.substring(headerEnd + 4, quoteEnd)
      .replace(/<br\s*\/?>/gi, '').trim()
    let cleanedFull: string = fullContent
      .replace(/\[b\]Reply to \[pid=.*?\[\/pid\]\s*\[\/b\]/s, '')
      .replace(/\[pid=.*?Reply\[\/pid\]\s*\[b\]Post by.*?\(.*?\):\[\/b\]/s, '')
      .replace(/\[quote\]/g, '').replace(/\[\/quote\]/g, '')
      .replace(/<br\s*\/?>/gi, '')
      .trim()
    if (cleanedFull.length === 0) return
    if (existingBody === cleanedFull) return
    if (!cleanedFull.startsWith(existingBody)) return
    target.content = target.content.substring(0, headerEnd + 4) + '\n' + cleanedFull + target.content.substring(quoteEnd)
  }
  for (const p of posts) {
    injectReplyQuote(p)
    fixTruncatedQuote(p)
    if (p.comments) {
      for (const c of p.comments) {
        injectReplyQuote(c)
        fixTruncatedQuote(c)
      }
    }
  }
}
