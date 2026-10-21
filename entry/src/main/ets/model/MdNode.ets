/**
 * Markdown 抽象语法树节点类型枚举。
 *
 * 每个枚举成员对应一种 Markdown 结构元素，
 * 按块级/内联分为两大类。
 */
export enum MdNodeType {
  /** 标题 (H1-H6, `# ~ ######`) */
  HEADING,
  /** 段落 */
  PARAGRAPH,
  /** 纯文本（叶子节点） */
  TEXT,
  /** 粗体 `**text**` */
  BOLD,
  /** 斜体 `*text*` */
  ITALIC,
  /** 删除线 `~~text~~` */
  STRIKETHROUGH,
  /** 行内代码 `` `code` `` */
  CODE_INLINE,
  /** 围栏代码块 ` ```lang ... ``` ` */
  CODE_BLOCK,
  /** 无序列表 (`- ` / `* ` / `+ `) */
  UNORDERED_LIST,
  /** 有序列表 (`1. `) */
  ORDERED_LIST,
  /** 列表项 */
  LIST_ITEM,
  /** 引用块 (`> `) */
  BLOCKQUOTE,
  /** 分隔线 (`---` / `***`) */
  THEMATIC_BREAK,
  /** 链接 `[text](url)` */
  LINK,
  /** 图片 `![alt](url)`（块级独占一行，或内联降级为文本） */
  IMAGE,
  /** 表格（GFM `| a | b |` + 分隔行） */
  TABLE,
  /** 表格行（children 为 TABLE_CELL） */
  TABLE_ROW,
  /** 表格单元格（children 为内联节点） */
  TABLE_CELL,
}

/** 全局节点 ID 计数器，确保 ForEach key 唯一 */
let mdNodeIdCounter: number = 0

/**
 * Markdown AST 节点。
 *
 * 采用与 BBNode 一致的"单一类 + 枚举判别"模式，
 * 简化 JSON 序列化（对未来 taskpool 传参友好）。
 */
export class MdNode {
  /** 全局自增唯一 ID，用作 ForEach key */
  id: number = 0
  /** 稳定渲染 key，用于在重复解析相同前缀时复用 ArkUI 节点 */
  key: string = ''
  /** 节点类型 */
  type: MdNodeType = MdNodeType.TEXT
  /** 文本内容 */
  text: string = ''
  /** 子节点（树形结构） */
  children: MdNode[] = []
  /** 标题级别 (1-6)，仅 HEADING 有效；表格行用 1 表示表头 */
  level: number = 1
  /** 链接 / 图片 URL，仅 LINK / IMAGE 有效 */
  href: string = ''
  /** 代码块语言标识，仅 CODE_BLOCK 类型有效 */
  language: string = ''
  /** 任务列表勾选状态：-1 非任务项，0 未完成，1 已完成 */
  checked: number = -1
  /** 表格单元格对齐：left / center / right */
  align: string = 'left'

  /**
   * 创建 MD 节点并分配唯一 ID。
   *
   * @param type - 节点类型
   */
  constructor(type: MdNodeType) {
    mdNodeIdCounter++
    this.id = mdNodeIdCounter
    this.type = type
  }
}
