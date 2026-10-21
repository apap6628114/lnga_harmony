/**
 * AI 端点与响应解析纯逻辑。
 *
 * 所有函数只做字符串/JSON 处理，不发起网络请求，可独立单元测试。
 * 自定义服务商的端点形态差异很大，这里统一收口：
 * - 允许用户填 `https://host`、`https://host/v1`，或直接填完整
 *   `.../chat/completions` / `.../responses`；
 * - 模型列表与工具端点各自从基础地址派生。
 */

import { AiApiProtocol } from '../../model/AiConfig'
import { AiModelInfo } from '../../model/AiModelInfo'

/** Chat Completions 路径后缀。 */
const CHAT_SUFFIX: string = '/chat/completions'
/** Responses 路径后缀。 */
const RESPONSES_SUFFIX: string = '/responses'

/**
 * 去掉末尾斜杠。
 *
 * @param url - 原始地址
 * @returns 规范化地址
 */
function trimTrailingSlash(url: string): string {
  let result: string = url.trim()
  while (result.endsWith('/')) {
    result = result.substring(0, result.length - 1)
  }
  return result
}

/**
 * 去掉端点里已含的协议路径后缀，得到基础地址。
 *
 * @param endpoint - 用户填写的端点
 * @returns 基础地址（无 /chat/completions 或 /responses）
 */
export function stripProtocolSuffix(endpoint: string): string {
  let base: string = trimTrailingSlash(endpoint)
  if (base.endsWith(CHAT_SUFFIX)) {
    base = base.substring(0, base.length - CHAT_SUFFIX.length)
  } else if (base.endsWith(RESPONSES_SUFFIX)) {
    base = base.substring(0, base.length - RESPONSES_SUFFIX.length)
  }
  return trimTrailingSlash(base)
}

/**
 * 构造对话请求 URL。
 *
 * 用户已填完整协议路径时原样使用；否则按协议追加标准路径。
 *
 * @param endpoint - 用户填写的端点
 * @param protocol - 对话协议
 * @returns 完整请求 URL
 */
export function buildChatUrl(endpoint: string, protocol: AiApiProtocol): string {
  const url: string = trimTrailingSlash(endpoint)
  if (url.endsWith(CHAT_SUFFIX) || url.endsWith(RESPONSES_SUFFIX)) {
    return url
  }
  return url + (protocol === AiApiProtocol.RESPONSES ? RESPONSES_SUFFIX : CHAT_SUFFIX)
}

/**
 * 构造模型列表 URL。
 *
 * @param endpoint - 用户填写的端点
 * @returns 完整 `/models` URL
 */
export function buildModelsUrl(endpoint: string): string {
  return stripProtocolSuffix(endpoint) + '/models'
}

/**
 * 构造搜索服务工具请求 URL。
 *
 * 用户可能填基础地址（https://api.deepseek.com）、带版本（.../v1），
 * 也可能填完整工具路径（.../v1/tools/search）。完整路径必须按 toolPath
 * 重建，否则 search 与 fetch 会落到同一个 URL。
 *
 * @param toolsEndpoint - 工具服务端点
 * @param toolPath - `search` 或 `fetch`
 * @returns 完整工具 URL
 */
export function buildToolsUrl(toolsEndpoint: string, toolPath: string): string {
  let base: string = trimTrailingSlash(toolsEndpoint)
  const searchSuffix: string = '/tools/search'
  const fetchSuffix: string = '/tools/fetch'
  if (base.endsWith(searchSuffix)) {
    base = base.substring(0, base.length - searchSuffix.length)
  } else if (base.endsWith(fetchSuffix)) {
    base = base.substring(0, base.length - fetchSuffix.length)
  }
  if (base.endsWith('/v1')) {
    return base + '/tools/' + toolPath
  }
  return base + '/v1/tools/' + toolPath
}

/**
 * 从 `/models` 响应 JSON 中解析模型列表。
 *
 * 兼容两种常见形态：
 * - OpenAI：`{ object: 'list', data: [{ id, ... }] }`
 * - 部分服务商直接返回数组 `[{ id, ... }]`
 *
 * @param responseText - 响应 JSON 文本
 * @returns 模型列表（按 id 去重，保持服务端顺序）
 */
export function parseModelList(responseText: string): AiModelInfo[] {
  const result: AiModelInfo[] = []
  if (responseText.trim().length === 0) {
    return result
  }

  let data: Object[] = []
  try {
    const parsed: Object = JSON.parse(responseText) as Object
    if (Array.isArray(parsed)) {
      data = parsed as Object[]
    } else {
      const record: Record<string, Object> = parsed as Record<string, Object>
      const rawData: Object | undefined = record['data']
      if (rawData !== undefined && rawData !== null && Array.isArray(rawData)) {
        data = rawData as Object[]
      }
    }
  } catch (e) {
    return result
  }

  const seen: Record<string, boolean> = {}
  for (let i: number = 0; i < data.length; i++) {
    const item: Record<string, Object> = data[i] as Record<string, Object>
    const idRaw: Object | undefined = item['id']
    const id: string = typeof idRaw === 'string' ? idRaw as string : ''
    if (id.length === 0 || seen[id] === true) {
      continue
    }
    seen[id] = true
    result.push(buildModelInfo(item, id))
  }
  return result
}

/**
 * 从单条模型 JSON 构建模型元数据。
 *
 * @param item - 模型 JSON 对象
 * @param id - 模型标识
 * @returns 模型元数据
 */
function buildModelInfo(item: Record<string, Object>, id: string): AiModelInfo {
  const info: AiModelInfo = new AiModelInfo()
  info.id = id

  const nameRaw: Object | undefined = item['name']
  const name: string = typeof nameRaw === 'string' ? nameRaw as string : ''
  info.displayName = name.length > 0 ? name : id

  const contextRaw: Object | undefined = item['context_window']
  info.contextWindow = typeof contextRaw === 'number' ? contextRaw as number : 0

  const outputRaw: Object | undefined = item['max_output_tokens']
  info.maxOutputTokens = typeof outputRaw === 'number' ? outputRaw as number : 0

  const modalitiesRaw: Object | undefined = item['input_modalities']
  if (modalitiesRaw !== undefined && modalitiesRaw !== null && Array.isArray(modalitiesRaw)) {
    const modalities: Object[] = modalitiesRaw as Object[]
    for (let i: number = 0; i < modalities.length; i++) {
      if (modalities[i] === 'image') {
        info.supportsImage = true
        break
      }
    }
  }
  return info
}

/**
 * 从错误响应体中提取服务端错误描述。
 *
 * 同时兼容 OpenAI 的 `{ error: { message } }` 与纯文本错误体。
 *
 * @param responseText - 响应文本
 * @returns 错误描述，无法提取时返回空字符串
 */
export function extractServerError(responseText: string): string {
  if (responseText.trim().length === 0) {
    return ''
  }
  try {
    const json: Record<string, Object> = JSON.parse(responseText) as Record<string, Object>
    const errObj: Object | undefined = json['error']
    if (errObj) {
      const errRecord: Record<string, Object> = errObj as Record<string, Object>
      const messageRaw: Object | undefined = errRecord['message']
      if (typeof messageRaw === 'string') {
        return messageRaw as string
      }
    }
    const messageRaw: Object | undefined = json['message']
    if (typeof messageRaw === 'string') {
      return messageRaw as string
    }
  } catch (e) {
    // 非 JSON 错误体：截断后原样返回，便于用户定位
    const compact: string = responseText.replace(/\s+/g, ' ').trim()
    return compact.length > 200 ? compact.substring(0, 200) : compact
  }
  return ''
}
