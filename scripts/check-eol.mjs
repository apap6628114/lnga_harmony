#!/usr/bin/env node
/**
 * 仓库行尾检查：确保所有已跟踪文本文件为 LF（无 CRLF、无混合行尾、无 BOM）。
 *
 * 用法：
 *   node scripts/check-eol.mjs            检查（发现违规退出码 1）
 *   node scripts/check-eol.mjs --fix      字节级修复（仅删除 CRLF 中的 CR，不触碰编码）
 *
 * 背景：仓库通过 .gitattributes（* text=auto eol=lf）强制 LF 入库/检出，
 * 但 Windows 工具/脚本直接写盘可能产出 CRLF 或混合行尾，且 git 对混合行尾
 * 文件的 eol 判断不可靠（git ls-files --eol 按多数行归类）。本脚本以字节
 * 级检测为准，供 AI 维护自检与 CI 门禁复用。
 */
import { execSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync, statSync } from 'node:fs'
import { join } from 'node:path'

const fix = process.argv.includes('--fix')
/** 二进制扩展名白名单（其余视为文本参与检测）。 */
const binaryExt = /\.(png|jpg|jpeg|gif|webp|bmp|ico|hap|jar|zip|gz|woff2?|ttf|otf|mp3|mp4|wav|aac|flac)$/i

const files = execSync('git ls-files', { encoding: 'utf8' }).split('\n').filter(Boolean)
let bad = 0

for (const f of files) {
  if (binaryExt.test(f)) continue
  const p = join(process.cwd(), f)
  if (!existsSync(p) || !statSync(p).isFile()) continue
  const b = readFileSync(p)
  // 含 NUL 视为二进制，跳过
  if (b.includes(0)) continue
  const hasCr = b.includes(13)
  const hasLf = b.includes(10)
  const hasBom = b.length >= 3 && b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf
  if (!(hasCr && hasLf) && !hasBom) continue

  bad++
  if (fix) {
    const out = []
    for (let i = 0; i < b.length; i++) {
      if (b[i] === 13 && i + 1 < b.length && b[i + 1] === 10) continue
      if (hasBom && i < 3) continue
      out.push(b[i])
    }
    writeFileSync(p, Buffer.from(out))
    console.log(`[fix] ${f}${hasBom ? ' (BOM)' : ''}`)
  } else {
    console.log(`[bad] ${f}${hasBom ? ' (BOM)' : ' (CRLF/混合行尾)'}`)
  }
}

if (bad > 0 && !fix) {
  console.error(`\n发现 ${bad} 个文件行尾违规。修复：node scripts/check-eol.mjs --fix`)
  process.exit(1)
}
console.log(bad === 0 ? 'OK: 全部已跟踪文本文件为 LF' : `已修复 ${bad} 个文件（修复后请 git add 并复查 git status）`)
