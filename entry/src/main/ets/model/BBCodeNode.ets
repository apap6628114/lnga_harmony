/**
 * BBCode 语义节点类型。
 */
export enum BBNodeType {
  /** 普通文字。 */ TEXT,
  /** 粗体。 */ BOLD,
  /** 斜体。 */ ITALIC,
  /** 下划线。 */ UNDERLINE,
  /** 删除线。 */ STRIKETHROUGH,
  /** 文字颜色。 */ COLOR,
  /** 相对字号。 */ SIZE,
  /** 字体族。 */ FONT,
  /** 外部或普通链接。 */ URL,
  /** 图片。 */ IMAGE,
  /** 引用块。 */ QUOTE,
  /** 折叠块。 */ COLLAPSE,
  /** 代码块。 */ CODE,
  /** 列表。 */ LIST,
  /** 列表项。 */ LIST_ITEM,
  /** 楼层链接。 */ PID_LINK,
  /** 用户链接。 */ UID_LINK,
  /** 主题链接。 */ TID_LINK,
  /** 用户提及。 */ MENTION,
  /** 回复来源头。 */ POST_BY,
  /** 表情。 */ EMOTION,
  /** 视频。 */ VIDEO,
  /** 音频。 */ AUDIO,
  /** 骰子。 */ DICE,
  /** 警告块。 */ WARN,
  /** 相册。 */ ALBUM,
  /** 左浮动块。 */ FLOAT_LEFT,
  /** 右浮动块。 */ FLOAT_RIGHT,
  /** 对齐块。 */ ALIGN,
  /** 表格。 */ TABLE,
  /** 表格行。 */ TABLE_ROW,
  /** 表格单元格。 */ TABLE_CELL,
  /** 白名单样式块。 */ STYLE_DIV,
  /** Flash 媒体。 */ FLASH,
  /** 水平分隔线。 */ HR,
  /** 段落。 */ PARAGRAPH,
  /** 下标。 */ SUBSCRIPT,
  /** 上标。 */ SUPERSCRIPT,
}

/**
 * BBCode 解析阶段使用的通用语义节点。
 */
export class BBNode {
  /** 节点类型。 */
  type: BBNodeType = BBNodeType.TEXT
  /** 文字或原始样式声明。 */
  text: string = ''
  /** 当前解析进程内的节点标识。 */
  id: number = 0
  /** 子节点。 */
  children: BBNode[] = []
  /** 链接地址。 */
  href: string = ''
  /** 文字颜色。 */
  color: string = ''
  /** 相对字号百分比。 */
  size: number = 0
  /** 媒体地址。 */
  src: string = ''
  /** 块标题。 */
  title: string = ''
  /** 表情分类。 */
  emotionCat: string = ''
  /** 表情代码。 */
  emotionCode: string = ''
  /** 字体族。 */
  fontFamily: string = ''
  /** 对齐方式。 */
  align: string = ''
  /** 表格跨列数。 */
  colSpan: number = 0
  /** 表格跨行数。 */
  rowSpan: number = 0
  /** 表格建议列宽。 */
  colWidth: number = 0
  /** 跨越当前块节点且应由其后代继承的内联格式开始标签。 */
  inheritedFormatTags: string[] = []
}
