import { taskpool } from '@kit.ArkTS'
import { withTimeout } from '../../common/utils/TimeoutUtils'
import { BBNode, BBNodeType } from '../../model/BBCodeNode'
import { parseBBCode } from './parser'
import { parseBBCodeTask, BBNodeJSON } from '../task/BBCodeParseTask'
import { LruCache } from '../../common/cache/LruCache'
import { Logger, DOMAIN_PARSER } from '../../common/utils/Logger'

const logger = new Logger(DOMAIN_PARSER, 'BBCodeCache')
const MAX_CACHE_SIZE: number = 150
/** 复杂正文后台解析允许的最长等待时间。 */
const PARSE_TIMEOUT_MS: number = 30000
const cache: LruCache<BBNode[]> = new LruCache<BBNode[]>(MAX_CACHE_SIZE)
const pendingSet: Set<string> = new Set()

/**
 * 将 taskpool 返回的 JSON 恢复为 BBNode 数组。
 *
 * @param json 序列化节点数组
 * @returns 恢复后的节点数组
 */
function bbNodesFromJSON(json: string): BBNode[] {
  const raw: BBNodeJSON[] = JSON.parse(json) as BBNodeJSON[]
  const result: BBNode[] = []
  for (let i: number = 0; i < raw.length; i++) {
    result.push(jsonToBBNode(raw[i]))
  }
  return result
}

/**
 * 递归恢复一个可序列化节点。
 *
 * @param d 可序列化节点
 * @returns BBNode 实例
 */
function jsonToBBNode(d: BBNodeJSON): BBNode {
  const n: BBNode = new BBNode()
  n.type = d.type as BBNodeType
  n.text = d.text
  n.id = d.id
  n.href = d.href
  n.color = d.color
  n.size = d.size
  n.src = d.src
  n.title = d.title
  n.emotionCat = d.emotionCat
  n.emotionCode = d.emotionCode
  n.fontFamily = d.fontFamily
  n.align = d.align
  n.colSpan = d.colSpan
  n.rowSpan = d.rowSpan
  n.colWidth = d.colWidth
  n.inheritedFormatTags = d.inheritedFormatTags ?? []
  const childCount: number = d.children.length
  for (let i: number = 0; i < childCount; i++) {
    n.children.push(jsonToBBNode(d.children[i]))
  }
  return n
}

/**
 * 同步读取缓存，未命中时在当前线程解析。
 *
 * @param content 原始帖子正文
 * @returns 解析节点数组
 */
export function getCachedBBNodes(content: string): BBNode[] {
  const cached: BBNode[] | undefined = cache.get(content)
  if (cached) return cached

  const nodes: BBNode[] = parseBBCode(content)
  cache.set(content, nodes)
  return nodes
}

/** 清空 BBCode 内存缓存。 */
export function clearBBCodeCache(): void {
  cache.clear()
}

/**
 * 以默认优先级预热一条 BBCode 正文。
 *
 * @param content 原始帖子正文
 */
export function preWarmBBCache(content: string): void {
  preWarmBatch([content], taskpool.Priority.MEDIUM)
}

/**
 * 异步预热一批 BBCode 正文，不等待完成。
 *
 * @param contents 原始帖子正文数组
 * @param priority 可选 taskpool 优先级
 */
export function preWarmBatch(contents: string[], priority?: taskpool.Priority): void {
  preWarmBatchAwait(contents, priority).catch((err: Error) => {
    logger.error('preWarmBatch failed: %{public}s', err.message)
  })
}

/**
 * 异步预热一批 BBCode 正文并等待完成。
 *
 * @param contents 原始帖子正文数组
 * @param priority 可选 taskpool 优先级
 */
export async function preWarmBatchAwait(contents: string[], priority?: taskpool.Priority): Promise<void> {
  const toParse: string[] = []
  for (let i: number = 0; i < contents.length; i++) {
    const c: string = contents[i]
    if (!c || cache.has(c) || pendingSet.has(c)) continue
    toParse.push(c)
    pendingSet.add(c)
  }
  if (toParse.length === 0) return

  const p: taskpool.Priority = priority !== undefined ? priority : taskpool.Priority.MEDIUM
  const group: taskpool.TaskGroup = new taskpool.TaskGroup()
  for (let i: number = 0; i < toParse.length; i++) {
    try {
      group.addTask(new taskpool.Task(parseBBCodeTask, toParse[i]))
    } catch (e) {
      logger.error('addTask failed: %{public}s', (e as Error).message)
    }
  }
  let results: Object[];
  try {
    results = await withTimeout<Object[]>(
      taskpool.execute(group, p) as Promise<Object[]>,
      PARSE_TIMEOUT_MS
    ) as Object[]
  } catch (e) {
    logger.error('taskpool execute failed: %{public}s', (e as Error).message)
    for (let i: number = 0; i < toParse.length; i++) {
      pendingSet.delete(toParse[i])
    }
    return
  }
  for (let i: number = 0; i < results.length; i++) {
    cache.set(toParse[i], bbNodesFromJSON(results[i] as string))
    pendingSet.delete(toParse[i])
  }
}
