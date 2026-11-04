import { describe, expect, it } from '@ohos/hypium'
import { ThreadRenderMode } from '../main/ets/common/constants/Constants'
import { normalizeMeta } from '../main/ets/common/persistence/PersistenceMetaStore'
import { PersistenceMeta } from '../main/ets/common/persistence/PersistenceTypes'
import { ThreadTreeGuidePolicy } from '../main/ets/common/utils/ThreadTreeGuidePolicy'

/**
 * 帖子「递进树」一次性引导单元测试。
 *
 * 覆盖两件事：
 * 1. **触发策略**（纯函数）：已提示过 / 离线存档来源 / 默认树样式三条排除规则，
 *    以及唯一允许分支"首次以列表样式打开在线帖子"；
 * 2. **持久化标记的磁盘兼容读取**（`normalizeMeta`）：meta 是逐字段重建的，
 *    新字段必须显式搬运，旧数据缺字段 / 坏字段都要安全兜底为"未提示"。
 *
 * 标记的落盘由 `AppStore.acknowledgeTreeGuide` 承担（依赖持久化单例，属启动链路），
 * 不在 Local Test 覆盖范围内。
 *
 * 注册入口：`List.test.ets` 中 `import threadTreeGuideUnitTest from './ThreadTreeGuideUnit.test'`
 * 后调用 `threadTreeGuideUnitTest()`。
 */

/**
 * 注册「递进树」一次性引导单元测试。
 */
export default function threadTreeGuideUnitTest(): void {
  describe('threadTreeGuide', (): void => {
    it('showsOnFirstListReading', 0, (): void => {
      /* 唯一允许弹出的组合：从未提示 + 在线来源 + 列表样式 */
      expect(ThreadTreeGuidePolicy.shouldShow(false, false, ThreadRenderMode.LIST)).assertTrue()
    })

    it('staysHiddenWhenAlreadyShown', 0, (): void => {
      /* 持久化标记是"只提示一次"的唯一依据 */
      expect(ThreadTreeGuidePolicy.shouldShow(true, false, ThreadRenderMode.LIST)).assertFalse()
    })

    it('staysHiddenForSavedSource', 0, (): void => {
      /* 离线存档没有全帖抓取通道，不提供树入口（THREAD_TREE_DESIGN D6） */
      expect(ThreadTreeGuidePolicy.shouldShow(false, true, ThreadRenderMode.LIST)).assertFalse()
    })

    it('staysHiddenUnderTreeDefault', 0, (): void => {
      /* 默认样式已是递进树的用户打开帖子直接进树页，由树页静默置位 */
      expect(ThreadTreeGuidePolicy.shouldShow(false, false, ThreadRenderMode.TREE)).assertFalse()
    })

    it('staysHiddenWhenEveryExclusionHolds', 0, (): void => {
      /* 三个排除条件同时成立也必须不弹（防御组合顺序回归） */
      expect(ThreadTreeGuidePolicy.shouldShow(true, true, ThreadRenderMode.TREE)).assertFalse()
    })

    it('readsGuideFlagFromMetaPayload', 0, (): void => {
      /*
       * meta 是逐字段重建的（不是 JSON.parse 直接赋给类）：新字段必须显式搬进锚点，
       * 否则标记永远读不回来、每次冷启动都会重新提示。
       */
      const raw: Record<string, Object> = {}
      raw['treeGuideAcknowledged'] = true
      const meta: PersistenceMeta = normalizeMeta(raw)
      expect(meta.treeGuideAcknowledged).assertTrue()
    })

    it('defaultsGuideFlagWhenMetaFieldMissing', 0, (): void => {
      /* 升级前写下的旧 meta 没有该字段：必须安全兜底为"未提示"而不是 undefined */
      const raw: Record<string, Object> = {}
      raw['dataVersion'] = 1
      const meta: PersistenceMeta = normalizeMeta(raw)
      expect(meta.treeGuideAcknowledged).assertFalse()
    })

    it('defaultsGuideFlagWhenMetaFieldInvalid', 0, (): void => {
      /* 坏字段不得被当作已提示（否则用户永远看不到引导） */
      const raw: Record<string, Object> = {}
      raw['treeGuideAcknowledged'] = 'yes'
      const meta: PersistenceMeta = normalizeMeta(raw)
      expect(meta.treeGuideAcknowledged).assertFalse()
    })
  })
}
