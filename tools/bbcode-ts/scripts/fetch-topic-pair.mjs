/**
 * 拉取同一用户同页同模式的 thread.php 成对数据（JSON + HTML）并落盘。
 *
 * 用途：HTML 主题列表模式 → JSON 覆盖验证套件的数据采集（用户发帖/回帖记录）。
 * 以 JSON（thread.php?lite=js）为基准，HTML（thread.php 静态页）为被测对象，
 * 两者必须来自同一 authorid 同一 page 同一模式，才能做逐条目/逐字段对比
 * （tests/html-topic-coverage.test.ts）。
 *
 * 用法：
 *   node scripts/fetch-topic-pair.mjs <uid> [reply] [page]
 *     <uid>  用户 id（authorid）
 *     reply  可选：传任意非空值抓取回帖记录（searchpost=1），缺省抓发帖记录
 *     page   页码（默认 1）
 *
 * 输出（命名规则：html-topicpair 前缀）：
 *   samples/html-topicpair-u<uid>[-s1]-p<page>.json   JSON API 响应（净化后）
 *   samples/html-topicpair-u<uid>[-s1]-p<page>.html   thread.php 原始 HTML（GBK 解码）
 *   samples/html-topicpairs.lst                       追加登记一对（自动去重）
 *
 * 通用抓取层（凭证、请求头、GBK 解码、净化）见 tools/nga-data-fetch
 * （skill: nga-data-fetch）；本脚本保留成对抓取、标记校验与样本登记逻辑。
 */
import { writeFileSync, readFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SAMPLES = join(ROOT, 'samples')
const LIST_FILE = join(SAMPLES, 'html-topicpairs.lst')

const { fetchNgaJson } = await import('../../nga-data-fetch/lib/json.js')
const { fetchNgaHtml } = await import('../../nga-data-fetch/lib/html.js')

const args = process.argv.slice(2)
const uid = args[0]
const isReply = args[1] ? true : false
const page = args[2] ?? '1'

if (!uid || !/^\d+$/.test(uid)) {
  console.error('用法: node scripts/fetch-topic-pair.mjs <uid> [reply] [page]')
  process.exit(1)
}

// JSON 主通道：净化文本直接落盘；obj 用于校验 data.__T
const jsonParams = {
  page,
  lite: 'js',
  noprefix: '',
  authorid: uid,
  __inchst: 'UTF8',
}
if (isReply) jsonParams.searchpost = '1'
const jsonResult = await fetchNgaJson('thread.php', jsonParams)
if (!jsonResult.ok) {
  console.error(`JSON 抓取失败 [${jsonResult.kind}]: ${jsonResult.error}`)
  process.exit(1)
}
const jsonObj = jsonResult.obj
const hasT = typeof jsonObj?.data === 'object' && jsonObj.data !== null && '__T' in jsonObj.data
if (!hasT) {
  console.error(`JSON 响应缺少 data.__T（error=${jsonObj?.error} error_msg=${jsonObj?.error_msg}），可能未登录/被反爬`)
  process.exit(1)
}

// HTML 降级：与客户端同源 UA/Cookie；校验 topicArg.add 调用标记（服务端渲染完整页而非 JS 启动壳）
const htmlUrl = `https://bbs.nga.cn/thread.php?authorid=${uid}&page=${page}` +
  (isReply ? '&searchpost=1' : '')
const htmlResult = await fetchNgaHtml(htmlUrl, { markers: ['commonui.topicArg.add('] })
if (!htmlResult.ok) {
  console.error(`HTML 抓取失败: ${htmlResult.error}`)
  process.exit(1)
}
if (htmlResult.matched === false) {
  console.error(`HTML 响应缺少 commonui.topicArg.add 调用标记（${htmlResult.missingMarkers.join(', ')}），疑似 JS 启动壳而非服务端渲染页面（UA 问题？）`)
  process.exit(1)
}

const base = `html-topicpair-u${uid}${isReply ? '-s1' : ''}-p${page}`
const jsonFile = join(SAMPLES, `${base}.json`)
const htmlFile = join(SAMPLES, `${base}.html`)
writeFileSync(jsonFile, jsonResult.raw, 'utf8')
writeFileSync(htmlFile, htmlResult.text, 'utf8')

// 登记 html-topicpairs.lst（去重）
const existing = existsSync(LIST_FILE) ? readFileSync(LIST_FILE, 'utf8').split('\n').map((l) => l.trim()).filter((l) => l.length > 0 && !l.startsWith('#')) : []
if (!existing.includes(base)) {
  writeFileSync(LIST_FILE, existing.concat(base).join('\n') + '\n', 'utf8')
}

const rows = Object.keys(jsonObj.data.__T ?? {}).length
console.log(`uid=${uid} reply=${isReply ? 1 : 0} page=${page} -> ${base}`)
console.log(`  JSON: ${rows} 条 | 文件 ${jsonFile}`)
console.log(`  HTML: ${htmlResult.text.length} 字符 | 文件 ${htmlFile}`)
console.log(`  已登记 ${LIST_FILE}`)
