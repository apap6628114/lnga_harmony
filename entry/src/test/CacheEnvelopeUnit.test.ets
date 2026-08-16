import { describe, expect, it } from '@ohos/hypium'
import { CacheEnvelopeStore } from '../main/ets/common/infra/CacheEnvelopeStore'

/**
 * 缓存信封测试样本。
 */
class CacheSample {
  id: string = ''
  seen: boolean = false
}

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
 * 创建信封对象。
 *
 * @param schemaVersion - 结构版本
 * @param uid - 归属用户 ID
 * @param items - 条目数组
 * @returns 信封对象
 */
function createEnvelope(schemaVersion: number, uid: string, items: CacheSample[]): Record<string, Object> {
  const envelope: Record<string, Object> = {
    'schemaVersion': schemaVersion,
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
    it('acceptsValidEnvelope', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>(1, 'cached_samples', isValidSample)
      const envelope: Record<string, Object> = createEnvelope(1, 'u1', [createSample('a', false)])

      expect(tool.isValidEnvelope(envelope, 'u1')).assertTrue()
    })

    it('rejectsWrongSchemaVersion', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>(1, 'cached_samples', isValidSample)
      const envelope: Record<string, Object> = createEnvelope(2, 'u1', [createSample('a', false)])

      expect(tool.isValidEnvelope(envelope, 'u1')).assertFalse()
    })

    it('rejectsWrongOwnerUid', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>(1, 'cached_samples', isValidSample)
      const envelope: Record<string, Object> = createEnvelope(1, 'u2', [createSample('a', false)])

      expect(tool.isValidEnvelope(envelope, 'u1')).assertFalse()
    })

    it('rejectsNonArrayItems', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>(1, 'cached_samples', isValidSample)
      const envelope: Record<string, Object> = { 'schemaVersion': 1, 'uid': 'u1', 'items': 'not-an-array' }

      expect(tool.isValidEnvelope(envelope, 'u1')).assertFalse()
    })

    it('rejectsInvalidItemAndNullEnvelope', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>(1, 'cached_samples', isValidSample)
      const badItem: Record<string, Object> = { 'id': 'a', 'seen': 'not-boolean' }
      const envelope: Record<string, Object> = {
        'schemaVersion': 1,
        'uid': 'u1',
        'items': [badItem]
      }

      expect(tool.isValidEnvelope(envelope, 'u1')).assertFalse()
      expect(tool.isValidEnvelope(null, 'u1')).assertFalse()
    })

    it('extractsItemsAsCopy', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>(1, 'cached_samples', isValidSample)
      const items: CacheSample[] = [createSample('a', false), createSample('b', true)]
      const envelope: Record<string, Object> = createEnvelope(1, 'u1', items)

      const extracted: CacheSample[] = tool.extractItems(envelope)
      expect(extracted.length).assertEqual(2)
      expect(extracted[0].id).assertEqual('a')
      expect(extracted[1].seen).assertTrue()

      items.pop()
      expect(extracted.length).assertEqual(2)
    })

    it('buildsScopedCacheKey', 0, (): void => {
      const tool: CacheEnvelopeStore<CacheSample> =
        new CacheEnvelopeStore<CacheSample>(1, 'cached_samples', isValidSample)

      expect(tool.key('u1')).assertEqual('cached_samples_u1')
    })
  })
}
