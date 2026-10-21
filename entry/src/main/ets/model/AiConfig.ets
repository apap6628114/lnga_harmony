/**
 * AI 配置数据模型。
 *
 * 一个配置（profile）描述「用哪个服务商、走哪种协议、用哪个模型」：
 * - DeepSeek 官方：Responses API，端点在预设里预填，用户只需填 Key 并拉取模型；
 * - 自定义服务商：端点、协议、模型全部由用户填写（OpenAI 兼容协议）。
 *
 * 联网工具（web_search / web_fetch）由客户端执行，执行后端固定为
 * DeepSeek 官方 Search / Fetch API，因此工具鉴权与对话鉴权可以不同。
 */

/** AI 温度参数默认值。 */
export const DEFAULT_AI_TEMPERATURE: number = 0.7
/** AI 温度参数最小值。 */
export const MIN_AI_TEMPERATURE: number = 0
/** AI 温度参数最大值。 */
export const MAX_AI_TEMPERATURE: number = 2
/** DeepSeek 官方 API 固定端点。 */
export const DEFAULT_DEEPSEEK_ENDPOINT: string = 'https://api.deepseek.com'
/** DeepSeek 官方 Search / Fetch 工具端点。 */
export const DEFAULT_AI_TOOLS_ENDPOINT: string = 'https://api.deepseek.com'
/** 搜索服务商标识：DeepSeek 官方（当前唯一内置实现）。 */
export const SEARCH_PROVIDER_DEEPSEEK: string = 'deepseek'
/** Agent 单轮对话内允许的最大工具轮数默认值。 */
export const DEFAULT_AI_MAX_AGENT_STEPS: number = 6
/** Agent 工具轮数下限（至少允许一次工具调用）。 */
export const MIN_AI_MAX_AGENT_STEPS: number = 1
/** Agent 工具轮数上限（长链路任务允许极高上限，实际调用仍受取消与超时约束）。 */
export const MAX_AI_MAX_AGENT_STEPS: number = 1000

/**
 * 对话协议。
 *
 * 两种都是 OpenAI 公开的事实标准，自定义服务商只需兼容其一即可接入：
 * - RESPONSES：DeepSeek 官方与 OpenAI 新版 `/responses`；
 * - CHAT_COMPLETIONS：绝大多数第三方兼容服务商的 `/chat/completions`。
 */
export enum AiApiProtocol {
  /** OpenAI Responses API */
  RESPONSES = 'responses',
  /** OpenAI Chat Completions API */
  CHAT_COMPLETIONS = 'chat_completions'
}

/** 服务商类型（决定表单预填策略）。 */
export enum AiProviderKind {
  /** DeepSeek 官方：端点固定、参数预填、只要求填 Key */
  DEEPSEEK = 'deepseek',
  /** 自定义：端点 / 协议 / 模型全部手填 */
  CUSTOM = 'custom'
}

/**
 * AI 提供方配置。
 *
 * 不设置输出长度上限：请求不携带 max_tokens / max_output_tokens，
 * 由服务端按模型自身能力决定单次回复长度，避免客户端魔法值把长回答截断。
 */
export class AiProviderProfile {
  /** 唯一标识（生成时赋值） */
  id: string = ''
  /** 用户命名的方案名称 */
  name: string = ''
  /** 服务商类型（预设） */
  presetId: string = AiProviderKind.DEEPSEEK
  /** 对话 API 端点地址（DeepSeek 固定，自定义手填） */
  endpoint: string = DEFAULT_DEEPSEEK_ENDPOINT
  /** API 密钥（不记录到日志） */
  apiKey: string = ''
  /** 模型名称 */
  modelName: string = ''
  /** 对话协议 */
  protocol: AiApiProtocol = AiApiProtocol.RESPONSES
  /** 温度参数（0.0 - 2.0，默认 0.7） */
  temperature: number = DEFAULT_AI_TEMPERATURE
  /** 是否启用客户端工具（web_search / web_fetch） */
  toolsEnabled: boolean = true
  /** 是否启用联网搜索工具 */
  enableWebSearch: boolean = true
  /** 是否启用网页抓取工具 */
  enableWebFetch: boolean = true
  /**
   * 旧版搜索服务商标识（仅用于迁移到独立搜索配置）。
   *
   * 新配置不再写入；执行期使用激活的 AiSearchProfile。
   */
  searchProvider: string = SEARCH_PROVIDER_DEEPSEEK
  /** Agent 单轮对话内最大工具轮数 */
  maxAgentSteps: number = DEFAULT_AI_MAX_AGENT_STEPS
  /** 旧版工具端点（仅用于迁移） */
  toolsEndpoint: string = DEFAULT_AI_TOOLS_ENDPOINT
  /** 旧版工具密钥（仅用于迁移） */
  toolsApiKey: string = ''
}

/** 连接测试结果 */
export class AiTestResult {
  /** 是否成功 */
  success: boolean = false
  /** 模型回复文本（成功时） */
  message: string = ''
  /** 耗时（毫秒） */
  durationMs: number = 0
  /** 错误信息（失败时） */
  errorMessage: string = ''
}

/**
 * 判断端点是否指向 DeepSeek 官方服务。
 *
 * @param endpoint - 端点地址
 * @returns true 表示 DeepSeek 官方
 */
export function isDeepSeekEndpoint(endpoint: string): boolean {
  return endpoint.toLowerCase().indexOf('api.deepseek.com') >= 0
}

/**
 * 将任意字符串值解析为对话协议。
 *
 * @param value - 持久化值（可能为 undefined）
 * @param endpoint - 端点地址，用于推断旧配置
 * @returns 规范化后的协议
 */
function normalizeProtocol(value: string, endpoint: string): AiApiProtocol {
  if (value === AiApiProtocol.RESPONSES) {
    return AiApiProtocol.RESPONSES
  }
  if (value === AiApiProtocol.CHAT_COMPLETIONS) {
    return AiApiProtocol.CHAT_COMPLETIONS
  }
  // 旧配置没有协议字段：DeepSeek 官方端点走 Responses，其余按 Chat Completions 推断
  return isDeepSeekEndpoint(endpoint) ? AiApiProtocol.RESPONSES : AiApiProtocol.CHAT_COMPLETIONS
}

/**
 * 将持久化的原始配置归一化为当前版本的完整配置。
 *
 * 持久化 JSON 里缺失的字段全部补默认值，避免旧版本配置在新版本里
 * 出现 undefined 导致 UI 或请求构造异常。
 *
 * @param raw - 从持久化读出的原始配置
 * @returns 归一化后的配置
 */
export function normalizeAiProfile(raw: AiProviderProfile): AiProviderProfile {
  if (raw === null || raw === undefined) {
    return new AiProviderProfile()
  }
  const profile: AiProviderProfile = new AiProviderProfile()
  profile.id = readStringField(raw.id)
  profile.name = readStringField(raw.name)

  let endpoint: string = readStringField(raw.endpoint).trim()
  const presetIdRaw: string = readStringField(raw.presetId)
  let presetId: string = ''
  if (presetIdRaw === AiProviderKind.DEEPSEEK || presetIdRaw === AiProviderKind.CUSTOM) {
    presetId = presetIdRaw
  } else {
    presetId = isDeepSeekEndpoint(endpoint) ? AiProviderKind.DEEPSEEK : AiProviderKind.CUSTOM
  }
  // 只有 DeepSeek 预设才回填官方端点：自定义方案端点留空交给表单校验，
  // 避免把用户的自定义密钥静默发往官方端点。
  if (endpoint.length === 0 && presetId === AiProviderKind.DEEPSEEK) {
    endpoint = DEFAULT_DEEPSEEK_ENDPOINT
  }
  profile.endpoint = endpoint
  profile.presetId = presetId

  profile.apiKey = readStringField(raw.apiKey)
  profile.modelName = readStringField(raw.modelName)
  profile.protocol = normalizeProtocol(readStringField(raw.protocol), endpoint)

  const temperature: number = typeof raw.temperature === 'number' ? raw.temperature : DEFAULT_AI_TEMPERATURE
  profile.temperature = clampAiTemperature(temperature)

  profile.toolsEnabled = raw.toolsEnabled !== false
  profile.enableWebSearch = raw.enableWebSearch !== false
  profile.enableWebFetch = raw.enableWebFetch !== false

  const searchProvider: string = readStringField(raw.searchProvider).trim()
  profile.searchProvider = searchProvider.length > 0 ? searchProvider : SEARCH_PROVIDER_DEEPSEEK

  const steps: number = typeof raw.maxAgentSteps === 'number' ? raw.maxAgentSteps : DEFAULT_AI_MAX_AGENT_STEPS
  profile.maxAgentSteps = clampAgentSteps(steps)

  const toolsEndpoint: string = readStringField(raw.toolsEndpoint).trim()
  profile.toolsEndpoint = toolsEndpoint.length > 0 ? toolsEndpoint : DEFAULT_AI_TOOLS_ENDPOINT
  profile.toolsApiKey = readStringField(raw.toolsApiKey)
  return profile
}

/**
 * 防御性读取字符串字段。
 *
 * 旧版本持久化 JSON 可能缺少新字段（运行时为 undefined），
 * 这里统一归一为空字符串，避免把 undefined 带到 UI 与请求构造。
 *
 * @param value - 原始字段值
 * @returns 字符串值，缺失时为空字符串
 */
function readStringField(value: string): string {
  return typeof value === 'string' ? value : ''
}

/**
 * 将温度参数限制到可编辑范围。
 *
 * @param value - 原始温度值
 * @returns 规范化后的温度值
 */
export function clampAiTemperature(value: number): number {
  if (isNaN(value)) {
    return DEFAULT_AI_TEMPERATURE
  }
  const clamped: number = Math.max(MIN_AI_TEMPERATURE, Math.min(MAX_AI_TEMPERATURE, value))
  return Math.round(clamped * 10) / 10
}

/**
 * 将 Agent 工具轮数限制到合法范围。
 *
 * @param value - 原始轮数
 * @returns 规范化后的轮数
 */
export function clampAgentSteps(value: number): number {
  if (isNaN(value)) {
    return DEFAULT_AI_MAX_AGENT_STEPS
  }
  return Math.max(MIN_AI_MAX_AGENT_STEPS, Math.min(MAX_AI_MAX_AGENT_STEPS, Math.round(value)))
}

/**
 * 判断配置是否打开了工具开关（不判断服务商密钥是否就绪）。
 *
 * 密钥就绪判断交给搜索服务商适配器：不同服务商需要的凭据不同。
 *
 * @param profile - AI 配置
 * @returns true 表示至少启用了一个工具
 */
export function hasToolSwitchesOn(profile: AiProviderProfile): boolean {
  if (!profile.toolsEnabled) {
    return false
  }
  return profile.enableWebSearch || profile.enableWebFetch
}
