import { describe, expect, it } from '@ohos/hypium'
import { DomainIds, PersistenceCatalog } from '../main/ets/common/persistence/PersistenceCatalog'
import {
  DomainScope,
  ExportPolicy,
  ImportPolicy,
  PERSISTENCE_KEY_NAMESPACE,
  PERSISTENCE_META_KEY,
  StorageKind
} from '../main/ets/common/persistence/PersistenceTypes'

/**
 * 持久化域注册表单元测试。
 *
 * 覆盖：注册表完整性（唯一性/命名规范）、域分类（scope/存储介质）、导出导入策略、
 * 键命名空间与内部键隔离。这些不变量是"统一治理"的地基，任何新增域都必须通过本套用例。
 */

/**
 * 注册持久化注册表单元测试。
 */
export default function persistenceCatalogUnitTest(): void {
  describe('persistenceCatalog', (): void => {
    it('passesSelfValidation', 0, (): void => {
      const problems: string[] = PersistenceCatalog.validate()

      expect(problems.length).assertEqual(0)
    })

    it('containsAllRequiredDomains', 0, (): void => {
      const ids: string[] = PersistenceCatalog.ids()
      const required: string[] = [
        DomainIds.AUTH, DomainIds.SESSIONS, DomainIds.SETTINGS, DomainIds.THEME,
        DomainIds.CATEGORIES, DomainIds.PROFILES, DomainIds.NOTIFICATIONS, DomainIds.ACTIVITIES,
        DomainIds.FAVORITE_MEMBERSHIP, DomainIds.HISTORY, DomainIds.READING_PROGRESS,
        DomainIds.TREE_READING_PROGRESS,
        DomainIds.VOTES, DomainIds.POLL_VOTED, DomainIds.TRACKED_THREADS, DomainIds.AI_SESSIONS,
        DomainIds.AI_TOOL_CACHE, DomainIds.DRAFTS, DomainIds.DRAFT_MEDIA, DomainIds.SAVED_THREADS,
        DomainIds.MOVING_PHOTO_CACHE, DomainIds.META
      ]

      expect(ids.length).assertEqual(required.length)
      for (let i: number = 0; i < required.length; i++) {
        expect(ids.indexOf(required[i]) >= 0).assertTrue()
      }
    })

    it('hasNoUidSuffixInPreferenceKeys', 0, (): void => {
      const specs = PersistenceCatalog.byStorage(StorageKind.PREFERENCES)
      for (let i: number = 0; i < specs.length; i++) {
        const key: string = specs[i].fullKey()
        // 取消账号隔离的核心不变量：键里不得出现 uid 占位/拼接痕迹
        expect(key.indexOf('${') < 0).assertTrue()
        expect(key.startsWith(PERSISTENCE_KEY_NAMESPACE)).assertTrue()
      }
    })

    it('reservesMetaKeyExclusively', 0, (): void => {
      const metaSpec = PersistenceCatalog.byId(DomainIds.META)
      const authSpec = PersistenceCatalog.byId(DomainIds.AUTH)

      expect(metaSpec !== null).assertTrue()
      expect(authSpec !== null).assertTrue()
      if (metaSpec !== null && authSpec !== null) {
        expect(metaSpec.fullKey() === PERSISTENCE_META_KEY).assertTrue()
        expect(authSpec.fullKey() === PERSISTENCE_META_KEY).assertFalse()
      }
    })

    it('marksCredentialsNeverExportable', 0, (): void => {
      const authSpec = PersistenceCatalog.byId(DomainIds.AUTH)
      const sessionsSpec = PersistenceCatalog.byId(DomainIds.SESSIONS)

      expect(authSpec !== null).assertTrue()
      expect(sessionsSpec !== null).assertTrue()
      if (authSpec !== null && sessionsSpec !== null) {
        expect(authSpec.exportPolicy === ExportPolicy.NEVER).assertTrue()
        expect(sessionsSpec.exportPolicy === ExportPolicy.NEVER).assertTrue()
        expect(authSpec.importPolicy === ImportPolicy.NEVER).assertTrue()
      }
    })

    it('keepsPrivacySensitiveDomainsOptional', 0, (): void => {
      const aiSessions = PersistenceCatalog.byId(DomainIds.AI_SESSIONS)

      expect(aiSessions !== null).assertTrue()
      if (aiSessions !== null) {
        // AI 对话含隐私内容：默认不勾选导出（调研结论 D2）
        expect(aiSessions.exportPolicy === ExportPolicy.OPTIONAL).assertTrue()
      }
    })

    it('excludesNonPortableDraftMediaFromExport', 0, (): void => {
      const draftMedia = PersistenceCatalog.byId(DomainIds.DRAFT_MEDIA)

      expect(draftMedia !== null).assertTrue()
      if (draftMedia !== null) {
        // 草稿媒体副本体积大且沙箱路径不可移植：不进入导出容器
        expect(draftMedia.exportPolicy === ExportPolicy.NEVER).assertTrue()
      }
    })

    it('classifiesAccountMirrors', 0, (): void => {
      const mirrors = PersistenceCatalog.mirrorDomains()
      const ids: string[] = []
      for (let i: number = 0; i < mirrors.length; i++) {
        expect(mirrors[i].scope === DomainScope.ACCOUNT_MIRROR).assertTrue()
        ids.push(mirrors[i].id)
      }

      expect(ids.indexOf(DomainIds.NOTIFICATIONS) >= 0).assertTrue()
      expect(ids.indexOf(DomainIds.ACTIVITIES) >= 0).assertTrue()
      expect(ids.indexOf(DomainIds.FAVORITE_MEMBERSHIP) >= 0).assertTrue()
      expect(ids.indexOf(DomainIds.TRACKED_THREADS) >= 0).assertFalse()
    })

    it('classifiesDeviceScopedHistoryAsDevice', 0, (): void => {
      const history = PersistenceCatalog.byId(DomainIds.HISTORY)

      expect(history !== null).assertTrue()
      if (history !== null) {
        expect(history.scope === DomainScope.DEVICE).assertTrue()
        expect(history.storage === StorageKind.PREFERENCES).assertTrue()
      }
    })

    it('registersTreeReadingProgressAsDeviceProgressDomain', 0, (): void => {
      const spec = PersistenceCatalog.byId(DomainIds.TREE_READING_PROGRESS)

      expect(spec !== null).assertTrue()
      if (spec !== null) {
        // 与列表阅读进度同口径：设备级、可导出、按键去重合并、可清空
        expect(spec.scope === DomainScope.DEVICE).assertTrue()
        expect(spec.storage === StorageKind.PREFERENCES).assertTrue()
        expect(spec.exportPolicy === ExportPolicy.INCLUDE).assertTrue()
        expect(spec.importPolicy === ImportPolicy.MERGE_BY_KEY).assertTrue()
        expect(spec.clearable).assertTrue()
      }
    })

    it('separatesFileDomainsFromPreferences', 0, (): void => {
      const files = PersistenceCatalog.byStorage(StorageKind.JSON_FILES)
      const ids: string[] = []
      for (let i: number = 0; i < files.length; i++) {
        ids.push(files[i].id)
        expect(files[i].dirName.length > 0).assertTrue()
      }

      expect(ids.indexOf(DomainIds.DRAFTS) >= 0).assertTrue()
      expect(ids.indexOf(DomainIds.SAVED_THREADS) >= 0).assertTrue()
    })

    it('returnsNullForUnknownDomain', 0, (): void => {
      expect(PersistenceCatalog.byId('not-exist') === null).assertTrue()
    })

    it('exposesReasonableStorageLimits', 0, (): void => {
      const all = PersistenceCatalog.all()
      for (let i: number = 0; i < all.length; i++) {
        // 每域声明的条目均值必须为正（数据管理页体积估算依赖）
        expect(all[i].avgItemBytes > 0).assertTrue()
      }
    })
  })
}
