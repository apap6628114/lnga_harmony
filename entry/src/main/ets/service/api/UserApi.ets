/**
 * NGA 用户 API - 当前用户、用户资料、用户成分分析
 */

import { ngaClient } from '../NgaClient';
import { appStore } from '../../store/AppStore';
import {
  CurrentUserResult, UserProfileResult, UserActivityAnalysis, ForumStat,
} from '../../model/NgaApiResults';
import { UserInfo } from '../../model/UserInfo';
import { ProfileData, ReputationData, AdminForumsData } from '../../model/User';
import { resolveEffectiveMuteTs } from '../../parser/MuteParser';
import { formatTime, formatTimestampCST } from '../../common/utils/Utils';
import { Logger, DOMAIN_SERVICE, formatError } from '../../common/utils/Logger';

const logger = new Logger(DOMAIN_SERVICE, 'UserApi')

// ============== 当前用户 ==============

export async function getCurrentUser(token: string): Promise<CurrentUserResult> {
  const result = new CurrentUserResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '会话不存在';
    return result;
  }

  try {
    const params: Record<string, string> = {
      '__lib': 'ucp', '__act': 'get', 'lite': 'js', 'noprefix': '', 'uid': session.uid,
    };
    const raw = await ngaClient.get('/nuke.php', params, { uid: session.uid, cid: session.cid }) as Record<string, Object>;
    const data = raw?.['data'] as Record<string, Object> | undefined;
    const d = (data?.['0'] ?? data) as Record<string, Object> | undefined;

    const nickName = String(d?.['username'] ?? session.nickName);
    const avatarUrl = String(d?.['avatar'] ?? session.avatarUrl);

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

// ============== 用户资料 ==============

export async function getUserProfile(token: string, uid: string): Promise<UserProfileResult> {
  const result = new UserProfileResult();
  const session = appStore.getSession(token);
  if (!session) {
    result.error = '未登录';
    return result;
  }

  try {
    const params: Record<string, string> = {
      '__lib': 'ucp', '__act': 'get', 'lite': 'js', 'noprefix': '', 'uid': uid,
    };
    const extraHeaders: Record<string, string> = {
      'Referer': `https://bbs.nga.cn/nuke.php?func=ucp&lite=jsx&uid=${uid}`,
    };
    const raw = await ngaClient.get('/nuke.php', params, { uid: session.uid, cid: session.cid }, extraHeaders) as Record<string, Object>;

    const errorObj = raw?.['error'];
    if (errorObj) {
      const errMsg = typeof errorObj === 'string' ? String(errorObj) :
        String((errorObj as Record<string, Object>)['0']);
      result.error = errMsg || '获取用户资料失败';
      return result;
    }

    const rawInner = (raw?.['data'] ?? {}) as Record<string, Object>;
    const d = (rawInner['0'] ?? rawInner) as Record<string, Object>;
    const regTimestamp = Number(d['regdate']) || 0;
    // 禁言到期时间：maxBuffMute 为 buff 类禁言（105）到期时间戳，muteTime 为旧字段
    // （仅反映历史 mute_time，对 buff 禁言恒为 0）——优先 maxBuffMute
    const effectiveMuteTs = resolveEffectiveMuteTs(
      Number(d['muteTime']) || 0,
      Number(d['maxBuffMute']) || 0
    );
    const medalStr = String(d['medal'] ?? '0');
    const hasMedal = medalStr !== '0' && medalStr !== '';

    const repList: ReputationData[] = [];
    if (d['reputation'] && typeof d['reputation'] === 'object') {
      const repObj = d['reputation'] as Record<string, Object>;
      const repKeys = Object.keys(repObj);
      for (let i = 0; i < repKeys.length; i++) {
        const entry = repObj[repKeys[i]];
        if (Array.isArray(entry)) {
          const arr = entry as Object[];
          const repItem = new ReputationData();
          repItem.name = String(arr[0] ?? '');
          repItem.value = String(arr[1] ?? '');
          repItem.reputation = Number(arr[2] ?? 0);
          repItem.topicSubject = String(arr[3] ?? '');
          repItem.postContent = String(arr[4] ?? '');
          repItem.author = String(arr[5] ?? '');
          repItem.time = Number(arr[6] ?? 0);
          repList.push(repItem);
        }
      }
    }

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
    profile.userName = String(d['username'] ?? '');
    profile.avatarUrl = String(d['avatar'] ?? '');
    profile.group = String(d['group'] ?? '');
    profile.title = String(d['title'] ?? '');
    profile.honor = String(d['honor'] ?? '');
    profile.yz = Number(d['yz'] ?? 0);
    profile.money = String(d['money'] ?? '');
    profile.fame = String(d['fame'] ?? '');
    profile.rvrc = String(d['rvrc'] ?? '');
    profile.posts = String(d['posts'] ?? '');
    profile.regdate = regTimestamp > 0 ? String(regTimestamp) : '';
    profile.sign = String(d['sign'] ?? '');
    profile.ipLoc = String(d['ipLoc'] ?? '');
    profile.medal = hasMedal ? medalStr : '';
    profile.muteTime = effectiveMuteTs > 0 ? formatTimestampCST(effectiveMuteTs) : '';
    profile.followByNum = String(d['follow_by_num'] ?? '');
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
 * 官方 [@用户名] 链接指向 nuke.php?func=ucp&username= 用户页（页内 `__UCPUSER`
 * JSON 变量携带 uid）；客户端资料卡只认 uid，故点击时先经本函数解析 uid。
 * 用户不存在时服务端返回 `{"error":{"0":"找不到用户"}}`。
 *
 * @param token - 登录令牌
 * @param username - 用户名称（原文，URL 编码由 NgaClient 统一处理）
 * @returns 用户 UID；用户不存在、未登录或请求失败时返回空字符串
 */
export async function resolveUidByUsername(token: string, username: string): Promise<string> {
  const session = appStore.getSession(token);
  if (!session) return '';
  try {
    const params: Record<string, string> = {
      'func': 'ucp', 'lite': 'js', 'noprefix': '', '__inchst': 'UTF8', 'username': username,
    };
    const text: string = await ngaClient.getHtmlText('/nuke.php', params, { uid: session.uid, cid: session.cid });
    if (text.indexOf('找不到用户') >= 0) return '';
    const match: RegExpMatchArray | null = text.match(/__UCPUSER\s*=\s*\{"uid":(\d+)/);
    return match ? match[1] : '';
  } catch (e) {
    logger.warn('按用户名解析 UID 失败: %{public}s', formatError(e));
    return '';
  }
}

// ============== 用户成分分析 ==============

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
  if (!session) return null;

  try {
    const topicParams: Record<string, string> = {
      'page': '1', 'lite': 'js', 'noprefix': '', 'authorid': uid,
    };
    const topicRaw = await ngaClient.get('/thread.php', topicParams, { uid: session.uid, cid: session.cid }) as Record<string, Object>;
    const tData = (topicRaw['data'] as Record<string, Object> | undefined)?.['__T'] as Record<string, Object> | undefined;
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

    const replyParams: Record<string, string> = {
      'page': '1', 'lite': 'js', 'noprefix': '', 'authorid': uid, 'searchpost': '1',
    };
    const replyRaw = await ngaClient.get('/thread.php', replyParams, { uid: session.uid, cid: session.cid }) as Record<string, Object>;
    const rData = (replyRaw['data'] as Record<string, Object> | undefined)?.['__T'] as Record<string, Object> | undefined;
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

    return result;
  } catch (e) {
    logger.warn('获取用户成分分析失败: %{public}s', formatError(e));
    return null;
  }
}
