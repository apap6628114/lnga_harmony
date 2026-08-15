/**
 * HTML 降级调试：抓取 NGA 静态 read.php，经客户端同源降级解析器转换后输出指定楼层。
 *
 * 用法：
 *   node scripts/inspect-thread-html.mjs <tid> [page] [lou ...]
 *
 * 在 JSON 主通道不可用或专门调查 HTML 模式时使用（AGENTS.md R2.4）。
 * 通用抓取层（凭证、请求头、GBK 解码、标记检查）来自 tools/nga-data-fetch；
 * 帖子页 → JSON 同形状的解析（parseHtmlToRawJson）是 nga-bbcode-ts 镜像真源，
 * 从 dist 产物引用（需先 npm run build）。
 */
import { createRequire } from 'node:module'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const require = createRequire(import.meta.url)
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')

const { fetchNgaHtml } = await import('../../nga-data-fetch/lib/html.js')
const { parseHtmlToRawJson } = require('../dist/src/parser/nga/html-thread/index.js')

/** 输出一个 HTML 降级转 JSON 楼层的调试摘要。 */
function printRow(lou, row, fullContent) {
  const content = String(row['content'] ?? '')
  const shownContent = fullContent || content.length <= 180 ? content : content.substring(0, 180) + '…'
  console.log(`lou=${lou} pid=${String(row['pid'] ?? '')} authorid=${String(row['authorid'] ?? '')}`)
  console.log(`author=${String(row['author'] ?? '')} subject=${String(row['subject'] ?? '')}`)
  console.log(`content=${shownContent}`)
}

async function main() {
  const args = process.argv.slice(2)
  const tid = args[0] ?? ''
  const page = args[1] ?? '1'
  const requestedLous = args.slice(2)
  if (!/^\d+$/.test(tid) || !/^\d+$/.test(page) ||
    requestedLous.some((lou) => !/^\d+$/.test(lou))) {
    console.error('用法: npm run inspect:html -- <tid> [page] [lou ...]')
    process.exitCode = 1
    return
  }

  const result = await fetchNgaHtml(
    `https://bbs.nga.cn/read.php?page=${page}&tid=${tid}`,
    { markers: ['commonui.postArg.proc('] },
  )
  if (!result.ok) {
    console.error(`HTML 抓取失败: ${result.error}`)
    process.exitCode = 1
    return
  }
  if (result.matched === false) {
    console.error(`HTML 缺少 commonui.postArg.proc 标记（${result.missingMarkers.join(', ')}），无法确认是完整帖子页`)
    process.exitCode = 1
    return
  }

  const parsed = parseHtmlToRawJson(result.text)
  const rows = parsed.data.__R
  const allLous = Object.keys(rows).sort((left, right) => Number(left) - Number(right))
  const selectedLous = requestedLous.length > 0 ? requestedLous : allLous
  console.log(`tid=${tid} page=${page} HTML=${result.text.length} 字符 转换楼层=${allLous.length}`)

  for (const lou of selectedLous) {
    const rawRow = rows[lou]
    if (rawRow === undefined) {
      console.log(`lou=${lou} 未找到`)
      continue
    }
    printRow(lou, rawRow, requestedLous.length > 0)
  }
}

main().catch((error) => {
  console.error(error.message)
  process.exitCode = 1
})
