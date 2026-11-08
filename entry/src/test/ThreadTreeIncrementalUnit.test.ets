import { describe, it, expect } from '@ohos/hypium'
import {
  canActivateTarget,
  canOverrideTarget,
  decideTargetState,
  formatCompactProgress,
  formatFilteredText,
  formatLoadingText,
  formatMissingText,
  formatReadyLoadingText,
  formatReadyText,
  formatTargetLabel,
  formatWaitTargetText,
  resolveBannerMode,
  shouldShowBanner,
  targetPageRatio
} from '../main/ets/common/utils/ThreadTreeLocatePolicy'
import {
  LocateSource,
  LocateState,
  TreeBannerMode,
  TreePagePhase
} from '../main/ets/model/ThreadTreeLocate'
import {
  computeTreeRowDiff,
  RowDiffResult,
  RowOpKind
} from '../main/ets/common/utils/ThreadTreeRowDiff'
import { PostInfo } from '../main/ets/model/PostInfo'
import { ThreadTreeRow, ThreadTreeRowKind } from '../main/ets/model/ThreadTree'

/**
 * 构造一行树行。
 *
 * @param pid - 楼层 pid
 * @param kind - 行类型
 * @returns 树行
 */
function createRow(pid: number, kind: number): ThreadTreeRow {
  const row: ThreadTreeRow = new ThreadTreeRow()
  row.kind = kind
  const post: PostInfo = new PostInfo()
  post.pid = pid
  post.lou = pid
  row.post = post
  row.displayContent = 'body-' + String(pid)
  return row
}

/**
 * 构造折叠行。
 *
 * @param rootPid - 所属根 pid
 * @param totalCount - 后代总数
 * @returns 折叠行
 */
function createMoreRow(rootPid: number, totalCount: number): ThreadTreeRow {
  const row: ThreadTreeRow = new ThreadTreeRow()
  row.kind = ThreadTreeRowKind.MORE
  row.post = null
  row.rootPid = rootPid
  row.totalCount = totalCount
  row.hiddenCount = totalCount - 2
  return row
}

/**
 * 行键生成（与页面 `rowKey` 同构的简化版）。
 *
 * @param row - 树行
 * @returns 键值
 */
function keyOf(row: ThreadTreeRow): string {
  const pid: number = row.post !== null ? row.post.pid : row.rootPid
  return String(row.kind) + '_' + String(pid)
}

/**
 * 注册「递进树增量加载」的纯逻辑测试。
 *
 * 覆盖两类契约：
 * 1. 定位目标状态机（只看楼主过滤不能误判为"已删除"、未就绪不给动作、胶囊状态组合）；
 * 2. 行序列 diff（纯插入走 ADD、内容变化走 CHANGE、无法增量时 RELOAD）。
 */
export default function threadTreeIncrementalUnitTest(): void {
  describe('threadTreeLocatePolicy', (): void => {
    it('decideTargetState_readyWhenInTree', 0, (): void => {
      expect(decideTargetState(true, true, 3, 1, false)).assertEqual(LocateState.READY)
    })

    it('decideTargetState_filteredWhenOnlyInAllPosts', 0, (): void => {
      /* 只看楼主把目标过滤掉了：模型里没有、全量里有，不能判成 MISSING */
      expect(decideTargetState(true, false, 3, 5, false)).assertEqual(LocateState.FILTERED)
    })

    it('decideTargetState_missingWhenPageCommitted', 0, (): void => {
      expect(decideTargetState(false, false, 3, 5, false)).assertEqual(LocateState.MISSING)
    })

    it('decideTargetState_waitingWhenPageNotCommitted', 0, (): void => {
      expect(decideTargetState(false, false, 9, 5, false)).assertEqual(LocateState.WAITING)
    })

    it('decideTargetState_unknownPageWaitsUntilComplete', 0, (): void => {
      expect(decideTargetState(false, false, -1, 5, false)).assertEqual(LocateState.WAITING)
      expect(decideTargetState(false, false, -1, 5, true)).assertEqual(LocateState.MISSING)
    })

    it('canOverrideTarget_resumeNeverOverrides', 0, (): void => {
      expect(canOverrideTarget(LocateSource.RESUME, '')).assertTrue()
      expect(canOverrideTarget(LocateSource.RESUME, LocateSource.RESUME)).assertFalse()
      expect(canOverrideTarget(LocateSource.RESUME, LocateSource.ROUTE)).assertFalse()
    })

    it('canOverrideTarget_routeAndUserOverride', 0, (): void => {
      expect(canOverrideTarget(LocateSource.ROUTE, LocateSource.RESUME)).assertTrue()
      expect(canOverrideTarget(LocateSource.USER, LocateSource.ROUTE)).assertTrue()
    })

    it('canActivateTarget_onlyReadyAndFiltered', 0, (): void => {
      expect(canActivateTarget(LocateState.READY)).assertTrue()
      expect(canActivateTarget(LocateState.FILTERED)).assertTrue()
      expect(canActivateTarget(LocateState.WAITING)).assertFalse()
      expect(canActivateTarget(LocateState.MISSING)).assertFalse()
      expect(canActivateTarget(LocateState.NONE)).assertFalse()
    })

    it('decideTargetState_cacheHitTargetIsAlreadyPromotable', 0, (): void => {
      /*
       * 缓存命中（进度读盘晚于第 1 页交付）：目标登记瞬间就已经在树里，
       * 不会再有 WAITING → READY 的状态变化。判定结果必须是 READY / FILTERED，
       * 页面才能在这种「登记即就绪」的时序下补发一次「前往查看 / 查看全部」。
       */
      const ready: number = decideTargetState(true, true, 12, 29, false)
      expect(ready).assertEqual(LocateState.READY)
      expect(canActivateTarget(ready)).assertTrue()
      const filtered: number = decideTargetState(true, false, 12, 29, false)
      expect(filtered).assertEqual(LocateState.FILTERED)
      expect(canActivateTarget(filtered)).assertTrue()
    })

    it('resolveBannerMode_enteringAndFailed', 0, (): void => {
      expect(resolveBannerMode(TreePagePhase.ENTERING, LocateState.NONE, false))
        .assertEqual(TreeBannerMode.HIDDEN)
      expect(resolveBannerMode(TreePagePhase.FAILED, LocateState.READY, false))
        .assertEqual(TreeBannerMode.ERROR)
      expect(resolveBannerMode(TreePagePhase.STREAMING, LocateState.NONE, true))
        .assertEqual(TreeBannerMode.STOPPING)
    })

    it('resolveBannerMode_streamingCombinations', 0, (): void => {
      expect(resolveBannerMode(TreePagePhase.STREAMING, LocateState.NONE, false))
        .assertEqual(TreeBannerMode.LOADING)
      expect(resolveBannerMode(TreePagePhase.STREAMING, LocateState.WAITING, false))
        .assertEqual(TreeBannerMode.LOADING_WAIT)
      /* 目标就绪/被过滤都不再由胶囊承载（「前往」交给 Toast），胶囊回到纯进度 */
      expect(resolveBannerMode(TreePagePhase.STREAMING, LocateState.READY, false))
        .assertEqual(TreeBannerMode.LOADING)
      expect(resolveBannerMode(TreePagePhase.STREAMING, LocateState.FILTERED, false))
        .assertEqual(TreeBannerMode.LOADING)
    })

    it('resolveBannerMode_completeKeepsLoadedBanner', 0, (): void => {
      /* 加载结束不消失：任意目标状态都转为常驻的 LOADED（只显示 `N/X`） */
      expect(resolveBannerMode(TreePagePhase.COMPLETE, LocateState.NONE, false))
        .assertEqual(TreeBannerMode.LOADED)
      expect(resolveBannerMode(TreePagePhase.COMPLETE, LocateState.READY, false))
        .assertEqual(TreeBannerMode.LOADED)
      expect(resolveBannerMode(TreePagePhase.COMPLETE, LocateState.WAITING, false))
        .assertEqual(TreeBannerMode.LOADED)
      expect(resolveBannerMode(TreePagePhase.COMPLETE, LocateState.FILTERED, false))
        .assertEqual(TreeBannerMode.LOADED)
      expect(resolveBannerMode(TreePagePhase.COMPLETE, LocateState.MISSING, false))
        .assertEqual(TreeBannerMode.LOADED)
      expect(resolveBannerMode(TreePagePhase.STOPPED, LocateState.READY, false))
        .assertEqual(TreeBannerMode.LOADED)
      /* 停止过渡态优先于阶段判定 */
      expect(resolveBannerMode(TreePagePhase.STOPPED, LocateState.READY, true))
        .assertEqual(TreeBannerMode.STOPPING)
    })

    it('shouldShowBanner_visibleWheneverTotalKnown', 0, (): void => {
      /* 单页帖也显示 `1/1`；加载结束的 LOADED 同样常驻 */
      expect(shouldShowBanner(TreeBannerMode.LOADING, 1)).assertTrue()
      expect(shouldShowBanner(TreeBannerMode.LOADING, 2)).assertTrue()
      expect(shouldShowBanner(TreeBannerMode.LOADED, 1)).assertTrue()
      expect(shouldShowBanner(TreeBannerMode.LOADED, 29)).assertTrue()
      /* 停止过渡与错误必须被看见，不受总页数限制 */
      expect(shouldShowBanner(TreeBannerMode.STOPPING, 29)).assertTrue()
      expect(shouldShowBanner(TreeBannerMode.ERROR, 1)).assertTrue()
      expect(shouldShowBanner(TreeBannerMode.ERROR, 0)).assertTrue()
      /* 隐藏态永远不显示；总页数未知（第 1 页未回）同样不显示 */
      expect(shouldShowBanner(TreeBannerMode.HIDDEN, 29)).assertFalse()
      expect(shouldShowBanner(TreeBannerMode.LOADING, 0)).assertFalse()
      expect(shouldShowBanner(TreeBannerMode.LOADED, 0)).assertFalse()
    })

    it('targetPageRatio_clampsAndReportsUnknown', 0, (): void => {
      expect(targetPageRatio(-1, 29)).assertEqual(-1)
      expect(targetPageRatio(0, 29)).assertEqual(-1)
      expect(targetPageRatio(10, 0)).assertEqual(-1)
      expect(targetPageRatio(10, 29) > 0.3 && targetPageRatio(10, 29) < 0.4).assertTrue()
      /* 页码越界视为记录过期，按未知处理，不画在 100% */
      expect(targetPageRatio(99, 29)).assertEqual(-1)
    })

    it('formatCompactProgress_digitsOnly', 0, (): void => {
      expect(formatCompactProgress(12, 29)).assertEqual('12/29')
      /* 总页数未知时退化为已提交页数：绝不显示 12/0 */
      expect(formatCompactProgress(12, 0)).assertEqual('12')
      expect(formatCompactProgress(0, 29)).assertEqual('0/29')
    })

    it('formatters_matchDesignedCopy', 0, (): void => {
      expect(formatLoadingText(12, 29)).assertEqual('已加载 12/29 页')
      expect(formatWaitTargetText('上次阅读位置', 12, 40))
        .assertEqual('载入到上次阅读位置 12/40 页')
      expect(formatReadyText('上次阅读位置')).assertEqual('已到上次阅读位置')
      expect(formatReadyLoadingText('上次阅读位置', 12, 29))
        .assertEqual('已到上次阅读位置 · 12/29 页')
      expect(formatFilteredText('上次阅读位置')).assertEqual('上次阅读位置在只看楼主视图外')
      expect(formatMissingText('上次阅读位置', 12, 29))
        .assertEqual('上次阅读位置未加载（12/29 页）')
    })

    it('formatTargetLabel_bySource', 0, (): void => {
      expect(formatTargetLabel(LocateSource.RESUME, -1)).assertEqual('上次阅读位置')
      expect(formatTargetLabel(LocateSource.ROUTE, 812)).assertEqual('第 812 楼')
      expect(formatTargetLabel(LocateSource.USER, -1)).assertEqual('目标楼层')
    })
  })

  describe('threadTreeRowDiff', (): void => {
    it('diffFromEmpty_isSingleAdd', 0, (): void => {
      const next: ThreadTreeRow[] = [createRow(1, ThreadTreeRowKind.ROOT)]
      const result: RowDiffResult = computeTreeRowDiff([], next, keyOf)
      expect(result.needReload).assertFalse()
      expect(result.ops.length).assertEqual(1)
      expect(result.ops[0].kind).assertEqual(RowOpKind.ADD)
      expect(result.ops[0].index).assertEqual(0)
      expect(result.ops[0].count).assertEqual(1)
    })

    it('appendAtTail_isSingleAdd', 0, (): void => {
      const oldRows: ThreadTreeRow[] = [
        createRow(1, ThreadTreeRowKind.ROOT),
        createRow(2, ThreadTreeRowKind.CHILD)
      ]
      const next: ThreadTreeRow[] = [
        createRow(1, ThreadTreeRowKind.ROOT),
        createRow(2, ThreadTreeRowKind.CHILD),
        createRow(3, ThreadTreeRowKind.ROOT)
      ]
      const result: RowDiffResult = computeTreeRowDiff(oldRows, next, keyOf)
      expect(result.needReload).assertFalse()
      expect(result.ops.length).assertEqual(1)
      expect(result.ops[0].kind).assertEqual(RowOpKind.ADD)
      expect(result.ops[0].index).assertEqual(2)
      expect(result.ops[0].count).assertEqual(1)
    })

    it('insertInMiddle_usesOldIndex', 0, (): void => {
      const oldRows: ThreadTreeRow[] = [
        createRow(1, ThreadTreeRowKind.ROOT),
        createRow(5, ThreadTreeRowKind.ROOT)
      ]
      const next: ThreadTreeRow[] = [
        createRow(1, ThreadTreeRowKind.ROOT),
        createRow(2, ThreadTreeRowKind.CHILD),
        createRow(3, ThreadTreeRowKind.CHILD),
        createRow(5, ThreadTreeRowKind.ROOT)
      ]
      const result: RowDiffResult = computeTreeRowDiff(oldRows, next, keyOf)
      expect(result.needReload).assertFalse()
      expect(result.ops.length).assertEqual(1)
      expect(result.ops[0].kind).assertEqual(RowOpKind.ADD)
      expect(result.ops[0].index).assertEqual(1)
      expect(result.ops[0].count).assertEqual(2)
    })

    it('multiPointInsert_producesSeparateAdds', 0, (): void => {
      const oldRows: ThreadTreeRow[] = [
        createRow(1, ThreadTreeRowKind.ROOT),
        createRow(5, ThreadTreeRowKind.ROOT),
        createRow(9, ThreadTreeRowKind.ROOT)
      ]
      const next: ThreadTreeRow[] = [
        createRow(1, ThreadTreeRowKind.ROOT),
        createRow(2, ThreadTreeRowKind.CHILD),
        createRow(5, ThreadTreeRowKind.ROOT),
        createRow(6, ThreadTreeRowKind.CHILD),
        createRow(9, ThreadTreeRowKind.ROOT)
      ]
      const result: RowDiffResult = computeTreeRowDiff(oldRows, next, keyOf)
      expect(result.needReload).assertFalse()
      expect(result.ops.length).assertEqual(2)
      expect(result.ops[0].index).assertEqual(1)
      expect(result.ops[1].index).assertEqual(2)
    })

    it('unchangedRows_produceNoOps', 0, (): void => {
      const oldRows: ThreadTreeRow[] = [createRow(1, ThreadTreeRowKind.ROOT)]
      const next: ThreadTreeRow[] = [createRow(1, ThreadTreeRowKind.ROOT)]
      const result: RowDiffResult = computeTreeRowDiff(oldRows, next, keyOf)
      expect(result.needReload).assertFalse()
      expect(result.ops.length).assertEqual(0)
    })

    it('addAndChangeOnSameIndex_fallsBackToReload', 0, (): void => {
      /* 折叠行前插入子行时，MORE 的计数也在变：ADD@1 与 CHANGE@1 同 index，
         官方规定同 index 只有第一条生效，必须整体重载 */
      const oldRows: ThreadTreeRow[] = [
        createRow(1, ThreadTreeRowKind.ROOT),
        createMoreRow(1, 3)
      ]
      const next: ThreadTreeRow[] = [
        createRow(1, ThreadTreeRowKind.ROOT),
        createRow(2, ThreadTreeRowKind.CHILD),
        createRow(3, ThreadTreeRowKind.CHILD),
        createMoreRow(1, 5)
      ]
      const result: RowDiffResult = computeTreeRowDiff(oldRows, next, keyOf)
      expect(result.needReload).assertTrue()
      expect(result.ops.length).assertEqual(1)
      expect(result.ops[0].kind).assertEqual(RowOpKind.RELOAD)
    })

    it('moreRowCountChange_producesChange', 0, (): void => {
      const oldRows: ThreadTreeRow[] = [
        createRow(1, ThreadTreeRowKind.ROOT),
        createMoreRow(1, 4)
      ]
      const next: ThreadTreeRow[] = [
        createRow(1, ThreadTreeRowKind.ROOT),
        createMoreRow(1, 6)
      ]
      const result: RowDiffResult = computeTreeRowDiff(oldRows, next, keyOf)
      expect(result.needReload).assertFalse()
      expect(result.ops.length).assertEqual(1)
      expect(result.ops[0].kind).assertEqual(RowOpKind.CHANGE)
      expect(result.ops[0].index).assertEqual(1)
    })

    it('deletionFallsBackToReload', 0, (): void => {      const oldRows: ThreadTreeRow[] = [
        createRow(1, ThreadTreeRowKind.ROOT),
        createRow(2, ThreadTreeRowKind.CHILD)
      ]
      const next: ThreadTreeRow[] = [createRow(1, ThreadTreeRowKind.ROOT)]
      const result: RowDiffResult = computeTreeRowDiff(oldRows, next, keyOf)
      expect(result.needReload).assertTrue()
      expect(result.ops.length).assertEqual(1)
      expect(result.ops[0].kind).assertEqual(RowOpKind.RELOAD)
    })

    it('reorderFallsBackToReload', 0, (): void => {
      const oldRows: ThreadTreeRow[] = [
        createRow(1, ThreadTreeRowKind.ROOT),
        createRow(2, ThreadTreeRowKind.ROOT)
      ]
      const next: ThreadTreeRow[] = [
        createRow(2, ThreadTreeRowKind.ROOT),
        createRow(1, ThreadTreeRowKind.ROOT)
      ]
      const result: RowDiffResult = computeTreeRowDiff(oldRows, next, keyOf)
      expect(result.needReload).assertTrue()
    })
  })
}
