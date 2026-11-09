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
  buildRowId,
  buildRowKey,
  computeTreeRowDiff,
  RowDiffResult,
  RowOpKind,
  stampRowContentRev
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
 * 行身份键：直接复用页面同款实现，避免测试自造格式与生产代码漂移。
 *
 * @param row - 树行
 * @returns 身份键（diff 匹配用）
 */
function idOf(row: ThreadTreeRow): string {
  return buildRowId(row)
}

/**
 * 行展示键：直接复用页面同款实现（身份 + 内容版本 + 高亮）。
 *
 * @param row - 树行
 * @returns LazyForEach 键值
 */
function displayKeyOf(row: ThreadTreeRow): string {
  return buildRowKey(row)
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
      const result: RowDiffResult = computeTreeRowDiff([], next, idOf, displayKeyOf)
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
      const result: RowDiffResult = computeTreeRowDiff(oldRows, next, idOf, displayKeyOf)
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
      const result: RowDiffResult = computeTreeRowDiff(oldRows, next, idOf, displayKeyOf)
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
      const result: RowDiffResult = computeTreeRowDiff(oldRows, next, idOf, displayKeyOf)
      expect(result.needReload).assertFalse()
      expect(result.ops.length).assertEqual(2)
      expect(result.ops[0].index).assertEqual(1)
      expect(result.ops[1].index).assertEqual(2)
    })

    it('unchangedRows_produceNoOps', 0, (): void => {
      const oldRows: ThreadTreeRow[] = [createRow(1, ThreadTreeRowKind.ROOT)]
      const next: ThreadTreeRow[] = [createRow(1, ThreadTreeRowKind.ROOT)]
      const result: RowDiffResult = computeTreeRowDiff(oldRows, next, idOf, displayKeyOf)
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
      const result: RowDiffResult = computeTreeRowDiff(oldRows, next, idOf, displayKeyOf)
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
      const result: RowDiffResult = computeTreeRowDiff(oldRows, next, idOf, displayKeyOf)
      expect(result.needReload).assertFalse()
      expect(result.ops.length).assertEqual(1)
      expect(result.ops[0].kind).assertEqual(RowOpKind.CHANGE)
      expect(result.ops[0].index).assertEqual(1)
    })

    it('moreRowCountChange_carriesContentKey', 0, (): void => {
      /* 折叠行计数变化时 CHANGE 必须带含内容版本的新键：
         不传键时框架沿用旧键并复用旧组件，「共 N 条回复」会停在旧值 */
      const oldMore: ThreadTreeRow = createMoreRow(1, 4)
      const nextMore: ThreadTreeRow = createMoreRow(1, 6)
      nextMore.uiRev = 1
      const result: RowDiffResult = computeTreeRowDiff(
        [createRow(1, ThreadTreeRowKind.ROOT), oldMore],
        [createRow(1, ThreadTreeRowKind.ROOT), nextMore],
        idOf,
        displayKeyOf)
      expect(result.needReload).assertFalse()
      expect(result.ops.length).assertEqual(1)
      expect(result.ops[0].kind).assertEqual(RowOpKind.CHANGE)
      expect(result.ops[0].key).assertEqual(displayKeyOf(nextMore))
    })

    it('identityKeyIgnoresContentVersion', 0, (): void => {
      /* 身份键不含 uiRev：内容版本递增不能让 diff 把它当成删除/重排而退 RELOAD */
      const oldMore: ThreadTreeRow = createMoreRow(1, 4)
      const nextMore: ThreadTreeRow = createMoreRow(1, 6)
      nextMore.uiRev = 3
      const result: RowDiffResult = computeTreeRowDiff([oldMore], [nextMore], idOf, displayKeyOf)
      expect(result.needReload).assertFalse()
      expect(result.ops.length).assertEqual(1)
      expect(result.ops[0].kind).assertEqual(RowOpKind.CHANGE)
    })

    it('contentEqual_producesNoChange', 0, (): void => {
      /* 内容完全一致（即使行对象是新建的）不能产生 CHANGE，避免无谓重建 */
      const oldMore: ThreadTreeRow = createMoreRow(1, 6)
      const nextMore: ThreadTreeRow = createMoreRow(1, 6)
      nextMore.uiRev = 2
      const result: RowDiffResult = computeTreeRowDiff([oldMore], [nextMore], idOf, displayKeyOf)
      expect(result.needReload).assertFalse()
      expect(result.ops.length).assertEqual(0)
    })

    it('deletionFallsBackToReload', 0, (): void => {
      const oldRows: ThreadTreeRow[] = [
        createRow(1, ThreadTreeRowKind.ROOT),
        createRow(2, ThreadTreeRowKind.CHILD)
      ]
      const next: ThreadTreeRow[] = [createRow(1, ThreadTreeRowKind.ROOT)]
      const result: RowDiffResult = computeTreeRowDiff(oldRows, next, idOf, displayKeyOf)
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
      const result: RowDiffResult = computeTreeRowDiff(oldRows, next, idOf, displayKeyOf)
      expect(result.needReload).assertTrue()
    })

    it('buildRowKey_includesContentVersion', 0, (): void => {
      /* 展示键必须含内容版本：版本变了键才变，LazyForEach 才会重建该行 */
      const row: ThreadTreeRow = createRow(7, ThreadTreeRowKind.CHILD)
      row.uiRev = 3
      expect(displayKeyOf(row)).assertEqual(buildRowId(row) + '_u3')
      row.uiRev = 4
      expect(displayKeyOf(row)).assertEqual(buildRowId(row) + '_u4')
    })

    it('stampRowContentRev_bumpsChangedRow', 0, (): void => {
      /* 折叠计数变化：上一版 uiRev=0，新行结算后应为 1 */
      const oldMore: ThreadTreeRow = createMoreRow(1, 4)
      const nextMore: ThreadTreeRow = createMoreRow(1, 6)
      stampRowContentRev([oldMore], [nextMore])
      expect(nextMore.uiRev).assertEqual(1)
    })

    it('stampRowContentRev_inheritsUnchangedRow', 0, (): void => {
      /* 内容一致：继承上一版版本，不制造无谓重建 */
      const oldMore: ThreadTreeRow = createMoreRow(1, 6)
      oldMore.uiRev = 2
      const nextMore: ThreadTreeRow = createMoreRow(1, 6)
      stampRowContentRev([oldMore], [nextMore])
      expect(nextMore.uiRev).assertEqual(2)
    })

    it('stampRowContentRev_restoresFloorVersionWhenRowReappears', 0, (): void => {
      /* 行从不可见状态重现（只看楼主切换回来）：用楼层版本兜底，不回退到旧键 */
      const row: ThreadTreeRow = createRow(9, ThreadTreeRowKind.CHILD)
      const post: PostInfo | null = row.post
      if (post !== null) {
        post.uiRev = 4
      }
      stampRowContentRev([], [row])
      expect(row.uiRev).assertEqual(4)
    })

    it('postVersionChange_producesChange', 0, (): void => {
      /* 正文没变、但楼层内容版本变了（评论数/标题/附件更新）：仍要产出 CHANGE 并带新键 */
      const oldRow: ThreadTreeRow = createRow(11, ThreadTreeRowKind.CHILD)
      const newRow: ThreadTreeRow = createRow(11, ThreadTreeRowKind.CHILD)
      const newPost: PostInfo | null = newRow.post
      if (newPost !== null) {
        newPost.uiRev = 1
      }
      stampRowContentRev([oldRow], [newRow])
      expect(newRow.uiRev).assertEqual(1)
      const result: RowDiffResult = computeTreeRowDiff([oldRow], [newRow], idOf, displayKeyOf)
      expect(result.needReload).assertFalse()
      expect(result.ops.length).assertEqual(1)
      expect(result.ops[0].kind).assertEqual(RowOpKind.CHANGE)
      expect(result.ops[0].key).assertEqual(displayKeyOf(newRow))
    })
  })
}
