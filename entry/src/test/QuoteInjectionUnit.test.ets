import { describe, expect, it } from '@ohos/hypium'
import { injectQuoteContent, stripCommentReplyHeader } from '../main/ets/common/utils/QuoteInjection'
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

    it('keepsBodyOfGluedReplyToHeader', 0, (): void => {
      /* 真实形态（tid=47855036 的 16 楼）：正文与 Reply to 头共用同一个 [b] 块，
       * 中间没有 <br/>。注入后本层正文必须保留在引用区之外——旧实现按 [/b] 切正文，
       * 正文会被整段丢掉（列表模式整层只剩引用块）。 */
      const lou5Content: string = '葱这个玩意味道差能差到哪里去？<br/><br/>看最后一张图，葱白也不短啊？'
      const lou16Content: string =
        '[b]Reply to [pid=886957875,47855036,1]Reply[/pid] Post by [uid=309772]collins[/uid] ' +
        '(2026-11-05 11:33)最差的也不过是又苦又辣，不过种葱的也不i傻是，肯定挑好的种，' +
        '即便味道出现偏差也不至于太离谱。[/b]'
      const lou5 = makePost(886957875, 5, lou5Content)
      const lou16 = makePost(886958643, 16, lou16Content)
      const posts: PostInfo[] = [lou16, lou5]
      injectQuoteContent(posts, posts)

      expect(lou16.content.includes('葱这个玩意味道差能差到哪里去？')).assertTrue()
      expect(lou16.content.includes('最差的也不过是又苦又辣')).assertTrue()
      expect(lou16.content.indexOf('最差的也不过是') > lou16.content.indexOf('[/quote]')).assertTrue()
      expect(lou16.content.endsWith('即便味道出现偏差也不至于太离谱。')).assertTrue()
    })

    it('stripsGluedHeaderFromReferencedFloor', 0, (): void => {
      /* 被引用楼层自身是粘连 Reply to 形态：注入的引用区只含它的正文，
       * 头与末尾的 [/b] 都不得进入引用区。 */
      const quotedContent: string =
        '[b]Reply to [pid=200,47855036,1]Reply[/pid] Post by [uid=2]乙[/uid] (2026-11-05 10:00)' +
        '被引用楼的粘连正文[/b]'
      const targetContent: string =
        '[b]Reply to [pid=100,47855036,1]Reply[/pid] Post by [uid=1]甲[/uid] (2026-11-05 11:00)[/b]<br/>本层正文'
      const quoted = makePost(100, 2, quotedContent)
      const target = makePost(101, 3, targetContent)
      const posts: PostInfo[] = [target, quoted]
      injectQuoteContent(posts, posts)

      expect(target.content.includes('被引用楼的粘连正文')).assertTrue()
      expect(target.content.includes('Reply to [pid=200')).assertFalse()
      expect(target.content.includes('[/b]被引用楼的粘连正文')).assertFalse()
      expect(target.content.endsWith('本层正文')).assertTrue()
    })

    it('stripsCommentReplyHeaderKeepingGluedBody', 0, (): void => {
      /* 楼中楼评论的回复头：标准形态只去头；粘连形态只去头与末尾 [/b]，
       * 评论正文必须保留（旧正则按 [/b] 截取会把正文整段吃掉）。 */
      const standard: string =
        '[b]Reply to [pid=1,2,3]Reply[/pid] Post by [uid=9]甲[/uid] (2025-05-26 17:37)[/b]<br/><br/>评论正文'
      expect(stripCommentReplyHeader(standard)).assertEqual('<br/><br/>评论正文')

      const glued: string =
        '[b]Reply to [pid=1,2,3]Reply[/pid] Post by [uid=9]甲[/uid] (2025-05-26 17:37)评论粘连正文[/b]'
      expect(stripCommentReplyHeader(glued)).assertEqual('评论粘连正文')

      const anonymous: string =
        '[b]Reply to [pid=1,2,3]Reply[/pid] Post by [uid]#anony_abc[/uid] (2025-05-26 17:37)匿名评论[/b]'
      expect(stripCommentReplyHeader(anonymous)).assertEqual('匿名评论')

      /* 头尾带冒号与空格再闭合：不得残留裸 [/b] */
      const colonClose: string =
        '[b]Reply to [pid=1,2,3]Reply[/pid] Post by [uid=9]甲[/uid] (2025-05-26 17:37): [/b]<br/>评论正文'
      expect(stripCommentReplyHeader(colonClose)).assertEqual('<br/>评论正文')

      /* 作者段带颜色包装的楼号：`[color=gray](224楼)[/color] (日期)` */
      const floorHint: string =
        '[b]Reply to [pid=1,2,3]Reply[/pid] Post by [uid=9]甲[/uid][color=gray](224楼)[/color] ' +
        '(2025-07-27 22:54)楼号评论[/b]'
      expect(stripCommentReplyHeader(floorHint)).assertEqual('楼号评论')

      /* 非标准「Reply to 某人」不是服务端回复头：原样返回，不得按 [/b] 截断 */
      const loose: string = '[b]Reply to 某人[/b] 他说 [uid=1]甲[/uid] (2020年) 那段话很有道理'
      expect(stripCommentReplyHeader(loose)).assertEqual(loose)

      expect(stripCommentReplyHeader('普通评论正文')).assertEqual('普通评论正文')
    })

    it('keepsCommentReplyHeaderWhenNoBodyRemains', 0, (): void => {
      /**
       * 保守剥离：评论整条只有回复头时回退原文，不能把气泡剥成空。
       * 与楼层「只有引用区」的处理一致（`PostComments.commentNodes` 会保留 POST_BY 节点）。
       */
      const headerOnly: string =
        '[b]Reply to [pid=1,2,3]Reply[/pid] Post by [uid=9]甲[/uid] (2025-05-26 17:37)[/b]'
      expect(stripCommentReplyHeader(headerOnly)).assertEqual(headerOnly)

      /* 头 + 尾部空行：剥离后只剩 <br/>，同样视为没有正文 */
      const headerWithBreaks: string =
        '[b]Reply to [pid=1,2,3]Reply[/pid] Post by [uid=9]甲[/uid] (2025-05-26 17:37)[/b]<br/><br/>'
      expect(stripCommentReplyHeader(headerWithBreaks)).assertEqual(headerWithBreaks)

      /* 头 + 只有 &nbsp;：同样是「没有可见正文」 */
      const headerWithNbsp: string =
        '[b]Reply to [pid=1,2,3]Reply[/pid] Post by [uid=9]甲[/uid] (2025-05-26 17:37)[/b]&nbsp;'
      expect(stripCommentReplyHeader(headerWithNbsp)).assertEqual(headerWithNbsp)

      /* 有正文时仍正常剥头（回归保护） */
      const withBody: string =
        '[b]Reply to [pid=1,2,3]Reply[/pid] Post by [uid=9]甲[/uid] (2025-05-26 17:37)[/b]<br/>评论正文'
      expect(stripCommentReplyHeader(withBody)).assertEqual('<br/>评论正文')
    })

    it('leavesCommentsOutOfQuoteInjection', 0, (): void => {
      /**
       * 评论气泡始终过滤 [quote]：对评论做引用注入只会把 Reply-to 头改写成隐藏的
       * [quote] 块，让「只有回复头」的评论失去唯一的可见文字（空气泡）。
       * 楼层仍需注入（列表页显示引用块）。
       */
      const header: string =
        '[b]Reply to [pid=900,47475364,1]Reply[/pid] Post by [uid=9]乙[/uid] (2025-05-26 17:37)[/b]'
      const comment: PostInfo = makePost(901, 1, header)
      const floorContent: string =
        '[b]Reply to [pid=900,47475364,1]Reply[/pid] Post by [uid=9]甲[/uid] (2025-05-26 17:37)[/b]<br/>楼层正文'
      const floor: PostInfo = makePost(902, 1, floorContent)
      const target: PostInfo = makePost(900, 0, '被引用楼层正文')
      floor.comments = [comment]
      const posts: PostInfo[] = [floor, target]

      injectQuoteContent(posts, posts)

      /** 评论正文不得被改写成 [quote] */
      expect(comment.content).assertEqual(header)
      /** 楼层仍正常注入（转成 [quote] 块并填入被引用正文） */
      expect(floor.content.startsWith('[quote][pid=900,47475364,1]Reply[/pid]')).assertTrue()
      expect(floor.content.includes('被引用楼层正文')).assertTrue()
    })
  })
}
