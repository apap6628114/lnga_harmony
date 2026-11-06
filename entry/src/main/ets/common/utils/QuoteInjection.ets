import type { PostInfo } from '../../model/PostInfo'
import {
  buildReplyQuoteContent,
  fixTruncatedQuoteContent,
  stripCommentReplyHeader as stripCommentReplyHeaderCore
} from './QuoteInjectionCore'

/**
 * 剥离楼中楼评论开头的 Reply to 头（评论气泡不重复显示回复头）。
 *
 * 纯字符串逻辑在镜像真源 `QuoteInjectionCore.stripCommentReplyHeader`（Node 侧有回归）：
 * - 边界按「作者段 + 日期/楼号括号」定位（不是 `[/b]`），标准/粘连形态都只去头、保留正文；
 * - **保守剥离**：剥离后没有可见正文（只剩空白/`<br/>`/`&nbsp;`）时返回原文，
 *   整条评论只有回复头时不至于留下空气泡；调用方据此保留 `POST_BY` 节点
 *   （见 `PostComments.commentNodes`）。
 *
 * @param content - 评论原始正文
 * @returns 用于展示的评论正文；只有回复头时返回原文
 */
export function stripCommentReplyHeader(content: string): string {
  return stripCommentReplyHeaderCore(content)
}

/**
 * 引用注入装配层（楼层集合遍历）。
 *
 * 引用区处理核心（Reply to 注入 / 截断引用修复）为字符串级纯函数，
 * 已下沉至 TS 镜像真源 QuoteInjectionCore（Node 侧以真实样本回归），
 * 本文件仅负责 PostInfo 楼层集合的装配与原文查找回调。
 *
 * **只处理楼层，不处理 `comments`**：评论气泡始终过滤 `[quote]` 块（`PostComments`），
 * 把评论的 Reply-to 头注入成 `[quote]` 只会掩盖回复头文字、让「只有回复头」的评论
 * 变成空气泡；评论的回复头由 `stripCommentReplyHeader` 负责展示或不展示。
 *
 * @param posts - 需要处理的页面帖子
 * @param currentPosts - 当前已加载窗口内的帖子（用于查找引用原文）
 * @param prevPosts - 替换前的帖子（用于查找跨页引用原文）
 */
export function injectQuoteContent(posts: PostInfo[], currentPosts: PostInfo[], prevPosts?: PostInfo[]): void {
  const origByPid: Map<number, string> = new Map()
  /** 收集楼层与贴条的原始正文（贴条 pid 也可能被楼层引用）。 */
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
  }
}
