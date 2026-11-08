import { describe, expect, it } from '@ohos/hypium'
import { PostInfo } from '../main/ets/model/PostInfo'
import {
  buildArchiveCoverageHint,
  mergeSavedThreadPage,
  resolveArchiveStartPage
} from '../main/ets/common/utils/SavedThreadTreePolicy'

/**
 * 离线存档 → 递进树 纯逻辑单元测试。
 *
 * 覆盖两件事：
 * 1. **覆盖范围提示**：全帖存档不提示；部分页 / 起点不是第 1 页时给出准确区间，
 *    并说明「未保存页里的引用会显示为顶层楼层」——这是残树不被误读的前提；
 * 2. **跨页楼层合并**：按 pid 去重、按 `lou` 升序，与在线全帖抓取同一口径。
 *
 * 存档读取/解析与页面状态（`getSavedThreadTreeResult` / `ThreadTreePanel`）依赖
 * AppStore 与文件系统，属启动链路，不在 Local Test 覆盖范围内。
 */

/**
 * 构造一个只带排序/识别字段的楼层。
 *
 * @param pid - 楼层 pid
 * @param lou - 楼层号
 * @returns 楼层对象
 */
function makePost(pid: number, lou: number): PostInfo {
  const post: PostInfo = new PostInfo()
  post.pid = pid
  post.lou = lou
  return post
}

/**
 * 注册离线存档递进树单元测试。
 */
export default function savedThreadTreeUnitTest(): void {
  describe('savedThreadTree', (): void => {
    it('hidesHintForCompleteArchive', 0, (): void => {
      /* 从第 1 页起且覆盖总页数：全帖存档，标题的 [离线] 前缀已足够说明来源 */
      expect(buildArchiveCoverageHint(10, 1, 10)).assertEqual('')
    })

    it('hidesHintWhenTotalPagesMissing', 0, (): void => {
      /* 旧存档没有 totalPages：按 savedPages 兜底，视为全帖而不是"缺无数页" */
      expect(buildArchiveCoverageHint(10, 1, 0)).assertEqual('')
    })

    it('reportsLeadingPagesWhenTailMissing', 0, (): void => {
      /* 只保存了前 3 页（原帖 10 页）：给区间 + 引用悬空说明 */
      const hint: string = buildArchiveCoverageHint(3, 1, 10)
      expect(hint.indexOf('前 3 页') >= 0).assertTrue()
      expect(hint.indexOf('原帖共 10 页') >= 0).assertTrue()
      expect(hint.indexOf('顶层楼层') >= 0).assertTrue()
    })

    it('reportsPageRangeWhenStartPageNotFirst', 0, (): void => {
      /* 保存第 5-10 页：区间必须用线上页码，而不是存档页序 */
      const hint: string = buildArchiveCoverageHint(6, 5, 15)
      expect(hint.indexOf('第 5-10 页') >= 0).assertTrue()
      expect(hint.indexOf('原帖共 15 页') >= 0).assertTrue()
    })

    it('treatsMissingStartPageAsFirst', 0, (): void => {
      /* 旧存档没有 startPage（0）：按第 1 页起处理，区间仍要提示不完整 */
      const hint: string = buildArchiveCoverageHint(2, 0, 8)
      expect(hint.indexOf('前 2 页') >= 0).assertTrue()
    })

    it('returnsEmptyForInvalidPageCount', 0, (): void => {
      /* 空存档没有可提示的边界 */
      expect(buildArchiveCoverageHint(0, 1, 10)).assertEqual('')
    })

    it('normalizesArchiveStartPage', 0, (): void => {
      /* 外部导入字段可能是 0 / 负数 / 小数 / NaN / Infinity：一律落到合法页码，绝不参与字符串拼接 */
      expect(resolveArchiveStartPage(0)).assertEqual(1)
      expect(resolveArchiveStartPage(-3)).assertEqual(1)
      expect(resolveArchiveStartPage(NaN)).assertEqual(1)
      expect(resolveArchiveStartPage(Infinity)).assertEqual(1)
      expect(resolveArchiveStartPage(2.7)).assertEqual(2)
      expect(resolveArchiveStartPage(5)).assertEqual(5)
    })

    it('clampsInvertedRangeWhenStartBeyondTotal', 0, (): void => {
      /* 异常存档（起始页超过总页数）不能出现「第 10-8 页」这种倒挂区间 */
      const hint: string = buildArchiveCoverageHint(5, 10, 8)
      expect(hint.indexOf('第 10 页') >= 0).assertTrue()
      expect(hint.indexOf('10-8') >= 0).assertFalse()
    })

    it('treatsArchiveLongerThanTotalAsComplete', 0, (): void => {
      /* 页数多于总页数的脏数据：按全帖处理，不提示一个不存在的区间 */
      expect(buildArchiveCoverageHint(10, 1, 5)).assertEqual('')
    })

    it('mergesPagesInLouOrder', 0, (): void => {
      /* 两页楼层按 lou 升序合并（存档页序到达时天然有序） */
      const collected: PostInfo[] = []
      const firstPage: PostInfo[] = [makePost(1001, 0), makePost(1002, 1), makePost(1003, 2)]
      const secondPage: PostInfo[] = [makePost(1004, 3), makePost(1005, 4)]
      expect(mergeSavedThreadPage(collected, firstPage)).assertEqual(3)
      expect(mergeSavedThreadPage(collected, secondPage)).assertEqual(2)
      expect(collected.length).assertEqual(5)
      expect(collected[4].pid).assertEqual(1005)
    })

    it('keepsLouOrderWhenPagesOverlap', 0, (): void => {
      /* 翻页期间楼层漂移会让同一楼出现在两页：按 pid 去重，不能出现重复行 */
      const collected: PostInfo[] = [makePost(1001, 0), makePost(1002, 1)]
      const repeated: PostInfo[] = [makePost(1002, 1), makePost(1003, 2)]
      expect(mergeSavedThreadPage(collected, repeated)).assertEqual(1)
      expect(collected.length).assertEqual(3)
      expect(collected[2].pid).assertEqual(1003)
    })

    it('insertsOutOfOrderFloorByLou', 0, (): void => {
      /* 乱序页（例如老存档页序异常）：插入到正确位置，不污染建树的父子判断 */
      const collected: PostInfo[] = [makePost(1001, 0), makePost(1003, 2)]
      expect(mergeSavedThreadPage(collected, [makePost(1002, 1)])).assertEqual(1)
      expect(collected[1].pid).assertEqual(1002)
      expect(collected[2].pid).assertEqual(1003)
    })

    it('ignoresEmptyPage', 0, (): void => {
      /* 空页（整页都重复/解析为空）不产生任何新增 */
      const collected: PostInfo[] = [makePost(1001, 0)]
      expect(mergeSavedThreadPage(collected, [])).assertEqual(0)
      expect(collected.length).assertEqual(1)
    })
  })
}
