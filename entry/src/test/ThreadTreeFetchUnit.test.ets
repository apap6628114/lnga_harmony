import { describe, it, expect } from '@ohos/hypium'
import {
  derivePartial,
  formatPageFailureMessage,
  isSkippedPagesOverwhelming,
  isSkippablePageFailure,
  ThreadTreeFetchResult
} from '../main/ets/service/ThreadTreeFetchService'
import { ThreadResult } from '../main/ets/model/ThreadResult'
import {
  isEmptyWholePage,
  THREAD_NO_FLOOR_ERROR
} from '../main/ets/service/api/ThreadApi'

/**
 * 构造一页请求结果。
 *
 * @param ok - 是否成功
 * @param emptyPage - 是否「合法空页」（整页没有可见楼层）
 * @param error - 失败文案
 * @returns 页面结果
 */
function createPageResult(ok: boolean, emptyPage: boolean, error: string): ThreadResult {
  const result: ThreadResult = new ThreadResult()
  result.ok = ok
  result.emptyPage = emptyPage
  result.error = error
  return result
}

/**
 * 构造解析后的原始帖子数据（只保留判定用到的 `data.__R`）。
 *
 * @param rawRowsJson - `data.__R` 的 JSON 文本
 * @returns 同形状原始数据
 */
function createRaw(rawRowsJson: string): Record<string, Object> {
  return JSON.parse('{"data":{"__R":' + rawRowsJson + '}}') as Record<string, Object>
}

/** 没有 `__R` 键的原始数据（页面结构异常，取数层会先拦下）。 */
const RAW_WITHOUT_ROWS: Record<string, Object> = JSON.parse('{"data":{}}') as Record<string, Object>

/**
 * 注册递进树全帖抓取的「跳过异常页」策略测试。
 *
 * 只覆盖纯判定：不构造抓取任务、不发请求。核心契约是
 * 「合法空页可以跳过，其余失败一律整体失败」——放宽这条会让风控/弱网下的
 * 批量请求越打越多，收紧这条则回到「一页被删整帖打不开」。
 */
export default function threadTreeFetchUnitTest(): void {
  describe('threadTreeFetchSkipPolicy', (): void => {
    it('skipsLegalEmptyPage', 0, (): void => {
      /** 服务端返回合法帖子页但整页没有可见楼层：跳过该页继续抓其余页。 */
      const page: ThreadResult = createPageResult(false, true, THREAD_NO_FLOOR_ERROR)
      expect(isSkippablePageFailure(page)).assertTrue()
    })

    it('doesNotSkipNetworkFailure', 0, (): void => {
      /** 超时/网络异常不是页面状态：继续抓只会连续超时。 */
      const page: ThreadResult = createPageResult(false, false, '第 3 页请求超时或异常：timeout')
      expect(isSkippablePageFailure(page)).assertFalse()
    })

    it('doesNotSkipServerErrorPage', 0, (): void => {
      /** 帖子被锁定 / 待审核：整帖不可读，逐页跳过没有意义。 */
      const page: ThreadResult = createPageResult(false, false, '帖子正等待审核')
      expect(isSkippablePageFailure(page)).assertFalse()
    })

    it('doesNotSkipThrottledEmptyPage', 0, (): void => {
      /**
       * 防御性约定：当前 `emptyPage` 结果的 error 恒为 `THREAD_NO_FLOOR_ERROR`，
       * 生产上不会同时带风控文案；这条用例锁定「即使将来 emptyPage 语义扩展到
       * 携带原始错误，风控文案也绝不跳过」的契约，避免限流被静默放大。
       */
      const page: ThreadResult = createPageResult(false, true, '访问过于频繁，请稍后再试')
      expect(isSkippablePageFailure(page)).assertFalse()
    })

    it('doesNotSkipSuccessfulPage', 0, (): void => {
      /** 成功页不进入失败分支。 */
      const page: ThreadResult = createPageResult(true, false, '')
      expect(isSkippablePageFailure(page)).assertFalse()
    })

    it('threadResultDefaultsToNonEmptyPage', 0, (): void => {
      /** 默认 Result 不能被当成空页：置位只发生在解析出 0 楼层的整页视图里。 */
      const result: ThreadResult = new ThreadResult()
      expect(result.emptyPage).assertFalse()
      expect(result.ok).assertFalse()
    })

    it('fetchResultDefaultsToNoSkippedPages', 0, (): void => {
      /** 抓取结果的跳过页列表默认为空，调用方据此决定是否提示。 */
      const result: ThreadTreeFetchResult = new ThreadTreeFetchResult()
      expect(result.skippedPages.length).assertEqual(0)
    })
  })

  describe('threadTreeEmptyPageDetection', (): void => {
    it('detectsWholePageWithoutFloors', 0, (): void => {
      /** 整页视图 + 无服务端过滤 + 原始数据 0 行：唯一的「合法空页」形态。 */
      const raw: Record<string, Object> = createRaw('{}')
      expect(isEmptyWholePage('', '', raw)).assertTrue()
    })

    it('rejectsSinglePostView', 0, (): void => {
      /** 单帖视图 0 楼层是「目标楼层已删除」，不是空页。 */
      const raw: Record<string, Object> = createRaw('{}')
      expect(isEmptyWholePage('824920438', '', raw)).assertFalse()
    })

    it('rejectsServerSideAuthorFilter', 0, (): void => {
      /** 只看楼主（服务端 authorid 过滤）翻到没有楼主楼层的页：过滤结果，不是空页。 */
      const raw: Record<string, Object> = createRaw('{}')
      expect(isEmptyWholePage('', '205511', raw)).assertFalse()
    })

    it('rejectsPageWithRawRows', 0, (): void => {
      /** 原始数据仍有楼层行（例如全被黑名单/关键词过滤）不是空页。 */
      const raw: Record<string, Object> = createRaw(
        '{"0":{"pid":0,"lou":0,"content":"主楼正文"}}')
      expect(isEmptyWholePage('', '', raw)).assertFalse()
    })

    it('treatsMissingRowsAsEmpty', 0, (): void => {
      /** `__R` 缺失同样没有可用楼层行（该形态在取数层已先抛错，这里锁定纯函数语义）。 */
      expect(isEmptyWholePage('', '', RAW_WITHOUT_ROWS)).assertTrue()
    })
  })

  describe('threadTreePageFailureMessage', (): void => {
    it('describesEmptyFirstPage', 0, (): void => {
      /** 第 1 页空页是整帖失败：文案要说明「没有可显示的楼层」而不是技术兜底。 */
      const page: ThreadResult = createPageResult(false, true, THREAD_NO_FLOOR_ERROR)
      expect(formatPageFailureMessage(1, page))
        .assertEqual('第 1 页没有可显示的楼层（整页楼层可能已被删除或屏蔽）')
    })

    it('usesUnifiedThrottleHint', 0, (): void => {
      /** 风控命中给统一提示，不暴露服务端原始文案。 */
      const page: ThreadResult = createPageResult(false, false, '访问过于频繁，请稍后再试')
      expect(formatPageFailureMessage(2, page)).assertEqual('访问过于频繁，请稍后再试')
    })

    it('keepsUnderlyingReason', 0, (): void => {
      /** 普通失败保留底层原因，便于用户判断是网络还是权限问题。 */
      const page: ThreadResult = createPageResult(false, false, '连接超时')
      expect(formatPageFailureMessage(3, page)).assertEqual('第 3 页加载失败：连接超时')
    })

    it('fallsBackWhenReasonMissing', 0, (): void => {
      /** 没有原因时仍给出带页码的失败文案。 */
      const page: ThreadResult = createPageResult(false, false, '')
      expect(formatPageFailureMessage(4, page)).assertEqual('第 4 页加载失败')
    })
  })

  describe('threadTreeSkippedOverwhelming', (): void => {
    it('keepsPartialResultUnderLimit', 0, (): void => {
      /** 2 页帖缺 1 页：仍有一页内容可读，不升级为整体失败。 */
      expect(isSkippedPagesOverwhelming(1, 2)).assertFalse()
      expect(isSkippedPagesOverwhelming(0, 29)).assertFalse()
    })

    it('failsWhenHalfOrMoreSkipped', 0, (): void => {
      /** 3 页帖缺 2 页只剩 1 页、29 页帖缺 15 页：不是局部问题，整体失败。 */
      expect(isSkippedPagesOverwhelming(2, 3)).assertTrue()
      expect(isSkippedPagesOverwhelming(15, 29)).assertTrue()
    })

    it('keepsBoundaryBelowThreshold', 0, (): void => {
      /** 29 页帖缺 14 页（不足一半）：仍按部分完整结果提交。 */
      expect(isSkippedPagesOverwhelming(14, 29)).assertFalse()
    })
  })

  describe('threadTreePartialResult', (): void => {
    it('marksIncompleteWhenPagesRemain', 0, (): void => {
      /** 只覆盖 1/20 页（人工中断或某页失败后停止）：属于部分结果。 */
      expect(derivePartial(1, 20)).assertTrue()
      expect(derivePartial(0, 20)).assertTrue()
    })

    it('marksCompleteWhenAllPagesCovered', 0, (): void => {
      /** 全部页覆盖（跳过空页也计覆盖）：不是部分结果。 */
      expect(derivePartial(20, 20)).assertFalse()
      expect(derivePartial(21, 20)).assertFalse()
    })

    it('doesNotMarkPartialWithoutTotal', 0, (): void => {
      /** 总页数未知时由调用方先判 `ok`，`partial` 保持 false（口径一致）。 */
      expect(derivePartial(0, 0)).assertFalse()
      expect(derivePartial(3, -1)).assertFalse()
    })

    it('fetchResultDefaultsToCompleteShape', 0, (): void => {
      /**
       * 默认结果必须是「完整」口径：`partial=false`、`loadedPages=0`。
       * 这保证任何忘记填字段的路径都不会被页面误判成部分数据。
       */
      const result: ThreadTreeFetchResult = new ThreadTreeFetchResult()
      expect(result.partial).assertFalse()
      expect(result.loadedPages).assertEqual(0)
      expect(result.cancelled).assertFalse()
      expect(result.ok).assertFalse()
    })
  })
}
