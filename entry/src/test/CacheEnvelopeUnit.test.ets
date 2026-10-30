import { describe, expect, it } from '@ohos/hypium'
import { CacheEnvelopeStore } from '../main/ets/common/infra/CacheEnvelopeStore'

/**
 * 缓存信封测试样本。
 */
class CacheSample {
  id: string = ''
  seen: boolean = false
}

/** 账号镜像域（需要 ownerUid 软隔离）。 */
const MIRROR_DOMAIN: string = 'notifications'

/** 设备级域（忽略账号）。 */
const DEVICE_DOMAIN: string = 'ai_sessions'

/**
 * 校验单条样本：id 非空 string 且 seen 为 boolean。
 *
 * @param value - 待校验对象
 * @returns 是否有效
 */
function isValidSample(value: Object): boolean {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return false
  }
  const record: Record<string, Object> = value as Record<string, Object>
  return typeof record['id'] === 'string' &&
    String(record['id']).length > 0 &&
    typeof record['seen'] === 'boolean'
}

/**
 * 创建新格式域信封。
 *
 * @param domain - 域 ID
 * @param ownerUid - 归属账号（设备级域为空串）
 * @param items - 条目数组
 * @returns 信封对象
 */
function createEnvelope(domain: string, ownerUid: string, items: Object[]): Record<string, Object> {
  const payload: Record<string, Object> = {}
  payload['items'] = items
  const envelope: Record<string, Object> = {
    'schemaVersion': 1,
    'domain': domain,
    'updatedAt': 1730000000000,
    'ownerUid': ownerUid,
    'payload': payload
  }
  return envelope
}

/**
 * 创建旧版信封（`{schemaVersion, uid, items}`，迁移期兼容形态）。
 *
 * @param uid - 归属账号
 * @param items - 条目数组
 * @returns 旧信封对象
 */
function createLegacyEnvelope(uid: string, items: Object[]): Record<string, Object> {
  const envelope: Record<string, Object> = {
    'schemaVersion': 3,
    'uid': uid,
    'items': items
  }
  return envelope
}

/**
 * 创建样本。
 *
 * @param id - 样本 ID
 * @param seen - 是否已读
 * @returns 样本
 */
function createSample(id: string, seen: boolean): CacheSample {
  const sample: CacheSample = new CacheSample()
  sample.id = id
  sample.seen = seen
  return sample
}

/**
 * 注册缓存信封工具单元测试。
 */
export default function cacheEnvelopeUnitTest(): void {
  describe('cacheEnvelopeStore', (): void => {
    it('acceptsMirrorEnvelopeWithMatchingOwner', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>(MIRROR_DOMAIN, isValidSample)
      const items: Object[] = [createSample('a', false) as Object]
      const envelope: Record<string, Object> = createEnvelope(MIRROR_DOMAIN, 'u1', items)

      expect(tool.isValidEnvelope(envelope, 'u1')).assertTrue()
    })

    it('rejectsMirrorEnvelopeWithOtherOwner', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>(MIRROR_DOMAIN, isValidSample)
      const items: Object[] = [createSample('a', false) as Object]
      const envelope: Record<string, Object> = createEnvelope(MIRROR_DOMAIN, 'u2', items)

      // 账号镜像域：切号后读到上一个账号的缓存必须判非法（避免展示他人通知）
      expect(tool.isValidEnvelope(envelope, 'u1')).assertFalse()
    })

    it('acceptsDeviceEnvelopeRegardlessOfOwner', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>(DEVICE_DOMAIN, isValidSample)
      const items: Object[] = [createSample('a', false) as Object]
      const envelope: Record<string, Object> = createEnvelope(DEVICE_DOMAIN, 'u2', items)

      // 设备级域：取消账号隔离后任何账号都可读写
      expect(tool.isValidEnvelope(envelope, 'u1')).assertTrue()
    })

    it('acceptsLegacyEnvelopeDuringMigration', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>(MIRROR_DOMAIN, isValidSample)
      const items: Object[] = [createSample('a', false) as Object]
      const envelope: Record<string, Object> = createLegacyEnvelope('u1', items)

      expect(tool.isValidEnvelope(envelope, 'u1')).assertTrue()
    })

    it('acceptsBareItemsPayloadFromMigrator', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>(DEVICE_DOMAIN, isValidSample)
      const payload: Record<string, Object> = {}
      payload['items'] = [createSample('a', true) as Object]

      // 迁移器把旧信封转换成裸 `{items}` 载荷：Store 必须能读懂（否则迁移后数据不可见）
      expect(tool.isValidEnvelope(payload, '')).assertTrue()
    })

    it('rejectsDomainMismatch', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>(MIRROR_DOMAIN, isValidSample)
      const items: Object[] = [createSample('a', false) as Object]
      const envelope: Record<string, Object> = createEnvelope('history', 'u1', items)

      // 键/内容错配自检：settings 的载荷不应被当成通知读出来
      expect(tool.isValidEnvelope(envelope, 'u1')).assertFalse()
    })

    it('rejectsNonArrayItems', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>(MIRROR_DOMAIN, isValidSample)
      const payload: Record<string, Object> = {}
      payload['items'] = 'not-an-array'
      const envelope: Record<string, Object> = {
        'schemaVersion': 1,
        'domain': MIRROR_DOMAIN,
        'ownerUid': 'u1',
        'payload': payload
      }

      expect(tool.isValidEnvelope(envelope, 'u1')).assertFalse()
    })

    it('rejectsInvalidItemAndNullEnvelope', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>(MIRROR_DOMAIN, isValidSample)
      const badItem: Record<string, Object> = { 'id': 'a', 'seen': 'not-boolean' }
      const items: Object[] = [badItem as Object]
      const envelope: Record<string, Object> = createEnvelope(MIRROR_DOMAIN, 'u1', items)

      expect(tool.isValidEnvelope(envelope, 'u1')).assertFalse()
      expect(tool.isValidEnvelope(null, 'u1')).assertFalse()
    })

    it('extractsItemsAsCopy', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>(MIRROR_DOMAIN, isValidSample)
      const items: Object[] = [createSample('a', false) as Object, createSample('b', true) as Object]
      const envelope: Record<string, Object> = createEnvelope(MIRROR_DOMAIN, 'u1', items)

      const extracted: CacheSample[] = tool.extractItems(envelope)
      expect(extracted.length).assertEqual(2)
      expect(extracted[0].id).assertEqual('a')
      expect(extracted[1].seen).assertTrue()

      items.pop()
      expect(extracted.length).assertEqual(2)
    })

    it('buildsNamespacedKeyIgnoringUid', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>(MIRROR_DOMAIN, isValidSample)

      // 取消账号物理隔离：键不含 uid，统一 v2 命名空间
      expect(tool.key('u1')).assertEqual('v2.notifications')
      expect(tool.key('')).assertEqual('v2.notifications')
      expect(tool.key('u1') === tool.key('u2')).assertTrue()
    })

    it('returnsEmptyKeyForUnregisteredDomain', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>('not-registered', isValidSample)

      expect(tool.key('u1')).assertEqual('')
    })
  })
}
