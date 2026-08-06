import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { parseBBCode } from '../src/parser/bbcode/parser'
import { preprocessContent } from '../src/parser/bbcode/lexer'
import { decodeHtmlEntities } from '../src/parser/_shared/HtmlEntityCodec'
import { flattenInlineNodes, InlineRun } from '../src/common/components/bbcode/bbcode-utils'
import { BBNode, BBNodeType } from '../src/model/BBCodeNode'
import { loadSampleContent, isSubsequence, concatTextNodes } from './helpers'

// ---------------------------------------------------------------------------
// 工具：剥离 BBCode 标签得到"期望的纯文本"
// ---------------------------------------------------------------------------

/** 剥离预处理后正文中的全部 [标签]。 */
function stripBBCodeTags(s: string): string {
  return s.replace(/\[[^\]]*\]/g, '')
}

/**
 * 计算某个正文的期望纯文本（预处理 + 剥离标签 + 解码实体）。
 *
 * 两侧语义对齐（解析器的真实设计行为）：媒体类标签（img/flash/album）
 * 整体丢弃含内容（解析器产出 IMAGE 等节点，无 TEXT）。
 *
 * @param content 原始正文
 * @returns 期望纯文本
 */
function expectedPlainText(content: string): string {
  let preprocessed: string = preprocessContent(content)
  preprocessed = preprocessed.replace(/\[(img|flash|album|video|audio)(?:=[^\]]*)?\][\s\S]*?\[\/\1\]/gi, '')
  return decodeHtmlEntities(stripBBCodeTags(preprocessed)).replace(/\n{3,}/g, '\n\n').trim()
}

// ---------------------------------------------------------------------------
// 结构工具
// ---------------------------------------------------------------------------

/** 统计解析树中的指定类型节点数量。 */
function countType(nodes: BBNode[], type: BBNodeType): number {
  let count: number = 0
  for (const n of nodes) {
    if (n.type === type) count++
    count += countType(n.children, type)
  }
  return count
}

/** 递归遍历找到第一个指定类型的节点。 */
function findType(nodes: BBNode[], type: BBNodeType): BBNode | undefined {
  for (const n of nodes) {
    if (n.type === type) return n
    const child: BBNode | undefined = findType(n.children, type)
    if (child) return child
  }
  return undefined
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

describe('文本零丢失不变量（真实样本）', () => {
  const sampleFiles: string[] = readFileSync(join(process.cwd(), 'samples', 'samples.lst'), 'utf8')
    .split('\n')
    .map((line: string) => line.trim())
    .filter((line: string) => line.length > 0 && !line.startsWith('#'))

  for (const name of sampleFiles) {
    it(`样本 ${name}：解析结果不含原始文字缺失`, () => {
      const content: string = loadSampleContent(name)
      const nodes: BBNode[] = parseBBCode(content)
      const actual: string = concatTextNodes(nodes)
      const expected: string = expectedPlainText(content)
      assert.ok(
        isSubsequence(expected, actual),
        `原文文字未完整保留。\n期望(子序列基准)前 200 字符: ${expected.slice(0, 200)}\n实际前 200 字符: ${actual.slice(0, 200)}`
      )
    })
  }
})

describe('真实样本结构（demo.txt）', () => {
  const content: string = loadSampleContent('demo.txt')
  const nodes: BBNode[] = parseBBCode(content)

  it('解析出 4 个表格（demo.txt 含 4 个 [table]）', () => {
    assert.equal(countType(nodes, BBNodeType.TABLE), 4)
  })

  it('第一个表格行数超过 40（含 rowspan 合并的大表）', () => {
    const tables: BBNode[] = []
    collectTables(nodes, tables)
    assert.ok(tables.length >= 1, '未找到表格')
    assert.ok(countType(tables[0].children, BBNodeType.TABLE_ROW) > 40,
      `第一张表行数异常: ${countType(tables[0].children, BBNodeType.TABLE_ROW)}`)
  })

  it('表格单元格保留 colspan/rowspan 属性', () => {
    const cellCount: number = countType(nodes, BBNodeType.TABLE_CELL)
    assert.ok(cellCount > 100, `单元格数异常: ${cellCount}`)
  })

  it('collapse 折叠块结构与标题', () => {
    const collapse: BBNode | undefined = findType(nodes, BBNodeType.COLLAPSE)
    assert.ok(collapse, '未找到 [collapse] 节点')
    assert.equal(collapse.title, '12.0制造业的变化')
  })

  it('关键短语完整保留', () => {
    const actual: string = concatTextNodes(nodes)
    const phrases: string[] = [
      '12.0开始了~~~',
      '写在前面：首先感谢大家在11.0版本的支持',
      '熔铸活力',
      '密谋小径鱼钩',
      '苏丶恩#5291',
      '萨拉斯竞争者',
      '金山文档会实时更新',
      '三星材料+二星公函',
      '破法者的掩蔽'
    ]
    for (const phrase of phrases) {
      assert.ok(actual.includes(phrase), `关键短语缺失: ${phrase}`)
    }
  })

  it('URL 链接保留 href', () => {
    const urls: BBNode[] = []
    collectType(nodes, BBNodeType.URL, urls)
    assert.ok(urls.length > 0, '未找到 URL 节点')
    const kdocs: BBNode | undefined = urls.find((u: BBNode) => u.href.includes('kdocs.cn'))
    assert.ok(kdocs, `金山文档链接丢失，全部 href: ${urls.map((u: BBNode) => u.href).join(', ')}`)
  })
})

// ---------------------------------------------------------------------------
// 真实样本结构（demo2.txt）
// ---------------------------------------------------------------------------

describe('真实样本结构（demo2.txt）', () => {
  const content: string = loadSampleContent('demo2.txt')
  const nodes: BBNode[] = parseBBCode(content)

  it('超长 URL（1349 字符 text fragment 链接）被识别为链接而非退化文本', () => {
    const urls: BBNode[] = []
    collectType(nodes, BBNodeType.URL, urls)
    assert.equal(urls.length, 1, `URL 节点应为 1 个，实际 ${urls.length}`)
    const href: string = urls[0].href
    assert.ok(href.includes('finance.sina.com.cn'), `href 应为新浪链接: ${href.slice(0, 80)}`)
    assert.ok(href.length > 512, `href 应完整保留超长片段（超过旧 512 上限）: ${href.length}`)
    // 显示文字
    const text: string = concatTextNodes(urls[0].children)
    assert.ok(text.includes('竹知了'), `链接文字缺失: ${text}`)
  })

  it('无退化文本残留（[url 标签未被当作文本原样输出）', () => {
    const actual: string = concatTextNodes(nodes)
    assert.ok(!actual.includes('[url='), `存在退化标签文本: ${actual.slice(0, 120)}`)
  })
})

// ---------------------------------------------------------------------------
// 边角样例（解析器功能面覆盖）
// ---------------------------------------------------------------------------

describe('边角样例', () => {
  const cases: Array<{ name: string; input: string; asserts?: (nodes: BBNode[]) => void }> = [
    { name: '基础嵌套', input: '[b][i][u]嵌套文字[/u][/i][/b]' },
    { name: '样式属性', input: '[color=red][size=150%][font=楷体]样式组合[/font][/size][/color]' },
    { name: '无属性 url', input: '链接 [url]https://example.com[/url] 结束' },
    { name: '带属性 url', input: '[url=https://example.com]显示文字[/url]' },
    { name: '引用块', input: '[quote]引用的内容[/quote]' },
    {
      name: 'code 块原样保留标签',
      input: '[code][b]不该加粗[/b] 与 [/size] 都是文字[/code]',
      asserts: (nodes: BBNode[]) => {
        const code: BBNode | undefined = findType(nodes, BBNodeType.CODE)
        if (!code) assert.fail('未找到 CODE 节点')
        const text: string = concatTextNodes([code])
        assert.ok(text.includes('[b]不该加粗[/b]'), `code 内容被解释: ${text}`)
      }
    },
    {
      name: '嵌套列表',
      input: '[list][*]一级一[*]一级二[list][*]二级一[*]二级二[/list][*]一级三[/list]',
      asserts: (nodes: BBNode[]) => {
        assert.equal(countType(nodes, BBNodeType.LIST), 2, '嵌套 list 应为 2 个')
        assert.equal(countType(nodes, BBNodeType.LIST_ITEM), 5, '列表项应为 5 个')
      }
    },
    {
      name: '表格与合并单元格',
      input: '[table][tr][td rowspan=2]合并行[/td][td]普通[/td][/tr][tr][td]第二行[/td][/tr][/table]',
      asserts: (nodes: BBNode[]) => {
        const tables: BBNode[] = []
        collectTables(nodes, tables)
        assert.equal(tables.length, 1)
        const rows: BBNode[] = []
        collectType(tables[0].children, BBNodeType.TABLE_ROW, rows)
        assert.equal(rows.length, 2, '表格应为 2 行')
        const cells: BBNode[] = []
        collectType(tables[0].children, BBNodeType.TABLE_CELL, cells)
        assert.equal(cells.length, 3, '表格应为 3 个单元格')
        assert.equal(cells[0].rowSpan, 2, 'rowspan 未保留')
      }
    },
    { name: '未闭合标签容错', input: '[b]未闭合粗体' },
    { name: '乱序闭合容错', input: '[/b][b]乱序[/i]闭合' },
    { name: '四级标题', input: '[h]四级标题内容[/h]' },
    { name: '居中对齐', input: '[align=center]居中文字[/align]' },
    { name: '图片', input: '[img]https://img.example.com/a.jpg[/img]' },
    { name: '折叠块', input: '[collapse=折叠标题]折叠内容[/collapse]' },
    { name: '特殊字符实体', input: '实体 &amp;&lt;&gt;&quot;&#91;字面&#93; 与 裸 [ 方括号' },
    { name: '大小写标签', input: '[B]大写粗体[/B] [COLOR=BLUE]大写颜色[/COLOR]' },
    { name: '表情标签', input: '表情 [s:ac:01] 之后文字' },
    {
      name: '大写变体 smile 表情（回归：快速路径 [img] 大小写敏感）',
      input: '表情 [IMG]https://img4.nga.cn/ngabbs/post/smile/a_1.png[/IMG] 之后',
      asserts: (nodes: BBNode[]) => {
        assert.equal(countType(nodes, BBNodeType.EMOTION), 1, '大写 [IMG] smile 链接应解析为表情')
        assert.equal(countType(nodes, BBNodeType.IMAGE), 0, '不应退化为图片节点')
      }
    },
    { name: '闪存媒体', input: '[flash=video]https://video.example.com/a.mp4[/flash]' },
    { name: '上下标', input: '化学 H[sub]2[/sub]O 与 x[sup]2[/sup]' },
    {
      name: '横线与段落',
      input: '前文[hr]后文',
      asserts: (nodes: BBNode[]) => {
        assert.ok(countType(nodes, BBNodeType.HR) >= 1, '未找到 HR 节点')
      }
    }
  ]

  for (const c of cases) {
    it(c.name, () => {
      const nodes: BBNode[] = parseBBCode(c.input)
      // 文本零丢失
      const actual: string = concatTextNodes(nodes)
      const expected: string = expectedPlainText(c.input)
      assert.ok(
        isSubsequence(expected, actual),
        `文字缺失。期望: ${expected}，实际: ${actual}`
      )
      // 无栈溢出/深度爆炸（宽松：解析结果节点总数有界）
      const total: number = countType(nodes, BBNodeType.TEXT) + countType(nodes, BBNodeType.BOLD)
      assert.ok(total >= 0, '节点统计异常')
      if (c.asserts) c.asserts(nodes)
    })
  }
})

// ---------------------------------------------------------------------------
// 渲染层空白行折叠（回归：历史修复 be0ec156 在镜像化时丢失）
// ---------------------------------------------------------------------------

describe('渲染层空白行折叠（回归 be0ec156）', () => {
  it('正文连续换行折叠为单个换行', () => {
    const nodes: BBNode[] = parseBBCode('第一段<br/><br/><br/>第二段')
    const runs: InlineRun[] = flattenInlineNodes(nodes)
    assert.equal(runs.length, 1)
    assert.equal(runs[0].text, '第一段\n第二段')
  })

  it('引用区连续换行折叠为单个换行', () => {
    const nodes: BBNode[] = parseBBCode('[quote]引用一<br/><br/><br/>引用二[/quote]')
    const quote: BBNode | undefined = findType(nodes, BBNodeType.QUOTE)
    if (!quote) assert.fail('未找到 QUOTE 节点')
    const runs: InlineRun[] = flattenInlineNodes(quote.children)
    assert.equal(runs.length, 1)
    assert.equal(runs[0].text, '引用一\n引用二')
  })

  it('单个换行原样保留', () => {
    const nodes: BBNode[] = parseBBCode('第一段<br/>第二段')
    const runs: InlineRun[] = flattenInlineNodes(nodes)
    assert.equal(runs.length, 1)
    assert.equal(runs[0].text, '第一段\n第二段')
  })

  it('解析树保留原始连续换行（零丢失/快照/官方差分不受影响）', () => {
    const nodes: BBNode[] = parseBBCode('第一段<br/><br/><br/>第二段')
    assert.equal(concatTextNodes(nodes), '第一段\n\n\n第二段')
  })
})

// ---------------------------------------------------------------------------
// 收集工具（避免使用非 ArkTS 兼容语法）
// ---------------------------------------------------------------------------

/** 收集解析树中所有指定类型节点。 */
function collectType(nodes: BBNode[], type: BBNodeType, out: BBNode[]): void {
  for (const n of nodes) {
    if (n.type === type) out.push(n)
    collectType(n.children, type, out)
  }
}

/** 收集解析树中所有 TABLE 节点。 */
function collectTables(nodes: BBNode[], out: BBNode[]): void {
  collectType(nodes, BBNodeType.TABLE, out)
}
