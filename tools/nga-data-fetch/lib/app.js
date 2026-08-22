/**
 * NGA 官方 APP 签名接口抓取层。
 *
 * 公共请求形态与 nga.apk v7.17.17 对齐：POST form、app_id/access_uid/
 * access_token/t/sign/__output/__inchst 全部进入 body，完整 X-NGA-* 请求头，
 * 默认主机固定为 ngabbs.com。网页 GET API 仍由 json.js/html.js 独立提供。
 */
'use strict'

const { createHash } = require('node:crypto')

const { resolveCookie } = require('./credential.js')
const { buildApiUrl, ngaFetchText } = require('./request.js')
const { classifyJsonText } = require('./json.js')

/** 官方 APP ID。 */
const NGA_APP_ID = '1010'

/** 官方 APP 主接口签名密钥。 */
const NGA_APP_SECRET = '392e916a6d1d8b7523e2701470000c30bc2165a1'

/** 官方 APP 默认 API 主机。 */
const NGA_APP_BASE = 'https://ngabbs.com'

/**
 * 从 Cookie 中读取 APP 签名所需的 uid 与 token。
 *
 * @param {string} cookie Cookie 请求头值
 * @returns {{ uid: string, token: string }} APP 登录字段
 */
function parseAppCredential(cookie) {
  const values = {}
  for (const part of cookie.split(';')) {
    const item = part.trim()
    const separator = item.indexOf('=')
    if (separator <= 0) continue
    values[item.slice(0, separator)] = item.slice(separator + 1)
  }
  return {
    uid: values.ngaPassportUid || '',
    token: values.ngaPassportCid || '',
  }
}

/**
 * 生成官方 APP 主接口签名。
 *
 * @param {{ accessUid?: string, accessToken?: string, signParams?: string, timestamp?: string, appId?: string, secret?: string }} [opts]
 * @returns {string} 小写 MD5 hex
 */
function makeAppSign(opts = {}) {
  const appId = opts.appId || NGA_APP_ID
  const accessUid = opts.accessUid || ''
  const accessToken = opts.accessToken || ''
  const signParams = opts.signParams || ''
  const timestamp = opts.timestamp || String(Math.floor(Date.now() / 1000))
  const secret = opts.secret || NGA_APP_SECRET
  return createHash('md5')
    .update(`${appId}${accessUid}${accessToken}${signParams}${timestamp}${secret}`, 'utf8')
    .digest('hex')
}

/**
 * 构造官方 APP 完整请求头。
 *
 * @returns {Record<string, string>} HTTP 请求头
 */
function buildAppHeaders() {
  return {
    'Content-Type': 'application/x-www-form-urlencoded',
    'User-Agent': 'Mozilla/5.0 (Linux; Android 10; NOH-AN00 Build/HUAWEINOH-AN00; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/83.0.4103.106 Mobile Safari/537.36 Nga_Official/7.17.17',
    'X-Requested-With': 'gov.pianzong.androidnga',
    'X-USER-AGENT': 'Nga_Official/7.17.17(HUAWEI NOH-AN00;Android 10)',
    'X-NGA-CHANNEL': 'official',
    'X-NGA-VERSION-NAME': '7.17.17',
    'X-NGA-VERSION-CODE': '71717',
    Referer: 'https://ngabbs.com/',
  }
}

/**
 * 构造官方 APP POST body。
 *
 * @param {Record<string, string|number>} params 业务参数
 * @param {{ uid: string, token: string }} credential APP 登录字段
 * @param {{ output?: string|number, signParams?: string, timestamp?: string }} [opts]
 * @returns {URLSearchParams} form body
 */
function buildAppFields(params, credential, opts = {}) {
  const timestamp = opts.timestamp || String(Math.floor(Date.now() / 1000))
  const output = String(opts.output === undefined ? '12' : opts.output)
  const fields = new URLSearchParams({
    __output: output,
    __inchst: 'utf-8',
    app_id: NGA_APP_ID,
    access_uid: credential.uid,
    access_token: credential.token,
    t: timestamp,
    sign: makeAppSign({
      accessUid: credential.uid,
      accessToken: credential.token,
      signParams: opts.signParams || '',
      timestamp,
    }),
  })
  for (const key of Object.keys(params)) {
    fields.set(key, String(params[key]))
  }
  return fields
}

/**
 * 解释 APP JSON 包装层，并将非成功业务码转成统一失败结果。
 *
 * `read.php?__output=17` 的 HTML 成功包固定携带 `code=521`，因此只有同时
 * 存在 HTML 字符串时才把 521 视为成功；其余非零业务码均视为接口失败。
 *
 * @param {string} text HTTP 响应正文
 * @returns {{ ok: boolean, kind: string, obj?: Object, error?: string, errorMsg?: string }} 分类结果
 */
function classifyAppJsonText(text) {
  const classified = classifyJsonText(text)
  if (!classified.ok || !classified.obj || typeof classified.obj !== 'object') {
    return classified
  }
  const envelope = classified.obj
  const code = typeof envelope.code === 'number' ? envelope.code : undefined
  const isHtmlSuccess = code === 521 && typeof envelope.html === 'string'
  if (code === undefined || code === 0 || isHtmlSuccess) {
    return classified
  }
  const message = typeof envelope.msg === 'string' && envelope.msg.trim()
    ? envelope.msg.trim()
    : `APP 接口返回业务错误码 ${code}`
  return {
    ok: false,
    kind: 'app-error',
    obj: envelope,
    error: message,
    errorMsg: message,
  }
}

/**
 * 请求任意官方 APP JSON 接口。
 *
 * @param {string} endpoint 接口路径
 * @param {Record<string, string|number>} [params] POST body 业务参数
 * @param {{ cookie?: string, base?: string, output?: string|number, signParams?: string, query?: Record<string,string|number>, raw?: boolean }} [opts]
 * @returns {Promise<{ ok: boolean, status: number, kind: string, raw?: string, obj?: Object, error?: string, errorMsg?: string }>}
 */
async function fetchNgaAppJson(endpoint, params = {}, opts = {}) {
  const cookie = opts.cookie === undefined ? resolveCookie() : opts.cookie
  const credential = parseAppCredential(cookie)
  if (!credential.uid || !credential.token) {
    return { ok: false, status: 0, kind: 'login-required', error: 'APP 凭证缺少 uid 或 token' }
  }
  const url = buildApiUrl(endpoint, opts.query, opts.base || NGA_APP_BASE)
  const fields = buildAppFields(params, credential, opts)
  const response = await ngaFetchText(url, {
    cookie,
    encoding: 'utf-8',
    headers: buildAppHeaders(),
    method: 'POST',
    body: fields.toString(),
  })
  if (!response.ok) {
    return { ok: false, status: response.status, kind: 'http-error', error: response.error }
  }
  if (opts.raw) {
    return { ok: true, status: response.status, kind: 'ok', raw: response.text }
  }
  const classified = classifyAppJsonText(response.text)
  return {
    ok: classified.ok,
    status: response.status,
    kind: classified.kind,
    raw: response.text,
    obj: classified.obj,
    error: classified.error,
    errorMsg: classified.errorMsg,
  }
}

/**
 * 拉取 APP read.php __output=17 并提取 HTML 页面。
 *
 * @param {Record<string, string|number>} params read.php 业务参数
 * @param {{ cookie?: string, base?: string }} [opts]
 * @returns {Promise<{ ok: boolean, status: number, kind: string, html?: string, envelope?: Object, raw?: string, error?: string }>}
 */
async function fetchNgaAppArticleHtml(params, opts = {}) {
  const result = await fetchNgaAppJson('read.php', params, {
    cookie: opts.cookie,
    base: opts.base,
    output: '17',
    signParams: '',
  })
  if (!result.ok) return result
  const envelope = result.obj
  const html = envelope && typeof envelope.html === 'string' ? envelope.html : ''
  if (!html.trim()) {
    const code = envelope && envelope.code !== undefined ? ` code=${envelope.code}` : ''
    const message = envelope && envelope.msg ? ` ${envelope.msg}` : ''
    return {
      ok: false,
      status: result.status,
      kind: 'invalid-app-html',
      raw: result.raw,
      error: `APP read.php __output=17 未返回 html。${code}${message}`.trim(),
    }
  }
  return {
    ok: true,
    status: result.status,
    kind: 'ok',
    html,
    envelope,
    raw: result.raw,
  }
}

module.exports = {
  NGA_APP_ID,
  NGA_APP_SECRET,
  NGA_APP_BASE,
  parseAppCredential,
  makeAppSign,
  buildAppHeaders,
  buildAppFields,
  classifyAppJsonText,
  fetchNgaAppJson,
  fetchNgaAppArticleHtml,
}
