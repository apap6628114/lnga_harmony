import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { preprocessJson } from '../parser/NgaJsonSanitizer';
import { ngaThrottler } from '../common/concurrency/Throttler';
import { Logger, DOMAIN_NETWORK, formatError } from '../common/utils/Logger';
import {
  stringToUint8Array,
  uint8ArrayToBase64,
  decodeGb18030,
  buildEncodedBody,
  buildMultipart,
  emptyStringRecord,
} from '../common/utils/CodecUtils';
import { extractHostname, buildUrl } from '../common/utils/UrlUtils';
import { parseSessionCookies, normalizeCookieList } from '../common/CookieUtils';
import { NGA_API_DOMAINS as DOMAINS, NGA_UPLOAD_URL } from '../common/constants/NgaDomains';

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

const NGA_RSA_PUBLIC_KEY =
  'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAyKzZWDimCN1OCprqWUhF' +
  'UPhcwxDE62/BFVP6LtQHJu+65dm4YNmDvzitmcfaXW9YbhXnd4oP7j+6vpcgJQ+p' +
  '3ucySo1ZnqO0Bb2JKEtxpCmxe7IYXhFEkJqHpFYBTiAxQz2n2mX4JZy/ehBUSMjz' +
  'gzd0NdG6Ai1C42oCzYltUOjNWZUNHn1nqpElSWHnUWqkdN8+5ISP/ZMKiQdFANkE' +
  'qDGw3/34qyF+E/hVgrGF4/CcWNP/LJCdB6DYtx7VPlQZF0tP1s+q/++rC4rQ2wmV' +
  'l2V8zGh1j7ojZbt62hVjy6byK1E/2XYo97ZtL4KDW7F5jJMvSDRFR7901UR8hCdf' +
  '4wIDAQAB';

let activeDomainIndex: number = 0;

const logger = new Logger(DOMAIN_NETWORK, 'NgaClient');

// ============== 工具函数 ==============

// 编解码工具（stringToUint8Array/uint8ArrayToBase64/decodeGb18030/emojiToHtmlEntity/
// gbkPercentEncode/buildEncodedBody/buildMultipart/emptyStringRecord）
// 已下沉至 common/utils/CodecUtils.ets。
// URL 工具（extractHostname/buildUrl）已下沉至 common/utils/UrlUtils.ets。

// ============== RSA 加密 ==============

async function encryptPassword(password: string): Promise<string> {
  // convertKey 需要 DER 编码的二进制数据，即 Base64 解码后的原始字节
  const base64 = new util.Base64Helper();
  const pubKeyData: cryptoFramework.DataBlob = {
    data: base64.decodeSync(NGA_RSA_PUBLIC_KEY),
  };

  let keyGenerator: cryptoFramework.AsyKeyGenerator
  try {
    keyGenerator = cryptoFramework.createAsyKeyGenerator('RSA2048')
  } catch (e) {
    throw new Error('RSA密钥生成器创建失败')
  }
  let keyPair: cryptoFramework.KeyPair
  try {
    keyPair = await keyGenerator.convertKey(pubKeyData, null)
  } catch (e) {
    throw new Error('RSA密钥转换失败')
  }
  let cipher: cryptoFramework.Cipher
  try {
    cipher = cryptoFramework.createCipher('RSA2048|PKCS1')
  } catch (e) {
    throw new Error('RSA密码器创建失败')
  }
  try {
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, keyPair.pubKey, null);
  } catch (e) {
    throw new Error('RSA加密初始化失败');
  }
  const inputData: cryptoFramework.DataBlob = {
    data: stringToUint8Array(password),
  };
  let output: cryptoFramework.DataBlob;
  try {
    output = await cipher.doFinal(inputData);
  } catch (e) {
    throw new Error('RSA加密失败');
  }
  return uint8ArrayToBase64(output.data);
}

// ============== HTTP 请求 ==============

const LOG_CHUNK_SIZE: number = 1500;

function logChunks(prefix: string, text: string): void {
  if (!logger.isVerbose()) {
    return;
  }
  if (text.length === 0) {
    return;
  }
  if (text.length <= LOG_CHUNK_SIZE) {
    logger.verbose('%{public}s', prefix + text);
    return;
  }
  let offset = 0;
  let seq = 1;
  while (offset < text.length) {
    const end = Math.min(offset + LOG_CHUNK_SIZE, text.length);
    logger.verbose('%{public}s', prefix + `[${seq}]` + text.slice(offset, end));
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

async function ngaPostMultipart(path: string, fields: Record<string, string>,
  cookies?: Cookies, baseUrl: string = ''): Promise<object> {
  const mp = buildMultipart(fields);
  const headers: Record<string, string> = emptyStringRecord();
  headers['Content-Type'] = mp.contentType;
  return ngaRequest(path, http.RequestMethod.POST, emptyStringRecord(),
    mp.body, cookies, baseUrl, headers);
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

async function ngaGetWithBaseUrl(path: string, params: Record<string, string>,
  baseUrl: string, cookies?: Cookies): Promise<object> {
  return ngaRequest(path, http.RequestMethod.GET, params, '', cookies, baseUrl, emptyStringRecord());
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
  skipInchst?: boolean): Promise<object> {
  if (!skipInchst && !params['__inchst']) {
    params['__inchst'] = 'UTF8';
  }

  // baseUrl 由调用方传入：常为空串，使 executeWithRetry 重试时遍历 DOMAINS 轮换。
  const response: HttpResponse = await executeWithRetry(
    path, params, method, body, cookies, extraHeaders, baseUrl
  );

  // GB18030 解码
  const rawText = decodeGb18030(response.body);
  logChunks('[NGA][RES] body:', rawText);

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
  postMultipart: (path: string, fields: Record<string, string>,
    cookies?: Cookies, baseUrl?: string) => Promise<object>;
  getRaw: (path: string, params: Record<string, string>,
    extraHeaders?: Record<string, string>) => Promise<ArrayBuffer>;
  getWithBaseUrl: (path: string, params: Record<string, string>,
    baseUrl: string, cookies?: Cookies) => Promise<object>;
  getHtmlText: (path: string, params: Record<string, string>,
    cookies?: Cookies) => Promise<string>;
  getCaptchaV2: (captchaId: string) => Promise<string>;
  loginPassword: (loginParams: LoginParams) => Promise<LoginResultData>;
  logout: (cookies: Cookies) => Promise<void>;
  rotateDomain: () => void;
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

  async postMultipart(path: string, fields: Record<string, string>,
    cookies?: Cookies, baseUrl?: string): Promise<object> {
    return ngaPostMultipart(path, fields, cookies, baseUrl || '');
  },

  async getRaw(path: string, params: Record<string, string>,
    extraHeaders?: Record<string, string>): Promise<ArrayBuffer> {
    return ngaGetRaw(path, params, extraHeaders);
  },

  async getWithBaseUrl(path: string, params: Record<string, string>,
    baseUrl: string, cookies?: Cookies): Promise<object> {
    return ngaGetWithBaseUrl(path, params, baseUrl, cookies);
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

  rotateDomain(): void {
    activeDomainIndex = (activeDomainIndex + 1) % DOMAINS.length;
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

/**
 * 上传附件到 img8.nga.cn （Multipart + 二进制）
 * 对应 Java TopicPostModel.buildMultipartBody() + uploadFileInner()
 */
export async function ngaUploadFile(
  imageData: ArrayBuffer,
  fileName: string,
  auth: string,
  fid: number,
  cookies: Cookies
): Promise<string> {
  const url: string = NGA_UPLOAD_URL
  const boundary: string = '----NGAFormBoundary' + Math.random().toString(36).slice(2, 12)
  const encoder: util.TextEncoder = util.TextEncoder.create()

  const textFields: string =
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="attachment_file1_url_utf8_name"\r\n\r\n' + fileName + '\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="fid"\r\n\r\n' + String(fid) + '\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="auth"\r\n\r\n' + auth + '\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="func"\r\n\r\nupload\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="v2"\r\n\r\n1\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="lite"\r\n\r\njs\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="attachment_file1_auto_size"\r\n\r\n\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="attachment_file1_watermark"\r\n\r\n\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="attachment_file1_dscp"\r\n\r\n\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="attachment_file1_img"\r\n\r\n1\r\n' +
    '--' + boundary + '\r\n' +
    // origin_domain 为服务端约定值（非连接域名），不随站点域切换修改
    'Content-Disposition: form-data; name="origin_domain"\r\n\r\nbbs.ngacn.cc\r\n'

  const fileHeader: string =
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="attachment_file1"; filename="' + fileName + '"\r\n' +
    'Content-Type: image/jpeg\r\n\r\n'
  const fileFooter: string = '\r\n--' + boundary + '--\r\n'

  const textBytes: Uint8Array = encoder.encodeInto(textFields)
  const headerBytes: Uint8Array = encoder.encodeInto(fileHeader)
  const footerBytes: Uint8Array = encoder.encodeInto(fileFooter)
  const imageU8: Uint8Array = new Uint8Array(imageData)

  const totalLength: number = textBytes.byteLength + headerBytes.byteLength + imageU8.byteLength + footerBytes.byteLength
  const fullBody: Uint8Array = new Uint8Array(totalLength)
  let pos: number = 0
  fullBody.set(textBytes, pos)
  pos += textBytes.byteLength
  fullBody.set(headerBytes, pos)
  pos += headerBytes.byteLength
  fullBody.set(imageU8, pos)
  pos += imageU8.byteLength
  fullBody.set(footerBytes, pos)

  const contentType: string = 'multipart/form-data; boundary=' + boundary
  const headers: Record<string, string> = {
    'Content-Type': contentType,
    'User-Agent': 'NGA_WP_JW',
    'X-User-Agent': 'Nga_Official',
  }
  if (cookies) {
    headers['Cookie'] = 'ngaPassportUid=' + cookies.uid + '; ngaPassportCid=' + cookies.cid
  }

  logger.verbose('[NGA][UPLOAD] %{public}s size=%{public}s', url, String(imageData.byteLength))
  return new Promise<string>((resolve, reject) => {
    const httpRequest = http.createHttp()
    httpRequest.request(url, {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: fullBody.buffer as ArrayBuffer,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      readTimeout: 120000,
      connectTimeout: 30000,
    }, (err, resp) => {
      httpRequest.destroy()
      if (err) {
        logger.verbose('[NGA][UPLOAD] fail: %{public}s', err.message)
        reject(new Error('上传失败: ' + err.message))
        return
      }
      const respText: string = decodeGb18030(resp.result as ArrayBuffer)
      logger.verbose('[NGA][UPLOAD] resp %{public}s %{public}s', String(resp.responseCode), respText.slice(0, 200))
      if (resp.responseCode !== 200) {
        reject(new Error('上传HTTP ' + String(resp.responseCode)))
        return
      }
      resolve(respText)
    })
  })
}

