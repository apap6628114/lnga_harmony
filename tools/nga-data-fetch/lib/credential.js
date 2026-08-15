/**
 * 持久化凭证管理（NGA 登录 Cookie）。
 *
 * 约定（与 AGENTS.md R2.1 一致）：
 * - 解析顺序：NGA_COOKIE 环境变量（一次性覆盖）→ NGA_COOKIE_FILE 指定的文件
 *   → 工具默认 .nga-cookie.txt → 兼容回退 tools/bbcode-ts/.nga-cookie.txt（旧位置）。
 * - 有效凭证 = 单行纯 Cookie 值，同时含非空 ngaPassportUid 与 ngaPassportCid；
 *   带 "Cookie:" 前缀、换行、Set-Cookie 属性均视为结构不完整。
 * - 本模块任何函数都不得输出 Cookie / UID / CID 明文（日志、报错、返回摘要均只给结构信息）。
 */
'use strict'

const { existsSync, readFileSync, writeFileSync } = require('node:fs')
const { join } = require('node:path')

/** 工具根目录（本文件位于 <工具根>/lib/）。 */
const TOOL_ROOT = join(__dirname, '..')

/** 默认持久化凭证文件。 */
const DEFAULT_COOKIE_FILE = join(TOOL_ROOT, '.nga-cookie.txt')

/** 兼容回退：旧位置（迁移期，读取不写回）。 */
const LEGACY_COOKIE_FILE = join(__dirname, '..', '..', 'bbcode-ts', '.nga-cookie.txt')

/**
 * 解析凭证来源路径：
 * NGA_COOKIE_FILE 环境变量 → 默认文件；默认文件不存在时回退旧位置。
 *
 * @returns {string} 凭证文件路径（可能不存在）
 */
function resolveCookieFile() {
  const fromEnv = process.env.NGA_COOKIE_FILE
  if (fromEnv && fromEnv.length > 0) return fromEnv
  if (existsSync(DEFAULT_COOKIE_FILE)) return DEFAULT_COOKIE_FILE
  if (existsSync(LEGACY_COOKIE_FILE)) return LEGACY_COOKIE_FILE
  return DEFAULT_COOKIE_FILE
}

/**
 * 按约定顺序解析当前可用的 Cookie 字符串。
 *
 * @returns {string} Cookie 值；不可用时返回空字符串
 */
function resolveCookie() {
  const fromEnv = process.env.NGA_COOKIE
  if (fromEnv && fromEnv.length > 0) return fromEnv.trim()
  const file = resolveCookieFile()
  if (existsSync(file)) {
    const value = readFileSync(file, 'utf8').trim()
    if (value.length > 0) return value
  }
  return ''
}

/**
 * 校验 Cookie 字符串结构是否完整（不发送请求）。
 *
 * @param {string} cookie 待校验的 Cookie 值
 * @returns {{ ok: boolean, issues: string[] }} ok=false 时 issues 给出原因
 */
function validateCookieStructure(cookie) {
  const issues = []
  if (!cookie || cookie.length === 0) {
    issues.push('Cookie 为空')
    return { ok: false, issues }
  }
  if (/^cookie\s*:/i.test(cookie)) {
    issues.push('带 "Cookie:" 前缀，应只保存纯 Cookie 值')
  }
  if (/[\r\n]/.test(cookie)) {
    issues.push('包含换行，应为单行')
  }
  if (/;\s*(path|expires|domain|max-age)\s*=/i.test(cookie)) {
    issues.push('混入 Set-Cookie 属性（Path/Expires 等），应只保存请求头 Cookie 值')
  }
  const pairs = cookie.split(';').map((p) => p.trim()).filter((p) => p.length > 0)
  const hasUid = pairs.some((p) => /^ngaPassportUid=(\S+)$/.test(p))
  const hasCid = pairs.some((p) => /^ngaPassportCid=(\S+)$/.test(p))
  if (!hasUid) issues.push('缺少非空 ngaPassportUid')
  if (!hasCid) issues.push('缺少非空 ngaPassportCid')
  return { ok: issues.length === 0, issues }
}

/**
 * 把已核验的 Cookie 落盘为持久化凭证。
 * 仅接受结构完整的单行纯 Cookie；拒绝时不写盘。
 *
 * @param {string} cookie Cookie 请求头值
 * @param {string} [file] 目标文件；默认 resolveCookieFile()
 * @returns {{ ok: boolean, file?: string, issues?: string[] }}
 */
function saveCookie(cookie, file) {
  const value = typeof cookie === 'string' ? cookie.trim() : ''
  const check = validateCookieStructure(value)
  if (!check.ok) return { ok: false, issues: check.issues }
  const target = file || DEFAULT_COOKIE_FILE
  writeFileSync(target, value + '\n', 'utf8')
  return { ok: true, file: target }
}

/**
 * 检查当前凭证的结构状态（不发送请求，不泄露明文）。
 *
 * @returns {{ ok: boolean, source: string, issues: string[] }}
 */
function checkCredential() {
  const fromEnv = !!(process.env.NGA_COOKIE && process.env.NGA_COOKIE.length > 0)
  const cookie = resolveCookie()
  const source = fromEnv ? '环境变量 NGA_COOKIE' : `文件 ${resolveCookieFile()}`
  const check = validateCookieStructure(cookie)
  if (fromEnv) {
    // 环境变量存在即视为来源可用，结构问题仍要报告
    return { ok: check.ok, source, issues: check.issues }
  }
  if (cookie.length === 0) {
    return { ok: false, source, issues: ['凭证文件缺失或为空（可执行 nga-fetch save <cookie> 落盘）'] }
  }
  return { ok: check.ok, source, issues: check.issues }
}

module.exports = {
  TOOL_ROOT,
  DEFAULT_COOKIE_FILE,
  LEGACY_COOKIE_FILE,
  resolveCookieFile,
  resolveCookie,
  validateCookieStructure,
  saveCookie,
  checkCredential,
}
