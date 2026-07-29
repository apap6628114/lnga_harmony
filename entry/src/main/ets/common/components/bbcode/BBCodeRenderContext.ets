import { BBNode, BBNodeType } from '../../../model/BBCodeNode'
import { AppColors } from '../../constants/Constants'

/** 引用块嵌套层级对应的左边框颜色序列（按引用深度循环取色）。 */
export const QUOTE_BORDER_COLORS: Resource[] = AppColors.quoteBorders

/**
 * BBCode 渲染上下文，沿节点树向下传递。
 *
 * 用于在递归渲染时记录当前是否处于引用块内以及引用嵌套深度，
 * 以便调整字号、字色、行高等样式。
 */
export class RenderContext {
  /** 是否处于引用块（QUOTE）内 */
  inQuote: boolean = false
  /** 引用嵌套深度，根节点为 0 */
  quoteDepth: number = 0
}

/**
 * 引用块子节点拆分结果。
 *
 * 引用块（QUOTE）的第一个子节点可能是 POST_BY（引用来源头），
 * 需将其与正文（body）分离后分别渲染。
 */
export class QuoteSplit {
  /** 是否含有 POST_BY 引用头 */
  hasHeader: boolean = false
  /** 引用来源作者 UID；无法识别来源时为空字符串。 */
  sourceAuthorId: string = ''
  /** 引用正文节点（去除头之后的剩余子节点） */
  body: BBNode[] = []
}

/**
 * 从引用来源头中提取作者 UID。
 *
 * @param node - POST_BY 引用来源头
 * @returns 引用作者 UID；无法识别时为空字符串
 */
function extractQuoteAuthorId(node: BBNode): string {
  if (node.type === BBNodeType.UID_LINK) {
    const prefix: string = '#/profile?uid='
    if (node.href.startsWith(prefix)) {
      return node.href.substring(prefix.length)
    }
  }
  for (let i = 0; i < node.children.length; i++) {
    const authorId: string = extractQuoteAuthorId(node.children[i])
    if (authorId.length > 0) {
      return authorId
    }
  }
  return ''
}

/**
 * 拆分引用块的子节点，区分引用头（POST_BY）与正文。
 *
 * 当 children 的第一个节点类型为 POST_BY 时，标记 hasHeader=true，
 * 并将剩余节点作为 body；否则 body 即全部 children。
 *
 * @param children - 引用块的原始子节点数组
 * @returns 拆分结果
 */
export function splitQuoteChildren(children: BBNode[]): QuoteSplit {
  const result = new QuoteSplit()
  if (children.length > 0 && children[0].type === BBNodeType.POST_BY) {
    result.hasHeader = true
    result.sourceAuthorId = extractQuoteAuthorId(children[0])
    const b: BBNode[] = []
    for (let i = 1; i < children.length; i++) b.push(children[i])
    result.body = b
  } else {
    result.body = children
  }
  return result
}

/**
 * 判断引用正文是否来自黑名单用户。
 *
 * 只有携带标准 POST_BY 来源头并能提取 UID 的引用才会参与判断；
 * 无来源的普通引用不会被猜测性遮蔽。
 *
 * @param children - 引用块的原始子节点数组
 * @param blacklistIds - 当前黑名单 UID 集合
 * @returns 是否应遮蔽引用正文
 */
export function isQuoteFromBlacklistedUser(children: BBNode[], blacklistIds: Set<string>): boolean {
  const split: QuoteSplit = splitQuoteChildren(children)
  return split.sourceAuthorId.length > 0 && blacklistIds.has(split.sourceAuthorId)
}

/**
 * 节点分组单元。
 *
 * BBCodeContentView 将顶层节点按内联/块级聚合成若干分组（Group），
 * 每个分组内的内联节点会渲染进同一个 Text 容器。
 */
export class NodeGroup {
  /** 分组类型：'inline'（内联组）或 'block'（块级单节点） */
  kind: string = 'inline'
  /** 该分组包含的节点 */
  nodes: BBNode[] = []
}
