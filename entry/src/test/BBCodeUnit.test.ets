import { describe, expect, it } from '@ohos/hypium'
import { BBNode, BBNodeType } from '../main/ets/model/BBCodeNode'
import { parseBBCode } from '../main/ets/parser/bbcode/parser'
import { indexOfIgnoreCase } from '../main/ets/parser/bbcode/lexer'
import { MAX_LIST_DEPTH } from '../main/ets/parser/bbcode/block-handlers/handleList'
import {
  applyInlineFormatTags,
  applyTextStyleDeclaration,
  extractTextStyleAlign,
  flattenInlineNodes,
  InlineBaseline,
  InlineRun,
  InlineRunKind,
  InlineTextStyle,
  isInlineRunsBlank,
  normalizeFontFamily
} from '../main/ets/common/components/bbcode/bbcode-utils'
import {
  buildTableLayout,
  TableLayout,
} from '../main/ets/common/components/bbcode/table-layout'

/**
 * 注册 BBCode 解析与文字样式规范化回归测试。
 */
export default function bbcodeUnitTest(): void {
  describe('bbcodeFormatting', (): void => {
    it('combinesDeepNestedTextStyles', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[color=red][b][u][size=150%]12.0开始了~~~[/size][/u][/b][/color]')
      const runs: InlineRun[] = flattenInlineNodes(nodes)

      expect(runs.length).assertEqual(1)
      expect(runs[0].text).assertEqual('12.0开始了~~~')
      expect(runs[0].style.color).assertEqual('#ff0000')
      expect(runs[0].style.bold).assertTrue()
      expect(runs[0].style.underline).assertTrue()
      expect(runs[0].style.italic).assertFalse()
      expect(runs[0].style.scalePercent).assertEqual(150)
    })

    it('mapsNgaPaletteAndCssBaseColors', 0, (): void => {
      const runs: InlineRun[] = flattenInlineNodes(parseBBCode(
        '[color=royalblue]宝[/color][color=crimson]红[/color][color=seagreen]海[/color]' +
        '[color=teal]青[/color][color=maroon]栗[/color][color=Silver]银[/color]'))

      expect(runs.length).assertEqual(6)
      expect(runs[0].style.color).assertEqual('#4169e1')
      expect(runs[1].style.color).assertEqual('#dc143c')
      expect(runs[2].style.color).assertEqual('#2e8b57')
      expect(runs[3].style.color).assertEqual('#008080')
      expect(runs[4].style.color).assertEqual('#800000')
      expect(runs[5].style.color).assertEqual('#c0c0c0')
    })

    it('passesThroughUnmappedNamedColor', 0, (): void => {
      const runs: InlineRun[] = flattenInlineNodes(parseBBCode('[color=gold]金[/color]'))

      expect(runs.length).assertEqual(1)
      expect(runs[0].style.color).assertEqual('gold')
    })

    it('keepsFormattingInsideClickableLink', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[b][url=https://example.com][i]格式化链接[/i][/url][/b]')
      const runs: InlineRun[] = flattenInlineNodes(nodes)

      expect(runs.length).assertEqual(1)
      expect(runs[0].kind).assertEqual(InlineRunKind.LINK)
      expect(runs[0].href).assertEqual('https://example.com')
      expect(runs[0].style.bold).assertTrue()
      expect(runs[0].style.italic).assertTrue()
    })

    it('decodesAnonymousNameInAttributeLessUidQuote', 0, (): void => {
      const encodedName: string = '#anony_0d89af3611314647cc3f028cd0976872'
      const nodes: BBNode[] = parseBBCode(
        '[quote][pid=878473588,47373567,1]Reply[/pid] [b]Post by [uid]' + encodedName +
        '[/uid][color=gray](18楼)[/color] (2026-08-14 21:52):[/b]<br/><br/>引用正文[/quote]')
      const runs: InlineRun[] = flattenInlineNodes(nodes[0].children)
      let rendered: string = ''
      for (let index: number = 0; index < runs.length; index++) {
        rendered += runs[index].text
      }

      expect(rendered.indexOf('甲瞿涂丁武罗') >= 0).assertTrue()
      expect(rendered.indexOf(encodedName)).assertEqual(-1)
    })

    it('keepsHrefOfOverlongTextFragmentUrl', 0, (): void => {
      const href: string = 'https://example.com/news/2026-08-05/doc-x.shtml#:~:text=' +
        '%E7%AB%B9%E7%9F%A5%E4%BA%86'.repeat(80)
      const nodes: BBNode[] = parseBBCode('[url=' + href + ']“竹知了”事件的四点思考[/url]')

      expect(nodes.length).assertEqual(1)
      expect(nodes[0].type).assertEqual(BBNodeType.URL)
      expect(nodes[0].href.length).assertLarger(512)
      expect(nodes[0].href).assertEqual(href)
      const runs: InlineRun[] = flattenInlineNodes(nodes)
      expect(runs.length).assertEqual(1)
      expect(runs[0].kind).assertEqual(InlineRunKind.LINK)
      expect(runs[0].href).assertEqual(href)
    })

    it('stillDropsOverlongStyleTagAsPlainText', 0, (): void => {
      const longAttr: string = 'rgb(' + '1'.repeat(600) + ')'
      const raw: string = '[color=' + longAttr + ']文字[/color]'
      const nodes: BBNode[] = parseBBCode(raw)
      const runs: InlineRun[] = flattenInlineNodes(nodes)

      expect(runs.length).assertEqual(1)
      expect(runs[0].kind).assertEqual(InlineRunKind.TEXT)
      expect(runs[0].text).assertEqual(raw)
    })

    it('acceptsUppercaseTagsAndKeepsLineBreaks', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[B][URL=https://example.com][U]链接[/U][/URL][/B]<br/><br/>&lt;T&gt; &#91;b&#93;')
      const runs: InlineRun[] = flattenInlineNodes(nodes)

      expect(runs.length).assertEqual(2)
      expect(runs[0].kind).assertEqual(InlineRunKind.LINK)
      expect(runs[0].style.bold).assertTrue()
      expect(runs[0].style.underline).assertTrue()
      expect(runs[1].text).assertEqual('\n<T> [b]')
    })

    it('findsClosingTagsWithoutAllocatingLowercaseContent', 0, (): void => {
      const content: string = '前缀[/TD]后缀'

      expect(indexOfIgnoreCase(content, '[/td]', 0)).assertEqual(2)
      expect(indexOfIgnoreCase(content, '[/TR]', 3)).assertEqual(-1)
    })

    it('classifiesCachedInlineRunsWithoutReparsing', 0, (): void => {
      expect(isInlineRunsBlank(flattenInlineNodes(parseBBCode('   ')))).assertTrue()
      expect(isInlineRunsBlank(flattenInlineNodes(parseBBCode('\n')))).assertFalse()
      expect(isInlineRunsBlank(flattenInlineNodes(parseBBCode('[s:ac:blink]')))).assertFalse()
    })

    it('decodesCodeWithoutRenderingHtmlEntities', 0, (): void => {
      const nodes: BBNode[] = parseBBCode('[code]&lt;div&gt;<br/>x[/code]')

      expect(nodes.length).assertEqual(1)
      expect(nodes[0].type).assertEqual(BBNodeType.CODE)
      expect(nodes[0].text).assertEqual('<div>\nx')
    })

    it('parsesNgaNestedListsAsRecursiveTree', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[list]\n' +
          '[*]Did you think we had forgotten?\n' +
          '[list]\n' +
          '[*]Did you think we had forgiven?\n' +
          '[list]\n' +
          '[*]Behold, now, the terrible vengeance of the Forsaken!\n' +
          '[/list][/list][/list]')
      const firstItem: BBNode = nodes[0].children[0]
      const secondList: BBNode = firstItem.children[1]
      const secondItem: BBNode = secondList.children[0]
      const thirdList: BBNode = secondItem.children[1]
      const thirdItem: BBNode = thirdList.children[0]

      expect(nodes.length).assertEqual(1)
      expect(nodes[0].type).assertEqual(BBNodeType.LIST)
      expect(nodes[0].children.length).assertEqual(1)
      expect(firstItem.type).assertEqual(BBNodeType.LIST_ITEM)
      expect(firstItem.children[0].text.trim()).assertEqual('Did you think we had forgotten?')
      expect(secondList.type).assertEqual(BBNodeType.LIST)
      expect(secondList.children.length).assertEqual(1)
      expect(secondItem.children[0].text.trim()).assertEqual('Did you think we had forgiven?')
      expect(thirdList.type).assertEqual(BBNodeType.LIST)
      expect(thirdList.children.length).assertEqual(1)
      expect(thirdItem.children[0].text).assertEqual(
        'Behold, now, the terrible vengeance of the Forsaken!')
    })

    it('keepsListBoundariesInsideCodeBlocks', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[list][*]前[code][*][/list][/code]后[*][b]第二项[/b][/list]')
      const list: BBNode = nodes[0]
      const firstItem: BBNode = list.children[0]
      const secondItem: BBNode = list.children[1]

      expect(nodes.length).assertEqual(1)
      expect(list.type).assertEqual(BBNodeType.LIST)
      expect(list.children.length).assertEqual(2)
      expect(firstItem.children.length).assertEqual(3)
      expect(firstItem.children[0].text).assertEqual('前')
      expect(firstItem.children[1].type).assertEqual(BBNodeType.CODE)
      expect(firstItem.children[1].text).assertEqual('[*][/list]')
      expect(firstItem.children[2].text).assertEqual('后')
      expect(secondItem.children[0].type).assertEqual(BBNodeType.BOLD)
      expect(secondItem.children[0].children[0].text).assertEqual('第二项')
    })

    it('recoversUppercaseAndUnclosedListsWithoutDroppingText', 0, (): void => {
      const nodes: BBNode[] = parseBBCode('[LIST]前置正文[*]显式项目[LIST][*]嵌套项目')
      const list: BBNode = nodes[0]
      const explicitItem: BBNode = list.children[1]
      const nestedList: BBNode = explicitItem.children[1]

      expect(nodes.length).assertEqual(1)
      expect(list.type).assertEqual(BBNodeType.LIST)
      expect(list.children.length).assertEqual(2)
      expect(list.children[0].children[0].text).assertEqual('前置正文')
      expect(explicitItem.children[0].text).assertEqual('显式项目')
      expect(nestedList.type).assertEqual(BBNodeType.LIST)
      expect(nestedList.children[0].children[0].text).assertEqual('嵌套项目')
    })

    it('limitsPathologicalListNestingAndPreservesOverflowSource', 0, (): void => {
      let source: string = ''
      for (let i: number = 0; i < MAX_LIST_DEPTH + 2; i++) source += '[list][*]'
      source += '底部正文'
      for (let i: number = 0; i < MAX_LIST_DEPTH + 2; i++) source += '[/list]'

      const nodes: BBNode[] = parseBBCode(source)
      let currentList: BBNode = nodes[0]
      let parsedDepth: number = 0
      while (currentList.type === BBNodeType.LIST) {
        parsedDepth++
        const item: BBNode = currentList.children[0]
        let nestedList: BBNode | undefined = undefined
        for (let i: number = 0; i < item.children.length; i++) {
          if (item.children[i].type === BBNodeType.LIST) {
            nestedList = item.children[i]
            break
          }
        }
        if (nestedList === undefined) break
        currentList = nestedList
      }

      expect(nodes.length).assertEqual(1)
      expect(parsedDepth).assertEqual(MAX_LIST_DEPTH)
      expect(currentList.children[0].children[0].type).assertEqual(BBNodeType.TEXT)
      expect(currentList.children[0].children[0].text.startsWith('[list][*]')).assertTrue()
      expect(currentList.children[0].children[0].text.indexOf('底部正文') >= 0).assertTrue()
    })

    it('continuesInlineStyleAcrossImageBlock', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[size=150%]前[img]https://example.com/a.jpg[/img]后[/size]')

      expect(nodes.length).assertEqual(3)
      expect(nodes[0].type).assertEqual(BBNodeType.SIZE)
      expect(nodes[1].type).assertEqual(BBNodeType.IMAGE)
      expect(nodes[2].type).assertEqual(BBNodeType.SIZE)
      expect(flattenInlineNodes([nodes[0]])[0].style.scalePercent).assertEqual(150)
      expect(flattenInlineNodes([nodes[2]])[0].style.scalePercent).assertEqual(150)
    })

    it('continuesAttributedLinkAcrossImageBlock', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[url=https://example.com]前[img]https://example.com/a.jpg[/img]后[/url]')
      const after: InlineRun[] = flattenInlineNodes([nodes[2]])

      expect(nodes.length).assertEqual(3)
      expect(nodes[0].type).assertEqual(BBNodeType.URL)
      expect(nodes[1].type).assertEqual(BBNodeType.IMAGE)
      expect(nodes[2].type).assertEqual(BBNodeType.URL)
      expect(after.length).assertEqual(1)
      expect(after[0].text).assertEqual('后')
      expect(after[0].href).assertEqual('https://example.com')
    })

    it('continuesDerivedLinkAcrossImageBlock', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[url]https://example.com[img]https://example.com/a.jpg[/img]继续[/url]')
      const after: InlineRun[] = flattenInlineNodes([nodes[2]])

      expect(nodes.length).assertEqual(3)
      expect(nodes[0].href).assertEqual('https://example.com')
      expect(after.length).assertEqual(1)
      expect(after[0].kind).assertEqual(InlineRunKind.LINK)
      expect(after[0].href).assertEqual('https://example.com')
    })

    it('appliesOuterStyleToTransparentHipContent', 0, (): void => {
      const runs: InlineRun[] = flattenInlineNodes(parseBBCode('[b]前[hip]中[/hip]后[/b]'))

      expect(runs.length).assertEqual(1)
      expect(runs[0].text).assertEqual('前中后')
      expect(runs[0].style.bold).assertTrue()
    })

    it('combinesOuterAndInnerStylesAcrossHipBlocks', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[b]外[hip][i]前[p]段落[/p]后[/i][/hip]尾[/b]')
      const paragraphStyle: InlineTextStyle = applyInlineFormatTags(
        nodes[2].inheritedFormatTags, new InlineTextStyle())

      expect(nodes.length).assertEqual(5)
      expect(nodes[2].type).assertEqual(BBNodeType.PARAGRAPH)
      expect(paragraphStyle.bold).assertTrue()
      expect(paragraphStyle.italic).assertTrue()
    })

    it('parsesParagraphAndHorizontalRule', 0, (): void => {
      const nodes: BBNode[] = parseBBCode('[p]第一段[/p][hr]')

      expect(nodes.length).assertEqual(2)
      expect(nodes[0].type).assertEqual(BBNodeType.PARAGRAPH)
      expect(nodes[0].children.length).assertEqual(1)
      expect(nodes[0].children[0].text).assertEqual('第一段')
      expect(nodes[1].type).assertEqual(BBNodeType.HR)
    })

    it('parsesBothHeadingFormsAsBlocks', 0, (): void => {
      const nodes: BBNode[] = parseBBCode('  ===第一条===  \r\n[H][color=red]第二条[/color][/H]')

      expect(nodes.length).assertEqual(3)
      expect(nodes[0].type).assertEqual(BBNodeType.HEADING)
      expect(nodes[0].children[0].text).assertEqual('第一条')
      expect(nodes[1].text).assertEqual('\r\n')
      expect(nodes[2].type).assertEqual(BBNodeType.HEADING)
      expect(nodes[2].children[0].type).assertEqual(BBNodeType.COLOR)
      expect(nodes[2].children[0].children[0].text).assertEqual('第二条')
    })

    it('normalizesNestedAndInlineFormattedHeadingSeparators', 0, (): void => {
      const forms: string[] = [
        '[h]===“乌拉特克的诅咒”内容更新包含内容===[/h]',
        '[size=150%][b]===“乌拉特克的诅咒”内容更新包含内容===[/b][/size]',
        '[h][size=150%][b]===“乌拉特克的诅咒”内容更新包含内容===[/b][/size][/h]',
        '[size=150%][b][h]===“乌拉特克的诅咒”内容更新包含内容===[/h][/b][/size]'
      ]

      for (let i: number = 0; i < forms.length; i++) {
        const nodes: BBNode[] = parseBBCode(forms[i])
        const runs: InlineRun[] = flattenInlineNodes(nodes[0].children)
        expect(nodes.length).assertEqual(1)
        expect(nodes[0].type).assertEqual(BBNodeType.HEADING)
        expect(runs.length).assertEqual(1)
        expect(runs[0].text).assertEqual('“乌拉特克的诅咒”内容更新包含内容')
        if (i > 0) {
          expect(runs[0].style.scalePercent).assertEqual(150)
          expect(runs[0].style.bold).assertTrue()
        }
      }
    })

    it('limitsHeadingSeparatorsToFullLinesOutsideCode', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '公式 a===b===c\n[code]===行内代码===[/code]\n[code]\n===跨行代码===\n[/code]\n===标题===')

      expect(nodes.length).assertEqual(6)
      expect(nodes[0].type).assertEqual(BBNodeType.TEXT)
      expect(nodes[0].text).assertEqual('公式 a===b===c\n')
      expect(nodes[1].type).assertEqual(BBNodeType.CODE)
      expect(nodes[1].text).assertEqual('===行内代码===')
      expect(nodes[2].text).assertEqual('\n')
      expect(nodes[3].type).assertEqual(BBNodeType.CODE)
      expect(nodes[3].text).assertEqual('\n===跨行代码===\n')
      expect(nodes[4].text).assertEqual('\n')
      expect(nodes[5].type).assertEqual(BBNodeType.HEADING)
      expect(nodes[5].children[0].text).assertEqual('标题')
    })

    it('parsesHeadingAfterNestedSameTypeBlocks', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[quote][quote]内层引用[/quote]\n===引用内标题===\n[/quote]')

      expect(nodes.length).assertEqual(1)
      expect(nodes[0].type).assertEqual(BBNodeType.QUOTE)
      expect(nodes[0].children.length).assertEqual(4)
      expect(nodes[0].children[0].type).assertEqual(BBNodeType.QUOTE)
      expect(nodes[0].children[2].type).assertEqual(BBNodeType.HEADING)
      expect(nodes[0].children[2].children[0].text).assertEqual('引用内标题')
    })

    it('keepsInvalidHeadingWrappersInTheInlinePipeline', 0, (): void => {
      const invalidSizeRuns: InlineRun[] = flattenInlineNodes(
        parseBBCode('[size=invalid]===标题===[/size]'))
      const crossingRuns: InlineRun[] = flattenInlineNodes(
        parseBBCode('[b][i]===标题===[/b][/i]'))

      expect(invalidSizeRuns.length).assertEqual(1)
      expect(invalidSizeRuns[0].text).assertEqual('[size=invalid]===标题===[/size]')
      expect(crossingRuns.length).assertEqual(2)
      expect(crossingRuns[0].text).assertEqual('===标题===')
      expect(crossingRuns[1].text).assertEqual('[/i]')
    })

    it('keepsTagHeavyContentOnTheNormalInlinePath', 0, (): void => {
      const runs: InlineRun[] = flattenInlineNodes(parseBBCode('[b]x[/b]'.repeat(1200)))

      expect(runs.length).assertEqual(1)
      expect(runs[0].text.length).assertEqual(1200)
      expect(runs[0].style.bold).assertTrue()
    })

    it('removesQuoteHeaderSeparatingBreaks', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[quote][pid=1,2,1]Reply[/pid] [b]Post by [uid=42]user[/uid] (2026-01-01):[/b]<br/><br/>正文[/quote]')

      expect(nodes.length).assertEqual(1)
      expect(nodes[0].type).assertEqual(BBNodeType.QUOTE)
      expect(nodes[0].children.length).assertEqual(2)
      expect(nodes[0].children[0].type).assertEqual(BBNodeType.POST_BY)
      expect(nodes[0].children[1].text).assertEqual('正文')
    })

    it('keepsReplyToPrefixAndBodyBoundaryWhenNoBreak', 0, (): void => {
      /* 真实形态（tid=47475364 lou=51）：Reply to 引用头与正文之间无 <br/> 分隔，
       * 且处于引用链（51 回复 43，43 引用 35，35 回复 34，34 引用 28）中。
       * 头部 "Reply to " 前缀必须保留（文本零丢失），正文不得被吞入引用头。
       */
      const nodes: BBNode[] = parseBBCode(
        '[b]Reply to [pid=880288018,47475364,3]Reply[/pid] Post by [uid=42023922]llllllIl[/uid] ' +
        '(2026-09-01 12:44)[/b][s:ac:哭笑]我懒得讨论傻逼网易的问题，他到现在还没做说明纯态度问题<br/>纯对是一人月觉得太扯罢了，按这么排期一个游戏百人四五年内容不得玩家玩到撑')

      expect(nodes.length).assertEqual(3)
      expect(nodes[0].type).assertEqual(BBNodeType.POST_BY)
      expect(nodes[0].children.length).assertEqual(5)
      expect(nodes[0].children[0].type).assertEqual(BBNodeType.TEXT)
      expect(nodes[0].children[0].text).assertEqual('Reply to ')
      expect(nodes[0].children[1].type).assertEqual(BBNodeType.PID_LINK)
      expect(nodes[0].children[1].href).assertEqual('#/thread?tid=47475364&pid=880288018&page=3')
      expect(nodes[0].children[3].type).assertEqual(BBNodeType.UID_LINK)
      expect(nodes[0].children[3].href).assertEqual('#/profile?uid=42023922')
      expect(nodes[0].children[4].text).assertEqual(' (2026-09-01 12:44):')
      expect(nodes[1].type).assertEqual(BBNodeType.EMOTION)
      expect(nodes[2].type).assertEqual(BBNodeType.TEXT)
      expect(nodes[2].text.startsWith('我懒得讨论傻逼网易的问题')).assertTrue()
      expect(nodes[2].text.endsWith('内容不得玩家玩到撑')).assertTrue()
    })

    it('keepsQuoteReplyPageInPidLinkHref', 0, (): void => {
      // NGA 引用头 [pid=pid,tid,page] 携带引用楼层所在页，
      // 链接必须保留 page 供帖子页按页加载整页后定位
      const quoteNodes: BBNode[] = parseBBCode(
        '[quote][pid=868052707,46425481,8]Reply[/pid] [b]Post by [uid=1379135]就是会装死[/uid] ' +
        '(2026-05-14 13:34):[/b]<br/>燃烧之刃dk漂亮男孩又来麻烦大佬做披风[/quote]')
      expect(quoteNodes.length).assertEqual(1)
      expect(quoteNodes[0].type).assertEqual(BBNodeType.QUOTE)
      const postBy: BBNode = quoteNodes[0].children[0]
      expect(postBy.type).assertEqual(BBNodeType.POST_BY)
      const replyLink: BBNode = postBy.children[0]
      expect(replyLink.type).assertEqual(BBNodeType.PID_LINK)
      expect(replyLink.href).assertEqual('#/thread?tid=46425481&pid=868052707&page=8')

      // 两值形式（普通回复链接）行为不变
      const plainNodes: BBNode[] = parseBBCode('[pid=101112,131415]回复链接[/pid]')
      expect(plainNodes[0].type).assertEqual(BBNodeType.PID_LINK)
      expect(plainNodes[0].href).assertEqual('#/thread?tid=131415&pid=101112')

      // 第三值非数字时不追加 page
      const oddNodes: BBNode[] = parseBBCode('[pid=1,2,abc]Reply[/pid]')
      expect(oddNodes[0].type).assertEqual(BBNodeType.PID_LINK)
      expect(oddNodes[0].href).assertEqual('#/thread?tid=2&pid=1')
    })

    it('preservesUnknownAndUnmatchedTagsAsText', 0, (): void => {
      const runs: InlineRun[] = flattenInlineNodes(parseBBCode('前[/b][unknown]后'))

      expect(runs.length).assertEqual(1)
      expect(runs[0].text).assertEqual('前[/b][unknown]后')
    })

    it('appliesWhitelistedStyleDeclaration', 0, (): void => {
      const base = new InlineTextStyle()
      const style: InlineTextStyle = applyTextStyleDeclaration(
        'color: #ff0000; font-size: 150%; font-weight: 700; font-style: italic; font-family: 宋体', base)

      expect(style.color).assertEqual('#ff0000')
      expect(style.scalePercent).assertEqual(150)
      expect(style.bold).assertTrue()
      expect(style.italic).assertTrue()
      expect(style.fontFamily).assertEqual('serif')
    })

    it('supportsFontNestedSizeAndBaselines', 0, (): void => {
      const runs: InlineRun[] = flattenInlineNodes(parseBBCode(
        '[font=Consolas][size=200%][size=200%]大[/size][/size][sub]下[/sub][sup]上[/sup][/font]'))

      expect(runs.length).assertEqual(3)
      expect(runs[0].style.fontFamily).assertEqual('Consolas,monospace')
      expect(runs[0].style.scalePercent).assertEqual(300)
      expect(runs[1].style.baseline).assertEqual(InlineBaseline.SUBSCRIPT)
      expect(runs[2].style.baseline).assertEqual(InlineBaseline.SUPERSCRIPT)
    })

    it('normalizesFontFamilyWithFallbackChain', 0, (): void => {
      // 拉丁专名：系统表存在时精确命中，否则落到保底族
      expect(normalizeFontFamily('Times New Roman')).assertEqual('Times New Roman,serif')
      expect(normalizeFontFamily('Arial')).assertEqual('Arial,sans-serif')
      expect(normalizeFontFamily('Courier New')).assertEqual('Courier New,monospace')
      // 长名优先于子串抢占
      expect(normalizeFontFamily('Arial Black')).assertEqual('Arial Black,sans-serif')
      // 中文/拼音别名直接落到保底族
      expect(normalizeFontFamily('宋体')).assertEqual('serif')
      expect(normalizeFontFamily('simhei')).assertEqual('sans-serif')
      // 通用族与未知名字
      expect(normalizeFontFamily('monospace')).assertEqual('monospace')
      expect(normalizeFontFamily('Futura')).assertEqual('Futura')
    })

    it('derivesUrlFromFormattedBody', 0, (): void => {
      const runs: InlineRun[] = flattenInlineNodes(parseBBCode(
        '[url][b]https://example.com/path[/b][/url]'))

      expect(runs.length).assertEqual(1)
      expect(runs[0].kind).assertEqual(InlineRunKind.LINK)
      expect(runs[0].href).assertEqual('https://example.com/path')
      expect(runs[0].style.bold).assertTrue()
    })

    it('parsesLinkInsideDisplayBrackets', 0, (): void => {
      const runs: InlineRun[] = flattenInlineNodes(parseBBCode(
        '文档 [[url]https://example.com[/url]]'))

      expect(runs.length).assertEqual(3)
      expect(runs[0].text).assertEqual('文档 [')
      expect(runs[1].kind).assertEqual(InlineRunKind.LINK)
      expect(runs[1].href).assertEqual('https://example.com')
      expect(runs[2].text).assertEqual(']')
    })

    it('containsMalformedCrossingTags', 0, (): void => {
      const runs: InlineRun[] = flattenInlineNodes(parseBBCode('[b][i]内[/b]外[/i]'))

      expect(runs.length).assertEqual(2)
      expect(runs[0].text).assertEqual('内')
      expect(runs[0].style.bold).assertTrue()
      expect(runs[0].style.italic).assertTrue()
      expect(runs[1].text).assertEqual('外[/i]')
      expect(runs[1].style.bold).assertFalse()
      expect(runs[1].style.italic).assertFalse()
    })

    it('doesNotDuplicateInvalidStyleAcrossBlocks', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[size=invalid]前[img]https://example.com/a.jpg[/img]后[/size]')
      const before: InlineRun[] = flattenInlineNodes([nodes[0]])
      const after: InlineRun[] = flattenInlineNodes([nodes[2]])

      expect(before[0].text).assertEqual('[size=invalid]前')
      expect(after[0].text).assertEqual('后[/size]')
      expect(nodes[1].inheritedFormatTags.length).assertEqual(0)
    })

    it('keepsInheritedStyleWhenCssValueIsRejected', 0, (): void => {
      const inherited: InlineTextStyle = applyInlineFormatTags(['[color=red]'], new InlineTextStyle())
      const style: InlineTextStyle = applyTextStyleDeclaration(
        'color: rgb(1, 2, 3); font-family: ' + 'x'.repeat(65) + '; text-align: center', inherited)

      expect(style.color).assertEqual('#ff0000')
      expect(style.fontFamily).assertEqual('')
      expect(extractTextStyleAlign('color:red; text-align: CENTER')).assertEqual('center')
      expect(extractTextStyleAlign('color:red')).assertEqual('')
    })

    it('keepsColumnsAlignedAcrossRowSpan', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[table][tr][td rowspan=2]合并行[/td][td]普通[/td][/tr][tr][td]第二行[/td][/tr][/table]')
      const layout: TableLayout = buildTableLayout(nodes[0])

      expect(layout.columnCount).assertEqual(2)
      expect(layout.rows.length).assertEqual(2)
      expect(layout.rows[1].cells.length).assertEqual(2)
      expect(layout.rows[0].cells[0].rendersContent).assertFalse()
      expect(layout.rows[1].cells[0].rendersContent).assertTrue()
      expect(layout.rows[1].cells[0].connectsAbove).assertTrue()
      expect(layout.rows[1].cells[1].columnStart).assertEqual(1)
      expect(layout.rows[1].cells[1].rendersContent).assertTrue()
    })

    it('keepsRectangularAreaForCombinedRowAndColumnSpan', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[table][tr][td rowspan=2 colspan=2]合并[/td][td]右上[/td][/tr][tr][td]右下[/td][/tr][/table]')
      const layout: TableLayout = buildTableLayout(nodes[0])

      expect(layout.columnCount).assertEqual(3)
      expect(layout.rows[1].cells[0].columnSpan).assertEqual(2)
      expect(layout.rows[1].cells[1].columnStart).assertEqual(2)
    })

    it('resolvesRelativeAttachTagToCdnLink', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[attach]./mon_202608/03/k2Q81-97rkXrT6wSk0-zk.mp4[/attach]')

      expect(nodes.length).assertEqual(1)
      expect(nodes[0].type).assertEqual(BBNodeType.URL)
      expect(nodes[0].href).assertEqual(
        'https://img.nga.cn/attachments/mon_202608/03/k2Q81-97rkXrT6wSk0-zk.mp4')
      expect(nodes[0].text).assertEqual(nodes[0].href)
      const runs: InlineRun[] = flattenInlineNodes(nodes)
      expect(runs.length).assertEqual(1)
      expect(runs[0].kind).assertEqual(InlineRunKind.LINK)
    })

    it('keepsNonNgaAttachTagAsPlainText', 0, (): void => {
      const nodes: BBNode[] = parseBBCode('[attach]https://evil.example.com/a.zip[/attach]')

      expect(nodes.length).assertEqual(1)
      expect(nodes[0].type).assertEqual(BBNodeType.TEXT)
      expect(nodes[0].text).assertEqual('[attach]https://evil.example.com/a.zip[/attach]')
    })

    it('keepsUnclosedAttachTagAsPlainText', 0, (): void => {
      const nodes: BBNode[] = parseBBCode('[attach]./mon_202608/03/unclosed.mp4')

      expect(nodes.length).assertEqual(1)
      expect(nodes[0].type).assertEqual(BBNodeType.TEXT)
      expect(nodes[0].text).assertEqual('[attach]./mon_202608/03/unclosed.mp4')
    })
  })

  it('normalizesLegacyAttachDomainImgToNgaCn', 0, (): void => {
    // 官方 commonui.correctAttachUrl 语义：img.nga.178.com 等旧附件域统一迁移到 img.nga.cn
    const nodes: BBNode[] = parseBBCode(
      '[img]https://img.nga.178.com/attachments/mon_202112/05/x.png[/img]')

    expect(nodes.length).assertEqual(1)
    expect(nodes[0].type).assertEqual(BBNodeType.IMAGE)
    expect(nodes[0].src).assertEqual('https://img.nga.cn/attachments/mon_202112/05/x.png')
  })

  it('keepsNonNgaDomainImgUrlUnchanged', 0, (): void => {
    const nodes: BBNode[] = parseBBCode('[img]https://example.com/a.png[/img]')

    expect(nodes.length).assertEqual(1)
    expect(nodes[0].type).assertEqual(BBNodeType.IMAGE)
    expect(nodes[0].src).assertEqual('https://example.com/a.png')
  })

  it('normalizesImgInTableCells', 0, (): void => {
    const nodes: BBNode[] = parseBBCode(
      '[table][tr][td][img]https://img.nga.178.com/attachments/mon_202112/05/x.png[/img]AL[/td][/tr][/table]')
    expect(nodes.length).assertEqual(1)
    const cell: BBNode = nodes[0].children[0].children[0]
    expect(cell.type).assertEqual(BBNodeType.TABLE_CELL)
    expect(cell.children[0].type).assertEqual(BBNodeType.IMAGE)
    expect(cell.children[0].src).assertEqual('https://img.nga.cn/attachments/mon_202112/05/x.png')
  })

  it('parsesNumericMentionAsProfileLink', 0, (): void => {
    const nodes: BBNode[] = parseBBCode('[@123456]')

    expect(nodes.length).assertEqual(1)
    expect(nodes[0].type).assertEqual(BBNodeType.MENTION)
    expect(nodes[0].href).assertEqual('#/profile?uid=123456')
    expect(nodes[0].text).assertEqual('@123456')
  })

  it('parsesUidPrefixedMentionCaseInsensitively', 0, (): void => {
    const nodes: BBNode[] = parseBBCode('[@UID123] 与 [@uid456]')

    expect(nodes.length).assertEqual(3)
    expect(nodes[0].type).assertEqual(BBNodeType.MENTION)
    expect(nodes[0].href).assertEqual('#/profile?uid=123')
    expect(nodes[2].type).assertEqual(BBNodeType.MENTION)
    expect(nodes[2].href).assertEqual('#/profile?uid=456')
  })

  it('parsesTextUsernameMentionAsUsernameRoute', 0, (): void => {
    const nodes: BBNode[] = parseBBCode('[@那个黑枪不能再打了]')
    const runs: InlineRun[] = flattenInlineNodes(nodes)

    expect(nodes.length).assertEqual(1)
    expect(nodes[0].type).assertEqual(BBNodeType.MENTION)
    expect(nodes[0].text).assertEqual('@那个黑枪不能再打了')
    expect(nodes[0].href.startsWith('#/profile?username=')).assertTrue()
    expect(runs.length).assertEqual(1)
    expect(runs[0].kind).assertEqual(InlineRunKind.LINK)
  })

  it('keepsOutOfRangeMentionAsPlainText', 0, (): void => {
    const nodes: BBNode[] = parseBBCode('[@1] 与 [@ABCDEFGHIJKLMNOPQRSTUV]')

    expect(nodes.length).assertEqual(1)
    expect(nodes[0].type).assertEqual(BBNodeType.TEXT)
    expect(nodes[0].text).assertEqual('[@1] 与 [@ABCDEFGHIJKLMNOPQRSTUV]')
  })
}
