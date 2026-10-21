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
}
