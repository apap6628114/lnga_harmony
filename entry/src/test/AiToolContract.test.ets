import { describe, it, expect } from '@ohos/hypium'
import {
  AI_TOOL_CATALOG,
  AiToolMeta,
  AiToolSettings,
  findAiToolMeta
} from '../main/ets/model/AiToolConfig'
import { AiToolContext, TOOL_ERROR_BAD_ARGS, TOOL_ERROR_UNAVAILABLE } from '../main/ets/service/ai/tools/AiToolAdapter'
import type { AiToolResult } from '../main/ets/service/ai/tools/AiToolAdapter'
import { AiToolDefinition } from '../main/ets/service/ai/AiProtocolTypes'
import { AiToolRegistry, aiToolRegistry } from '../main/ets/service/ai/tools/ToolRegistry'
import { GetContextTool } from '../main/ets/service/ai/tools/ContextTool'

/**
 * 工具契约回归测试。
 *
 * 覆盖三类"改代码时不会报错、上线后才发现"的静默回归：
 * 1. 目录（AI_TOOL_CATALOG）与注册表漂移：新增工具漏登记、删除工具留死条目；
 * 2. 工具定义 Schema 不合规：required 指向不存在的字段、参数没有 description、
 *    enum 为空数组——这些会让模型猜参数、发出无效调用；
 * 3. 可用性判定与失败分类：未登录时的工具集合、缺参时的 errorCode。
 *
 * 全部用例不发网络请求：只走定义、可用性与参数校验分支。
 */
export default function aiToolContractTest(): void {
  describe('aiToolContract', (): void => {
    it('catalogAndRegistryAgree', 0, (): void => {
      const registered: string[] = aiToolRegistry.getRegisteredNames()
      expect(registered.length).assertEqual(AI_TOOL_CATALOG.length)
      for (let i: number = 0; i < AI_TOOL_CATALOG.length; i++) {
        const name: string = AI_TOOL_CATALOG[i].name
        expect(registered.indexOf(name) >= 0).assertTrue()
        /* 顺序也要一致：tools 声明逐轮稳定是前缀缓存的前提 */
        expect(registered[i]).assertEqual(name)
      }
      for (let i: number = 0; i < registered.length; i++) {
        const meta: AiToolMeta | null = findAiToolMeta(registered[i])
        expect(meta !== null).assertTrue()
      }
    })

    it('hasNoDuplicateToolNames', 0, (): void => {
      const seen: string[] = []
      for (let i: number = 0; i < AI_TOOL_CATALOG.length; i++) {
        const name: string = AI_TOOL_CATALOG[i].name
        expect(seen.indexOf(name) < 0).assertTrue()
        seen.push(name)
      }
      const registered: string[] = aiToolRegistry.getRegisteredNames()
      for (let i: number = 0; i < registered.length; i++) {
        expect(registered.indexOf(registered[i]) === i).assertTrue()
      }
    })

    it('registerIsIdempotent', 0, (): void => {
      const registry: AiToolRegistry = new AiToolRegistry()
      registry.register(new GetContextTool((ctx: AiToolContext): string[] =>
        registry.getAvailableNames(ctx)))
      registry.register(new GetContextTool((ctx: AiToolContext): string[] =>
        registry.getAvailableNames(ctx)))
      expect(registry.getRegisteredNames().length).assertEqual(1)
    })

    it('everyDefinitionHasObjectSchema', 0, (): void => {
      const definitions: AiToolDefinition[] = aiToolRegistry.getDefinitions(makeContext(true))
      expect(definitions.length > 0).assertTrue()
      for (let i: number = 0; i < definitions.length; i++) {
        const definition: AiToolDefinition = definitions[i]
        expect(definition.name.length > 0).assertTrue()
        expect(definition.description.length > 10).assertTrue()
        const parameters: Record<string, Object> = definition.parameters
        expect(parameters['type'] as string).assertEqual('object')
        expect(parameters['additionalProperties'] as boolean).assertFalse()
        const properties: Record<string, Object> = parameters['properties'] as Record<string, Object>
        expect(properties !== null && properties !== undefined).assertTrue()
        const required: Object[] = parameters['required'] as Object[]
        expect(required !== null && required !== undefined).assertTrue()
        const propertyKeys: string[] = Object.keys(properties)
        for (let j: number = 0; j < required.length; j++) {
          const key: string = required[j] as string
          expect(propertyKeys.indexOf(key) >= 0).assertTrue()
        }
      }
    })

    it('everyPropertyIsDocumented', 0, (): void => {
      const definitions: AiToolDefinition[] = aiToolRegistry.getDefinitions(makeContext(true))
      for (let i: number = 0; i < definitions.length; i++) {
        const properties: Record<string, Object> =
          definitions[i].parameters['properties'] as Record<string, Object>
        const keys: string[] = Object.keys(properties)
        for (let j: number = 0; j < keys.length; j++) {
          const property: Record<string, Object> = properties[keys[j]] as Record<string, Object>
          const type: string = property['type'] as string
          expect(type.length > 0).assertTrue()
          const description: string = property['description'] as string
          expect(description.length > 0).assertTrue()
          const enumValues: Object[] | undefined = property['enum'] as Object[] | undefined
          if (enumValues !== undefined) {
            expect(enumValues.length > 0).assertTrue()
          }
        }
      }
    })

    it('titleAndAnnotationsComeFromCatalog', 0, (): void => {
      const definitions: AiToolDefinition[] = aiToolRegistry.getDefinitions(makeContext(true))
      for (let i: number = 0; i < definitions.length; i++) {
        const definition: AiToolDefinition = definitions[i]
        const meta: AiToolMeta | null = findAiToolMeta(definition.name)
        expect(meta !== null).assertTrue()
        if (meta === null) {
          continue
        }
        expect(definition.title).assertEqual(meta.title)
        /** 内置工具一律只读；写操作在不开放之前不应出现 destructive */
        expect(definition.annotations.readOnly).assertTrue()
        expect(definition.annotations.destructive).assertFalse()
        expect(definition.annotations.openWorld).assertEqual(meta.openWorld === true)
      }
    })

    it('loggedOutExposesOnlyMetaTools', 0, (): void => {
      const names: string[] = aiToolRegistry.getAvailableNames(makeContext(false))
      /* 未登录时只剩零网络请求的元工具：上下文读取 + 大结果续读 */
      expect(names.length).assertEqual(2)
      expect(names.indexOf('get_context') >= 0).assertTrue()
      expect(names.indexOf('expand_tool_result') >= 0).assertTrue()
    })

    it('loggedInWithoutSearchExposesNgaToolsOnly', 0, (): void => {
      const names: string[] = aiToolRegistry.getAvailableNames(makeContext(true))
      expect(names.indexOf('nga_read_thread') >= 0).assertTrue()
      expect(names.indexOf('nga_get_me') >= 0).assertTrue()
      expect(names.indexOf('nga_user_activity') >= 0).assertTrue()
      /** 未配置搜索服务：联网工具不可用 */
      expect(names.indexOf('web_search') < 0).assertTrue()
      expect(names.indexOf('web_fetch') < 0).assertTrue()
      let ngaCount: number = 0
      for (let i: number = 0; i < names.length; i++) {
        if (names[i].indexOf('nga_') === 0) {
          ngaCount++
        }
      }
      expect(ngaCount).assertEqual(10)
    })

    it('contextToolReportsLoginStateAndBlockedTools', 0, async (): Promise<void> => {
      const context: AiToolContext = makeContext(false)
      const result: AiToolResult = await aiToolRegistry.execute('get_context', '', context, '')
      expect(result.success).assertTrue()
      expect(result.content.indexOf('未登录') >= 0).assertTrue()
      /** 未配置搜索服务时，联网工具应出现在「暂不可用」清单里 */
      expect(result.content.indexOf('web_search') >= 0).assertTrue()
    })

    it('readThreadRejectsPidWithoutTid', 0, async (): Promise<void> => {
      const context: AiToolContext = makeContext(true)
      const result: AiToolResult = await aiToolRegistry.execute('nga_read_thread',
        '{"pid":"123456789"}', context, '')
      expect(result.success).assertFalse()
      expect(result.errorCode).assertEqual(TOOL_ERROR_BAD_ARGS)
      expect(result.content.indexOf('tid') >= 0).assertTrue()
    })

    it('unknownToolReportsUnavailable', 0, async (): Promise<void> => {
      const context: AiToolContext = makeContext(true)
      const result: AiToolResult = await aiToolRegistry.execute('not_a_tool', '{}', context, '')
      expect(result.success).assertFalse()
      expect(result.errorCode).assertEqual(TOOL_ERROR_UNAVAILABLE)
    })

    it('disabledToolDisappearsFromDefinitions', 0, (): void => {
      const context: AiToolContext = makeContext(true)
      context.tools = new AiToolSettings()
      context.tools.enabled['nga_read_thread'] = false
      const names: string[] = aiToolRegistry.getAvailableNames(context)
      expect(names.indexOf('nga_read_thread') < 0).assertTrue()
      expect(names.indexOf('nga_get_me') >= 0).assertTrue()
    })
  })
}

/**
 * 构造测试用的工具执行上下文。
 *
 * @param authenticated - 是否已登录
 * @returns 上下文
 */
function makeContext(authenticated: boolean): AiToolContext {
  const context: AiToolContext = new AiToolContext()
  context.tools = new AiToolSettings()
  context.authenticated = authenticated
  context.token = authenticated ? 'test-token' : ''
  context.selfUid = authenticated ? '12345' : ''
  context.selfUserName = authenticated ? 'tester' : ''
  return context
}
