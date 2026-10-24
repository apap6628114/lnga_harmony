#!/usr/bin/env node
/**
 * 调试：把 APP read.php __output=17 的帖子 HTML 解析为同形状 JSON，并列出楼层/贴条 pid。
 *
 * 用法：
 *   node scripts/inspect-html-pids.js <html文件> [目标pid ...]
 *
 * 目标 pid 若出现在某楼的 comments（贴条）里会单独标注——贴条不是独立楼层，
 * 没有自己的 __R 行。贴条 pid 能否作为 read.php?pid= 的单帖入口打开**尚未验证**：
 * 本脚本只陈述页面结构，不推断服务端对贴条 pid 的单帖行为。
 */
'use strict'

const { readFileSync } = require('node:fs')
const { join } = require('node:path')

const ROOT = join(__dirname, '..', '..', 'bbcode-ts')
const { parseHtmlToRawJson } = require(join(ROOT, 'dist', 'src', 'parser', 'nga', 'html-thread', 'index.js'))

function main() {
  const args = process.argv.slice(2)
  const file = args[0]
  const targets = args.slice(1)
  if (!file) {
    console.error('用法: node scripts/inspect-html-pids.js <html文件> [目标pid ...]')
    process.exit(1)
  }
  const html = readFileSync(file, 'utf8')
  const parsed = parseHtmlToRawJson(html)
  const data = parsed.data || {}
  const rows = data.__R || {}
  const lous = Object.keys(rows)
  console.log(`__PAGE=${data.__PAGE} __ROWS=${data.__ROWS} __R__ROWS_PAGE=${data.__R__ROWS_PAGE} 楼层行=${lous.length}` +
    ` __R存在=${data.__R !== undefined} data键=${Object.keys(data).join(',')}`)
  for (const lou of lous) {
    const row = rows[lou]
    const comments = Array.isArray(row.comments) ? row.comments : []
    console.log(`lou=${lou} pid=${row.pid} authorid=${row.authorid} author=${row.author} comments=${comments.length}` +
      (row.comment_to_id !== undefined ? ` comment_to_id=${row.comment_to_id}` : ''))
    for (const comment of comments) {
      console.log(`    comment pid=${comment.pid} authorid=${comment.authorid} lou=${comment.lou}` +
        ` subject=${String(comment.subject || '').slice(0, 40)}`)
    }
  }
  const rowPids = lous.map((lou) => String(rows[lou].pid))
  for (const target of targets) {
    const direct = rowPids.indexOf(target)
    if (direct >= 0) {
      console.log(`目标 pid=${target} -> 楼层行 lou=${lous[direct]}（页内可直接定位）`)
      continue
    }
    let found = false
    for (const lou of lous) {
      const comments = Array.isArray(rows[lou].comments) ? rows[lou].comments : []
      for (const comment of comments) {
        if (String(comment.pid) === target) {
          console.log(`目标 pid=${target} -> 贴条（comment），挂在 lou=${lou} 主楼 pid=${rows[lou].pid} 下（无独立楼层行）`)
          found = true
        }
      }
    }
    if (!found) {
      console.log(`目标 pid=${target} -> 本页既无楼层行也无贴条`)
    }
  }
}

main()
