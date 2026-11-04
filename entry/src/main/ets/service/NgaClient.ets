import { http } from '@kit.NetworkKit';
import { preprocessJson, extractScriptStoreJson } from '../parser/NgaJsonSanitizer';
import { classifyAuthFailure } from './api/AuthErrors';
import { ngaThrottler, isThrottleCooldownMessage, THROTTLE_COOLDOWN_MARKER } from '../common/concurrency/Throttler';
import type { Throttler } from '../common/concurrency/Throttler';
import {
  DEFAULT_THROTTLE_COOLDOWN_MS,
  hasThrottleSignal,
  isWritableOperation,
  looksLikeThrottle,
  retryDelayMs
} from './api/NgaThrottleSignals';
import { Logger, DOMAIN_NETWORK, formatError } from '../common/utils/Logger';
import {
  uint8ArrayToBase64,
  decodeGb18030,
  decodeUtf8,
  buildEncodedBody,
  buildMultipart,
  emptyStringRecord,
} from '../common/utils/CodecUtils';
import { extractHostname, buildUrl } from '../common/utils/UrlUtils';
import { parseSessionCookies, normalizeCookieList } from '../common/CookieUtils';
import { NGA_API_DOMAINS as DOMAINS } from '../common/constants/NgaDomains';
import { encryptPassword } from '../common/security/NgaRsaCipher';
import { makeClientChecksum, makeSign, NGA_APP_ID } from '../common/security/NgaSigner';

// ============== 类型定义 ==============

interface LoginParams {
  username: string;
  password: string;
  captchaId: string;
  captcha: string;
  type: string;
}

export interface LoginResultData {
  success: boolean;
  uid: string;
  cid: string;
  error: string;
  setCookies: string[];
}

// ============== 常量 ==============

let activeDomainIndex: number = 0;

const logger = new Logger(DOMAIN_NETWORK, 'NgaClient');

// ============== 工具函数 ==============

// 编解码工具（stringToUint8Array/uint8ArrayToBase64/decodeGb18030/emojiToHtmlEntity/
// buildEncodedBody/buildMultipart/emptyStringRecord）
// 已下沉至 common/utils/CodecUtils.ets。
// URL 工具（extractHostname/buildUrl）已下沉至 common/utils/UrlUtils.ets。

// ============== HTTP 请求 ==============

const LOG_CHUNK_SIZE: number = 1500;

/**
 * 对请求/响应日志中的敏感字段打码（access_token/access_uid/sign/password）。
 *
 * 官方签名通道的 POST body 含 access_uid/access_token/sign，verbose 日志不得
 * 泄露凭据。注意：仅脱敏值本身，参数名保留便于诊断。
 *
 * @param text - 原始日志文本
 * @returns 脱敏后的日志文本
 */
function sanitizeSensitiveLog(text: string): string {
  let s: string = text;
  s = s.replace(/(access_token|access_uid|sign|password)=([^&\s]*)/gi, '$1=***');
  return s;
}

function logChunks(prefix: string, text: string): void {
  if (!logger.isVerbose()) {
    return;
  }
  const safeText: string = sanitizeSensitiveLog(text);
  if (safeText.length === 0) {
    return;
  }
  if (safeText.length <= LOG_CHUNK_SIZE) {
    logger.verbose('%{public}s', prefix + safeText);
    return;
  }
  let offset = 0;
  let seq = 1;
  while (offset < safeText.length) {
    const end = Math.min(offset + LOG_CHUNK_SIZE, safeText.length);
    logger.verbose('%{public}s', prefix + `[${seq}]` + safeText.slice(offset, end));
    offset = end;
    seq++;
  }
}

function httpReq(url: string, method: http.RequestMethod,
  header: Record<string, string>, body?: string): Promise<HttpResponse> {
  logger.verbose('[NGA][REQ] %{public}s %{public}s', method, url);
  if (body && body.length > 0) {
    logChunks('[NGA][REQ] body:', body);
  }
  return new Promise<HttpResponse>((resolve, reject) => {
    const httpRequest = http.createHttp();
    const options: http.HttpRequestOptions = {
      method,
      header,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      readTimeout: 30000,
      connectTimeout: 15000,
    };
    if (body) {
      options.extraData = body;
    }
    httpRequest.request(url, options, (err, response) => {
      httpRequest.destroy();
      if (err) {
        logger.verbose('[NGA][REQ] fail: %{public}s, %{public}s', url, err.message);
        reject(new Error(`HTTP请求失败: ${err.message}`));
        return;
      }
      logger.verbose('[NGA][RES] %{public}d %{public}s', response.responseCode, url);
      resolve({
        status: response.responseCode,
        body: response.result as ArrayBuffer,
        header: response.header as Record<string, Object>,
      });
    });
  });
}

interface HttpResponse {
  status: number
  body: ArrayBuffer
  /** 响应头映射，可选；调用方需要读取 set-cookie 等响应头时由 httpReq 填充。 */
  header?: Record<string, Object>
}

/**
 * 统一的「首次请求 + 失败后遍历 DOMAINS 重试 + ngaThrottler acquire/release」执行器。
 *
 * 调用方传入的 baseUrl 决定重试策略：传空字符串时重试遍历 DOMAINS 轮换；传非空
 * 字符串时重试始终命中该域名。
 *
 * header 构造逻辑统一：User-Agent + X-User-Agent + extraHeaders(可选) + Cookie(可选) +
 * POST 时的 Content-Type/Content-Length。
 *
 * Content-Length 注意：POST 分支默认按 body.length（UTF-16 字符数）设置 Content-Length。
 * 这对纯 ASCII body（字符数=字节数，如 urlencoded 表单）安全。但 multipart body 若含非 ASCII
 * （如 loginPassword 的中文用户名），字符数 < UTF-8 字节数会导致 Content-Length 偏小、
 * 服务端可能截断读取。此类场景传 skipContentLength=true 跳过自动设置，由鸿蒙 http 库按
 * body 实际字节填充（与原直接 http.createHttp 不设 Content-Length 的行为一致）。
 *
 * throttler 时序：首次 acquire(hostname)；首次成功则 finally 兜底 release(hostname)；
 * 首次失败立即 release + 置 released=true，重试各域名单独 acquire/finally release。
 *
 * @param path - API 路径
 * @param params - query 参数
 * @param method - HTTP 方法
 * @param body - 请求体（POST 时）
 * @param cookies - 会话 cookie（可选）
 * @param extraHeaders - 额外 header（可选）
 * @param baseUrl - 调用方传入的基础 URL；空串则首次/重试均用 DOMAINS 轮换
 * @param skipContentLength - 为 true 时跳过 POST 的 Content-Length 自动设置，供 multipart
 *   含非 ASCII body 的场景（如 loginPassword）让传输库按实际字节填充；默认 false
 * @param allowRetry - 为 false 时关闭「失败后轮换域名重试」。**写操作必须为 false**：
 *   请求可能已到达服务端，重试会造成重复发帖 / 重复回复（不可逆的数据事故）。
 *   重试之间带指数退避（见 NgaThrottleSignals.retryDelayMs），不再是失败即连打。
 * @param throttle - 本次请求使用的限流器；默认全站 {@link ngaThrottler}。树页一次性
 *   批量读取会传入专用实例（更宽的滑动窗口），但**冷却闸门仍是全局的**：所有实例都
 *   在 `ngaRequest` 入口检查 `ngaThrottler` 的冷却状态，风控命中后不会绕开。
 * @returns HTTP 响应（status + ArrayBuffer body）
 */
async function executeWithRetry(
  path: string,
  params: Record<string, string>,
  method: http.RequestMethod,
  body: string,
  cookies: Cookies | undefined,
  extraHeaders: Record<string, string> | undefined,
  baseUrl: string,
  skipContentLength: boolean = false,
  allowRetry: boolean = true,
  throttle: Throttler = ngaThrottler
): Promise<HttpResponse> {
  const resolvedBaseUrl: string = baseUrl || DOMAINS[activeDomainIndex];
  const hostname: string = extractHostname(resolvedBaseUrl);

  const url: string = buildUrl(resolvedBaseUrl, path, params);
  const header: Record<string, string> = {
    'User-Agent': 'NGA_WP_JW',
    'X-User-Agent': 'Nga_Official',
  };

  if (extraHeaders) {
    const keys = Object.keys(extraHeaders);
    for (let i = 0; i < keys.length; i++) {
      header[keys[i]] = extraHeaders[keys[i]];
    }
  }

  if (cookies) {
    header['Cookie'] = `ngaPassportUid=${cookies.uid}; ngaPassportCid=${cookies.cid}`;
  }

  if (method === http.RequestMethod.POST) {
    if (body && !header['Content-Type']) {
      header['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    if (!skipContentLength && !header['Content-Length']) {
      header['Content-Length'] = body ? String(body.length) : '0';
    }
  }

  let released: boolean = false;
  let response: HttpResponse = { status: 0, body: new ArrayBuffer(0) };
  let firstErrorMsg: string = '';

  // 冷却期在 acquire 处直接 reject。acquire 必须放在 try/finally **之外**：
  // reject 时尚未占用槽位，若进了 finally 的 release，会误释放别的请求的槽位。
  await throttle.acquire(hostname);

  try {
    try {
      response = await httpReq(url, method, header, body);
    } catch (firstError) {
      firstErrorMsg = (firstError as Error).message;
      throttle.release(hostname);
      released = true;

      // 写操作不自动重试：请求可能已经被服务端处理，重试等于重复提交。
      // 明确告诉调用方「结果未知」，让它提示用户核对，而不是悄悄再发一次。
      if (!allowRetry) {
        throw new Error('请求未完成（写操作不自动重试，请确认操作是否已生效）: ' + firstErrorMsg);
      }

      // 重试前复查全局冷却：首请求失败与重试之间，别的请求可能已经触发风控拉闸。
      // 独立限流桶（树页）不会自己进入冷却，这一步保证重试也不会绕开闸门。
      if (ngaThrottler.isCoolingDown()) {
        throw new Error(THROTTLE_COOLDOWN_MARKER + '请求过于频繁，请稍后重试');
      }

      let retrySuccess = false;
      for (let i = 1; i < DOMAINS.length; i++) {
        const retryDomainIdx = (activeDomainIndex + i) % DOMAINS.length;
        const retryBaseUrl = baseUrl || DOMAINS[retryDomainIdx];
        const retryHostname = extractHostname(retryBaseUrl);

        // 退避后才重试：失败即连打多个域名是最容易被判定为攻击的形态
        await sleep(retryDelayMs(i));
        await throttle.acquire(retryHostname);
        try {
          const retryUrl = buildUrl(retryBaseUrl, path, params);
          response = await httpReq(retryUrl, method, header, body);
          retrySuccess = true;
          break;
        } catch (retryError) {
          firstErrorMsg = (retryError as Error).message;
        } finally {
          throttle.release(retryHostname);
        }
      }

      if (!retrySuccess) {
        throw new Error(`请求失败: ${firstErrorMsg}`);
      }
    }
    return response;
  } finally {
    if (!released) {
      throttle.release(hostname);
    }
  }
}

/**
 * 等待指定毫秒数。
 *
 * @param ms - 毫秒
 * @returns 等待完成的 Promise
 */
function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => resolve(), ms);
  });
}

/**
 * 构造风控冷却期的标准失败响应。
 *
 * 复用项目既有的「通用业务错误码」协议（`error_code: 15` = 频率限制，见
 * `parser/ErrorParser.ets` 文件头），而不是自造 `__throttled` 之类的新字段：
 * 业务层与 ErrorParser 已经认这条通道，新字段只会变成一个没有消费者的标记。
 *
 * 形状与正常业务错误一致（`error['0']` 是可读文案），现有业务层无需任何改动即可展示。
 *
 * @param remainingMs - 剩余冷却时长
 * @returns 失败响应对象
 */
function buildThrottledResponse(remainingMs: number): Record<string, Object> {
  const seconds: number = Math.max(1, Math.ceil(remainingMs / 1000));
  const message: string = 'NGA 接口触发频率限制，已暂停请求约 ' + seconds.toString() +
    ' 秒（风控保护）。请稍后重试；如需继续浏览，可减少一次读取的页数与楼层数。';
  const errorMap: Record<string, string> = {};
  errorMap['0'] = message;
  const result: Record<string, Object> = {};
  result['error'] = errorMap as Object;
  result['error_code'] = 15 as Object;
  return result;
}

/**
 * 标记一次风控命中：拉闸进入冷却，并返回标准失败响应。
 *
 * @param path - 命中的接口路径（仅用于日志）
 * @returns 标准失败响应
 */
function throttledByMessage(path: string): Record<string, Object> {
  ngaThrottler.enterCooldown(DEFAULT_THROTTLE_COOLDOWN_MS);
  logger.warn('[NGA][THROTTLE] 风控文案命中，进入 %{public}d ms 冷却: %{public}s',
    DEFAULT_THROTTLE_COOLDOWN_MS, path);
  return buildThrottledResponse(DEFAULT_THROTTLE_COOLDOWN_MS);
}

// ============== 鉴权失效信号 ==============

/**
 * 鉴权失效信号回调（由 AppStore 在启动时注册）。
 *
 * 网络层只负责"识别并上报"，**不**清登录态、**不**跳页面：判断与处置属于
 * `SessionGuard`（去抖 + iflogin 二次确认），避免单个业务错误直接把用户踢下线。
 */
let authFailureHandler: ((message: string) => void) | null = null

/**
 * 注册鉴权失效信号回调（幂等；重复注册覆盖）。
 *
 * @param handler - 收到"疑似未登录"信号时的回调；传 null 取消注册
 */
export function setAuthFailureHandler(handler: ((message: string) => void) | null): void {
  authFailureHandler = handler
}

/**
 * 若响应里出现"未登录/会话失效"信号，上报给已注册的回调。
 *
 * @param raw - 已解析的响应对象
 */
function emitAuthFailure(raw: object): void {
  if (authFailureHandler === null) {
    return;
  }
  const message: string | null = classifyAuthFailure(raw);
  if (message !== null) {
    logger.verbose('[NGA][AUTH] 响应含未登录信号: %{public}s', message);
    authFailureHandler(message);
  }
}

// ============== 写操作本地门禁 ==============

/**
 * 写操作本地门禁（由 AppStore 在启动时注册）。
 *
 * 只在**写接口**上生效（判定复用 `NgaThrottleSignals.isWritableOperation` 的读写白名单，
 * 默认「不在只读清单里的一律按写处理」）：返回 null 表示放行，返回非空串表示拦截原因。
 *
 * 为什么放在网络层而不是各个 UI 入口：写操作入口散落在多个面板与三个编辑器管理器里
 * （回复/发帖/贴条/编辑/赞踩/投票/收藏/关注/私信/签到/子版块订阅），逐个加检查必然漏改；
 * 而所有写请求都要经过本通道，一处拦截即可全覆盖。被拦下的请求**不会真正发出**，
 * 避免在服务端异常期间制造无效请求、叠加风控计数。
 */
type WriteGuard = () => string | null

let writeGuard: WriteGuard | null = null

/**
 * 注册写操作本地门禁（幂等；重复注册覆盖）。
 *
 * @param guard - 返回拦截原因的回调；传 null 取消注册
 */
export function setWriteGuard(guard: WriteGuard | null): void {
  writeGuard = guard
}

/**
 * 构造"被本地门禁拦截"的失败响应。
 *
 * 形状必须**同时**覆盖三类调用方的判读方式，缺一类就会把拦截误判成成功：
 * - 按 `code` 判定的（如签到 `Number(raw['code'] ?? 0) === 0` 即成功）→ 必须给非 0 的 `code`；
 * - 按 `msg` 取文案的（`readAppError` 在 code 非 0 时读 `msg`）；
 * - 按 `error['0']` 取文案的（`parseNgaError`、网页通道形态）。
 *
 * 另带 `__localBlocked` 标记，让 `classifyAuthFailure` 不把它误当成服务端的未登录信号
 * （否则降级态会被自己的拦截反复"确认"，形成信号回环）。
 *
 * @param message - 拦截原因（面向用户）
 * @returns 失败响应对象
 */
export function buildBlockedResponse(message: string): Record<string, Object> {
  const errorMap: Record<string, string> = {};
  errorMap['0'] = message;
  const result: Record<string, Object> = {};
  result['code'] = 1 as Object;
  result['msg'] = message as Object;
  result['error'] = errorMap as Object;
  result['__localBlocked'] = true as Object;
  return result;
}

/**
 * 读取当前写操作门禁的拦截原因（供不走 `postSigned` 的写通道复用）。
 *
 * 附件上传（`NgaUploader`）是独立的 multipart 请求，不经过 `postSigned`，因此拿不到
 * 上面的拦截；它的调用方在 `ThreadWriteApi.uploadAttachment` 等处用本函数补同一层判断。
 *
 * @returns 拦截原因；放行时返回 null
 */
export function getWriteBlockReason(): string | null {
  if (writeGuard === null) {
    return null;
  }
  return writeGuard();
}

// ============== NGA 核心 ==============

/**
 * 构造官方 APP 签名接口的 POST body 字段（公共参数 + 业务参数）。
 *
 * 公共参数（app_id/access_uid/access_token/t/sign/__output/__inchst）与业务参数
 * 全部进 POST body（urlencoded）；签名 `sign = MD5(app_id+access_uid+access_token+
 * signParams+t+secret)`。access_uid = session uid，access_token = session cid。
 *
 * @param params - 业务参数
 * @param cookies - 会话 cookie（提供 access_uid/access_token）
 * @param signParams - 参与签名的参数值拼接（addSignParams；无则空串）
 * @param output - __output 值（'14'=build 默认，'12'=buildNew 默认）
 * @param inchst - __inchst 值
 * @returns POST body 字段
 */
function buildSignedFields(params: Record<string, string>, cookies: Cookies | undefined,
  signParams: string, output: string, includeClientChecksum: boolean = false,
  inchst: string = 'utf-8'): Record<string, string> {
  const ts: string = String(Math.floor(Date.now() / 1000));
  const accessUid: string = cookies ? cookies.uid : '';
  const accessToken: string = cookies ? cookies.cid : '';
  const fields: Record<string, string> = {
    '__output': output,
    '__inchst': inchst,
    'app_id': NGA_APP_ID,
    'access_uid': accessUid,
    'access_token': accessToken,
    't': ts,
    'sign': makeSign({ accessUid: accessUid, accessToken: accessToken, signParams: signParams, ts: ts }),
  };
  if (includeClientChecksum) {
    fields['__ngaClientChecksum'] = makeClientChecksum({ uid: accessUid, ts: ts });
  }
  const keys = Object.keys(params);
  for (let i = 0; i < keys.length; i++) {
    fields[keys[i]] = params[keys[i]];
  }
  return fields;
}

/**
 * 官方 APP 签名接口的完整认证头。
 *
 * ngaRequest 默认只有 NGA_WP_JW/X-User-Agent+Cookie，缺 X-NGA-* 会被服务端拒/
 * 签名错误，官方接口即失败。这里与 nga-hack nga-client buildHeaders 对齐：
 * Nga_Official 版本头 + 认证头。
 *
 * @returns 认证头
 */
function buildSignedHeaders(): Record<string, string> {
  const extraHeaders: Record<string, string> = {
    'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
    'User-Agent': 'Mozilla/5.0 (Linux; Android 10; NOH-AN00 Build/HUAWEINOH-AN00; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/83.0.4103.106 Mobile Safari/537.36 Nga_Official/7.17.17',
    'X-Requested-With': 'gov.pianzong.androidnga',
    'X-USER-AGENT': 'Nga_Official/7.17.17(HUAWEI NOH-AN00;Android 10)',
    'X-NGA-CHANNEL': 'official',
    'X-NGA-VERSION-NAME': '7.17.17',
    'X-NGA-VERSION-CODE': '71717',
    'Referer': 'https://ngabbs.com/',
  };
  return extraHeaders;
}

/**
 * 官方 APP 签名 POST 的公共发送原语。
 *
 * skipInchst=true：query 不含 __inchst（__inchst 已由 fields 进入 body），与官方 appPost 一致。
 * baseUrl 固定 ngabbs.com：官方接口在 ngabbs.com 有效（bbs.nga.cn 上部分接口返回
 * 「未定义服务」，实测）；不走 DOMAINS 轮换。
 *
 * @param path - 请求路径（如 /thread.php、/nuke.php、/app_api.php）
 * @param qparams - URL query 参数（带 __lib/__act 的接口由调用方传入；thread.php 无此参数）
 * @param fields - POST body 字段（buildSignedFields 构造）
 * @param cookies - 会话 cookie
 * @param utf8Response - 响应体解码方式：`true`（默认）按 UTF-8，`false` 按 GB18030。
 *   App 签名通道的官方接口（__output=12/14/17）恒返回 UTF-8；但 `read.php __output=8`
 *   的服务端响应标注 `encode:"GBK"`，实测 `__inchst` 与 Content-Type charset 都改不动它，
 *   必须按 GB18030 解码，否则中文主题标题会整段变成替换字符（见 postSignedPathGb）。
 * @param allowRetry - 是否允许失败后轮换域名重试（写操作必须为 false）
 * @param throttle - 限流器（默认全站）
 * @returns NGA JSON 响应
 */
async function ngaPostSignedCore(path: string, qparams: Record<string, string>,
  fields: Record<string, string>, cookies: Cookies | undefined,
  utf8Response: boolean = true, allowRetry: boolean = true,
  throttle: Throttler = ngaThrottler): Promise<object> {
  const extraHeaders: Record<string, string> = buildSignedHeaders();
  return ngaRequest(path, http.RequestMethod.POST, qparams,
    buildEncodedBody(fields), cookies, 'https://ngabbs.com', extraHeaders, true, utf8Response,
    allowRetry, throttle);
}

/**
 * App 签名接口（POST form + access_uid/access_token/sign），__lib/__act 放 URL query。
 *
 * 对应官方客户端 appPost：`__lib/__act` 放 URL query（`<host>/<path>?__lib=..&__act=..`），
 * 其余公共参数（app_id/access_uid/access_token/t/sign/__output/__inchst）与业务参数
 * 放 POST body（urlencoded）。
 *
 * 鸿蒙端实测：把 `__lib/__act` 放 body 时 app_api.php 返回 `{"code":2,"msg":"未定义服务"}`，
 * 放 URL query 才被识别（与 nga-hack nga-client 结论一致）。该方法供官方接口
 * （首页分类 app_api.php home/category、版块搜索 app_api.php forum/search、
 * 版面主题列表/搜索 app_api.php subject/list|search（SUBJECT_LIST/SUBJECT_SEARCH）、
 * 子版块订阅切换 app_api.php subject/subscription、用户发帖回帖 app_api.php
 * user/subjects|replys、私信 app_api.php message/list|detail、
 * 通知 app_api.php notify/list、关注动态 nuke.php follow_v2/get_push_list、
 * 关注/取关与关注/粉丝列表 nuke.php follow_v2/follow|get_follow|get_follow_by、
 * 发帖分类与推荐 app_api.php post/titletype|recommend、投票 app_api.php subject/vote、
 * 签到 nuke.php check_in/check_in、
 * 主题收藏夹 nuke.php topic_favor_v2/list_folder|new_folder|modify_folder|
 * del_folder|add|del、收藏夹内主题列表 app_api.php favor/all 等）使用，
 * 是官方 APP 签名接口的统一通道。
 *
 * @param path - 请求路径（如 /nuke.php、/app_api.php）
 * @param lib - __lib 值
 * @param act - __act 值
 * @param params - 业务参数（进 body）
 * @param cookies - 会话 cookie（提供 access_uid/access_token 与 Cookie 头）
 * @param signParams - 参与签名的参数值拼接（addSignParams，如用户主题/回帖 = 目标 uid；无则空串）
 * @param output - __output，默认 '12'
 * @param includeClientChecksum - 是否加入官方帖子提交使用的客户端校验和
 * @param inchst - __inchst 值；轻量 post/reply 评论接口显式传空串
 */
async function ngaPostSigned(path: string, lib: string, act: string,
  params: Record<string, string>, cookies: Cookies | undefined,
  signParams: string, output: string, includeClientChecksum: boolean = false,
  inchst: string = 'utf-8'): Promise<object> {
  const fields: Record<string, string> = buildSignedFields(
    params, cookies, signParams, output, includeClientChecksum, inchst
  );
  const qparams: Record<string, string> = { '__lib': lib, '__act': act };
  // 写操作与带客户端校验和的提交一律不自动重试：它们已经在服务端产生副作用，
  // 重试就是重复提交。判定集中在 NgaThrottleSignals.isWritableOperation。
  const allowRetry: boolean = !includeClientChecksum && !isWritableOperation(lib, act);
  return ngaPostSignedCore(path, qparams, fields, cookies, true, allowRetry);
}

/**
 * App 签名接口（POST form + access_uid/access_token/sign），**无 __lib/__act**。
 *
 * 用于 read.php 官方帖子内容（卡片 R1：`read.php?` 无 `__lib/__act`、
 * 无 addSignParams）。请求形态与 ngaPostSigned 完全一致（公共参数 + 业务
 * 参数进 body，完整认证头，ngabbs.com），仅 URL 不拼 __lib/__act。
 * （版面主题列表/搜索已随迁移切换至 app_api.php subject/list|search，
 * 不再使用本通道。）
 *
 * 本通道固定是只读的 read.php，因此**允许失败重试**（不经 isWritableOperation 判定）；
 * 若将来有写语义的接口复用本函数，必须显式传 allowRetry=false。
 *
 * read.php 帖子详情使用 `POST + sign + signParams='' + __output=17`，返回官方 Article 包装
 * `{code:521,htmlBaseUrl,htmlTitle,html,msg,template:"read"}`，html 是完整帖子页面，
 * 供客户端 HTML 解析使用。
 *
 * @param path - 请求路径（如 /read.php）
 * @param params - 业务参数（进 body）
 * @param cookies - 会话 cookie（提供 access_uid/access_token 与 Cookie 头）
 * @param signParams - 参与签名的参数值拼接（read.php 无 addSignParams → 传空串）
 * @param output - __output，默认 '14'（read.php 帖子详情传 '17'）
 * @param throttle - 本次请求使用的限流器（默认全站；树页批量读取传专用实例）
 * @returns NGA JSON 响应
 */
async function ngaPostSignedPath(path: string, params: Record<string, string>,
  cookies: Cookies | undefined, signParams: string, output: string,
  throttle?: Throttler): Promise<object> {
  const fields: Record<string, string> = buildSignedFields(params, cookies, signParams, output);
  return ngaPostSignedCore(path, emptyStringRecord(), fields, cookies, true, true,
    throttle !== undefined ? throttle : ngaThrottler);
}

/**
 * App 签名接口（POST form + access_uid/access_token/sign），**响应按 GB18030 解码**。
 *
 * 与 {@link ngaPostSignedPath} 完全同形，只有响应解码方式不同：`read.php` 的
 * `__output=8` 通道服务端固定以 GBK 返回（响应体自带 `"encode":"GBK"`，实测
 * `__inchst=UTF8`、`Content-Type: …charset=GBK`、空 `__inchst` 三种写法均不改变），
 * 而签名通道默认按 UTF-8 解码，直接读会把中文标题解成替换字符。
 *
 * 用途：跟踪帖子更新的轻量状态查询（`__output=8` 响应约 20KB，且直接带
 * `__T.replies/lastpost/subject/locked`，无需 HTML 解析）。
 *
 * @param path - 请求路径（当前仅 /read.php）
 * @param params - 业务参数（进 body）
 * @param cookies - 会话 cookie（提供 access_uid/access_token 与 Cookie 头）
 * @param signParams - 参与签名的参数值拼接（read.php 无 addSignParams → 传空串）
 * @param output - __output 值（read.php 状态查询传 '8'）
 * @param throttle - 本次请求使用的限流器（默认全站）
 */
async function ngaPostSignedPathGb(path: string, params: Record<string, string>,
  cookies: Cookies | undefined, signParams: string, output: string,
  throttle?: Throttler): Promise<object> {
  const fields: Record<string, string> = buildSignedFields(params, cookies, signParams, output);
  return ngaPostSignedCore(path, emptyStringRecord(), fields, cookies, false, true,
    throttle !== undefined ? throttle : ngaThrottler);
}

async function ngaGetRaw(path: string, params: Record<string, string>,
  extraHeaders?: Record<string, string>): Promise<ArrayBuffer> {
  const result = await rawRequest(path, http.RequestMethod.GET, params, '', extraHeaders);
  return result;
}

export interface Cookies {
  uid: string;
  cid: string;
}

/**
 * NGA API 核心请求。
 *
 * 在 {@link executeWithRetry} 之上统一负责三件事：
 * 1. **风控前置**：冷却期内直接返回可读失败响应，不发请求、不排长队；
 * 2. **风控识别**：HTTP 429 与「过于频繁 / 刷新太快」类文案都会拉闸进冷却，
 *    因为 NGA 的限流大多是 200 + HTML 提示页，只看状态码会完全漏掉；
 * 3. **响应解码与解析**：UTF-8 / GB18030、script store 提取、HTML 错误页归一化。
 *
 * @param path - API 路径
 * @param method - HTTP 方法
 * @param params - query 参数
 * @param body - 请求体
 * @param cookies - 会话 cookie
 * @param baseUrl - 基础 URL（空串走 DOMAINS 轮换）
 * @param extraHeaders - 额外 header
 * @param skipInchst - 是否跳过自动注入 __inchst
 * @param utf8Response - 是否按 UTF-8 解码（false 走 GB18030）
 * @param allowRetry - 是否允许失败后轮换域名重试（写操作必须为 false）
 * @param throttle - 本次请求使用的限流器（默认全站；树页批量读取传专用实例）
 * @returns NGA 响应对象
 */
async function ngaRequest(path: string, method: http.RequestMethod,
  params: Record<string, string>, body: string,
  cookies: Cookies | undefined, baseUrl: string,
  extraHeaders: Record<string, string> | undefined,
  skipInchst: boolean = false, utf8Response: boolean = false,
  allowRetry: boolean = true, throttle: Throttler = ngaThrottler): Promise<object> {
  if (!skipInchst && !params['__inchst']) {
    params['__inchst'] = 'UTF8';
  }

  // 冷却期内不发请求：既省一次握手，也让调用方立刻拿到可读原因。
  // 只做「读」的快速失败，避免在已被限流的状态下继续重试、把惩罚窗口拉长。
  const cooldownBefore: number = ngaThrottler.cooldownRemainingMs();
  if (cooldownBefore > 0) {
    return buildThrottledResponse(cooldownBefore);
  }

  // baseUrl 由调用方传入：常为空串，使 executeWithRetry 重试时遍历 DOMAINS 轮换。
  let response: HttpResponse;
  try {
    response = await executeWithRetry(
      path, params, method, body, cookies, extraHeaders, baseUrl, false, allowRetry, throttle
    );
  } catch (netError) {
    const message: string = (netError as Error).message;
    // 重试途中撞上冷却：翻译成标准失败响应，而不是把带标记的内部错误抛给业务层
    if (isThrottleCooldownMessage(message)) {
      return buildThrottledResponse(ngaThrottler.cooldownRemainingMs());
    }
    // ArkTS 不允许 throw 任意类型（arkts-limited-throw），重新包一层 Error 保留原文案
    throw new Error(message);
  }

  if (response.status === 429) {
    ngaThrottler.enterCooldown(DEFAULT_THROTTLE_COOLDOWN_MS);
    logger.warn('[NGA][THROTTLE] 429 from %{public}s', path);
    return buildThrottledResponse(DEFAULT_THROTTLE_COOLDOWN_MS);
  }

  const rawText: string = utf8Response ? decodeUtf8(response.body) : decodeGb18030(response.body);
  logChunks('[NGA][RES] body:', rawText);

  // 注意：这里**不做全文风控匹配**。NGA 的帖子正文完全可能包含「过于频繁」这类词
  // （技术讨论、反馈帖），对整段 200 响应全文匹配会让读到一个普通帖子就把全站拖进
  // 60 秒冷却。风控只在「错误形态」上判定：HTML 错误页的提示文案、或 JSON 的 error 字段。

  // 部分接口（如 ucp/get）成功时也返回 HTML 包裹的
  // <script>window.script_muti_get_var_store={...}</script> 而非纯 JSON；
  // 必须先于「HTML 错误页」判定识别该形态，否则会被误判为错误页。
  const storeJson: string | null = extractScriptStoreJson(rawText);
  if (storeJson !== null) {
    const storeText = preprocessJson(storeJson);
    try {
      const storeParsed: Record<string, Object> = JSON.parse(storeText) as Record<string, Object>;
      if (hasThrottleSignal(storeParsed)) {
        return throttledByMessage(path);
      }
      return storeParsed;
    } catch (storeParseError) {
      // 提取成功但解析失败：落入后续 HTML/JSON 处理，保留原始错误信息
    }
  }

  // 处理 HTML 错误页
  const trimmed = rawText.trimStart();
  if (trimmed.startsWith('<!DOCTYPE') || trimmed.startsWith('<html')) {
    const msgMatch = rawText.match(/<!--msginfostart-->([\s\S]*?)<!--msginfoend-->/);
    const codeMatch = rawText.match(/<!--msgcodestart-->(\d+)<!--msgcodeend-->/);
    const titleMatch = rawText.match(/<title>([\s\S]*?)<\/title>/);
    const htmlError = msgMatch ? msgMatch[1].replace(/<[^>]+>/g, '').trim()
      : titleMatch ? titleMatch[1].trim()
      : '服务器返回了非预期的HTML页面';

    // 只在错误页的提示文案上判定风控，覆盖面既够（真实限流就是错误页）又不误伤正文
    if (looksLikeThrottle(htmlError)) {
      return throttledByMessage(path);
    }

    const errObj: Record<string, string> = { '0': htmlError };
    const result: Record<string, Object> = { 'error': errObj as Object };
    if (codeMatch) {
      const codeNum = Number(codeMatch[1]);
      result['error_code'] = codeNum as Object;
    }
    return result;
  }

  // JSON 处理
  const text = preprocessJson(rawText);
  try {
    const parsed: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
    if (hasThrottleSignal(parsed)) {
      return throttledByMessage(path);
    }
    return parsed;
  } catch (parseError) {
    const errResult: Record<string, Object> = {
      '__parseError': true as Object,
      '__rawLength': text.length as Object,
      'error': new Error((parseError as Error).message) as Object,
    };
    return errResult;
  }
}

async function rawRequest(path: string, method: http.RequestMethod,
  params: Record<string, string>, body: string,
  extraHeaders: Record<string, string> | undefined): Promise<ArrayBuffer> {
  const baseUrl = DOMAINS[activeDomainIndex];
  const url = buildUrl(baseUrl, path, params);
  const header: Record<string, string> = {
    'User-Agent': 'NGA_WP_JW',
    'X-User-Agent': 'Nga_Official',
  };
  if (extraHeaders) {
    const keys = Object.keys(extraHeaders);
    for (let i = 0; i < keys.length; i++) {
      header[keys[i]] = extraHeaders[keys[i]];
    }
  }
  const httpResult = await httpReq(url, method, header, body);
  return httpResult.body;
}

// ============== 公共接口 ==============

interface INgaClient {
  /** App 签名接口（POST form + access_uid/access_token/sign），__lib/__act 放 URL query。 */
  postSigned: (path: string, lib: string, act: string, params: Record<string, string>,
    cookies: Cookies | undefined, signParams: string, output: string,
    includeClientChecksum?: boolean, inchst?: string, signalAuthFailure?: boolean) => Promise<object>;
  /** App 签名接口（POST form + access_uid/access_token/sign），无 __lib/__act（thread.php 官方通道）。 */
  postSignedPath: (path: string, params: Record<string, string>,
    cookies: Cookies | undefined, signParams: string, output: string,
    throttle?: Throttler) => Promise<object>;
  /** App 签名接口，响应按 GB18030 解码（read.php __output=8 跟踪状态查询通道）。 */
  postSignedPathGb: (path: string, params: Record<string, string>,
    cookies: Cookies | undefined, signParams: string, output: string) => Promise<object>;
  getCaptchaV2: (captchaId: string) => Promise<string>;
  loginPassword: (loginParams: LoginParams) => Promise<LoginResultData>;
  logout: (cookies: Cookies) => Promise<void>;
  getActiveDomain: () => string;
  setActiveDomainIndex: (index: number) => void;
  getDomainList: () => string[];
}

const client: INgaClient = {
  async postSigned(path: string, lib: string, act: string,
    params: Record<string, string>, cookies: Cookies | undefined,
    signParams: string, output: string, includeClientChecksum: boolean = false,
    inchst: string = 'utf-8', signalAuthFailure: boolean = true): Promise<object> {
    // 写操作本地门禁：降级态（服务端已明确拒绝当前凭证）下不再把写请求发出去。
    // 读接口不受影响 —— NGA 各接口的会话校验强度不一致，读能力要留给服务端回答。
    if (writeGuard !== null && isWritableOperation(lib, act)) {
      const blocked: string | null = writeGuard();
      if (blocked !== null) {
        logger.verbose('[NGA][GUARD] 写操作被本地门禁拦截: %{public}s/%{public}s', lib, act);
        return buildBlockedResponse(blocked);
      }
    }
    const raw: object = await ngaPostSigned(path, lib, act, params, cookies, signParams, output,
      includeClientChecksum, inchst);
    // 轮询类调用（通知/关注动态）显式传 false：后台轮询撞上未登录不应打断用户。
    if (signalAuthFailure) {
      emitAuthFailure(raw);
    }
    return raw;
  },

  async postSignedPath(path: string, params: Record<string, string>,
    cookies: Cookies | undefined, signParams: string, output: string,
    throttle?: Throttler): Promise<object> {
    return ngaPostSignedPath(path, params, cookies, signParams, output, throttle);
  },

  async postSignedPathGb(path: string, params: Record<string, string>,
    cookies: Cookies | undefined, signParams: string, output: string): Promise<object> {
    return ngaPostSignedPathGb(path, params, cookies, signParams, output);
  },

  async getCaptchaV2(captchaId: string): Promise<string> {
    const params: Record<string, string> = { 'id': captchaId, 'from': 'login' };
    const headers: Record<string, string> = {
      'Referer': 'https://bbs.nga.cn/nuke/account_copy.html?login',
    };
    const buffer = await ngaGetRaw('/login_check_code.php', params, headers);
    const base64 = uint8ArrayToBase64(new Uint8Array(buffer));
    return `data:image/png;base64,${base64}`;
  },

  async loginPassword(loginParams: LoginParams): Promise<LoginResultData> {
    const encryptedPassword = await encryptPassword(loginParams.password);

    const fields: Record<string, string> = {
      '__lib': 'login',
      '__output': '1',
      '__act': 'login',
      '__inchst': 'UTF-8',
      'app_id': '5004',
      'device': '',
      'name': loginParams.username,
      'type': loginParams.type,
      'password': encryptedPassword,
      'rid': loginParams.captchaId,
      'captcha': loginParams.captcha.toUpperCase(),
    };

    const mp = buildMultipart(fields);
    const extraHeaders: Record<string, string> = {
      'Referer': 'https://bbs.nga.cn/nuke/account_copy.html?login',
      'Origin': 'https://bbs.nga.cn',
      'Content-Type': mp.contentType,
      'Accept': '*/*',
    };

    // 走统一通道（executeWithRetry），获得 ngaThrottler 限流保护；
    // 但登录是写操作，**不自动重试**（重试会重复消耗验证码，也可能被判为暴力尝试）。
    // 关键参数：
    // - baseUrl 固定为 'https://bbs.nga.cn'，executeWithRetry 重试不轮换域名（保持原硬编码行为）；
    // - path='/nuke.php'，buildUrl(baseUrl, path, {}) 拼得 'https://bbs.nga.cn/nuke.php'，与原硬编码 URL 一致；
    // - Content-Type 放在 extraHeaders，executeWithRetry 的 POST 分支只在 !header['Content-Type']
    //   时才覆盖为 urlencoded，故 multipart 的 Content-Type 不会被破坏；
    // - skipContentLength=true：multipart body 可能含非 ASCII（如中文用户名），body.length（UTF-16
    //   字符数）会小于实际 UTF-8 字节数导致 Content-Length 偏小、服务端截断读取。跳过自动设置，
    //   由鸿蒙 http 库按 multipart body 实际字节填充，与原直接 http.createHttp 不设 Content-Length 的
    //   行为完全一致，ASCII/中文用户名均安全；
    // - cookies 传 undefined（登录前无会话），不会注入 Cookie 头；
    // - executeWithRetry 不注入 __inchst（那是 ngaRequest :337-338 做的），故登录请求体不会被改动。
    let response: HttpResponse;
    try {
      response = await executeWithRetry(
        '/nuke.php',
        emptyStringRecord(),
        http.RequestMethod.POST,
        mp.body,
        undefined,
        extraHeaders,
        'https://bbs.nga.cn',
        true,
        // 登录是写操作：重试会重复消耗验证码，且可能让服务端判定为暴力尝试
        false,
      );
    } catch (loginError) {
      const message: string = (loginError as Error).message;
      // 冷却闸门的错误带内部标记（[NGATHROTTLE]），不能原样渲染给用户
      if (isThrottleCooldownMessage(message)) {
        const throttledResult: LoginResultData = {
          success: false, uid: '', cid: '',
          error: '登录请求过于频繁，请稍后再试', setCookies: [],
        };
        return throttledResult;
      }
      throw new Error(message);
    }

    const bodyText = decodeGb18030(response.body);
    const setCookieHeader = response.header
      ? response.header['set-cookie'] as string | string[] | undefined
      : undefined;
    const cookies: string[] = normalizeCookieList(setCookieHeader);
    const sessionCookie = parseSessionCookies(setCookieHeader);
    let uid = sessionCookie.uid;
    let cid = sessionCookie.cid;

    if (!uid || !cid) {
      const cleaned = preprocessJson(bodyText);
      let parsed: Record<string, Object> | null = null;
      try { parsed = JSON.parse(cleaned) as Record<string, Object>; } catch (e) { logger.error('loginPassword JSON parse (uid/cid fallback) failed: %{public}s', formatError(e)); }      const parsedData = parsed?.['data'] as Record<string, Object> | undefined;
      if (parsedData && parsedData['1'] && parsedData['2']) {
        uid = String(parsedData['1']);
        cid = String(parsedData['2']);
      }
    }

    if (uid && cid) {
      const result: LoginResultData = {
        success: true, uid, cid, error: '', setCookies: cookies,
      };
      return result;
    }

    const cleaned = preprocessJson(bodyText);
    let parsed: Record<string, Object> | null = null;
    try { parsed = JSON.parse(cleaned); } catch (e) { logger.error('loginPassword JSON parse (error fallback) failed: %{public}s', formatError(e)); }
    const errorObj = parsed?.['error'] as Record<string, string> | undefined;
    const errorMsg = errorObj?.['0'] ?? bodyText.slice(0, 300);

    const failResult: LoginResultData = {
      success: false, uid: '', cid: '', error: errorMsg, setCookies: cookies,
    };
    return failResult;
  },

  async logout(cookies: Cookies): Promise<void> {
    // 官方映射（ct_d_pswitch_map pswitch_683）：nuke.php?__lib=login&__act=logout。
    // 登录系接口不走标准签名（卡片 7：无 access_uid/access_token/t/sign），cookie 认证即可；
    // 官方 App 主流程以本地清态为主（H5 网页登出为辅），此处为服务端会话通知。
    const params: Record<string, string> = {
      '__lib': 'login',
      '__act': 'logout',
      '__output': '1',
    };
    // 登出是写操作（服务端会话通知）：不自动重试，避免重复提交。
    await ngaRequest('/nuke.php', http.RequestMethod.GET, params, '', cookies, '', undefined,
      true, false, false);
  },

  getActiveDomain(): string {
    return DOMAINS[activeDomainIndex];
  },

  setActiveDomainIndex(index: number): void {
    if (index >= 0 && index < DOMAINS.length) {
      activeDomainIndex = index;
    }
  },

  getDomainList(): string[] {
    return DOMAINS.slice();
  },
};

export const ngaClient: INgaClient = client;
