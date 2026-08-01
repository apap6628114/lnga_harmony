/**
 * NGA 认证 API - 登录/会话/凭据注入
 * 提供验证码获取、两步登录、凭据注入、会话校验与登出等能力。
 */

import { ngaClient } from '../NgaClient';
import { appStore } from '../../store/AppStore';
import type { Session } from '../../store/SessionRegistry';
import { parseNgaError } from '../../parser/ErrorParser';
import {
  CaptchaResult, LoginStep1Result, LoginStep2Result,
  InjectResult,
} from '../../model/NgaApiResults';
import { UserInfo } from '../../model/UserInfo';
import { Logger, DOMAIN_SERVICE, formatError } from '../../common/utils/Logger';

// ============== 临时登录会话 ==============

interface LoginSession {
  username: string;
  password: string;
  createdAt: number;
}

const loginSessions = new Map<string, LoginSession>();

// ============== 验证码 ==============

export async function getCaptcha(captchaId: string): Promise<CaptchaResult> {
  const result = new CaptchaResult();
  try {
    result.image = await ngaClient.getCaptchaV2(captchaId);
    result.ok = true;
  } catch (e) {
    result.error = (e as Error).message ?? '获取验证码失败';
  }
  return result;
}

// ============== 两步登录 ==============

export async function loginStep1(username: string, password: string): Promise<LoginStep1Result> {
  const result = new LoginStep1Result();

  if (!username || !password) {
    result.error = '请输入用户名和密码';
    return result;
  }

  const captchaId = `login${Date.now()}${Math.floor(Math.random() * 10000)}`;
  const loginToken = generateLoginToken();

  loginSessions.set(loginToken, { username, password, createdAt: Date.now() });

  try {
    result.captchaImage = await ngaClient.getCaptchaV2(captchaId);
  } catch (e) {
    // 图片获取失败不阻塞
  }

  result.needCaptcha = true;
  result.loginToken = loginToken;
  result.captchaId = captchaId;
  result.ok = true;
  return result;
}

export async function loginStep2(loginToken: string, captchaId: string, captcha: string): Promise<LoginStep2Result> {
  const result = new LoginStep2Result();

  if (!captcha || !captchaId) {
    result.needCaptcha = true;
    result.loginToken = loginToken;
    result.error = '请输入验证码';
    return result;
  }

  const session = loginSessions.get(loginToken);
  if (!session || Date.now() - session.createdAt > 5 * 60 * 1000) {
    result.needCaptcha = true;
    result.error = '登录会话已过期，请重试';
    return result;
  }

  const loginResult = await ngaClient.loginPassword({
    username: session.username,
    password: session.password,
    captchaId,
    captcha,
    type: '',
  });

  if (loginResult.success && loginResult.uid && loginResult.cid) {
    loginSessions.delete(loginToken);

    let nickName = session.username;
    const avatarUrl = `https://img4.nga.178.com/ngabbs/nga_classic/avatar/${loginResult.uid}.png`;

    // 尝试从 cookie 获取昵称
    const extracted = extractNickName(loginResult.setCookies);
    if (extracted) nickName = extracted;

    // 尝试从 NGA 获取昵称
    try {
      const fetched = await fetchNickNameFromNga(loginResult.uid, loginResult.cid, loginResult.uid);
      if (fetched) {
        nickName = fetched.nickName || nickName;
      }
    } catch (e) {
      // 忽略
    }

    const token = await appStore.createSession(loginResult.uid, loginResult.cid, nickName, avatarUrl);
    result.ok = true;
    result.token = token;
    const user = new UserInfo();
    user.uid = loginResult.uid;
    user.nickName = nickName;
    user.avatarUrl = avatarUrl;
    result.user = user;
    return result;
  }

  // 验证码错误，刷新验证码
  const newCaptchaId = `login${Date.now()}${Math.floor(Math.random() * 10000)}`;
  try {
    result.captchaImage = await ngaClient.getCaptchaV2(newCaptchaId);
  } catch (e) {
    // ignore
  }

  result.needCaptcha = true;
  result.loginToken = loginToken;
  result.captchaId = newCaptchaId;
  result.error = loginResult.error || '验证码错误';
  return result;
}

/**
 * 从 set-cookie 头中提取 passport 编码昵称
 */
function extractNickName(setCookies: string[]): string {
  for (let i = 0; i < setCookies.length; i++) {
    const match = setCookies[i].match(/ngaPassportUrlencodedUname=([^;]+)/);
    if (match) {
      try {
        return decodeURIComponent(match[1]);
      } catch (e) {
        return '';
      }
    }
  }
  return '';
}

/**
 * 通过 ucp 接口拉取目标用户的昵称/头像
 */
async function fetchNickNameFromNga(uid: string, cid: string, targetUid: string): Promise<UserInfo | null> {
  try {
    const params: Record<string, string> = {
      '__lib': 'ucp', '__act': 'get', 'lite': 'js', 'noprefix': '', 'uid': targetUid,
    };
    const raw = await ngaClient.get('/nuke.php', params, { uid, cid }) as Record<string, Object>;
    const data = raw?.['data'] as Record<string, Object> | undefined;
    const d = (data?.['0'] ?? data) as Record<string, Object> | undefined;
    if (d && d['username']) {
      const user = new UserInfo();
      user.nickName = String(d['username']);
      user.avatarUrl = String(d['avatar'] ?? '');
      return user;
    }
  } catch (e) {
    // ignore
  }
  return null;
}

/**
 * 生成 32 位十六进制登录令牌
 */
function generateLoginToken(): string {
  const chars = '0123456789abcdef';
  let result = '';
  for (let i = 0; i < 32; i++) {
    result += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return result;
}

// ============== 会话校验 ==============

export async function verifyToken(token: string): Promise<boolean> {
  const session = appStore.getSession(token);
  if (!session) {
    return false;
  }
  try {
    const params: Record<string, string> = {
      '__lib': 'ucp', '__act': 'get', 'lite': 'js', 'noprefix': '', 'uid': session.uid,
    };
    const raw = await ngaClient.get('/nuke.php', params, { uid: session.uid, cid: session.cid }) as Record<string, Object>;
    const error = parseNgaError(raw);
    if (error) {
      return false;
    }
    return true;
  } catch (e) {
    // 网络异常时无法验证，默认视为有效，避免离线时强制登出
    return true;
  }
}

// ============== 凭据注入（直登） ==============

export async function injectCredentials(uid: string, cid: string): Promise<InjectResult> {
  const result = new InjectResult();

  if (!uid || !cid) {
    result.error = '凭据不完整';
    return result;
  }

  try {
    let nickName = uid;
    const avatarUrl = `https://img4.nga.178.com/ngabbs/nga_classic/avatar/${uid}.png`;

    const fetched = await fetchNickNameFromNga(uid, cid, uid);
    if (fetched) {
      nickName = fetched.nickName || nickName;
    }

    const token = await appStore.createSession(uid, cid, nickName, avatarUrl);
    result.ok = true;
    result.token = token;
    const user = new UserInfo();
    user.uid = uid;
    user.nickName = nickName;
    user.avatarUrl = avatarUrl;
    result.user = user;
  } catch (e) {
    result.error = '凭据无效或已过期';
  }
  return result;
}

// ============== 登出 ==============

const logoutLogger = new Logger(DOMAIN_SERVICE, 'AuthApi.Logout')

/**
 * 通知 NGA 服务端使当前 token 对应的 cid 会话失效。
 *
 * 仅做网络请求，不碰本地 Store 状态。
 * 本地清理由 LogoutOrchestrator 编排的 clearAuth() 统一完成。
 * 网络失败不阻塞本地登出。
 */
export async function invalidateServerSession(token: string): Promise<void> {
  const session = appStore.getSession(token);
  if (session) {
    try {
      await ngaClient.logout({ uid: session.uid, cid: session.cid });
    } catch (e) {
      logoutLogger.warn('服务端登出失败: %{public}s', formatError(e));
    }
  }
}

/**
 * 读取会话信息（WebView 等场景直接复用当前登录态）
 */
export function getSession(token: string): Session | null {
  return appStore.getSession(token);
}
