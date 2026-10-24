#!/usr/bin/env node
/**
 * 抓取官方 APP 通知中心列表（app_api.php?__lib=notify&__act=list，__output=14）。
 *
 * 与 App 内 `MessageApi.getNotifications` 同参数（checksum / time_limit=0 / get=111），
 * 便于线下复现"我的消息"里的具体通知记录，例如指向已删除楼层的残留回复通知。
 *
 * 用法：node tools/nga-data-fetch/scripts/fetch-notify.js [输出文件]
 * 默认输出到 tools/nga-data-fetch/out/notify-list.json（不依赖调用方 cwd）。
 */
'use strict'

const { mkdirSync, writeFileSync } = require('node:fs')
const { dirname, join } = require('node:path')

const { resolveCookie } = require('../lib/credential.js')
const { fetchNgaAppJson, parseAppCredential, makeClientChecksum } = require('../lib/app.js')

/** 默认输出路径：固定落在工具自己的 out/ 目录。 */
const DEFAULT_OUT = join(__dirname, '..', 'out', 'notify-list.json')

async function main() {
  const out = process.argv[2] || DEFAULT_OUT
  const cookie = resolveCookie()
  const credential = parseAppCredential(cookie)
  if (!credential.uid || !credential.token) {
    console.error('APP 凭证缺少 uid 或 token')
    process.exit(1)
  }
  const ts = String(Math.floor(Date.now() / 1000))
  const result = await fetchNgaAppJson('/app_api.php', {
    __ngaClientChecksum: makeClientChecksum(credential.uid, ts),
    time_limit: '0',
    get: '111',
  }, {
    output: '14',
    query: { __lib: 'notify', __act: 'list' },
    raw: true,
  })
  if (!result.ok) {
    console.error(`notify/list 失败 [${result.kind}]: ${result.error || ''}`)
    process.exit(1)
  }
  mkdirSync(dirname(out), { recursive: true })
  writeFileSync(out, result.raw, 'utf8')
  let summary = `notify/list -> ${out}（${result.raw.length} 字符）`
  try {
    const obj = JSON.parse(result.raw)
    const body = obj && obj.result ? obj.result : {}
    summary += ` code=${obj.code} reply=${(body.reply || []).length}` +
      ` msg=${(body.msg || []).length} sys=${(body.sys || []).length}`
  } catch (e) {
    summary += ` 非 JSON：${e.message}`
  }
  console.log(summary)
}

main().catch((err) => {
  console.error(`未预期错误: ${err.message}`)
  process.exit(1)
})
