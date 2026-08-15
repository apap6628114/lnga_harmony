/**
 * NGA 帖子 API - 帖子详情、回帖、评论、附件上传
 * 含 HTML 强制模式调试开关、JSON/HTML 双通道解析与图片预热。
 */

import { ngaClient, ngaUploadFile } from '../NgaClient';
import { appStore } from '../../store/AppStore';
import { parseThreadData } from '../../parser/ThreadParser';
import { parseNgaError } from '../../parser/ErrorParser';
import { parseFromClient } from '../../parser/ClientParser';
import { isUserMuted } from '../../parser/MuteParser';
import { resolveAttachUrl } from '../../parser/_shared/AttachUrl';
import { parseHtmlTask } from '../../parser/task/HtmlParseTask';
import { withTimeout } from '../../common/utils/TimeoutUtils';
import { taskpool } from '@kit.ArkTS';
import { ImageLoadStrategy } from '../../common/constants/Constants';
import { KEY_FORCE_HTML_MODE } from '../../common/constants/AppStorageKeys';
import { fetchImageSize } from '../../common/media/ImageSizeUtil';
import { isWifiConnected } from '../../common/utils/NetworkUtil';
import type { ThreadData, ThreadRowInfo, Attachment, ThreadInfo } from '../../model/Thread';
import { PostInfo, PostAttachInfo } from '../../model/PostInfo';
import { ThreadResult, ThreadPaging, PostAuthResult, PostReplyResult, TopicCategoriesResult } from '../../model/ThreadResult';
import { UploadAttachmentResult } from '../../model/NgaApiResults';
import { Logger, DOMAIN_SERVICE, formatError } from '../../common/utils/Logger'

const logger = new Logger(DOMAIN_SERVICE, 'ThreadApi')

// ============== 调试开关 ==============

/** 调试开关：true 时 getThread 强制走 HTML 解析模式，跳过 JSON API */
export function getForceHtmlMode(): boolean {
  const stored: boolean = AppStorage.get<boolean>(KEY_FORCE_HTML_MODE) ?? false
  return stored
}

export function setForceHtmlMode(v: boolean): void {
  AppStorage.setOrCreate<boolean>(KEY_FORCE_HTML_MODE, v)
}

// ============== 帖子详情 ==============

/**
 * 双通道取数结果：原始同形状数据 + 通道信息。
 */
interface ThreadRawResult {
  /** 与 JSON 同形状的原始数据（JSON 响应或 HTML 解析结果）；双通道均失败时为 null。 */
  raw: Record<string, Object> | null
  /** 是否经由 HTML 通道（强制 HTML / pid-only 特例 / JSON 失败降级）。 */
  viaHtml: boolean
  /** JSON 通道的错误信息（供日志/Toast/错误消息拼接；HTML 通道为空串）。 */
  jsonError: string
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
 * 双通道取数原语：read.php JSON 优先，残缺/错误时降级 HTML，返回同形状原始对象。
 *
 * 这是 getThread（渲染整页）与 locatePidPage（仅取 pid 序列）共享的底层取数：
 * 不解析、不过滤、不预热、不触碰渲染状态。JSON 被官方阻断为残缺响应
 * （README Rule 2：Unterminated string / 意外 EOF / HTML 错误页）或返回业务
 * 错误时，自动降级 read.php HTML 解析（parseHtmlTask）。本函数保证不抛异常：
 * 双通道均失败时返回 raw=null。
 *
 * @param token - 会话令牌
 * @param tid - 主题 ID（可空：仅 pid 场景走 HTML 特例）
 * @param pid - 楼层 pid（可空）
 * @param authorid - 只看楼主用户 ID（可空）
 * @param page - 页码（'e' 表示末页）
 * @returns 取数结果
 */
async function fetchThreadRaw(token: string, tid: string, pid: string,
  authorid: string, page: string): Promise<ThreadRawResult> {
  const session = appStore.getSession(token);
  if (!session) {
    return { raw: null, viaHtml: false, jsonError: '未登录' };
  }

  if (getForceHtmlMode() || !tid) {
    // 调试模式 / 强制走 HTML 解析 / 仅 pid 无 tid（现有特例）：直接 HTML 通道
    const htmlParams: Record<string, string> = {
      'tid': tid || '',
      'page': page || '1',
    };
    if (pid) htmlParams['pid'] = pid;
    if (authorid) htmlParams['authorid'] = authorid;
    try {
      const html: string = await ngaClient.getHtmlText('/read.php', htmlParams,
        { uid: session.uid, cid: session.cid });
      const rawObj: Object = await taskpool.execute(parseHtmlTask, html)
      return { raw: rawObj as Record<string, Object>, viaHtml: true, jsonError: '' };
    } catch (e) {
      return { raw: null, viaHtml: true, jsonError: (e as Error).message ?? 'HTML 解析异常' };
    }
  }

  // JSON 主通道
  let jsonError: string = '';
  try {
    const ngaParams: Record<string, string> = {
      'page': page || '1',
      '__output': '8',
      'noprefix': '',
      'v2': '',
    };
    if (tid) ngaParams['tid'] = tid;
    if (pid) ngaParams['pid'] = pid;
    if (authorid) ngaParams['authorid'] = authorid;
    const raw = await ngaClient.get('/read.php', ngaParams,
      { uid: session.uid, cid: session.cid }) as Record<string, Object>;
    const err = parseNgaError(raw);
    if (err) {
      jsonError = err;
    } else {
      return { raw: raw, viaHtml: false, jsonError: '' };
    }
  } catch (e) {
    jsonError = (e as Error).message ?? 'JSON 请求异常';
    logger.error('[NGA][REQ] JSON API 请求失败，降级 HTML: %{public}s', jsonError);
  }

  // HTML 降级
  const fallbackParams: Record<string, string> = {
    'tid': tid || '',
    'page': page || '1',
  };
  if (pid) fallbackParams['pid'] = pid;
  if (authorid) fallbackParams['authorid'] = authorid;
  try {
    const html: string = await ngaClient.getHtmlText('/read.php', fallbackParams,
      { uid: session.uid, cid: session.cid });
    const rawObj: Object = await taskpool.execute(parseHtmlTask, html)
    return { raw: rawObj as Record<string, Object>, viaHtml: true, jsonError: jsonError };
  } catch (e) {
    return { raw: null, viaHtml: true, jsonError: jsonError };
  }
}

/**
 * 获取帖子详情（JSON 主通道优先，残缺/错误时自动降级 HTML 解析）。
 *
 * 双通道取数由 fetchThreadRaw 完成，本函数负责解析（fillThreadResult）与
 * 过滤/预热，是 ThreadPanel 渲染整页的唯一取数入口。
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
      // 双通道均失败
      result.error = fetched.jsonError || '无法加载该帖子';
      return result;
    }
    // 调试模式：JSON 接口失败降级为 HTML 解析时弹出提示，便于观察请求通道
    if (fetched.viaHtml && fetched.jsonError.length > 0 && appStore.settings.debugMode) {
      appStore.showToast('JSON 接口失败，已降级为 HTML 模式：' + fetched.jsonError)
    }
    fillThreadResult(fetched.raw, result, blacklist, keywords, noteMap);
    // 降级通道解析不到楼层时判定失败（JSON 主通道保持原语义：填充即 ok）
    if (fetched.viaHtml && fetched.jsonError.length > 0 && result.posts.length === 0) {
      result.ok = false;
      result.error = fetched.jsonError || result.error || '无法加载该帖子';
    }
  } catch (e) {
    const htmlErr: string = (e as Error).message ?? 'HTML 解析异常';
    result.error = htmlErr;
  }
  return result;
}

/**
 * 在帖子数据就绪后，提前预热所有图片的尺寸头
 */
function prefetchPostImages(posts: PostInfo[]): void {
  if (!appStore.settings.enableImageSizePrefetch) {
    return
  }
  let strategy: string = appStore.settings.imageLoadStrategy
  if (strategy === ImageLoadStrategy.MANUAL) {
    return
  }
  if (strategy === ImageLoadStrategy.WIFI_ONLY && !isWifiConnected()) {
    return
  }
  for (let i = 0; i < posts.length; i++) {
    const post: PostInfo = posts[i]
    if (post.isInBlackList || appStore.settingsStore.isBlacklisted(String(post.authorid))) {
      continue
    }
    const attachs: PostAttachInfo[] = post.attachs
    for (let j = 0; j < attachs.length; j++) {
      const url: string = attachs[j].attachurl
      if (url && url.length > 0) {
        fetchImageSize(url)
      }
    }
  }
}

/**
 * 二分查找目标楼层 pid 所在页码。
 *
 * 纯数据行为：经由双通道取数原语 fetchThreadRaw（JSON 主通道优先，被官方
 * 阻断为残缺响应时自动降级 HTML），只读原始 __R 的页末 pid 与 __ROWS 分页
 * 信息，不解析、不过滤、不预热、不依赖渲染状态。利用 NGA 楼层 pid 在主题内
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
 * 从 NGA 原始 JSON 填充 ThreadResult（JSON API 与 HTML 降级共享）
 *
 * @param raw - 原始响应对象
 * @param result - 输出结果
 * @param blacklist - 黑名单 UID
 * @param keywords - 标题屏蔽关键词
 * @param noteMap - 用户备注表
 */
function fillThreadResult(raw: Record<string, Object>, result: ThreadResult,
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
    // 1. __U 用户表 mute_time（禁言到期时间戳）——JSON/HTML 双通道均有；
    // 2. __U 用户表 buffs（105 = 禁言 buff）——JSON 通道增强。
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
      // JSON 模式主楼 vote 与主题级一致（此分支通常不触发）；
      // 保留以防 JSON 模式 __R[0] 缺 vote 而 __T 有值的异常情况
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

  prefetchPostImages(result.posts);

  result.ok = true;
}

// ============== 发帖/回帖 ==============

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

/**
 * 发帖/回复/评论前的鉴权预检。
 *
 * 对应官方客户端 TopicPostModel.getPostInfo：请求 post.php 并解析
 * window.script_muti_get_var_store 前缀的 JSON，返回 auth（附件上传校验码）、
 * 附件上传地址与版主标记。
 *
 * @param token - 会话令牌
 * @param fid - 版块 ID
 * @param action - 操作类型（new/reply/modify 等）
 * @param tid - 主题 ID（回复/编辑场景）
 * @param pid - 楼层 ID（回复/编辑场景）
 * @param comment - 是否贴条（1 表示贴条）
 * @param stid - 子版块 ID（发新主题到子版块时传，0 表示父版块）
 * @returns 鉴权结果；服务端返回错误时 ok 为 false
 */
export async function getPostAuth(token: string, fid: number, action: string,
  tid: number, pid: number, comment: number, stid: number = 0): Promise<PostAuthResult> {
  const result = new PostAuthResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    const authParams: Record<string, string> = {
      'fid': String(fid),
      'lite': 'js',
    };
    if (action) authParams['action'] = action;
    if (pid) authParams['pid'] = String(pid);
    if (tid) authParams['tid'] = String(tid);
    if (comment) authParams['comment'] = String(comment);
    if (stid) authParams['stid'] = String(stid);

    const raw = await ngaClient.postWithQuery('/post.php', authParams, { uid: session.uid, cid: session.cid }) as Record<string, Object>;
    const err = parseNgaError(raw);
    if (err) {
      result.error = err;
      return result;
    }
    const dataObj = raw?.['data'] as Record<string, Object> | undefined;
    result.auth = String(dataObj?.['auth'] ?? '');
    result.attachUrl = String(dataObj?.['attach_url'] ?? '');
    result.if_moderator = Number(dataObj?.['if_moderator'] ?? 0);
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '获取auth失败';
  }
  return result;
}

export async function postReply(token: string, tid: number, fid: number,
  content: string, anony: number, attachments: string, attachmentsCheck: string,
  stid: number, action: string, pid: number, postSubject: string): Promise<PostReplyResult> {
  const result = new PostReplyResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    const fields: Record<string, string> = {
      'step': '2',
      'action': action || 'reply',
      'fid': String(fid),
      'post_content': content,
      'anony': String(anony),
      '__output': '8',
    };
    // 与官方协议一致：无附件时不携带 attachments 字段，否则服务端会进入附件确认校验并报错
    if (attachments) {
      fields['attachments'] = attachments;
      fields['attachments_check'] = attachmentsCheck;
    }
    if (tid) fields['tid'] = String(tid);
    if (pid) fields['pid'] = String(pid);
    if (postSubject) fields['post_subject'] = postSubject;
    if (stid) fields['stid'] = String(stid);

    const raw = await ngaClient.post('/post.php', fields,
      { uid: session.uid, cid: session.cid }, ['post_content', 'post_subject']) as Record<string, Object>;
    const error = parseNgaError(raw);
    if (error) {
      result.error = error;
      return result;
    }
    const dataObj = raw?.['data'] as Record<string, Object> | undefined;
    result.tid = Number(dataObj?.['tid'] ?? tid ?? 0);
    result.pid = String(dataObj?.['pid'] ?? '');
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '回复失败';
  }
  return result;
}

/**
 * 发布新主题。
 *
 * 对应官方客户端 TopicPostTask + PostParam.toString()：POST post.php，
 * action=new、step=2；post_subject 与 post_content 走 GBK 百分号编码。
 * 响应带 __output=8 时为 JSON，data.tid 为新主题 ID。
 *
 * @param token - 会话令牌
 * @param fid - 版块 ID
 * @param stid - 子版块 ID（0 表示发在父版块）
 * @param subject - 标题
 * @param content - 正文（BBCode）
 * @param anony - 是否匿名（1 表示匿名）
 * @param attachments - 附件参数（tab 分隔）
 * @param attachmentsCheck - 附件校验参数（tab 分隔）
 * @returns 提交结果；成功时 tid 为新主题 ID
 */
export async function postNewTopic(token: string, fid: number, stid: number,
  subject: string, content: string, anony: number, attachments: string,
  attachmentsCheck: string): Promise<PostReplyResult> {
  const result = new PostReplyResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    const fields: Record<string, string> = {
      'step': '2',
      'action': 'new',
      'fid': String(fid),
      'post_subject': subject,
      'post_content': content,
      'anony': String(anony),
      '__output': '8',
    };
    // 与官方协议一致：无附件时不携带 attachments 字段，否则服务端会进入附件确认校验并报错
    if (attachments) {
      fields['attachments'] = attachments;
      fields['attachments_check'] = attachmentsCheck;
    }
    if (stid) fields['stid'] = String(stid);

    const raw = await ngaClient.post('/post.php', fields,
      { uid: session.uid, cid: session.cid }, ['post_content', 'post_subject']) as Record<string, Object>;
    const error = parseNgaError(raw);
    if (error) {
      result.error = error;
      return result;
    }
    const dataObj = raw?.['data'] as Record<string, Object> | undefined;
    result.tid = Number(dataObj?.['tid'] ?? 0);
    result.pid = String(dataObj?.['pid'] ?? '');
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '发帖失败';
  }
  return result;
}

export async function postComment(token: string, tid: number, pid: number,
  fid: number, content: string, anony: number): Promise<PostReplyResult> {
  const result = new PostReplyResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    const fields: Record<string, string> = {
      'step': '2',
      'action': 'reply',
      'comment': '1',
      'lite': 'htmljs',
      'nojump': '1',
      'fid': String(fid),
      'tid': String(tid),
      'pid': String(pid),
      'post_content': content,
      'anony': String(anony),
      '__output': '8',
    };

    const raw = await ngaClient.post('/post.php', fields,
      { uid: session.uid, cid: session.cid }, ['post_content']) as Record<string, Object>;
    const error = parseNgaError(raw);
    if (error) {
      result.error = error;
      return result;
    }
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '评论失败';
  }
  return result;
}

// ============== 附件上传 ==============

export async function uploadAttachment(token: string, auth: string,
  fid: number, imageData: ArrayBuffer, fileName: string): Promise<UploadAttachmentResult> {
  const result = new UploadAttachmentResult()
  const session = appStore.getSession(token)
  if (!session) {
    result.error = '未登录'
    return result
  }

  try {
    const rawText: string = await ngaUploadFile(imageData, fileName, auth, fid, {
      uid: session.uid,
      cid: session.cid,
    })
    const cleaned: string = rawText.replace('window.script_muti_get_var_store=', '').trim()
    logger.verbose('[NGA][UPLOAD] raw: %{public}s', rawText.slice(0, 300))
    logger.verbose('[NGA][UPLOAD] cleaned: %{public}s', cleaned.slice(0, 300))
    // NGA 上传接口返回 JS 对象字面量（单引号+无引号属性名），转成严格 JSON
    const jsonStr: string = cleaned
      .replace(/'/g, '"')
      .replace(/([{,]\s*)([a-zA-Z_$][\w$]*)(\s*:)/g, '$1"$2"$3')
    let parsed: Record<string, Object>
    try {
      parsed = JSON.parse(jsonStr) as Record<string, Object>
    } catch (parseErr) {
      result.error = '上传响应解析失败: ' + (parseErr as Error).message
      return result
    }
    // 检查服务端错误码（对应 Java error_code == 9 附件过大）
    const errorCode: number = Number(parsed['error_code'] ?? 0)
    if (errorCode !== 0) {
      result.error = '上传被拒绝 (错误码 ' + String(errorCode) + ')。若图片过大请压缩后再试'
      return result
    }
    const dataObj = parsed['data'] as Record<string, Object> | undefined
    if (!dataObj) {
      result.error = '上传响应缺少 data'
      return result
    }
    const attachUrl: string = String(dataObj['attach_url'] ?? '')
    const attachment: string = String(dataObj['attachment'] ?? '')
    result.url = String(dataObj['url'] ?? attachUrl + attachment)
    result.attachments = String(dataObj['attachments'] ?? '')
    result.attachmentsCheck = String(dataObj['attachments_check'] ?? '')
    result.ok = true
  } catch (e) {
    result.error = (e as Error).message ?? '上传失败'
  }
  return result
}
