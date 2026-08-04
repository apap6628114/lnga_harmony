import { writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { parseBBCode } from '../src/parser/bbcode/parser'
import { BBNode } from '../src/model/BBCodeNode'
import { loadSampleContent, nodeToJson } from '../tests/helpers'

/**
 * 生成 demo.txt 解析快照基线。
 *
 * 运行：npm run snapshot。生成 samples/demo.snapshot.json，
 * 提交前人工审查 diff（git diff samples/demo.snapshot.json）。
 */

const SAMPLES_DIR: string = join(process.cwd(), 'samples')
const SNAPSHOT_FILE: string = join(SAMPLES_DIR, 'demo.snapshot.json')

const content: string = loadSampleContent('demo.txt')
const nodes: BBNode[] = parseBBCode(content)
const json: string = JSON.stringify(nodeToJson(nodes), null, 1)

writeFileSync(SNAPSHOT_FILE, json, 'utf8')
console.log(`已生成 ${SNAPSHOT_FILE}（${nodes.length} 个顶层节点，${json.length} 字符）`)
