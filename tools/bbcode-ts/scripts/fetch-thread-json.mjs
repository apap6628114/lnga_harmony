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
 *   无 lou → 整页 JSON（GBK 解码 + preprocessJson 净化，可直接 JSON.parse，data.__R 为楼层列表）
 *   有 lou → 该楼层 content，输出为 `"content": "..."` 格式
 *            （tests/helpers.ts::loadSampleContent 直接可读，可直接存 samples/ 固化）
 *
 * 通用抓取层（凭证解析、请求头、GBK 解码、JSON 净化）已抽取到 tools/nga-data-fetch
 * （skill: nga-data-fetch）；本脚本只保留帖子特定的参数解析与楼层提取。
 */
import { writeFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')

const { fetchNgaJson } = await import('../../nga-data-fetch/lib/json.js')

// 数字参数依次为 tid / page / lou；非数字参数为输出文件名
const args = process.argv.slice(2)
const nums = args.filter((a) => /^\d+$/.test(a))
const tid = nums[0]
const page = nums[1] ?? '1'
const lou = nums[2] ?? null

const defaultName = `raw-tid${tid}-page${page}${lou !== null ? `-lou${lou}` : ''}.json`
const outFile = args.find((a) => !/^\d+$/.test(a)) ?? defaultName

if (!tid) {
  console.error('用法: node scripts/fetch-thread-json.mjs <tid> [page] [输出文件名] [lou]')
  process.exit(1)
}

const result = await fetchNgaJson('read.php', {
  page,
  __output: 8,
  tid,
  __inchst: 'UTF8',
})

if (!result.ok) {
  console.error(`抓取失败 [${result.kind}]: ${result.error}`)
  process.exit(1)
}

if (lou !== null) {
  // 提取指定楼层 content，输出 loadSampleContent 兼容格式
  const obj = JSON.parse(result.raw)
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

writeFileSync(outFile, result.raw, 'utf8')

// 校验可解析性 + 完整性
const obj = JSON.parse(result.raw)
const hasRows = typeof obj.data === 'object' && obj.data !== null && '__R' in obj.data
console.log(`tid=${tid} page=${page} -> ${outFile}`)
console.log(`error=${obj.error ?? 0} error_msg=${obj.error_msg ?? ''} data.__R 存在=${hasRows}`)
console.log(`楼层数=${hasRows ? Object.keys(obj.data.__R).length : 'N/A'}`)
