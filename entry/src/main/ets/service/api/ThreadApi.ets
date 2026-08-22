/**
 * NGA 帖子 API - 帖子详情、pid 定位、主题分类（读取域）
 * 帖子详情统一使用官方 APP HTML 响应，解析后转换为客户端内部帖子数据。
 *
 * 官方 APP 使用 POST form + 公共签名参数（app_id/access_uid/access_token/t/sign/
 * __output/__inchst），帖子内容使用 __output=17。服务端返回
 * {code,htmlBaseUrl,htmlTitle,html,msg,template} 包装，html 是完整帖子页面；
 * 本客户端提取 html 后交给 HTML 解析器，再复用统一的帖子解析与 BBCode 渲染链。
 * 支持 page=e（末页）、pid 定位（单帖+贴条）、authorid 只看楼主。
 * 发帖、回帖、评论、附件上传等写入操作见 ThreadWriteApi。
 */

import { ngaClient } from '../NgaClient';
import { appStore } from '../../store/AppStore';
import { parseThreadData } from '../../parser/ThreadParser';
import { parseNgaError } from '../../parser/ErrorParser';
import { parseFromClient } from '../../parser/ClientParser';
import { isUserMuted } from '../../parser/MuteParser';
import { resolveAttachUrl } from '../../parser/_shared/AttachUrl';
import { parseHtmlTask } from '../../parser/task/HtmlParseTask';
import { withTimeout } from '../../common/utils/TimeoutUtils';
import { taskpool } from '@kit.ArkTS';
import type { ThreadData, ThreadRowInfo, Attachment, ThreadInfo } from '../../model/Thread';
import { PostInfo, PostAttachInfo } from '../../model/PostInfo';
import { ThreadResult, ThreadPaging, TopicCategoriesResult } from '../../model/ThreadResult';
import { Logger, DOMAIN_SERVICE, formatError } from '../../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'ThreadApi')

// ============== 帖子详情 ==============

/**
 * 帖子 HTML 取数结果：HTML 解析结果与请求或解析错误。
 */
export interface ThreadRawResult {
  /** HTML 解析后与内部帖子解析器兼容的原始数据；请求或解析失败时为 null。 */
  raw: Record<string, Object> | null
  /** HTML 请求或解析失败信息；成功时为空串。 */
  error: string
}

/**
 * NGA Thread HTML 请求的固定入口与参数。
 */
export interface ThreadHtmlRequest {
  /** 请求路径。 */
  path: string
  /** 帖子详情业务参数。 */
  params: Record<string, string>
  /** 参与公共签名的参数串。 */
  signParams: string
  /** NGA 输出模式。 */
  output: string
}

/**
 * 构造官方 APP 的 Thread HTML 请求。
 *
 * @param tid - 主题 ID
 * @param pid - 楼层 ID
 * @param authorid - 只看某作者的楼层
 * @param page - 页码，e 表示末页
 * @returns 固定使用 read.php 与 __output=17 的请求描述
 */
export function buildThreadHtmlRequest(tid: string, pid: string, authorid: string,
  page: string): ThreadHtmlRequest {
  return {
    path: '/read.php',
    params: {
      'tid': tid,
      'pid': pid,
      'topid': '',
      'authorid': authorid,
      'opt': '',
      'page': page || '1',
      '__localres': '1',
    },
    signParams: '',
    output: '17',
  }
}

/**
 * 从官方 APP read.php 的 __output=17 响应中提取帖子 HTML。
 *
 * 官方客户端的 Article 模型把 code=521、template=read 视为成功，HTML
 * 位于顶层 html 字段；这里不依赖 code 的成功判断，只接受非空 html，兼容
 * 服务端在不同错误场景下省略 code 或 template 的响应差异。
 *
 * @param response - ngaClient 解析后的 APP 响应
 * @returns 完整帖子 HTML
 * @throws 响应缺少可解析的 html 字段时抛出错误
 */
export function extractAppArticleHtml(response: object): string {
  const responseObj: Record<string, Object> = response as Record<string, Object>;
  const htmlValue: Object | undefined = responseObj['html'];
  if (typeof htmlValue === 'string' && htmlValue.trim().length > 0) {
    return htmlValue;
  }
  const code: string = String(responseObj['code'] ?? '');
  const message: string = String(responseObj['msg'] ?? '');
  if (message.length > 0) {
    throw new Error(`APP read.php HTML 接口失败${code ? `（${code}）` : ''}：${message}`);
  }
  throw new Error('APP read.php HTML 接口未返回 html');
}

/**
 * 通过官方 APP read.php __output=17 拉取并解析帖子 HTML。
 *
 * @param uid - 当前登录用户 ID
 * @param cid - 当前登录会话令牌
 * @param tid - 主题 ID
 * @param pid - 楼层 ID
 * @param authorid - 只看某作者的楼层
 * @param page - 页码，e 表示末页
 * @returns 与帖子解析器兼容的原始帖子对象
 */
async function fetchAppArticleHtmlRaw(uid: string, cid: string, tid: string,
  pid: string, authorid: string, page: string): Promise<Record<string, Object>> {
  const request: ThreadHtmlRequest = buildThreadHtmlRequest(tid, pid, authorid, page);
  const response: Record<string, Object> = await ngaClient.postSignedPath(request.path, request.params,
    { uid: uid, cid: cid }, request.signParams, request.output) as Record<string, Object>;
  const html: string = extractAppArticleHtml(response);
  const parsed: Object = await taskpool.execute(parseHtmlTask, html);
  const parsedObj: Record<string, Object> = parsed as Record<string, Object>;
  const parsedData: Record<string, Object> | undefined = parsedObj['data'] as Record<string, Object> | undefined;
  if (!parsedData || parsedData['__R'] === undefined) {
    throw new Error('APP read.php HTML 解析结果缺少帖子楼层');
  }
  return parsedObj;
}

/**
 * 判断 HTML 解析结果是否包含至少一个可作为帖子楼层的原始行。
 *
 * 该判断基于关键词过滤前的原始数据，避免所有楼层命中过滤词时被误判为
 * HTML 请求或解析失败。
 *
 * @param raw - HTML 解析后的同形状原始帖子数据
 * @returns 是否存在有效原始楼层
 */
export function hasRawThreadRows(raw: Record<string, Object>): boolean {
  const dataObj: Record<string, Object> | undefined = raw['data'] as Record<string, Object> | undefined;
  const rawRows: Record<string, Object> | undefined = dataObj?.['__R'] as Record<string, Object> | undefined;
  if (!rawRows) {
    return false;
  }
  const keys: string[] = Object.keys(rawRows);
  for (let i = 0; i < keys.length; i++) {
    const row: Record<string, Object> | undefined = rawRows[keys[i]] as Record<string, Object> | undefined;
    if (!row || row['pid'] === undefined || row['pid'] === null) {
      continue;
    }
    if (row['comment_to_id'] !== undefined && row['comment_to_id'] !== null
      && row['content'] === undefined) {
      continue;
    }
    return true;
  }
  return false;
}

/**
 * 取一页原始数据中页末楼层的 pid。
 *
 * 与 parseThreadData 的 rowList 末尾语义一致：楼层顺序即 Object.keys 顺序，
 * 跳过缺失 pid 的行与贴条行（comment_to_id 存在且无 content，不占楼层）。
 *
 * @param raw - 同形状原始数据
 * @returns 页末楼层 pid；无有效楼层时返回 -1
 */
function lastPidOfPage(raw: Record<string, Object>): number {
  const dataObj = raw['data'] as Record<string, Object> | undefined;
  const rows = dataObj?.['__R'] as Record<string, Object> | undefined;
  if (!rows) {
    return -1;
  }
  const keys: string[] = Object.keys(rows);
  for (let i = keys.length - 1; i >= 0; i--) {
    const row = rows[keys[i]] as Record<string, Object>;
    if (!row) {
      continue;
    }
    if (row['pid'] === undefined || row['pid'] === null) {
      continue;
    }
    if (row['comment_to_id'] !== undefined && row['comment_to_id'] !== null
      && row['content'] === undefined) {
      continue;
    }
    return Number(row['pid']);
  }
  return -1;
}

/**
 * HTML-only 取数原语：使用官方 APP __output=17 HTML，再复用 HTML 解析器返回
 * 内部帖子解析器需要的同形状原始对象。
 *
 * 这是 getThread（渲染整页）与 locatePidPage（仅取 pid 序列）共享的底层取数：
 * 不解析、不过滤、不触碰渲染状态。ThreadPanel、pid 定位和离线保存均共享此原语。
 * 本函数保证不抛异常：HTML 请求或解析失败时返回 raw=null。
 *
 * @param token - 会话令牌
 * @param tid - 主题 ID（可空）
 * @param pid - 楼层 pid（可空）
 * @param authorid - 只看楼主用户 ID（可空）
 * @param page - 页码（'e' 表示末页）
 * @returns 取数结果
 */
export async function fetchThreadRaw(token: string, tid: string, pid: string,
  authorid: string, page: string): Promise<ThreadRawResult> {
  const session = appStore.getSession(token);
  if (!session) {
    return { raw: null, error: '未登录' };
  }

  try {
    const rawObj: Record<string, Object> = await fetchAppArticleHtmlRaw(session.uid, session.cid,
      tid || '', pid, authorid, page);
    return { raw: rawObj, error: '' };
  } catch (e) {
    const error: string = (e as Error).message ?? 'APP HTML 请求或解析异常';
    logger.error('[NGA][REQ] read.php HTML 请求或解析失败: %{public}s', error);
    return { raw: null, error: error };
  }
}

/**
 * 获取帖子详情（官方 APP HTML 解析）。
 *
 * HTML 取数由 fetchThreadRaw 完成，本函数负责解析（fillThreadResult）与过滤，
 * 是 ThreadPanel 渲染整页的唯一取数入口。
 */
export async function getThread(token: string, tid: string, pid: string,
  authorid: string, page: string,
  blacklist: Set<string> = new Set(),
  keywords: string[] = [],
  noteMap: Record<string, string> = {}): Promise<ThreadResult> {
  const result = new ThreadResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    if (!tid && !pid) {
      result.error = '缺少 tid 或 pid';
      return result;
    }

    const fetched: ThreadRawResult = await fetchThreadRaw(token, tid, pid, authorid, page);
    if (!fetched.raw) {
      result.error = fetched.error || '无法加载该帖子';
      return result;
    }
    fillThreadResult(fetched.raw, result, blacklist, keywords, noteMap);
    if (result.posts.length === 0 && !hasRawThreadRows(fetched.raw)) {
      result.ok = false;
      result.error = result.error || 'HTML 解析结果没有帖子楼层';
    }
  } catch (e) {
    const htmlErr: string = (e as Error).message ?? 'HTML 解析异常';
    result.error = htmlErr;
  }
  return result;
}

/**
 * 二分查找目标楼层 pid 所在页码。
 *
 * 纯数据行为：经由 HTML-only 取数原语 fetchThreadRaw，只读原始 __R 的页末 pid 与 __ROWS
 * 分页信息，不解析、不过滤、不依赖渲染状态。利用 NGA 楼层 pid 在主题内
 * 随楼号严格递增的性质（删除楼层只产生 pid 空洞、不破坏单调性）二分定位。
 * 总页数自包含获取：先请求末页（page=e），以 __ROWS/__R__ROWS_PAGE 按
 * parseThreadData 同款公式换算真实总页数，同时以主题末楼 pid 排除「目标 pid
 * 超出主题末楼」（楼层不存在或已删除）的情形；主题内部的删除空洞无法在此
 * 拦截，由 ThreadPanel 页内未命中后的单帖兜底处理。
 *
 * 本方法保证不抛异常：任一页请求失败/超时/数据异常均返回 -1；进度回调的
 * 异常被隔离记录，不影响查找结果。
 *
 * 进度回调：末页请求完成后即可确定总步数（1 + ⌈log₂总页数⌉，二分步数上界），
 * 随后每完成一步回调一次，供 UI 展示「正在定位楼层… n/N」的可预期进度。
 *
 * 适用场景：入口仅携带 pid、没有页码线索（用户回帖列表、外部 pid 链接）时，
 * 在打开 Thread 之前先调用本方法换算页码，再以正确页码打开并定位。
 *
 * @param token - 会话令牌
 * @param tid - 主题 ID
 * @param targetPid - 目标楼层 pid
 * @param onProgress - 进度回调（done 已完成步数，total 总步数；total<=1 表示步数未知）
 * @returns 目标楼层所在页码；请求失败、楼层已删除或数据异常时返回 -1
 */
export async function locatePidPage(token: string, tid: string, targetPid: number,
  onProgress?: (done: number, total: number) => void): Promise<number> {
  const session = appStore.getSession(token);
  if (!session) {
    return -1;
  }
  try {
    // 先请求末页：拿真实总页数与主题末楼 pid。每次请求带 15s 超时，失败即整体 -1。
    const lastFetch: ThreadRawResult = await withTimeout<ThreadRawResult>(
      fetchThreadRaw(token, tid, '', '', 'e'), 15000);
    if (!lastFetch.raw) {
      return -1;
    }
    const lastData = lastFetch.raw['data'] as Record<string, Object> | undefined;
    const totalRows: number = Number(lastData?.['__ROWS'] ?? 0);
    const rowsPerPage: number = Math.max(20, Number(lastData?.['__R__ROWS_PAGE'] ?? 0));
    let totalPages: number = 1;
    if (totalRows > 0) {
      totalPages = Math.ceil(totalRows / rowsPerPage);
    } else {
      // __ROWS 缺失（异常响应）时按本页行数估算，与 parseThreadData 的降级口径一致
      const lastRows = lastData?.['__R'] as Record<string, Object> | undefined;
      const rowCount: number = lastRows ? Object.keys(lastRows).length : 0;
      if (rowCount > 0) {
        totalPages = Math.ceil(rowCount / rowsPerPage);
      }
    }
    const lastPidOfThread: number = lastPidOfPage(lastFetch.raw);
    if (lastPidOfThread > 0 && targetPid > lastPidOfThread) {
      // 目标 pid 超出主题末楼：楼层不存在或已删除
      return -1;
    }
    // 总步数 = 末页 1 步 + 二分步数上界 ⌈log₂(totalPages)⌉，此后每步可精确上报
    const totalSteps: number = 1 + Math.ceil(Math.log2(Math.max(1, totalPages)))
    let doneSteps: number = 1
    if (onProgress) {
      try {
        onProgress(doneSteps, totalSteps)
      } catch (e) {
        logger.warn('locatePidPage 进度回调异常: %{public}s', formatError(e))
      }
    }
    let lo: number = 1;
    let hi: number = Math.max(1, totalPages);
    // 「找第一个满足 lastPid >= target 的页」必须用下取整 mid：
    // 上取整时若判定走向 hi = mid 且 mid 恰等于 hi（如 lo=1,hi=2 → mid=2），
    // hi 不收缩、lo<hi 恒成立，会死循环重复请求同一页。
    while (lo < hi) {
      const mid: number = Math.floor((lo + hi) / 2);
      doneSteps++
      if (onProgress) {
        try {
          onProgress(doneSteps, totalSteps)
        } catch (e) {
          logger.warn('locatePidPage 进度回调异常: %{public}s', formatError(e))
        }
      }
      const fetched: ThreadRawResult = await withTimeout<ThreadRawResult>(
        fetchThreadRaw(token, tid, '', '', String(mid)), 15000);
      if (!fetched.raw) {
        return -1;
      }
      const lastPid: number = lastPidOfPage(fetched.raw);
      if (lastPid <= 0) {
        // 防御分支：页内无有效楼层 pid（正常数据不可达）
        return -1;
      }
      if (lastPid < targetPid) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  } catch (e) {
    logger.warn('locatePidPage 失败 tid=%{public}s targetPid=%{public}d error=%{public}s',
      tid, targetPid, formatError(e));
    return -1;
  }
}

/**
 * 从 HTML 解析后的 NGA 原始数据填充 ThreadResult
 *
 * @param raw - 原始响应对象
 * @param result - 输出结果
 * @param blacklist - 黑名单 UID
 * @param keywords - 标题屏蔽关键词
 * @param noteMap - 用户备注表
 */
export function fillThreadResult(raw: Record<string, Object>, result: ThreadResult,
  blacklist: Set<string>, keywords: string[] = [],
  noteMap: Record<string, string> = {}): void {
  const data: ThreadData = parseThreadData(raw, blacklist, keywords, noteMap);
  const dataObj: Record<string, Object> | undefined = raw?.['data'] as Record<string, Object> | undefined;

  if (dataObj?.['__PAGE']) {
    data.pagination.page = Number(dataObj['__PAGE']);
  }

  const __U: Record<string, Object> = (dataObj?.['__U'] ?? {}) as Record<string, Object>;
  const forumInfo: Record<string, string> = data.__F as Record<string, string>;
  result.forumName = forumInfo?.['name'] ?? '';

  const groupMap: Map<number, string> = new Map();
  const uKeys: string[] = Object.keys(__U);
  for (let uk = 0; uk < uKeys.length; uk++) {
    const uEntry = __U[uKeys[uk]] as Record<string, Object> | undefined;
    if (uEntry && uEntry['__GROUPS'] && typeof uEntry['__GROUPS'] === 'object') {
      const groups = uEntry['__GROUPS'] as Record<string, Object>;
      const gKeys = Object.keys(groups);
      for (let gi = 0; gi < gKeys.length; gi++) {
        const gEntry = groups[gKeys[gi]] as Record<string, Object>;
        if (gEntry && gEntry['0'] && gEntry['2'] !== undefined) {
          groupMap.set(Number(gEntry['2']), String(gEntry['0']));
        }
      }
      break;
    }
  }

  const mapRowToPost = (row: ThreadRowInfo): PostInfo => {
    const userInfo: Record<string, Object> | undefined = __U[String(row.authorid)] as Record<string, Object> | undefined;
    const post: PostInfo = new PostInfo();
    post.tid = row.tid;
    post.pid = row.pid;
    post.lou = row.lou;
    post.authorid = row.authorid;
    const rawAuthor: string = String(userInfo?.['username'] ?? row.author ?? '');
    post.author = rawAuthor;
    post.isanonymous = row.isanonymous || (rawAuthor.startsWith('#anony_') && rawAuthor.length === 39);
    post.subject = row.subject;
    post.content = row.content;
    post.vote = row.vote;
    post.postdate = row.postdate;
    post.postdatetimestamp = row.postdatetimestamp;
    const memberid: number = Number(userInfo?.['memberid'] ?? 0);
    const rvrc: number = Number(userInfo?.['rvrc'] ?? 0);
    post.level = String(Math.max(0, rvrc));
    post.yz = String(userInfo?.['yz'] ?? row.yz ?? '');
    post.avatar = String(userInfo?.['avatar'] ?? row.js_escap_avatar ?? '');
    post.signature = String(userInfo?.['signature'] ?? row.signature ?? '');
    post.attachs = row.attachs.map((a: Attachment): PostAttachInfo => {
      const info: PostAttachInfo = new PostAttachInfo();
      info.aid = a.aid;
      info.attachurl = resolveAttachUrl(a.attachurl);
      info.url_utf8_org_name = a.url_utf8_org_name;
      info.name = a.name;
      info.ext = a.ext;
      info.type = a.type;
      info.size = a.size;
      info.thumb = a.thumb;
      info.thumbUrl = info.attachurl;
      info.dscp = a.dscp;
      info.subid = a.subid;
      return info;
    });
    post.comments = row.comments.map(mapRowToPost);
    post.hotReplies = row.hotReplies.map(mapRowToPost);
    post.fromClient = parseFromClient(row.from_client);
    post.from_client_model = row.from_client_model;
    post.alterinfo = row.alterinfo;
    post.score = row.score;
    post.score_2 = row.score_2;
    post.isInBlackList = row.isInBlackList;
    post.userNote = row.userNote;
    // 禁言判定（与官方网页数据同源）：
    // 1. __U 用户表 mute_time（禁言到期时间戳）；
    // 2. __U 用户表 buffs（105 = 禁言 buff）。
    post.muteTime = String(userInfo?.['mute_time'] ?? row.muteTime ?? '');
    post.isMuted = isUserMuted(userInfo, row.muteTime);
    post.reputation = Number(userInfo?.['reputation'] ?? row.reputation ?? 0);
    post.memberGroup = groupMap.get(memberid) ?? String(row.memberGroup ?? '');
    post.postCount = String(userInfo?.['postnum'] ?? row.postCount ?? '');
    return post;
  };

  result.posts = data.rowList.map(mapRowToPost);

  if (dataObj?.['__T']) {
    const __T: Record<string, Object> = dataObj['__T'] as Record<string, Object>;
    let rawT: Record<string, Object> | null = null;
    if (__T['tid']) {
      rawT = __T;
    } else {
      const tKeys: string[] = Object.keys(__T);
      if (tKeys.length > 0) {
        const first: Record<string, Object> | undefined = __T[tKeys[0]] as Record<string, Object> | undefined;
        if (first && typeof first === 'object' && first['tid']) {
          rawT = first;
        }
      }
    }
    if (rawT) {
      const rawAuthorId: number = Number(rawT['authorid'] ?? 0);
      const firstPostAuthorId: number | undefined = data.rowList.find(r => r.lou === 0)?.authorid;
      const finalAuthorId: number = rawAuthorId > 0 ? rawAuthorId : (firstPostAuthorId ?? rawAuthorId);

      const info: ThreadInfo = {
        tid: Number(rawT['tid'] ?? 0),
        fid: Number(rawT['fid'] ?? 0),
        subject: String(rawT['subject'] ?? ''),
        replies: Number(rawT['replies'] ?? 0),
        authorid: finalAuthorId,
        author: String(rawT['author'] ?? ''),
        postdate: Number(rawT['postdate'] ?? 0),
        lastpost: Number(rawT['lastpost'] ?? 0),
        lastposter: String(rawT['lastposter'] ?? ''),
        locked: Number(rawT['locked'] ?? 0) !== 0,
        recommend: Number(rawT['recommend'] ?? 0),
        digest: Number(rawT['digest'] ?? 0),
        type: Number(rawT['type'] ?? 0),
        topic_misc: String(rawT['topic_misc'] ?? ''),
      };
      result.threadInfo = info;
      // 防御性兜底：主题级投票 __T.post_misc_var.vote 回填到主楼。
      // 保留主题级 vote 回填，防止 HTML 解析结果的 __R[0] 缺 vote 而 __T 有值。
      const pmv: Record<string, Object> | undefined = rawT['post_misc_var'] as Record<string, Object> | undefined;
      if (pmv) {
        const topicVote: string = String(pmv['vote'] ?? '');
        if (topicVote.length > 0) {
          for (let pi: number = 0; pi < result.posts.length; pi++) {
            if (result.posts[pi].lou === 0 && result.posts[pi].vote.length === 0) {
              result.posts[pi].vote = topicVote;
              break;
            }
          }
        }
      }
    }
  }

  result.pagination = new ThreadPaging();
  result.pagination.page = data.pagination.page;
  result.pagination.totalPages = data.pagination.totalPages;
  result.pagination.totalRows = data.pagination.totalRows;

  result.ok = true;
}

// ============== 主题分类 ==============

/**
 * 获取版块的发主题分类标签（对应官方客户端 TopicPostModel.loadTopicCategory）。
 *
 * @param token - 会话令牌
 * @param fid - 版块 ID
 * @returns 分类名列表；无分类时返回空列表
 */
export async function getTopicCategories(token: string, fid: number): Promise<TopicCategoriesResult> {
  const result = new TopicCategoriesResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    const params: Record<string, string> = {
      '__lib': 'topic_key',
      '__act': 'get',
      'fid': String(fid),
      '__output': '8',
    };
    const raw = await ngaClient.get('/nuke.php', params, { uid: session.uid, cid: session.cid }) as Record<string, Object>;
    const err = parseNgaError(raw);
    if (err) {
      result.error = err;
      return result;
    }
    // 响应结构: data["0"] 为有序分类表，每项形如 {"0": "分类名"}
    const dataObj = raw?.['data'] as Record<string, Object> | undefined;
    const table = dataObj?.['0'] as Record<string, Object> | undefined;
    if (table) {
      const keys: string[] = Object.keys(table);
      for (let i = 0; i < keys.length; i++) {
        const entry: Object | undefined = table[keys[i]];
        if (entry === undefined) {
          continue;
        }
        // 兼容条目为原始字符串或 {"0": "分类名"} 对象两种形状
        const name: string = typeof entry === 'string' ? String(entry)
          : String((entry as Record<string, Object>)['0'] ?? '');
        if (name.length > 0) {
          result.categories.push(name);
        }
      }
    }
    result.ok = true;
  } catch (e) {
    logger.warn('获取主题分类失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '获取主题分类失败';
  }
  return result;
}
