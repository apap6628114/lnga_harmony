/**
 * NGA 通用请求层：UA/Cookie 请求头、GBK/GB18030 解码、响应分类。
 *
 * 请求头约定（与客户端同源，AGENTS.md R8.1）：
 *   User-Agent: NGA_WP_JW + X-User-Agent: Nga_Official（Mozilla UA 可能被 403）。
 * 域名常量来自 nga-bbcode-ts 镜像真源（NgaDomains.ts），保持单源。
 */
'use strict'

const { NGA_API_DOMAINS } = require('nga-bbcode-ts/dist/src/common/constants/NgaDomains.js')

/** 默认 API 站点域。 */
const NGA_BASE = NGA_API_DOMAINS[0] || 'https://bbs.nga.cn'

/**
 * 生成客户端同源请求头。
 *
 * @param {string} cookie 凭证 Cookie 值
 * @returns {Record<string, string>} fetch headers
 */
function ngaHeaders(cookie) {
  const headers = {
    'User-Agent': 'NGA_WP_JW',
    'X-User-Agent': 'Nga_Official',
  }
  if (cookie && cookie.length > 0) headers.Cookie = cookie
  return headers
}

/**
 * 拼接 API URL：`<base>/<endpoint>?<query>`。
 *
 * @param {string} endpoint 接口路径（如 read.php、nuke.php）
 * @param {Record<string, string|number>} [params] 查询参数（值会 URL 编码）
 * @param {string} [base] 覆盖默认站点域
 * @returns {string} 完整 URL
 */
function buildApiUrl(endpoint, params, base) {
  const cleanEndpoint = endpoint.startsWith('/') ? endpoint.slice(1) : endpoint
  const url = `${base || NGA_BASE}/${cleanEndpoint}`
  if (!params) return url
  const keys = Object.keys(params)
  if (keys.length === 0) return url
  const query = keys
    .map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(String(params[k]))}`)
    .join('&')
  return `${url}?${query}`
}

/**
 * 发起请求并按指定编码解码为文本。
 *
 * @param {string} url 完整 URL
 * @param {{ cookie?: string, encoding?: string, headers?: Record<string,string> }} [opts]
 * @returns {Promise<{ ok: boolean, status: number, text: string, error?: string }>}
 */
async function ngaFetchText(url, opts = {}) {
  const encoding = opts.encoding || 'gbk'
  let response
  try {
    response = await fetch(url, { headers: ngaHeaders(opts.cookie || '') })
  } catch (err) {
    return { ok: false, status: 0, text: '', error: `网络错误: ${err.message}` }
  }
  if (!response.ok) {
    // 错误响应也尝试解码（NGA 403 常为 GBK JSON，含 error 51 请先登录等业务信息）
    let text = ''
    try {
      text = new TextDecoder(encoding).decode(await response.arrayBuffer())
    } catch {
      text = ''
    }
    const msg = response.status === 403
      ? 'HTTP 403（可能被 NGA 反爬拦截或凭证过期）'
      : `HTTP ${response.status}`
    return { ok: false, status: response.status, text, error: msg }
  }
  let text = ''
  try {
    text = new TextDecoder(encoding).decode(await response.arrayBuffer())
  } catch (err) {
    return { ok: false, status: response.status, text: '', error: `解码失败(${encoding}): ${err.message}` }
  }
  return { ok: true, status: response.status, text }
}

module.exports = {
  NGA_BASE,
  ngaHeaders,
  buildApiUrl,
  ngaFetchText,
}
