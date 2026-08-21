import { describe, expect, it } from '@ohos/hypium'
import {
  extractFavoriteError,
  extractFavoriteFolderId,
  parseFavoriteTopicFolders,
  parseForumFavoriteBoards
} from '../main/ets/parser/FavoriteParser'
import { FavoriteMembershipState } from '../main/ets/model/Favorite'
import type { FavoriteTopicFolder } from '../main/ets/model/Favorite'
import type { FavBoardItem } from '../main/ets/model/NgaApiResults'
import { FavoriteStore } from '../main/ets/store/FavoriteStore'
import { AuthState } from '../main/ets/store/AuthStore'
import { PreferencesStore } from '../main/ets/common/infra/PreferencesStore'
import { SerialQueue } from '../main/ets/common/infra/SerialQueue'
import { AuthScope } from '../main/ets/store/AuthScope'
import { PageScope } from '../main/ets/common/concurrency/PageScope'

/**
 * 暴露收藏 Store 代际以验证账号重新初始化会使旧回调失效。
 */
class FavoriteStoreProbe extends FavoriteStore {
  /**
   * 返回当前 Store 代际。
   *
   * @returns 当前代际
   */
  getGenerationForTest(): number {
    return this.generationGuard.current()
  }
}

/**
 * 注册主题收藏夹解析单元测试。
 *
 * fixtures 来自官方 APP 签名接口实测（topic_favor_v2.list_folder __output=12
 * 的 {code:"0",result:[{id,type,name,bytes,length,default}]} 形状；字段均为
 * 字符串；new_folder __output=14 的 {code:"0",result:["操作成功",<ID>]} 形状）。
 */
export default function favoriteUnitTest(): void {
  describe('favoriteParser', (): void => {
    it('parsesOfficialFolderListAndSortsDefaultFirst', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":"0","result":[' +
          '{"id":"8","type":"2","name":"攻略","bytes":"144","length":"12"},' +
          '{"id":"3","type":"0","name":"默认收藏","bytes":"0","length":"4","default":"1"}' +
          ']}')
      const folders: FavoriteTopicFolder[] = parseFavoriteTopicFolders(raw)
      expect(folders.length).assertEqual(2)
      expect(folders[0].id).assertEqual('3')
      expect(folders[0].isDefault).assertTrue()
      expect(folders[0].topicCount).assertEqual(4)
      expect(folders[1].id).assertEqual('8')
      expect(folders[1].name).assertEqual('攻略')
      expect(folders[1].isDefault).assertFalse()
      expect(folders[1].topicCount).assertEqual(12)
    })

    it('acceptsNumericFolderIds', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":"0","result":[{"id":16270236,"type":"0","name":"稍后阅读","length":2}]}')
      const folders: FavoriteTopicFolder[] = parseFavoriteTopicFolders(raw)
      expect(folders.length).assertEqual(1)
      expect(folders[0].id).assertEqual('16270236')
      expect(folders[0].isDefault).assertFalse()
    })

    it('skipsEntryWithoutId', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":"0","result":[{"name":"NoId"},{"id":"3","name":"默认收藏"}]}')
      const folders: FavoriteTopicFolder[] = parseFavoriteTopicFolders(raw)
      expect(folders.length).assertEqual(1)
      expect(folders[0].id).assertEqual('3')
    })

    it('parsesOutput14NestedResultShape', 0, (): void => {
      // 官方老封装 __output=14：result 数组套数组 [[{...}],"0"]
      const raw: object = JSON.parse(
        '{"code":"0","result":[[' +
          '{"id":"8","name":"攻略","length":"1"},' +
          '{"id":"3","name":"默认收藏","default":"1"}' +
          '],"0"]}')
      const folders: FavoriteTopicFolder[] = parseFavoriteTopicFolders(raw)
      expect(folders.length).assertEqual(2)
      expect(folders[0].id).assertEqual('3')
      expect(folders[0].isDefault).assertTrue()
    })

    it('returnsEmptyListForEmptyResult', 0, (): void => {
      const raw: object = JSON.parse('{"code":"0","result":[]}')
      const folders: FavoriteTopicFolder[] = parseFavoriteTopicFolders(raw)
      expect(folders.length).assertEqual(0)
    })

    it('returnsEmptyListForMissingResult', 0, (): void => {
      const folders: FavoriteTopicFolder[] = parseFavoriteTopicFolders(JSON.parse('{}'))
      expect(folders.length).assertEqual(0)
    })

    it('returnsEmptyListForBusinessFailure', 0, (): void => {
      const raw: object = JSON.parse('{"code":"1","msg":"参数错误"}')
      const folders: FavoriteTopicFolder[] = parseFavoriteTopicFolders(raw)
      expect(folders.length).assertEqual(0)
    })

    it('returnsEmptyListForMalformedPayload', 0, (): void => {
      const raw: object = JSON.parse('{"code":"0","result":"invalid"}')
      const folders: FavoriteTopicFolder[] = parseFavoriteTopicFolders(raw)
      expect(folders.length).assertEqual(0)
    })

    it('normalizesInvalidTopicCount', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":"0","result":[' +
          '{"id":"3","name":"默认收藏","length":"invalid","default":"1"},' +
          '{"id":"8","name":"攻略","length":"-2"}' +
          ']}')
      const folders: FavoriteTopicFolder[] = parseFavoriteTopicFolders(raw)
      expect(folders[0].topicCount).assertEqual(0)
      expect(folders[1].topicCount).assertEqual(0)
    })

    it('treatsNonNumericDefaultAsNotDefault', 0, (): void => {
      // default 为非法字符串时不得误判为默认夹
      const raw: object = JSON.parse(
        '{"code":"0","result":[{"id":"3","name":"默认收藏","default":"abc"}]}')
      const folders: FavoriteTopicFolder[] = parseFavoriteTopicFolders(raw)
      expect(folders.length).assertEqual(1)
      expect(folders[0].isDefault).assertFalse()
    })

    it('treatsStringZeroDefaultAsNotDefault', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":"0","result":[{"id":"3","name":"默认收藏","default":"0"},' +
          '{"id":"8","name":"攻略","length":"0"}]}')
      const folders: FavoriteTopicFolder[] = parseFavoriteTopicFolders(raw)
      expect(folders[0].id).assertEqual('3')
      expect(folders[0].isDefault).assertFalse()
      expect(folders[1].isDefault).assertFalse()
      expect(folders[1].topicCount).assertEqual(0)
    })
  })

  describe('favoriteFolderIdExtraction', (): void => {
    it('extractsNumericIdFromNewFolderResult', 0, (): void => {
      const raw: object = JSON.parse('{"code":"0","result":["操作成功",16270236]}')
      expect(extractFavoriteFolderId(raw)).assertEqual('16270236')
    })

    it('extractsStringIdFromNewFolderResult', 0, (): void => {
      const raw: object = JSON.parse('{"code":"0","result":["操作成功","42"]}')
      expect(extractFavoriteFolderId(raw)).assertEqual('42')
    })

    it('extractsIdFromObjectResult', 0, (): void => {
      const raw: object = JSON.parse('{"code":"0","result":{"id":"7"}}')
      expect(extractFavoriteFolderId(raw)).assertEqual('7')
    })

    it('extractsIdFromFolderEntryResult', 0, (): void => {
      const raw: object = JSON.parse('{"code":"0","result":[{"id":"9","name":"x"}]}')
      expect(extractFavoriteFolderId(raw)).assertEqual('9')
    })

    it('extractsBareNumericResult', 0, (): void => {
      const raw: object = JSON.parse('{"code":"0","result":16270236}')
      expect(extractFavoriteFolderId(raw)).assertEqual('16270236')
    })

    it('extractsBareNumericStringResult', 0, (): void => {
      const raw: object = JSON.parse('{"code":"0","result":"42"}')
      expect(extractFavoriteFolderId(raw)).assertEqual('42')
    })

    it('skipsNonNumericObjectKeys', 0, (): void => {
      // 对象数字键回退仅接受纯数字值：文案键不得被当作 ID
      const raw: object = JSON.parse('{"code":"0","result":{"0":"操作成功","1":"123"}}')
      expect(extractFavoriteFolderId(raw)).assertEqual('123')
      const textOnly: object = JSON.parse('{"code":"0","result":{"0":"操作成功"}}')
      expect(extractFavoriteFolderId(textOnly)).assertEqual('')
    })

    it('returnsEmptyWhenIdMissing', 0, (): void => {
      const raw: object = JSON.parse('{"code":"0","result":"操作成功"}')
      expect(extractFavoriteFolderId(raw)).assertEqual('')
    })
  })

  describe('favoriteErrorExtraction', (): void => {
    it('returnsNullForSuccess', 0, (): void => {
      const raw: object = JSON.parse('{"code":"0","result":"操作成功"}')
      expect(extractFavoriteError(raw)).assertNull()
    })

    it('returnsMessageForBusinessFailure', 0, (): void => {
      const raw: object = JSON.parse('{"code":"1","msg":"参数错误"}')
      expect(extractFavoriteError(raw)).assertEqual('参数错误')
    })

    it('treatsStringCodeFailure', 0, (): void => {
      // 实测官方 code 为字符串（如 "0"）；字符串非 0 同样按业务失败处理
      const raw: object = JSON.parse('{"code":"1","msg":"操作失败"}')
      expect(extractFavoriteError(raw)).assertEqual('操作失败')
    })

    it('fallsBackToErrorCodeWhenMsgMissing', 0, (): void => {
      const raw: object = JSON.parse('{"code":2}')
      expect(extractFavoriteError(raw)).assertEqual('错误码: 2')
    })

    it('extractsLegacyErrorObject', 0, (): void => {
      const raw: object = JSON.parse('{"error":{"0":"操作失败"}}')
      expect(extractFavoriteError(raw)).assertEqual('操作失败')
    })

    it('extractsLegacyErrorString', 0, (): void => {
      const raw: object = JSON.parse('{"error":"操作失败"}')
      expect(extractFavoriteError(raw)).assertEqual('操作失败')
    })

    it('returnsFailureForParseErrorResponse', 0, (): void => {
      // ngaRequest JSON 解析失败形态（error 为 Error 实例，不可遍历）：
      // 必须先于 error/code 分支识别，否则会被误判为成功
      const raw: object = JSON.parse('{"__parseError":true,"__rawLength":12,"error":{}}')
      expect(extractFavoriteError(raw)).assertEqual('响应解析失败')
    })

    it('returnsNullForMissingShape', 0, (): void => {
      expect(extractFavoriteError(JSON.parse('{}'))).assertNull()
    })
  })

  describe('forumFavoriteBoards', (): void => {
    it('parsesOfficialOutput12Shape', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":[' +
          '{"id":-444012,"fid":-444012,"name":"自行车：我们的骑迹","info":null},' +
          '{"id":843,"fid":843,"name":"国际新闻","info":null}' +
          ']}')
      const boards: FavBoardItem[] = parseForumFavoriteBoards(raw)
      expect(boards.length).assertEqual(2)
      expect(boards[0].fid).assertEqual(-444012)
      expect(boards[0].name).assertEqual('自行车：我们的骑迹')
      expect(boards[1].fid).assertEqual(843)
    })

    it('parsesOfficialOutput14NestedShape', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":[[' +
          '{"id":843,"fid":843,"name":"国际新闻","info":null},' +
          '{"id":-7,"fid":-7,"name":"网事杂谈","info":null}' +
          ']]}')
      const boards: FavBoardItem[] = parseForumFavoriteBoards(raw)
      expect(boards.length).assertEqual(2)
      expect(boards[0].fid).assertEqual(843)
      expect(boards[1].fid).assertEqual(-7)
    })

    it('returnsEmptyListForUnrecognizedShape', 0, (): void => {
      const boards: FavBoardItem[] = parseForumFavoriteBoards(JSON.parse('{"code":0,"result":"invalid"}'))
      expect(boards.length).assertEqual(0)
    })

    it('skipsEntriesWithoutValidFid', 0, (): void => {
      const raw: object = JSON.parse(
        '{"code":0,"result":[{"name":"NoFid"},{"id":843,"fid":843,"name":"国际新闻"}]}')
      const boards: FavBoardItem[] = parseForumFavoriteBoards(raw)
      expect(boards.length).assertEqual(1)
      expect(boards[0].fid).assertEqual(843)
    })
  })

  describe('favoriteStoreMembership', (): void => {
    it('distinguishesUnknownFavoredAndNotFavored', 0, async (): Promise<void> => {
      const store: FavoriteStore = new FavoriteStore()
      const auth: AuthState = new AuthState()
      auth.uid = 'test-user'
      auth.token = 'test-token'
      auth.isAuthenticated = true
      await store.init(new PreferencesStore(), new SerialQueue(), auth)

      expect(store.getTopicFolderState('100', '3')).assertEqual(FavoriteMembershipState.UNKNOWN)
      store.recordTopicMembership('100', '3', true)
      expect(store.getTopicFolderState('100', '3')).assertEqual(FavoriteMembershipState.FAVORED)
      store.recordTopicMembership('100', '3', false)
      expect(store.getTopicFolderState('100', '3')).assertEqual(FavoriteMembershipState.NOT_FAVORED)
    })

    it('doesNotTreatPassiveListRegistrationAsMutation', 0, async (): Promise<void> => {
      const store: FavoriteStore = new FavoriteStore()
      const auth: AuthState = new AuthState()
      auth.uid = 'test-user'
      auth.token = 'test-token'
      auth.isAuthenticated = true
      await store.init(new PreferencesStore(), new SerialQueue(), auth)

      store.recordTopicMemberships(['100', '101'], '3', true)
      expect(store.getFolderMutationVersion('3')).assertEqual(0)
      expect(store.getTopicFolderIds('100').length).assertEqual(1)
      expect(store.getTopicFolderIds('101').length).assertEqual(1)
    })
  })

  describe('favoriteAsyncScope', (): void => {
    it('invalidatesAuthScopeAfterIdentityOrGenerationChange', 0, (): void => {
      const auth: AuthState = new AuthState()
      auth.uid = 'user-a'
      auth.token = 'token-a'
      auth.isAuthenticated = true
      const scope: AuthScope = AuthScope.capture(auth, 1)

      expect(scope.isCurrent(auth, 1)).assertTrue()
      auth.uid = 'user-b'
      auth.token = 'token-b'
      expect(scope.isCurrent(auth, 1)).assertFalse()
      auth.uid = 'user-a'
      auth.token = 'token-a'
      expect(scope.isCurrent(auth, 2)).assertFalse()
    })

    it('invalidatesPageCallbacksAfterDisappearOrNewSession', 0, (): void => {
      const scope: PageScope = new PageScope()
      const firstGeneration: number = scope.begin()
      expect(scope.isActive(firstGeneration)).assertTrue()
      scope.end()
      expect(scope.isActive(firstGeneration)).assertFalse()
      const secondGeneration: number = scope.begin()
      expect(scope.isActive(firstGeneration)).assertFalse()
      expect(scope.isActive(secondGeneration)).assertTrue()
    })

    it('advancesStoreGenerationOnEveryAccountInitialization', 0, async (): Promise<void> => {
      const store: FavoriteStoreProbe = new FavoriteStoreProbe()
      const auth: AuthState = new AuthState()
      auth.uid = 'user-a'
      auth.token = 'token-a'
      auth.isAuthenticated = true
      const preferencesStore: PreferencesStore = new PreferencesStore()
      const queue: SerialQueue = new SerialQueue()

      await store.init(preferencesStore, queue, auth)
      const firstGeneration: number = store.getGenerationForTest()
      auth.uid = 'user-b'
      auth.token = 'token-b'
      await store.init(preferencesStore, queue, auth)
      const secondGeneration: number = store.getGenerationForTest()
      auth.uid = 'user-a'
      auth.token = 'token-a'
      await store.init(preferencesStore, queue, auth)
      const thirdGeneration: number = store.getGenerationForTest()

      expect(secondGeneration > firstGeneration).assertTrue()
      expect(thirdGeneration > secondGeneration).assertTrue()
    })
  })
}
