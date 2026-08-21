import { describe, it, expect } from '@ohos/hypium'
import { parseAppUserTopicList } from '../main/ets/parser/AppUserTopicParser'
import type { ThreadPageInfo, TopicListInfo } from '../main/ets/model/Topic'

/**
 * 构造 favor/all（app_api.php）官方响应。
 *
 * 实测形状（2026-08，ngabbs.com，__output=12）：
 * {"code":"0","msg":"操作成功","result":{"data":[{tid,fid,author,authorid,subject,
 *  postdate,lastpost,lastposter,replies,type,forumname,...}]},
 *  "totalPage":"1","total":"9","currentPage":"1","perPage":"35"}
 * - result.data 直接为主题数组（与 app_api.php user/subjects 同构）
 * - 分页字段 totalPage/total/currentPage/perPage 在响应顶层（值可能为 string）
 *
 * @param tids - 主题 ID 列表
 * @param totalPage - 总页数字符串
 * @returns favor/all 响应
 */
function createFavorAllResponse(tids: number[], totalPage: string): Record<string, Object> {
  const data: Object[] = []
  for (let i = 0; i < tids.length; i++) {
    const item: Record<string, Object> = {
      'tid': tids[i],
      'fid': 843,
      'author': 'ShieldCannon',
      'authorid': 67071786,
      'subject': '测试收藏主题标题',
      'postdate': 1758307501,
      'lastpost': 1787217026,
      'lastposter': '树叶砖工',
      'replies': 50,
      'type': 32,
      'forumname': '',
    }
    data.push(item as Object)
  }
  const result: Record<string, Object> = {
    'data': data,
  }
  const response: Record<string, Object> = {
    'code': '0',
    'msg': '操作成功',
    'result': result,
    'totalPage': totalPage,
    'total': '9',
    'currentPage': '1',
    'perPage': '35',
  }
  return response
}

/**
 * 收藏夹内主题列表（app_api.php favor/all）官方接口解析单元测试。
 *
 * 复用 parseAppUserTopicList（与 user/subjects 同构：result.data 数组 +
 * 顶层 totalPage），验证 favor/all 实测形状的字段归一化与分页语义。
 */
export default function appFavoriteTopicUnitTest(): void {
  describe('appFavoriteTopicList', (): void => {
    it('parsesFavorAllOfficialShape', 0, (): void => {
      const raw: object = createFavorAllResponse([44627932, 44625486], '1')
      const info: TopicListInfo | null =
        parseAppUserTopicList(raw, new Set<string>(), [], 1)
      expect(info).not().assertNull()
      const list: TopicListInfo = info as TopicListInfo
      expect(list.threadPageList.length).assertEqual(2)
      expect(list.pagination.totalPages).assertEqual(1)
      const first: ThreadPageInfo = list.threadPageList[0]
      expect(first.tid).assertEqual(44627932)
      expect(first.author).assertEqual('ShieldCannon')
      expect(first.replies).assertEqual(50)
    })

    it('normalizesForumNameIntoBoard', 0, (): void => {
      const raw: object = createFavorAllResponse([44627932], '1')
      const info: TopicListInfo | null =
        parseAppUserTopicList(raw, new Set<string>(), [], 1)
      expect(info).not().assertNull()
      const list: TopicListInfo = info as TopicListInfo
      const first: ThreadPageInfo = list.threadPageList[0]
      // forumname 为空串时归一化为空版面名（board），不构造 parent 对象
      expect(first.board).assertEqual('')
    })

    it('honorsTopLevelTotalPage', 0, (): void => {
      const raw: object = createFavorAllResponse([44627932], '7')
      const info: TopicListInfo | null =
        parseAppUserTopicList(raw, new Set<string>(), [], 1)
      expect(info).not().assertNull()
      const list: TopicListInfo = info as TopicListInfo
      expect(list.pagination.totalPages).assertEqual(7)
    })

    it('returnsNullForBusinessFailure', 0, (): void => {
      const raw: Record<string, Object> = {
        'code': '1',
        'msg': '参数错误',
      }
      const info: TopicListInfo | null =
        parseAppUserTopicList(raw, new Set<string>(), [], 1)
      expect(info).assertNull()
    })

    it('treatsEmptyPageAsEnd', 0, (): void => {
      // 顶层 totalPage 为权威值：空 data 数组 + totalPage=3 → totalPages=3
      const raw: object = createFavorAllResponse([], '3')
      const info: TopicListInfo | null =
        parseAppUserTopicList(raw, new Set<string>(), [], 3)
      expect(info).not().assertNull()
      const list: TopicListInfo = info as TopicListInfo
      expect(list.threadPageList.length).assertEqual(0)
      expect(list.pagination.totalPages).assertEqual(3)
      // 无 totalPage 的真空页：totalPages = page（已到底，不再翻页）
      const emptyResult: Record<string, Object> = {
        'data': [],
      }
      const noTotalPage: Record<string, Object> = {
        'code': 0,
        'result': emptyResult,
      }
      const fallback: TopicListInfo | null =
        parseAppUserTopicList(noTotalPage, new Set<string>(), [], 3)
      expect(fallback).not().assertNull()
      const fallbackList: TopicListInfo = fallback as TopicListInfo
      expect(fallbackList.threadPageList.length).assertEqual(0)
      expect(fallbackList.pagination.totalPages).assertEqual(3)
    })

    it('marksBlacklistedAuthorTopics', 0, (): void => {
      const raw: object = createFavorAllResponse([44627932, 44625486], '1')
      const blacklist: Set<string> = new Set<string>()
      blacklist.add('67071786')
      // parseTopicList 对黑名单作者仅标记 isInBlackList 不过滤（过滤的只有标题关键词）
      const info: TopicListInfo | null =
        parseAppUserTopicList(raw, blacklist, [], 1)
      expect(info).not().assertNull()
      const list: TopicListInfo = info as TopicListInfo
      expect(list.threadPageList.length).assertEqual(2)
      expect(list.threadPageList[0].isInBlackList).assertTrue()
      expect(list.threadPageList[1].isInBlackList).assertTrue()
    })

    it('filtersKeywordMatchedTopics', 0, (): void => {
      const raw: object = createFavorAllResponse([44627932, 44625486], '1')
      // 标题关键词命中「测试」→ 从列表移除
      const info: TopicListInfo | null =
        parseAppUserTopicList(raw, new Set<string>(), ['测试'], 1)
      expect(info).not().assertNull()
      const list: TopicListInfo = info as TopicListInfo
      expect(list.threadPageList.length).assertEqual(0)
    })

    it('keepsTopicsOutsideBlacklistUnmarked', 0, (): void => {
      const raw: Record<string, Object> = createFavorAllResponse([44627932], '1')
      const result: Record<string, Object> = raw['result'] as Record<string, Object>
      const items: Object[] = result['data'] as Object[]
      const first: Record<string, Object> = items[0] as Record<string, Object>
      first['authorid'] = 205511
      const blacklist: Set<string> = new Set<string>()
      blacklist.add('67071786')
      const info: TopicListInfo | null =
        parseAppUserTopicList(raw, blacklist, [], 1)
      expect(info).not().assertNull()
      const list: TopicListInfo = info as TopicListInfo
      expect(list.threadPageList.length).assertEqual(1)
      expect(list.threadPageList[0].isInBlackList).assertFalse()
    })
  })
}
