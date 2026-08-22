import { describe, it, expect } from '@ohos/hypium'
import {
  extractAppTopicListError,
  parseAppTopicList,
} from '../main/ets/parser/AppTopicListParser'
import { parseForumCategories, parseForumSearch } from '../main/ets/parser/ForumParser'
import {
  buildAppThreadQuery,
  buildAppSignParams,
  normalizeAppFid,
} from '../main/ets/common/utils/AppTopicListQuery'
import type { TopicListInfo } from '../main/ets/model/Topic'
import type { Category, ForumSearchItem } from '../main/ets/model/Forum'
import type { TopicListParams } from '../main/ets/service/api/ForumApi'

/**
 * 构造官方 thread.php 主题列表响应（实测形状，nga-hack 探测 fid=7）。
 *
 * @returns 官方响应
 */
function createAppTopicListResponse(): Record<string, Object> {
  const attachObj: Record<string, Object> = {
    'attachurl': 'mon_202608/19/7Q68-jpq0ZtT3cS1uo-11i.jpeg',
  }
  const attachs: Object[] = [attachObj]
  const topicMiscVar: Record<string, Object> = {
    '1': 67108904,
    '2': 47344543,
  }
  const parent: Record<string, Object> = {
    '0': 7,
    '1': 47344543,
    '2': '乌拉特克的诅咒：烈毒之渊首杀合集',
  }
  const topic1: Record<string, Object> = {
    'tid': 47344551,
    'fid': 7,
    'quote_from': 0,
    'icon': 0,
    'topic_misc': 'AgLSa58BBAAAKA',
    'author': '皮纳特丶',
    'authorid': 64371487,
    'subject': '[战报帖]乌拉特克的诅咒首杀争霸赛',
    'type': 73732,
    'postdate': 1786338953,
    'lastpost': 1787343739,
    'lastposter': 'IceLibra',
    'replies': 504,
    'lastmodify': 1787343778,
    'recommend': 10,
    'attachs': attachs,
    'tpcurl': '/read.php?tid=47344551',
    'topic_misc_var': topicMiscVar,
    'parent': parent,
  }
  const topic2: Record<string, Object> = {
    'tid': 47344607,
    'fid': 7,
    'quote_from': 0,
    'icon': 0,
    'author': '#anony_38ac8d5e60bda0f1f0a0f2a0d0a0f1f',
    'authorid': 0,
    'subject': '匿名提问贴',
    'type': 0,
    'postdate': 1786340000,
    'lastpost': 1787340000,
    'lastposter': '路人甲',
    'replies': 3,
    'lastmodify': 1787340000,
    'recommend': 0,
    'tpcurl': '/read.php?tid=47344607',
  }
  const tArr: Object[] = [topic1, topic2]
  const sub1: Object[] = [124, '莫高雷壁画洞穴', '暴雪艺术原创', 20472000, 2606]
  const sub2: Object[] = [255, '团队管理经验交流', '管理经验交流', 14673796, 2606]
  const sub3: Object[] = [533, '大秘境集合石', '', 9810209, 40]
  const sub4: Object[] = [47344543, '乌拉特克的诅咒：烈毒之渊首杀合集', '', 47344543, 542]
  const subForums: Record<string, Object> = {
    '124': sub1,
    '255': sub2,
    '533': sub3,
    't47344543': sub4,
  }
  const forumInfo: Record<string, Object> = {
    'fid': 7,
    'name': '艾泽拉斯议事厅 - Hall of Azeroth',
    'topped_topic': 17326655,
    'sub_forums': subForums,
  }
  const currentUser: Record<string, Object> = {
    'uid': 42023922,
    'group_bit': 98528,
    'admincheck': 0,
    'rvrc': 10,
  }
  const globalConfig: Record<string, Object> = {
    '_ATTACH_BASE_VIEW': 'img.nga.cn/attachments',
  }
  const result: Record<string, Object> = {
    '__CU': currentUser,
    '__GLOBAL': globalConfig,
    '__ROWS': 3741919,
    '__T': tArr,
    '__T__ROWS': 54,
    '__T__ROWS_PAGE': 35,
    '__R__ROWS_PAGE': 20,
    '__F': forumInfo,
  }
  const response: Record<string, Object> = {
    'code': 0,
    'result': result,
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
  }
}

export default function appTopicListUnitTest(): void {
  describe('appTopicListUnitTest', () => {
    it('extractsBusinessError', 0, () => {
      expect(extractAppTopicListError(createAppTopicListResponse())).assertNull()
      const pageError: Record<string, Object> = {
        'code': 2048,
        'msg': '页面错误',
      }
      expect(extractAppTopicListError(pageError)).assertEqual('页面错误')
      const rateLimited: Record<string, Object> = {
        'code': 15,
        'msg': '频率限制',
      }
      expect(extractAppTopicListError(rateLimited)).assertEqual('频率限制')
      const signError: Record<string, Object> = {
        'code': 5,
        'msg': '签名错误',
      }
      expect(extractAppTopicListError(signError)).assertEqual('签名错误')
      /* code!=0 且无 msg：回退「错误码: N」 */
      const noMsg: Record<string, Object> = {
        'code': 42,
      }
      expect(extractAppTopicListError(noMsg)).assertEqual('错误码: 42')
      /* 形状不可识别（无 code）视为无业务错误 */
      const emptyResult: Record<string, Object> = {}
      const noCode: Record<string, Object> = {
        'result': emptyResult,
      }
      expect(extractAppTopicListError(noCode)).assertNull()
      /* ngaRequest 对 HTTP 层 HTML 错误页的归一化形状：error 对象与 error_code 透传 */
      const errObj: Record<string, Object> = {
        '0': '页面被吃了',
      }
      const htmlErrorObj: Record<string, Object> = {
        'error': errObj,
      }
      expect(extractAppTopicListError(htmlErrorObj)).assertEqual('页面被吃了')
      const htmlErrorCode: Record<string, Object> = {
        'error_code': 15,
      }
      expect(extractAppTopicListError(htmlErrorCode)).assertEqual('频率限制')
    })

    it('parsesOfficialTopicList', 0, () => {
      const info: TopicListInfo | null = parseAppTopicList(
        createAppTopicListResponse(), new Set<string>(), [], 1, 1787344000)
      expect(info).not().assertNull()
      const list = info as TopicListInfo
      /* __T 数组逐条解析 */
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
      expect(first.topicMisc).assertEqual('AgLSa58BBAAAKA')
      /* 匿名条目：isAnonymity + 匿名名被解码为可读名（不再是 #anony_ 原文） */
      const second = list.threadPageList[1]
      expect(second.isAnonymity).assertTrue()
      expect(second.author).not().assertEqual('#anony_38ac8d5e60bda0f1f0a0f2a0d0a0f1f')
      /* parent['2'] → board（官方条目的父合集名） */
      expect(first.board).assertEqual('乌拉特克的诅咒：烈毒之渊首杀合集')
      /* 版块名与子版块（官方数组值 [fid, 名称, 简介, tid, 类型位] 按 fid 解析） */
      expect(list.name).assertEqual('艾泽拉斯议事厅 - Hall of Azeroth')
      expect(list.subBoardList.length).assertEqual(4)
      expect(list.subBoardList[0].fid).assertEqual(124)
      expect(list.subBoardList[0].name).assertEqual('莫高雷壁画洞穴')
      expect(list.subBoardList[0].filterId).assertEqual('20472000')
      expect(list.subBoardList[0].attributes).assertEqual(2606)
      /* 分页：__ROWS / __T__ROWS_PAGE */
      expect(list.pagination.page).assertEqual(1)
      expect(list.pagination.totalRows).assertEqual(3741919)
      expect(list.pagination.totalPages).assertEqual(Math.ceil(3741919 / 35))
      /* curTime 使用调用方传入的服务端时间（官方响应无 time 字段） */
      expect(list.curTime).assertEqual(1787344000)
    })

    it('fallsBackToLocalTimeForCurTime', 0, () => {
      const info: TopicListInfo | null = parseAppTopicList(
        createAppTopicListResponse(), new Set<string>(), [], 1)
      expect(info).not().assertNull()
      const list = info as TopicListInfo
      /* 未传 curTime 时以本地秒级时间戳兜底（官方响应无 time 字段，24 小时热门
         窗口依赖 curTime）。用 ±10s 宽松窗口断言，避免机器时钟抖动误报。 */
      const now: number = Math.floor(Date.now() / 1000)
      expect(list.curTime).assertLarger(now - 10)
      expect(list.curTime).assertLess(now + 10)
    })

    it('filtersKeywordsAndBlacklist', 0, () => {
      const keywords: string[] = ['战报']
      const blacklist: Set<string> = new Set<string>(['64371487'])
      const info: TopicListInfo | null = parseAppTopicList(
        createAppTopicListResponse(), blacklist, keywords, 1, 1787344000)
      expect(info).not().assertNull()
      const list = info as TopicListInfo
      /* 标题含「战报」的主题被屏蔽，匿名主题保留 */
      expect(list.threadPageList.length).assertEqual(1)
      expect(list.threadPageList[0].tid).assertEqual(47344607)
      expect(list.threadPageList[0].isInBlackList).assertFalse()
      /* 黑名单命中：不屏蔽主题，但标记 isInBlackList */
      const onlyBlacklist: Set<string> = new Set<string>(['64371487'])
      const info2: TopicListInfo | null = parseAppTopicList(
        createAppTopicListResponse(), onlyBlacklist, [], 1, 1787344000)
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
      expect(parseAppTopicList(failed, new Set<string>(), [], 1)).assertNull()
      /* result 非对象 */
      const scalarResult: Record<string, Object> = {
        'code': 0,
        'result': 'not-an-object',
      }
      expect(parseAppTopicList(scalarResult, new Set<string>(), [], 1)).assertNull()
      /* result 缺失 */
      const missingResult: Record<string, Object> = {
        'code': 0,
      }
      expect(parseAppTopicList(missingResult, new Set<string>(), [], 1)).assertNull()
      /* result 缺 __T（形状不可识别） */
      const emptyForum: Record<string, Object> = {}
      const noTopicsResult: Record<string, Object> = {
        '__F': emptyForum,
      }
      const noTopics: Record<string, Object> = {
        'code': 0,
        'result': noTopicsResult,
      }
      expect(parseAppTopicList(noTopics, new Set<string>(), [], 1)).assertNull()
    })

    it('buildsOfficialThreadQuery', 0, () => {
      /* 变体 A 普通列表：fid 直传 */
      const fidParams: TopicListParams = createParams()
      fidParams.fid = '7'
      fidParams.page = '2'
      const fidQuery: Record<string, string> = buildAppThreadQuery(fidParams)
      expect(fidQuery['page']).assertEqual('2')
      expect(fidQuery['fid']).assertEqual('7')
      expect(fidQuery['stid']).assertUndefined()
      /* fid "356" 映射为 "323" */
      const mappedParams: TopicListParams = createParams()
      mappedParams.fid = '356'
      expect(buildAppThreadQuery(mappedParams)['fid']).assertEqual('323')
      expect(normalizeAppFid('356')).assertEqual('323')
      expect(normalizeAppFid('7')).assertEqual('7')
      /* stid 优先于 fid（请求层） */
      const stidParams: TopicListParams = createParams()
      stidParams.fid = '7'
      stidParams.stid = '88'
      const stidQuery: Record<string, string> = buildAppThreadQuery(stidParams)
      expect(stidQuery['stid']).assertEqual('88')
      expect(stidQuery['fid']).assertUndefined()
      /* fid = '-1'（全局）不进入请求参数 */
      const globalParams: TopicListParams = createParams()
      globalParams.fid = '-1'
      expect(buildAppThreadQuery(globalParams)['fid']).assertUndefined()
      /* 变体 C 主题搜索：key + table=7 + fid 限定 + content */
      const searchParams: TopicListParams = createParams()
      searchParams.key = '少前'
      searchParams.fid = '-195362'
      searchParams.content = '1'
      const searchQuery: Record<string, string> = buildAppThreadQuery(searchParams)
      expect(searchQuery['key']).assertEqual('少前')
      expect(searchQuery['table']).assertEqual('7')
      expect(searchQuery['fid']).assertEqual('-195362')
      expect(searchQuery['content']).assertEqual('1')
      /* recommend 分支只发 recommend（实测 order_by/user 不影响结果） */
      const recommendParams: TopicListParams = createParams()
      recommendParams.fid = '7'
      recommendParams.recommend = '1'
      const recommendQuery: Record<string, string> = buildAppThreadQuery(recommendParams)
      expect(recommendQuery['recommend']).assertEqual('1')
      expect(recommendQuery['order_by']).assertUndefined()
      expect(recommendQuery['user']).assertUndefined()
      /* 独立排序：orderBy 进 order_by */
      const orderParams: TopicListParams = createParams()
      orderParams.fid = '7'
      orderParams.orderBy = 'postdatedesc'
      expect(buildAppThreadQuery(orderParams)['order_by']).assertEqual('postdatedesc')
      /* page > 100：补 nounion=1 + order_by=postdatedesc */
      const deepParams: TopicListParams = createParams()
      deepParams.fid = '7'
      deepParams.page = '101'
      const deepQuery: Record<string, string> = buildAppThreadQuery(deepParams)
      expect(deepQuery['nounion']).assertEqual('1')
      expect(deepQuery['order_by']).assertEqual('postdatedesc')
    })

    it('computesAppSignParams', 0, () => {
      /* 搜索用 key */
      const searchParams: TopicListParams = createParams()
      searchParams.key = '少前'
      searchParams.fid = '-195362'
      expect(buildAppSignParams(searchParams)).assertEqual('少前')
      /* 普通列表用 fid（映射后） */
      const fidParams: TopicListParams = createParams()
      fidParams.fid = '356'
      expect(buildAppSignParams(fidParams)).assertEqual('323')
      /* stid 场景显式空串（签名与请求参数一致，避免 code=5） */
      const stidParams: TopicListParams = createParams()
      stidParams.fid = '7'
      stidParams.stid = '88'
      expect(buildAppSignParams(stidParams)).assertEqual('')
      /* 空参数 */
      expect(buildAppSignParams(createParams())).assertEqual('')
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
