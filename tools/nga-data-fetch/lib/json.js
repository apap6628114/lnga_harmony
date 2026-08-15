/**
 * NGA JSON 数据获取与后处理（通用，适用于任意 __output 接口）。
 *
 * 后处理管线：GBK 解码 → 提取 script_muti_get_var_store（__output=3 等 HTML 包裹场景）
 * → preprocessJson 净化（镜像真源 nga-bbcode-ts）→ JSON.parse → 业务错误判定。
 * 净化逻辑不在本工具内复制，统一 require nga-bbcode-ts 的 dist 产物，保持单源。
 */
'use strict'

const { ngaFetchText, buildApiUrl } = require('./request.js')
const { resolveCookie } = require('./credential.js')

const {
  preprocessJson,
  extractScriptStoreJson,
} = require('nga-bbcode-ts/dist/src/parser/NgaJsonSanitizer.js')

/**
 * 净化并解析 NGA 响应文本，做通用业务判定。
 *
 * @param {string} text GBK 解码后的原始响应
 * @returns {{ ok: boolean, kind: string, obj?: Object, error?: string, errorMsg?: string }}
 *   kind: ok | login-required | business-error | invalid-json
 */
function classifyJsonText(text) {
  if (!text || text.length === 0) {
    return { ok: false, kind: 'invalid-json', error: '空响应' }
  }
  const store = extractScriptStoreJson(text)
  const toParse = store !== null ? store : text
  let cleaned
  try {
    cleaned = preprocessJson(toParse)
  } catch (err) {
    return { ok: false, kind: 'invalid-json', error: `净化失败: ${err.message}` }
  }
  let obj
  try {
    obj = JSON.parse(cleaned)
  } catch (err) {
    return { ok: false, kind: 'invalid-json', error: `JSON.parse 失败: ${err.message}` }
  }
  const error = obj && obj.error !== undefined ? obj.error : null
  let errorMsg = obj && obj.error_msg !== undefined ? String(obj.error_msg) : ''
  // NGA 错误对象形态：{"error":{"0":"51:请先登录",...},"data":{"__MESSAGE":{...}}}（403 常带）
  let errorCode = error
  if (error && typeof error === 'object' && error['0'] !== undefined) {
    const first = String(error['0'])
    const codeMatch = /^(\d+)[:：]/.exec(first)
    if (codeMatch) errorCode = parseInt(codeMatch[1], 10)
    if (!errorMsg) errorMsg = first.replace(/^(\d+)[:：]/, '').trim()
  }
  if (errorCode !== null && errorCode !== 0 && errorCode !== '') {
    if (String(errorCode) === '15' || /登录|权限/.test(errorMsg)) {
      return { ok: false, kind: 'login-required', error: `error ${errorCode}（未登录/权限不足）: ${errorMsg}` }
    }
    return { ok: false, kind: 'business-error', error: `error ${errorCode}: ${errorMsg}` }
  }
  if (errorMsg && errorMsg.length > 0) {
    return { ok: false, kind: 'business-error', error: errorMsg }
  }
  return { ok: true, kind: 'ok', obj, error: null, errorMsg: '' }
}

/**
 * 获取并后处理任意 NGA JSON 接口。
 *
 * @param {string} endpoint 接口路径（如 read.php）
 * @param {Record<string, string|number>} [params] 查询参数
 * @param {{ cookie?: string, encoding?: string, base?: string, raw?: boolean }} [opts]
 *   raw=true 时跳过业务判定，只返回净化文本（调用方自行解释，如帖子楼层提取）
 * @returns {Promise<{ ok: boolean, status: number, kind: string, raw?: string, obj?: Object, error?: string, errorMsg?: string }>}
 */
async function fetchNgaJson(endpoint, params, opts = {}) {
  const cookie = opts.cookie !== undefined ? opts.cookie : resolveCookie()
  const url = buildApiUrl(endpoint, params, opts.base)
  const resp = await ngaFetchText(url, { cookie, encoding: opts.encoding })
  if (!resp.ok) {
    // 错误响应体常为 GBK JSON（error 51 请先登录等），尝试识别业务/登录错误
    if (resp.text && resp.text.length > 0) {
      const classified = classifyJsonText(resp.text)
      if (classified.kind === 'login-required' || classified.kind === 'business-error') {
        return { ok: false, status: resp.status, kind: classified.kind, error: classified.error }
      }
    }
    return { ok: false, status: resp.status, kind: 'http-error', error: resp.error }
  }
  // 与既有抓取行为一致：落盘文本为净化后可 parse 的形态
  const store = extractScriptStoreJson(resp.text)
  const toParse = store !== null ? store : resp.text
  let raw
  try {
    raw = preprocessJson(toParse)
  } catch (err) {
    return { ok: false, status: resp.status, kind: 'invalid-json', error: `净化失败: ${err.message}` }
  }
  if (opts.raw) {
    return { ok: true, status: resp.status, kind: 'ok', raw, error: null }
  }
  const classified = classifyJsonText(raw)
  return {
    ok: classified.ok,
    status: resp.status,
    kind: classified.kind,
    raw,
    obj: classified.obj,
    error: classified.error,
    errorMsg: classified.errorMsg,
  }
}

module.exports = {
  classifyJsonText,
  fetchNgaJson,
}
