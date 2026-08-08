/**
 * 拉取 NGA 帖子 JSON 调试数据并落盘（官方 API __output=8）。
 *
 * 用法：
 *   node scripts/fetch-thread-json.mjs <tid> [page] [输出文件名] [lou]
 *
 * 参数（按内容识别，位置可灵活）：
 *   tid / page / lou  依次为三个数字参数；lou 省略时输出整页数据，指定时提取该楼层内容
 *   输出文件名  非数字参数；省略时按页与楼层自动命名
 *
 * 输出：
 *   无 lou → 整页 JSON（GBK 解码 + tab 转义，可直接 JSON.parse，data.__R 为楼层列表）
 *   有 lou → 该楼层 content，输出为 `"content": "..."` 格式
 *            （tests/helpers.ts::loadSampleContent 直接可读，可直接存 samples/ 固化）
 *
 * 前置：cookie 从环境变量 NGA_COOKIE 读取（登录后浏览器 document.cookie）；
 * 响应 GBK 编码，TextDecoder('gbk') 显式解码；UA 用 NGA_WP_JW。
 *
 * 注：官方网页渲染 DOM 无法静态抓取（read.php 对静态请求返回 JS 启动壳），
 * 渲染后楼层 DOM 需用浏览器 devtools 从已渲染页面提取（README 调试流程第 5-8 步）。
 */
import { writeFileSync } from 'node:fs'

// 数字参数依次为 tid / page / lou；非数字参数为输出文件名
const args = process.argv.slice(2)
const nums = args.filter((a) => /^\d+$/.test(a))
const tid = nums[0]
const page = nums[1] ?? '1'
const lou = nums[2] ?? null
const cookie = process.env.NGA_COOKIE

const defaultName = `raw-tid${tid}-page${page}${lou !== null ? `-lou${lou}` : ''}.json`
const outFile = args.find((a) => !/^\d+$/.test(a)) ?? defaultName

if (!tid) {
  console.error('用法: node scripts/fetch-thread-json.mjs <tid> [page] [输出文件名] [lou]')
  process.exit(1)
}
if (!cookie) {
  console.error('缺少环境变量 NGA_COOKIE（浏览器 document.cookie）')
  process.exit(1)
}

const url = `https://bbs.nga.cn/read.php?page=${page}&__output=8&tid=${tid}&__inchst=UTF8`

const resp = await fetch(url, {
  headers: {
    Cookie: cookie,
    'User-Agent': 'NGA_WP_JW',
    'X-User-Agent': 'Nga_Official',
  },
})

if (!resp.ok) {
  console.error(`HTTP ${resp.status}`)
  process.exit(1)
}

const sanitized = new TextDecoder('gbk').decode(await resp.arrayBuffer()).replace(/\t/g, '\\t')

if (lou !== null) {
  // 提取指定楼层 content，输出 loadSampleContent 兼容格式
  const obj = JSON.parse(sanitized)
  const rows = Object.values(obj.data?.__R ?? {})
  const floor = rows.find((r) => r.lou === Number(lou))
  if (!floor) {
    console.error(`第 ${page} 页中未找到 lou=${lou} 楼层`)
    process.exit(1)
  }
  writeFileSync(outFile, `"content": ${JSON.stringify(floor.content)},`, 'utf8')
  console.log(`tid=${tid} page=${page} lou=${lou} -> ${outFile}（content ${floor.content.length} 字符）`)
  console.log(`subject=${floor.subject ?? ''}`)
  process.exit(0)
}

writeFileSync(outFile, sanitized, 'utf8')

// 校验可解析性 + 完整性
const obj = JSON.parse(sanitized)
const hasRows = typeof obj.data === 'object' && obj.data !== null && '__R' in obj.data
console.log(`tid=${tid} page=${page} -> ${outFile}`)
console.log(`error=${obj.error} error_msg=${obj.error_msg} data.__R 存在=${hasRows}`)
console.log(`楼层数=${hasRows ? obj.data.__R.length : 'N/A'}`)
