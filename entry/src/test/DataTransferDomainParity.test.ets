import { describe, expect, it } from '@ohos/hypium'
import { DomainIds, PersistenceCatalog } from '../main/ets/common/persistence/PersistenceCatalog'
import {
  DomainScope,
  DomainSpec,
  ExportPolicy,
  ImportPolicy
} from '../main/ets/common/persistence/PersistenceTypes'
import { mergePayload } from '../main/ets/common/transfer/DomainMergers'
import {
  DataTransferService,
  isValidFileDomainItem
} from '../main/ets/common/transfer/DataTransferService'
import { BackupContainer, ImportPlan, SkippedDomain } from '../main/ets/common/transfer/TransferTypes'

/**
 * 数据导入「域对等性」回归测试（审计 IMP-01 / IMP-02 / IMP-09）。
 *
 * 覆盖：
 * 1. Catalog 域对等性：21 域唯一且自检通过；ExportPolicy.INCLUDE 域的 ImportPolicy 不得为 NEVER；
 *    ImportPolicy.SKIP 域只允许 OPTIONAL/NEVER 导出；SECRET 域导出/导入双向 NEVER；
 *    ENVELOPE（rawPayload=false）域集合恰为 6 个；
 * 2. 解析防护（IMP-01）：单域载荷 JSON 字符数 > 8MB 时不再静默丢弃——
 *    `ParseOutcome.droppedDomains` 记录被丢弃域与原因，`warning` 汇总提示；容器只剩被丢弃域时
 *    返回带原因的失败文案（而不是笼统的「数据域列表为空」）；
 * 3. ENVELOPE 形态归一（IMP-09）：tracked_threads / ai_sessions 即使输入裸数组，合并输出也必须
 *    是 `{ items: T[] }` 对象（CacheEnvelopeStore 只读 payload.items）；history 仍保持裸数组；
 * 4. 文件域条目校验（IMP-02）：`isValidFileDomainItem` 拦截 Store 读取侧会静默跳过的条目
 *    （saved_threads 缺 rawPages / 空 rawPages / tid 非纯数字；drafts 非法键）；
 * 5. 被丢弃域进入导入计划：`buildImportPlan(container, restore, droppedDomains)` 为每个解析阶段
 *    被丢弃的域生成 willSkip 条目（不依赖 Hub 初始化，因此可在 Local Test 覆盖）。
 *
 * ⚠️ Local Test 环境 cryptoFramework 不可用：`parseBackup` 只在容器 `checksum` 非空时才计算
 * SHA-256，因此本套用例构造的容器 `checksum` 恒为空串（会走「缺少校验和」warning 分支，
 * 不影响 droppedDomains 断言）。**禁止**构造非空 checksum，也**禁止**在测试里调用
 * `exportBackup` / `encryptBackup`。
 */

/** 单域载荷上限（与 DataTransferService 的 MAX_DOMAIN_PAYLOAD_CHARS 一致：8MB 字符）。 */
const DOMAIN_PAYLOAD_LIMIT: number = 8 * 1024 * 1024

/**
 * 构造刚好超过单域上限的 ASCII 填充串。
 *
 * 用固定长度 chunk 拼接而不是逐字符拼接，避免 800 万次字符串追加拖慢测试；
 * 目标长度只比上限多 4KB，控制 Local Test 的内存占用。
 *
 * @returns 长度 > DOMAIN_PAYLOAD_LIMIT 的填充串
 */
function makeOversizedPadding(): string {
  const chunkSize: number = 4096
  let chunk: string = ''
  for (let i: number = 0; i < chunkSize; i++) {
    chunk += 'x'
  }
  const target: number = DOMAIN_PAYLOAD_LIMIT + 4096
  let pad: string = ''
  while (pad.length < target) {
    pad += chunk
  }
  return pad
}

/**
 * 构造含「超限 saved_threads 域」的明文容器 JSON 文本。
 *
 * @param includeHistory - 是否再放一个合法小域（history，空数组），用于让容器整体可解析成功
 * @returns 容器文本（checksum 为空串，避免触发 cryptoFramework）
 */
function buildOverLimitContainerText(includeHistory: boolean): string {
  const pad: string = makeOversizedPadding()
  let text: string = '{"magic":"NGA_OH_BACKUP","formatVersion":1,"dataVersion":2,"domains":['
  text += '{"id":"saved_threads","label":"离线存档","schemaVersion":1,"payload":'
  text += '[{"tid":"44191387","rawPages":[],"pad":"' + pad + '"}]}'
  if (includeHistory) {
    text += ',{"id":"history","label":"浏览历史","schemaVersion":1,"payload":[]}'
  }
  text += '],"checksum":""}'
  return text
}

/**
 * 构造一个带业务键与时间字段的条目对象（跟踪/AI 会话/历史通用）。
 *
 * @param keyField - 业务键字段名（tid / id）
 * @param keyValue - 业务键值
 * @param timeField - 时间字段名
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
 * 从 `{items: T[]}` 信封形态的合并结果中取条目数组（形态非法时返回空数组）。
 *
 * @param payload - 合并结果 payload
 * @returns 条目数组
 */
function readWrappedItems(payload: Object): Object[] {
  const record: Record<string, Object> = payload as Record<string, Object>
  const items: Object | undefined = record['items']
  return items !== undefined && items !== null && Array.isArray(items) ? items as Object[] : []
}

/**
 * 注册数据导入域对等性回归测试。
 */
export default function dataTransferDomainParityTest(): void {
  describe('dataTransferDomainParity', (): void => {
    it('registersTwentyOneUniqueDomainsAndPassesSelfValidation', 0, (): void => {
      const all: DomainSpec[] = PersistenceCatalog.all()
      expect(all.length).assertEqual(21)

      const ids: string[] = PersistenceCatalog.ids()
      expect(ids.length).assertEqual(all.length)
      const seen: Set<string> = new Set<string>()
      for (let i: number = 0; i < ids.length; i++) {
        expect(seen.has(ids[i])).assertFalse()
        seen.add(ids[i])
      }

      expect(PersistenceCatalog.validate().length).assertEqual(0)
    })

    it('keepsExportImportPolicyParity', 0, (): void => {
      const all: DomainSpec[] = PersistenceCatalog.all()
      for (let i: number = 0; i < all.length; i++) {
        const spec: DomainSpec = all[i]
        // 默认勾选导出的域必须可导入（否则「导出有、导入永远丢」）
        if (spec.exportPolicy === ExportPolicy.INCLUDE) {
          expect(spec.importPolicy === ImportPolicy.NEVER).assertFalse()
        }
        // SKIP 只用于缓存/镜像/不可移植域：它们要么可选导出，要么永不导出
        if (spec.importPolicy === ImportPolicy.SKIP) {
          const exportable: boolean = spec.exportPolicy === ExportPolicy.OPTIONAL ||
            spec.exportPolicy === ExportPolicy.NEVER
          expect(exportable).assertTrue()
        }
        // 凭证域双向 NEVER（导出侧不出现、导入侧硬拒绝）
        if (spec.scope === DomainScope.SECRET) {
          expect(spec.exportPolicy === ExportPolicy.NEVER).assertTrue()
          expect(spec.importPolicy === ImportPolicy.NEVER).assertTrue()
        }
      }
    })

    it('marksOnlyExpectedDomainsAsEnvelopePayload', 0, (): void => {
      const expected: string[] = [
        DomainIds.NOTIFICATIONS, DomainIds.ACTIVITIES, DomainIds.FAVORITE_MEMBERSHIP,
        DomainIds.TRACKED_THREADS, DomainIds.AI_SESSIONS, DomainIds.AI_TOOL_CACHE
      ]
      const actual: string[] = []
      const all: DomainSpec[] = PersistenceCatalog.all()
      for (let i: number = 0; i < all.length; i++) {
        // rawPayload=false 即 ENVELOPE 域：Store 读 `envelope.payload`
        if (!all[i].rawPayload) {
          actual.push(all[i].id)
        }
      }
      expect(actual.length).assertEqual(expected.length)
      for (let i: number = 0; i < expected.length; i++) {
        expect(actual.indexOf(expected[i]) >= 0).assertTrue()
      }
    })

    it('reportsOversizedDomainInsteadOfSilentlyDroppingIt', 0, async (): Promise<void> => {
      const service: DataTransferService = new DataTransferService()
      const outcome = await service.parseBackup(buildOverLimitContainerText(true), '')

      // 容器本身可解析（还有合法的 history 域）
      expect(outcome.ok).assertTrue()
      const parsedContainer: BackupContainer | null = outcome.container
      expect(parsedContainer !== null).assertTrue()
      if (parsedContainer === null) {
        return
      }
      expect(parsedContainer.domains.length).assertEqual(1)
      expect(parsedContainer.domains[0].id).assertEqual(DomainIds.HISTORY)

      // 超限域被记录而不是静默丢弃
      expect(outcome.droppedDomains.length).assertEqual(1)
      expect(outcome.droppedDomains[0].domainId).assertEqual(DomainIds.SAVED_THREADS)
      expect(outcome.droppedDomains[0].reason.indexOf('8MB') >= 0).assertTrue()

      // 解析成功但存在丢弃域时必须有用户可见的 warning
      expect(outcome.warning.length > 0).assertTrue()
      expect(outcome.warning.indexOf('跳过') >= 0).assertTrue()
    })

    it('rejectsContainerWhenEveryDomainIsDropped', 0, async (): Promise<void> => {
      const service: DataTransferService = new DataTransferService()
      const outcome = await service.parseBackup(buildOverLimitContainerText(false), '')

      // 全部域都被丢弃：不能误判 ok=true，错误文案要带原因
      expect(outcome.ok).assertFalse()
      expect(outcome.container === null).assertTrue()
      expect(outcome.droppedDomains.length).assertEqual(1)
      expect(outcome.error.indexOf('无法导入') >= 0).assertTrue()
      expect(outcome.error.indexOf('8MB') >= 0).assertTrue()
    })

    it('forcesTrackedThreadsItemsEnvelopeFromBareArrays', 0, (): void => {
      const local: Object[] = []
      local.push(makeTimeEntry('tid', '1', 'lastCheckAt', 100))
      const incoming: Object[] = []
      incoming.push(makeTimeEntry('tid', '2', 'lastCheckAt', 200))

      const result = mergePayload(DomainIds.TRACKED_THREADS, local, incoming)

      // 不得输出裸数组：CacheEnvelopeStore 只读 payload.items
      expect(Array.isArray(result.merged)).assertFalse()
      const list: Object[] = readWrappedItems(result.merged)
      expect(list.length).assertEqual(2)
    })

    it('forcesAiSessionsItemsEnvelopeFromBareArrays', 0, (): void => {
      const local: Object[] = []
      local.push(makeTimeEntry('id', 's1', 'updatedAt', 100))
      const incoming: Object[] = []
      incoming.push(makeTimeEntry('id', 's2', 'updatedAt', 200))

      const result = mergePayload(DomainIds.AI_SESSIONS, local, incoming)

      expect(Array.isArray(result.merged)).assertFalse()
      const list: Object[] = readWrappedItems(result.merged)
      expect(list.length).assertEqual(2)
    })

    it('keepsHistoryAsBareArray', 0, (): void => {
      const local: Object[] = []
      local.push(makeTimeEntry('tid', '1', 'ts', 100))
      const incoming: Object[] = []
      incoming.push(makeTimeEntry('tid', '2', 'ts', 200))

      const result = mergePayload(DomainIds.HISTORY, local, incoming)

      expect(Array.isArray(result.merged)).assertTrue()
      const list: Object[] = result.merged as Object[]
      expect(list.length).assertEqual(2)
    })

    it('rejectsSavedThreadItemsThatStoreWouldSkip', 0, (): void => {
      const missingPages: Record<string, Object> = {}
      missingPages['tid'] = '44191387'
      expect(isValidFileDomainItem(DomainIds.SAVED_THREADS, missingPages)).assertFalse()

      const emptyPages: Record<string, Object> = {}
      emptyPages['tid'] = '44191387'
      const noPageList: Object[] = []
      emptyPages['rawPages'] = noPageList
      expect(isValidFileDomainItem(DomainIds.SAVED_THREADS, emptyPages)).assertFalse()

      const page: Record<string, Object> = {}
      page['pid'] = '1'
      const pages: Object[] = []
      pages.push(page)

      const nonNumericTid: Record<string, Object> = {}
      nonNumericTid['tid'] = 'abc'
      nonNumericTid['rawPages'] = pages
      expect(isValidFileDomainItem(DomainIds.SAVED_THREADS, nonNumericTid)).assertFalse()

      // 纯数字 tid + 非空 rawPages 才是 Store 能读回的条目
      const valid: Record<string, Object> = {}
      valid['tid'] = '44191387'
      valid['rawPages'] = pages
      expect(isValidFileDomainItem(DomainIds.SAVED_THREADS, valid)).assertTrue()
    })

    it('rejectsDraftItemsWithInvalidKeys', 0, (): void => {
      const valid: Record<string, Object> = {}
      valid['key'] = 'draft_44191387_edit_2_abc123'
      expect(isValidFileDomainItem(DomainIds.DRAFTS, valid)).assertTrue()

      const badChar: Record<string, Object> = {}
      badChar['key'] = 'bad key!'
      expect(isValidFileDomainItem(DomainIds.DRAFTS, badChar)).assertFalse()

      const emptyKey: Record<string, Object> = {}
      emptyKey['key'] = ''
      expect(isValidFileDomainItem(DomainIds.DRAFTS, emptyKey)).assertFalse()
    })

    it('reportsDuplicateAndMissingPayloadDomains', 0, async (): Promise<void> => {
      // 重复域 ID 只保留首个、缺 payload 的域直接跳过：两种情况都必须进 droppedDomains（禁止静默丢弃）
      const text: string = '{"magic":"NGA_OH_BACKUP","formatVersion":1,"dataVersion":2,"domains":['
        + '{"id":"history","schemaVersion":1,"payload":[]},'
        + '{"id":"history","schemaVersion":1,"payload":[]},'
        + '{"id":"theme","schemaVersion":1},'
        + '{"id":"votes","schemaVersion":1,"payload":{}}'
        + '],"checksum":""}'
      const service: DataTransferService = new DataTransferService()
      const outcome = await service.parseBackup(text, '')

      expect(outcome.ok).assertTrue()
      const parsed: BackupContainer | null = outcome.container
      expect(parsed !== null).assertTrue()
      if (parsed === null) {
        return
      }
      expect(parsed.domains.length).assertEqual(2)
      expect(parsed.domains[0].id).assertEqual(DomainIds.HISTORY)
      expect(parsed.domains[1].id).assertEqual(DomainIds.VOTES)

      expect(outcome.droppedDomains.length).assertEqual(2)
      let sawDuplicate: boolean = false
      let sawMissingPayload: boolean = false
      for (let i: number = 0; i < outcome.droppedDomains.length; i++) {
        const reason: string = outcome.droppedDomains[i].reason
        if (reason.indexOf('重复') >= 0) {
          sawDuplicate = true
        }
        if (reason.indexOf('缺少内容') >= 0) {
          sawMissingPayload = true
        }
      }
      expect(sawDuplicate).assertTrue()
      expect(sawMissingPayload).assertTrue()
    })

    it('exposesDroppedDomainsAsSkippedPlanEntries', 0, async (): Promise<void> => {
      const service: DataTransferService = new DataTransferService()
      const container: BackupContainer = new BackupContainer()
      container.magic = 'NGA_OH_BACKUP'
      container.formatVersion = 1
      container.dataVersion = 2
      container.checksum = ''

      const dropped: SkippedDomain[] = []
      dropped.push(new SkippedDomain(DomainIds.SAVED_THREADS, '单域数据超过 8MB 上限，已跳过', '离线存档'))
      dropped.push(new SkippedDomain('unknown_future_domain', '数据域条目不是有效对象'))

      // Hub 未初始化时 buildImportPlan 会在 hub 检查处返回，但「被丢弃域必须可见」的条目
      // 在版本/hub 检查之前就已经生成，这里据此锁定 IMP-01 的「不静默丢弃」契约。
      const plan: ImportPlan = await service.buildImportPlan(container, true, dropped)

      expect(plan.entries.length).assertEqual(2)
      expect(plan.entries[0].willSkip).assertTrue()
      expect(plan.entries[0].domainId).assertEqual(DomainIds.SAVED_THREADS)
      expect(plan.entries[0].reason.indexOf('8MB') >= 0).assertTrue()
      expect(plan.entries[1].willSkip).assertTrue()
      // label 为空时回退到 domainId，计划行不会显示空白
      expect(plan.entries[1].label).assertEqual('unknown_future_domain')
    })
  })
}
