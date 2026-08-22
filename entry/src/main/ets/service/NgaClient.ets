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
import { makeSign, NGA_APP_ID } from '../common/security/NgaSigner';

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
// gbkPercentEncode/buildEncodedBody/buildMultipart/emptyStringRecord）
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
 * ngaRequest（轮换域名）与 ngaGetHtmlText（固定域名，不轮换）逻辑同构，差异仅在
 * 调用方传入的 baseUrl：传空字符串时重试遍历 DOMAINS 轮换；传非空字符串（如
 * DOMAINS[activeDomainIndex]）时重试始终命中该域名，行为与原实现逐字等价。
 *
 * header 构造逻辑统一：User-Agent + X-User-Agent + extraHeaders(可选) + Cookie(可选) +
 * POST 时的 Content-Type/Content-Length。GET 调用方传 method=GET、body=''、
 * extraHeaders=undefined 时行为与原 ngaGetHtmlText 的 header 构造等价。
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

async function ngaGet(path: string, params: Record<string, string>,
  cookies?: Cookies, extraHeaders?: Record<string, string>): Promise<object> {
  return ngaRequest(path, http.RequestMethod.GET, params, '', cookies, '', extraHeaders);
}

async function ngaPost(path: string, body: Record<string, string>,
  cookies?: Cookies, gbkFieldKeys?: string[]): Promise<object> {
  const hasGbk: boolean = gbkFieldKeys !== undefined && gbkFieldKeys.length > 0;
  return ngaRequest(path, http.RequestMethod.POST, emptyStringRecord(),
    buildEncodedBody(body, gbkFieldKeys), cookies, '', emptyStringRecord(), hasGbk);
}

/**
 * 发送同时携带查询参数与表单正文的 NGA POST 请求。
 *
 * @param path - 请求路径
 * @param params - URL 查询参数
 * @param body - application/x-www-form-urlencoded 表单
 * @param cookies - NGA 登录 Cookie
 * @returns NGA JSON 响应
 */
async function ngaPostWithQueryAndBody(path: string, params: Record<string, string>,
  body: Record<string, string>, cookies?: Cookies): Promise<object> {
  return ngaRequest(path, http.RequestMethod.POST, params,
    buildEncodedBody(body), cookies, '', emptyStringRecord());
}

async function ngaPostWithQuery(path: string, params: Record<string, string>,
  cookies?: Cookies): Promise<object> {
  const extraHeaders: Record<string, string> = {
    'Content-Length': '0',
    'User-Agent': 'Mozilla/5.0 (Linux; Android 10; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.144 Mobile Safari/537.36',
  };
  return ngaRequest(path, http.RequestMethod.POST, params,
    '', cookies, '', extraHeaders, true);
}

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
 * @returns POST body 字段
 */
function buildSignedFields(params: Record<string, string>, cookies: Cookies | undefined,
  signParams: string, output: string): Record<string, string> {
  const ts: string = String(Math.floor(Date.now() / 1000));
  const accessUid: string = cookies ? cookies.uid : '';
  const accessToken: string = cookies ? cookies.cid : '';
  const fields: Record<string, string> = {
    '__output': output,
    '__inchst': 'utf-8',
    'app_id': NGA_APP_ID,
    'access_uid': accessUid,
    'access_token': accessToken,
    't': ts,
    'sign': makeSign({ accessUid: accessUid, accessToken: accessToken, signParams: signParams, ts: ts }),
  };
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
 * 用户发帖回帖 app_api.php user/subjects|replys、私信 app_api.php message/list|detail、
 * 通知 app_api.php notify/list、关注动态 nuke.php follow_v2/get_push_list、
 * 关注/取关与关注/粉丝列表 nuke.php follow_v2/follow|get_follow|get_follow_by、
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
 */
async function ngaPostSigned(path: string, lib: string, act: string,
  params: Record<string, string>, cookies: Cookies | undefined,
  signParams: string, output: string): Promise<object> {
  const fields: Record<string, string> = buildSignedFields(params, cookies, signParams, output);
  const qparams: Record<string, string> = { '__lib': lib, '__act': act };
  return ngaPostSignedCore(path, qparams, fields, cookies);
}

/**
 * App 签名接口（POST form + access_uid/access_token/sign），**无 __lib/__act**。
 *
 * 用于 thread.php 官方主题列表/主题搜索（卡片 R2：`thread.php?` 无 `__lib/__act`，
 * 官方客户端 kt.c.V/W/S0 走 thread.php 入口 + 公共参数签名）与 read.php 官方
 * 帖子内容（卡片 R1：`read.php?` 无 `__lib/__act`、无 addSignParams）。
 * 请求形态与 ngaPostSigned 完全一致（公共参数 + 业务参数进 body，完整认证头，
 * ngabbs.com），仅 URL 不拼 __lib/__act。
 *
 * 实测（nga-hack nga-client 探测）：POST + sign + `signParams=fid|key` + `__output=14`
 * 返回 `{"code":0,"result":{"__T":[...],"__F":{...},"__ROWS":...,"__T__ROWS_PAGE":35,...}}`；
 * signParams 传错（空/不符）返回 `{"code":5,"msg":"签名错误"}`。
 *
 * read.php 实测（鸿蒙端）：POST + sign + `signParams=''` + `__output=11` 返回与网页版
 * 同构的结构化 JSON `{data:{__CU,__GLOBAL,__U,__R,__T,__F,__R__ROWS,__R__ROWS_PAGE,
 * __ROWS,__PAGE},time}`（中文以 \uXXXX 转义，GB18030/UTF-8 解码均安全），
 * 支持 page=e（末页）、pid 定位（单帖+贴条）、authorid 只看楼主；业务错误形态
 * `{"error":["2048:找不到主题",null,null],"data":{"__MESSAGE":...}}`（error 数组）。
 * 同一 read.php 的 `__output=17` 返回官方 Article 包装
 * `{code:521,htmlBaseUrl,htmlTitle,html,msg,template:"read"}`，html 是完整帖子页面，
 * 供客户端 HTML 解析降级使用。
 *
 * @param path - 请求路径（如 /thread.php、/read.php）
 * @param params - 业务参数（进 body）
 * @param cookies - 会话 cookie（提供 access_uid/access_token 与 Cookie 头）
 * @param signParams - 参与签名的参数值拼接（thread.php 主题列表 = fid，搜索 = key；
 *   read.php 无 addSignParams → 传空串；无则空串）
 * @param output - __output，默认 '14'（thread.php 官方通道实测值；
 *   read.php JSON 传 '11'，HTML 降级传 '17'，见上）
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

async function ngaGetHtmlText(path: string, params: Record<string, string>,
  cookies?: Cookies): Promise<string> {
  // 传入 DOMAINS[activeDomainIndex]（非空），使 executeWithRetry 内的
  // retryBaseUrl = baseUrl || DOMAINS[retryDomainIdx] 永远命中 baseUrl，
  // 保持原 ngaGetHtmlText "重试不轮换域名"的行为。
  const response: HttpResponse = await executeWithRetry(
    path, params, http.RequestMethod.GET, '', cookies, undefined,
    DOMAINS[activeDomainIndex]
  );
  return decodeGb18030(response.body);
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
  get: (path: string, params: Record<string, string>,
    cookies?: Cookies, extraHeaders?: Record<string, string>) => Promise<object>;
  post: (path: string, body: Record<string, string>, cookies?: Cookies,
    gbkFieldKeys?: string[]) => Promise<object>;
  /** 发送同时携带查询参数与表单正文的 POST 请求。 */
  postWithQueryAndBody: (path: string, params: Record<string, string>,
    body: Record<string, string>, cookies?: Cookies) => Promise<object>;
  postWithQuery: (path: string, params: Record<string, string>, cookies?: Cookies) => Promise<object>;
  /** App 签名接口（POST form + access_uid/access_token/sign），__lib/__act 放 URL query。 */
  postSigned: (path: string, lib: string, act: string, params: Record<string, string>,
    cookies: Cookies | undefined, signParams: string, output: string) => Promise<object>;
  /** App 签名接口（POST form + access_uid/access_token/sign），无 __lib/__act（thread.php 官方通道）。 */
  postSignedPath: (path: string, params: Record<string, string>,
    cookies: Cookies | undefined, signParams: string, output: string) => Promise<object>;
  getHtmlText: (path: string, params: Record<string, string>,
    cookies?: Cookies) => Promise<string>;
  getCaptchaV2: (captchaId: string) => Promise<string>;
  loginPassword: (loginParams: LoginParams) => Promise<LoginResultData>;
  logout: (cookies: Cookies) => Promise<void>;
  getActiveDomain: () => string;
  setActiveDomainIndex: (index: number) => void;
  getDomainList: () => string[];
}

const client: INgaClient = {
  async get(path: string, params: Record<string, string>,
    cookies?: Cookies, extraHeaders?: Record<string, string>): Promise<object> {
    return ngaGet(path, params, cookies, extraHeaders);
  },

  async post(path: string, body: Record<string, string>,
    cookies?: Cookies, gbkFieldKeys?: string[]): Promise<object> {
    return ngaPost(path, body, cookies, gbkFieldKeys);
  },

  /**
   * 发送同时携带查询参数与表单正文的 POST 请求。
   *
   * @param path - 请求路径
   * @param params - URL 查询参数
   * @param body - 表单正文
   * @param cookies - NGA 登录 Cookie
   * @returns NGA JSON 响应
   */
  async postWithQueryAndBody(path: string, params: Record<string, string>,
    body: Record<string, string>, cookies?: Cookies): Promise<object> {
    return ngaPostWithQueryAndBody(path, params, body, cookies);
  },

  async postWithQuery(path: string, params: Record<string, string>,
    cookies?: Cookies): Promise<object> {
    return ngaPostWithQuery(path, params, cookies);
  },

  async postSigned(path: string, lib: string, act: string,
    params: Record<string, string>, cookies: Cookies | undefined,
    signParams: string, output: string): Promise<object> {
    return ngaPostSigned(path, lib, act, params, cookies, signParams, output);
  },

  async postSignedPath(path: string, params: Record<string, string>,
    cookies: Cookies | undefined, signParams: string, output: string): Promise<object> {
    return ngaPostSignedPath(path, params, cookies, signParams, output);
  },

  async getHtmlText(path: string, params: Record<string, string>,
    cookies?: Cookies): Promise<string> {
    return ngaGetHtmlText(path, params, cookies);
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
    const params: Record<string, string> = {
      '__lib': 'logout',
      '__output': '1',
    };
    await ngaGet('/nuke.php', params, cookies);
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
