/**
 * 帖子页（自然列表 `ThreadPanel` / 递进树 `ThreadTreePanel`）共用的**纯语义工具**。
 *
 * 两种阅读样式在数据源、分页/建树、滚动模型上是隔离的，但有一批「同一个问题的答案」
 * 各自实现了一遍：楼主身份判定、收藏菜单文案、离线来源判定、阅读进度来源白名单、
 * 标题栏可见标题、朗读元数据、帖子网页地址。复制两份的代价不是行数，而是**漂移**：
 * 只改一处时两种样式会对同一个帖子给出不同结论。既有的「与列表页同一口径」「与列表页
 * 同构」注释，正是靠人肉维持这种一致性的痕迹。
 *
 * 本文件只收纳**无状态、可被两种样式同时调用**的判定与文案。凡是需要读写组件状态、
 * 触发刷新或依赖 UIContext 的逻辑都不属于这里（那属于页面自身）。
 */

import { getActiveDomain } from '../../service/api/MiscApi'
import { FavoriteMembershipState } from '../../model/Favorite'
import { ThreadSource } from '../../store/RouterStore'
import type { PostInfo } from '../../model/PostInfo'
import type { TtsMediaMetadata } from '../media/TtsAvSessionController'

/**
 * 该稳定作者标识是否可用于身份比较。
 *
 * 空串（解析不出）与非正数字（匿名楼的页内局部合成号）都不可比：前者没有信息，
 * 后者逐页重排，拿它判定会既漏判楼主、又误判撞号的匿名用户。
 *
 * @param authorKey - 待判定的稳定作者标识（普通帖为 uid 数字串，匿名帖为 `#anony_` 编码名）
 * @returns 可用于比较时为 true
 */
export function isAuthorKeyUsable(authorKey: string): boolean {
  if (authorKey.length === 0) {
    return false
  }
  const numeric: number = Number(authorKey)
  return isNaN(numeric) || numeric > 0
}

/**
 * 当前楼层是否为主题作者（楼主）所发。
 *
 * 判据是稳定作者标识而不是 uid：匿名帖里 uid 是页内局部号（见 `PostInfo.authorKey`），
 * 只有 `#anony_` 编码名能跨页认出楼主的匿名回复。
 *
 * @param hasThreadAuthorKey - 是否已取得可比较的楼主标识
 * @param threadAuthorKey - 楼主稳定作者标识
 * @param post - 待判定楼层
 * @returns 是楼主所发时为 true
 */
export function isTopicAuthorPost(hasThreadAuthorKey: boolean, threadAuthorKey: string,
  post: PostInfo): boolean {
  return hasThreadAuthorKey && post.authorKey === threadAuthorKey
}

/**
 * 在楼层集合里取主楼（lou=0）作者昵称。
 *
 * 添加跟踪时带上，避免跟踪列表在首次检查回填前显示「未知作者」；主楼不在当前集合
 * （只看楼主以外的跨页/跨树视图）时返回空串，由检查响应里的 `__T.author` 回填。
 *
 * @param posts - 楼层集合（列表页是分页窗口，树页是全帖）
 * @returns 楼主昵称；未知时返回空串
 */
export function findTopicAuthorName(posts: PostInfo[]): string {
  for (let index: number = 0; index < posts.length; index++) {
    if (posts[index].lou === 0) {
      return posts[index].author
    }
  }
  return ''
}

/**
 * 返回当前可信收藏状态对应的菜单文案。
 *
 * @param state - 主题收藏关系状态
 * @returns 收藏操作菜单文案
 */
export function favoriteMenuLabel(state: FavoriteMembershipState): string {
  if (state === FavoriteMembershipState.FAVORED) {
    return '管理收藏'
  }
  if (state === FavoriteMembershipState.NOT_FAVORED) {
    return '收藏到…'
  }
  return '收藏夹…'
}

/**
 * 是否由「保存的帖子」离线存档来源打开。
 *
 * 离线存档模式下隐藏与在线收藏/保存冲突的功能入口，且不写阅读进度/浏览历史、
 * 不推进跟踪已读、不补页。
 *
 * @param threadSource - 打开帖子的路由来源（ThreadSource 枚举值）
 * @returns 是否离线存档来源
 */
export function isSavedThreadSource(threadSource: string): boolean {
  return threadSource === ThreadSource.SAVED
}

/**
 * 该路由来源是否允许恢复阅读进度。
 *
 * 仅「继续阅读」语义的来源：主题列表、浏览历史、未标注的默认入口。链接/搜索/通知等
 * 明确指向某楼层或某页的来源不恢复——那会覆盖用户当下的真实意图。
 *
 * @param threadSource - 打开帖子的路由来源（ThreadSource 枚举值）
 * @returns 来源是否允许恢复
 */
export function canResumeReadingProgress(threadSource: string): boolean {
  return threadSource === ThreadSource.DEFAULT ||
    threadSource === ThreadSource.TOPIC_LIST ||
    threadSource === ThreadSource.BROWSE_HISTORY
}

/**
 * 标题栏可见标题。
 *
 * 两条规则按优先级叠加：楼主被屏蔽时只显示占位文案（不泄露标题），离线存档在前加
 * 前缀提醒（替代悬浮提示，不遮挡内容）。
 *
 * @param subject - 主题标题
 * @param authorBlocked - 楼主是否在屏蔽名单中
 * @param savedSource - 是否离线存档来源
 * @returns 可显示标题
 */
export function visibleThreadSubject(subject: string, authorBlocked: boolean,
  savedSource: boolean): string {
  // 说明：黑名单只存真实 uid，匿名帖的主题作者没有真实 uid（`threadAuthorId` 是页内
  // 局部号），故匿名楼主无法被拉黑——这是"不知道是谁"的必然结果，不是漏判。
  if (authorBlocked) {
    return '该用户已被屏蔽'
  }
  if (savedSource) {
    return '[离线] ' + subject
  }
  return subject
}

/**
 * 楼层朗读的系统播控元数据。
 *
 * @param tid - 主题 ID
 * @param subject - 主题标题（为空时用通用标题）
 * @param post - 楼层
 * @returns 播控元数据
 */
export function buildReadAloudMetadata(tid: string, subject: string, post: PostInfo): TtsMediaMetadata {
  const floorName: string = post.lou === 0 ? '楼主' : '第' + post.lou.toString() + '楼'
  return {
    assetId: 'thread-' + tid + '-post-' + post.pid.toString(),
    title: subject.trim().length > 0 ? subject : '帖子朗读',
    artist: post.author,
    album: floorName
  }
}

/**
 * 帖子的网页版地址（当前生效域名 + read.php）。
 *
 * @param tid - 主题 ID
 * @returns 网页版 URL
 */
export function threadWebUrl(tid: string): string {
  return getActiveDomain() + '/read.php?tid=' + tid
}
