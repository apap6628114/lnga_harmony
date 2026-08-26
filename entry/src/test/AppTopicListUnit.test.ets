import { describe, it, expect } from '@ohos/hypium'
import {
  extractSubjectListError,
  parseSubjectList,
  parseSubjectSubBoards,
  parseToppedList,
  parseHotSubjectList,
  convertTitleFontApi,
} from '../main/ets/parser/AppSubjectListParser'
import { parseForumCategories, parseForumSearch } from '../main/ets/parser/ForumParser'
import {
  buildSubjectQuery,
  buildSubjectSignParams,
  buildToppedQuery,
  buildToppedSignParams,
  buildHotQuery,
  buildHotSignParams,
  buildSubscriptionFields,
  buildSubscriptionSignParams,
  buildSubscriptionType,
  normalizeSubjectFid,
} from '../main/ets/common/utils/SubjectListQuery'
import { getHotDays } from '../main/ets/common/utils/TopicListUtils'
import type { TopicListInfo } from '../main/ets/model/Topic'
import type { SubBoard, Category, ForumSearchItem } from '../main/ets/model/Forum'
import type { TopicListParams } from '../main/ets/service/api/ForumApi'

/**
 * 构造官方 subject/list 主题列表响应（实测形状，nga-hack 探测 fid=7）。
 *
 * result.data 主题数组 + result.subForum 子版块数组（位置字段+命名键双格式），
 * 分页字段在响应顶层，forumname 在顶层。
 *
 * @returns 官方响应
 */
function createSubjectListResponse(): Record<string, Object> {
  const attachObj: Record<string, Object> = {
    'attachurl': 'mon_202608/19/7Q68-jpq0ZtT3cS1uo-11i.jpeg',
  }
  const attachs: Object[] = [attachObj]
  const fontApi: Record<string, Object> = {
    'color': 'orange',
    'bold': true,
    'italic': false,
    'underline': false,
  }
  const topic1: Record<string, Object> = {
    'tid': 47344551,
    'fid': 7,
    'author': '皮纳特丶',
    'authorid': 64371487,
    'subject': '[战报帖]乌拉特克的诅咒首杀争霸赛',
    'postdate': 1786338953,
    'lastpost': 1787343739,
    'lastposter': 'IceLibra',
    'replies': 504,
    'type': 73732,
    'attachs': attachs,
    'titlefont_api': fontApi,
    'style': 1,
    'topic_misc_var_bit1': 67108904,
    'set_elm_parent': 47344543,
    'is_set_elm': true,
    'forumname': '乌拉特克的诅咒：烈毒之渊首杀合集',
  }
  const topic2: Record<string, Object> = {
    'tid': 47344607,
    'fid': 7,
    'author': '#anony_38ac8d5e60bda0f1f0a0f2a0d0a0f1f',
    'authorid': 0,
    'subject': '匿名提问贴',
    'type': 0,
    'postdate': 1786340000,
    'lastpost': 1787340000,
    'lastposter': '路人甲',
    'replies': 3,
  }
  const dataArr: Object[] = [topic1, topic2]
  const sub1: Record<string, Object> = {
    '0': 255,
    '1': '团队管理经验交流',
    '2': '管理经验交流',
    '3': 14673796,
    '4': 2606,
    'id': 255,
    'name': '团队管理经验交流',
    'info': '管理经验交流',
    'checked': 1,
    'allow_checked': 1,
    'sub_type': 2606,
    'tid': 14673796,
  }
  const sub2: Record<string, Object> = {
    '0': 533,
    '1': '大秘境集合石',
    '2': '',
    '3': 9810209,
    '4': 296,
    'id': 533,
    'name': '大秘境集合石',
    'info': '',
    'checked': 0,
    'allow_checked': 0,
    'sub_type': 296,
    'tid': 9810209,
  }
  const sub3: Record<string, Object> = {
    '0': 47344543,
    '1': '乌拉特克的诅咒：烈毒之渊首杀合集',
    '2': '',
    '3': 47344543,
    '4': 542,
    'id': 47344543,
    'name': '乌拉特克的诅咒：烈毒之渊首杀合集',
    'info': '',
    'checked': 1,
    'allow_checked': 1,
    'sub_type': 542,
    'tid': 47344543,
    'is_set': 1,
  }
  const subArr: Object[] = [sub1, sub2, sub3]
  const header: Record<string, Object> = {
    'title': '艾泽拉斯议事厅',
    'opentype': 2,
    'opendata': '35730796',
  }
  const result: Record<string, Object> = {
    'attachPrefix': 'https://img.nga.cn/attachments/',
    'subForum': subArr,
    'topic_key': '',
    'sessionPrivilege': '',
    'data': dataArr,
    'unionforum_ary_all': [],
    'header': header,
  }
  const response: Record<string, Object> = {
    'code': 0,
    'msg': '操作成功',
    'result': result,
    'totalPage': 106923,
    'total': 3742292,
    'currentPage': 1,
    'perPage': 35,
    'forumname': '艾泽拉斯议事厅 - Hall of Azeroth',
    'fid': 7,
    'bit_data': 134217832,
    '__CURRENT_ORDER': '',
  }
  return response
}

/**
 * 构造页面层主题列表参数（全字段默认值）。
 *
 * @returns 主题列表参数
 */
function createParams(): TopicListParams {
  return {
    fid: '', stid: '', page: '1', key: '', author: '', authorid: '',
    favor: '', recommend: '', orderBy: '', searchpost: '', content: '', fidgroup: '',
    topped: '', hotDays: '',
  }
}

/**
 * 构造官方 subject/topped 置顶列表响应（实测形状，nga-hack app-json 探测 fid=7）。
 *
 * {code, msg, result:{data:[...]}}——与 subject/list 同构但无 totalPage/
 * subForum 字段；服务端忽略 page 参数、恒返回全部置顶帖（实测 fid=7 共 18 条）。
 *
 * @returns 官方响应
 */
function createToppedListResponse(): Record<string, Object> {
  const topic1: Record<string, Object> = {
    'tid': 17326655,
    'fid': 7,
    'author': 'zeg',
    'authorid': 58,
    'subject': '[置顶]版头公告与版规',
    'postdate': 1500000000,
    'lastpost': 1787743598,
    'lastposter': 'zeg',
    'replies': 0,
    'type': 2097152,
    'forumname': '艾泽拉斯议事厅',
  }
  const topic2: Record<string, Object> = {
    'tid': 47344551,
    'fid': 7,
    'author': '皮纳特丶',
    'authorid': 64371487,
    'subject': '[置顶]开荒战报集合帖',
    'postdate': 1786338953,
    'lastpost': 1787343739,
    'lastposter': 'IceLibra',
    'replies': 504,
    'type': 73732,
    'forumname': '',
  }
  const result: Record<string, Object> = {
    'data': [topic1, topic2],
  }
  return {
    'code': 0,
    'msg': '操作成功',
    'result': result,
  }
}

/**
 * 构造官方 subject/hot 热帖列表响应（实测形状，nga-hack app-json 探测 fid=7 days=1）。
 *
 * {code, expire_at, attachPrefix, bit_data, result:[扁平主题数组]}——result
 * 直接是数组（与 subject/list 的 result.data 不同），无 msg/totalPage；
 * _page 参数被服务端忽略（实测 days=1 返回 32 条、days=7 返回 230 条、
 * days=30 返回 930 条完整热度榜）。
 *
 * @returns 官方响应
 */
function createHotSubjectListResponse(): Record<string, Object> {
  const topic1: Record<string, Object> = {
    'tid': 47442318,
    'fid': 7,
    'author': 'hiroqq',
    'authorid': 60884047,
    'subject': '商城新坐骑，有什么好说的，直接冲雷子就对了！',
    'postdate': 1787713440,
    'lastpost': 1787743350,
    'lastposter': '吹唢呐的猫7262',
    'replies': 170,
    'type': 8196,
    'forumname': '',
  }
  const topic2: Record<string, Object> = {
    'tid': 47442690,
    'fid': 7,
    'author': '测试用户',
    'authorid': 100,
    'subject': '[吐槽氵] 两天休闲团是怎么管理团队的',
    'postdate': 1787723936,
    'lastpost': 1787743606,
    'lastposter': '有时午夜有彩虹',
    'replies': 27,
    'type': 0,
    'forumname': '',
  }
  return {
    'expire_at': 1787747245,
    'attachPrefix': 'https://img.nga.cn/attachments/',
    'bit_data': 134217832,
    'code': 0,
    'result': [topic1, topic2],
  }
}

export default function appTopicListUnitTest(): void {
  describe('appTopicListUnitTest', () => {
    it('extractsBusinessError', 0, () => {
      expect(extractSubjectListError(createSubjectListResponse())).assertNull()
      const pageError: Record<string, Object> = {
        'code': 2048,
        'msg': '页面错误',
      }
      expect(extractSubjectListError(pageError)).assertEqual('页面错误')
      const rateLimited: Record<string, Object> = {
        'code': 15,
        'msg': '频率限制',
      }
      expect(extractSubjectListError(rateLimited)).assertEqual('频率限制')
      const signError: Record<string, Object> = {
        'code': 5,
        'msg': '签名错误',
      }
      expect(extractSubjectListError(signError)).assertEqual('签名错误')
      /* code!=0 且无 msg：回退「错误码: N」 */
      const noMsg: Record<string, Object> = {
        'code': 42,
      }
      expect(extractSubjectListError(noMsg)).assertEqual('错误码: 42')
      /* 形状不可识别（无 code）视为无业务错误 */
      const emptyResult: Record<string, Object> = {}
      const noCode: Record<string, Object> = {
        'result': emptyResult,
      }
      expect(extractSubjectListError(noCode)).assertNull()
      /* ngaRequest 对 HTTP 层 HTML 错误页的归一化形状：error 对象与 error_code 透传 */
      const errObj: Record<string, Object> = {
        '0': '页面被吃了',
      }
      const htmlErrorObj: Record<string, Object> = {
        'error': errObj,
      }
      expect(extractSubjectListError(htmlErrorObj)).assertEqual('页面被吃了')
      const htmlErrorCode: Record<string, Object> = {
        'error_code': 15,
      }
      expect(extractSubjectListError(htmlErrorCode)).assertEqual('频率限制')
    })

    it('parsesOfficialSubjectList', 0, () => {
      const info: TopicListInfo | null = parseSubjectList(
        createSubjectListResponse(), new Set<string>(), [], 1)
      expect(info).not().assertNull()
      const list = info as TopicListInfo
      /* result.data 逐条解析 */
      expect(list.threadPageList.length).assertEqual(2)
      const first = list.threadPageList[0]
      expect(first.tid).assertEqual(47344551)
      expect(first.fid).assertEqual(7)
      expect(first.author).assertEqual('皮纳特丶')
      expect(first.authorId).assertEqual(64371487)
      expect(first.replies).assertEqual(504)
      expect(first.subject).assertEqual('[战报帖]乌拉特克的诅咒首杀争霸赛')
      expect(first.lastPoster).assertEqual('IceLibra')
      expect(first.postDate).assertEqual(1786338953)
      expect(first.type).assertEqual(73732)
      /* forumname → parent['2'] → board（官方条目无 parent 字段） */
      expect(first.board).assertEqual('乌拉特克的诅咒：烈毒之渊首杀合集')
      /* titlefont_api 对象 → titlefont 位值（8 橙 + 32 粗 = 40） */
      expect(first.titleFont).assertEqual('40')
      /* 匿名条目：isAnonymity + 匿名名被解码为可读名（不再是 #anony_ 原文） */
      const second = list.threadPageList[1]
      expect(second.isAnonymity).assertTrue()
      expect(second.author).not().assertEqual('#anony_38ac8d5e60bda0f1f0a0f2a0d0a0f1f')
      /* 顶层 forumname → 版块名 */
      expect(list.name).assertEqual('艾泽拉斯议事厅 - Hall of Azeroth')
      /* subForum → subBoardList（账号级真实订阅状态） */
      expect(list.subBoardList.length).assertEqual(3)
      expect(list.subBoardList[0].fid).assertEqual(255)
      expect(list.subBoardList[0].checked).assertTrue()
      expect(list.subBoardList[1].checked).assertFalse()
      /* 分页：顶层 totalPage */
      expect(list.pagination.page).assertEqual(1)
      expect(list.pagination.totalRows).assertEqual(106923)
      expect(list.pagination.totalPages).assertEqual(106923)
    })

    it('parsesSubjectSubBoards', 0, () => {
      const res: Record<string, Object> = (createSubjectListResponse()['result']) as Record<string, Object>
      const subs: SubBoard[] = parseSubjectSubBoards(res)
      expect(subs.length).assertEqual(3)
      /* 常规子版块：checked=1 真实订阅状态、allow_checked=1 可屏蔽 */
      const first: SubBoard = subs[0]
      expect(first.fid).assertEqual(255)
      expect(first.name).assertEqual('团队管理经验交流')
      expect(first.description).assertEqual('管理经验交流')
      expect(first.tidStr).assertEqual('14673796')
      expect(first.filterId).assertEqual('14673796')
      expect(first.type).assertEqual(2606)
      expect(first.attributes).assertEqual(2606)
      expect(first.checked).assertTrue()
      expect(first.filterable).assertTrue()
      /* allow_checked=0：服务端已排除其主题混合，UI 禁用开关 */
      const blocked: SubBoard = subs[1]
      expect(blocked.fid).assertEqual(533)
      expect(blocked.checked).assertFalse()
      expect(blocked.filterable).assertFalse()
      /* 合集子版块（is_set=1）：checked=1 且可订阅 */
      const setSub: SubBoard = subs[2]
      expect(setSub.fid).assertEqual(47344543)
      expect(setSub.filterId).assertEqual('47344543')
      expect(setSub.checked).assertTrue()
      expect(setSub.filterable).assertTrue()
    })

    it('parsesEmptySubBoards', 0, () => {
      /* 搜索响应（subject/search）无 subForum → 空列表 */
      const emptyRes: Record<string, Object> = {
        'data': [],
      }
      const subs: SubBoard[] = parseSubjectSubBoards(emptyRes)
      expect(subs.length).assertEqual(0)
      /* result 缺失/非对象 */
      expect(parseSubjectSubBoards(undefined).length).assertEqual(0)
    })

    it('defaultsAllowCheckedToTrue', 0, () => {
      /* allow_checked 缺失时按可订阅处理（服务端常规子版块均显式返回） */
      const sub: Record<string, Object> = {
        '0': 42,
        '1': '缺 allow_checked',
        '3': 42,
        '4': 2606,
        'id': 42,
        'name': '缺 allow_checked',
        'checked': 1,
        'sub_type': 2606,
        'tid': 42,
      }
      const subArr: Object[] = [sub]
      const result: Record<string, Object> = {
        'subForum': subArr,
      }
      const subs: SubBoard[] = parseSubjectSubBoards(result)
      expect(subs.length).assertEqual(1)
      expect(subs[0].filterable).assertTrue()
    })

    it('convertsTitleFontApi', 0, () => {
      const orangeBold: Record<string, Object> = {
        'color': 'orange',
        'bold': true,
        'italic': false,
        'underline': false,
      }
      expect(convertTitleFontApi(orangeBold)).assertEqual('40')
      const redItalicUnderline: Record<string, Object> = {
        'color': 'red',
        'bold': false,
        'italic': true,
        'underline': true,
      }
      expect(convertTitleFontApi(redItalicUnderline)).assertEqual('193')
      const gray: Record<string, Object> = {
        'color': 'gray',
      }
      expect(convertTitleFontApi(gray)).assertEqual('16')
      const goldBold: Record<string, Object> = {
        'color': 'gold',
        'bold': true,
      }
      expect(convertTitleFontApi(goldBold)).assertEqual('34')
      const green: Record<string, Object> = {
        'color': 'green',
      }
      expect(convertTitleFontApi(green)).assertEqual('4')
      /* 无任何字体标记 → 空串 */
      const plain: Record<string, Object> = {
        'color': '',
      }
      expect(convertTitleFontApi(plain)).assertEqual('')
      /* 非法 color（未知色名/数字）：不设颜色位，样式位仍生效 */
      const unknownColor: Record<string, Object> = {
        'color': 'blue',
        'bold': true,
      }
      expect(convertTitleFontApi(unknownColor)).assertEqual('32')
      const numericColor: Record<string, Object> = {
        'color': 8,
        'italic': true,
      }
      expect(convertTitleFontApi(numericColor)).assertEqual('64')
    })

    it('fallsBackToLocalTimeForCurTime', 0, () => {
      const info: TopicListInfo | null = parseSubjectList(
        createSubjectListResponse(), new Set<string>(), [], 1)
      expect(info).not().assertNull()
      const list = info as TopicListInfo
      /* 官方 subject 系响应无 time 字段，以本地秒级时间戳兜底（24 小时热门
         窗口依赖 curTime）。用 ±10s 宽松窗口断言，避免机器时钟抖动误报。 */
      const now: number = Math.floor(Date.now() / 1000)
      expect(list.curTime).assertLarger(now - 10)
      expect(list.curTime).assertLess(now + 10)
    })

    it('filtersKeywordsAndBlacklist', 0, () => {
      const keywords: string[] = ['战报']
      const blacklist: Set<string> = new Set<string>(['64371487'])
      const info: TopicListInfo | null = parseSubjectList(
        createSubjectListResponse(), blacklist, keywords, 1)
      expect(info).not().assertNull()
      const list = info as TopicListInfo
      /* 标题含「战报」的主题被屏蔽，匿名主题保留 */
      expect(list.threadPageList.length).assertEqual(1)
      expect(list.threadPageList[0].tid).assertEqual(47344607)
      expect(list.threadPageList[0].isInBlackList).assertFalse()
      /* 黑名单命中：不屏蔽主题，但标记 isInBlackList */
      const onlyBlacklist: Set<string> = new Set<string>(['64371487'])
      const info2: TopicListInfo | null = parseSubjectList(
        createSubjectListResponse(), onlyBlacklist, [], 1)
      expect(info2).not().assertNull()
      const list2 = info2 as TopicListInfo
      expect(list2.threadPageList.length).assertEqual(2)
      expect(list2.threadPageList[0].isInBlackList).assertTrue()
    })

    it('returnsNullOnFailureOrUnknownShape', 0, () => {
      /* 业务失败 */
      const emptyResult: Record<string, Object> = {}
      const failed: Record<string, Object> = {
        'code': 2048,
        'msg': '页面错误',
        'result': emptyResult,
      }
      expect(parseSubjectList(failed, new Set<string>(), [], 1)).assertNull()
      /* result 非对象 */
      const scalarResult: Record<string, Object> = {
        'code': 0,
        'result': 'not-an-object',
      }
      expect(parseSubjectList(scalarResult, new Set<string>(), [], 1)).assertNull()
      /* result 缺失 */
      const missingResult: Record<string, Object> = {
        'code': 0,
      }
      expect(parseSubjectList(missingResult, new Set<string>(), [], 1)).assertNull()
      /* result 缺 data（形状不可识别） */
      const noDataResult: Record<string, Object> = {
        'subForum': [],
      }
      const noData: Record<string, Object> = {
        'code': 0,
        'result': noDataResult,
      }
      expect(parseSubjectList(noData, new Set<string>(), [], 1)).assertNull()
    })

    it('buildsSubjectQuery', 0, () => {
      /* 变体 list 普通列表：fid 直传 */
      const fidParams: TopicListParams = createParams()
      fidParams.fid = '7'
      fidParams.page = '2'
      const fidQuery: Record<string, string> = buildSubjectQuery(fidParams)
      expect(fidQuery['page']).assertEqual('2')
      expect(fidQuery['fid']).assertEqual('7')
      expect(fidQuery['stid']).assertUndefined()
      /* fid "356" 映射为 "323" */
      const mappedParams: TopicListParams = createParams()
      mappedParams.fid = '356'
      expect(buildSubjectQuery(mappedParams)['fid']).assertEqual('323')
      expect(normalizeSubjectFid('356')).assertEqual('323')
      expect(normalizeSubjectFid('7')).assertEqual('7')
      /* stid 优先于 fid（请求层） */
      const stidParams: TopicListParams = createParams()
      stidParams.fid = '7'
      stidParams.stid = '88'
      const stidQuery: Record<string, string> = buildSubjectQuery(stidParams)
      expect(stidQuery['stid']).assertEqual('88')
      expect(stidQuery['fid']).assertUndefined()
      /* fid = '-1'（全局）不进入请求参数 */
      const globalParams: TopicListParams = createParams()
      globalParams.fid = '-1'
      expect(buildSubjectQuery(globalParams)['fid']).assertUndefined()
      /* 变体 search 主题搜索：key + table=7 + fid 限定 + content */
      const searchParams: TopicListParams = createParams()
      searchParams.key = '少前'
      searchParams.fid = '-195362'
      searchParams.content = '1'
      const searchQuery: Record<string, string> = buildSubjectQuery(searchParams)
      expect(searchQuery['key']).assertEqual('少前')
      expect(searchQuery['table']).assertEqual('7')
      expect(searchQuery['fid']).assertEqual('-195362')
      expect(searchQuery['content']).assertEqual('1')
      /* recommend 分支只发 recommend（实测 order_by/user 不影响结果） */
      const recommendParams: TopicListParams = createParams()
      recommendParams.fid = '7'
      recommendParams.recommend = '1'
      const recommendQuery: Record<string, string> = buildSubjectQuery(recommendParams)
      expect(recommendQuery['recommend']).assertEqual('1')
      expect(recommendQuery['order_by']).assertUndefined()
      expect(recommendQuery['user']).assertUndefined()
      /* 独立排序：orderBy 进 order_by */
      const orderParams: TopicListParams = createParams()
      orderParams.fid = '7'
      orderParams.orderBy = 'postdatedesc'
      expect(buildSubjectQuery(orderParams)['order_by']).assertEqual('postdatedesc')
      /* page > 100：补 nounion=1 + order_by=postdatedesc */
      const deepParams: TopicListParams = createParams()
      deepParams.fid = '7'
      deepParams.page = '101'
      const deepQuery: Record<string, string> = buildSubjectQuery(deepParams)
      expect(deepQuery['nounion']).assertEqual('1')
      expect(deepQuery['order_by']).assertEqual('postdatedesc')
    })

    it('computesSubjectSignParams', 0, () => {
      /* 搜索用 key（实测：传 fid 返回 code=5 签名错误） */
      const searchParams: TopicListParams = createParams()
      searchParams.key = '少前'
      searchParams.fid = '-195362'
      expect(buildSubjectSignParams(searchParams)).assertEqual('少前')
      /* 普通列表用 fid（映射后；实测：空串返回 code=5 签名错误） */
      const fidParams: TopicListParams = createParams()
      fidParams.fid = '356'
      expect(buildSubjectSignParams(fidParams)).assertEqual('323')
      /* stid 场景显式空串（实测：传 stid 返回 code=5 签名错误） */
      const stidParams: TopicListParams = createParams()
      stidParams.fid = '7'
      stidParams.stid = '88'
      expect(buildSubjectSignParams(stidParams)).assertEqual('')
      /* 空参数 */
      expect(buildSubjectSignParams(createParams())).assertEqual('')
    })

    it('buildsToppedQueryAndSignParams', 0, () => {
      /* 置顶变体（官方 kt.c.r0）：topped=fid + page，无 order_by/recommend */
      const query: Record<string, string> = buildToppedQuery('7', '1')
      expect(query['topped']).assertEqual('7')
      expect(query['page']).assertEqual('1')
      expect(query['order_by']).assertUndefined()
      /* page 缺省兜底 1 */
      const defaultPage: Record<string, string> = buildToppedQuery('-195362', '')
      expect(defaultPage['topped']).assertEqual('-195362')
      expect(defaultPage['page']).assertEqual('1')
      /* signParams = topped 值原样（官方 r0 无 356→323 归一化） */
      expect(buildToppedSignParams('356')).assertEqual('356')
      expect(buildToppedSignParams('7')).assertEqual('7')
    })

    it('buildsHotQueryAndSignParams', 0, () => {
      /* 热门变体（官方 kt.c.O）：fid + days + _page */
      const query: Record<string, string> = buildHotQuery('7', '1')
      expect(query['fid']).assertEqual('7')
      expect(query['days']).assertEqual('1')
      expect(query['_page']).assertEqual('1')
      /* signParams = fid+days 直接拼接（如 7+1 → "71"） */
      expect(buildHotSignParams('7', '1')).assertEqual('71')
      expect(buildHotSignParams('7', '30')).assertEqual('730')
      /* fid 空串（合集场景）：signParams 仅 days，与官方 .a(str + i2) 一致 */
      expect(buildHotSignParams('', '7')).assertEqual('7')
    })

    it('mapsHotRangeToDays', 0, () => {
      /* 时间窗档位 → 官方 TopArticleListScope days：24小时→1、本周→7、本月→30 */
      expect(getHotDays('day')).assertEqual('1')
      expect(getHotDays('week')).assertEqual('7')
      expect(getHotDays('month')).assertEqual('30')
      /* 未知档位按 24 小时兜底 */
      expect(getHotDays('year')).assertEqual('1')
    })

    it('parsesToppedList', 0, () => {
      const info: TopicListInfo | null = parseToppedList(
        createToppedListResponse(), new Set<string>(), [], 1)
      expect(info).not().assertNull()
      const list = info as TopicListInfo
      /* result.data 逐条解析，字段与 subject/list 同构 */
      expect(list.threadPageList.length).assertEqual(2)
      expect(list.threadPageList[0].tid).assertEqual(17326655)
      expect(list.threadPageList[0].subject).assertEqual('[置顶]版头公告与版规')
      expect(list.threadPageList[0].replies).assertEqual(0)
      expect(list.threadPageList[1].authorId).assertEqual(64371487)
      /* 不分页：totalPages=1、totalRows=条目数（无 totalPage 字段） */
      expect(list.pagination.page).assertEqual(1)
      expect(list.pagination.totalPages).assertEqual(1)
      expect(list.pagination.totalRows).assertEqual(2)
      /* 无 forumname/subForum 字段 */
      expect(list.name).assertEqual('')
      expect(list.subBoardList.length).assertEqual(0)
      /* 业务失败（code!=0）→ null */
      const failed: Record<string, Object> = {
        'code': 5,
        'msg': '签名错误',
        'result': { 'data': [] },
      }
      expect(parseToppedList(failed, new Set<string>(), [], 1)).assertNull()
      /* result.data 缺失 → null */
      const noData: Record<string, Object> = {
        'code': 0,
        'result': {},
      }
      expect(parseToppedList(noData, new Set<string>(), [], 1)).assertNull()
      /* result.data 空数组 → 非 null 空列表（UI 空态依据），totalPages=0 不诱导翻页 */
      const empty: Record<string, Object> = {
        'code': 0,
        'msg': '操作成功',
        'result': { 'data': [] },
      }
      const emptyInfo: TopicListInfo | null = parseToppedList(empty, new Set<string>(), [], 1)
      expect(emptyInfo).not().assertNull()
      const emptyList = emptyInfo as TopicListInfo
      expect(emptyList.threadPageList.length).assertEqual(0)
      expect(emptyList.pagination.totalPages).assertEqual(0)
      /* 单条边界：N=1 → totalPages=1 */
      const single: Record<string, Object> = {
        'code': 0,
        'result': { 'data': [{ 'tid': 1, 'fid': 7, 'subject': '单条置顶', 'replies': 0 }] },
      }
      const singleInfo: TopicListInfo | null = parseToppedList(single, new Set<string>(), [], 1)
      expect(singleInfo).not().assertNull()
      const singleList = singleInfo as TopicListInfo
      expect(singleList.threadPageList.length).assertEqual(1)
      expect(singleList.pagination.totalPages).assertEqual(1)
      expect(singleList.pagination.totalRows).assertEqual(1)
    })

    it('parsesHotSubjectList', 0, () => {
      const info: TopicListInfo | null = parseHotSubjectList(
        createHotSubjectListResponse(), new Set<string>(), [], 1)
      expect(info).not().assertNull()
      const list = info as TopicListInfo
      /* result 扁平数组逐条解析 */
      expect(list.threadPageList.length).assertEqual(2)
      expect(list.threadPageList[0].tid).assertEqual(47442318)
      expect(list.threadPageList[0].replies).assertEqual(170)
      expect(list.threadPageList[0].subject).assertEqual('商城新坐骑，有什么好说的，直接冲雷子就对了！')
      expect(list.threadPageList[1].authorId).assertEqual(100)
      /* 不分页：totalPages=1、totalRows=条目数 */
      expect(list.pagination.page).assertEqual(1)
      expect(list.pagination.totalPages).assertEqual(1)
      expect(list.pagination.totalRows).assertEqual(2)
      /* 无 subForum */
      expect(list.subBoardList.length).assertEqual(0)
      /* 业务失败（code!=0，hot 响应无 msg）→ null */
      const failed: Record<string, Object> = {
        'code': 5,
        'result': [],
      }
      expect(parseHotSubjectList(failed, new Set<string>(), [], 1)).assertNull()
      /* result 非数组 → null */
      const wrongShape: Record<string, Object> = {
        'code': 0,
        'result': { 'data': [] },
      }
      expect(parseHotSubjectList(wrongShape, new Set<string>(), [], 1)).assertNull()
      /* result 空数组 → 非 null 空列表（UI 空态依据），totalPages=0 不诱导翻页 */
      const empty: Record<string, Object> = {
        'code': 0,
        'result': [],
      }
      const emptyInfo: TopicListInfo | null = parseHotSubjectList(empty, new Set<string>(), [], 1)
      expect(emptyInfo).not().assertNull()
      const emptyList = emptyInfo as TopicListInfo
      expect(emptyList.threadPageList.length).assertEqual(0)
      expect(emptyList.pagination.totalPages).assertEqual(0)
      /* 关键词过滤在 flat 列表上生效（复用 parseTopicList 链路） */
      const filtered: Record<string, Object> = {
        'code': 0,
        'result': [{ 'tid': 1, 'fid': 7, 'subject': '屏蔽词测试', 'replies': 1 }],
      }
      const filteredInfo: TopicListInfo | null = parseHotSubjectList(
        filtered, new Set<string>(), ['屏蔽词'], 1)
      expect(filteredInfo).not().assertNull()
      const filteredList = filteredInfo as TopicListInfo
      expect(filteredList.threadPageList.length).assertEqual(0)
    })

    it('buildsSubscriptionParams', 0, () => {
      /* show=true → type=1 订阅 */
      expect(buildSubscriptionType(true)).assertEqual('1')
      /* show=false → type=2 取消订阅 */
      expect(buildSubscriptionType(false)).assertEqual('2')
      /* 订阅字段：ufid/fid/type/sub_type/tid（与官方 T0 逐字段一致） */
      const fields: Record<string, string> = buildSubscriptionFields(7, 124, 2606, '20472000', true)
      expect(fields['ufid']).assertEqual('7')
      expect(fields['fid']).assertEqual('124')
      expect(fields['type']).assertEqual('1')
      expect(fields['sub_type']).assertEqual('2606')
      expect(fields['tid']).assertEqual('20472000')
      /* 取消订阅 type=2 */
      const cancel: Record<string, string> = buildSubscriptionFields(7, 124, 2606, '20472000', false)
      expect(cancel['type']).assertEqual('2')
      /* signParams = ufid+fid+type 拼接（实测：错误拼接返回 code=5） */
      expect(buildSubscriptionSignParams(7, 124, true)).assertEqual('71241')
      expect(buildSubscriptionSignParams(7, 124, false)).assertEqual('71242')
    })

    it('buildsDeepSearchQuery', 0, () => {
      /* search 变体 + page>100：key/table/fid + nounion=1 + order_by=postdatedesc */
      const deepSearch: TopicListParams = createParams()
      deepSearch.key = '少前'
      deepSearch.fid = '7'
      deepSearch.page = '101'
      const deepQuery: Record<string, string> = buildSubjectQuery(deepSearch)
      expect(deepQuery['key']).assertEqual('少前')
      expect(deepQuery['table']).assertEqual('7')
      expect(deepQuery['fid']).assertEqual('7')
      expect(deepQuery['nounion']).assertEqual('1')
      expect(deepQuery['order_by']).assertEqual('postdatedesc')
    })

    it('paginatesOptimisticallyWhenTotalPageMissing', 0, () => {
      /* 无 totalPage + 非空页：totalPages = page+1（乐观，继续翻页） */
      const topic: Record<string, Object> = {
        'tid': 1,
        'fid': 7,
        'author': '测试',
        'authorid': 100,
        'subject': '乐观分页',
        'postdate': 1786340000,
        'lastpost': 1786340000,
        'lastposter': '路人',
        'replies': 0,
        'type': 0,
      }
      const dataArr: Object[] = [topic]
      const result: Record<string, Object> = {
        'data': dataArr,
      }
      const noTotal: Record<string, Object> = {
        'code': 0,
        'result': result,
      }
      const info: TopicListInfo | null = parseSubjectList(noTotal, new Set<string>(), [], 1)
      expect(info).not().assertNull()
      const list = info as TopicListInfo
      expect(list.pagination.totalPages).assertEqual(2)
      /* 无 totalPage + 真空页：totalPages = page（已到底） */
      const emptyResult: Record<string, Object> = {
        'data': [],
      }
      const emptyPage: Record<string, Object> = {
        'code': 0,
        'result': emptyResult,
      }
      const info2: TopicListInfo | null = parseSubjectList(emptyPage, new Set<string>(), [], 3)
      expect(info2).not().assertNull()
      const list2 = info2 as TopicListInfo
      expect(list2.pagination.totalPages).assertEqual(3)
      expect(list2.threadPageList.length).assertEqual(0)
    })

    it('fallsBackToResultTotalPage', 0, () => {
      /* 顶层无 totalPage，result 内层提供（实测两种位置都可能返回） */
      const topic: Record<string, Object> = {
        'tid': 1,
        'fid': 7,
        'author': '测试',
        'authorid': 100,
        'subject': '内层分页',
        'postdate': 1786340000,
        'lastpost': 1786340000,
        'lastposter': '路人',
        'replies': 0,
        'type': 0,
      }
      const dataArr: Object[] = [topic]
      const result: Record<string, Object> = {
        'data': dataArr,
        'totalPage': 5,
      }
      const response: Record<string, Object> = {
        'code': 0,
        'result': result,
      }
      const info: TopicListInfo | null = parseSubjectList(response, new Set<string>(), [], 2)
      expect(info).not().assertNull()
      const list = info as TopicListInfo
      expect(list.pagination.totalPages).assertEqual(5)
      expect(list.pagination.page).assertEqual(2)
    })

    it('parsesSearchResponseWithoutSubBoards', 0, () => {
      /* subject/search 响应形状：result.data + 顶层 totalPage，无 subForum */
      const topic: Record<string, Object> = {
        'tid': 1,
        'fid': 7,
        'author': '测试',
        'authorid': 100,
        'subject': '搜索结果',
        'postdate': 1786340000,
        'lastpost': 1786340000,
        'lastposter': '路人',
        'replies': 0,
        'type': 0,
        'forumname': '艾泽拉斯议事厅',
      }
      const dataArr: Object[] = [topic]
      const result: Record<string, Object> = {
        'data': dataArr,
      }
      const response: Record<string, Object> = {
        'code': 0,
        'msg': '操作成功',
        'result': result,
        'totalPage': 3,
      }
      const info: TopicListInfo | null = parseSubjectList(response, new Set<string>(), [], 1)
      expect(info).not().assertNull()
      const list = info as TopicListInfo
      expect(list.threadPageList.length).assertEqual(1)
      expect(list.threadPageList[0].board).assertEqual('艾泽拉斯议事厅')
      expect(list.subBoardList.length).assertEqual(0)
      expect(list.pagination.totalPages).assertEqual(3)
    })

    it('parsesOfficialCategoryArray', 0, () => {
      /* 官方 home/category：result 为分类数组（实测 7 个分类） */
      const forum1: Record<string, Object> = {
        'fid': 7,
        'name': '艾泽拉斯议事厅',
        'info': '魔兽主讨论区',
        'nameS': '议事厅',
        'bit': 9,
        'is_forumlist': false,
        'id': 7,
        'icon': '',
      }
      const forum2: Record<string, Object> = {
        'fid': -7,
        'name': '网事杂谈',
        'bit': 1,
        'is_forumlist': false,
        'id': -7,
        'icon': '',
      }
      const group1: Record<string, Object> = {
        'name': '艾泽拉斯议事厅',
        'id': 10000,
        'info': '',
        'forums': [forum1],
      }
      const group2: Record<string, Object> = {
        'name': '网事杂谈',
        'id': 10004,
        'info': '',
        'forums': [forum2],
      }
      const cat1: Record<string, Object> = {
        'id': 0,
        '_id': 'wow',
        'name': '魔兽世界',
        'groups': [group1],
      }
      const cat2: Record<string, Object> = {
        'id': 0,
        '_id': 'other',
        'name': '网事杂谈',
        'groups': [group2],
      }
      const cats: Object[] = [cat1, cat2]
      const response: Record<string, Object> = {
        'code': 0,
        'forum_icon_pre': 'http://img4.nga.cn/ngabbs/nga_classic/f/app/',
        'result': cats,
      }
      const categories: Category[] = parseForumCategories(response)
      expect(categories.length).assertEqual(2)
      expect(categories[0].id).assertEqual('wow')
      expect(categories[0].name).assertEqual('魔兽世界')
      expect(categories[0].sub.length).assertEqual(1)
      expect(categories[0].sub[0].name).assertEqual('艾泽拉斯议事厅')
      expect(categories[0].sub[0].content.length).assertEqual(1)
      expect(categories[0].sub[0].content[0].fid).assertEqual(7)
      expect(categories[0].sub[0].content[0].name).assertEqual('艾泽拉斯议事厅')
      expect(categories[0].sub[0].content[0].bit).assertEqual(9)
      expect(categories[1].id).assertEqual('other')
      expect(categories[1].sub[0].content[0].fid).assertEqual(-7)
    })

    it('parsesOfficialForumSearchResult', 0, () => {
      /* 官方 forum/search：result 为 Forum 数组（实测 key=warcraft） */
      const parent1: Record<string, Object> = {
        'fid': 857,
        'name': '暴雪游戏',
      }
      const parent2: Record<string, Object> = {
        'fid': 857,
        'name': '暴雪游戏',
      }
      const item1: Record<string, Object> = {
        'id': 490,
        'fid': 490,
        'stid': 0,
        'name': '魔兽争霸',
        'parent': parent1,
        'info': '',
      }
      const item2: Record<string, Object> = {
        'id': 852,
        'fid': 852,
        'stid': 0,
        'name': '魔兽大作战',
        'parent': parent2,
        'info': '',
      }
      const items: Object[] = [item1, item2]
      const response: Record<string, Object> = {
        'code': 0,
        'msg': '操作成功',
        'result': items,
      }
      const forums: ForumSearchItem[] = parseForumSearch(response)
      expect(forums.length).assertEqual(2)
      expect(forums[0].fid).assertEqual('490')
      /* 官方元素 stid 恒为 0（非专题版块）；stid 存在时优先于 id */
      expect(forums[0].stid).assertEqual('0')
      expect(forums[0].name).assertEqual('魔兽争霸')
      expect(forums[1].name).assertEqual('魔兽大作战')
    })
  })
}
