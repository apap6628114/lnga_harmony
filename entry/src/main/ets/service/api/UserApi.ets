/**
 * NGA 用户 API - 当前用户、用户资料、用户成分分析
 */

import { ngaClient, Cookies } from '../NgaClient';
import { appStore } from '../../store/AppStore';
import {
  CurrentUserResult, UserProfileResult, UserActivityAnalysis, ForumStat, SearchUserResult,
} from '../../model/NgaApiResults';
import { UserInfo } from '../../model/UserInfo';
import { ProfileData, ReputationData, AdminForumsData } from '../../model/User';
import { resolveEffectiveMuteTs } from '../../parser/MuteParser';
import { appUserListEndpoints, extractAppUserTopicItems } from '../../parser/AppUserTopicParser';
import type { AppUserListEndpoint } from '../../parser/AppUserTopicParser';
import { extractAppUser, extractAppUserError } from '../../parser/AppUserParser';
import { parseReputationList } from '../../parser/ReputationParser';
import { formatTime, formatTimestampCST } from '../../common/utils/Utils';
import { Logger, DOMAIN_SERVICE, formatError } from '../../common/utils/Logger';

const logger = new Logger(DOMAIN_SERVICE, 'UserApi')

// ============== 当前用户 ==============

/**
 * 通过 NGA 官方 APP 签名接口查询用户对象。
 *
 * ucp/get 使用 POST form，__lib/__act 位于 URL query；uid 查询传 uid，用户名
 * 查询传 username，signParams 为空，输出格式使用官方客户端的 __output=12。
 * 所有昵称、会话校验、用户搜索和用户资料请求都经此入口，避免重新落回网页 GET。
 *
 * @param cookies - NGA 会话凭据
 * @param lookupKey - 查询字段，uid 或 username
 * @param lookupValue - 查询值
 * @returns NGA 用户对象
 */
export async function getSignedUser(cookies: Cookies, lookupKey: string,
  lookupValue: string): Promise<Record<string, Object>> {
  const params: Record<string, string> = {};
  params[lookupKey] = lookupValue;
  const raw: Record<string, Object> = await ngaClient.postSigned(
    '/nuke.php', 'ucp', 'get', params, cookies, '', '12'
  ) as Record<string, Object>;
  const code: Object | undefined = raw['code'];
  if (code !== undefined && Number(code) !== 0) {
    throw new Error(extractAppUserError(raw, '获取用户信息失败'));
  }
  const user: Record<string, Object> | null = extractAppUser(raw);
  if (user === null) {
    throw new Error(extractAppUserError(raw, '用户不存在或资料为空'));
  }
  return user;
}

/**
 * 获取当前登录用户的轻量信息，并刷新本地会话缓存。
 *
 * @param token - 当前账号令牌
 * @returns 当前用户信息
 */
export async function getCurrentUser(token: string): Promise<CurrentUserResult> {
  const result = new CurrentUserResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '会话不存在';
    return result;
  }

  try {
    const d: Record<string, Object> = await getSignedUser(
      { uid: session.uid, cid: session.cid }, 'uid', session.uid
    );

    const nickName = String(d['nickname'] ?? d['username'] ?? session.nickName);
    const avatarUrl = String(d['avatar'] ?? session.avatarUrl);

    await appStore.updateSession(token, nickName, avatarUrl);

    const user = new UserInfo();
    user.uid = session.uid;
    user.nickName = nickName;
    user.avatarUrl = avatarUrl;
    result.ok = true;
    result.user = user;
  } catch (e) {
    logger.warn('获取当前用户失败，使用会话缓存: %{public}s', formatError(e));
    const user = new UserInfo();
    user.uid = session.uid;
    user.nickName = session.nickName;
    user.avatarUrl = session.avatarUrl;
    result.ok = true;
    result.user = user;
  }
  return result;
}

// ============== 用户搜索 ==============

/**
 * 按关键词搜索用户（对齐 MNGA get_remote_user：纯数字自动按 uid，否则按用户名）。
 *
 * @param token - 当前账号令牌
 * @param key - 搜索关键词（uid 或用户名）
 * @returns 用户搜索结果
 */
export async function searchUser(token: string, key: string): Promise<SearchUserResult> {
  const result = new SearchUserResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    let lookupKey: string = 'username';
    if (/^\d+$/.test(key)) {
      lookupKey = 'uid';
    }
    const d: Record<string, Object> = await getSignedUser(
      { uid: session.uid, cid: session.cid }, lookupKey, key
    );
    const uid: string = String(d['uid'] ?? '');
    if (uid.length > 0) {
      result.data.push({
        uid: uid,
        userName: String(d['username'] ?? d['nickname'] ?? ''),
        avatarUrl: String(d['avatar'] ?? ''),
      });
    }
    result.ok = true;
  } catch (e) {
    logger.warn('搜索用户失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '搜索用户失败';
  }
  return result;
}

// ============== 用户资料 ==============

/**
 * 获取指定用户的资料卡数据。
 *
 * @param token - 当前账号令牌
 * @param uid - 目标用户 UID
 * @returns 用户资料
 */
export async function getUserProfile(token: string, uid: string): Promise<UserProfileResult> {
  const result = new UserProfileResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    const d: Record<string, Object> = await getSignedUser(
      { uid: session.uid, cid: session.cid }, 'uid', uid
    );
    const regTimestamp = Number(d['regdate']) || 0;
    // 禁言到期时间：maxBuffMute 为 buff 类禁言（105）到期时间戳，muteTime 为旧字段
    // （仅反映历史 mute_time，对 buff 禁言恒为 0）——优先 maxBuffMute
    const effectiveMuteTs = resolveEffectiveMuteTs(
      Number(d['muteTime'] ?? d['mute_time']) || 0,
      Number(d['maxBuffMute']) || 0
    );
    const medalStr = String(d['medal'] ?? '0');
    const hasMedal = medalStr !== '0' && medalStr !== '';

    // 多版面声望（[名称, 数值, 描述] 三元组；非「威望历史记录」，见 ReputationParser）
    const repList: ReputationData[] = parseReputationList(d['reputation']);

    const adminList: AdminForumsData[] = [];
    if (d['adminForums'] && typeof d['adminForums'] === 'object') {
      const forums = d['adminForums'] as Record<string, Object>;
      const fKeys = Object.keys(forums);
      for (let i = 0; i < fKeys.length; i++) {
        const name = forums[fKeys[i]];
        if (typeof name === 'string') {
          const item = new AdminForumsData();
          item.fid = fKeys[i];
          item.forumName = String(name);
          adminList.push(item);
        }
      }
    }

    const profile = new ProfileData();
    profile.uid = String(d['uid'] ?? uid);
    profile.userName = String(d['username'] ?? d['nickname'] ?? '');
    profile.avatarUrl = String(d['avatar'] ?? '');
    profile.group = String(d['group'] ?? '');
    profile.title = String(d['title'] ?? '');
    profile.honor = String(d['honor'] ?? '');
    profile.yz = Number(d['yz'] ?? 0);
    profile.money = String(d['money'] ?? '');
    profile.fame = String(d['fame'] ?? '');
    profile.rvrc = String(d['rvrc'] ?? '');
    profile.posts = String(d['posts'] ?? d['postnum'] ?? '');
    profile.regdate = regTimestamp > 0 ? String(regTimestamp) : '';
    profile.sign = String(d['sign'] ?? d['signature'] ?? '');
    profile.ipLoc = String(d['ipLoc'] ?? '');
    profile.medal = hasMedal ? medalStr : '';
    profile.muteTime = effectiveMuteTs > 0 ? formatTimestampCST(effectiveMuteTs) : '';
    profile.followNum = String(d['follow_num'] ?? '');
    profile.followByNum = String(d['follow_by_num'] ?? '');
    profile.follow = Number(d['follow'] ?? 0) === 1;
    profile.adminForums = adminList;
    profile.reputationEntryList = repList;

    result.data = profile;
    result.ok = true;
  } catch (e) {
    logger.warn('获取用户资料失败: %{public}s', formatError(e));
    result.error = (e as Error).message ?? '获取用户资料失败';
  }
  return result;
}

/**
 * 按用户名解析用户 UID。
 *
 * 官方 [@用户名] 链接最终通过 ucp/get 的 username 查询拿到用户对象，不再抓取
 * HTML 用户页；资料卡仍只接收 UID，因此保留这个解析入口供链接分发层调用。
 *
 * @param token - 登录令牌
 * @param username - 用户名称
 * @returns 用户 UID；用户不存在、未登录或请求失败时返回空字符串
 */
export async function resolveUidByUsername(token: string, username: string): Promise<string> {
  const session = appStore.getSession(token);
  if (!session) return '';
  try {
    const user: Record<string, Object> = await getSignedUser(
      { uid: session.uid, cid: session.cid }, 'username', username
    );
    return String(user['uid'] ?? '');
  } catch (e) {
    logger.warn('按用户名解析 UID 失败: %{public}s', formatError(e));
    return '';
  }
}

// ============== 用户成分分析 ==============

/**
 * 抓取指定用户的发帖/回帖记录主题表（__T 形状）。
 *
 * 仅走官方 APP 签名接口（thread.php 网页版通道已随用户历史查询一并移除）：
 *  - 发帖（TA 的主题）：app_api.php?__lib=user&__act=subjects（主，字段含 forumname/post；
 *    兜底 nuke.php?__lib=load_topic&__act=load_topic_by_uid，result 为数字键字典）
 *  - 回帖：app_api.php?__lib=user&__act=replys（元素含 post 楼层信息）
 *
 * 统一经 extractAppUserTopicItems 归一化（forumname→parent、post→__P），
 * 返回按索引归一为 __T 形状的字典，供 getUserActivityAnalysis 直接消费。
 *
 * 注意：仅取第 1 页作为成分分析样本（非全量历史）；真空页（无任何条目）同样
 * 返回空 __T 而非失败，由统计层得到 0 计数。
 *
 * @param token 会话令牌
 * @param uid 目标用户 id
 * @param searchpost true=回帖记录，false=发帖记录
 * @returns __T 主题表；接口业务失败/形状不可识别时返回 null
 */
async function fetchUserTopicT(token: string, uid: string, searchpost: boolean): Promise<Record<string, Object> | null> {
  const session = appStore.getSession(token);
  if (!session) {
    return null;
  }
  const cookies: Cookies = { uid: session.uid, cid: session.cid };
  const endpoints: AppUserListEndpoint[] = appUserListEndpoints(searchpost);
  for (let i = 0; i < endpoints.length; i++) {
    const ep: AppUserListEndpoint = endpoints[i];
    try {
      const params: Record<string, string> = { 'uid': uid, 'page': '1' };
      const raw: Record<string, Object> = await ngaClient.postSigned(ep.path, ep.lib, ep.act,
        params, cookies, uid, '12') as Record<string, Object>;
      const items: Record<string, Object>[] | null = extractAppUserTopicItems(raw);
      if (items !== null) {
        // 接口成功（含真空页/满占位页）：原样返回，统计层自行过滤受限条目
        const t: Record<string, Object> = {};
        for (let j = 0; j < items.length; j++) {
          t[String(j)] = items[j];
        }
        return t;
      }
      logger.warn('[NGA][REQ] 用户记录官方接口失败(%{public}s/%{public}s)', ep.lib, ep.act);
    } catch (e) {
      logger.warn('[NGA][REQ] 用户记录官方接口异常(%{public}s/%{public}s): %{public}s',
        ep.lib, ep.act, formatError(e));
    }
  }
  return null;
}

export async function getUserActivityAnalysis(token: string, uid: string): Promise<UserActivityAnalysis | null> {
  const result = new UserActivityAnalysis();
  const hourDist: number[] = [];
  for (let i = 0; i < 24; i++) hourDist.push(0);
  result.hourDistribution = hourDist;

  const forumMap: Record<string, ForumStat> = {};

  const addToForum = (name: string, isTopic: boolean): void => {
    let n = name;
    if (!n || n.length === 0) n = '未知';
    if (!forumMap[n]) {
      const fs = new ForumStat();
      fs.name = n;
      forumMap[n] = fs;
    }
    if (isTopic) forumMap[n].topicCount++;
    else forumMap[n].replyCount++;
  };

  const extractHour = (ts: number): void => {
    if (ts <= 0) return;
    const d = new Date(ts > 1e12 ? ts : ts * 1000);
    // 统计口径与展示一致：NGA 服务器时间（东八区）
    const cst = new Date(d.getTime() + d.getTimezoneOffset() * 60000 + 8 * 3600000);
    const h = cst.getHours();
    if (h >= 0 && h < 24) result.hourDistribution[h]++;
  };

  const extractForumName = (raw: Record<string, Object>): string => {
    const parent = raw['parent'] as Record<string, Object> | undefined;
    if (parent && parent['2']) return String(parent['2']);
    return '';
  };

  const session = appStore.getSession(token);
  if (!session) {
    return null;
  }

  try {
    const tData: Record<string, Object> | null = await fetchUserTopicT(token, uid, false);
    if (tData) {
      const tKeys = Object.keys(tData);
      for (let i = 0; i < tKeys.length; i++) {
        const entry = tData[tKeys[i]] as Record<string, Object>;
        const subject = String(entry['subject'] ?? '');
        const entryAuthorId = Number(entry['authorid'] ?? 0);
        if (!entry['tid'] || entryAuthorId === 0) continue;
        if (subject.includes('帖子发布或回复时间超过限制') || subject.includes('帐号权限不足')) continue;
        result.topicCount++;
        result.topicSubjects.push(subject + ' (' + formatTime(Number(entry['postdate'] ?? 0)) + ')');
        addToForum(extractForumName(entry), true);
        extractHour(Number(entry['postdate'] ?? 0));
      }
    }

    const rData: Record<string, Object> | null = await fetchUserTopicT(token, uid, true);
    if (rData) {
      const rKeys = Object.keys(rData);
      for (let i = 0; i < rKeys.length; i++) {
        const entry = rData[rKeys[i]] as Record<string, Object>;
        const subject = String(entry['subject'] ?? '');
        const entryAuthorId = Number(entry['authorid'] ?? 0);
        if (!entry['tid'] || entryAuthorId === 0) continue;
        if (subject.includes('帖子发布或回复时间超过限制') || subject.includes('帐号权限不足')) continue;
        result.replyCount++;
        addToForum(extractForumName(entry), false);
        const pData = entry['__P'] as Record<string, Object> | undefined;
        if (pData && pData['content']) {
          let rc: string = String(pData['content']);
          rc = rc.replace(/\[quote\][\s\S]*?\[\/quote\]/gi, '');
          rc = rc.replace(/\[\/?(?:pid|uid|tid|b|i|u|del|h|url|color|size|font|collapse|code)\d*[^\]]*\]/gi, '');
          rc = rc.replace(/\[s:\w+:\w+\]/g, '');
          rc = rc.replace(/<[^>]+>/g, '');
          rc = rc.replace(/https?:\/\/\S+/g, '');
          rc = rc.replace(/\s+/g, ' ').trim();
          if (rc.length > 0) {
            const replyTs = Number(pData?.['postdate'] ?? 0);
            result.replySnippets.push('回复于《' + subject + '》(' + formatTime(replyTs) + '): ' + rc.slice(0, 200));
          }
        }
        const replyTs = Number(pData?.['postdate'] ?? 0);
        if (replyTs > 0) {
          extractHour(replyTs);
        }
      }
    }

    const fList: ForumStat[] = [];
    const fKeys = Object.keys(forumMap);
    for (let i = 0; i < fKeys.length; i++) {
      fList.push(forumMap[fKeys[i]]);
    }
    fList.sort((a, b) => (b.topicCount + b.replyCount) - (a.topicCount + a.replyCount));
    result.forumList = fList;

    // 调试模式：官方接口加载失败的段提示（thread.php 通道已移除，仅官方签名接口）
    if ((!tData || !rData) && appStore.settings.debugMode) {
      const failedSeg: string = (!tData ? '发帖记录' : '') +
        (!tData && !rData ? '、' : '') + (!rData ? '回帖记录' : '');
      appStore.showToast('用户成分分析加载失败（' + failedSeg + '的官方接口请求失败）')
    }

    return result;
  } catch (e) {
    logger.warn('获取用户成分分析失败: %{public}s', formatError(e));
    return null;
  }
}
