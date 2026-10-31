import { describe, expect, it } from '@ohos/hypium'
import { DomainIds, PersistenceCatalog } from '../main/ets/common/persistence/PersistenceCatalog'
import {
  DomainSpec,
  ExportPolicy,
  ImportPolicy
} from '../main/ets/common/persistence/PersistenceTypes'
import { mergePayload, MergeResult } from '../main/ets/common/transfer/DomainMergers'
import { DataTransferService, ParseOutcome } from '../main/ets/common/transfer/DataTransferService'
import {
  BackupContainer,
  BackupDomainEntry
} from '../main/ets/common/transfer/TransferTypes'

/**
 * 数据「导出 → 导入」容器往返回归测试。
 *
 * 覆盖（对应审计 EXP-01/EXP-02/IMP-01 的闭环门禁）：
 * 1. 容器往返解析：手工构造与导出产物同形的明文容器（16 个可导出域、镜像域带 ownerUid），
 *    `parseBackup` 必须完整解析、不丢域；每个域可被 Catalog 命中、策略不是 NEVER；
 * 2. 每域合并器兼容：16 个可导出域的典型 payload 都能被 `mergePayload` 接受，输出形态符合
 *    域约定（settings/theme 对象；history/reading_progress/drafts/saved_threads 裸数组；
 *    votes/poll_voted 对象；tracked_threads/ai_sessions 强制 `{items}` 信封；缓存域原样透传）；
 * 3. 幂等往返：第一次合并结果同时作为 local 与 incoming 再合并，added/updated 必须为 0，
 *    不允许同一份备份重复导入时条目翻倍；
 * 4. 重复域 ID 去重：只保留首个，重复条目进入 `ParseOutcome.droppedDomains`（原因含「重复」），
 *    不再静默丢弃；
 * 5. 未来容器版本解析宽容：`parseBackup` 只负责解析，`formatVersion=2` 不在解析层拒绝
 *    （版本拒绝由 `buildImportPlan` 负责，跳过测试以保持分层）。
 *
 * ⚠️ Local Test 环境 cryptoFramework 不可用：`parseBackup` 仅在容器 `checksum` 非空时计算
 * SHA-256。因此本套用例构造的容器 **checksum 恒为空串**（走「缺少校验和」的 warning 分支），
 * 禁止构造非空 checksum，也禁止在测试里调用 `exportBackup` / `encryptBackup`。
 *
 * 注册：由 `List.test.ets` 统一注册并调用 `dataTransferRoundTripTest()`（本文件不修改 List）。
 */

/** 镜像域 ownerUid 样本（导出时写入、导入解析应原样保留）。 */
const MIRROR_OWNER_UID: string = 'u1'

/** 可导出域数量（INCLUDE 9 + OPTIONAL 7；NEVER 5 个不出现）。 */
const EXPORTABLE_DOMAIN_COUNT: number = 16

/**
 * 按 Catalog 声明顺序返回 16 个可导出域的 ID。
 *
 * 与 `PersistenceCatalog.exportable()` 的顺序一致：导出容器按声明顺序写入 domains。
 *
 * @returns 域 ID 数组
 */
function exportableIds(): string[] {
  const ids: string[] = []
  ids.push(DomainIds.SETTINGS)
  ids.push(DomainIds.THEME)
  ids.push(DomainIds.CATEGORIES)
  ids.push(DomainIds.PROFILES)
  ids.push(DomainIds.NOTIFICATIONS)
  ids.push(DomainIds.ACTIVITIES)
  ids.push(DomainIds.FAVORITE_MEMBERSHIP)
  ids.push(DomainIds.HISTORY)
  ids.push(DomainIds.READING_PROGRESS)
  ids.push(DomainIds.VOTES)
  ids.push(DomainIds.POLL_VOTED)
  ids.push(DomainIds.TRACKED_THREADS)
  ids.push(DomainIds.AI_SESSIONS)
  ids.push(DomainIds.AI_TOOL_CACHE)
  ids.push(DomainIds.DRAFTS)
  ids.push(DomainIds.SAVED_THREADS)
  return ids
}

/**
 * 构造容器中的一个域条目 JSON（与 `BackupDomainEntry` 导出形状一致）。
 *
 * @param id - 域 ID
 * @param payloadJson - 已序列化的 payload JSON 文本
 * @param ownerUid - 镜像域来源账号（非镜像域传空串，输出中省略该字段）
 * @returns 域条目 JSON 文本
 */
function makeDomainJson(id: string, payloadJson: string, ownerUid: string): string {
  let text: string = '{"id":"' + id + '","label":"' + id + '","schemaVersion":1,"updatedAt":0'
  if (ownerUid.length > 0) {
    text += ',"ownerUid":"' + ownerUid + '"'
  }
  text += ',"payload":' + payloadJson + '}'
  return text
}

/**
 * 构造覆盖全部 16 个可导出域的合法明文容器 JSON 文本。
 *
 * 每个域给最小合法形状；镜像域写 ownerUid 供「归属保留」断言使用；
 * `checksum` 为空串（避免 Local Test 触发 cryptoFramework 的 SHA-256）。
 *
 * @returns 容器 JSON 文本
 */
function buildFullContainerText(): string {
  const entries: string[] = []
  entries.push(makeDomainJson(DomainIds.SETTINGS, '{}', ''))
  entries.push(makeDomainJson(DomainIds.THEME, '{"mode":"system"}', ''))
  entries.push(makeDomainJson(DomainIds.CATEGORIES, '{}', ''))
  entries.push(makeDomainJson(DomainIds.PROFILES, '{}', ''))
  entries.push(makeDomainJson(DomainIds.NOTIFICATIONS, '{"items":[]}', MIRROR_OWNER_UID))
  entries.push(makeDomainJson(DomainIds.ACTIVITIES, '{"items":[]}', MIRROR_OWNER_UID))
  entries.push(makeDomainJson(DomainIds.FAVORITE_MEMBERSHIP,
    '{"favoredFolderIds":[],"knownFolderIds":[]}', MIRROR_OWNER_UID))
  entries.push(makeDomainJson(DomainIds.HISTORY, '[]', ''))
  entries.push(makeDomainJson(DomainIds.READING_PROGRESS, '[]', ''))
  entries.push(makeDomainJson(DomainIds.VOTES, '{}', ''))
  entries.push(makeDomainJson(DomainIds.POLL_VOTED, '{}', ''))
  entries.push(makeDomainJson(DomainIds.TRACKED_THREADS, '{"items":[]}', ''))
  entries.push(makeDomainJson(DomainIds.AI_SESSIONS, '{"items":[]}', ''))
  entries.push(makeDomainJson(DomainIds.AI_TOOL_CACHE, '{"items":[]}', ''))
  entries.push(makeDomainJson(DomainIds.DRAFTS, '[]', ''))
  entries.push(makeDomainJson(DomainIds.SAVED_THREADS, '[]', ''))
  let text: string = '{"magic":"NGA_OH_BACKUP","formatVersion":1,"dataVersion":2,'
  text += '"exportedAt":1730000000000,"appVersionName":"1.2.0","appVersionCode":1020000,'
  text += '"deviceTag":"phone","domains":['
  for (let i: number = 0; i < entries.length; i++) {
    if (i > 0) {
      text += ','
    }
    text += entries[i]
  }
  text += '],"checksum":""}'
  return text
}

/**
 * 在解析结果里按域 ID 查找域条目。
 *
 * @param container - 已解析容器
 * @param domainId - 域 ID
 * @returns 域条目；不存在返回 null
 */
function findDomainEntry(container: BackupContainer, domainId: string): BackupDomainEntry | null {
  for (let i: number = 0; i < container.domains.length; i++) {
    if (container.domains[i].id === domainId) {
      return container.domains[i]
    }
  }
  return null
}

/**
 * 判断值是否为非 null 的对象（用于断言合并不返回 null）。
 *
 * @param value - 待判断值
 * @returns 是否非 null
 */
function isPresentObject(value: Object | null): boolean {
  return value !== null
}

/**
 * 从 `{items: T[]}` 信封形态的 payload 中取条目数组（形态非法返回 null）。
 *
 * @param payload - 域 payload
 * @returns 条目数组；非信封形态返回 null
 */
function readItemsField(payload: Object): Object[] | null {
  if (Array.isArray(payload) || typeof payload !== 'object') {
    return null
  }
  const record: Record<string, Object> = payload as Record<string, Object>
  const items: Object | undefined = record['items']
  return items !== undefined && items !== null && Array.isArray(items) ? items as Object[] : null
}

/**
 * 判断域的输出形态是否为裸数组（history/reading_progress/drafts/saved_threads）。
 *
 * @param domainId - 域 ID
 * @returns 是否裸数组形态
 */
function isBareArrayDomain(domainId: string): boolean {
  return domainId === DomainIds.HISTORY || domainId === DomainIds.READING_PROGRESS ||
    domainId === DomainIds.DRAFTS || domainId === DomainIds.SAVED_THREADS
}

/**
 * 判断域的输出形态是否必须为 `{items: T[]}` 信封（tracked_threads/ai_sessions）。
 *
 * @param domainId - 域 ID
 * @returns 是否 ENVELOPE 形态
 */
function isEnvelopeDomain(domainId: string): boolean {
  return domainId === DomainIds.TRACKED_THREADS || domainId === DomainIds.AI_SESSIONS
}

/**
 * 判断域是否为导入侧的缓存/镜像域（合并器走原样透传分支）。
 *
 * @param domainId - 域 ID
 * @returns 是否透传域
 */
function isCacheDomain(domainId: string): boolean {
  return domainId === DomainIds.CATEGORIES || domainId === DomainIds.PROFILES ||
    domainId === DomainIds.NOTIFICATIONS || domainId === DomainIds.ACTIVITIES ||
    domainId === DomainIds.FAVORITE_MEMBERSHIP || domainId === DomainIds.AI_TOOL_CACHE
}

/**
 * 构造带业务键与时间字段的条目对象（history/tracked_threads/ai_sessions 通用）。
 *
 * @param keyField - 业务键字段名（tid / id）
 * @param keyValue - 业务键值
 * @param timeField - 时间字段名（ts / lastCheckAt / updatedAt）
 * @param timeValue - 时间戳
 * @returns 条目对象
 */
function makeTimeEntry(keyField: string, keyValue: string, timeField: string,
  timeValue: number): Record<string, Object> {
  const entry: Record<string, Object> = {}
  entry[keyField] = keyValue
  entry[timeField] = timeValue
  return entry
}

/**
 * 构造 votes 域的一条投票记录（Record 值为对象，含 ts 时间字段）。
 *
 * @param ts - 更新时间戳
 * @returns 投票记录
 */
function makeVoteEntry(ts: number): Record<string, Object> {
  const entry: Record<string, Object> = {}
  entry['ts'] = ts
  const upPids: string[] = []
  upPids.push('1')
  entry['upPids'] = upPids
  const downPids: string[] = []
  entry['downPids'] = downPids
  return entry
}

/**
 * 构造一个「未来版本」容器文本（formatVersion=2，仅含一个 theme 域）。
 *
 * @returns 容器 JSON 文本
 */
function buildFutureFormatContainerText(): string {
  let text: string = '{"magic":"NGA_OH_BACKUP","formatVersion":2,"dataVersion":2,'
  text += '"domains":[{"id":"theme","label":"主题","schemaVersion":1,'
  text += '"payload":{"mode":"dark"}}],"checksum":""}'
  return text
}

/**
 * 注册数据导出→导入容器往返测试。
 */
export default function dataTransferRoundTripTest(): void {
  describe('dataTransferRoundTrip', (): void => {
    it('parsesAllSixteenExportableDomainsFromExportShapedContainer', 0,
      async (): Promise<void> => {
        const service: DataTransferService = new DataTransferService()
        const outcome: ParseOutcome = await service.parseBackup(buildFullContainerText(), '')

        expect(outcome.ok).assertTrue()
        expect(outcome.needPassword).assertFalse()
        // checksum 为空：必须给出「缺少校验和」的非阻断警告，且解析不中断
        expect(outcome.warning.indexOf('校验和') >= 0).assertTrue()
        expect(outcome.droppedDomains.length).assertEqual(0)

        const container: BackupContainer | null = outcome.container
        expect(container !== null).assertTrue()
        if (container === null) {
          return
        }
        expect(container.magic).assertEqual('NGA_OH_BACKUP')
        expect(container.formatVersion).assertEqual(1)
        expect(container.dataVersion).assertEqual(2)
        expect(container.domains.length).assertEqual(EXPORTABLE_DOMAIN_COUNT)

        // 可导出域清单 = Catalog 声明顺序（导出容器 domains 顺序稳定）
        const exportableSpecs: DomainSpec[] = PersistenceCatalog.exportable()
        expect(exportableSpecs.length).assertEqual(EXPORTABLE_DOMAIN_COUNT)
        const expectedIds: string[] = exportableIds()
        expect(expectedIds.length).assertEqual(EXPORTABLE_DOMAIN_COUNT)
        for (let i: number = 0; i < expectedIds.length; i++) {
          expect(exportableSpecs[i].id).assertEqual(expectedIds[i])
          // 解析结果不丢域且顺序一致
          expect(container.domains[i].id).assertEqual(expectedIds[i])
        }

        // 每个解析出的域都必须被 Catalog 识别，且导出/导入策略均不是 NEVER
        for (let i: number = 0; i < container.domains.length; i++) {
          const entry: BackupDomainEntry = container.domains[i]
          const spec: DomainSpec | null = PersistenceCatalog.byId(entry.id)
          expect(spec !== null).assertTrue()
          if (spec === null) {
            continue
          }
          expect(spec.exportPolicy === ExportPolicy.NEVER).assertFalse()
          expect(spec.importPolicy === ImportPolicy.NEVER).assertFalse()
        }
      })

    it('preservesMirrorOwnerUidOnParsedDomains', 0, async (): Promise<void> => {
      const service: DataTransferService = new DataTransferService()
      const outcome: ParseOutcome = await service.parseBackup(buildFullContainerText(), '')
      const container: BackupContainer | null = outcome.container
      expect(container !== null).assertTrue()
      if (container === null) {
        return
      }

      // 三个账号镜像域的来源 ownerUid 必须被保留（导入侧用于跨账号串号防护）
      const mirrorIds: string[] = []
      mirrorIds.push(DomainIds.NOTIFICATIONS)
      mirrorIds.push(DomainIds.ACTIVITIES)
      mirrorIds.push(DomainIds.FAVORITE_MEMBERSHIP)
      for (let i: number = 0; i < mirrorIds.length; i++) {
        const mirrorEntry: BackupDomainEntry | null = findDomainEntry(container, mirrorIds[i])
        expect(mirrorEntry !== null).assertTrue()
        if (mirrorEntry !== null) {
          expect(mirrorEntry.ownerUid).assertEqual(MIRROR_OWNER_UID)
        }
      }

      // 非镜像域不携带 ownerUid：解析结果保持空串
      const settingsEntry: BackupDomainEntry | null =
        findDomainEntry(container, DomainIds.SETTINGS)
      expect(settingsEntry !== null).assertTrue()
      if (settingsEntry !== null) {
        expect(settingsEntry.ownerUid).assertEqual('')
      }
    })

    it('mergesEveryExportableDomainPayloadWithExpectedShape', 0, async (): Promise<void> => {
      const service: DataTransferService = new DataTransferService()
      const outcome: ParseOutcome = await service.parseBackup(buildFullContainerText(), '')
      const container: BackupContainer | null = outcome.container
      expect(container !== null).assertTrue()
      if (container === null) {
        return
      }

      let mergedDomains: number = 0
      for (let i: number = 0; i < container.domains.length; i++) {
        const entry: BackupDomainEntry = container.domains[i]
        // 本机无数据（null）+ 备份 payload：模拟导入合并的最常见路径
        const result: MergeResult = mergePayload(entry.id, null, entry.payload)
        expect(isPresentObject(result.merged)).assertTrue()

        if (isBareArrayDomain(entry.id)) {
          // history/reading_progress/drafts/saved_threads：输出裸数组
          expect(Array.isArray(result.merged)).assertTrue()
        } else {
          // settings/theme/votes/poll_voted/缓存域/ENVELOPE 域：输出对象（非数组）
          expect(Array.isArray(result.merged)).assertFalse()
        }
        if (isEnvelopeDomain(entry.id)) {
          // tracked_threads/ai_sessions：必须归一为 {items: T[]}，否则 CacheEnvelopeStore 读成空域
          const items: Object[] | null = readItemsField(result.merged)
          expect(items !== null).assertTrue()
        }
        if (isCacheDomain(entry.id)) {
          // 缓存/镜像域：原样透传，不产生 added/updated 计数
          expect(result.added).assertEqual(0)
          expect(result.updated).assertEqual(0)
        }
        mergedDomains++
      }
      expect(mergedDomains).assertEqual(EXPORTABLE_DOMAIN_COUNT)
    })

    it('isIdempotentWhenMergingOwnOutputBackIn', 0, (): void => {
      // history：裸数组（tid + ts）
      const historyIncoming: Object[] = []
      historyIncoming.push(makeTimeEntry('tid', '1', 'ts', 100))
      const historyFirst: MergeResult = mergePayload(DomainIds.HISTORY, null, historyIncoming)
      expect(historyFirst.added).assertEqual(1)
      const historySecond: MergeResult =
        mergePayload(DomainIds.HISTORY, historyFirst.merged, historyFirst.merged)
      expect(historySecond.added).assertEqual(0)
      expect(historySecond.updated).assertEqual(0)

      // votes：Record<tid, {upPids, downPids, ts}>
      const votesIncoming: Record<string, Object> = {}
      votesIncoming['100'] = makeVoteEntry(100)
      const votesFirst: MergeResult = mergePayload(DomainIds.VOTES, null, votesIncoming)
      expect(votesFirst.added).assertEqual(1)
      const votesSecond: MergeResult =
        mergePayload(DomainIds.VOTES, votesFirst.merged, votesFirst.merged)
      expect(votesSecond.added).assertEqual(0)
      expect(votesSecond.updated).assertEqual(0)

      // tracked_threads：输出 {items} 信封，再次合并不得重复计入
      const trackedItems: Object[] = []
      trackedItems.push(makeTimeEntry('tid', '1', 'lastCheckAt', 100))
      const trackedIncoming: Record<string, Object> = {}
      trackedIncoming['items'] = trackedItems
      const trackedFirst: MergeResult =
        mergePayload(DomainIds.TRACKED_THREADS, null, trackedIncoming)
      expect(trackedFirst.added).assertEqual(1)
      expect(Array.isArray(trackedFirst.merged)).assertFalse()
      const trackedItemsAfter: Object[] | null = readItemsField(trackedFirst.merged)
      expect(trackedItemsAfter !== null).assertTrue()
      if (trackedItemsAfter !== null) {
        expect(trackedItemsAfter.length).assertEqual(1)
      }
      const trackedSecond: MergeResult =
        mergePayload(DomainIds.TRACKED_THREADS, trackedFirst.merged, trackedFirst.merged)
      expect(trackedSecond.added).assertEqual(0)
      expect(trackedSecond.updated).assertEqual(0)

      // ai_sessions：输出 {items} 信封，再次合并不得重复计入
      const sessionItems: Object[] = []
      sessionItems.push(makeTimeEntry('id', 's1', 'updatedAt', 100))
      const sessionsIncoming: Record<string, Object> = {}
      sessionsIncoming['items'] = sessionItems
      const sessionsFirst: MergeResult =
        mergePayload(DomainIds.AI_SESSIONS, null, sessionsIncoming)
      expect(sessionsFirst.added).assertEqual(1)
      expect(Array.isArray(sessionsFirst.merged)).assertFalse()
      const sessionsAfter: Object[] | null = readItemsField(sessionsFirst.merged)
      expect(sessionsAfter !== null).assertTrue()
      if (sessionsAfter !== null) {
        expect(sessionsAfter.length).assertEqual(1)
      }
      const sessionsSecond: MergeResult =
        mergePayload(DomainIds.AI_SESSIONS, sessionsFirst.merged, sessionsFirst.merged)
      expect(sessionsSecond.added).assertEqual(0)
      expect(sessionsSecond.updated).assertEqual(0)
    })

    it('deduplicatesRepeatedDomainIdsWithVisibleReason', 0, async (): Promise<void> => {
      // 同一 history 出现两次 + 一个合法 theme：重复域只保留首个，且必须进 droppedDomains
      let text: string = '{"magic":"NGA_OH_BACKUP","formatVersion":1,"dataVersion":2,"domains":['
      text += '{"id":"history","label":"浏览历史","schemaVersion":1,"payload":[]},'
      text += '{"id":"history","label":"浏览历史","schemaVersion":1,"payload":[]},'
      text += '{"id":"theme","label":"主题","schemaVersion":1,"payload":{"mode":"dark"}}'
      text += '],"checksum":""}'
      const service: DataTransferService = new DataTransferService()
      const outcome: ParseOutcome = await service.parseBackup(text, '')

      expect(outcome.ok).assertTrue()
      const container: BackupContainer | null = outcome.container
      expect(container !== null).assertTrue()
      if (container === null) {
        return
      }
      // 3 个输入条目里重复的 1 个被丢弃 → 容器少 1
      expect(container.domains.length).assertEqual(2)
      expect(container.domains[0].id).assertEqual(DomainIds.HISTORY)
      expect(container.domains[1].id).assertEqual(DomainIds.THEME)

      expect(outcome.droppedDomains.length).assertEqual(1)
      expect(outcome.droppedDomains[0].domainId).assertEqual(DomainIds.HISTORY)
      expect(outcome.droppedDomains[0].reason.indexOf('重复') >= 0).assertTrue()
    })

    it('acceptsFutureFormatVersionInParserLayerOnly', 0, async (): Promise<void> => {
      const service: DataTransferService = new DataTransferService()
      const outcome: ParseOutcome = await service.parseBackup(buildFutureFormatContainerText(), '')

      // 解析层宽容：formatVersion=2 仍能读出容器（版本拒绝由 buildImportPlan 负责）
      expect(outcome.ok).assertTrue()
      const container: BackupContainer | null = outcome.container
      expect(container !== null).assertTrue()
      if (container === null) {
        return
      }
      expect(container.formatVersion).assertEqual(2)
      expect(container.domains.length).assertEqual(1)
      expect(container.domains[0].id).assertEqual(DomainIds.THEME)
    })
  })
}
