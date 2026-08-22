import { describe, it, expect } from '@ohos/hypium'
import { parseThreadData } from '../main/ets/parser/ThreadParser'
import { parseNgaError } from '../main/ets/parser/ErrorParser'
import { extractAppArticleHtml } from '../main/ets/service/api/ThreadApi'
import type { ThreadRowInfo } from '../main/ets/model/Thread'

/**
 * 构造官方 APP 签名通道 read.php（POST form + __output=11）的结构化响应。
 *
 * 形状与实测样本（ngabbs.com read.php?tid=44191387，__output=11）一致：
 * - 顶层 {data, time}，无 code/msg（成功态）
 * - data 含 __CU/__GLOBAL/__U/__R/__T/__F/__R__ROWS/__R__ROWS_PAGE/__ROWS/__PAGE
 * - __R 为楼层数组（含主楼 lou=0），贴条以 comment 数组内嵌在宿主楼层
 * - 楼层 attachs 可为 null 或缺失（主楼无该键，回复楼为 null）；__U 用户
 *   mute_time/signature 可为 null
 *
 * @returns 官方通道响应对象
 */
function createOfficialReadResponse(): object {
  return JSON.parse(
    '{"data":{' +
      '"__CU":{"uid":42023922,"group_bit":98528,"admincheck":false,"rvrc":10},' +
      '"__GLOBAL":{"_ATTACH_BASE_VIEW":"img.nga.cn/attachments"},' +
      '"__U":{"205511":{"uid":205511,"username":"gerraerd","credit":169157220,' +
        '"medal":"101,45,442","groupid":5,"memberid":5,' +
        '"avatar":"https://img.nga.cn/avatars/2002/2c7/032/000/205511_0.jpg?89",' +
        '"yz":4,"honor":" 1781139315 汪汪汪","regdate":1133203527,"mute_time":null,' +
        '"postnum":493,"rvrc":10,"money":37981,"thisvisit":1787273030,' +
        '"signature":null,"bit_data":169157220},' +
        '"42384794":{"uid":42384794,"username":"铜镜印无邪","credit":135668224,' +
        '"groupid":-1,"memberid":39,' +
        '"avatar":"https://img.nga.cn/avatars/2002/d9a/86b/002/42384794_0.jpg?53",' +
        '"yz":4,"regdate":1511949245,"mute_time":null,"postnum":551,"rvrc":10,' +
        '"money":28300,"thisvisit":1787222979,"signature":"父母安在，老婆温柔",' +
        '"bit_data":135668224}},' +
      '"__R":[' +
        '{"pid":0,"fid":-7,"tid":44191387,"authorid":205511,"type":33554432,' +
          '"score":0,"score_2":0,"recommend":10,"postdate":"2025-05-26 17:27",' +
          '"subject":"iOS客户端闪退问题，请下载恩基爱社区app。",' +
          '"alterinfo":"[E1748252294 0 0]\\t",' +
          '"content":"[del]别骂了别骂了[/del]<br/>原客户端 NGA玩家社区 停止更新已久。",' +
          '"lou":0,"content_length":209,"follow":0,"from_client":"7 iOS",' +
          '"postdatetimestamp":1748251672},' +
        '{"pid":824920438,"fid":-7,"tid":44191387,"authorid":42384794,"type":0,' +
          '"score":95,"score_2":0,"recommend":0,"postdate":"2025-05-26 17:32",' +
          '"subject":"","alterinfo":"","content":"安卓版还没做好吗","lou":1,' +
          '"content_length":16,"from_client":"8 Android","postdatetimestamp":1748251933,' +
          '"attachs":null},' +
        '{"pid":824921217,"fid":-7,"tid":44191387,"authorid":360579,"type":8196,' +
          '"score":9,"score_2":0,"recommend":0,"postdate":"2025-05-26 17:37",' +
          '"subject":"","alterinfo":"",' +
          '"content":"[noimg]./-7Qbvwn-dj7mK2bT1kShs-13i.jpg[/noimg]<br/><br/>是这个吗？",' +
          '"lou":4,"content_length":51,"attachs":null,"comment_id":["824921555"],' +
          '"from_client":"8 Android","postdatetimestamp":1748252240,' +
          '"comment":[{"pid":824921555,"fid":-7,"tid":44191387,"authorid":205511,"type":1,' +
            '"score":0,"score_2":0,"recommend":0,"postdate":"2025-05-26 17:39",' +
            '"subject":"","alterinfo":"",' +
            '"content":"[b]Reply to [pid=824921217,44191387,1]Reply[/pid] Post by ' +
            '[uid=360579]迷惘中的骑士[/uid][/b]<br/><br/>不是啦",' +
            '"lou":7,"content_length":53,"comment_to_id":824921217,' +
            '"from_client":"7 iOS","reply_to":824921217,"postdatetimestamp":1748252378}]}' +
      '],' +
      '"__T":{"fid":-7,"tid":44191387,"topic_misc":"AQAAACE",' +
        '"subject":"iOS客户端闪退问题，请下载恩基爱社区app。","locked":0,"recommend":10,' +
        '"type":0,"replies":539,"authorid":205511,"postdate":1748251672,' +
        '"lastpost":1786923606,"author":"gerraerd","lastposter":"喇多","digest":0,' +
        '"lastmodify":1787288690,"tpid":0,"topic_misc_var":{"1":33},' +
        '"post_misc_var":{"content_length":209,"fid":-7}},' +
      '"__F":{"custom_level":"[{r:-21000,n:\\"泡沫\\"},{r:0,n:\\"镜花水月\\"}]",' +
        '"name":"网事杂谈"},' +
      '"__PAGE":1,"__ROWS":540,"__R__ROWS":19,"__R__ROWS_PAGE":20},' +
      '"time":1787323566}')
}

/**
 * 注册 Thread 官方 APP 签名通道（read.php __output=11）单元测试。
 */
export default function appThreadUnitTest(): void {
  describe('appThreadOfficialChannel', (): void => {
    it('extractsOfficialHtmlArticleEnvelope', 0, (): void => {
      const response: object = JSON.parse(
        '{"code":521,"htmlBaseUrl":"https://ngabbs.com/","htmlTitle":"帖子",' +
          '"html":"<!--postliststart--><div>帖子内容</div>",' +
          '"msg":"","template":"read"}')
      expect(extractAppArticleHtml(response)).assertEqual(
        '<!--postliststart--><div>帖子内容</div>')
    })

    it('parsesOfficialReadArrayShape', 0, (): void => {
      const result = parseThreadData(createOfficialReadResponse())
      // 官方 __R 为数组：主楼 + 普通回复 + 贴条宿主行均解析为楼层
      expect(result.rowList.length).assertEqual(3)
      const main: ThreadRowInfo = result.rowList[0]
      expect(main.pid).assertEqual(0)
      expect(main.lou).assertEqual(0)
      expect(main.authorid).assertEqual(205511)
      expect(main.content).assertEqual('[del]别骂了别骂了[/del]<br/>原客户端 NGA玩家社区 停止更新已久。')
      expect(main.postdate).assertEqual('2025-05-26 17:27')
      expect(main.postdatetimestamp).assertEqual(1748251672)
      expect(main.from_client).assertEqual('7 iOS')
      // 主楼无 attachs 键 → 空数组
      expect(main.attachs.length).assertEqual(0)

      const reply: ThreadRowInfo = result.rowList[1]
      expect(reply.pid).assertEqual(824920438)
      expect(reply.lou).assertEqual(1)
      // attachs=null 安全降级为空数组
      expect(reply.attachs.length).assertEqual(0)
      expect(reply.content).assertEqual('安卓版还没做好吗')
    })

    it('parsesOfficialTieTiaoCommentInline', 0, (): void => {
      const result = parseThreadData(createOfficialReadResponse())
      const host: ThreadRowInfo = result.rowList[2]
      expect(host.pid).assertEqual(824921217)
      expect(host.lou).assertEqual(4)
      expect(host.comments.length).assertEqual(1)
      const comment: ThreadRowInfo = host.comments[0]
      expect(comment.pid).assertEqual(824921555)
      expect(comment.authorid).assertEqual(205511)
      expect(comment.lou).assertEqual(7)
      expect(comment.content.includes('[b]Reply to')).assertTrue()
      // 贴条元素为叶子：不携带嵌套评论
      expect(host.comments[0].comments.length).assertEqual(0)
      expect(host.comments[0].attachs.length).assertEqual(0)
    })

    it('parsesOfficialPaginationAndForum', 0, (): void => {
      const result = parseThreadData(createOfficialReadResponse())
      // __ROWS=540、__R__ROWS_PAGE=20 → 27 页
      expect(result.__ROWS).assertEqual(540)
      expect(result.pagination.totalRows).assertEqual(540)
      expect(result.pagination.totalPages).assertEqual(27)
      // __F 透传（fillThreadResult 从中取 forumName）
      const forum: Record<string, string> = result.__F
      expect(forum['name']).assertEqual('网事杂谈')
    })

    it('parseNgaErrorHandlesOfficialErrorArray', 0, (): void => {
      // 官方通道业务错误：{"error":["2048:找不到主题",null,null],"data":{"__MESSAGE":...}}
      const notFound: object = JSON.parse(
        '{"error":["2048:找不到主题",null,null],"data":{"__MESSAGE":"找不到主题"},"time":1787323566}')
      expect(parseNgaError(notFound)).assertEqual('2048:找不到主题')
      // 未登录（HTTP 403 body）：error[0]="1:未登录"，error[1] 为登录链接 HTML
      const notLoggedIn: object = JSON.parse(
        '{"error":["1:未登录","<br/><a href=/nuke.php?__lib=login&__act=account&login>[登录]</a>",null],' +
          '"data":{"__MESSAGE":"未登录"}}')
      expect(parseNgaError(notLoggedIn)).assertEqual('1:未登录')
      // 成功形状无 error 键 → null
      expect(parseNgaError(createOfficialReadResponse())).assertNull()
    })
  })
}
