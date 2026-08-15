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
 *   samples/html-pair-<tid>-p<page>.json   JSON API 原始响应（GBK 解码 + 净化，可直接 JSON.parse）
 *   samples/html-pair-<tid>-p<page>.html   read.php 原始 HTML（GBK 解码；与客户端 HTML 模式同源同 UA）
 *   samples/html-pairs.lst                 追加登记一对（每行一个基准名 html-pair-<tid>-p<page>，自动去重）
 *
 * 通用抓取层（凭证、请求头、GBK 解码、净化）已抽取到 tools/nga-data-fetch
 * （skill: nga-data-fetch）；本脚本保留成对抓取、标记校验与样本登记逻辑。
 */
import { writeFileSync, readFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SAMPLES = join(ROOT, 'samples')
const LIST_FILE = join(SAMPLES, 'html-pairs.lst')

const { fetchNgaJson } = await import('../../nga-data-fetch/lib/json.js')
const { fetchNgaHtml } = await import('../../nga-data-fetch/lib/html.js')

const args = process.argv.slice(2)
const tid = args[0]
const page = args[1] ?? '1'

if (!tid || !/^\d+$/.test(tid)) {
  console.error('用法: node scripts/fetch-thread-pair.mjs <tid> [page]')
  process.exit(1)
}

// JSON 主通道：净化文本可直接落盘；obj 用于校验 data.__R
const jsonResult = await fetchNgaJson('read.php', {
  page,
  __output: 8,
  tid,
  __inchst: 'UTF8',
})
if (!jsonResult.ok) {
  console.error(`JSON 抓取失败 [${jsonResult.kind}]: ${jsonResult.error}`)
  process.exit(1)
}
const jsonObj = jsonResult.obj
const hasRows = typeof jsonObj?.data === 'object' && jsonObj.data !== null && '__R' in jsonObj.data
if (!hasRows) {
  console.error(`JSON 响应缺少 data.__R（error=${jsonObj?.error} error_msg=${jsonObj?.error_msg}），可能未登录/被反爬`)
  process.exit(1)
}

// HTML 降级：与客户端同源 UA/Cookie；校验 postArg 调用标记（服务端渲染完整页而非 JS 启动壳）
const htmlResult = await fetchNgaHtml(
  `https://bbs.nga.cn/read.php?page=${page}&tid=${tid}`,
  { markers: ['commonui.postArg.proc('] },
)
if (!htmlResult.ok) {
  console.error(`HTML 抓取失败: ${htmlResult.error}`)
  process.exit(1)
}
if (htmlResult.matched === false) {
  console.error(`HTML 响应缺少 commonui.postArg.proc 调用标记（${htmlResult.missingMarkers.join(', ')}），疑似 JS 启动壳而非服务端渲染页面（UA 问题？）`)
  process.exit(1)
}

const base = `html-pair-${tid}-p${page}`
const jsonFile = join(SAMPLES, `${base}.json`)
const htmlFile = join(SAMPLES, `${base}.html`)
writeFileSync(jsonFile, jsonResult.raw, 'utf8')
writeFileSync(htmlFile, htmlResult.text, 'utf8')

// 登记 html-pairs.lst（去重）
const existing = existsSync(LIST_FILE) ? readFileSync(LIST_FILE, 'utf8').split('\n').map((l) => l.trim()).filter((l) => l.length > 0 && !l.startsWith('#')) : []
if (!existing.includes(base)) {
  writeFileSync(LIST_FILE, existing.concat(base).join('\n') + '\n', 'utf8')
}

const rows = Object.keys(jsonObj.data.__R ?? {}).length
console.log(`tid=${tid} page=${page} -> ${base}`)
console.log(`  JSON: ${rows} 楼, __ROWS=${jsonObj.data.__ROWS} | 文件 ${jsonFile}`)
console.log(`  HTML: ${htmlResult.text.length} 字符 | 文件 ${htmlFile}`)
console.log(`  已登记 ${LIST_FILE}`)
