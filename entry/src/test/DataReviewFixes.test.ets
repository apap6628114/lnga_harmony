import { describe, expect, it } from '@ohos/hypium'
import { DomainIds, PersistenceCatalog } from '../main/ets/common/persistence/PersistenceCatalog'
import { DomainSpec, PersistenceMeta, isDomainOversized, DOMAIN_SIZE_WARN_BYTES } from '../main/ets/common/persistence/PersistenceTypes'
import {
  convertDomainValues,
  LegacyValue,
  MigrationContext,
  MigrationConvertResult
} from '../main/ets/common/persistence/DomainMigrators'
import { normalizeMeta } from '../main/ets/common/persistence/PersistenceMetaStore'
import {
  DraftFilterResult,
  DraftPortabilityResult,
  filterDraftsForAccount,
  makeDraftsPortable
} from '../main/ets/common/transfer/DraftPortability'
import {
  FileDomainWritePlan,
  planFileDomainWrites
} from '../main/ets/common/transfer/DataTransferService'
import { draftUidPart } from '../main/ets/common/utils/DraftKeyUtils'

/**
 * 独立评审（REVIEW_CODE / REVIEW_REQUIREMENTS / REVIEW_ADVERSARIAL）后修复项的回归测试。
 *
 * 覆盖：
 * A. `filterDraftsForAccount`：本机/备份草稿只保留当前账号（评审 R-A01 草稿跨账号外带）；
 * B. `makeDraftsPortable`：media 原位清空、保持字段顺序（评审 R-C05「内容相同判无变化」）；
 * C. `planFileDomainWrites`：纯函数不修改入参（评审 R-A08）；
 * D. `convertDomainValues` 的 `legacyRetained` 置位：可重试跳过置位、不可重试不置位（评审 R-C03）；
 * E. `normalizeMeta`：旧 meta 缺失新字段安全兜底、`legacyRetained` 解析、`transferHistory`
 *    未知类型丢弃与上限截断（评审 R-C04）。
 *
 * 全部为纯逻辑用例，不触发 cryptoFramework / 文件 IO。
 */
function requireSpec(domainId: string): DomainSpec {
  const spec: DomainSpec | null = PersistenceCatalog.byId(domainId)
  if (spec === null) {
    throw new Error('域未登记：' + domainId)
  }
  return spec
}

/**
 * 构造一条草稿记录（key/content/media）。
 *
 * @param key - 草稿键
 * @param mediaCount - 媒体条目数
 * @returns 草稿记录
 */
function makeDraft(key: string, mediaCount: number): Record<string, Object> {
  const draft: Record<string, Object> = {}
  draft['key'] = key
  draft['content'] = 'body'
  const media: Object[] = []
  for (let i: number = 0; i < mediaCount; i++) {
    const item: Record<string, Object> = {}
    item['localPath'] = '/files/draft_media/' + String(i)
    media.push(item)
  }
  draft['media'] = media
  return draft
}

export default function dataReviewFixesTest(): void {
  describe('dataReviewFixes', (): void => {
    // ================= A. 草稿按账号过滤（R-A01） =================

    it('filtersDraftsOfOtherAccounts', 0, (): void => {
      const uidPart: string = draftUidPart('u1')
      const list: Object[] = []
      list.push(makeDraft('draft_1_edit_2_' + uidPart, 0))
      list.push(makeDraft('draft_1_edit_2_oldhash', 0))
      list.push(makeDraft('draft_2_newtopic_3_another', 0))

      const filtered: DraftFilterResult = filterDraftsForAccount(list, 'u1')
      const kept: Object[] = filtered.payload as Object[]
      expect(kept.length).assertEqual(1)
      expect(filtered.filtered).assertEqual(2)
      // 入参未被修改（过滤是纯函数）
      expect(list.length).assertEqual(3)
      const keptDraft: Record<string, Object> = kept[0] as Record<string, Object>
      expect(String(keptDraft['key'])).assertEqual('draft_1_edit_2_' + uidPart)

      // 未登录：只保留 anon 尾
      const anonList: Object[] = []
      anonList.push(makeDraft('draft_1_edit_2_anon', 0))
      anonList.push(makeDraft('draft_1_edit_2_' + uidPart, 0))
      const anonFiltered: DraftFilterResult = filterDraftsForAccount(anonList, '')
      expect((anonFiltered.payload as Object[]).length).assertEqual(1)
      expect(anonFiltered.filtered).assertEqual(1)

      // 非数组载荷原样返回
      const notArray: Object = new Object()
      expect(filterDraftsForAccount(notArray, 'u1').payload === notArray).assertTrue()
    })

    // ================= B. 草稿媒体清空保持字段顺序（R-C05） =================

    it('stripsDraftsMediaKeepingFieldOrder', 0, (): void => {
      const draft: Record<string, Object> = makeDraft('draft_1_edit_2_abc', 2)
      const input: Object[] = [draft]
      const ported: DraftPortabilityResult = makeDraftsPortable(input)
      const outList: Object[] = ported.payload as Object[]
      expect(outList.length).assertEqual(1)
      const outDraft: Record<string, Object> = outList[0] as Record<string, Object>
      const keys: string[] = Object.keys(outDraft)
      // 字段顺序保持（key → content → media），media 原位清空：这是"内容相同判无变化"的前提
      expect(keys[0]).assertEqual('key')
      expect(keys[1]).assertEqual('content')
      expect(keys[2]).assertEqual('media')
      expect((outDraft['media'] as Object[]).length).assertEqual(0)
      expect(ported.strippedDrafts).assertEqual(1)
      expect(ported.strippedMedia).assertEqual(2)
      // 入参未被修改
      expect((draft['media'] as Object[]).length).assertEqual(2)

      // 旧草稿没有 media 字段：补空数组（保持可被 DraftStore 读取）
      const legacyDraft: Record<string, Object> = {}
      legacyDraft['key'] = 'draft_9_edit_1_abc'
      legacyDraft['content'] = 'x'
      const legacyPorted: DraftPortabilityResult = makeDraftsPortable([legacyDraft])
      const legacyOut: Record<string, Object> =
        (legacyPorted.payload as Object[])[0] as Record<string, Object>
      expect((legacyOut['media'] as Object[]).length).assertEqual(0)
      expect(legacyPorted.strippedMedia).assertEqual(0)
    })

    // ================= C. 文件域写入计划不修改入参（R-A08） =================

    it('plansFileWritesWithoutMutatingInput', 0, (): void => {
      const spec: DomainSpec = requireSpec(DomainIds.DRAFTS)
      const item: Record<string, Object> = makeDraft('draft_1_edit_2_oldhash', 0)
      const payload: Object[] = [item]
      const writePlan: FileDomainWritePlan = planFileDomainWrites(spec, payload, 'u1')
      expect(writePlan.writes.length).assertEqual(1)
      expect(writePlan.failed).assertEqual(0)
      // 入参 key 保持原值（纯函数不得原地改写调用方数据）
      expect(String(item['key'])).assertEqual('draft_1_edit_2_oldhash')
      // 文件名与内容中的 key 使用改写后的当前账号片段
      const expectedKey: string = 'draft_1_edit_2_' + draftUidPart('u1')
      expect(writePlan.writes[0].name).assertEqual(expectedKey + '.json')
      expect(writePlan.writes[0].content.indexOf(expectedKey) >= 0).assertTrue()
    })

    // ================= D. legacyRetained 置位（R-C03） =================

    it('marksRetryableSkipsAsLegacyRetained', 0, (): void => {
      const ctx: MigrationContext = new MigrationContext('3', 1000)
      // settings：多份旧键且无当前账号匹配 → 可重试（登录后重试）
      const settingsValues: LegacyValue[] = []
      const settingsA: Record<string, Object> = {}
      settingsA['fontSize'] = 1
      settingsValues.push(new LegacyValue('settings_1', '1', settingsA))
      const settingsB: Record<string, Object> = {}
      settingsB['fontSize'] = 2
      settingsValues.push(new LegacyValue('settings_2', '2', settingsB))
      const settingsResult: MigrationConvertResult =
        convertDomainValues(DomainIds.SETTINGS, settingsValues, ctx)
      expect(settingsResult.ok).assertFalse()
      expect(settingsResult.skippedReason.length > 0).assertTrue()
      expect(settingsResult.legacyRetained).assertTrue()

      // 账号镜像域：旧缓存不属于当前账号 → 可重试
      const mirrorValues: LegacyValue[] = []
      const mirrorValue: Record<string, Object> = {}
      mirrorValue['items'] = []
      mirrorValues.push(new LegacyValue('cached_notifications_1', '1', mirrorValue))
      const mirrorResult: MigrationConvertResult =
        convertDomainValues(DomainIds.NOTIFICATIONS, mirrorValues, ctx)
      expect(mirrorResult.ok).assertFalse()
      expect(mirrorResult.legacyRetained).assertTrue()

      // 收藏关系：无当前账号旧值 → 可重试
      const favValues: LegacyValue[] = []
      const favValue: Record<string, Object> = {}
      favValue['favoredFolderIds'] = []
      favValues.push(new LegacyValue('favorite_topic_membership_v1_1', '1', favValue))
      const favResult: MigrationConvertResult =
        convertDomainValues(DomainIds.FAVORITE_MEMBERSHIP, favValues, ctx)
      expect(favResult.ok).assertFalse()
      expect(favResult.legacyRetained).assertTrue()

      // 反例：uid 匹配但结构非法 → 不可重试，不应计入"升级未完成"警示
      const matchedCtx: MigrationContext = new MigrationContext('1', 1000)
      const badValues: LegacyValue[] = []
      badValues.push(new LegacyValue('favorite_topic_membership_v1_1', '1', []))
      const badResult: MigrationConvertResult =
        convertDomainValues(DomainIds.FAVORITE_MEMBERSHIP, badValues, matchedCtx)
      expect(badResult.ok).assertFalse()
      expect(badResult.skippedReason.indexOf('结构非法') >= 0).assertTrue()
      expect(badResult.legacyRetained).assertFalse()
    })

    // ================= F. 4MB 阈值纯函数（R-D08） =================

    it('flagsOversizedDomainsByByteThreshold', 0, (): void => {
      expect(isDomainOversized(0)).assertFalse()
      expect(isDomainOversized(DOMAIN_SIZE_WARN_BYTES)).assertFalse()
      // 严格大于阈值才告警（与"超过 4MB"文案一致）
      expect(isDomainOversized(DOMAIN_SIZE_WARN_BYTES + 1)).assertTrue()
    })

    // ================= E. meta 反序列化（R-C04） =================

    it('normalizesLegacyRetainedAndTransferHistory', 0, (): void => {
      const raw: Record<string, Object> = {}
      raw['dataVersion'] = 2
      const migrationRecord: Record<string, Object> = {}
      migrationRecord['status'] = 'completed'
      const domains: Object[] = []
      const domainRecord: Record<string, Object> = {}
      domainRecord['domain'] = 'settings'
      domainRecord['status'] = 'skipped'
      domainRecord['reason'] = '多账号设置旧键且无当前账号匹配'
      domainRecord['legacyRetained'] = true
      domains.push(domainRecord)
      migrationRecord['domains'] = domains
      raw['migration'] = migrationRecord

      const history: Object[] = []
      const goodEntry: Record<string, Object> = {}
      goodEntry['kind'] = 'import'
      goodEntry['at'] = 123
      goodEntry['domainCount'] = 3
      goodEntry['ok'] = true
      history.push(goodEntry)
      // 未知类型应被丢弃
      const badEntry: Record<string, Object> = {}
      badEntry['kind'] = 'unknown'
      history.push(badEntry)
      raw['transferHistory'] = history

      const meta: PersistenceMeta = normalizeMeta(raw)
      expect(meta.migration.domains.length).assertEqual(1)
      expect(meta.migration.domains[0].legacyRetained).assertTrue()
      expect(meta.migration.status).assertEqual('completed')
      expect(meta.transferHistory.length).assertEqual(1)
      expect(meta.transferHistory[0].kind).assertEqual('import')
      expect(meta.transferHistory[0].domainCount).assertEqual(3)

      // 旧 meta 完全没有新字段：安全兜底，不因缺字段崩溃/误报
      const legacyRaw: Record<string, Object> = {}
      legacyRaw['dataVersion'] = 1
      const legacyMeta: PersistenceMeta = normalizeMeta(legacyRaw)
      expect(legacyMeta.transferHistory.length).assertEqual(0)
      expect(legacyMeta.migration.domains.length).assertEqual(0)

      // 历史超过上限：截断到 TRANSFER_HISTORY_MAX
      const many: Object[] = []
      for (let i: number = 0; i < 15; i++) {
        const entry: Record<string, Object> = {}
        entry['kind'] = 'export'
        entry['at'] = i
        many.push(entry)
      }
      const cappedRaw: Record<string, Object> = {}
      cappedRaw['transferHistory'] = many
      expect(normalizeMeta(cappedRaw).transferHistory.length).assertEqual(10)
    })
  })
}
