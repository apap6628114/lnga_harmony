import type { PostInfo } from '../../model/PostInfo'
import { buildReplyQuoteContent, fixTruncatedQuoteContent } from './QuoteInjectionCore'

/**
 * 引用注入装配层（楼层集合遍历）。
 *
 * 引用区处理核心（Reply to 注入 / 截断引用修复）为字符串级纯函数，
 * 已下沉至 TS 镜像真源 QuoteInjectionCore（Node 侧以真实样本回归），
 * 本文件仅负责 PostInfo 楼层集合的装配与原文查找回调。
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
    target.content = buildReplyQuoteContent(target.content,
      (pid: number): string | undefined => origByPid.get(pid))
  }
  /** 用已加载的完整原文修复服务端截断的引用正文。 */
  const fixTruncatedQuote = (target: PostInfo): void => {
    target.content = fixTruncatedQuoteContent(target.content,
      (pid: number): string | undefined => origByPid.get(pid))
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
