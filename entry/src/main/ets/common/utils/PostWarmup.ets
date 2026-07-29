import { taskpool } from '@kit.ArkTS'

import type { PostInfo } from '../../model/PostInfo'
import { preWarmBatchAwait } from '../../parser/bbcode/BBCodeCache'

/**
 * 帖子预热工具：把帖子集合中的 BBCode 文本收集后批量预热解析缓存。
 * 外迁自 ThreadPanel，纯函数化（不访问 appStore），由调用方决定是否包含签名。
 */

/**
 * 收集帖子集合中所有需要预热解析的 BBCode 文本。
 * 收集顺序：content + signature（若 includeSignatures） + 评论 content。
 *
 * @param posts - 帖子列表
 * @param includeSignatures - 是否收集签名
 * @returns 待预热的 BBCode 文本数组
 */
export function collectPostContents(posts: PostInfo[], includeSignatures: boolean): string[] {
  const contents: string[] = []
  for (let i: number = 0; i < posts.length; i++) {
    const p: PostInfo = posts[i]
    if (!p.isInBlackList) {
      if (p.content) contents.push(p.content)
      if (includeSignatures && p.signature) contents.push(p.signature)
    }
    const comments: PostInfo[] = p.comments
    for (let j: number = 0; j < comments.length; j++) {
      if (!comments[j].isInBlackList && comments[j].content) {
        contents.push(comments[j].content)
      }
    }
  }
  return contents
}

/**
 * 预热帖子集合的 BBCode 解析缓存。
 * 失败时静默降级（getCachedBBNodes 在缓存未命中时会同步解析）。
 *
 * @param posts - 帖子列表
 * @param includeSignatures - 是否收集签名
 * @param priority - taskpool 优先级
 */
export async function preWarmPosts(posts: PostInfo[], includeSignatures: boolean, priority?: taskpool.Priority): Promise<void> {
  const contents: string[] = collectPostContents(posts, includeSignatures)
  try {
    await preWarmBatchAwait(contents, priority)
  } catch (e) {
    // fallback: getCachedBBNodes will sync-parse on cache miss
  }
}
