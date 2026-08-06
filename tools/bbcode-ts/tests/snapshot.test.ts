import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { parseBBCode } from '../src/parser/bbcode/parser'
import { BBNode } from '../src/model/BBCodeNode'
import { loadSampleContent, nodeToJson } from './helpers'

/** 样本目录。 */
const SAMPLES_DIR: string = join(process.cwd(), 'samples')

/** 样本清单（每行一个文件名，# 开头为注释）。 */
const LIST_FILE: string = join(SAMPLES_DIR, 'samples.lst')

const sampleNames: string[] = readFileSync(LIST_FILE, 'utf8')
  .split('\n')
  .map((line: string) => line.trim())
  .filter((line: string) => line.length > 0 && !line.startsWith('#'))

for (const name of sampleNames) {
  const base: string = name.replace(/\.txt$/, '')
  const SNAPSHOT_FILE: string = join(SAMPLES_DIR, `${base}.snapshot.json`)

  describe(`解析快照回归（${name}）`, () => {
    it('快照基线存在（先运行 npm run snapshot 生成）', () => {
      assert.ok(existsSync(SNAPSHOT_FILE),
        `快照基线不存在。请先运行: npm run snapshot\n（生成 ${SNAPSHOT_FILE} 并人工审查后提交）`)
    })

    it('当前解析结果与基线一致', () => {
      const content: string = loadSampleContent(name)
      const nodes: BBNode[] = parseBBCode(content)
      const current: string = JSON.stringify(nodeToJson(nodes), null, 1)
      const baseline: string = readFileSync(SNAPSHOT_FILE, 'utf8').trim()
      assert.equal(current, baseline,
        '解析结果与快照基线不一致。若为预期变更（解析逻辑修复），请重新生成快照并审查 diff: npm run snapshot')
    })
  })
}
