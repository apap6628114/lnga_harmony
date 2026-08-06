import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { parseBBCode } from '../src/parser/bbcode/parser'
import { BBNode } from '../src/model/BBCodeNode'
import { loadSampleContent, nodeToJson } from '../tests/helpers'

/**
 * 为 samples.lst 中每个样本生成解析快照基线。
 *
 * 运行：npm run snapshot。每个样本生成 samples/<basename>.snapshot.json
 * （如 demo.txt → demo.snapshot.json），提交前人工审查 git diff。
 */

/** 样本目录。 */
const SAMPLES_DIR: string = join(process.cwd(), 'samples')

/** 样本清单（每行一个文件名，# 开头为注释）。 */
const LIST_FILE: string = join(SAMPLES_DIR, 'samples.lst')

const sampleNames: string[] = readFileSync(LIST_FILE, 'utf8')
  .split('\n')
  .map((line: string) => line.trim())
  .filter((line: string) => line.length > 0 && !line.startsWith('#'))

for (const name of sampleNames) {
  const content: string = loadSampleContent(name)
  const nodes: BBNode[] = parseBBCode(content)
  const json: string = JSON.stringify(nodeToJson(nodes), null, 1)
  const base: string = name.replace(/\.txt$/, '')
  const out: string = join(SAMPLES_DIR, `${base}.snapshot.json`)
  writeFileSync(out, json, 'utf8')
  console.log(`已生成 ${out}（${nodes.length} 个顶层节点，${json.length} 字符）`)
}
