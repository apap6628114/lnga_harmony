#!/usr/bin/env node
/**
 * TS 镜像 → ArkTS 源码 单向同步脚本。
 *
 * 真源是 tools/bbcode-ts/src/ 下的 TS 镜像（在 Node 环境验证过的解析/渲染逻辑）；
 * 本脚本将镜像机械写回 entry/src/main/ets/ 对应的 .ets 文件。
 * 仅做扩展名替换与内容拷贝，不做任何改写——镜像代码必须始终遵守 ArkTS 子集，
 * 否则生成的 .ets 无法通过 DevEco 编译。
 *
 * 用法：
 *   node scripts/sync-to-ets.mjs          # 实际同步
 *   node scripts/sync-to-ets.mjs --dry    # 只打印将发生的变更
 */
import { readdirSync, readFileSync, writeFileSync, statSync } from 'node:fs'
import { join, relative, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const MIRROR_DIR = join(ROOT, 'src')
const TARGET_DIR = join(ROOT, '..', '..', 'entry', 'src', 'main', 'ets')

const dryRun = process.argv.includes('--dry')

/**
 * 递归收集目录下所有 .ts 文件。
 *
 * @param {string} dir 起始目录
 * @returns {string[]} 文件绝对路径列表
 */
function collectTsFiles(dir) {
  const out = []
  for (const name of readdirSync(dir)) {
    const full = join(dir, name)
    if (statSync(full).isDirectory()) {
      out.push(...collectTsFiles(full))
    } else if (name.endsWith('.ts')) {
      out.push(full)
    }
  }
  return out
}

const changed = []
const added = []
let skipped = 0

for (const mirrorFile of collectTsFiles(MIRROR_DIR)) {
  const rel = relative(MIRROR_DIR, mirrorFile) // 如 parser/bbcode/lexer.ts
  const targetRel = rel.replace(/\.ts$/, '.ets')
  const targetFile = join(TARGET_DIR, targetRel)

  const mirrorContent = readFileSync(mirrorFile, 'utf8')
  let targetContent = null
  try {
    targetContent = readFileSync(targetFile, 'utf8')
  } catch {
    // 目标不存在 → 新增
  }

  if (targetContent === mirrorContent) {
    skipped++
    continue
  }
  if (targetContent === null) {
    added.push(targetRel)
  } else {
    changed.push(targetRel)
  }

  if (!dryRun) writeFileSync(targetFile, mirrorContent, 'utf8')
}

console.log(dryRun ? '[dry-run] 将执行以下同步：' : '同步完成：')
console.log(`  修改 ${changed.length} 个文件：`)
for (const f of changed) console.log(`    ~ ${f}`)
console.log(`  新增 ${added.length} 个文件：`)
for (const f of added) console.log(`    + ${f}`)
console.log(`  无变化跳过 ${skipped} 个文件`)
