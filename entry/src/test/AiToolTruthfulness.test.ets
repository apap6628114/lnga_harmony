/**
 * 工具「声明 vs 实现」一致性回归测试。
 *
 * 背景：工具描述是模型唯一的说明书。描述里写「可增大 limit 继续看」而实现把 limit
 * 卡在 50、描述里写「同时传 username 优先」而实现按 uid 走，模型都会照着错误的
 * 说明书做决定，最终表现为「数据只有这些」或「查错了人」。这类偏差不会让编译失败，
 * 也不会让任何一条既有用例失败，只能靠针对性的契约断言钉住。
 *
 * 覆盖两类断言：
 * 1. 纯函数边界：列表窗口（offset + limit）与健壮字段读取；
 * 2. 每个易漂移工具的 Schema / 描述关键事实（分页参数、样本口径、能力限制）。
 */

import { describe, expect, it } from '@ohos/hypium'
import { AiToolContext } from '../main/ets/service/ai/tools/AiToolAdapter'
import type { AiToolDefinition } from '../main/ets/service/ai/AiProtocolTypes'
import {
  buildListWindowHint,
  pickNumber,
  pickText,
  resolveListWindow
} from '../main/ets/service/ai/tools/nga/NgaToolSupport'
import type { ListWindow } from '../main/ets/service/ai/tools/nga/NgaToolSupport'
import { HISTORY_MAX_COUNT } from '../main/ets/store/HistoryStore'
import { findAiToolMeta } from '../main/ets/model/AiToolConfig'
import type { AiToolMeta } from '../main/ets/model/AiToolConfig'
import {
  NgaMyHistoryTool,
  NgaMySavedTool,
  NgaMyTrackedTool
} from '../main/ets/service/ai/tools/nga/NgaMyLibraryTools'
import {
  NgaMyFollowingTool,
  NgaMyNotificationsTool
} from '../main/ets/service/ai/tools/nga/NgaMySocialTools'
import { NgaMyPostsTool } from '../main/ets/service/ai/tools/nga/NgaMyPostTools'
import { NgaGetUserTool, NgaUserActivityTool } from '../main/ets/service/ai/tools/nga/NgaUserTools'
import { NgaReadThreadTool } from '../main/ets/service/ai/tools/nga/NgaThreadTools'
import { NgaSearchTopicsTool } from '../main/ets/service/ai/tools/nga/NgaTopicTools'
import { NgaListFavoritesTool } from '../main/ets/service/ai/tools/nga/NgaFavoriteTools'
import { WebFetchTool } from '../main/ets/service/ai/tools/WebFetchTool'
import { normalizeResultCount } from '../main/ets/service/ai/tools/WebSearchTool'

/**
 * 读取工具定义里的参数表。
 *
 * @param definition - 工具定义
 * @returns 参数表
 */
function readProperties(definition: AiToolDefinition): Record<string, Object> {
  return definition.parameters['properties'] as Record<string, Object>
}

/**
 * 读取单个参数的 Schema。
 *
 * @param definition - 工具定义
 * @param name - 参数名
 * @returns 参数 Schema
 */
function readProperty(definition: AiToolDefinition, name: string): Record<string, Object> {
  const properties: Record<string, Object> = readProperties(definition)
  return properties[name] as Record<string, Object>
}

/**
 * 读取单个参数的 description。
 *
 * @param definition - 工具定义
 * @param name - 参数名
 * @returns 参数说明
 */
function propertyDescription(definition: AiToolDefinition, name: string): string {
  return readProperty(definition, name)['description'] as string
}

/**
 * 判断参数是否存在。
 *
 * @param definition - 工具定义
 * @param name - 参数名
 * @returns true 表示存在
 */
function hasProperty(definition: AiToolDefinition, name: string): boolean {
  return Object.keys(readProperties(definition)).indexOf(name) >= 0
}

/**
 * 注册工具声明一致性测试。
 */
export default function aiToolTruthfulnessTest(): void {
  describe('aiToolTruthfulness', (): void => {
    it('historyWindowPagesThroughEntireLedger', 0, (): void => {
      /** 500 条浏览记录分三段读：200 + 200 + 100，不能停在 50 条 */
      const first: ListWindow = resolveListWindow(500, 0, 200)
      expect(first.start).assertEqual(0)
      expect(first.count).assertEqual(200)
      expect(first.hasMore).assertTrue()
      expect(first.nextOffset).assertEqual(200)

      const second: ListWindow = resolveListWindow(500, 200, 200)
      expect(second.start).assertEqual(200)
      expect(second.count).assertEqual(200)
      expect(second.nextOffset).assertEqual(400)
      expect(second.hasMore).assertTrue()

      const last: ListWindow = resolveListWindow(500, 400, 200)
      expect(last.start).assertEqual(400)
      expect(last.count).assertEqual(100)
      expect(last.nextOffset).assertEqual(500)
      expect(last.hasMore).assertFalse()
    })

    it('windowClampsOffsetBeyondTotal', 0, (): void => {
      const window: ListWindow = resolveListWindow(10, 99, 20)
      expect(window.start).assertEqual(10)
      expect(window.count).assertEqual(0)
      expect(window.hasMore).assertFalse()
    })

    it('windowHandlesZeroTotalAndNegativeOffset', 0, (): void => {
      const empty: ListWindow = resolveListWindow(0, 0, 20)
      expect(empty.count).assertEqual(0)
      expect(empty.hasMore).assertFalse()

      const negative: ListWindow = resolveListWindow(30, -5, 10)
      expect(negative.start).assertEqual(0)
      expect(negative.count).assertEqual(10)
    })

    it('windowHintPointsAtExactNextOffset', 0, (): void => {
      const hint: string = buildListWindowHint(resolveListWindow(500, 0, 200))
      expect(hint.indexOf('offset=200') >= 0).assertTrue()
      expect(hint.indexOf('共 500 条') >= 0).assertTrue()

      const tail: string = buildListWindowHint(resolveListWindow(500, 400, 200))
      expect(tail.indexOf('已读到末尾') >= 0).assertTrue()

      /** 一段就看完时不需要提示，避免每份结果都拖一条无意义尾注 */
      const none: string = buildListWindowHint(resolveListWindow(10, 0, 20))
      expect(none.length).assertEqual(0)
    })

    it('pickTextConvertsNumericLegacyFields', 0, (): void => {
      /** 旧格式把 tid 存成数字：必须转成字符串，否则 '123' !== 123 会查不到 */
      expect(pickText(123)).assertEqual('123')
      expect(pickText(undefined)).assertEqual('')
      expect(pickText('abc')).assertEqual('abc')
    })

    it('pickNumberAcceptsNumericStrings', 0, (): void => {
      expect(pickNumber('42', 0)).assertEqual(42)
      expect(pickNumber('abc', -1)).assertEqual(-1)
      expect(pickNumber(undefined, 7)).assertEqual(7)
    })

    it('historySchemaExposesOffsetAndPageLimit', 0, (): void => {
      const definition: AiToolDefinition =
        new NgaMyHistoryTool().getDefinition(new AiToolContext())
      expect(definition.description.indexOf('offset') >= 0).assertTrue()
      expect(definition.description.indexOf(HISTORY_MAX_COUNT.toString()) >= 0).assertTrue()
      expect(hasProperty(definition, 'offset')).assertTrue()
      expect(propertyDescription(definition, 'limit').indexOf('200') >= 0).assertTrue()
      expect(propertyDescription(definition, 'offset').indexOf('offset') >= 0).assertTrue()
    })

    it('savedSchemaExposesOffset', 0, (): void => {
      const definition: AiToolDefinition =
        new NgaMySavedTool().getDefinition(new AiToolContext())
      expect(hasProperty(definition, 'offset')).assertTrue()
      expect(propertyDescription(definition, 'limit').indexOf('200') >= 0).assertTrue()
    })

    it('followingAndNotificationsSchemaExposeOffset', 0, (): void => {
      const following: AiToolDefinition =
        new NgaMyFollowingTool().getDefinition(new AiToolContext())
      expect(hasProperty(following, 'offset')).assertTrue()
      expect(following.description.indexOf('offset') >= 0).assertTrue()

      const notifications: AiToolDefinition =
        new NgaMyNotificationsTool().getDefinition(new AiToolContext())
      expect(hasProperty(notifications, 'offset')).assertTrue()
      expect(notifications.description.indexOf('offset') >= 0).assertTrue()
    })

    it('trackedSchemaDoesNotAdvertiseNonexistentPaging', 0, (): void => {
      /**
       * 跟踪任务本身最多 50 条，limit 上限 50 已能一次读完；
       * 给它加 offset 只会增加模型的选择负担，这里钉住「没有这个参数」。
       */
      const definition: AiToolDefinition =
        new NgaMyTrackedTool().getDefinition(new AiToolContext())
      expect(hasProperty(definition, 'offset')).assertFalse()
      expect(propertyDescription(definition, 'limit').indexOf('50') >= 0).assertTrue()
      expect(definition.description.indexOf('50') >= 0).assertTrue()
    })

    it('activityDescribesFirstPageSampleNotTotals', 0, (): void => {
      /**
       * 实现只取发帖 / 回帖接口的第一页样本（UserApi.fetchUserTopicT 固定 page=1），
       * 描述若写「总数」，模型会把 35 / 20 条的样本当成账号历史总量。
       */
      const definition: AiToolDefinition =
        new NgaUserActivityTool().getDefinition(new AiToolContext())
      expect(definition.description.indexOf('第一页样本') >= 0).assertTrue()
      expect(definition.description.indexOf('发帖/回复总数') < 0).assertTrue()
      expect(definition.description.indexOf('不是该账号的历史总量') >= 0).assertTrue()
    })

    it('myPostsDoesNotPromiseTotalCount', 0, (): void => {
      const meta: AiToolMeta | null = findAiToolMeta('nga_my_posts')
      expect(meta !== null).assertTrue()
      if (meta !== null) {
        /** 目录文案曾写「用于我一共发了多少帖」，与工具描述「不要声称总数」直接矛盾 */
        expect(meta.description.indexOf('用于「我一共发了多少帖」') < 0).assertTrue()
        expect(meta.description.indexOf('不返回主题总数') >= 0).assertTrue()
      }
      const definition: AiToolDefinition =
        new NgaMyPostsTool().getDefinition(new AiToolContext())
      expect(definition.description.indexOf('不返回主题总数') >= 0).assertTrue()
    })

    it('getUserDescriptionMatchesUidPriority', 0, (): void => {
      /** 实现：同时传 uid 与 username 时走 uid（不为 username 多发一次解析请求） */
      const definition: AiToolDefinition =
        new NgaGetUserTool().getDefinition(new AiToolContext())
      const description: string = propertyDescription(definition, 'username')
      expect(description.indexOf('以 uid 为准') >= 0).assertTrue()
      expect(description.indexOf('username 优先') < 0).assertTrue()
    })

    it('readThreadDescriptionMatchesBudgetBehavior', 0, (): void => {
      /**
       * 单楼不再有独立的 1800 字死上限：正文只受 max_chars 约束，
       * 否则模型把 max_chars 调大也读不到长楼后半段。
       */
      const definition: AiToolDefinition =
        new NgaReadThreadTool().getDefinition(new AiToolContext())
      expect(definition.description.indexOf('1800') < 0).assertTrue()
      expect(definition.description.indexOf('max_chars') >= 0).assertTrue()
      expect(definition.description.indexOf('未展示') >= 0).assertTrue()
      expect(propertyDescription(definition, 'max_chars').indexOf('20000') >= 0).assertTrue()
      expect(propertyDescription(definition, 'max_floors').indexOf('跨页') >= 0).assertTrue()
    })

    it('webFetchDeclaresProtocolRequirement', 0, (): void => {
      /** 描述声明「必须是 http / https 开头」，实现也必须拒绝裸域名 */
      const definition: AiToolDefinition = new WebFetchTool().getDefinition(new AiToolContext())
      expect(definition.description.indexOf('http') >= 0).assertTrue()
      expect(propertyDescription(definition, 'url').indexOf('http') >= 0).assertTrue()
    })

    it('webSearchNormalizesResultCount', 0, (): void => {
      /** 模型常把整数写成字符串；忽略它会让「要 10 条」静默退化成 5 条 */
      expect(normalizeResultCount(5)).assertEqual(5)
      expect(normalizeResultCount('5')).assertEqual(5)
      expect(normalizeResultCount('abc')).assertEqual(5)
      expect(normalizeResultCount(99)).assertEqual(10)
      expect(normalizeResultCount(0)).assertEqual(1)
      expect(normalizeResultCount(undefined)).assertEqual(5)
    })

    it('searchTopicsSaysClientTruncates', 0, (): void => {
      /** 实际是客户端先截断再检索，描述不能写成「被服务端拒绝并截断」 */
      const definition: AiToolDefinition =
        new NgaSearchTopicsTool().getDefinition(new AiToolContext())
      expect(propertyDescription(definition, 'key').indexOf('客户端截断') >= 0).assertTrue()
      expect(definition.description.indexOf('客户端截断') >= 0).assertTrue()
    })

    it('favoritesLimitOnlyAppliesToFolderMode', 0, (): void => {
      /** 列收藏夹时不消费 limit，描述必须说明它只在主题模式生效 */
      const definition: AiToolDefinition =
        new NgaListFavoritesTool().getDefinition(new AiToolContext())
      expect(propertyDescription(definition, 'limit').indexOf('仅在传入 folder_id 时生效') >= 0)
        .assertTrue()
    })

    it('historyCapMatchesStoreConstant', 0, (): void => {
      /** 工具描述里的 500 必须来自 HistoryStore 的同一个常量，不能是第二份抄写 */
      expect(HISTORY_MAX_COUNT).assertEqual(500)
      const definition: AiToolDefinition =
        new NgaMyHistoryTool().getDefinition(new AiToolContext())
      expect(definition.description.indexOf('最多保留 ' + HISTORY_MAX_COUNT.toString()) >= 0)
        .assertTrue()
    })
  })
}
