import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { buildReplyQuoteContent, fixTruncatedQuoteContent } from '../src/common/utils/QuoteInjectionCore'

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
})
