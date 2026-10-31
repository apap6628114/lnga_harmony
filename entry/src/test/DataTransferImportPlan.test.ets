import { describe, expect, it } from '@ohos/hypium'
import { DomainIds, PersistenceCatalog } from '../main/ets/common/persistence/PersistenceCatalog'
import {
  DomainSpec,
  TransferHistoryEntry,
  TransferHistoryKind,
  TRANSFER_HISTORY_MAX,
  appendTransferHistory
} from '../main/ets/common/persistence/PersistenceTypes'
import { BackupDomainEntry, ImportPlanEntry } from '../main/ets/common/transfer/TransferTypes'
import {
  DomainPreCheckResult,
  FileDomainWrite,
  FileDomainWritePlan,
  mergeDomainImportEntry,
  planFileDomainWrites,
  preEvaluateDomainImport
} from '../main/ets/common/transfer/DataTransferService'
import { DomainUpgradeResult, upgradeDomainPayload } from '../main/ets/common/transfer/DomainUpgraders'
import {
  DraftKeyNormalizeResult,
  DraftPortabilityResult,
  makeDraftsPortable,
  normalizeDraftKeysForAccount
} from '../main/ets/common/transfer/DraftPortability'
import { draftUidPart } from '../main/ets/common/utils/DraftKeyUtils'

/**
 * 导入计划 / 文件域写入 / 草稿可移植化 / 域升级器 / 传输历史 — 纯函数回归测试。
 *
 * 覆盖（task-7）：
 * A. `preEvaluateDomainImport` 策略矩阵：凭证/内部域拒绝、媒体副本硬跳过、账号镜像域的登录态与
 *    来源 ownerUid、未登录草稿跳过、缓存域恢复开关、域 schemaVersion 高/低（低版本走升级器）；
 * B. `mergeDomainImportEntry`：settings 字段+数组并集、theme 整体覆盖、tracked_threads 裸数组
 *    输入归一到 `{items}`、SKIP 缓存域整体覆盖计数、镜像域来源账号未知的 reason 标注；
 * C. `planFileDomainWrites`：草稿键尾部账号片段改写（文件名 = 改写后键 + `.json`，内容 key 同步）、
 *    saved_threads 非法条目计入 failed、非数组载荷空计划；
 * D. `makeDraftsPortable`：清空草稿 media 引用但不修改入参、非数组原样返回；
 * E. `upgradeDomainPayload`：当前无已注册升级规则 → ok=false 且 note 说明原因；
 * F. `appendTransferHistory`：最新在前、超过 `TRANSFER_HISTORY_MAX` 截断。
 *
 * 全部为纯逻辑用例，不触发 cryptoFramework（不涉及 checksum/加密），可在 Local Test 运行。
 */

/**
 * 取域元数据（未登记视为测试环境异常，直接抛错）。
 *
 * @param domainId - 域 ID
 * @returns 域元数据
 */
function requireSpec(domainId: string): DomainSpec {
  const spec: DomainSpec | null = PersistenceCatalog.byId(domainId)
  if (spec === null) {
    throw new Error('域未登记：' + domainId)
  }
  return spec
}

/**
 * 构造备份中的域条目。
 *
 * @param domainId - 域 ID
 * @param schemaVersion - 备份里的域 schema 版本
 * @param payload - 载荷
 * @param ownerUid - 归属账号（仅镜像域有意义）
 * @returns 域条目
 */
function makeIncoming(domainId: string, schemaVersion: number, payload: Object,
  ownerUid: string): BackupDomainEntry {
  const entry: BackupDomainEntry = new BackupDomainEntry()
  entry.id = domainId
  entry.schemaVersion = schemaVersion
  entry.payload = payload
  entry.ownerUid = ownerUid
  return entry
}

/**
 * 构造一条传输历史记录。
 *
 * @param at - 完成时间（毫秒）
 * @returns 历史记录
 */
function makeHistoryEntry(at: number): TransferHistoryEntry {
  const entry: TransferHistoryEntry = new TransferHistoryEntry()
  entry.kind = TransferHistoryKind.IMPORT
  entry.at = at
  entry.ok = true
  entry.note = 'h-' + String(at)
  return entry
}

/**
 * 注册导入计划纯函数回归测试。
 */
export default function dataTransferImportPlanTest(): void {
  describe('dataTransferImportPlan', (): void => {
    // ================= A. preEvaluateDomainImport 策略矩阵 =================

    it('rejectsCredentialAndInternalDomains', 0, (): void => {
      const ids: string[] = [DomainIds.AUTH, DomainIds.SESSIONS, DomainIds.META]
      for (let i: number = 0; i < ids.length; i++) {
        const result: DomainPreCheckResult = preEvaluateDomainImport(
          requireSpec(ids[i]), makeIncoming(ids[i], 1, new Object(), ''), true, 'u1')
        const skip: ImportPlanEntry | null = result.skipEntry
        expect(skip !== null).assertTrue()
        if (skip !== null) {
          expect(skip.willSkip).assertTrue()
          expect(skip.reason.indexOf('不允许导入') >= 0).assertTrue()
        }
      }
    })

    it('rejectsNonPortableMediaDomains', 0, (): void => {
      const ids: string[] = [DomainIds.DRAFT_MEDIA, DomainIds.MOVING_PHOTO_CACHE]
      for (let i: number = 0; i < ids.length; i++) {
        const result: DomainPreCheckResult = preEvaluateDomainImport(
          requireSpec(ids[i]), makeIncoming(ids[i], 1, new Object(), ''), true, 'u1')
        const skip: ImportPlanEntry | null = result.skipEntry
        expect(skip !== null).assertTrue()
        if (skip !== null) {
          expect(skip.willSkip).assertTrue()
          expect(skip.reason.indexOf('不参与导入') >= 0).assertTrue()
        }
      }
    })

    it('handlesAccountMirrorOwnerAndLogin', 0, (): void => {
      const spec: DomainSpec = requireSpec(DomainIds.NOTIFICATIONS)
      const emptyItems: Object[] = []
      const payload: Record<string, Object> = {}
      payload['items'] = emptyItems

      // 未登录：镜像域跳过
      const anonymous: DomainPreCheckResult =
        preEvaluateDomainImport(spec, makeIncoming(DomainIds.NOTIFICATIONS, 1, payload, 'u1'),
          true, '')
      const anonymousSkip: ImportPlanEntry | null = anonymous.skipEntry
      expect(anonymousSkip !== null).assertTrue()
      if (anonymousSkip !== null) {
        expect(anonymousSkip.reason.indexOf('未登录') >= 0).assertTrue()
      }

      // 已登录但来源账号不同：跳过（防跨账号串号）
      const otherOwner: DomainPreCheckResult =
        preEvaluateDomainImport(spec, makeIncoming(DomainIds.NOTIFICATIONS, 1, payload, 'other'),
          true, 'u1')
      const otherSkip: ImportPlanEntry | null = otherOwner.skipEntry
      expect(otherSkip !== null).assertTrue()
      if (otherSkip !== null) {
        expect(otherSkip.reason.indexOf('其他登录账号') >= 0).assertTrue()
      }

      // 已登录且来源账号未知（旧版备份 ownerUid 为空）：不跳过
      const unknownOwner: DomainPreCheckResult =
        preEvaluateDomainImport(spec, makeIncoming(DomainIds.NOTIFICATIONS, 1, payload, ''),
          true, 'u1')
      expect(unknownOwner.skipEntry === null).assertTrue()
    })

    it('requiresLoginForDrafts', 0, (): void => {
      const spec: DomainSpec = requireSpec(DomainIds.DRAFTS)
      const drafts: Object[] = []

      const anonymous: DomainPreCheckResult = preEvaluateDomainImport(
        spec, makeIncoming(DomainIds.DRAFTS, 1, drafts, ''), true, '')
      const skip: ImportPlanEntry | null = anonymous.skipEntry
      expect(skip !== null).assertTrue()
      if (skip !== null) {
        expect(skip.reason.indexOf('未登录') >= 0).assertTrue()
      }

      // 已登录时草稿域不跳过（键改写由 planFileDomainWrites 负责）
      const loggedIn: DomainPreCheckResult = preEvaluateDomainImport(
        spec, makeIncoming(DomainIds.DRAFTS, 1, drafts, ''), true, 'u1')
      expect(loggedIn.skipEntry === null).assertTrue()
    })

    it('followsRestoreCacheDomainsSwitch', 0, (): void => {
      const spec: DomainSpec = requireSpec(DomainIds.CATEGORIES)
      const incoming: BackupDomainEntry = makeIncoming(DomainIds.CATEGORIES, 1, new Object(), '')

      const disabled: DomainPreCheckResult = preEvaluateDomainImport(spec, incoming, false, 'u1')
      const skip: ImportPlanEntry | null = disabled.skipEntry
      expect(skip !== null).assertTrue()
      if (skip !== null) {
        expect(skip.reason.indexOf('缓存类数据') >= 0).assertTrue()
      }

      const enabled: DomainPreCheckResult = preEvaluateDomainImport(spec, incoming, true, 'u1')
      expect(enabled.skipEntry === null).assertTrue()
    })

    it('handlesDomainSchemaVersionBounds', 0, (): void => {
      const spec: DomainSpec = requireSpec(DomainIds.HISTORY)

      // 高于当前版本：直接跳过
      const tooNew: DomainPreCheckResult = preEvaluateDomainImport(
        spec, makeIncoming(DomainIds.HISTORY, 2, new Object(), ''), true, 'u1')
      const tooNewSkip: ImportPlanEntry | null = tooNew.skipEntry
      expect(tooNewSkip !== null).assertTrue()
      if (tooNewSkip !== null) {
        expect(tooNewSkip.reason.indexOf('版本高于') >= 0).assertTrue()
      }

      // 低于当前版本：走升级器；当前无注册规则 → 跳过并给出原因
      const tooOld: DomainPreCheckResult = preEvaluateDomainImport(
        spec, makeIncoming(DomainIds.HISTORY, 0, new Object(), ''), true, 'u1')
      const tooOldSkip: ImportPlanEntry | null = tooOld.skipEntry
      expect(tooOldSkip !== null).assertTrue()
      if (tooOldSkip !== null) {
        expect(tooOldSkip.reason.indexOf('升级规则') >= 0).assertTrue()
      }
    })

    // ================= B. mergeDomainImportEntry =================

    it('mergesSettingsFieldsAndArrayUnion', 0, (): void => {
      const spec: DomainSpec = requireSpec(DomainIds.SETTINGS)

      const localBlacklist: Object[] = []
      const localUser: Record<string, Object> = {}
      localUser['userId'] = '1'
      localBlacklist.push(localUser)
      const local: Record<string, Object> = {}
      local['fontSize'] = 1
      local['blacklist'] = localBlacklist

      const incomingBlacklist: Object[] = []
      const incomingUser: Record<string, Object> = {}
      incomingUser['userId'] = '2'
      incomingBlacklist.push(incomingUser)
      const incomingPayload: Record<string, Object> = {}
      incomingPayload['fontSize'] = 2
      incomingPayload['blacklist'] = incomingBlacklist

      const entry: ImportPlanEntry = mergeDomainImportEntry(
        spec, makeIncoming(DomainIds.SETTINGS, 1, incomingPayload, ''),
        incomingPayload, local)

      expect(entry.willSkip).assertFalse()
      const merged: Record<string, Object> = entry.mergedPayload as Record<string, Object>
      // 标量字段导入值覆盖
      expect(Number(merged['fontSize'])).assertEqual(2)
      // 数组字段按业务键并集（本机 u1 + 导入 u2）
      const blacklist: Object[] = merged['blacklist'] as Object[]
      expect(blacklist.length).assertEqual(2)
      expect(entry.added + entry.updated > 0).assertTrue()
      expect(entry.total).assertEqual(entry.added + entry.updated)
    })

    it('replacesThemePayload', 0, (): void => {
      const spec: DomainSpec = requireSpec(DomainIds.THEME)

      const local: Record<string, Object> = {}
      local['mode'] = 'light'
      const incomingPayload: Record<string, Object> = {}
      incomingPayload['mode'] = 'dark'

      const entry: ImportPlanEntry = mergeDomainImportEntry(
        spec, makeIncoming(DomainIds.THEME, 1, incomingPayload, ''),
        incomingPayload, local)

      expect(entry.willSkip).assertFalse()
      const merged: Record<string, Object> = entry.mergedPayload as Record<string, Object>
      expect(String(merged['mode'])).assertEqual('dark')
      expect(entry.updated).assertEqual(1)
    })

    it('wrapsTrackedThreadsIntoItemsEnvelope', 0, (): void => {
      const spec: DomainSpec = requireSpec(DomainIds.TRACKED_THREADS)

      const tracked: Object[] = []
      const item: Record<string, Object> = {}
      item['tid'] = '1'
      item['lastCheckAt'] = 1
      tracked.push(item)

      const entry: ImportPlanEntry = mergeDomainImportEntry(
        spec, makeIncoming(DomainIds.TRACKED_THREADS, 1, tracked, ''),
        tracked, null)

      expect(entry.willSkip).assertFalse()
      // ENVELOPE 域：裸数组输入也必须归一为 { items: T[] }
      expect(Array.isArray(entry.mergedPayload)).assertFalse()
      const merged: Record<string, Object> = entry.mergedPayload as Record<string, Object>
      const items: Object[] = merged['items'] as Object[]
      expect(Array.isArray(items)).assertTrue()
      expect(items.length).assertEqual(1)
    })

    it('restoresSkipPolicyDomainAsWholePayload', 0, (): void => {
      const spec: DomainSpec = requireSpec(DomainIds.CATEGORIES)

      const itemList: Object[] = []
      const first: Record<string, Object> = {}
      first['a'] = 1
      const second: Record<string, Object> = {}
      second['a'] = 2
      itemList.push(first)
      itemList.push(second)
      const payload: Record<string, Object> = {}
      payload['items'] = itemList

      const entry: ImportPlanEntry = mergeDomainImportEntry(
        spec, makeIncoming(DomainIds.CATEGORIES, 1, payload, ''), payload, null)

      expect(entry.willSkip).assertFalse()
      // SKIP 缓存域整体覆盖：added 展示备份内条目数
      expect(entry.added).assertEqual(2)
      expect(entry.updated).assertEqual(0)
    })

    it('annotatesUnknownMirrorOwner', 0, (): void => {
      const spec: DomainSpec = requireSpec(DomainIds.NOTIFICATIONS)

      const items: Object[] = []
      const payload: Record<string, Object> = {}
      payload['items'] = items

      const entry: ImportPlanEntry = mergeDomainImportEntry(
        spec, makeIncoming(DomainIds.NOTIFICATIONS, 1, payload, ''),
        payload, null)

      expect(entry.willSkip).assertFalse()
      expect(entry.reason.indexOf('来源账号未知') >= 0).assertTrue()
    })

    // ================= C. planFileDomainWrites =================

    it('rewritesDraftKeyAndBuildsFileWrite', 0, (): void => {
      const spec: DomainSpec = requireSpec(DomainIds.DRAFTS)
      const payload: Object[] = []
      const draft: Record<string, Object> = {}
      draft['key'] = 'draft_123_edit_456_abc'
      draft['content'] = 'hello'
      payload.push(draft)

      const plan: FileDomainWritePlan = planFileDomainWrites(spec, payload, 'u1')
      expect(plan.failed).assertEqual(0)
      expect(plan.writes.length).assertEqual(1)

      const write: FileDomainWrite = plan.writes[0]
      // 文件名 = 改写后的草稿键 + .json
      const suffix: string = '.json'
      expect(write.name.substring(write.name.length - suffix.length)).assertEqual(suffix)
      const keyInName: string = write.name.substring(0, write.name.length - suffix.length)
      const expectedKey: string = 'draft_123_edit_456_' + draftUidPart('u1')
      expect(keyInName).assertEqual(expectedKey)

      // 文件内容里的 key 与文件名一致（打开草稿时以此为归属依据）
      const content: Record<string, Object> = JSON.parse(write.content) as Record<string, Object>
      expect(String(content['key'])).assertEqual(keyInName)
      expect(String(content['content'])).assertEqual('hello')
    })

    it('validatesSavedThreadFileWrites', 0, (): void => {
      const spec: DomainSpec = requireSpec(DomainIds.SAVED_THREADS)

      const page: Record<string, Object> = {}
      page['pid'] = '1'
      const pages: Object[] = []
      pages.push(page)

      const valid: Record<string, Object> = {}
      valid['tid'] = '123'
      valid['rawPages'] = pages

      const badTid: Record<string, Object> = {}
      badTid['tid'] = 'abc'
      badTid['rawPages'] = pages

      const emptyPages: Record<string, Object> = {}
      emptyPages['tid'] = '123'
      const noPages: Object[] = []
      emptyPages['rawPages'] = noPages

      const payload: Object[] = []
      payload.push(valid)
      payload.push(badTid)
      payload.push(emptyPages)

      const plan: FileDomainWritePlan = planFileDomainWrites(spec, payload, 'u1')
      expect(plan.writes.length).assertEqual(1)
      expect(plan.failed).assertEqual(2)
      expect(plan.writes[0].name).assertEqual('123.json')
    })

    it('returnsEmptyPlanForNonArrayPayload', 0, (): void => {
      const spec: DomainSpec = requireSpec(DomainIds.DRAFTS)
      const plan: FileDomainWritePlan = planFileDomainWrites(spec, new Object(), 'u1')
      expect(plan.writes.length).assertEqual(0)
      expect(plan.failed).assertEqual(0)
    })

    // ================= D. makeDraftsPortable =================

    it('stripsDraftMediaWithoutMutatingInput', 0, (): void => {
      const media1: Record<string, Object> = {}
      media1['localPath'] = '/x'
      const media2: Record<string, Object> = {}
      media2['localPath'] = '/y'
      const mediaList: Object[] = []
      mediaList.push(media1)
      mediaList.push(media2)

      const draft1: Record<string, Object> = {}
      draft1['key'] = 'k1'
      draft1['content'] = 'body'
      draft1['media'] = mediaList
      const draft2: Record<string, Object> = {}
      draft2['key'] = 'k2'
      const emptyMedia: Object[] = []
      draft2['media'] = emptyMedia

      const payload: Object[] = []
      payload.push(draft1)
      payload.push(draft2)

      const result: DraftPortabilityResult = makeDraftsPortable(payload)
      const portable: Object[] = result.payload as Object[]
      expect(portable.length).assertEqual(2)
      const first: Record<string, Object> = portable[0] as Record<string, Object>
      const firstMedia: Object[] = first['media'] as Object[]
      expect(firstMedia.length).assertEqual(0)
      // 正文与其它字段保留
      expect(String(first['content'])).assertEqual('body')
      expect(result.strippedDrafts).assertEqual(1)
      expect(result.strippedMedia).assertEqual(2)
      // 不修改入参：原草稿 media 仍是 2 条
      const originalMedia: Object[] = draft1['media'] as Object[]
      expect(originalMedia.length).assertEqual(2)
    })

    it('returnsNonArrayDraftPayloadAsIs', 0, (): void => {
      const nonArray: Object = new Object()
      const result: DraftPortabilityResult = makeDraftsPortable(nonArray)
      expect(result.payload === nonArray).assertTrue()
      expect(result.strippedDrafts).assertEqual(0)
      expect(result.strippedMedia).assertEqual(0)
    })

    // ================= E. upgradeDomainPayload =================

    it('rejectsUnregisteredDomainUpgrade', 0, (): void => {
      const payload: Object = new Object()
      const result: DomainUpgradeResult = upgradeDomainPayload(DomainIds.SETTINGS, 0, payload)
      expect(result.ok).assertFalse()
      expect(result.note.length > 0).assertTrue()
      expect(result.note.indexOf('升级规则') >= 0).assertTrue()
      // 失败时原样返回载荷
      expect(result.payload === payload).assertTrue()

      // 当前没有任何域注册了升级规则（提升 DomainSpec.schemaVersion 前必须先注册）
      const versions: number[] = [0, 1]
      const domains: string[] = [DomainIds.SETTINGS, DomainIds.NOTIFICATIONS, DomainIds.HISTORY]
      for (let i: number = 0; i < domains.length; i++) {
        for (let j: number = 0; j < versions.length; j++) {
          const each: DomainUpgradeResult =
            upgradeDomainPayload(domains[i], versions[j], new Object())
          expect(each.ok).assertFalse()
        }
      }
    })

    // ================= F. appendTransferHistory =================

    it('prependsTransferHistory', 0, (): void => {
      const existing: TransferHistoryEntry[] = []
      existing.push(makeHistoryEntry(1))
      existing.push(makeHistoryEntry(2))
      existing.push(makeHistoryEntry(3))
      const latest: TransferHistoryEntry = makeHistoryEntry(99)

      const next: TransferHistoryEntry[] = appendTransferHistory(existing, latest)
      expect(next.length).assertEqual(4)
      expect(next[0] === latest).assertTrue()
      expect(next[1] === existing[0]).assertTrue()
      expect(next[3] === existing[2]).assertTrue()

      // 空历史也能追加
      const fromNull: TransferHistoryEntry[] = appendTransferHistory(null, latest)
      expect(fromNull.length).assertEqual(1)
      expect(fromNull[0] === latest).assertTrue()
    })

    it('truncatesTransferHistoryToLimit', 0, (): void => {
      expect(TRANSFER_HISTORY_MAX).assertEqual(10)

      const existing: TransferHistoryEntry[] = []
      for (let i: number = 0; i < TRANSFER_HISTORY_MAX; i++) {
        existing.push(makeHistoryEntry(100 - i))
      }
      const latest: TransferHistoryEntry = makeHistoryEntry(200)

      const next: TransferHistoryEntry[] = appendTransferHistory(existing, latest)
      expect(next.length).assertEqual(TRANSFER_HISTORY_MAX)
      expect(next[0] === latest).assertTrue()
      // 原第 9 条（1-based，下标 8）成为截断后的最后一条
      expect(next[TRANSFER_HISTORY_MAX - 1] === existing[TRANSFER_HISTORY_MAX - 2]).assertTrue()
    })

    // ================= G. 草稿键归一化（审计 DES-19） =================

    it('normalizesDraftKeysToCurrentAccount', 0, (): void => {
      const oldHash: string = 'oldhash'
      const drafts: Object[] = []
      const first: Record<string, Object> = {}
      first['key'] = 'draft_123_edit_456_' + oldHash
      first['content'] = 'abc'
      drafts.push(first)
      const second: Record<string, Object> = {}
      second['key'] = 'draft_9_newtopic_1_' + oldHash
      second['content'] = 'xyz'
      drafts.push(second)

      const normalized: DraftKeyNormalizeResult = normalizeDraftKeysForAccount(drafts, 'u1')
      expect(normalized.rewritten).assertEqual(2)
      const items: Object[] = normalized.payload as Object[]
      expect(items.length).assertEqual(2)
      const saved: Record<string, Object> = items[0] as Record<string, Object>
      expect(String(saved['key'])).assertEqual('draft_123_edit_456_' + draftUidPart('u1'))
      expect(String(saved['content'])).assertEqual('abc')
      // 不修改入参
      expect(String(first['key'])).assertEqual('draft_123_edit_456_' + oldHash)

      // 已是当前账号：不改写、条目引用保持
      const current: Object[] = []
      const currentRecord: Record<string, Object> = {}
      currentRecord['key'] = 'draft_123_edit_456_' + draftUidPart('u1')
      current.push(currentRecord)
      const unchanged: DraftKeyNormalizeResult = normalizeDraftKeysForAccount(current, 'u1')
      expect(unchanged.rewritten).assertEqual(0)
      const unchangedItems: Object[] = unchanged.payload as Object[]
      expect(unchangedItems[0] === currentRecord).assertTrue()

      // 非数组载荷原样返回
      const notArray: Object = new Object()
      expect(normalizeDraftKeysForAccount(notArray, 'u1').payload === notArray).assertTrue()
    })

    it('treatsRenamedDraftAsUpdateNotAdd', 0, (): void => {
      const spec: DomainSpec = requireSpec(DomainIds.DRAFTS)
      const otherHash: string = 'otherhash'
      // 本机同目标草稿（当前账号键）
      const localDrafts: Object[] = []
      const localRecord: Record<string, Object> = {}
      localRecord['key'] = 'draft_123_edit_456_' + draftUidPart('u1')
      localRecord['content'] = 'old'
      localDrafts.push(localRecord)
      // 备份中同一目标草稿（其他账号键 + 不同内容）
      const incomingDrafts: Object[] = []
      const incomingRecord: Record<string, Object> = {}
      incomingRecord['key'] = 'draft_123_edit_456_' + otherHash
      incomingRecord['content'] = 'new'
      incomingDrafts.push(incomingRecord)
      const pre: DomainPreCheckResult = preEvaluateDomainImport(spec,
        makeIncoming(DomainIds.DRAFTS, 1, incomingDrafts, ''), true, 'u1')
      expect(pre.skipEntry === null).assertTrue()
      const merged: ImportPlanEntry = mergeDomainImportEntry(spec,
        makeIncoming(DomainIds.DRAFTS, 1, incomingDrafts, ''), pre.payload, localDrafts)
      expect(merged.willSkip).assertFalse()
      // 同键按导入值覆盖 → 更新 1 条，而不是新增
      expect(merged.updated).assertEqual(1)
      expect(merged.added).assertEqual(0)

      // 内容完全一致 → 无变化（不会触发写盘）
      const sameLocal: Object[] = []
      const sameRecord: Record<string, Object> = {}
      sameRecord['key'] = 'draft_123_edit_456_' + draftUidPart('u1')
      sameRecord['content'] = 'new'
      sameLocal.push(sameRecord)
      const pre2: DomainPreCheckResult = preEvaluateDomainImport(spec,
        makeIncoming(DomainIds.DRAFTS, 1, incomingDrafts, ''), true, 'u1')
      const merged2: ImportPlanEntry = mergeDomainImportEntry(spec,
        makeIncoming(DomainIds.DRAFTS, 1, incomingDrafts, ''), pre2.payload, sameLocal)
      expect(merged2.added).assertEqual(0)
      expect(merged2.updated).assertEqual(0)
    })
  })
}
