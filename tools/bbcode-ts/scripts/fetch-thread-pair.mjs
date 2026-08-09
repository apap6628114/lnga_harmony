/**
 * 拉取同一帖子同页的 JSON（__output=8）与 HTML（read.php）成对数据并落盘。
 *
 * 用途：HTML 模式 → JSON 覆盖验证套件的数据采集。以 JSON 为基准，HTML 为被测对象，
 * 两者必须来自同一 tid 同一 page，才能做逐楼层/逐字段对比（scripts/compare-html-json.ts、
 * tests/html-mode-coverage.test.ts）。
 *
 * 用法：
 *   node scripts/fetch-thread-pair.mjs <tid> [page]
 *
 * 输出（命名规则：html-pair 前缀）：
 *   samples/html-pair-<tid>-p<page>.json   JSON API 原始响应（GBK 解码 + tab 转义，可直接 JSON.parse）
 *   samples/html-pair-<tid>-p<page>.html   read.php 原始 HTML（GBK 解码；与客户端 HTML 模式同源同 UA）
 *   samples/html-pairs.lst                 追加登记一对（每行一个基准名 html-pair-<tid>-p<page>，自动去重）
 *
 * 前置：cookie 依次取环境变量 NGA_COOKIE、tools/bbcode-ts/.nga-cookie.txt（本地持久化，
 * 浏览器登录后 document.cookie，需 ngaPassportUid/ngaPassportCid）。
 * 请求头与 fetch-thread-json.mjs 一致：NGA_WP_JW UA + X-User-Agent: Nga_Official（Mozilla UA 会被 403）。
 *
 * 注意：JSON 与 HTML 响应均 GBK 编码，TextDecoder('gbk') 显式解码。
 */
import { writeFileSync, readFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SAMPLES = join(ROOT, 'samples')
const LIST_FILE = join(SAMPLES, 'html-pairs.lst')
const COOKIE_FILE = join(ROOT, '.nga-cookie.txt')

const args = process.argv.slice(2)
const tid = args[0]
const page = args[1] ?? '1'
const cookie = process.env.NGA_COOKIE ?? (existsSync(COOKIE_FILE) ? readFileSync(COOKIE_FILE, 'utf8').trim() : '')

if (!tid || !/^\d+$/.test(tid)) {
  console.error('用法: node scripts/fetch-thread-pair.mjs <tid> [page]')
  process.exit(1)
}
if (!cookie) {
  console.error('缺少 cookie：设 NGA_COOKIE 环境变量，或把 document.cookie 存入 .nga-cookie.txt（已 gitignore）')
  process.exit(1)
}

const headers = {
  Cookie: cookie,
  'User-Agent': 'NGA_WP_JW',
  'X-User-Agent': 'Nga_Official',
}

async function fetchGbk(url, label) {
  const resp = await fetch(url, { headers })
  if (!resp.ok) {
    console.error(`${label} HTTP ${resp.status}`)
    process.exit(1)
  }
  return new TextDecoder('gbk').decode(await resp.arrayBuffer())
}

const jsonUrl = `https://bbs.nga.cn/read.php?page=${page}&__output=8&tid=${tid}&__inchst=UTF8`
const htmlUrl = `https://bbs.nga.cn/read.php?page=${page}&tid=${tid}`

const jsonText = (await fetchGbk(jsonUrl, 'JSON')).replace(/\t/g, '\\t')
const htmlText = await fetchGbk(htmlUrl, 'HTML')

// 校验：JSON 可解析且含 __R；HTML 含 postArg 调用标记（说明是服务端渲染的完整页面而非 JS 启动壳）
const jsonObj = JSON.parse(jsonText)
const hasRows = typeof jsonObj.data === 'object' && jsonObj.data !== null && '__R' in jsonObj.data
if (!hasRows) {
  console.error(`JSON 响应缺少 data.__R（error=${jsonObj.error} error_msg=${jsonObj.error_msg}），可能未登录/被反爬`)
  process.exit(1)
}
if (!htmlText.includes('commonui.postArg.proc(')) {
  console.error('HTML 响应缺少 commonui.postArg.proc 调用标记，疑似 JS 启动壳而非服务端渲染页面（UA 问题？）')
  process.exit(1)
}

const base = `html-pair-${tid}-p${page}`
const jsonFile = join(SAMPLES, `${base}.json`)
const htmlFile = join(SAMPLES, `${base}.html`)
writeFileSync(jsonFile, jsonText, 'utf8')
writeFileSync(htmlFile, htmlText, 'utf8')

// 登记 html-pairs.lst（去重）
const existing = existsSync(LIST_FILE) ? readFileSync(LIST_FILE, 'utf8').split('\n').map((l) => l.trim()).filter((l) => l.length > 0 && !l.startsWith('#')) : []
if (!existing.includes(base)) {
  writeFileSync(LIST_FILE, existing.concat(base).join('\n') + '\n', 'utf8')
}

const rows = Object.keys(jsonObj.data.__R ?? {}).length
console.log(`tid=${tid} page=${page} -> ${base}`)
console.log(`  JSON: ${rows} 楼, __ROWS=${jsonObj.data.__ROWS} | 文件 ${jsonFile}`)
console.log(`  HTML: ${htmlText.length} 字符 | 文件 ${htmlFile}`)
console.log(`  已登记 ${LIST_FILE}`)
