import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { parseHtmlToRawJson } from '../src/parser/nga/html-thread/index'

/** HTML 降级调试脚本所在工具目录。 */
const ROOT: string = process.cwd()

/** 本地登录 Cookie 文件。 */
const COOKIE_FILE: string = join(ROOT, '.nga-cookie.txt')

/** HTML 转换结果的最小数据形状。 */
interface HtmlThreadResult {
  /** 帖子数据。 */
  data: HtmlThreadData
}

/** HTML 转换结果中的帖子数据。 */
interface HtmlThreadData {
  /** 以页面楼层号为键的楼层表。 */
  __R: Record<string, Object>
}

/**
 * 输出一个 HTML 降级转 JSON 楼层的调试摘要。
 *
 * @param lou 页面楼层号
 * @param row 楼层原始字段
 * @param fullContent 是否输出完整正文
 */
function printRow(lou: string, row: Record<string, Object>, fullContent: boolean): void {
  const content: string = String(row['content'] ?? '')
  const shownContent: string = fullContent || content.length <= 180 ? content : content.substring(0, 180) + '…'
  console.log(`lou=${lou} pid=${String(row['pid'] ?? '')} authorid=${String(row['authorid'] ?? '')}`)
  console.log(`author=${String(row['author'] ?? '')} subject=${String(row['subject'] ?? '')}`)
  console.log(`content=${shownContent}`)
}

/**
 * 在 JSON 主通道不可用或专门调查 HTML 模式时，抓取 NGA 静态 HTML，
 * 经客户端同源降级解析器转换后输出指定楼层。
 */
async function main(): Promise<void> {
  const args: string[] = process.argv.slice(2)
  const tid: string = args[0] ?? ''
  const page: string = args[1] ?? '1'
  const requestedLous: string[] = args.slice(2)
  if (!/^\d+$/.test(tid) || !/^\d+$/.test(page) ||
    requestedLous.some((lou: string): boolean => !/^\d+$/.test(lou))) {
    console.error('用法: npm run inspect:html -- <tid> [page] [lou ...]')
    process.exitCode = 1
    return
  }

  const cookie: string = process.env.NGA_COOKIE ??
    (existsSync(COOKIE_FILE) ? readFileSync(COOKIE_FILE, 'utf8').trim() : '')
  if (cookie.length === 0) {
    console.error('缺少 cookie：设 NGA_COOKIE，或写入 tools/bbcode-ts/.nga-cookie.txt')
    process.exitCode = 1
    return
  }

  const url: string = `https://bbs.nga.cn/read.php?page=${page}&tid=${tid}`
  const response: Response = await fetch(url, {
    headers: {
      Cookie: cookie,
      'User-Agent': 'NGA_WP_JW',
      'X-User-Agent': 'Nga_Official',
    },
  })
  if (!response.ok) {
    console.error(`HTML HTTP ${response.status}`)
    process.exitCode = 1
    return
  }

  const bytes: ArrayBuffer = await response.arrayBuffer()
  const html: string = new TextDecoder('gbk').decode(bytes)
  if (!html.includes('commonui.postArg.proc(')) {
    console.error('HTML 缺少 commonui.postArg.proc 标记，无法确认是完整帖子页')
    process.exitCode = 1
    return
  }

  const parsed: HtmlThreadResult = parseHtmlToRawJson(html) as HtmlThreadResult
  const rows: Record<string, Object> = parsed.data.__R
  const allLous: string[] = Object.keys(rows).sort((left: string, right: string): number =>
    Number(left) - Number(right))
  const selectedLous: string[] = requestedLous.length > 0 ? requestedLous : allLous
  console.log(`tid=${tid} page=${page} HTML=${bytes.byteLength} 字节 转换楼层=${allLous.length}`)

  for (let index: number = 0; index < selectedLous.length; index++) {
    const lou: string = selectedLous[index]
    const rawRow: Object | undefined = rows[lou]
    if (rawRow === undefined) {
      console.log(`lou=${lou} 未找到`)
      continue
    }
    printRow(lou, rawRow as Record<string, Object>, requestedLous.length > 0)
  }
}

main().catch((error: Error): void => {
  console.error(error.message)
  process.exitCode = 1
})
