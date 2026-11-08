/**
 * 递进树「单页局部合并」纯逻辑（无 UI / 无网络，可直接单测）。
 *
 * 用途：回复/编辑成功后**只抓一页**服务端数据，把这页楼层合并进当前全量楼层，
 * 由页面重建树并做增量通知。新楼层完全来自服务端：不估算楼号、不构造正文、
 * 不依赖提交响应的 `pid` 之外任何信息。
 *
 * 合并语义（与列表页 `ThreadPaginationManager.mergePage` 同源，但更严格）：
 * 1. 同 pid：以服务端对象替换；`guard` 命中且内容不一致时保留本地正文
 *    （read.php/CDN 缓存未失效时服务端仍返回编辑前的旧正文，列表页同一套保护）；
 * 2. 新 pid：追加到末尾（树的父子关系由 `buildThreadTree` 按引用重建，
 *    追加顺序不影响正确性）；
 * 3. **不删除、不移动、不改顺序**——树页的行 diff 只支持「新序列是旧序列的超序列」，
 *    任何删除/重排都会退化为整表 RELOAD 并让视口跳一下。
 */

import { PostInfo } from '../../model/PostInfo'

/** 一次单页合并的结果。 */
export class LocalMergeResult {
  /** 合并后的全量楼层（新数组，不修改入参数组本身） */
  posts: PostInfo[] = []

  /** 本次新增的楼层 pid（按服务端页内顺序） */
  addedPids: number[] = []

  /** 被服务端对象替换的楼层 pid（内容可能变化） */
  replacedPids: number[] = []

  /**
   * 目标楼层是否在本次合并里（新增或替换）。
   *
   * @param pid - 目标楼层 pid
   * @returns 命中时为 true
   */
  contains(pid: number): boolean {
    for (let i: number = 0; i < this.addedPids.length; i++) {
      if (this.addedPids[i] === pid) {
        return true
      }
    }
    for (let i: number = 0; i < this.replacedPids.length; i++) {
      if (this.replacedPids[i] === pid) {
        return true
      }
    }
    return false
  }
}

/**
 * 把一页服务端楼层合并进当前全量楼层。
 *
 * 幂等：同一页重复合并不会产生重复楼层（按 pid 去重，页内重复只取第一条）。
 *
 * @param current - 当前全量楼层
 * @param pagePosts - 该页服务端楼层
 * @param guardPid - 需要正文保护的楼层 pid（编辑场景；`0` 表示无）
 * @param guardContent - 刚提交的正文（已按 NGA content 约定把换行归一化为 `<br/>`）
 * @returns 合并结果（新数组，`current` 与 `pagePosts` 均不被修改）
 */
export function mergeTreePage(current: PostInfo[], pagePosts: PostInfo[],
  guardPid: number, guardContent: string): LocalMergeResult {
  const result: LocalMergeResult = new LocalMergeResult()
  const merged: PostInfo[] = []
  const indexByPid: Map<number, number> = new Map<number, number>()
  for (let i: number = 0; i < current.length; i++) {
    const post: PostInfo = current[i]
    if (indexByPid.has(post.pid)) {
      continue
    }
    indexByPid.set(post.pid, merged.length)
    merged.push(post)
  }
  const seen: Set<number> = new Set<number>()
  for (let i: number = 0; i < pagePosts.length; i++) {
    const source: PostInfo = pagePosts[i]
    if (seen.has(source.pid)) {
      continue
    }
    seen.add(source.pid)
    let fresh: PostInfo = source
    if (guardPid > 0 && source.pid === guardPid && source.content !== guardContent) {
      /**
       * 服务端返回的不是刚提交的正文：保留本地正文，不覆盖
       * （否则「编辑成功」会被 read.php/CDN 的旧缓存静默回退）。
       * 克隆后再改，保证调用方传入的服务端对象不被篡改。
       */
      fresh = clonePost(source)
      fresh.content = guardContent
    }
    const existingIndex: number | undefined = indexByPid.get(fresh.pid)
    if (existingIndex === undefined) {
      indexByPid.set(fresh.pid, merged.length)
      merged.push(fresh)
      result.addedPids.push(fresh.pid)
      continue
    }
    merged[existingIndex] = fresh
    result.replacedPids.push(fresh.pid)
  }
  result.posts = merged
  return result
}

/**
 * 浅拷贝一个楼层对象（用于正文保护时避免改写服务端返回对象）。
 *
 * @param source - 源对象
 * @returns 新对象（字段引用与源一致，仅 `content` 由调用方覆盖）
 */
function clonePost(source: PostInfo): PostInfo {
  const copy: PostInfo = new PostInfo()
  copy.tid = source.tid
  copy.pid = source.pid
  copy.uiRev = source.uiRev
  copy.lou = source.lou
  copy.authorid = source.authorid
  copy.author = source.author
  copy.authorKey = source.authorKey
  copy.subject = source.subject
  copy.content = source.content
  copy.vote = source.vote
  copy.postdate = source.postdate
  copy.postdatetimestamp = source.postdatetimestamp
  copy.level = source.level
  copy.yz = source.yz
  copy.avatar = source.avatar
  copy.signature = source.signature
  copy.attachs = source.attachs
  copy.comments = source.comments
  copy.hotReplies = source.hotReplies
  copy.fromClient = source.fromClient
  copy.from_client_model = source.from_client_model
  copy.isanonymous = source.isanonymous
  copy.alterinfo = source.alterinfo
  copy.score = source.score
  copy.score_2 = source.score_2
  copy.replyTo = source.replyTo
  copy.isInBlackList = source.isInBlackList
  copy.userNote = source.userNote
  copy.isMuted = source.isMuted
  copy.reputation = source.reputation
  copy.memberGroup = source.memberGroup
  copy.postCount = source.postCount
  copy.muteTime = source.muteTime
  return copy
}

/** 「补页结果能否合并」的判定结果。 */
export class MergePageDecision {
  /** 是否允许合并 */
  accept: boolean = false

  /** 合并使用的页号（`accept` 为 false 时为 0） */
  pageNo: number = 0

  /** 拒绝原因（日志/诊断用） */
  reason: string = ''
}

/**
 * 判定「补页结果」能否安全合并（页号 / 水位一致性）。
 *
 * 树页的 `allPosts` 必须是**按页连续的前缀**，所以补页只允许覆盖「已提交页 + 1」这一页：
 * - **回复**抓末页：末页页码只能是 `committedPages`（帖没涨页）或 `committedPages + 1`
 *   （刚好翻页）。跨更多页说明中间页从未加载，合并会留下页码空洞，后续
 *   `decideTargetState` 会把被跳过页的楼层误判成「不存在」；末页页码小于已加载页数
 *   则说明分页结构已变（删页 / 服务端回退成第 1 页），同样不可信；
 * - **编辑**抓指定页：服务端自报页码必须与请求页一致。`__PAGE` 缺失时
 *   `fillThreadResult` 会保留默认值 1，不校验就会把整页楼层写进错误的 `pageByPid`，
 *   之后每次编辑都会抓到错误的页。
 *
 * @param isEdit - 是否编辑（false 表示回复）
 * @param requestedPage - 请求页（回复为 `'e'`；编辑为页码数字串）
 * @param resolvedPage - 服务端自报页码（`ThreadResult.pagination.page`）
 * @param committedPages - 合并前已提交页数
 * @returns 判定结果
 */
export function resolveMergePage(isEdit: boolean, requestedPage: string, resolvedPage: number,
  committedPages: number): MergePageDecision {
  const decision: MergePageDecision = new MergePageDecision()
  if (resolvedPage <= 0) {
    decision.reason = '服务端未返回页码'
    return decision
  }
  if (isEdit) {
    const requested: number = parseInt(requestedPage, 10)
    if (!Number.isFinite(requested) || requested <= 0) {
      decision.reason = '请求页无效'
      return decision
    }
    if (resolvedPage !== requested) {
      decision.reason = '页号错位 ' + requestedPage + ' -> ' + String(resolvedPage)
      return decision
    }
    decision.accept = true
    decision.pageNo = resolvedPage
    return decision
  }
  if (resolvedPage < committedPages) {
    decision.reason = '末页页码小于已加载页数'
    return decision
  }
  if (resolvedPage > committedPages + 1) {
    decision.reason = '跨页缺口 ' + String(committedPages) + ' -> ' + String(resolvedPage)
    return decision
  }
  decision.accept = true
  decision.pageNo = resolvedPage
  return decision
}
