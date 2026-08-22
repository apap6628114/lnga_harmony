#!/usr/bin/env node
/**
 * nga-fetch CLI — NGA 通用数据抓取入口。
 *
 * 用法：
 *   node bin/nga-fetch.js json <endpoint> [k=v ...] [--out <file>] [--raw] [--base <url>]
 *       抓取任意 JSON 接口（如 read.php __output=8），默认打印业务摘要并落盘净化文本；
 *       --raw 跳过业务判定（调用方自行解释数据）；--out 覆盖落盘路径。
 *   node bin/nga-fetch.js html <url> [--out <file>] [--marker <文本>]...
 *       抓取任意 NGA 页面，可选校验页面标记（如 commonui.postArg.proc(）。
 *   node bin/nga-fetch.js app-json <endpoint> [k=v ...] [--output <n>]
 *       [--sign-params <值>] [--query <k=v>]... [--out <file>] [--raw]
 *       使用官方 APP 签名 POST 抓取接口；__lib/__act 等 URL 参数通过 --query 传入。
 *   node bin/nga-fetch.js app-html <tid> [page] [--out <file>]
 *       使用官方 APP read.php __output=17 抓取包装内的完整帖子 HTML。
 *   node bin/nga-fetch.js check
 *       校验当前凭证结构（不发请求）。
 *   node bin/nga-fetch.js verify [--url <u>]
 *       用真实请求验证凭证是否失效；默认探针 read.php?__output=8&tid=47373567&page=1，
 *       可用 --url 覆盖（返回 error 15 / 未登录 / 403 / 不可解析均视为失效）。
 *   node bin/nga-fetch.js save <cookie值>
 *       校验并落盘持久化凭证（拒绝结构不完整）。
 *
 * 凭证来源：NGA_COOKIE 环境变量 → NGA_COOKIE_FILE 指定文件 → 工具默认 .nga-cookie.txt
 * → 兼容回退 tools/bbcode-ts/.nga-cookie.txt。任何输出都不会打印 Cookie/UID/CID 明文。
 */
'use strict'

const { writeFileSync } = require('node:fs')
const { join } = require('node:path')

const credential = require('../lib/credential.js')
const { buildApiUrl } = require('../lib/request.js')
const { fetchNgaJson } = require('../lib/json.js')
const { fetchNgaHtml } = require('../lib/html.js')
const { fetchNgaAppJson, fetchNgaAppArticleHtml } = require('../lib/app.js')

/** 凭证门禁固定基准：必须成功获取 tid=44191387 的帖子信息（data.__R 存在）。 */
const PROBE_URL = 'https://bbs.nga.cn/read.php?tid=44191387&page=1&__output=8&__inchst=UTF8'

function parseArgs(argv) {
  const positional = []
  const options = {}
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--out' || arg === '--base' || arg === '--url' || arg === '--marker' ||
      arg === '--output' || arg === '--sign-params' || arg === '--query') {
      const key = arg.slice(2)
      options[key] = options[key] === undefined ? argv[++i] : [].concat(options[key], argv[++i])
      continue
    }
    if (arg === '--raw') {
      options.raw = true
      continue
    }
    positional.push(arg)
  }
  return { positional, options }
}

/**
 * 把 k=v 参数列表转为对象。
 *
 * @param {string[]} args 参数列表
 * @returns {Record<string, string>} 参数对象
 */
function parseKeyValueArgs(args) {
  const params = {}
  for (const arg of args) {
    const separator = arg.indexOf('=')
    if (separator <= 0) exitError(`参数应为 k=v 形式: ${arg}`)
    params[arg.slice(0, separator)] = arg.slice(separator + 1)
  }
  return params
}

function exitError(message) {
  console.error(`[nga-fetch] ${message}`)
  process.exit(1)
}

async function cmdJson(args, options) {
  const endpoint = args[0]
  if (!endpoint) exitError('用法: nga-fetch json <endpoint> [k=v ...] [--out <file>] [--raw]')
  const params = parseKeyValueArgs(args.slice(1))
  const result = await fetchNgaJson(endpoint, params, {
    raw: options.raw,
    base: options.base,
  })
  if (!result.ok) {
    exitError(`${endpoint} 失败 [${result.kind}]: ${result.error || ''}`)
  }
  if (options.out || !options.raw) {
    const outFile = options.out || defaultOutName(endpoint, params)
    writeFileSync(outFile, result.raw, 'utf8')
    console.log(`${endpoint} -> ${outFile}（${result.raw.length} 字符）`)
  }
  if (result.obj) {
    const obj = result.obj
    console.log(`kind=${result.kind} error=${obj.error === undefined ? '-' : obj.error} ` +
      `error_msg=${obj.error_msg || '-'} data=${obj.data ? '存在' : '无'}`)
  }
}

/**
 * 抓取官方 APP 签名 JSON 接口。
 *
 * @param {string[]} args 命令位置参数
 * @param {Record<string, string|string[]|boolean>} options 命令选项
 * @returns {Promise<void>}
 */
async function cmdAppJson(args, options) {
  const endpoint = args[0]
  if (!endpoint) {
    exitError('用法: nga-fetch app-json <endpoint> [k=v ...] [--output <n>] [--sign-params <值>] [--query <k=v>]...')
  }
  const params = parseKeyValueArgs(args.slice(1))
  const queryValues = options.query === undefined
    ? []
    : Array.isArray(options.query) ? options.query : [options.query]
  const query = parseKeyValueArgs(queryValues)
  const result = await fetchNgaAppJson(endpoint, params, {
    base: options.base,
    output: options.output || '12',
    signParams: options['sign-params'] || '',
    query,
    raw: options.raw,
  })
  if (!result.ok) {
    exitError(`${endpoint} APP 请求失败 [${result.kind}]: ${result.error || ''}`)
  }
  if (options.out || !options.raw) {
    const outFile = options.out || `app-${defaultOutName(endpoint, params)}`
    writeFileSync(outFile, result.raw, 'utf8')
    console.log(`${endpoint} APP -> ${outFile}（${result.raw.length} 字符）`)
  }
  if (result.obj) {
    const topKeys = Object.keys(result.obj)
    console.log(`kind=${result.kind} 顶层字段=${topKeys.join(',') || '-'}`)
  }
}

/**
 * 抓取官方 APP read.php __output=17 HTML。
 *
 * @param {string[]} args 命令位置参数
 * @param {Record<string, string|string[]|boolean>} options 命令选项
 * @returns {Promise<void>}
 */
async function cmdAppHtml(args, options) {
  const tid = args[0]
  const page = args[1] || '1'
  if (!tid || !/^\d+$/.test(tid)) {
    exitError('用法: nga-fetch app-html <tid> [page] [--out <file>]')
  }
  const result = await fetchNgaAppArticleHtml({
    tid,
    pid: '',
    topid: '',
    authorid: '',
    opt: '',
    page,
    __localres: '1',
  }, { base: options.base })
  if (!result.ok) {
    exitError(`read.php APP HTML 失败 [${result.kind}]: ${result.error || ''}`)
  }
  const outFile = options.out || `app-read-tid${tid}-page${page}.html`
  writeFileSync(outFile, result.html, 'utf8')
  console.log(`APP read.php tid=${tid} page=${page} -> ${outFile}（${result.html.length} 字符）`)
}

function defaultOutName(endpoint, params) {
  const tid = params.tid || ''
  const page = params.page || ''
  const base = endpoint.replace(/\W+/g, '-')
  return `raw-${base}${tid ? `-tid${tid}` : ''}${page ? `-page${page}` : ''}.json`
}

async function cmdHtml(args, options) {
  const url = args[0]
  if (!url) exitError('用法: nga-fetch html <url> [--out <file>] [--marker <文本>]...')
  const markers = options.marker
    ? (Array.isArray(options.marker) ? options.marker : [options.marker])
    : undefined
  const result = await fetchNgaHtml(url, { markers })
  if (!result.ok) {
    exitError(`抓取失败 [${result.kind || 'http-error'}]: ${result.error}`)
  }
  if (options.out) {
    writeFileSync(options.out, result.text, 'utf8')
  }
  if (result.matched === false) {
    console.log(`URL -> ${result.text.length} 字符，但缺少标记: ${result.missingMarkers.join(', ')}`)
    process.exitCode = 2
    return
  }
  console.log(`URL -> ${result.text.length} 字符${result.matched ? '（标记齐全）' : ''}`)
}

function cmdCheck() {
  const result = credential.checkCredential()
  if (result.ok) {
    console.log(`凭证结构有效（来源: ${result.source}）`)
    return
  }
  console.error(`凭证不可用（来源: ${result.source}）:`)
  for (const issue of result.issues) console.error(`  - ${issue}`)
  process.exit(1)
}

async function cmdVerify(options) {
  const url = options.url || PROBE_URL
  const cookie = credential.resolveCookie()
  if (!cookie) {
    printRefreshGuide()
    exitError('无可用凭证：设 NGA_COOKIE 或先 nga-fetch save <cookie>')
  }
  const parsed = new URL(url)
  const params = {}
  parsed.searchParams.forEach((value, key) => { params[key] = value })
  const result = await fetchNgaJson(parsed.pathname.replace(/^\//, ''), params, {
    base: parsed.origin,
  })
  // 严格门禁：kind=ok 且拿到帖子楼层表 data.__R（"获取帖子信息成功"的定义）
  const hasRows = !!result.obj && typeof result.obj.data === 'object' &&
    result.obj.data !== null && '__R' in result.obj.data
  if (result.ok && hasRows) {
    const rows = Object.keys(result.obj.data.__R).length
    console.log(`凭证门禁通过：固定基准 tid=44191387 获取成功（kind=ok，${rows} 楼）`)
    return
  }
  if (result.ok && !hasRows) {
    console.error(`凭证门禁未通过：请求成功但响应缺少 data.__R（error=${result.obj && result.obj.error} error_msg=${result.obj && result.obj.error_msg}），基准判定失败`)
    printRefreshGuide()
    process.exit(1)
  }
  if (result.kind === 'business-error') {
    // 请求被业务拒绝（如帖子审核中/权限不足）不等于凭证失效，换探针再判定
    console.error(`凭证门禁未通过：请求被业务拒绝 ${result.error}（凭证结构有效；若固定基准帖本身异常，换 --url 指向可正常读取的帖子复核）`)
    process.exit(2)
  }
  if (result.kind === 'login-required') {
    console.error(`凭证门禁未通过：${result.error}`)
    printRefreshGuide()
    process.exit(1)
  }
  if (result.status === 403) {
    console.error(`凭证门禁未通过：HTTP 403（可能被 NGA 反爬拦截或网络不可达）`)
    printRefreshGuide()
    process.exit(1)
  }
  console.error(`凭证门禁未通过：${result.error || result.kind}`)
  printRefreshGuide()
  process.exit(1)
}

/** 输出标准刷新流程指引（对应 skill `nga-data-fetch` 的「刷新凭证」章节）。 */
function printRefreshGuide() {
  console.error('')
  console.error('刷新凭证（严格方法，见 skill nga-data-fetch）：')
  console.error('  1. 浏览器打开 https://bbs.nga.cn/read.php?tid=44191387 并确认已登录')
  console.error('  2. 在页面执行（chrome MCP evaluate_script），触发一次真实请求：')
  console.error("     () => fetch('https://bbs.nga.cn/read.php?tid=44191387&page=1&__output=8&__inchst=UTF8').then(r=>r.text()).then(()=>'ok')")
  console.error('  3. chrome MCP list_network_requests 找到刚发出的 read.php 请求')
  console.error('  4. chrome MCP get_network_request 提取其 Cookie 请求头（含 ngaPassportUid 与 ngaPassportCid）')
  console.error("  5. nga-fetch save '<完整 Cookie 请求头值>' 落盘（工具校验结构，缺 CID 拒绝）")
  console.error('  6. 重新执行 nga-fetch verify，门禁通过后才允许其他功能抓取数据')
}

function cmdSave(args) {
  const cookie = args[0]
  if (!cookie) exitError('用法: nga-fetch save <cookie值>')
  const result = credential.saveCookie(cookie)
  if (!result.ok) {
    console.error('拒绝落盘：')
    for (const issue of result.issues) console.error(`  - ${issue}`)
    process.exit(1)
  }
  console.log(`已持久化凭证 -> ${result.file}`)
}

async function main() {
  const argv = process.argv.slice(2)
  const { positional, options } = parseArgs(argv)
  const command = positional.shift()
  switch (command) {
    case 'json': await cmdJson(positional, options); break
    case 'html': await cmdHtml(positional, options); break
    case 'app-json': await cmdAppJson(positional, options); break
    case 'app-html': await cmdAppHtml(positional, options); break
    case 'check': cmdCheck(); break
    case 'verify': await cmdVerify(options); break
    case 'save': cmdSave(positional); break
    default:
      console.error(`未知命令: ${command || '(空)'}`)
      console.error('可用: json | html | app-json | app-html | check | verify | save')
      process.exit(1)
  }
}

main().catch((err) => {
  console.error(`[nga-fetch] 未预期错误: ${err.message}`)
  process.exit(1)
})
