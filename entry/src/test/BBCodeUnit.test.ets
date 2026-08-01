import { describe, expect, it } from '@ohos/hypium'
import { BBNode, BBNodeType } from '../main/ets/model/BBCodeNode'
import { parseBBCode } from '../main/ets/parser/bbcode/parser'
import { indexOfIgnoreCase } from '../main/ets/parser/bbcode/lexer'
import {
  applyInlineFormatTags,
  applyTextStyleDeclaration,
  extractTextStyleAlign,
  flattenInlineNodes,
  InlineBaseline,
  InlineRun,
  InlineRunKind,
  InlineTextStyle,
  isInlineRunsBlank
} from '../main/ets/common/components/bbcode/bbcode-utils'

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

    it('acceptsUppercaseTagsAndKeepsLineBreaks', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[B][URL=https://example.com][U]链接[/U][/URL][/B]<br/><br/>&lt;T&gt; &#91;b&#93;')
      const runs: InlineRun[] = flattenInlineNodes(nodes)

      expect(runs.length).assertEqual(2)
      expect(runs[0].kind).assertEqual(InlineRunKind.LINK)
      expect(runs[0].style.bold).assertTrue()
      expect(runs[0].style.underline).assertTrue()
      expect(runs[1].text).assertEqual('\n\n<T> [b]')
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

    it('removesQuoteHeaderSeparatingBreaks', 0, (): void => {
      const nodes: BBNode[] = parseBBCode(
        '[quote][pid=1,2,1]Reply[/pid] [b]Post by [uid=42]user[/uid] (2026-01-01):[/b]<br/><br/>正文[/quote]')

      expect(nodes.length).assertEqual(1)
      expect(nodes[0].type).assertEqual(BBNodeType.QUOTE)
      expect(nodes[0].children.length).assertEqual(2)
      expect(nodes[0].children[0].type).assertEqual(BBNodeType.POST_BY)
      expect(nodes[0].children[1].text).assertEqual('正文')
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
      expect(runs[0].style.fontFamily).assertEqual('monospace')
      expect(runs[0].style.scalePercent).assertEqual(300)
      expect(runs[1].style.baseline).assertEqual(InlineBaseline.SUBSCRIPT)
      expect(runs[2].style.baseline).assertEqual(InlineBaseline.SUPERSCRIPT)
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
      expect(style.fontFamily).assertEqual('HarmonyOS Sans')
      expect(extractTextStyleAlign('color:red; text-align: CENTER')).assertEqual('center')
      expect(extractTextStyleAlign('color:red')).assertEqual('')
    })
  })
}
