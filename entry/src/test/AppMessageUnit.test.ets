import { describe, expect, it } from '@ohos/hypium'
import {
  extractAppMessageError,
  normalizeAppMessageContent,
  parseAppMessageList,
  parseAppMessageDetail,
} from '../main/ets/parser/AppMessageParser'
import type {
  MessageListInfo,
  MessageDetailInfo,
  MessageThreadInfo,
  MessageArticle,
} from '../main/ets/model/Message'

/**
 * 官方 APP 私信接口解析器单元测试。
 * fixtures 形状来自 ngabbs.com 官方签名接口（app_api.php message/list|detail，
 * POST+sign，__output=12）实测样本（字段值已替换为合成数据）。
 */
export default function appMessageUnitTest(): void {
  describe('appMessageListParser', (): void => {
    it('parsesAppMessageListFields', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"msg":"操作成功","result":[' +
          '{"did":3405931,"bit":8,"subject":"你完成了任务 每日签到得N币",' +
          '"from_uid":0,"from_username":"","addTime":1631062273,"posts_num":389,' +
          '"last_modify":1777225492,"last_from":0,"last_from_username":""},' +
          '{"did":1234567,"bit":0,"subject":"你好",' +
          '"from_uid":1001,"from_username":"测试用户甲","addTime":1777000000,"posts_num":3,' +
          '"last_modify":1777000123,"last_from":1001,"last_from_username":"测试用户甲"}' +
          '],"currentPage":1,"nextPage":false,"perPage":35}')
      const info: MessageListInfo | null = parseAppMessageList(raw, 1)
      expect(info !== null).assertTrue()
      if (info === null) return
      expect(info.messageEntryList.length).assertEqual(2)
      // 系统消息（from_uid=0）字段映射：did→mid、addTime→time、last_modify→lasttime、posts_num→posts
      const sys: MessageThreadInfo = info.messageEntryList[0]
      expect(sys.mid).assertEqual(3405931)
      expect(sys.subject).assertEqual('你完成了任务 每日签到得N币')
      expect(sys.time).assertEqual('1631062273')
      expect(sys.lasttime).assertEqual('1777225492')
      expect(sys.posts).assertEqual(389)
      expect(sys.from_username).assertEqual('')
      expect(sys.last_from_username).assertEqual('')
      // 普通会话
      const normal: MessageThreadInfo = info.messageEntryList[1]
      expect(normal.mid).assertEqual(1234567)
      expect(normal.from_username).assertEqual('测试用户甲')
      expect(normal.last_from_username).assertEqual('测试用户甲')
      // 顶层分页字段：currentPage/perPage/nextPage(false → 0)
      expect(info.rowsPerPage).assertEqual(35)
      expect(info.currentPage).assertEqual(1)
      expect(info.nextPage).assertEqual(0)
    })

    it('parsesNextPageFlagAsPagePlusOne', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":[{"did":11,"subject":"a","posts_num":1}],' +
          '"currentPage":2,"nextPage":true,"perPage":35}')
      const info: MessageListInfo | null = parseAppMessageList(raw, 2)
      expect(info !== null).assertTrue()
      if (info === null) return
      expect(info.currentPage).assertEqual(2)
      expect(info.nextPage).assertEqual(3)
      expect(info.messageEntryList.length).assertEqual(1)
      expect(info.messageEntryList[0].mid).assertEqual(11)
    })

    it('returnsEmptyListForEmptyResult', 0, (): void => {
      const raw: object = JSON.parse('{"code":0,"msg":"操作成功","result":[]}')
      const info: MessageListInfo | null = parseAppMessageList(raw, 2)
      expect(info !== null).assertTrue()
      if (info === null) return
      expect(info.messageEntryList.length).assertEqual(0)
      // 空页无 nextPage 字段 → nextPage=0
      expect(info.nextPage).assertEqual(0)
      // currentPage 缺失时以请求页码兜底
      expect(info.currentPage).assertEqual(2)
    })

    it('returnsNullForBusinessFailure', 0, (): void => {
      const raw: object = JSON.parse('{"code":4,"msg":"参数错误","result":[]}')
      expect(parseAppMessageList(raw, 1)).assertNull()
    })

    it('returnsNullForUnrecognizedResultShape', 0, (): void => {
      const raw: object = JSON.parse('{"code":0,"result":{"data":[]}}')
      expect(parseAppMessageList(raw, 1)).assertNull()
    })

    it('skipsEntryWithoutDid', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":[' +
          '{"subject":"无did条目"},' +
          '{"did":42,"subject":"正常条目","posts_num":2}' +
          ']}')
      const info: MessageListInfo | null = parseAppMessageList(raw, 1)
      expect(info !== null).assertTrue()
      if (info === null) return
      expect(info.messageEntryList.length).assertEqual(1)
      expect(info.messageEntryList[0].mid).assertEqual(42)
    })
  })

  describe('appMessageDetailParser', (): void => {
    it('parsesAppMessageDetailFields', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"msg":"操作成功","result":[' +
          '{"id":253649708,"subject":"你好",' +
          '"content":"第一行<br/>[quote]引用内容<br/><br/>[/quote]<br/>结束",' +
          '"addTime":1777225492,"user":{"uid":1001,"username":"测试用户甲"}}' +
          ']}')
      const info: MessageDetailInfo | null = parseAppMessageDetail(raw, 1)
      expect(info !== null).assertTrue()
      if (info === null) return
      expect(info.messageEntryList.length).assertEqual(1)
      const article: MessageArticle = info.messageEntryList[0]
      expect(article.subject).assertEqual('你好')
      // <br> 系列换行标签转 \n，其余（BBCode）原样保留
      expect(article.content).assertEqual('第一行\n[quote]引用内容\n\n[/quote]\n结束')
      expect(article.time).assertEqual('1777225492')
      // 官方 id 透传（列表 key 唯一标识）、user.uid 透传（自己/对方判断）
      expect(article.id).assertEqual('253649708')
      expect(article.uid).assertEqual('1001')
      // author/from 均取 user.username；无网页版字段置空
      expect(article.author).assertEqual('测试用户甲')
      expect(article.from).assertEqual('测试用户甲')
      expect(article.formated_html_data).assertEqual('')
      expect(article.mute_time).assertEqual('')
      // 标题以首条消息 subject 兜底
      expect(info.title).assertEqual('你好')
      expect(info.currentPage).assertEqual(1)
      expect(info.nextPage).assertEqual(0)
    })

    it('parsesDetailNextPageAsPagePlusOne', 0, (): void => {
      // 官方响应顶层 nextPage 为 bool：true 表示还有更早消息 → 下一页=currentPage+1
      const raw: object = JSON.parse(
        '{"code":0,"result":[' +
          '{"id":11,"subject":"a","content":"c","addTime":1787000000,"user":{"uid":0,"username":"#SYSTEM#"}}' +
          '],"currentPage":2,"nextPage":true}')
      const info: MessageDetailInfo | null = parseAppMessageDetail(raw, 2)
      expect(info !== null).assertTrue()
      if (info === null) return
      expect(info.currentPage).assertEqual(2)
      expect(info.nextPage).assertEqual(3)
      expect(info.messageEntryList.length).assertEqual(1)
      expect(info.messageEntryList[0].id).assertEqual('11')
      expect(info.messageEntryList[0].uid).assertEqual('0')
    })

    it('returnsEmptyListForEmptyResult', 0, (): void => {
      const raw: object = JSON.parse('{"code":0,"msg":"操作成功","result":[]}')
      const info: MessageDetailInfo | null = parseAppMessageDetail(raw, 1)
      expect(info !== null).assertTrue()
      if (info === null) return
      expect(info.messageEntryList.length).assertEqual(0)
      expect(info.title).assertEqual('')
    })

    it('returnsNullForBusinessFailure', 0, (): void => {
      const raw: object = JSON.parse('{"code":4,"msg":"参数错误","result":[]}')
      expect(parseAppMessageDetail(raw, 1)).assertNull()
    })

    it('returnsNullForUnrecognizedResultShape', 0, (): void => {
      const raw: object = JSON.parse('{"code":0,"result":{}}')
      expect(parseAppMessageDetail(raw, 1)).assertNull()
    })

    it('keepsContentWithoutBrTagsUnchanged', 0, (): void => {
      expect(normalizeAppMessageContent('纯文本 [b]加粗[/b] &amp; 实体')).assertEqual(
        '纯文本 [b]加粗[/b] &amp; 实体')
      expect(normalizeAppMessageContent('a<br>b<br/>c<br />d<BR>e')).assertEqual('a\nb\nc\nd\ne')
    })

    it('stripsOtherHtmlTagsFromContent', 0, (): void => {
      // 官方 content 为 HTML+BBCode 混合：<br> 转 \n，其余标签整体剥离（对齐 ShareUtils 范式）
      expect(normalizeAppMessageContent(
        '正文<img src="https://x/a.jpg" alt="图"><a href="https://y">链接</a>尾部'))
        .assertEqual('正文链接尾部')
    })

    it('fallsBackEmptyUsernameWhenUserMissingOrInvalid', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":[' +
          '{"id":1,"subject":"无user","content":"c1","addTime":1787000000},' +
          '{"id":2,"subject":"null user","content":"c2","addTime":1787000001,"user":null},' +
          '{"id":3,"subject":"字符串user","content":"c3","addTime":1787000002,"user":"str"}' +
          ']}')
      const info: MessageDetailInfo | null = parseAppMessageDetail(raw, 1)
      expect(info !== null).assertTrue()
      if (info === null) return
      expect(info.messageEntryList.length).assertEqual(3)
      expect(info.messageEntryList[0].author).assertEqual('')
      expect(info.messageEntryList[1].author).assertEqual('')
      expect(info.messageEntryList[2].author).assertEqual('')
    })

    it('skipsEntryWithoutIdInDetail', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":[' +
          '{"subject":"无id"},' +
          '{"id":0,"subject":"零id"},' +
          '{"id":9,"subject":"正常","content":"x","addTime":1787000000}' +
          ']}')
      const info: MessageDetailInfo | null = parseAppMessageDetail(raw, 1)
      expect(info !== null).assertTrue()
      if (info === null) return
      expect(info.messageEntryList.length).assertEqual(1)
      expect(info.messageEntryList[0].subject).assertEqual('正常')
      expect(info.title).assertEqual('正常')
    })

    it('returnsNullForNullResult', 0, (): void => {
      const raw: object = JSON.parse('{"code":0,"result":null}')
      expect(parseAppMessageDetail(raw, 1)).assertNull()
      expect(parseAppMessageList(raw, 1)).assertNull()
    })
  })

  describe('appMessageErrorExtractor', (): void => {
    it('extractsMsgForNonZeroCode', 0, (): void => {
      const raw: object = JSON.parse('{"code":4,"msg":"参数错误","result":[]}')
      expect(extractAppMessageError(raw)).assertEqual('参数错误')
    })

    it('returnsNullForSuccess', 0, (): void => {
      const raw: object = JSON.parse('{"code":0,"msg":"操作成功","result":[]}')
      expect(extractAppMessageError(raw)).assertNull()
    })

    it('fallsBackToCodeWhenMsgMissing', 0, (): void => {
      const raw: object = JSON.parse('{"code":9}')
      expect(extractAppMessageError(raw)).assertEqual('错误码: 9')
    })
  })
}
