import { describe, expect, it } from '@ohos/hypium'
import { injectQuoteContent } from '../main/ets/common/utils/QuoteInjection'
import { PostInfo } from '../main/ets/model/PostInfo'

/**
 * 构造帖子对象。
 *
 * @param pid 楼层 pid
 * @param lou 楼层号
 * @param content 楼层正文
 * @returns 帖子对象
 */
function makePost(pid: number, lou: number, content: string): PostInfo {
  const p = new PostInfo()
  p.pid = pid
  p.lou = lou
  p.content = content
  return p
}

/**
 * 注册引用注入（QuoteInjection）回归测试。
 *
 * 覆盖 51 楼形态：Reply to 引用区必须只含被回复楼正文，
 * 不得粘连被回复楼引用链内容（官方语义对齐），换行保留。
 */
export default function quoteInjectionUnitTest(): void {
  describe('quoteInjection', (): void => {
    it('injectsOnlyReferencedBodyNotQuoteChain', 0, (): void => {
      /* 真实形态（tid=47475364 lou=43/51）：43 楼引用链平铺（28/34/35 楼的话）
       * + 自身正文；51 楼 Reply to 43。官方客户端 51 楼引用区开头是 43 楼正文
       * "对对对，我就是"，不得出现 43 楼引用链内容（"一个月真的张口就来"）。
       */
      const lou43Content: string =
        '[quote][pid=880281790,47475364,2]Reply[/pid] [b]Post by [uid=43097124]三月三儿三[/uid] ' +
        '(2026-09-01 11:47):[/b]<br/>[s:ac:哭笑]一个月真的张口就来，我们公司90%业务在h5做鸿蒙迁移都用了五六个人月。<br/>' +
        '[s:ac:哭笑]有啥好交流的，公司两个项目迁完没啥迭代需求就不碰鸿蒙了。[/quote]<br/><br/><br/><br/><br/>' +
        '对对对，我就是某厂做游戏的，不劳烦你给我介绍互联网公司开发流程<br/>' +
        '纯粹是不想做，现在发现市占率有压力了，被压kpi低头去做。'
      const lou51Content: string =
        '[b]Reply to [pid=880288018,47475364,3]Reply[/pid] Post by [uid=42023922]llllllIl[/uid] ' +
        '(2026-09-01 12:44)[/b][s:ac:哭笑]我懒得讨论傻逼网易的问题，他到现在还没做说明纯态度问题<br/>' +
        '纯对是一人月觉得太扯罢了。'
      const lou43 = makePost(880288018, 43, lou43Content)
      const lou51 = makePost(880300877, 51, lou51Content)
      const posts: PostInfo[] = [lou51, lou43]
      injectQuoteContent(posts, posts)

      expect(lou51.content.startsWith('[quote][pid=880288018,47475364,3]Reply[/pid]')).assertTrue()
      /* 引用区只含 43 楼自身正文：引用链内容（28 楼 "一个月真的张口就来"、
       * 35 楼 "有啥好交流的"）不得注入，也不得与正文无缝粘连。 */
      expect(lou51.content.includes('一个月真的张口就来')).assertFalse()
      expect(lou51.content.includes('有啥好交流的')).assertFalse()
      expect(lou51.content.includes('对对对，我就是某厂做游戏的')).assertTrue()
      /* 43 楼正文换行保留（<br/> 转 \n），段落之间不粘连。 */
      expect(lou51.content.includes('开发流程\n纯粹是不想做')).assertTrue()
      /* 51 楼自己的话保留在引用区外（原始 content 的 [s:ac:哭笑] 起，<br/> 原样保留）。 */
      expect(lou51.content.endsWith(
        '[s:ac:哭笑]我懒得讨论傻逼网易的问题，他到现在还没做说明纯态度问题<br/>纯对是一人月觉得太扯罢了。'))
        .assertTrue()
    })

    it('injectsReferencedPlainBodyForSimpleReplyTo', 0, (): void => {
      /* 被回复楼无引用区：注入其完整正文，换行保留。 */
      const lou20Content: string = '这有啥好嘲讽的？拿一年前的回复来证明不慢？<br/>第二段内容。'
      const lou28Content: string =
        '[b]Reply to [pid=880227572,47475364,2]Reply[/pid] Post by [uid=42023922]llllllIl[/uid] ' +
        '(2026-08-31 20:40)[/b][s:ac:哭笑]一个月真的张口就来，我们公司90%业务在h5做鸿蒙迁移都用了五六个人月。'
      const lou20 = makePost(880227572, 20, lou20Content)
      const lou28 = makePost(880264533, 28, lou28Content)
      const posts: PostInfo[] = [lou28, lou20]
      injectQuoteContent(posts, posts)

      expect(lou28.content.startsWith('[quote]')).assertTrue()
      expect(lou28.content.includes('这有啥好嘲讽的？拿一年前的回复来证明不慢？\n第二段内容。')).assertTrue()
      expect(lou28.content.includes('Reply to [pid')).assertFalse()
      expect(lou28.content.endsWith('[s:ac:哭笑]一个月真的张口就来，我们公司90%业务在h5做鸿蒙迁移都用了五六个人月。'))
        .assertTrue()
    })

    it('keepsTruncatedQuoteFixWithLineBreaks', 0, (): void => {
      /* 服务端截断引用（lou=44 引用 lou=33，截断发生在段落边界）修复为
       * 完整正文，换行保留（<br/> 转 \n），段落不粘连。 */
      const lou33Content: string = '事实就是网易策略就是没问题啊<br/>早期hm坑那么多，基本都得找hw的人驻场适配<br/>' +
        '反过来说，用网易云音乐的人，hm5.0什么都没得用。'
      const lou44Content: string =
        '[quote][pid=880268502,47475364,2]Reply[/pid] [b]Post by [uid=2130667]SunnyF[/uid] ' +
        '(2026-09-01 10:14):[/b]<br/>事实就是网易策略就是没问题啊<br/>早期hm坑那么多，基本都得找hw的人驻场适配[/quote]' +
        '<br/>为了舔网易居然打了一堆狗屁不通的字找补'
      const lou33 = makePost(880268502, 33, lou33Content)
      const lou44 = makePost(880288366, 44, lou44Content)
      const posts: PostInfo[] = [lou44, lou33]
      injectQuoteContent(posts, posts)

      expect(lou44.content.includes('反过来说，用网易云音乐的人，hm5.0什么都没得用。')).assertTrue()
      expect(lou44.content.includes('驻场适配\n反过来说')).assertTrue()
      expect(lou44.content.endsWith('<br/>为了舔网易居然打了一堆狗屁不通的字找补')).assertTrue()
    })

    it('skipsPostsAlreadyStartingWithQuote', 0, (): void => {
      /* 已是 [quote] 开头的楼层（服务端引用）不重复注入。 */
      const lou35Content: string = '[s:ac:哭笑]有啥好交流的，公司两个项目迁完没啥迭代需求就不碰鸿蒙了。'
      const lou43Content: string =
        '[quote][pid=880281790,47475364,2]Reply[/pid] [b]Post by [uid=43097124]三月三儿三[/uid] ' +
        '(2026-09-01 11:47):[/b]<br/>' + lou35Content + '[/quote]<br/><br/>对对对，我就是某厂做游戏的。'
      const lou35 = makePost(880281790, 35, lou35Content)
      const lou43 = makePost(880288018, 43, lou43Content)
      const posts: PostInfo[] = [lou43, lou35]
      const before: string = lou43.content
      injectQuoteContent(posts, posts)
      expect(lou43.content).assertEqual(before)
    })
  })
}
