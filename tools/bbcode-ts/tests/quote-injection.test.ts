import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  buildReplyQuoteContent,
  fixTruncatedQuoteContent,
  isBlankBodyText,
  stripCommentReplyHeader,
  stripReplyToHeader,
} from '../src/common/utils/QuoteInjectionCore'

/** 样本目录（相对 tools/bbcode-ts 运行目录）。 */
const SAMPLES_DIR: string = join(process.cwd(), 'samples')

/**
 * 从已固化的 APP 成对样本中读取真实楼层 content。
 *
 * @param lou 楼层号
 * @returns 该楼层真实 content；缺失时抛出
 */
function realContent(lou: number): string {
  const pair = JSON.parse(readFileSync(
    join(SAMPLES_DIR, 'app-html-pair-47475364-p3.json'), 'utf8'))
  const rows: Record<string, unknown> = (pair.data.__R ?? {}) as Record<string, unknown>
  const keys: string[] = Object.keys(rows)
  for (const key of keys) {
    const row: Record<string, unknown> = rows[key] as Record<string, unknown>
    if (row['lou'] === lou) {
      return String(row['content'] ?? '')
    }
  }
  throw new Error(`样本中不存在 lou=${lou}`)
}

/** 51 楼真实 content（Reply to 43 楼）。 */
const LOU51: string = realContent(51)
/** 43 楼真实 content（引用 35 楼，引用区为整条引用链平铺 + 自身正文）。 */
const LOU43: string = realContent(43)

/**
 * 引用注入核心（QuoteInjectionCore）回归。
 *
 * 覆盖 51 楼形态（tid=47475364）：Reply to 引用区必须只含被回复楼正文，
 * 不得粘连被回复楼引用链内容（官方语义对齐），换行保留。
 */
describe('引用注入核心（QuoteInjectionCore）', () => {
  it('Reply to 注入只取被回复楼正文，引用链内容不粘连', () => {
    const lookup = (pid: number): string | undefined => pid === 880288018 ? LOU43 : undefined
    const result: string = buildReplyQuoteContent(LOU51, lookup)

    assert.ok(result.startsWith('[quote][pid=880288018,47475364,3]Reply[/pid]'),
      '引用区头应保留 Reply 目标 pid')
    /* 引用链内容（28 楼 "一个月真的张口就来"、35 楼 "有啥好交流的"）不得注入 */
    assert.ok(!result.includes('一个月真的张口就来'), '不得粘连 28 楼引用链内容')
    assert.ok(!result.includes('有啥好交流的'), '不得粘连 35 楼引用链内容')
    /* 只含 43 楼自身正文，开头与官方客户端一致 */
    assert.ok(result.includes('对对对，我就是某厂做游戏的'), '应含 43 楼自身正文')
    assert.ok(result.indexOf('对对对，我就是') < result.indexOf('[/quote]'),
      '43 楼正文应位于引用区内')
    /* 段落换行保留（<br/> -> \n，表情标签保留），不无缝拼接 */
    assert.ok(result.includes('开发流程[s:ac:哭笑]\n无论线上游戏'), '43 楼正文换行应保留')
    /* 51 楼自己的话保留在引用区外 */
    assert.ok(result.endsWith(
      '[s:ac:哭笑]我懒得讨论傻逼网易的问题，他到现在还没做说明纯态度问题<br/>' +
      '纯对是一人月觉得太扯罢了，按这么排期一个游戏百人四五年内容不得玩家玩到撑'),
      '51 楼自己的话应原样保留在引用区外')
  })

  it('被回复楼无引用区时注入其完整正文', () => {
    const lou20: string = '这有啥好嘲讽的？拿一年前的回复来证明不慢？<br/>第二段内容。'
    const lou28: string =
      '[b]Reply to [pid=880227572,47475364,2]Reply[/pid] Post by [uid=42023922]llllllIl[/uid] ' +
      '(2026-08-31 20:40)[/b][s:ac:哭笑]一个月真的张口就来，我们公司90%业务在h5做鸿蒙迁移都用了五六个人月。'
    const lookup = (pid: number): string | undefined => pid === 880227572 ? lou20 : undefined
    const result: string = buildReplyQuoteContent(lou28, lookup)

    assert.ok(result.startsWith('[quote]'))
    assert.ok(result.includes('这有啥好嘲讽的？拿一年前的回复来证明不慢？\n第二段内容。'))
    assert.ok(!result.includes('Reply to [pid'), '被引用楼的 Reply to 头不进入引用区')
    assert.ok(result.endsWith('[s:ac:哭笑]一个月真的张口就来，我们公司90%业务在h5做鸿蒙迁移都用了五六个人月。'))
  })

  it('粘连 Reply to 头注入后本层正文不丢失', () => {
    /* 真实形态（tid 47855036 的 16 楼）：正文与头共用同一个 [b] 块，中间没有 <br/>。
     * 旧实现按 [/b] 切正文 → replyText 为空 → 本层正文整段消失（列表模式只剩引用块）。 */
    const glued: string =
      '[b]Reply to [pid=886957875,47855036,1]Reply[/pid] Post by [uid=309772]collins[/uid] ' +
      '(2026-11-05 11:33)最差的也不过是又苦又辣，不过种葱的也不i傻是，肯定挑好的种，' +
      '即便味道出现偏差也不至于太离谱。[/b]'
    const quoted: string = '葱这个玩意味道差能差到哪里去？<br/><br/>看最后一张图，葱白也不短啊？'
    const lookup = (pid: number): string | undefined => pid === 886957875 ? quoted : undefined
    const result: string = buildReplyQuoteContent(glued, lookup)

    assert.ok(result.includes('葱这个玩意味道差能差到哪里去？'), '引用区应含被引楼层正文')
    assert.ok(result.includes('最差的也不过是又苦又辣'), '本层正文必须保留')
    assert.ok(result.indexOf('最差的也不过是') > result.indexOf('[/quote]'),
      '本层正文应位于引用区之外')
    assert.ok(!result.includes('离谱。[/b]'), '不得残留头部闭合标签')
    assert.ok(result.endsWith('即便味道出现偏差也不至于太离谱。'), '本层正文应原样收尾')
  })

  it('被引用楼层是粘连 Reply to 时只注入其正文', () => {
    const target: string =
      '[b]Reply to [pid=100,47855036,1]Reply[/pid] Post by [uid=1]甲[/uid] (2026-11-05 11:00)[/b]<br/>本层正文'
    const quoted: string =
      '[b]Reply to [pid=200,47855036,1]Reply[/pid] Post by [uid=2]乙[/uid] (2026-11-05 10:00)' +
      '被引用楼的粘连正文[/b]'
    const lookup = (pid: number): string | undefined => pid === 100 ? quoted : undefined
    const result: string = buildReplyQuoteContent(target, lookup)

    assert.ok(result.includes('被引用楼的粘连正文'), '应注入被引用楼正文')
    assert.ok(!result.includes('Reply to [pid=200'), '被引用楼的头不进入引用区')
    assert.ok(!result.includes('[/b]被引用楼的粘连正文'), '不得残留头部闭合标签')
    assert.ok(result.endsWith('本层正文'), '本层正文应保留')
  })

  it('非 Reply to 格式或原文缺失时原样返回', () => {
    const plain: string = '普通正文[pid=1,2]链接[/pid]'
    assert.equal(buildReplyQuoteContent(plain, () => 'x'), plain)
    const replyTo: string =
      '[b]Reply to [pid=880227572,47475364,2]Reply[/pid] Post by [uid=42023922]llllllIl[/uid] ' +
      '(2026-08-31 20:40)[/b]正文'
    assert.equal(buildReplyQuoteContent(replyTo, () => undefined), replyTo)
    assert.equal(buildReplyQuoteContent(replyTo, () => ''), replyTo)
    /* 已被注入过（[quote] 开头）不重复处理 */
    assert.equal(buildReplyQuoteContent(LOU43, () => 'x'), LOU43)
  })

  it('Reply to 头不在正文开头时保留前缀文本', () => {
    /* 容错非标准数据：Reply to 头之前的前缀不得被注入吞掉（文字不被吞原则）。 */
    const odd: string =
      '前文内容[b]Reply to [pid=880227572,47475364,2]Reply[/pid] Post by [uid=42023922]llllllIl[/uid] ' +
      '(2026-08-31 20:40)[/b]正文'
    const lookup = (pid: number): string | undefined => pid === 880227572 ? '被引用楼正文<br/>第二段' : undefined
    const result: string = buildReplyQuoteContent(odd, lookup)

    assert.ok(result.startsWith('前文内容'), '前缀文本应保留')
    assert.ok(result.includes('[quote][pid=880227572,47475364,2]Reply[/pid]'))
    assert.ok(result.includes('被引用楼正文\n第二段'))
    assert.ok(result.endsWith('正文'))
  })

  it('粘连 Reply to 头 + 正文自带粗体时只去头部闭合', () => {
    /* 正文里自带 [b]重点[/b]：头部的 [/b] 在整段末尾，不能把第一个 [/b] 当头部闭合。 */
    const glued: string =
      '[b]Reply to [pid=880227572,47475364,2]Reply[/pid] Post by [uid=42023922]llllllIl[/uid] ' +
      '(2026-08-31 20:40)正文[b]重点[/b]结尾[/b]'
    const lookup = (pid: number): string | undefined => pid === 880227572 ? '被引用楼正文' : undefined
    const result: string = buildReplyQuoteContent(glued, lookup)

    assert.ok(result.includes('被引用楼正文'))
    assert.ok(result.endsWith('正文[b]重点[/b]结尾'), '本层正文与粗体格式应完整保留')
    assert.ok(!result.endsWith('[/b]'), '不得残留头部闭合标签')
  })

  it('Reply to 头缺 [/b] 或 [/b] 不在末尾时不吞正文', () => {
    const lookup = (pid: number): string | undefined => pid === 880227572 ? '被引用楼正文' : undefined
    /* 头缺 [/b]：正文完整保留 */
    const noClose: string =
      '[b]Reply to [pid=880227572,47475364,2]Reply[/pid] Post by [uid=42023922]llllllIl[/uid] ' +
      '(2026-08-31 20:40)<br/>本层正文'
    assert.ok(buildReplyQuoteContent(noClose, lookup).endsWith('<br/>本层正文'),
      '缺 [/b] 时正文不得被吞')
    /* [/b] 在正文中间（后面还有内容）：不能只取到 [/b] 之前 */
    const midClose: string =
      '[b]Reply to [pid=880227572,47475364,2]Reply[/pid] Post by [uid=42023922]llllllIl[/uid] ' +
      '(2026-08-31 20:40)[b]重点[/b]后面还有正文'
    const midResult: string = buildReplyQuoteContent(midClose, lookup)
    assert.ok(midResult.includes('后面还有正文'), '[/b] 之后的正文不得被吞')
  })

  it('stripReplyToHeader 按作者段+日期括号切分且不误吞', () => {
    /* 标准形态 */
    const standard: string =
      '[b]Reply to [pid=1,2,3]Reply[/pid] Post by [uid=9]甲[/uid] (2025-05-26 17:37): [/b]<br/>评论正文'
    assert.equal(stripReplyToHeader(standard), '<br/>评论正文')
    /* 粘连形态 */
    const glued: string =
      '[b]Reply to [pid=1,2,3]Reply[/pid] Post by [uid=9]甲[/uid] (2025-05-26 17:37)评论粘连正文[/b]'
    assert.equal(stripReplyToHeader(glued), '评论粘连正文')
    /* 匿名作者 */
    const anonymous: string =
      '[b]Reply to [pid=1,2,3]Reply[/pid] Post by [uid]#anony_abc[/uid] (2025-05-26 17:37)匿名评论[/b]'
    assert.equal(stripReplyToHeader(anonymous), '匿名评论')
    /* 非标准「Reply to 某人」不是服务端回复头：原样返回，不得按 [/b] 截断 */
    const loose: string = '[b]Reply to 某人[/b] 他说 [uid=1]甲[/uid] (2020年) 那段话很有道理'
    assert.equal(stripReplyToHeader(loose), loose)
    /* 正文里含 [/uid] 与括号的用户内容同样不误吞 */
    assert.equal(stripReplyToHeader('普通正文[uid=1]甲[/uid] (2020年) 后面'), '普通正文[uid=1]甲[/uid] (2020年) 后面')
  })

  it('截断引用修复保留段落换行', () => {
    const lou33: string = '事实就是网易策略就是没问题啊<br/>早期hm坑那么多，基本都得找hw的人驻场适配<br/>' +
      '反过来说，用网易云音乐的人，hm5.0什么都没得用。'
    const lou44: string =
      '[quote][pid=880268502,47475364,2]Reply[/pid] [b]Post by [uid=2130667]SunnyF[/uid] ' +
      '(2026-09-01 10:14):[/b]<br/>事实就是网易策略就是没问题啊<br/>早期hm坑那么多，基本都得找hw的人驻场适配[/quote]' +
      '<br/>为了舔网易居然打了一堆狗屁不通的字找补'
    const lookup = (pid: number): string | undefined => pid === 880268502 ? lou33 : undefined
    const result: string = fixTruncatedQuoteContent(lou44, lookup)

    assert.ok(result.includes('反过来说，用网易云音乐的人，hm5.0什么都没得用。'))
    assert.ok(result.includes('驻场适配\n反过来说'), '修复内容换行应保留')
    assert.ok(result.endsWith('<br/>为了舔网易居然打了一堆狗屁不通的字找补'))
  })

  it('截断点前缀不匹配或原文缺失时原样返回', () => {
    const lou33: string = '事实就是网易策略就是没问题啊<br/>早期hm坑那么多，基本都得找hw的人驻场适配<br/>' +
      '反过来说，用网易云音乐的人，hm5.0什么都没得用。'
    /* 截断带省略号（"反过......"）不属于完整正文前缀，不得误替换 */
    const truncated: string =
      '[quote][pid=880268502,47475364,2]Reply[/pid] [b]Post by [uid=2130667]SunnyF[/uid] ' +
      '(2026-09-01 10:14):[/b]<br/>事实就是网易策略就是没问题啊<br/>反过......[/quote]正文'
    const lookup = (pid: number): string | undefined => pid === 880268502 ? lou33 : undefined
    assert.equal(fixTruncatedQuoteContent(truncated, lookup), truncated)
    assert.equal(fixTruncatedQuoteContent(truncated, () => undefined), truncated)
    assert.equal(fixTruncatedQuoteContent('普通正文', lookup), '普通正文')
  })

  it('stripCommentReplyHeader 只在剥离后仍有正文时去头', () => {
    /* 有正文：正常剥头（标准形态保留前导 <br/>，与既有行为一致） */
    const withBody: string =
      '[b]Reply to [pid=1,2,3]Reply[/pid] Post by [uid=9]甲[/uid] (2025-05-26 17:37)[/b]<br/>评论正文'
    assert.equal(stripCommentReplyHeader(withBody), '<br/>评论正文')
    /* 只有回复头：保守回退原文，避免空气泡 */
    const headerOnly: string =
      '[b]Reply to [pid=1,2,3]Reply[/pid] Post by [uid=9]甲[/uid] (2025-05-26 17:37)[/b]'
    assert.equal(stripCommentReplyHeader(headerOnly), headerOnly)
    /* 头 + 只有空行/占位符：同样回退原文 */
    const headerWithBreaks: string =
      '[b]Reply to [pid=1,2,3]Reply[/pid] Post by [uid=9]甲[/uid] (2025-05-26 17:37)[/b]<br/><br/>'
    assert.equal(stripCommentReplyHeader(headerWithBreaks), headerWithBreaks)
    const headerWithNbsp: string =
      '[b]Reply to [pid=1,2,3]Reply[/pid] Post by [uid=9]甲[/uid] (2025-05-26 17:37)[/b]&nbsp;'
    assert.equal(stripCommentReplyHeader(headerWithNbsp), headerWithNbsp)
    /* 非 Reply to 开头原样返回 */
    assert.equal(stripCommentReplyHeader('普通评论正文'), '普通评论正文')
  })

  it('isBlankBodyText 识别空白/换行/占位符', () => {
    assert.equal(isBlankBodyText(''), true)
    assert.equal(isBlankBodyText('   \n\t'), true)
    assert.equal(isBlankBodyText('<br/>'), true)
    assert.equal(isBlankBodyText('<br>'), true)
    assert.equal(isBlankBodyText('<br />'), true)
    assert.equal(isBlankBodyText('&nbsp;'), true)
    assert.equal(isBlankBodyText('<br/>&nbsp;<br/>'), true)
    assert.equal(isBlankBodyText('正文'), false)
    assert.equal(isBlankBodyText('[s:ac:哭笑]'), false)
  })
})
