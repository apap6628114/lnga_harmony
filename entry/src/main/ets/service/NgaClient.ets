import { http } from '@kit.NetworkKit';
import { preprocessJson, extractScriptStoreJson } from '../parser/NgaJsonSanitizer';
import { ngaThrottler } from '../common/concurrency/Throttler';
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
  skipContentLength: boolean = false
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

  try {
    await ngaThrottler.acquire(hostname);
    try {
      response = await httpReq(url, method, header, body);
    } catch (firstError) {
      firstErrorMsg = (firstError as Error).message;
      ngaThrottler.release(hostname);
      released = true;

      let retrySuccess = false;
      for (let i = 1; i < DOMAINS.length; i++) {
        const retryDomainIdx = (activeDomainIndex + i) % DOMAINS.length;
        const retryBaseUrl = baseUrl || DOMAINS[retryDomainIdx];
        const retryHostname = extractHostname(retryBaseUrl);

        await ngaThrottler.acquire(retryHostname);
        try {
          const retryUrl = buildUrl(retryBaseUrl, path, params);
          response = await httpReq(retryUrl, method, header, body);
          retrySuccess = true;
          break;
        } catch (retryError) {
          firstErrorMsg = (retryError as Error).message;
        } finally {
          ngaThrottler.release(retryHostname);
        }
      }

      if (!retrySuccess) {
        throw new Error(`请求失败: ${firstErrorMsg}`);
      }
    }
    return response;
  } finally {
    if (!released) {
      ngaThrottler.release(hostname);
    }
  }
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
 * @returns NGA JSON 响应
 */
async function ngaPostSignedCore(path: string, qparams: Record<string, string>,
  fields: Record<string, string>, cookies: Cookies | undefined): Promise<object> {
  const extraHeaders: Record<string, string> = buildSignedHeaders();
  return ngaRequest(path, http.RequestMethod.POST, qparams,
    buildEncodedBody(fields), cookies, 'https://ngabbs.com', extraHeaders, true, true);
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
  return ngaPostSignedCore(path, qparams, fields, cookies);
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
 * read.php 帖子详情使用 `POST + sign + signParams='' + __output=17`，返回官方 Article 包装
 * `{code:521,htmlBaseUrl,htmlTitle,html,msg,template:"read"}`，html 是完整帖子页面，
 * 供客户端 HTML 解析使用。
 *
 * @param path - 请求路径（如 /read.php）
 * @param params - 业务参数（进 body）
 * @param cookies - 会话 cookie（提供 access_uid/access_token 与 Cookie 头）
 * @param signParams - 参与签名的参数值拼接（read.php 无 addSignParams → 传空串）
 * @param output - __output，默认 '14'（read.php 帖子详情传 '17'）
 */
async function ngaPostSignedPath(path: string, params: Record<string, string>,
  cookies: Cookies | undefined, signParams: string, output: string): Promise<object> {
  const fields: Record<string, string> = buildSignedFields(params, cookies, signParams, output);
  return ngaPostSignedCore(path, emptyStringRecord(), fields, cookies);
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
 * NGA API 核心请求
 */
async function ngaRequest(path: string, method: http.RequestMethod,
  params: Record<string, string>, body: string,
  cookies: Cookies | undefined, baseUrl: string,
  extraHeaders: Record<string, string> | undefined,
  skipInchst: boolean = false, utf8Response: boolean = false): Promise<object> {
  if (!skipInchst && !params['__inchst']) {
    params['__inchst'] = 'UTF8';
  }

  // baseUrl 由调用方传入：常为空串，使 executeWithRetry 重试时遍历 DOMAINS 轮换。
  const response: HttpResponse = await executeWithRetry(
    path, params, method, body, cookies, extraHeaders, baseUrl
  );

  const rawText: string = utf8Response ? decodeUtf8(response.body) : decodeGb18030(response.body);
  logChunks('[NGA][RES] body:', rawText);

  // 部分接口（如 ucp/get）成功时也返回 HTML 包裹的
  // <script>window.script_muti_get_var_store={...}</script> 而非纯 JSON；
  // 必须先于「HTML 错误页」判定识别该形态，否则会被误判为错误页。
  const storeJson: string | null = extractScriptStoreJson(rawText);
  if (storeJson !== null) {
    const storeText = preprocessJson(storeJson);
    try {
      return JSON.parse(storeText) as Record<string, Object>;
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
    return JSON.parse(text) as Record<string, Object>;
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
    includeClientChecksum?: boolean, inchst?: string) => Promise<object>;
  /** App 签名接口（POST form + access_uid/access_token/sign），无 __lib/__act（thread.php 官方通道）。 */
  postSignedPath: (path: string, params: Record<string, string>,
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
    inchst: string = 'utf-8'): Promise<object> {
    return ngaPostSigned(path, lib, act, params, cookies, signParams, output, includeClientChecksum, inchst);
  },

  async postSignedPath(path: string, params: Record<string, string>,
    cookies: Cookies | undefined, signParams: string, output: string): Promise<object> {
    return ngaPostSignedPath(path, params, cookies, signParams, output);
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

    // 走统一通道（executeWithRetry），获得 ngaThrottler 限流与同域名失败重试保护。
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
    const response: HttpResponse = await executeWithRetry(
      '/nuke.php',
      emptyStringRecord(),
      http.RequestMethod.POST,
      mp.body,
      undefined,
      extraHeaders,
      'https://bbs.nga.cn',
      true,
    );

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
    await ngaRequest('/nuke.php', http.RequestMethod.GET, params, '', cookies, '', undefined, true);
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
