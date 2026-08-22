/**
 * 拉取同一帖子同页的网页 JSON（__output=8）与官方 APP HTML
 * （签名 POST read.php __output=17 + __localres=1）成对样本。
 *
 * 用法：node scripts/fetch-thread-app-pair.mjs <tid> [page]
 */
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SAMPLES = join(ROOT, 'samples')
const LIST_FILE = join(SAMPLES, 'app-html-pairs.lst')
const PROBE_TID = '44191387'

const { fetchNgaJson } = await import('../../nga-data-fetch/lib/json.js')
const { fetchNgaAppArticleHtml } = await import('../../nga-data-fetch/lib/app.js')

const args = process.argv.slice(2)
const tid = args[0]
const page = args[1] ?? '1'

if (!tid || !/^\d+$/.test(tid)) {
  console.error('用法: node scripts/fetch-thread-app-pair.mjs <tid> [page]')
  process.exit(1)
}

const probe = await fetchNgaJson('read.php', {
  tid: PROBE_TID,
  page: '1',
  __output: 8,
  __inchst: 'UTF8',
})
const probeRows = probe.obj?.data?.__R
if (!probe.ok || typeof probeRows !== 'object' || probeRows === null) {
  console.error(`凭证门禁未通过：固定基准 tid=${PROBE_TID} 未获取到 data.__R`)
  process.exit(1)
}

const webJson = await fetchNgaJson('read.php', {
  page,
  __output: 8,
  tid,
  __inchst: 'UTF8',
})
if (!webJson.ok || typeof webJson.obj?.data?.__R !== 'object') {
  console.error(`网页 JSON 抓取失败 [${webJson.kind}]: ${webJson.error || '缺少 data.__R'}`)
  process.exit(1)
}

const appHtml = await fetchNgaAppArticleHtml({
  tid,
  pid: '',
  topid: '',
  authorid: '',
  opt: '',
  page,
  __localres: '1',
})
if (!appHtml.ok) {
  console.error(`APP HTML 抓取失败 [${appHtml.kind}]: ${appHtml.error}`)
  process.exit(1)
}
if (!appHtml.html.includes('commonui.postArg.proc(')) {
  console.error('APP HTML 缺少 commonui.postArg.proc 标记，无法作为帖子解释样本')
  process.exit(1)
}

const base = `app-html-pair-${tid}-p${page}`
const jsonFile = join(SAMPLES, `${base}.json`)
const htmlFile = join(SAMPLES, `${base}.html`)
writeFileSync(jsonFile, webJson.raw, 'utf8')
writeFileSync(htmlFile, appHtml.html, 'utf8')

const existing = existsSync(LIST_FILE)
  ? readFileSync(LIST_FILE, 'utf8').split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith('#'))
  : []
if (!existing.includes(base)) {
  writeFileSync(LIST_FILE, existing.concat(base).join('\n') + '\n', 'utf8')
}

const rows = Object.keys(webJson.obj.data.__R).length
console.log(`tid=${tid} page=${page} -> ${base}`)
console.log(`  网页 JSON: ${rows} 楼, __ROWS=${webJson.obj.data.__ROWS} | ${jsonFile}`)
console.log(`  APP HTML: ${appHtml.html.length} 字符 | ${htmlFile}`)
console.log(`  已登记 ${LIST_FILE}`)
