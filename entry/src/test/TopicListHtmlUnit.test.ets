import { describe, expect, it } from '@ohos/hypium'
import { parseHtmlTopicListToRawJson } from '../main/ets/parser/nga/html-topiclist/index'

/**
 * thread.php 主题列表 HTML 降级解析器（html-topiclist 镜像）单元测试。
 *
 * 覆盖降级通道的核心契约（输入为服务端渲染的静态 HTML 片段，输出与
 * thread.php JSON API 同形状的 { data: { __T, __F, __ROWS, __T__ROWS_PAGE, __PAGE } }）：
 * - 发帖记录行：topicArg.add 元数据 + DOM 展示字段 + 版块标记 + 分页估计
 * - 回帖记录行：__P 组装（pid / 回复正文 <br/> 保留 / 回复者 uid）
 * - 无版块标记行（如「超过限制」条目）：parent 与 JSON 一致为空串
 */
export default function topicListHtmlUnitTest(): void {
  describe('htmlTopicListParsing', (): void => {
    it('parsesTopicRowMetadataAndParent', 0, (): void => {
      const html: string =
        "<table id='topicrows'><tbody>" +
        "<tr class='row1 topicrow'>" +
        "<td class='c1'><a id='t_rc1_0' href='/read.php?tid=44627932' class='replies'>94</a></td>" +
        "<td class='c2'>" +
        "<a href='/read.php?tid=44627932' id='t_tt1_0' class='topic'>天然/合成橡胶 每日资讯分享</a>" +
        "<span id='t_pc1_0'></span><span class='titleadd2'>" +
        "<a href='/thread.php?stid=44618580' class='silver'>[期货交易]</a></span>" +
        "</td>" +
        "<td class='c3'>" +
        "<a href='/nuke.php?func=ucp&uid=205511' class='author' id='t_ta1_0' title='用户ID 205511'>gerraerd</a>" +
        "<span class='silver postdate' id='t_pt1_0'>1752714880</span>" +
        "</td>" +
        "<td class='c4'>" +
        "<a href='/read.php?tid=44627932&page=e' class='silver replydate' id='t_rt1_0'></a>" +
        "<span class='replyer' id='t_tr1_0'>20多岁还没去过火葬场</span>" +
        "</td>" +
        "</tr></tbody>" +
        "<script type='text/javascript'>commonui.topicArg.add(" +
        "'t_rc1_0','t_tt1_0','t_ta1_0','t_pt1_0','t_tr1_0','t_rt1_0','t_pc1_0'," +
        "'781',44627932,'','','0',1752714880,1786686937,94,65536,'AgKo01Q','',null,'',null,'','')" +
        "</script></table>" +
        "<script>var __PAGE = {0:'/thread.php?authorid=205511&fid=0',1:2,2:1,3:35};</script>"

      const raw: Object = parseHtmlTopicListToRawJson(html)
      const data: Record<string, Object> = (raw as Record<string, Object>)['data'] as Record<string, Object>
      const t: Record<string, Object> = data['__T'] as Record<string, Object>
      const keys: string[] = Object.keys(t)

      expect(keys.length).assertEqual(1)
      const entry: Record<string, Object> = t['0'] as Record<string, Object>
      expect(String(entry['tid'])).assertEqual('44627932')
      expect(String(entry['fid'])).assertEqual('781')
      expect(String(entry['subject'])).assertEqual('天然/合成橡胶 每日资讯分享')
      expect(String(entry['author'])).assertEqual('gerraerd')
      expect(String(entry['authorid'])).assertEqual('205511')
      expect(String(entry['postdate'])).assertEqual('1752714880')
      expect(String(entry['lastpost'])).assertEqual('1786686937')
      expect(String(entry['replies'])).assertEqual('94')
      expect(String(entry['lastposter'])).assertEqual('20多岁还没去过火葬场')
      expect(String(entry['type'])).assertEqual('65536')
      expect(String(entry['topic_misc'])).assertEqual('AgKo01Q')

      const parent: Record<string, Object> = entry['parent'] as Record<string, Object>
      expect(String(parent['0'])).assertEqual('781')
      expect(String(parent['1'])).assertEqual('44618580')
      expect(String(parent['2'])).assertEqual('期货交易')

      /* __PAGE 总页数 2 × 每页行数 35 → __ROWS 估计 70 */
      expect(String(data['__ROWS'])).assertEqual('70')
      expect(String(data['__T__ROWS_PAGE'])).assertEqual('35')
      expect(String(data['__PAGE'])).assertEqual('1')
    })

    it('parsesReplyRowPostAndContent', 0, (): void => {
      const html: string =
        "<table id='topicrows'><tbody>" +
        "<tr class='row1 topicrow'>" +
        "<td class='c1'><a id='t_rc1_0' href='/read.php?tid=44627932' class='replies'>94</a></td>" +
        "<td class='c2'>" +
        "<a href='/read.php?tid=44627932' id='t_tt1_0' class='topic'>天然/合成橡胶 每日资讯分享</a>" +
        "<span id='t_pc1_0'></span><span class='titleadd2'>" +
        "<a href='/thread.php?stid=44618580' class='silver'>[期货交易]</a></span>" +
        "<div class=\"topic_content\"><span class='silver'>[</span>" +
        "<a href='/read.php?tid=44627932&pid=878386616'>在主题中的回复</a><span class='silver'>]</span>" +
        "<div class='postcontent subtxt_color'>" +
        "<span id='postsubject44627932_878386616' class='b'></span><br/>" +
        "<span id='postcontent44627932_878386616'>[b]8.14 顺丁橡胶市场早间提示[/b]<br/><br/>1、内容</span>" +
        "</div></div></td>" +
        "<td class='c3'>" +
        "<a href='/nuke.php?func=ucp&uid=205511' class='author' id='t_ta1_0' title='用户ID 205511'>gerraerd</a>" +
        "<span class='silver postdate' id='t_pt1_0'>1752714880</span>" +
        "</td>" +
        "<td class='c4'><span class='replyer' id='t_tr1_0'>gerraerd</span></td>" +
        "</tr></tbody>" +
        "<script type='text/javascript'>commonui.topicArg.add(" +
        "'t_rc1_0','t_tt1_0','t_ta1_0','t_pt1_0','t_tr1_0','t_rt1_0','t_pc1_0'," +
        "'781',44627932,'878386616','','0',1752714880,1786686937,94,65536,'AgKo01Q','',null,'',null,'','')" +
        "</script>" +
        "<script type='text/javascript'>commonui.postDispMini(" +
        "$('postsubject44627932_878386616'),$('postcontent44627932_878386616'),0,44627932,878386616,205511,0)" +
        "</script></table>"

      const raw: Object = parseHtmlTopicListToRawJson(html)
      const data: Record<string, Object> = (raw as Record<string, Object>)['data'] as Record<string, Object>
      const t: Record<string, Object> = data['__T'] as Record<string, Object>
      const entry: Record<string, Object> = t['0'] as Record<string, Object>

      expect(String(entry['tid'])).assertEqual('44627932')
      expect(String(entry['replies'])).assertEqual('94')

      /* 回帖模式：__P 完整组装，正文中的 <br/> 保留为文本（与 JSON content 同形） */
      const p: Record<string, Object> = entry['__P'] as Record<string, Object>
      expect(p !== undefined).assertTrue()
      expect(String(p['tid'])).assertEqual('44627932')
      expect(String(p['pid'])).assertEqual('878386616')
      expect(String(p['authorid'])).assertEqual('205511')
      expect(String(p['subject'])).assertEqual('')
      expect(String(p['content'])).assertEqual('[b]8.14 顺丁橡胶市场早间提示[/b]<br/><br/>1、内容')
    })

    it('leavesPlaceholderRowParentEmpty', 0, (): void => {
      /* 「帖子发布或回复时间超过限制」行：无 titleadd2、作者 uid=0，parent 与 JSON 一致为空串 */
      const html: string =
        "<table id='topicrows'><tbody>" +
        "<tr class='row2 topicrow'>" +
        "<td class='c1'><a id='t_rc1_0' href='/read.php?tid=44625486' class='replies'>0</a></td>" +
        "<td class='c2'>" +
        "<a href='/read.php?tid=44625486' id='t_tt1_0' class='topic'>" +
        "<span class='silver b'>帖子发布或回复时间超过限制</span></a>" +
        "<span id='t_pc1_0'></span>" +
        "</td>" +
        "<td class='c3'>" +
        "<a href='/nuke.php?func=ucp&uid=0' class='author' id='t_ta1_0' title='用户ID 0'></a>" +
        "<span class='silver postdate' id='t_pt1_0'>0</span>" +
        "</td>" +
        "<td class='c4'><a href='/read.php?tid=44625486&page=e' class='silver replydate' id='t_rt1_0'></a>" +
        "<span class='replyer' id='t_tr1_0'></span></td>" +
        "</tr></tbody>" +
        "<script type='text/javascript'>commonui.topicArg.add(" +
        "'t_rc1_0','t_tt1_0','t_ta1_0','t_pt1_0','t_tr1_0','t_rt1_0','t_pc1_0'," +
        "'-7',44625486,'','','0',0,0,0,65536,'AgKo01Q','',null,'',null,'','')" +
        "</script></table>"

      const raw: Object = parseHtmlTopicListToRawJson(html)
      const data: Record<string, Object> = (raw as Record<string, Object>)['data'] as Record<string, Object>
      const t: Record<string, Object> = data['__T'] as Record<string, Object>
      const entry: Record<string, Object> = t['0'] as Record<string, Object>

      expect(String(entry['tid'])).assertEqual('44625486')
      expect(String(entry['authorid'])).assertEqual('0')
      expect(String(entry['subject'])).assertEqual('帖子发布或回复时间超过限制')
      expect(String(entry['parent'])).assertEqual('')
      /* 无 __P：发帖模式不携带回复对象 */
      expect(entry['__P'] === undefined).assertTrue()
    })
  })
}
