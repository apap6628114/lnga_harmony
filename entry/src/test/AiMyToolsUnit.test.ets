/**
 * 「我的」工具公用纯函数回归测试。
 *
 * 重点保护两类容易静默出错的逻辑：
 * 1. **回帖列表的不可读条目判定**：占位条目的 `tid` 是列表序号（187/215…）而不是真实 tid、
 *    正文为空，一旦被当成真实条目返回给模型，模型会拿假 tid 去读帖并得到「帖子不存在」。
 *    判定只依赖固定文案，因此这里把命中与两侧反例都钉住——将来若有人删掉过滤，
 *    或用更宽的关键词误伤正常标题，都会在这里失败。
 * 2. **毫秒 → 秒的时间换算**：本地台账是毫秒、服务端字段是秒，两处混用是本次改动里
 *    最容易写错的地方（多除或少除一次 1000 都不会报错，只会显示错日期）。
 */

import { describe, expect, it } from '@ohos/hypium'
import { isPlaceholderSubject, toSeconds } from '../main/ets/service/ai/tools/nga/NgaToolSupport'

/**
 * 注册「我的」工具纯函数测试。
 */
export default function aiMyToolsUnitTest(): void {
  describe('aiMyTools', (): void => {
    it('detectsExpiredPlaceholderSubject', 0, (): void => {
      expect(isPlaceholderSubject('帖子发布或回复时间超过限制')).assertTrue()
    })

    it('detectsPlaceholderEmbeddedInLongerSubject', 0, (): void => {
      expect(isPlaceholderSubject('（占位）帖子发布或回复时间超过限制')).assertTrue()
    })

    it('detectsPermissionDeniedSubject', 0, (): void => {
      expect(isPlaceholderSubject('帐号权限不足')).assertTrue()
    })

    it('keepsNormalSubject', 0, (): void => {
      expect(isPlaceholderSubject('所以恐龙是怎么繁衍的')).assertFalse()
    })

    it('keepsSubjectAboutTimeLimitWithoutPlaceholderText', 0, (): void => {
      expect(isPlaceholderSubject('关于发帖时间限制的讨论')).assertFalse()
    })

    it('keepsEmptySubject', 0, (): void => {
      expect(isPlaceholderSubject('')).assertFalse()
    })

    it('convertsMillisecondTimestampToSeconds', 0, (): void => {
      expect(toSeconds(1758307501000)).assertEqual(1758307501)
    })

    it('clampsNonPositiveTimestampToZero', 0, (): void => {
      expect(toSeconds(0)).assertEqual(0)
      expect(toSeconds(-1)).assertEqual(0)
    })
  })
}
