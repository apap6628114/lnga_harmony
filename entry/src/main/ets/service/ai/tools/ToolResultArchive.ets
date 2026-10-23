/**
 * 工具结果归档（大结果的"外置存储"）。
 *
 * ## 为什么需要它
 *
 * 上下文预算不够时，旧实现把工具结果**截断**后回传给模型，并告诉模型
 * 「用相同参数再调用一次，客户端有缓存」。这句话在预算耗尽时是**错的**：
 * 同参数重调会命中缓存、拿回同样的完整结果，然后再次被同一个预算截断——
 * 模型永远看不到后半段。信息不是被压缩了，是被永久丢弃了。
 *
 * 成熟 Agent（Claude Code 的大输出落文件 + 分段读取、OpenHands 的 observation
 * 外置）采用的做法是：**完整结果留在客户端，上下文里只放"头部 + 引用"，
 * 模型需要时用工具按偏移续读**。这样上下文占用可控，而信息量不损失。
 *
 * ## 边界
 *
 * - 归档只活在**一次 Agent 运行**内：历史不持久化 tool 消息，模型不会在下一轮
 *   引用上一轮的 result_id；跨轮需要原文时重新调用原工具（`ToolResultCache` 命中）。
 * - 容量按「条数 + 总字符」双重限制，超出按 LRU 淘汰。被淘汰的 id 再读取会
 *   得到明确失败，而不是空内容。
 */

/** 归档条目。 */
export class ArchivedToolResult {
  /** 结果 ID（模型用它调用 expand_tool_result） */
  id: string = ''
  /** 产生该结果的工具名 */
  toolName: string = ''
  /** 完整正文 */
  content: string = ''
  /** 归档时间 */
  createdAt: number = 0
}

/**
 * 一次续读切片。
 */
export class ToolArchiveSlice {
  /** 结果 ID */
  id: string = ''
  /** 切片正文 */
  text: string = ''
  /** 本次切片起始偏移（字符） */
  offset: number = 0
  /** 完整结果总字符数 */
  totalChars: number = 0
  /** 是否还有后续内容 */
  hasMore: boolean = false
  /** 下一段的起始偏移（hasMore 为 false 时等于 totalChars） */
  nextOffset: number = 0
}

/** 默认最多保留的归档条数。 */
export const ARCHIVE_MAX_ENTRIES: number = 32

/** 默认归档总字符上限（约 2MB 文本，够装几十页帖子正文）。 */
export const ARCHIVE_MAX_TOTAL_CHARS: number = 2000000

/** 续读的默认字符数（约 2–4K token，够读几楼）。 */
export const ARCHIVE_DEFAULT_READ_CHARS: number = 4000

/** 续读单次允许的最大字符数。 */
export const ARCHIVE_MAX_READ_CHARS: number = 16000

/**
 * 工具结果归档（LRU）。
 */
export class ToolResultArchive {
  /** ID -> 条目 */
  private map: Map<string, ArchivedToolResult> = new Map()
  /** LRU 顺序（队尾最新） */
  private order: string[] = []
  /** 条数上限 */
  private maxEntries: number
  /** 总字符上限 */
  private maxTotalChars: number
  /** 当前总字符数 */
  private totalChars: number = 0
  /** 自增序号（拼 ID 用） */
  private seq: number = 0

  /**
   * 构造归档。
   *
   * @param maxEntries - 条数上限
   * @param maxTotalChars - 总字符上限
   */
  constructor(maxEntries: number = ARCHIVE_MAX_ENTRIES,
    maxTotalChars: number = ARCHIVE_MAX_TOTAL_CHARS) {
    this.maxEntries = maxEntries > 0 ? maxEntries : ARCHIVE_MAX_ENTRIES
    this.maxTotalChars = maxTotalChars > 0 ? maxTotalChars : ARCHIVE_MAX_TOTAL_CHARS
  }

  /**
   * 归档一条完整结果。
   *
   * 空内容不归档（返回空串）：没有可续读的东西，给模型一个假 ID 只会增加无效调用。
   *
   * @param toolName - 工具名
   * @param content - 完整正文
   * @returns 结果 ID；内容为空时返回空串
   */
  put(toolName: string, content: string): string {
    if (content.length === 0) {
      return ''
    }
    this.seq++
    const entry: ArchivedToolResult = new ArchivedToolResult()
    entry.id = 'res_' + this.seq.toString() + '_' + Date.now().toString(36)
    entry.toolName = toolName
    entry.content = content
    entry.createdAt = Date.now()
    this.map.set(entry.id, entry)
    this.order.push(entry.id)
    this.totalChars += content.length
    this.evictIfNeeded()
    return entry.id
  }

  /**
   * 按 ID 取完整条目（命中会刷新 LRU）。
   *
   * @param id - 结果 ID
   * @returns 条目；不存在时返回 null
   */
  get(id: string): ArchivedToolResult | null {
    const entry: ArchivedToolResult | undefined = this.map.get(id)
    if (entry === undefined) {
      return null
    }
    this.touch(id)
    return entry
  }

  /**
   * 读取一个切片。
   *
   * 偏移与长度按 UTF-16 码元计算，但会**避免切断代理对**（emoji 等）：
   * 起始位置若落在低位代理上则前移一位，结束位置若停在代理对中间则回退一位。
   *
   * @param id - 结果 ID
   * @param offset - 起始偏移（<=0 按 0 处理，越界按末尾处理）
   * @param limit - 最大字符数（<=0 使用默认值）
   * @returns 切片；ID 不存在时返回 null
   */
  read(id: string, offset: number, limit: number): ToolArchiveSlice | null {
    const entry: ArchivedToolResult | null = this.get(id)
    if (entry === null) {
      return null
    }
    const total: number = entry.content.length
    let start: number = offset > 0 ? offset : 0
    if (start > total) {
      start = total
    }
    // 不切断代理对：落在低位代理上时从高位代理开始
    if (start > 0 && start < total && isLowSurrogate(entry.content.charCodeAt(start))) {
      start--
    }
    const wanted: number = limit > 0 ? limit : ARCHIVE_DEFAULT_READ_CHARS
    let end: number = start + wanted
    if (end > total) {
      end = total
    }
    if (end > start && end < total && isHighSurrogate(entry.content.charCodeAt(end - 1))) {
      end--
    }
    /*
     * 代理对保护可能把结束位置推回到起点（例如 1 个字符的窗口正好切在 emoji
     * 中间）。这时必须至少前进一个完整码点，否则 nextOffset 会停在原地，
     * 模型按 next_offset 续读会进入死循环。
     */
    if (end <= start && start < total) {
      end = Math.min(total, start + 2)
      if (end < total && isHighSurrogate(entry.content.charCodeAt(end - 1))) {
        end++
      }
    }
    const slice: ToolArchiveSlice = new ToolArchiveSlice()
    slice.id = id
    slice.text = entry.content.substring(start, end)
    slice.offset = start
    slice.totalChars = total
    slice.nextOffset = end
    slice.hasMore = end < total
    return slice
  }

  /**
   * 当前归档条数。
   *
   * @returns 条数
   */
  size(): number {
    return this.map.size
  }

  /**
   * 清空归档（会话切换 / 页面销毁时调用）。
   */
  clear(): void {
    this.map.clear()
    this.order = []
    this.totalChars = 0
  }

  /**
   * 按容量上限淘汰最久未使用的条目。
   */
  private evictIfNeeded(): void {
    while (this.order.length > this.maxEntries || this.totalChars > this.maxTotalChars) {
      /*
       * 至少保留最新一条：如果单条结果本身就超过总容量上限，继续淘汰会把
       * 刚返回给模型的 result_id 立刻删掉，续读必然失败。宁可短暂超限，
       * 也不要给出一个悬空引用。
       */
      if (this.order.length <= 1) {
        break
      }
      const oldest: string | undefined = this.order.shift()
      if (oldest === undefined) {
        break
      }
      const entry: ArchivedToolResult | undefined = this.map.get(oldest)
      if (entry !== undefined) {
        this.totalChars -= entry.content.length
        if (this.totalChars < 0) {
          this.totalChars = 0
        }
      }
      this.map.delete(oldest)
    }
  }

  /**
   * 把 ID 移到 LRU 队尾。
   *
   * @param id - 结果 ID
   */
  private touch(id: string): void {
    const index: number = this.order.indexOf(id)
    if (index >= 0) {
      this.order.splice(index, 1)
      this.order.push(id)
    }
  }
}

/**
 * 判断是否为 UTF-16 低位代理。
 *
 * @param code - 码元
 * @returns true 表示低位代理
 */
function isLowSurrogate(code: number): boolean {
  return code >= 0xDC00 && code <= 0xDFFF
}

/**
 * 判断是否为 UTF-16 高位代理。
 *
 * @param code - 码元
 * @returns true 表示高位代理
 */
function isHighSurrogate(code: number): boolean {
  return code >= 0xD800 && code <= 0xDBFF
}
