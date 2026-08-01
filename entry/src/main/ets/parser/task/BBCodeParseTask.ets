import { BBNode } from '../../model/BBCodeNode'
import { parseBBCode } from '../bbcode/parser'

/**
 * 可跨 taskpool 线程序列化的 BBCode 节点结构。
 */
interface BBNodeJSON {
  /** 节点类型枚举值。 */
  type: number
  /** 文字或原始样式声明。 */
  text: string
  /** 节点标识。 */
  id: number
  /** 子节点。 */
  children: BBNodeJSON[]
  /** 链接地址。 */
  href: string
  /** 文字颜色。 */
  color: string
  /** 相对字号百分比。 */
  size: number
  /** 媒体地址。 */
  src: string
  /** 块标题。 */
  title: string
  /** 表情分类。 */
  emotionCat: string
  /** 表情代码。 */
  emotionCode: string
  /** 字体族。 */
  fontFamily: string
  /** 对齐方式。 */
  align: string
  /** 表格跨列数。 */
  colSpan: number
  /** 表格跨行数。 */
  rowSpan: number
  /** 表格建议列宽。 */
  colWidth: number
  /** 跨块延续的内联格式标签。 */
  inheritedFormatTags: string[]
}

/**
 * 在 taskpool 工作线程中解析 BBCode 并返回可传输 JSON。
 *
 * @param content 原始帖子正文
 * @returns 序列化节点数组；解析失败时返回空数组
 */
@Concurrent
function parseBBCodeTask(content: string): string {
  try {
    const nodes: BBNode[] = parseBBCode(content)
    return JSON.stringify(nodes)
  } catch (e) {
    return '[]'
  }
}

export { parseBBCodeTask, BBNodeJSON }
