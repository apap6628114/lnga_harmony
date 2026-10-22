import { describe, it, expect } from '@ohos/hypium'
import { parseMd, parseInline } from '../main/ets/parser/md/MdParser'
import { MdNode, MdNodeType } from '../main/ets/model/MdNode'
import {
  AiApiProtocol,
  AiProviderKind,
  AiProviderProfile,
  DEFAULT_AI_MAX_AGENT_STEPS,
  DEFAULT_DEEPSEEK_ENDPOINT,
  SEARCH_PROVIDER_DEEPSEEK,
  clampAgentSteps,
  clampAiTemperature,
  hasToolSwitchesOn,
  normalizeAiProfile
} from '../main/ets/model/AiConfig'
import {
  AiSearchProfile,
  migrateSearchProfileFromChat,
  normalizeAiSearchProfile
} from '../main/ets/model/AiSearchConfig'
import {
  buildChatUrl,
  buildModelsUrl,
  buildToolsUrl,
  extractServerError,
  parseModelList,
  stripProtocolSuffix
} from '../main/ets/service/ai/AiEndpoint'
import { AiModelInfo } from '../main/ets/model/AiModelInfo'
import { parseArguments } from '../main/ets/service/ai/tools/WebSearchTool'
import { aiSearchProviderRegistry } from '../main/ets/service/ai/search/SearchProviderRegistry'
import { AiSearchProvider } from '../main/ets/service/ai/search/AiSearchProvider'
import { AiToolResult } from '../main/ets/service/ai/tools/AiToolAdapter'
import {
  FRESHNESS_AUTO,
  FRESHNESS_FRESH,
  LONG_TTL_MS,
  SHORT_TTL_MS,
  ToolCacheQuery,
  ToolResultCache,
  buildCacheQuery,
  normalizeToolArguments,
  toolCacheTtlMs
} from '../main/ets/service/ai/tools/ToolResultCache'
import {
  hasThrottleSignal,
  isWritableOperation,
  looksLikeThrottle,
  retryDelayMs
} from '../main/ets/service/api/NgaThrottleSignals'
import { Throttler } from '../main/ets/common/concurrency/Throttler'

/**
 * 构造一个成功工具结果（缓存用例复用）。
 *
 * @param content - 正文
 * @returns 工具结果
 */
function makeOkResult(content: string): AiToolResult {
  const result: AiToolResult = new AiToolResult()
  result.success = true
  result.content = content
  return result
}

/**
 * AI 链路纯逻辑回归测试。
 *
 * 覆盖三个最容易静默回归的契约：
 * 1. Markdown 新增块级元素（表格 / 图片 / 任务列表 / 嵌套列表 / 裸链接）的 AST 形状；
 * 2. 旧版本 AI 配置迁移（缺失字段补默认值，不能把 undefined 带进请求）；
 * 3. 端点派生（自定义服务商端点形态差异）与 `/models` 响应解析。
 */
export default function aiUnitTest(): void {
  describe('aiMarkdown', (): void => {
    it('parsesGfmTableWithAlignmentAndColumnFill', 0, (): void => {
      const nodes: MdNode[] = parseMd('| 名称 | 数量 |\n| :--- | ---: |\n| 苹果 | 3 |\n| 香蕉 |\n')
      expect(nodes.length).assertEqual(1)
      expect(nodes[0].type).assertEqual(MdNodeType.TABLE)
      /** 表头 + 两行数据 */
      expect(nodes[0].children.length).assertEqual(3)
      expect(nodes[0].children[0].level).assertEqual(1)
      /** 每行列数按表头补齐 */
      expect(nodes[0].children[1].children.length).assertEqual(2)
      expect(nodes[0].children[2].children.length).assertEqual(2)
      expect(nodes[0].children[0].children[0].align).assertEqual('left')
      expect(nodes[0].children[0].children[1].align).assertEqual('right')
      expect(nodes[0].children[1].children[0].children[0].text).assertEqual('苹果')
      /** 缺列补空单元格，不产生 undefined 节点 */
      expect(nodes[0].children[2].children[1].children.length).assertEqual(0)
    })

    it('keepsPipeParagraphWhenDividerIsMissing', 0, (): void => {
      const nodes: MdNode[] = parseMd('a | b\n普通文字')
      expect(nodes.length).assertEqual(1)
      expect(nodes[0].type).assertEqual(MdNodeType.PARAGRAPH)
    })

    it('parsesBlockImageLine', 0, (): void => {
      const nodes: MdNode[] = parseMd('![示意图](https://example.com/a.png)')
      expect(nodes.length).assertEqual(1)
      expect(nodes[0].type).assertEqual(MdNodeType.IMAGE)
      expect(nodes[0].text).assertEqual('示意图')
      expect(nodes[0].href).assertEqual('https://example.com/a.png')
    })

    it('marksTaskListItems', 0, (): void => {
      const nodes: MdNode[] = parseMd('- [ ] 待办\n- [x] 已完成\n- 普通项')
      expect(nodes.length).assertEqual(1)
      const items: MdNode[] = nodes[0].children
      expect(items.length).assertEqual(3)
      expect(items[0].checked).assertEqual(0)
      expect(items[1].checked).assertEqual(1)
      expect(items[2].checked).assertEqual(-1)
      expect(items[1].children[0].text).assertEqual('已完成')
    })

    it('nestsIndentedListItemAsSubList', 0, (): void => {
      const nodes: MdNode[] = parseMd('- 父项\n  - 子项一\n  - 子项二\n- 同级项')
      expect(nodes.length).assertEqual(1)
      const parent: MdNode = nodes[0].children[0]
      expect(parent.children.length).assertEqual(2)
      const subList: MdNode = parent.children[1]
      expect(subList.type).assertEqual(MdNodeType.UNORDERED_LIST)
      expect(subList.children.length).assertEqual(2)
      expect(subList.children[0].children[0].text).assertEqual('子项一')
      /** 同级项仍挂在顶层列表 */
      expect(nodes[0].children.length).assertEqual(2)
    })

    it('autoLinksBareUrlsAndStripsTrailingPunctuation', 0, (): void => {
      const inline: MdNode[] = parseInline('见 https://example.com/a。')
      let linkCount: number = 0
      let linkHref: string = ''
      for (let i: number = 0; i < inline.length; i++) {
        if (inline[i].type === MdNodeType.LINK) {
          linkCount++
          linkHref = inline[i].href
        }
      }
      expect(linkCount).assertEqual(1)
      expect(linkHref).assertEqual('https://example.com/a')
    })

    it('keepsBoldContentWhenItContainsBareUrl', 0, (): void => {
      const inline: MdNode[] = parseInline('**看 https://example.com**')
      expect(inline.length).assertEqual(1)
      expect(inline[0].type).assertEqual(MdNodeType.BOLD)
      /** 链接把粗体拆成多个子节点，text 为空但 children 保留内容 */
      expect(inline[0].text).assertEqual('')
      expect(inline[0].children.length > 0).assertTrue()
    })
  })

  describe('aiConfigMigration', (): void => {
    it('fillsDefaultsForLegacyProfile', 0, (): void => {
      /** 模拟旧版本持久化：协议 / 工具 / Agent 字段在 JSON 里不存在 */
      const legacyJson: string = '{"id":"ai_1","name":"旧配置",' +
        '"endpoint":"https://api.deepseek.com","apiKey":"sk-test",' +
        '"modelName":"deepseek-v4-flash","temperature":0.7}'
      const normalized: AiProviderProfile =
        normalizeAiProfile(JSON.parse(legacyJson) as AiProviderProfile)

      expect(normalized.presetId).assertEqual(AiProviderKind.DEEPSEEK)
      expect(normalized.protocol).assertEqual(AiApiProtocol.RESPONSES)
      expect(normalized.toolsEnabled).assertTrue()
      expect(normalized.enableWebSearch).assertTrue()
      expect(normalized.enableWebFetch).assertTrue()
      expect(normalized.maxAgentSteps).assertEqual(DEFAULT_AI_MAX_AGENT_STEPS)
      expect(normalized.toolsEndpoint).assertEqual('https://api.deepseek.com')
    })

    it('infersChatCompletionsForNonDeepSeekEndpoint', 0, (): void => {
      const customJson: string = '{"endpoint":"https://api.openai.com/v1",' +
        '"apiKey":"sk-test","modelName":"gpt-4o-mini"}'
      const normalized: AiProviderProfile =
        normalizeAiProfile(JSON.parse(customJson) as AiProviderProfile)
      expect(normalized.presetId).assertEqual(AiProviderKind.CUSTOM)
      expect(normalized.protocol).assertEqual(AiApiProtocol.CHAT_COMPLETIONS)
    })

    it('migratesLegacyToolKeyIntoSeparateSearchProfile', 0, (): void => {
      const chat: AiProviderProfile = new AiProviderProfile()
      chat.endpoint = DEFAULT_DEEPSEEK_ENDPOINT
      chat.apiKey = 'sk-chat'

      const migrated: AiSearchProfile = migrateSearchProfileFromChat(chat)
      expect(migrated.providerKind).assertEqual(SEARCH_PROVIDER_DEEPSEEK)
      expect(migrated.apiKey).assertEqual('sk-chat')

      chat.toolsApiKey = 'sk-tool'
      expect(migrateSearchProfileFromChat(chat).apiKey).assertEqual('sk-tool')

      chat.toolsEnabled = false
      expect(hasToolSwitchesOn(chat)).assertFalse()
    })

    it('defaultsSearchProviderAndKeepsKnownValue', 0, (): void => {
      const legacyJson: string = '{"endpoint":"https://api.deepseek.com",' +
        '"apiKey":"sk-test","modelName":"deepseek-flash"}'
      const normalized: AiProviderProfile =
        normalizeAiProfile(JSON.parse(legacyJson) as AiProviderProfile)
      expect(normalized.searchProvider).assertEqual(SEARCH_PROVIDER_DEEPSEEK)

      const withProvider: AiProviderProfile = new AiProviderProfile()
      withProvider.searchProvider = 'future-provider'
      expect(normalizeAiProfile(withProvider).searchProvider).assertEqual('future-provider')
    })

    it('clampsTemperatureAndAgentSteps', 0, (): void => {
      expect(clampAiTemperature(9)).assertEqual(2)
      expect(clampAiTemperature(-1)).assertEqual(0)
      expect(clampAgentSteps(1000)).assertEqual(1000)
      expect(clampAgentSteps(1001)).assertEqual(1000)
      expect(clampAgentSteps(0)).assertEqual(1)
    })
  })

  describe('aiEndpoint', (): void => {
    it('derivesChatUrlForBothProtocols', 0, (): void => {
      expect(buildChatUrl('https://api.deepseek.com', AiApiProtocol.RESPONSES))
        .assertEqual('https://api.deepseek.com/responses')
      expect(buildChatUrl('https://api.example.com/v1', AiApiProtocol.CHAT_COMPLETIONS))
        .assertEqual('https://api.example.com/v1/chat/completions')
      /** 用户已填完整路径时原样使用，不重复拼接 */
      expect(buildChatUrl('https://api.example.com/v1/chat/completions', AiApiProtocol.RESPONSES))
        .assertEqual('https://api.example.com/v1/chat/completions')
    })

    it('derivesModelsAndToolsUrls', 0, (): void => {
      expect(buildModelsUrl('https://api.deepseek.com/responses')).assertEqual('https://api.deepseek.com/models')
      expect(buildModelsUrl('https://api.example.com/v1/')).assertEqual('https://api.example.com/v1/models')
      expect(buildToolsUrl('https://api.deepseek.com', 'search'))
        .assertEqual('https://api.deepseek.com/v1/tools/search')
      expect(buildToolsUrl('https://api.deepseek.com/v1', 'fetch'))
        .assertEqual('https://api.deepseek.com/v1/tools/fetch')
      expect(buildToolsUrl('https://proxy.example.com/v1/tools/search', 'search'))
        .assertEqual('https://proxy.example.com/v1/tools/search')
      /** 端点填了完整工具路径时，fetch 必须重建为 fetch 路径 */
      expect(buildToolsUrl('https://proxy.example.com/v1/tools/search', 'fetch'))
        .assertEqual('https://proxy.example.com/v1/tools/fetch')
      expect(stripProtocolSuffix('https://api.example.com/v1/responses')).assertEqual('https://api.example.com/v1')
    })

    it('parsesOpenAiModelListAndDeduplicates', 0, (): void => {
      const text: string = '{"object":"list","data":[' +
        '{"id":"deepseek-flash","name":"DeepSeek-V4.1-Flash","context_window":1048576,"input_modalities":["text","image"]},' +
        '{"id":"deepseek-v4-pro","context_window":1048576},' +
        '{"id":"deepseek-flash"}]}'
      const models: AiModelInfo[] = parseModelList(text)
      expect(models.length).assertEqual(2)
      expect(models[0].id).assertEqual('deepseek-flash')
      expect(models[0].displayName).assertEqual('DeepSeek-V4.1-Flash')
      expect(models[0].contextWindow).assertEqual(1048576)
      expect(models[0].supportsImage).assertTrue()
      expect(models[1].id).assertEqual('deepseek-v4-pro')
      expect(models[1].supportsImage).assertFalse()
    })

    it('parsesBareArrayModelList', 0, (): void => {
      const models: AiModelInfo[] = parseModelList('[{"id":"m1"},{"id":"m2"}]')
      expect(models.length).assertEqual(2)
      expect(models[1].id).assertEqual('m2')
    })

    it('extractsServerErrorMessageSafely', 0, (): void => {
      expect(extractServerError('{"error":{"message":"bad key"}}')).assertEqual('bad key')
      expect(extractServerError('{"message":"boom"}')).assertEqual('boom')
      expect(extractServerError('plain text error')).assertEqual('plain text error')
      expect(extractServerError('')).assertEqual('')
    })

    it('parsesToolArgumentsDefensively', 0, (): void => {
      expect(parseArguments('{"query":"nga"}')['query'] as string).assertEqual('nga')
      expect(Object.keys(parseArguments('not-json')).length).assertEqual(0)
      expect(Object.keys(parseArguments('')).length).assertEqual(0)
      expect(Object.keys(parseArguments('[1,2]')).length).assertEqual(0)
    })
  })

  describe('aiSearchProvider', (): void => {
    it('registersDeepSeekAsOnlyProvider', 0, (): void => {
      expect(aiSearchProviderRegistry.list().length).assertEqual(1)
      expect(aiSearchProviderRegistry.list()[0].getKind()).assertEqual(SEARCH_PROVIDER_DEEPSEEK)
      expect(aiSearchProviderRegistry.isRegistered(SEARCH_PROVIDER_DEEPSEEK)).assertTrue()
    })

    it('fallsBackToDefaultForUnknownProviderKind', 0, (): void => {
      const provider: AiSearchProvider = aiSearchProviderRegistry.get('not-registered')
      expect(provider.getKind()).assertEqual(SEARCH_PROVIDER_DEEPSEEK)
      expect(aiSearchProviderRegistry.isRegistered('not-registered')).assertFalse()
    })

    it('reportsAvailabilityFromSearchProfileKey', 0, (): void => {
      const profile: AiSearchProfile = new AiSearchProfile()
      const provider: AiSearchProvider = aiSearchProviderRegistry.get(profile.providerKind)
      expect(provider.isAvailable(profile)).assertFalse()

      profile.apiKey = 'sk-ds'
      expect(provider.isAvailable(profile)).assertTrue()
      expect(provider.getUnavailableHint().length > 0).assertTrue()
    })

    it('normalizesSearchProfileEndpointAndProvider', 0, (): void => {
      const legacyJson: string = '{"name":"旧搜索"}'
      const normalized: AiSearchProfile =
        normalizeAiSearchProfile(JSON.parse(legacyJson) as AiSearchProfile)
      expect(normalized.providerKind).assertEqual(SEARCH_PROVIDER_DEEPSEEK)
      expect(normalized.endpoint).assertEqual('https://api.deepseek.com')
      expect(normalized.apiKey).assertEqual('')
    })
  })

  describe('aiToolCache', (): void => {
    it('derivesTtlFromCatalogMetadata', 0, (): void => {
      /** 开放世界（联网）不缓存：结果依赖站外实时内容 */
      expect(toolCacheTtlMs('web_search')).assertEqual(0)
      expect(toolCacheTtlMs('web_fetch')).assertEqual(0)
      /** 零参数上下文工具不缓存：没有网络请求，缓存只会拖长可用性清单的滞后 */
      expect(toolCacheTtlMs('get_context')).assertEqual(0)
      /** 未收录工具一律不缓存（新增工具必须先进目录） */
      expect(toolCacheTtlMs('not_a_tool')).assertEqual(0)
      /** 重接口走长 TTL，列表类走短 TTL */
      expect(toolCacheTtlMs('nga_read_thread')).assertEqual(LONG_TTL_MS)
      expect(toolCacheTtlMs('nga_list_topics')).assertEqual(SHORT_TTL_MS)
    })

    it('normalizesArgumentsForStableKeys', 0, (): void => {
      /** 键顺序不同的同一意图必须折叠成同一个键 */
      expect(normalizeToolArguments('{"b":2,"a":1}')).assertEqual('{"a":"1","b":"2"}')
      expect(normalizeToolArguments('{"a":1,"b":2}')).assertEqual('{"a":"1","b":"2"}')
      /** freshness 是取数意图，不是数据参数，不能参与拼键 */
      expect(normalizeToolArguments('{"a":1,"freshness":"fresh"}')).assertEqual('{"a":"1"}')
      expect(normalizeToolArguments('')).assertEqual('')
      /** 解析失败退回原文：宁可少命中，也不要把不同参数折叠成同一个键 */
      expect(normalizeToolArguments('not-json')).assertEqual('not-json')
      /** 值里含分隔符也不能伪造出与另一组参数相同的键 */
      const oneValue: string = normalizeToolArguments('{"key":"x&page=2"}')
      const twoValues: string = normalizeToolArguments('{"key":"x","page":"2"}')
      expect(oneValue === twoValues).assertFalse()
    })

    it('isolatesCacheBucketByUidAndParsesFreshness', 0, (): void => {
      const u1: ToolCacheQuery = buildCacheQuery('nga_read_thread', '111', '{"tid":"1"}')
      const u2: ToolCacheQuery = buildCacheQuery('nga_read_thread', '222', '{"tid":"1"}')
      expect(u1.key === u2.key).assertFalse()

      const fresh: ToolCacheQuery =
        buildCacheQuery('nga_read_thread', '111', '{"tid":"1","freshness":"fresh"}')
      expect(fresh.freshness).assertEqual(FRESHNESS_FRESH)
      /** freshness 不改变键：fresh 只是跳过读，写回仍落在同一条缓存上 */
      expect(fresh.key).assertEqual(u1.key)

      const bogus: ToolCacheQuery =
        buildCacheQuery('nga_read_thread', '111', '{"freshness":"whatever"}')
      expect(bogus.freshness).assertEqual(FRESHNESS_AUTO)
    })

    it('keysIncludePageContextFingerprint', 0, (): void => {
      /** 参数缺省时（省略 tid 读「当前帖」），不同页面上下文必须算出不同键 */
      const inThreadA: ToolCacheQuery =
        buildCacheQuery('nga_read_thread', '111', '{}', '100|0|111|7')
      const inThreadB: ToolCacheQuery =
        buildCacheQuery('nga_read_thread', '111', '{}', '200|0|111|7')
      expect(inThreadA.key === inThreadB.key).assertFalse()

      /** 同一帖子内用同样参数重复取数，必须命中同一个键 */
      const again: ToolCacheQuery =
        buildCacheQuery('nga_read_thread', '111', '{}', '100|0|111|7')
      expect(again.key).assertEqual(inThreadA.key)
    })

    it('refusesCacheKeyForUnparsableArguments', 0, (): void => {
      /**
       * 参数不是合法 JSON 时，真实输入会走 fallbackQuery 兜底，
       * 键无法代表它——必须拒绝缓存，否则会拿错误的键存不同的内容。
       */
      const broken: ToolCacheQuery = buildCacheQuery('nga_read_thread', '111', 'not-json', '')
      expect(broken.key).assertEqual('')

      /** 空串是合法的「无参数」调用，仍可缓存 */
      const empty: ToolCacheQuery = buildCacheQuery('nga_read_thread', '111', '', '')
      expect(empty.key.length > 0).assertTrue()
    })

    it('separatesFallbackQueryOnlyWhenArgumentsAreEmpty', 0, (): void => {
      /**
       * 完全没给参数时，搜索类工具会拿「最后一条用户消息」兜底取数，
       * 而这个兜底源不在上下文指纹里——必须并入键，否则两个不同问题会互相命中。
       */
      const askA: ToolCacheQuery =
        buildCacheQuery('nga_search_topics', '111', '{}', '100|0|111|7', '问 A')
      const askB: ToolCacheQuery =
        buildCacheQuery('nga_search_topics', '111', '{}', '100|0|111|7', '问 B')
      expect(askA.key === askB.key).assertFalse()

      /** 给了显式参数就不依赖兜底，问题文本变化不应打散缓存 */
      const explicitA: ToolCacheQuery =
        buildCacheQuery('nga_search_topics', '111', '{"key":"abc"}', '100|0|111|7', '问 A')
      const explicitB: ToolCacheQuery =
        buildCacheQuery('nga_search_topics', '111', '{"key":"abc"}', '100|0|111|7', '问 B')
      expect(explicitA.key).assertEqual(explicitB.key)
    })

    it('cachesOnlySuccessfulResultsAndExpires', 0, (): void => {
      let now: number = 1000
      const cache: ToolResultCache = new ToolResultCache(10, (): number => now)
      cache.set('k', makeOkResult('body'), 100)
      expect(cache.size).assertEqual(1)

      const hit: AiToolResult | null = cache.get('k')
      expect(hit !== null).assertTrue()
      if (hit !== null) {
        expect(hit.content).assertEqual('body')
        expect(hit.fromCache).assertTrue()
      }

      /** 过期后必须彻底消失，不能返回 stale 数据 */
      now = 1200
      expect(cache.get('k') === null).assertTrue()
      expect(cache.size).assertEqual(0)

      /** 失败结果不缓存：缓存一次失败会让后续 10 分钟都拿不到真实数据 */
      const bad: AiToolResult = new AiToolResult()
      bad.success = false
      bad.content = 'err'
      cache.set('bad', bad, 100)
      expect(cache.get('bad') === null).assertTrue()

      /** 空正文不缓存（避免把「取到但没有内容」固化成稳定结论） */
      cache.set('empty', makeOkResult(''), 100)
      expect(cache.get('empty') === null).assertTrue()
    })

    it('evictsLeastRecentlyUsed', 0, (): void => {
      const cache: ToolResultCache = new ToolResultCache(2, (): number => 0)
      cache.set('a', makeOkResult('a'), 1000)
      cache.set('b', makeOkResult('b'), 1000)
      /** 读一次 a，把 b 变成最久未使用 */
      cache.get('a')
      cache.set('c', makeOkResult('c'), 1000)
      expect(cache.get('a') !== null).assertTrue()
      expect(cache.get('b') === null).assertTrue()
      expect(cache.get('c') !== null).assertTrue()
    })

    it('invalidatesPerAccount', 0, (): void => {
      const q1: ToolCacheQuery = buildCacheQuery('nga_read_thread', '111', '{"tid":"1"}')
      const q2: ToolCacheQuery = buildCacheQuery('nga_read_thread', '222', '{"tid":"1"}')
      const cache: ToolResultCache = new ToolResultCache(10, (): number => 0)
      cache.set(q1.key, makeOkResult('u1'), 1000)
      cache.set(q2.key, makeOkResult('u2'), 1000)

      cache.invalidateUser('111')
      expect(cache.get(q1.key) === null).assertTrue()
      /** 另一个账号的数据不受影响 */
      expect(cache.get(q2.key) !== null).assertTrue()
    })
  })

  describe('ngaThrottleSignals', (): void => {
    it('treatsWritesAsNonRetryable', 0, (): void => {
      /** 发帖 / 回复：重试就是重复提交 */
      expect(isWritableOperation('post', 'reply')).assertTrue()
      expect(isWritableOperation('post', 'new')).assertTrue()
      /** 取发帖分类是读；推荐 / 反对是状态变更，必须按写处理 */
      expect(isWritableOperation('post', 'titletype')).assertFalse()
      expect(isWritableOperation('post', 'recommend')).assertTrue()
      /** subject 族用只读白名单，未知 act 保守按写处理 */
      expect(isWritableOperation('subject', 'vote')).assertTrue()
      expect(isWritableOperation('subject', 'subscription')).assertTrue()
      expect(isWritableOperation('subject', 'list')).assertFalse()
      expect(isWritableOperation('subject', 'search')).assertFalse()
      expect(isWritableOperation('subject', 'unknown_act')).assertTrue()
      /** 收藏 / 签到 / 关注 / 私信 */
      expect(isWritableOperation('topic_favor_v2', 'add')).assertTrue()
      expect(isWritableOperation('topic_favor_v2', 'list_folder')).assertFalse()
      expect(isWritableOperation('check_in', 'check_in')).assertTrue()
      expect(isWritableOperation('follow_v2', 'get_follow')).assertFalse()
      expect(isWritableOperation('follow_v2', 'follow')).assertTrue()
      expect(isWritableOperation('message', 'list')).assertFalse()
      expect(isWritableOperation('message', 'send')).assertTrue()
      /** 用户发帖 / 回帖记录是只读，必须保留重试能力 */
      expect(isWritableOperation('user', 'replys')).assertFalse()
      expect(isWritableOperation('user', 'subjects')).assertFalse()
      expect(isWritableOperation('load_topic', 'load_topic_by_uid')).assertFalse()
      /** 未知组合默认按写处理：不重试只是体验降级，重复提交是数据事故 */
      expect(isWritableOperation('ncp', 'something_new')).assertTrue()
      expect(isWritableOperation('', '')).assertTrue()
    })

    it('detectsThrottleTextButNotOrdinaryErrors', 0, (): void => {
      expect(looksLikeThrottle('您的操作过于频繁，请稍后再试')).assertTrue()
      expect(looksLikeThrottle('Too Many Requests')).assertTrue()
      expect(looksLikeThrottle('rate limit exceeded')).assertTrue()
      /** 普通业务错误绝不能触发冷却，否则一次正常报错会把全站拖进 60 秒冷却 */
      expect(looksLikeThrottle('主题不存在')).assertFalse()
      expect(looksLikeThrottle('请稍后再试')).assertFalse()
      expect(looksLikeThrottle('')).assertFalse()
    })

    it('backsOffExponentiallyWithCap', 0, (): void => {
      expect(retryDelayMs(1)).assertEqual(400)
      expect(retryDelayMs(2)).assertEqual(800)
      expect(retryDelayMs(3)).assertEqual(1600)
      /** 3200 封顶到 3000 */
      expect(retryDelayMs(4)).assertEqual(3000)
      expect(retryDelayMs(0)).assertEqual(0)
    })

    it('detectsThrottleAcrossResponseShapes', 0, (): void => {
      /** app_api 业务失败形态：{code, msg}，15 = 频率限制 */
      const appCode: Record<string, Object> =
        JSON.parse('{"code":15,"msg":"操作过于频繁"}') as Record<string, Object>
      expect(hasThrottleSignal(appCode)).assertTrue()
      /** code 以字符串下发时同样要命中 */
      const appCodeText: Record<string, Object> =
        JSON.parse('{"code":"15"}') as Record<string, Object>
      expect(hasThrottleSignal(appCodeText)).assertTrue()
      /** 文案不含关键词、只有错误码为 15，也必须命中 */
      const codeOnly: Record<string, Object> =
        JSON.parse('{"error":{"0":"请求失败","2":15}}') as Record<string, Object>
      expect(hasThrottleSignal(codeOnly)).assertTrue()
      /** HTML 错误页归一化形态 */
      const topCode: Record<string, Object> =
        JSON.parse('{"error_code":15}') as Record<string, Object>
      expect(hasThrottleSignal(topCode)).assertTrue()
      /** 正常成功响应不能被误判 */
      const ok: Record<string, Object> =
        JSON.parse('{"code":0,"result":{}}') as Record<string, Object>
      expect(hasThrottleSignal(ok)).assertFalse()
      /** 帖子正文里出现风控词，绝不能触发全站冷却 */
      const body: Record<string, Object> =
        JSON.parse('{"__T":{"0":{"subject":"刷新太快怎么办"}}}') as Record<string, Object>
      expect(hasThrottleSignal(body)).assertFalse()
    })
  })

  describe('ngaThrottlerGate', (): void => {
    it('rejectsAcquireDuringCooldown', 0, async (): Promise<void> => {
      const throttler: Throttler = new Throttler(1, 0, 100, 60000)
      expect(throttler.isCoolingDown()).assertFalse()

      throttler.enterCooldown(10000)
      expect(throttler.isCoolingDown()).assertTrue()
      expect(throttler.cooldownRemainingMs() > 0).assertTrue()

      let rejected: boolean = false
      try {
        await throttler.acquire('example.com')
      } catch (e) {
        rejected = true
      }
      expect(rejected).assertTrue()
    })

    it('keepsTheLaterDeadlineOnRepeatedCooldown', 0, (): void => {
      const throttler: Throttler = new Throttler(1, 0, 100, 60000)
      throttler.enterCooldown(20000)
      const longer: number = throttler.cooldownRemainingMs()
      /** 短冷却不能覆盖掉长冷却 */
      throttler.enterCooldown(1000)
      expect(throttler.cooldownRemainingMs() > longer - 1000).assertTrue()
    })
  })
}
