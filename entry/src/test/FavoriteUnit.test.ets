import { describe, expect, it } from '@ohos/hypium'
import { parseFavoriteTopicFolders } from '../main/ets/parser/FavoriteParser'
import { FavoriteMembershipState } from '../main/ets/model/Favorite'
import type { FavoriteTopicFolder } from '../main/ets/model/Favorite'
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
 */
export default function favoriteUnitTest(): void {
  describe('favoriteParser', (): void => {
    it('parsesAndSortsDefaultFolderFirst', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"0":{"8":{"id":"8","name":"攻略","length":12},' +
          '"3":{"id":"3","name":"默认收藏","length":4,"default":1}}}}')
      const folders: FavoriteTopicFolder[] = parseFavoriteTopicFolders(raw)
      expect(folders.length).assertEqual(2)
      expect(folders[0].id).assertEqual('3')
      expect(folders[0].isDefault).assertTrue()
      expect(folders[0].topicCount).assertEqual(4)
      expect(folders[1].name).assertEqual('攻略')
    })

    it('usesContainerKeyWhenFolderIdIsMissing', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"0":{"17":{"name":"稍后阅读","length":2}}}}')
      const folders: FavoriteTopicFolder[] = parseFavoriteTopicFolders(raw)
      expect(folders.length).assertEqual(1)
      expect(folders[0].id).assertEqual('17')
      expect(folders[0].isDefault).assertFalse()
    })

    it('returnsEmptyListForMalformedPayload', 0, (): void => {
      const raw: object = JSON.parse('{"data":{"0":"invalid"}}')
      const folders: FavoriteTopicFolder[] = parseFavoriteTopicFolders(raw)
      expect(folders.length).assertEqual(0)
    })

    it('normalizesInvalidTopicCount', 0, (): void => {
      const raw: object = JSON.parse(
        '{"data":{"0":{"3":{"id":"3","name":"默认收藏","length":"invalid","default":1},' +
          '"8":{"id":"8","name":"攻略","length":-2}}}}')
      const folders: FavoriteTopicFolder[] = parseFavoriteTopicFolders(raw)
      expect(folders[0].topicCount).assertEqual(0)
      expect(folders[1].topicCount).assertEqual(0)
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
