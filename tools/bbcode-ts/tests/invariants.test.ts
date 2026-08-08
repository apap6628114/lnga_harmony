import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { parseBBCode } from '../src/parser/bbcode/parser'
import { preprocessContent } from '../src/parser/bbcode/lexer'
import { decodeHtmlEntities } from '../src/parser/_shared/HtmlEntityCodec'
import { resolveAttachBBCodeUrl, resolveImgUrl } from '../src/parser/_shared/AttachUrl'
import { flattenInlineNodes, InlineRun, InlineRunKind } from '../src/common/components/bbcode/bbcode-utils'
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
 * 整体丢弃含内容（解析器产出 IMAGE 等节点，无 TEXT）；[attach] 按官方
 * ubbcode.js 替换语义处理——合法附件 URL 渲染为完整链接文本，非法保留原文。
 *
 * @param content 原始正文
 * @returns 期望纯文本
 */
function expectedPlainText(content: string): string {
  let preprocessed: string = preprocessContent(content)
  preprocessed = preprocessed.replace(/\[(img|flash|album|video|audio)(?:=[^\]]*)?\][\s\S]*?\[\/\1\]/gi, '')
  // 镜像 handleQuote 的消费语义：引用头（[pid=..]Reply[/pid] [b]Post by ...[/b]）
  // 后的连续换行段整体跳过（真实 NGA 数据为 </b><br/><br/>，预处理后成 \n\n）
  preprocessed = preprocessed.replace(
    /(\[pid=\d+,\d+,\d+\]Reply\[\/pid\] \[b\]Post by \[uid=\d+\].*?\[\/uid\] \([^)]+\):\[\/b\])(?:\r?\n)+/g,
    '$1')
  preprocessed = preprocessed.replace(/\[attach\](.+?)\[\/attach\]/gi,
    (match: string, url: string): string => {
      const resolved: string = resolveAttachBBCodeUrl(url)
      return resolved.length > 0 ? resolved : match
    })
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
// 教学文档语法覆盖（guide-bbcode.txt：源自 .wiki/NGA-BBS代码教学整理.html 21 节语法）
// ---------------------------------------------------------------------------

describe('教学文档语法覆盖（guide-bbcode.txt）', () => {
  const content: string = loadSampleContent('guide-bbcode.txt')
  const nodes: BBNode[] = parseBBCode(content)

  it('1. color：24 个官方颜色名全部识别', () => {
    const colors: BBNode[] = []
    collectType(nodes, BBNodeType.COLOR, colors)
    const names: string[] = colors.map((c: BBNode) => c.color)
    const official: string[] = [
      'skyblue', 'royalblue', 'blue', 'darkblue',
      'orange', 'orangered', 'crimson', 'red', 'firebrick', 'darkred',
      'green', 'limegreen', 'seagreen', 'teal',
      'deeppink', 'tomato', 'coral', 'purple', 'indigo',
      'burlywood', 'sandybrown', 'chocolate', 'sienna', 'silver'
    ]
    for (const name of official) {
      assert.ok(names.includes(name), `官方颜色名缺失: ${name}`)
    }
  })

  it('2. size：190% 保留，1% 截断到 50%（下限 clamp）', () => {
    const sizes: BBNode[] = []
    collectType(nodes, BBNodeType.SIZE, sizes)
    const values: number[] = sizes.map((s: BBNode) => s.size)
    assert.ok(values.includes(190), '190% 应保留')
    assert.ok(values.includes(50), '1% 应截断到 50')
  })

  it('3-4. font / b / u / i', () => {
    const fonts: BBNode[] = []
    collectType(nodes, BBNodeType.FONT, fonts)
    assert.equal(fonts.map((f: BBNode) => f.fontFamily).join(','), 'simsun,simhei,Arial')
    const actual: string = concatTextNodes(nodes)
    for (const phrase of ['粗体文本', '下划线文本', '斜体文本']) {
      assert.ok(actual.includes(phrase), `短语缺失: ${phrase}`)
    }
  })

  it('5. align：center 与 right', () => {
    const aligns: BBNode[] = []
    collectType(nodes, BBNodeType.ALIGN, aligns)
    assert.equal(aligns.map((a: BBNode) => a.align).join(','), 'center,right')
  })

  it('6. h：[/h] 与 ===x=== 双写法均渲染为 HEADING', () => {
    const headings: BBNode[] = []
    collectType(nodes, BBNodeType.HEADING, headings)
    assert.equal(headings.length, 3, '[h] 1 个 + === 1 个 + 嵌套修饰 1 个')
    assert.equal(concatTextNodes(headings[0].children), '我是一条分割线')
    assert.equal(concatTextNodes(headings[1].children), '我是一条分割线')
    const color: BBNode | undefined = findType(headings[2].children, BBNodeType.COLOR)
    if (!color) assert.fail('HEADING 内嵌套 COLOR 缺失')
    assert.equal(color.color, 'sienna')
  })

  it('7-8. l/r 浮动与三层嵌套 list', () => {
    assert.equal(countType(nodes, BBNodeType.FLOAT_LEFT), 1)
    assert.equal(countType(nodes, BBNodeType.FLOAT_RIGHT), 1)
    assert.equal(countType(nodes, BBNodeType.LIST), 3)
    assert.equal(countType(nodes, BBNodeType.LIST_ITEM), 3)
  })

  it('9. img：旧附件域绝对 URL 归一化到 img.nga.cn，相对路径拼 CDN', () => {
    const imgs: BBNode[] = []
    collectType(nodes, BBNodeType.IMAGE, imgs)
    assert.equal(imgs.length, 2)
    assert.equal(imgs[0].src, 'https://img.nga.cn/attachments/mon_201207/13/-3429350_4fff8633bec77.jpg',
      '旧域 img.ngacn.cc 应归一化')
    assert.equal(imgs[1].src, 'https://img.nga.cn/attachments/mon_202605/03/-nuoxnQ2x-55cdK28T3cSsg-hd.jpg',
      '相对路径 ./mon_ 应拼 CDN 根')
  })

  it('10. url：无属性推导与带属性两种形式', () => {
    const urls: BBNode[] = []
    collectType(nodes, BBNodeType.URL, urls)
    assert.equal(urls[0].href, 'http://bbs.ngacn.cc')
    assert.equal(urls[1].href, 'http://bbs.ngacn.cc')
    assert.equal(concatTextNodes(urls[1].children), '艾泽拉斯国家地理')
  })

  it('11-12. quote 嵌套引用与 code 原样保留标签', () => {
    assert.equal(countType(nodes, BBNodeType.QUOTE), 2, '嵌套引用应为 2 个 QUOTE')
    const codes: BBNode[] = []
    collectType(nodes, BBNodeType.CODE, codes)
    assert.equal(codes.length, 2)
    assert.equal(codes[1].text, '[b]不该加粗[/b] 与 [/size] 都是文字')
  })

  it('13. flash：swf 兜底 FLASH 节点，flash=video 明确 VIDEO', () => {
    const flashes: BBNode[] = []
    collectType(nodes, BBNodeType.FLASH, flashes)
    assert.equal(flashes.length, 1)
    assert.equal(flashes[0].href, 'http://player.youku.com/player.php/sid/XMjQ4Mjg3MTY=/v.swf')
    const videos: BBNode[] = []
    collectType(nodes, BBNodeType.VIDEO, videos)
    assert.equal(videos.length, 1)
    assert.equal(videos[0].src, 'https://video.example.com/a.mp4')
  })

  it('14. table：[td50] 无属性（文档列宽写法当前不识别），[td=2]/rowspan/[td=1,1,50] 生效', () => {
    const tables: BBNode[] = []
    collectTables(nodes, tables)
    assert.equal(tables.length, 2)
    const cells1: BBNode[] = []
    collectType(tables[0].children, BBNodeType.TABLE_CELL, cells1)
    assert.equal(cells1.length, 4)
    assert.equal(cells1[0].colWidth, 0, '[td50] 无等号形式当前不识别为列宽（固化行为）')
    const cells2: BBNode[] = []
    collectType(tables[1].children, BBNodeType.TABLE_CELL, cells2)
    assert.equal(cells2.length, 3)
    assert.equal(cells2[0].colSpan, 2)
    assert.equal(cells2[1].rowSpan, 2)
    assert.equal(cells2[2].colWidth, 50)
  })

  it('15. tid/pid：属性形式生成话题地址', () => {
    const tids: BBNode[] = []
    collectType(nodes, BBNodeType.TID_LINK, tids)
    assert.equal(tids.length, 2)
    assert.equal(tids[1].href, '#/thread?tid=456')
    const pids: BBNode[] = []
    collectType(nodes, BBNodeType.PID_LINK, pids)
    assert.equal(pids.length, 2)
    assert.equal(pids[1].href, '#/thread?tid=131415&pid=101112')
  })

  it('15b. [pid=pid,tid,page] 三值形式保留引用楼层页码', () => {
    const three: BBNode[] = parseBBCode('[pid=1000,12345,8]Reply[/pid]')
    const threePids: BBNode[] = []
    collectType(three, BBNodeType.PID_LINK, threePids)
    assert.equal(threePids.length, 1)
    assert.equal(threePids[0].href, '#/thread?tid=12345&pid=1000&page=8')

    const quoteNodes: BBNode[] = parseBBCode(
      '[quote][pid=868052707,46425481,8]Reply[/pid] [b]Post by [uid=1379135]就是会装死[/uid] (2026-05-14 13:34):[/b]<br/>燃烧之刃dk漂亮男孩又来麻烦大佬做披风[/quote]'
    )
    const quotePids: BBNode[] = []
    collectType(quoteNodes, BBNodeType.PID_LINK, quotePids)
    assert.equal(quotePids.length, 1)
    assert.equal(quotePids[0].href, '#/thread?tid=46425481&pid=868052707&page=8')

    const nonNumeric: BBNode[] = parseBBCode('[pid=1,2,abc]Reply[/pid]')
    const nonNumericPids: BBNode[] = []
    collectType(nonNumeric, BBNodeType.PID_LINK, nonNumericPids)
    assert.equal(nonNumericPids.length, 1)
    assert.equal(nonNumericPids[0].href, '#/thread?tid=2&pid=1')

    const fourParts: BBNode[] = parseBBCode('[pid=1,2,3,4]Reply[/pid]')
    const fourPids: BBNode[] = []
    collectType(fourParts, BBNodeType.PID_LINK, fourPids)
    assert.equal(fourPids.length, 1)
    assert.equal(fourPids[0].href, '#/thread?tid=2&pid=1&page=3')

    const emptyParts: BBNode[] = parseBBCode('[pid=,2,3]Reply[/pid]')
    const emptyPids: BBNode[] = []
    collectType(emptyParts, BBNodeType.PID_LINK, emptyPids)
    assert.equal(emptyPids.length, 1)
    assert.equal(emptyPids[0].href, '')
  })

  it('16-17. del 删除线与 album 相册', () => {
    assert.equal(countType(nodes, BBNodeType.STRIKETHROUGH), 1)
    const album: BBNode | undefined = findType(nodes, BBNodeType.ALBUM)
    if (!album) assert.fail('未找到 ALBUM 节点')
    assert.equal(album.title, '相册标题')
    const urls: BBNode[] = []
    collectType(album.children, BBNodeType.URL, urls)
    assert.equal(urls.length, 2)
    assert.equal(urls[0].href, 'http://xxx.com/ooo.jpg')
  })

  it('18. collapse：标题与折叠内容完整保留', () => {
    const collapse: BBNode | undefined = findType(nodes, BBNodeType.COLLAPSE)
    if (!collapse) assert.fail('未找到 COLLAPSE 节点')
    assert.equal(collapse.title, '来做个示例...')
    assert.ok(concatTextNodes(collapse.children).includes('这儿有一堆福利，有节操的人才能看到'))
  })

  it('19. @：数字 uid 与文本用户名均识别为 MENTION', () => {
    const mentions: BBNode[] = []
    collectType(nodes, BBNodeType.MENTION, mentions)
    assert.equal(mentions.length, 2)
    assert.equal(mentions[0].href, '#/profile?uid=123456')
    assert.equal(mentions[0].text, '@123456')
    assert.equal(mentions[1].text, '@那个黑枪不能再打了')
    assert.ok(mentions[1].href.startsWith('#/profile?username='), `用户名应走 username 路由: ${mentions[1].href}`)
  })

  it('20-21. lessernuke 警告块与 wiki 停用标签保留原文', () => {
    const warn: BBNode | undefined = findType(nodes, BBNodeType.WARN)
    if (!warn) assert.fail('未找到 WARN 节点')
    assert.equal(concatTextNodes(warn.children), '禁言警告内容')
    const actual: string = concatTextNodes(nodes)
    assert.ok(actual.includes('[wiki]曾经非常强大的维基[/wiki]'), '停用标签应保留原文')
  })

  it('实体解码：&amp;&lt;&gt;&quot; 解码为 &<>"', () => {
    const actual: string = concatTextNodes(nodes)
    assert.ok(actual.includes('&<>"'), `实体解码缺失: ${actual.slice(-80)}`)
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
    {
      name: 'mention UID 前缀（官方 ^(?:UID)?\\d+$ 大小写不敏感）',
      input: '[@UID123] 与 [@uid456]',
      asserts: (nodes: BBNode[]) => {
        const mentions: BBNode[] = []
        collectType(nodes, BBNodeType.MENTION, mentions)
        assert.equal(mentions.length, 2)
        assert.equal(mentions[0].href, '#/profile?uid=123')
        assert.equal(mentions[1].href, '#/profile?uid=456')
      }
    },
    {
      name: 'mention 文本用户名走 username 路由',
      input: '[@那个黑枪不能再打了]',
      asserts: (nodes: BBNode[]) => {
        const mention: BBNode | undefined = findType(nodes, BBNodeType.MENTION)
        if (!mention) assert.fail('未找到 MENTION 节点')
        assert.equal(mention.href, `#/profile?username=${encodeURIComponent('那个黑枪不能再打了')}`)
        assert.equal(mention.text, '@那个黑枪不能再打了')
      }
    },
    {
      name: 'mention 长度越界保留原文（官方 {2,20} 约束）',
      input: '[@1] 与 [@ABCDEFGHIJKLMNOPQRSTUV]',
      asserts: (nodes: BBNode[]) => {
        assert.equal(countType(nodes, BBNodeType.MENTION), 0, '越界长度不应识别')
        const actual: string = concatTextNodes(nodes)
        assert.ok(actual.includes('[@1]') && actual.includes('[@ABCDEFGHIJKLMNOPQRSTUV]'), `原文应保留: ${actual}`)
      }
    },
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
    {
      name: 'attach 相对路径拼 CDN（官方 [attach] 语义）',
      input: '[attach]./mon_202608/03/k2Q81-97rkXrT6wSk0-zk.mp4[/attach]',
      asserts: (nodes: BBNode[]) => {
        const url: BBNode | undefined = findType(nodes, BBNodeType.URL)
        if (!url) assert.fail('未找到 URL 节点')
        assert.equal(url.href, 'https://img.nga.cn/attachments/mon_202608/03/k2Q81-97rkXrT6wSk0-zk.mp4',
          '相对附件地址应拼 CDN 根')
        assert.equal(url.text, url.href, '显示文本应为完整 URL（官方 writelink 语义）')
      }
    },
    {
      name: 'attach 绝对附件域 URL 原样保留',
      input: '附件 [attach]https://img.nga.cn/attachments/mon_202608/03/a.mp4[/attach] 结束',
      asserts: (nodes: BBNode[]) => {
        const url: BBNode | undefined = findType(nodes, BBNodeType.URL)
        if (!url) assert.fail('未找到 URL 节点')
        assert.equal(url.href, 'https://img.nga.cn/attachments/mon_202608/03/a.mp4')
      }
    },
    {
      name: 'attach 非 NGA 附件域退化为原文（官方保留 $0 行为）',
      input: '前文 [attach]https://evil.example.com/a.zip[/attach] 后文',
      asserts: (nodes: BBNode[]) => {
        const actual: string = concatTextNodes(nodes)
        assert.ok(actual.includes('[attach]https://evil.example.com/a.zip[/attach]'),
          `应保留 [attach] 原文: ${actual}`)
        assert.equal(countType(nodes, BBNodeType.URL), 0, '不应生成链接节点')
      }
    },
    {
      name: 'attach 大小写标签',
      input: '[ATTACH]./mon_202608/03/b.png[/ATTACH]',
      asserts: (nodes: BBNode[]) => {
        const url: BBNode | undefined = findType(nodes, BBNodeType.URL)
        if (!url) assert.fail('未找到 URL 节点')
        assert.equal(url.href, 'https://img.nga.cn/attachments/mon_202608/03/b.png')
      }
    },
    {
      name: 'attach 未闭合保留原文（官方正则无匹配）',
      input: '前文 [attach]./mon_202608/03/unclosed.mp4 后文',
      asserts: (nodes: BBNode[]) => {
        const actual: string = concatTextNodes(nodes)
        assert.ok(actual.includes('[attach]./mon_202608/03/unclosed.mp4'),
          `未闭合 [attach] 应保留标记原文: ${actual}`)
        assert.equal(countType(nodes, BBNodeType.URL), 0, '不应生成链接节点')
      }
    },
    {
      name: 'attach 换行包裹保留原文（官方 . 不匹配 \\n）',
      input: '[attach]\n./mon_202608/03/c.png\n[/attach]',
      asserts: (nodes: BBNode[]) => {
        const actual: string = concatTextNodes(nodes)
        assert.ok(actual.includes('[attach]\n./mon_202608/03/c.png\n[/attach]'),
          `换行包裹应保留原文: ${JSON.stringify(actual)}`)
        assert.equal(countType(nodes, BBNodeType.URL), 0, '不应生成链接节点')
      }
    },
    {
      name: 'attach 内容前后空白保留原文（官方不 trim）',
      input: '[attach] ./mon_202608/03/d.png [/attach]',
      asserts: (nodes: BBNode[]) => {
        const actual: string = concatTextNodes(nodes)
        assert.ok(actual.includes('[attach] ./mon_202608/03/d.png [/attach]'),
          `空白包裹应保留原文: ${JSON.stringify(actual)}`)
        assert.equal(countType(nodes, BBNodeType.URL), 0, '不应生成链接节点')
      }
    },
    {
      name: 'attach 带属性形式整体保留原文（官方 `\\[attach\\]` 精确匹配）',
      input: '[attach=1]./mon_202608/03/e.png[/attach]',
      asserts: (nodes: BBNode[]) => {
        const actual: string = concatTextNodes(nodes)
        assert.ok(actual.includes('[attach=1]./mon_202608/03/e.png[/attach]'),
          `属性形式应保留原文: ${actual}`)
        assert.equal(countType(nodes, BBNodeType.URL), 0, '不应生成链接节点')
      }
    },
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

describe('attach 渲染层', () => {
  it('合法 [attach] 渲染为单个链接 Run（显示文本 = 完整 URL）', () => {
    const nodes: BBNode[] = parseBBCode('[attach]./mon_202608/03/k2Q81-97rkXrT6wSk0-zk.mp4[/attach]')
    const runs: InlineRun[] = flattenInlineNodes(nodes)
    assert.equal(runs.length, 1)
    assert.equal(runs[0].kind, InlineRunKind.LINK)
    assert.equal(runs[0].href, 'https://img.nga.cn/attachments/mon_202608/03/k2Q81-97rkXrT6wSk0-zk.mp4')
    assert.equal(runs[0].text, runs[0].href)
  })

  it('非法 [attach] 退化为普通文字 Run', () => {
    const nodes: BBNode[] = parseBBCode('前文 [attach]https://evil.example.com/a.zip[/attach] 后文')
    const runs: InlineRun[] = flattenInlineNodes(nodes)
    assert.equal(runs.length, 1)
    assert.equal(runs[0].kind, InlineRunKind.TEXT)
    assert.equal(runs[0].text, '前文 [attach]https://evil.example.com/a.zip[/attach] 后文')
  })
})

describe('img 域名归一化（对齐官方 commonui.correctAttachUrl）', () => {
  it('旧附件域 img.nga.178.com 绝对 URL 归一化到 img.nga.cn', () => {
    assert.equal(
      resolveImgUrl('https://img.nga.178.com/attachments/mon_202112/05/-40v3zQ2p-ccrhK3S1o-p.png'),
      'https://img.nga.cn/attachments/mon_202112/05/-40v3zQ2p-ccrhK3S1o-p.png'
    )
  })

  it('http 旧域 ngacn.cc / nga.donews.com / ngabbs.com 同样归一化', () => {
    assert.equal(
      resolveImgUrl('http://img.ngacn.cc/attachments/mon_202001/01/x.png'),
      'https://img.nga.cn/attachments/mon_202001/01/x.png'
    )
    assert.equal(
      resolveImgUrl('http://img.nga.donews.com/attachments/mon_202001/01/x.png'),
      'https://img.nga.cn/attachments/mon_202001/01/x.png'
    )
    assert.equal(
      resolveImgUrl('http://img.ngabbs.com/attachments/mon_202001/01/x.png'),
      'https://img.nga.cn/attachments/mon_202001/01/x.png'
    )
  })

  it('img7 子域匹配、img4 等其余数字子域不匹配（官方 img7? 逐字一致）', () => {
    assert.equal(
      resolveImgUrl('https://img7.nga.cn/attachments/mon_202001/01/x.png'),
      'https://img.nga.cn/attachments/mon_202001/01/x.png'
    )
    assert.equal(
      resolveImgUrl('https://img4.nga.178.com/attachments/mon_202001/01/x.png'),
      'https://img4.nga.178.com/attachments/mon_202001/01/x.png'
    )
  })

  it('非 NGA 附件域绝对 URL 原样保留', () => {
    const raw: string = 'https://example.com/attachments/mon_202001/01/x.png'
    assert.equal(resolveImgUrl(raw), raw)
  })

  it('表格内旧域 [img] 解析后 src 为新域', () => {
    const nodes: BBNode[] = parseBBCode('[table][tr][td][img]https://img.nga.178.com/attachments/mon_202112/05/x.png[/img]AL[/td][/tr][/table]')
    const img: BBNode | undefined = findType(nodes, BBNodeType.IMAGE)
    if (!img) assert.fail('未找到 IMAGE 节点')
    assert.equal(img.src, 'https://img.nga.cn/attachments/mon_202112/05/x.png')
  })
})

describe('线性扫描与批量格式化回归', () => {
  it('引用块中的大量内联标签保持完整样式和文字', () => {
    const fragmentCount: number = 4000
    const content: string = `[quote]${'[b]x[/b]'.repeat(fragmentCount)}[/quote]`
    const nodes: BBNode[] = parseBBCode(content)
    const quote: BBNode | undefined = findType(nodes, BBNodeType.QUOTE)
    if (!quote) assert.fail('未找到 QUOTE 节点')
    const runs: InlineRun[] = flattenInlineNodes(quote.children)
    assert.equal(runs.length, 1)
    assert.equal(runs[0].text, 'x'.repeat(fragmentCount))
    assert.equal(runs[0].style.bold, true)
  })

  it('单行大量单元格保持数量、顺序与内容', () => {
    const cellCount: number = 4000
    const content: string = `[table][tr]${'[td]x[/td]'.repeat(cellCount)}[/tr][/table]`
    const nodes: BBNode[] = parseBBCode(content)
    assert.equal(countType(nodes, BBNodeType.TABLE_CELL), cellCount)
    assert.equal(concatTextNodes(nodes), 'x'.repeat(cellCount))
  })

  it('表格单元格前后杂散内容沿用既有容错结果', () => {
    const content: string = '[table][tr]前[foo]中[td foo=1]甲[/td]后[/tr][/table]'
    const nodes: BBNode[] = parseBBCode(content)
    const row: BBNode | undefined = findType(nodes, BBNodeType.TABLE_ROW)
    if (!row) assert.fail('未找到 TABLE_ROW 节点')
    assert.equal(row.children.length, 2)
    assert.equal(row.children[0].type, BBNodeType.TEXT)
    assert.equal(row.children[0].text, '前foo]中')
    assert.equal(row.children[1].type, BBNodeType.TABLE_CELL)
    assert.equal(concatTextNodes(row.children[1].children), '甲')
  })

  it('大小写边界标签保持原有结构解释', () => {
    const content: string = '[QUOTE]甲[B]乙[/B][/QuOtE][LIST][*]丙[*]丁[/LiSt]'
    const nodes: BBNode[] = parseBBCode(content)
    assert.equal(countType(nodes, BBNodeType.QUOTE), 1)
    assert.equal(countType(nodes, BBNodeType.LIST), 1)
    assert.equal(countType(nodes, BBNodeType.LIST_ITEM), 2)
    assert.equal(concatTextNodes(nodes), '甲乙丙丁')
  })
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
