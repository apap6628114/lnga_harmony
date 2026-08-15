/**
 * NGA HTML 数据获取与通用后处理。
 *
 * 通用部分：任意 URL 抓取（客户端同源 UA/Cookie）、GBK 解码、页面标记检查、
 * script_muti_get_var_store 提取。帖子页 → JSON 同形状的解析（parseHtmlToRawJson）
 * 属于 nga-bbcode-ts 镜像真源，不在此复制。
 */
'use strict'

const { ngaFetchText } = require('./request.js')
const { resolveCookie } = require('./credential.js')

const { extractScriptStoreJson } =
  require('nga-bbcode-ts/dist/src/parser/NgaJsonSanitizer.js')

/**
 * 获取任意 NGA 页面（HTML/静态资源），并做可选标记检查。
 *
 * @param {string} url 完整 URL（含参数）
 * @param {{ cookie?: string, encoding?: string, markers?: string[] }} [opts]
 *   markers：需要存在的页面标记列表（如 'commonui.postArg.proc('），缺任一返回 matched=false
 * @returns {Promise<{ ok: boolean, status: number, text: string, matched?: boolean, missingMarkers?: string[], error?: string }>}
 */
async function fetchNgaHtml(url, opts = {}) {
  const cookie = opts.cookie !== undefined ? opts.cookie : resolveCookie()
  const resp = await ngaFetchText(url, { cookie, encoding: opts.encoding })
  if (!resp.ok) {
    return { ok: false, status: resp.status, text: '', error: resp.error }
  }
  const result = { ok: true, status: resp.status, text: resp.text }
  if (opts.markers && opts.markers.length > 0) {
    const missing = opts.markers.filter((m) => !resp.text.includes(m))
    result.matched = missing.length === 0
    result.missingMarkers = missing
  }
  return result
}

/**
 * 从 HTML 文本中提取 window.script_muti_get_var_store 内嵌 JSON。
 * 包装镜像真源的 extractScriptStoreJson，供 __output=3 等 HTML 包裹接口使用。
 *
 * @param {string} html 解码后的 HTML/文本
 * @returns {string|null} JSON 字符串；未找到返回 null
 */
function extractStoreJson(html) {
  return extractScriptStoreJson(html)
}

module.exports = {
  fetchNgaHtml,
  extractStoreJson,
}
