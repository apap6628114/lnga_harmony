import { describe, it, expect } from '@ohos/hypium'
import {
  appUserListEndpoints,
  extractAppUserTopicItems,
  normalizeAppUserTopicItem,
  parseAppUserTopicList,
} from '../main/ets/parser/AppUserTopicParser'
import type { AppUserListEndpoint } from '../main/ets/parser/AppUserTopicParser'
import type { TopicListInfo } from '../main/ets/model/Topic'

/**
 * 构造一个正常的官方主题条目（app_api.php user/subjects 形状）。
 *
 * @param tid - 主题 ID
 * @returns 官方条目
 */
function createTopicItem(tid: number): Record<string, Object> {
  const item: Record<string, Object> = {
    'tid': tid,
    'fid': 781,
    'author': '测试用户',
    'authorid': 205511,
    'subject': '测试主题标题',
    'postdate': 1752714880,
    'lastpost': 1786686937,
    'lastposter': '回复者甲',
    'replies': 94,
    'type': 65536,
    'forumname': '期货交易',
  }
  return item
}

/**
 * 构造 result 为「数字键字典」形状的官方响应（nuke.php load_topic_by_uid 实测形状）。
 *
 * @returns 官方响应
 */
function createDictResultResponse(): Record<string, Object> {
  const item0: Record<string, Object> = {
    'tid': 44627932,
    'fid': 781,
    'subject': '天然/合成橡胶 每日资讯分享',
    'type': 65536,
    'postdate': 1752714880,
    'quote_from': 0,
    'authorid': 205511,
    'recommend': 'recommend',
  }
  const item1: Record<string, Object> = {
    'tid': 44625486,
    'fid': -7,
    'subject': '受限帖子占位',
    'type': 0,
    'postdate': 1752674029,
    'quote_from': 0,
    'authorid': 0,
    'recommend': 'recommend',
  }
  const item2: Record<string, Object> = {
    'tid': 44331008,
    'fid': 781,
    'subject': '[合集申请]期货交易版面申请',
    'type': 65536,
    'postdate': 1749486352,
    'quote_from': 0,
    'authorid': 205511,
    'recommend': 'recommend',
  }
  const result: Record<string, Object> = {
    '0': item0,
    '1': item1,
    '7': item2,
  }
  const response: Record<string, Object> = {
    'code': 0,
    'result': result,
  }
  return response
}

/**
 * 构造 result 为「{data: [...]}」形状的官方响应（app_api.php user/subjects / replys）。
 *
 * @param withPost - 是否携带 post 楼层信息（replys 形状）
 * @returns 官方响应
 */
function createDataArrayResponse(withPost: boolean): Record<string, Object> {
  const normal: Record<string, Object> = createTopicItem(44627932)
  if (withPost) {
    const post: Record<string, Object> = {
      'tid': 44627932,
      'pid': 878386616,
      'authorid': 205511,
      'type': 0,
      'postdate': 1786670105,
      'subject': '',
      'content': '回帖内容',
    }
    normal['post'] = post
  }
  const placeholder: Record<string, Object> = {
    'tid': 44625486,
    'fid': -7,
    'author': '',
    'authorid': 0,
    'subject': '帖子发布或回复时间超过限制',
    'postdate': 0,
    'lastpost': 0,
    'lastposter': '',
    'replies': 0,
    'type': 0,
    'attachs': '',
    'error': '帖子发布或回复时间超过限制',
    'forumname': '',
  }
  const data: Object[] = [normal, placeholder]
  const result: Record<string, Object> = {
    'data': data,
  }
  const response: Record<string, Object> = {
    'code': 0,
    'msg': '操作成功',
    'result': result,
  }
  return response
}

/**
 * 构造 result 为纯数组形状的官方响应。
 *
 * @returns 官方响应
 */
function createArrayResultResponse(): Record<string, Object> {
  const item: Record<string, Object> = createTopicItem(44622035)
  const result: Object[] = [item]
  const response: Record<string, Object> = {
    'code': 0,
    'result': result,
  }
  return response
}

/**
 * 注册官方用户主题列表解析单元测试。
 */
export default function appUserTopicUnitTest(): void {
  describe('AppUserTopicUnit', () => {
    it('parsesDictResultShape', 0, () => {
      const items = extractAppUserTopicItems(createDictResultResponse())
      expect(items).not().assertNull()
      const list = items as Record<string, Object>[]
      // 字典键含占位空隙（0,1,7），全部条目原样保留（含 authorid=0 的受限条目）
      expect(list.length).assertEqual(3)
      expect(String(list[0]['tid'])).assertEqual('44627932')
      expect(String(list[1]['tid'])).assertEqual('44625486')
      expect(String(list[2]['tid'])).assertEqual('44331008')
    })

    it('parsesDataArrayShape', 0, () => {
      const items = extractAppUserTopicItems(createDataArrayResponse(false))
      expect(items).not().assertNull()
      const list = items as Record<string, Object>[]
      // 正常条目 + 受限占位条目均保留
      expect(list.length).assertEqual(2)
      const first = list[0]
      expect(String(first['author'])).assertEqual('测试用户')
      const parent = first['parent'] as Record<string, Object> | undefined
      expect(parent).not().assertUndefined()
      expect(String(parent?.['2'] ?? '')).assertEqual('期货交易')
    })

    it('parsesPlainArrayShape', 0, () => {
      const items = extractAppUserTopicItems(createArrayResultResponse())
      expect(items).not().assertNull()
      const list = items as Record<string, Object>[]
      expect(list.length).assertEqual(1)
      expect(Number(list[0]['replies'])).assertEqual(94)
    })

    it('preservesPlaceholderAndRestrictedItems', 0, () => {
      const placeholder: Record<string, Object> = {
        'tid': 44625486,
        'authorid': 0,
        'subject': '帖子发布或回复时间超过限制',
        'error': '帖子发布或回复时间超过限制',
        'attachs': '',
      }
      const normalized = normalizeAppUserTopicItem(placeholder)
      expect(normalized).not().assertNull()
      expect(String(normalized['tid'])).assertEqual('44625486')
      expect(Number(normalized['authorid'])).assertEqual(0)
      expect(String(normalized['subject'])).assertEqual('帖子发布或回复时间超过限制')
      expect(String(normalized['error'])).assertEqual('帖子发布或回复时间超过限制')
    })

    it('normalizesForumNameAndPostFloor', 0, () => {
      const response = createDataArrayResponse(true)
      const items = extractAppUserTopicItems(response)
      expect(items).not().assertNull()
      const list = items as Record<string, Object>[]
      expect(list.length).assertEqual(2)
      const first = list[0]
      const parent = first['parent'] as Record<string, Object> | undefined
      expect(parent).not().assertUndefined()
      expect(String(parent?.['2'] ?? '')).assertEqual('期货交易')
      const p = first['__P'] as Record<string, Object> | undefined
      expect(p).not().assertUndefined()
      expect(String(p?.['pid'] ?? '')).assertEqual('878386616')
      expect(String(p?.['content'] ?? '')).assertEqual('回帖内容')
    })

    it('returnsNullOnBusinessFailure', 0, () => {
      const failed: Record<string, Object> = {
        'code': 2,
        'msg': '未定义服务',
      }
      expect(extractAppUserTopicItems(failed)).assertNull()
      const unknownShape: Record<string, Object> = {
        'code': 0,
        'result': 'not-an-object',
      }
      expect(extractAppUserTopicItems(unknownShape)).assertNull()
      const missingResult: Record<string, Object> = {
        'code': 0,
      }
      expect(extractAppUserTopicItems(missingResult)).assertNull()
    })

    it('encodesPaginationSemantics', 0, () => {
      // 有可见条目的页（rawArr 非空）且无 totalPage：totalPages = page + 1（乐观继续）
      const nonEmpty: TopicListInfo | null = parseAppUserTopicList(
        createDataArrayResponse(false), new Set<string>(), [], 2)
      expect(nonEmpty).not().assertNull()
      const info = nonEmpty as TopicListInfo
      expect(info.threadPageList.length).assertEqual(2)
      expect(info.pagination.page).assertEqual(2)
      expect(info.pagination.totalPages).assertEqual(3)
      // 真空页（data 为空数组）：totalPages = page（已到底）
      const emptyData: Object[] = []
      const emptyResult: Record<string, Object> = {
        'data': emptyData,
      }
      const empty: Record<string, Object> = {
        'code': 0,
        'result': emptyResult,
      }
      const emptyInfo: TopicListInfo | null = parseAppUserTopicList(empty, new Set<string>(), [], 2)
      expect(emptyInfo).not().assertNull()
      const eInfo = emptyInfo as TopicListInfo
      expect(eInfo.threadPageList.length).assertEqual(0)
      expect(eInfo.pagination.totalPages).assertEqual(2)
    })

    it('keepsPagingThroughPlaceholderPages', 0, () => {
      // 满页占位（rawArr 非空但全部受限）：不得判定到底，继续翻页
      const placeholder: Record<string, Object> = {
        'tid': 44625486,
        'authorid': 0,
        'subject': '帖子发布或回复时间超过限制',
      }
      const placeholderData: Object[] = [placeholder, placeholder]
      const placeholderResult: Record<string, Object> = {
        'data': placeholderData,
      }
      const placeholderPage: Record<string, Object> = {
        'code': 0,
        'result': placeholderResult,
      }
      const info: TopicListInfo | null = parseAppUserTopicList(
        placeholderPage, new Set<string>(), [], 1)
      expect(info).not().assertNull()
      const pInfo = info as TopicListInfo
      expect(pInfo.threadPageList.length).assertEqual(2)
      expect(pInfo.pagination.totalPages).assertEqual(2)
    })

    it('usesServerTotalPageWhenPresent', 0, () => {
      // 服务端返回 totalPage 时以其为权威总页数（鸿蒙端实测形态：字段在 result 内）
      const data: Object[] = [createTopicItem(44627932)]
      const result: Record<string, Object> = {
        'data': data,
        'totalPage': '23',
        'total': '776',
        'currentPage': 1,
        'perPage': 35,
      }
      const response: Record<string, Object> = {
        'code': 0,
        'result': result,
      }
      const info: TopicListInfo | null = parseAppUserTopicList(response, new Set<string>(), [], 1)
      expect(info).not().assertNull()
      const pInfo = info as TopicListInfo
      expect(pInfo.threadPageList.length).assertEqual(1)
      expect(pInfo.pagination.totalPages).assertEqual(23)
    })

    it('usesTopLevelTotalPageWhenPresent', 0, () => {
      // 服务端返回 totalPage 的另一种实测形态：分页字段在响应顶层（与 result 平级），
      // result 仅含 data。此形态曾导致权威 totalPage 恒被忽略（P0 回归用例）。
      const data: Object[] = [createTopicItem(44627932)]
      const result: Record<string, Object> = {
        'data': data,
      }
      const response: Record<string, Object> = {
        'code': 0,
        'result': result,
        'totalPage': 23,
        'total': 776,
        'currentPage': 1,
        'perPage': 35,
      }
      const info: TopicListInfo | null = parseAppUserTopicList(response, new Set<string>(), [], 1)
      expect(info).not().assertNull()
      const pInfo = info as TopicListInfo
      expect(pInfo.threadPageList.length).assertEqual(1)
      expect(pInfo.pagination.totalPages).assertEqual(23)
    })

    it('capsSinglePageEndpointAtPageOne', 0, () => {
      // 不分页接口（load_topic_by_uid，maxPage=1）：第 1 页即到底，不诱导翻页
      const data: Object[] = [createTopicItem(44627932), createTopicItem(44622035)]
      const response: Record<string, Object> = {
        'code': 0,
        'result': data,
      }
      const info: TopicListInfo | null = parseAppUserTopicList(
        response, new Set<string>(), [], 1, 1)
      expect(info).not().assertNull()
      const pInfo = info as TopicListInfo
      expect(pInfo.threadPageList.length).assertEqual(2)
      expect(pInfo.pagination.totalPages).assertEqual(1)
    })

    it('returnsNullOnBusinessFailureOnAnyPage', 0, () => {
      // 业务失败（code!=0）在翻页时也必须返回 null 走错误态，不得伪装"已到底"
      const failed: Record<string, Object> = {
        'code': 15,
        'msg': '签名错误',
      }
      expect(parseAppUserTopicList(failed, new Set<string>(), [], 3)).assertNull()
      const failedData: Object[] = [createTopicItem(44627932)]
      const failedResult: Record<string, Object> = {
        'data': failedData,
      }
      const failedWithData: Record<string, Object> = {
        'code': 15,
        'result': failedResult,
      }
      expect(parseAppUserTopicList(failedWithData, new Set<string>(), [], 2)).assertNull()
    })

    it('normalizesEmptyPostDateString', 0, () => {
      // replys 的 post.postdate 可能为字符串空串：归一化必须归 0，不得透传空串
      const item: Record<string, Object> = createTopicItem(44627932)
      const post: Record<string, Object> = {
        'tid': 44627932,
        'pid': 878386616,
        'authorid': 65155718,
        'type': 0,
        'postdate': '',
        'subject': '',
        'content': '回帖内容',
      }
      item['post'] = post
      const normalized = normalizeAppUserTopicItem(item)
      const p = normalized['__P'] as Record<string, Object> | undefined
      expect(p).not().assertUndefined()
      expect(Number(p?.['postdate'] ?? -1)).assertEqual(0)
    })

    it('treatsUnknownShapeAsEndOnPaging', 0, () => {
      // 第 1 页形状不可识别：返回 null（调用方尝试兜底接口）
      const badPage1: Record<string, Object> = {
        'code': 0,
        'result': 'not-an-object',
      }
      expect(parseAppUserTopicList(badPage1, new Set<string>(), [], 1)).assertNull()
      // 翻页请求形状不可识别（服务端越界形态）：视为已到底，不报错
      const badPage2: Record<string, Object> = {
        'code': 0,
        'result': 'not-an-object',
      }
      const info: TopicListInfo | null = parseAppUserTopicList(
        badPage2, new Set<string>(), [], 5)
      expect(info).not().assertNull()
      const pInfo = info as TopicListInfo
      expect(pInfo.threadPageList.length).assertEqual(0)
      expect(pInfo.pagination.totalPages).assertEqual(5)
    })

    it('exposesEndpointPriority', 0, () => {
      const replyEndpoints: AppUserListEndpoint[] = appUserListEndpoints(true)
      expect(replyEndpoints.length).assertEqual(1)
      expect(replyEndpoints[0].lib).assertEqual('user')
      expect(replyEndpoints[0].act).assertEqual('replys')
      expect(replyEndpoints[0].maxPage).assertEqual(0)
      const topicEndpoints: AppUserListEndpoint[] = appUserListEndpoints(false)
      expect(topicEndpoints.length).assertEqual(2)
      expect(topicEndpoints[0].lib).assertEqual('user')
      expect(topicEndpoints[0].act).assertEqual('subjects')
      expect(topicEndpoints[0].maxPage).assertEqual(0)
      expect(topicEndpoints[1].lib).assertEqual('load_topic')
      expect(topicEndpoints[1].act).assertEqual('load_topic_by_uid')
      expect(topicEndpoints[1].maxPage).assertEqual(1)
    })
  })
}
