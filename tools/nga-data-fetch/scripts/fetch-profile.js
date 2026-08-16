'use strict'
/**
 * fetch-profile —— 抓取当前持久化账号的个人资料数据。
 *
 * 流程：
 *   1) read.php 门禁基准 → data.__CU 取当前登录用户 uid（不打印明文）
 *   2) nuke.php?__lib=ucp&__act=get&uid=<uid>&__output=8&__inchst=UTF8 → 资料 JSON，落盘 out/profile-ucp.json
 *   3) nuke.php?func=ucp&uid=<uid> → 网页资料页，落盘 out/profile-page.html
 *   4) 控制台输出整理摘要（uid 打码，时间戳转可读）
 *
 * 用法：node scripts/fetch-profile.js
 */
const { writeFileSync, mkdirSync } = require('node:fs')
const { join } = require('node:path')

const { fetchNgaJson } = require('../lib/json.js')
const { ngaFetchText, buildApiUrl } = require('../lib/request.js')
const { resolveCookie } = require('../lib/credential.js')

const OUT_DIR = join(__dirname, '..', 'out')

function maskUid(v) {
  const s = String(v)
  if (s.length <= 4) return '****'
  return s.slice(0, 2) + '***' + s.slice(-2)
}

function ts2str(ts) {
  const n = Number(ts)
  if (!n || Number.isNaN(n) || n <= 0) return String(ts)
  return new Date(n * 1000).toISOString().replace('T', ' ').slice(0, 19) + ' (UTC)'
}

function fmt(k, v) {
  if (k.toLowerCase().includes('uid')) return maskUid(v)
  if (/^regdate$|^lastvisit$|^thisvisit$|^lastpost$|^muteTime$|^mute_time$/.test(k)) return ts2str(v)
  if (typeof v === 'string' && v.length > 80) return v.slice(0, 80) + '…'
  if (typeof v === 'object') return JSON.stringify(v)
  return String(v)
}

async function main() {
  mkdirSync(OUT_DIR, { recursive: true })
  const cookie = resolveCookie()

  // 1) 当前用户 uid
  const post = await fetchNgaJson('read.php', {
    tid: '44191387', page: '1', __output: '8', __inchst: 'UTF8',
  })
  if (!post.ok) { console.error('门禁基准获取失败:', post.error); process.exit(1) }
  const uid = post.obj && post.obj.data && post.obj.data.__CU && post.obj.data.__CU.uid
  if (!uid) { console.error('无法从 __CU 定位当前用户'); process.exit(1) }
  console.log('当前账号 uid =', maskUid(uid))

  // 2) ucp get 资料 JSON
  const ucp = await fetchNgaJson('nuke.php', {
    __lib: 'ucp', __act: 'get', uid: String(uid), __output: '8', __inchst: 'UTF8',
  })
  if (!ucp.ok) { console.error('ucp get 失败:', ucp.error); process.exit(1) }
  const profile = (ucp.obj.data && ucp.obj.data['0']) || ucp.obj.data
  if (!profile || typeof profile !== 'object') {
    console.error('ucp get 响应形态异常'); process.exit(1)
  }
  const jsonFile = join(OUT_DIR, 'profile-ucp.json')
  writeFileSync(jsonFile, JSON.stringify(profile, null, 2), 'utf8')
  console.log(`资料 JSON 已落盘 -> ${jsonFile}`)

  console.log('\n===== 个人资料摘要 =====')
  for (const k of Object.keys(profile)) {
    console.log(`  ${k}: ${fmt(k, profile[k])}`)
  }

  // 3) 网页资料页（补充统计信息）
  const html = await ngaFetchText(buildApiUrl('nuke.php', { func: 'ucp', uid: String(uid) }), { cookie })
  if (html.ok && html.text.length > 0) {
    const htmlFile = join(OUT_DIR, 'profile-page.html')
    writeFileSync(htmlFile, html.text, 'utf8')
    console.log(`\n网页资料页已落盘 -> ${htmlFile}（${html.text.length} 字符）`)
  } else {
    console.log('\n网页资料页抓取失败:', html.error || '空响应')
  }
}

main().catch((e) => { console.error('未预期错误:', e.message); process.exit(1) })
