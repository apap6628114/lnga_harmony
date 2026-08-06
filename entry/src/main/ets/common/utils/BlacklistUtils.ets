import type { BlacklistEntry } from '../../model/SocialEntries'
import type { PostInfo } from '../../model/PostInfo'

/**
 * 规范化黑名单 UID。
 *
 * 仅接受正整数字符串，并移除前导零，确保与服务端作者 UID 的字符串表示一致。
 *
 * @param rawUserId - 待规范化的原始 UID
 * @returns 规范化 UID；格式非法时返回 null
 */
export function normalizeBlacklistUserId(rawUserId: string): string | null {
  const trimmed: string = rawUserId.trim()
  if (!/^\d+$/.test(trimmed)) {
    return null
  }
  const normalized: string = trimmed.replace(/^0+/, '')
  return normalized.length > 0 ? normalized : null
}

/**
 * 规范化并按 UID 去重黑名单持久化条目。
 *
 * @param entries - 原始黑名单条目
 * @param excludedUserId - 不允许出现在结果中的 UID，通常为当前登录用户
 * @returns 规范化后的黑名单条目
 */
export function normalizeBlacklistEntries(entries: BlacklistEntry[],
  excludedUserId: string = ''): BlacklistEntry[] {
  const result: BlacklistEntry[] = []
  const seenUserIds: Set<string> = new Set()
  const normalizedExcludedUserId: string | null = normalizeBlacklistUserId(excludedUserId)
  for (let i: number = 0; i < entries.length; i++) {
    const normalizedUserId: string | null = normalizeBlacklistUserId(entries[i].userId)
    if (normalizedUserId === null || normalizedUserId === normalizedExcludedUserId ||
      seenUserIds.has(normalizedUserId)) {
      continue
    }
    const normalizedEntry: BlacklistEntry = {
      userId: normalizedUserId,
      nickName: entries[i].nickName.trim() || `User${normalizedUserId}`,
    }
    result.push(normalizedEntry)
    seenUserIds.add(normalizedUserId)
  }
  return result
}

/**
 * 判断两个黑名单条目列表是否完全一致。
 *
 * @param left - 左侧列表
 * @param right - 右侧列表
 * @returns 是否按顺序完全一致
 */
export function areBlacklistEntriesEqual(left: BlacklistEntry[], right: BlacklistEntry[]): boolean {
  if (left.length !== right.length) {
    return false
  }
  for (let i: number = 0; i < left.length; i++) {
    if (left[i].userId !== right[i].userId || left[i].nickName !== right[i].nickName) {
      return false
    }
  }
  return true
}

/**
 * 递归刷新帖子及其楼中楼评论、热点回复的黑名单标记。
 *
 * 楼层本身仍保留在列表中，由渲染层根据标记遮蔽正文；楼中楼评论与热点回复由对应组件过滤。
 *
 * @param posts - 待刷新的帖子集合
 * @param blacklistIds - 当前黑名单 UID 集合
 */
export function applyBlacklistStateToPosts(posts: PostInfo[], blacklistIds: Set<string>): void {
  for (let i: number = 0; i < posts.length; i++) {
    const post: PostInfo = posts[i]
    post.isInBlackList = blacklistIds.has(String(post.authorid))
    applyBlacklistStateToPosts(post.comments, blacklistIds)
    applyBlacklistStateToPosts(post.hotReplies, blacklistIds)
  }
}
