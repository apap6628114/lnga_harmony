import { MdNode, MdNodeType } from '../../model/MdNode'
import { AppColors } from '../constants/Constants'
import { MdNodeDataSource } from '../datasource/MdNodeDataSource'

/**
 * Markdown AST 节点渲染组件。
 *
 * 只负责将已解析的 Markdown 节点渲染为 UI，不负责文本解析。
 */
@Component
export struct MdNodesView {
  /** Markdown AST 节点列表。 */
  @Prop @Watch('onNodesChange') nodes: MdNode[] = []
  /** 链接点击回调。 */
  onLinkClick: (href: string) => void = (_href: string) => {}
  /** 是否强制使用 LazyForEach 数据源渲染。 */
  forceLazy: boolean = false
  /** LazyForEach 数据源。外部增量维护时可传入同一个数据源实例。 */
  dataSource: MdNodeDataSource = new MdNodeDataSource()

  /** 渲染用节点缓存。 */
  @State private renderedNodes: MdNode[] = []

  /**
   * 节点列表变化时同步普通渲染缓存与内部数据源。
   */
  private onNodesChange(): void {
    this.renderedNodes = this.nodes
    if (!this.forceLazy) {
      this.dataSource.replaceAll(this.renderedNodes)
    }
  }

  /**
   * 组件出现时初始化渲染缓存。
   */
  aboutToAppear(): void {
    this.renderedNodes = this.nodes
    if (!this.forceLazy) {
      this.dataSource.replaceAll(this.renderedNodes)
    }
  }

  /**
   * 构建 Markdown 节点视图。
   */
  build() {
    Column() {
      if (this.forceLazy || this.renderedNodes.length >= 20) {
        LazyForEach(this.dataSource, (node: MdNode) => {
          this.RenderBlock(node)
        }, (node: MdNode) => this.renderKey(node, 'b'))
      } else {
        ForEach(this.renderedNodes, (node: MdNode) => {
          this.RenderBlock(node)
        }, (node: MdNode) => this.renderKey(node, 'b'))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 分派单个块级节点到对应的渲染方法。
   *
   * @param node - 块级节点
   */
  @Builder
  RenderBlock(node: MdNode) {
    if (node.type === MdNodeType.HEADING) {
      this.RenderHeading(node)
    } else if (node.type === MdNodeType.PARAGRAPH) {
      this.RenderParagraph(node)
    } else if (node.type === MdNodeType.CODE_BLOCK) {
      this.RenderCodeBlock(node)
    } else if (node.type === MdNodeType.UNORDERED_LIST) {
      this.RenderUnorderedList(node)
    } else if (node.type === MdNodeType.ORDERED_LIST) {
      this.RenderOrderedList(node)
    } else if (node.type === MdNodeType.BLOCKQUOTE) {
      this.RenderBlockquote(node)
    } else if (node.type === MdNodeType.THEMATIC_BREAK) {
      this.RenderThematicBreak()
    } else if (node.type === MdNodeType.IMAGE) {
      this.RenderImageBlock(node)
    } else if (node.type === MdNodeType.TABLE) {
      this.RenderTable(node)
    }
  }

  /** 渲染标题。 */
  @Builder
  RenderHeading(node: MdNode) {
    Text() {
      ForEach(node.children, (child: MdNode) => {
        this.RenderSpanLeaf(child)
      }, (child: MdNode) => this.renderKey(child, 'h'))
    }
    .fontSize(this.headingFontSize(node.level))
    .fontColor(AppColors.textPrimary)
    .fontWeight(this.headingFontWeight(node.level))
    .lineHeight(this.headingLineHeight(node.level))
    .width('100%')
    .margin({ top: node.level <= 2 ? 14 : 10, bottom: 4 })
  }

  /** 渲染段落。 */
  @Builder
  RenderParagraph(node: MdNode) {
    Text() {
      ForEach(node.children, (child: MdNode) => {
        this.RenderSpanLeaf(child)
      }, (child: MdNode) => this.renderKey(child, 'p'))
    }
    .fontSize(15)
    .fontColor(AppColors.textPrimary)
    .lineHeight(26)
    .width('100%')
    .margin({ top: 2, bottom: 6 })
  }

  /** 渲染围栏代码块。 */
  @Builder
  RenderCodeBlock(node: MdNode) {
    Column() {
      if (node.language.length > 0) {
        Text(node.language)
          .fontSize(11)
          .fontColor(AppColors.textTertiary)
          .padding({ left: 12, right: 12, top: 6, bottom: 4 })
      }
      Scroll() {
        Text(node.text)
          .fontSize(13)
          .fontColor(AppColors.textPrimary)
          .fontFamily('monospace')
          .lineHeight(20)
          .padding(12)
      }
      .width('100%')
      .scrollable(ScrollDirection.Horizontal)
    }
    .width('100%')
    .backgroundColor(AppColors.bgSecondary)
    .borderRadius(8)
    .margin({ top: 6, bottom: 6 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 渲染无序列表。 */
  @Builder
  RenderUnorderedList(node: MdNode) {
    Column() {
      ForEach(node.children, (item: MdNode) => {
        this.RenderListItem(item, 0)
      }, (item: MdNode) => this.renderKey(item, 'uli'))
    }
    .width('100%')
    .padding({ left: 8 })
    .margin({ top: 4, bottom: 4 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 渲染有序列表。 */
  @Builder
  RenderOrderedList(node: MdNode) {
    Column() {
      ForEach(node.children, (item: MdNode, index: number) => {
        this.RenderListItem(item, index + 1)
      }, (item: MdNode) => this.renderKey(item, 'ol'))
    }
    .width('100%')
    .padding({ left: 8 })
    .margin({ top: 4, bottom: 4 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 渲染单个列表项（支持任务勾选与一层子列表）。
   *
   * @param item - 列表项节点
   * @param order - 有序列表序号（0 表示无序列表）
   */
  @Builder
  RenderListItem(item: MdNode, order: number) {
    Column() {
      Row() {
        Text(this.listMarker(item, order))
          .fontSize(15)
          .fontColor(item.checked === 1 ? AppColors.textTertiary : AppColors.textPrimary)
          .margin({ right: 6 })
          .width(20)
          .textAlign(TextAlign.End)
        Text() {
          ForEach(item.children, (child: MdNode) => {
            if (this.isInlineNode(child)) {
              this.RenderSpanLeaf(child)
            }
          }, (child: MdNode) => this.renderKey(child, 'li'))
        }
        .fontSize(15)
        .fontColor(item.checked === 1 ? AppColors.textTertiary : AppColors.textPrimary)
        .decoration({ type: item.checked === 1 ? TextDecorationType.LineThrough : TextDecorationType.None })
        .lineHeight(26)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 2, bottom: 2 })
      .alignItems(VerticalAlign.Top)

      // 子列表（缩进嵌套）
      ForEach(item.children, (child: MdNode) => {
        if (child.type === MdNodeType.UNORDERED_LIST) {
          this.RenderUnorderedList(child)
        } else if (child.type === MdNodeType.ORDERED_LIST) {
          this.RenderOrderedList(child)
        }
      }, (child: MdNode) => 'sub_' + this.renderKey(child, 's'))
    }
    .width('100%')
    .padding({ left: 10 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 列表项前缀：任务框 / 序号 / 圆点。
   *
   * @param item - 列表项
   * @param order - 有序序号（0 表示无序）
   * @returns 前缀文本
   */
  private listMarker(item: MdNode, order: number): string {
    if (item.checked >= 0) {
      return item.checked === 1 ? '☑' : '☐'
    }
    if (order > 0) {
      return order.toString() + '.'
    }
    return '•'
  }

  /**
   * 判断节点是否为可内联渲染的类型。
   *
   * @param node - Markdown 节点
   * @returns true 表示可内联渲染
   */
  private isInlineNode(node: MdNode): boolean {
    return node.type === MdNodeType.TEXT ||
      node.type === MdNodeType.BOLD ||
      node.type === MdNodeType.ITALIC ||
      node.type === MdNodeType.STRIKETHROUGH ||
      node.type === MdNodeType.CODE_INLINE ||
      node.type === MdNodeType.LINK ||
      node.type === MdNodeType.IMAGE
  }

  /** 渲染引用块。 */
  @Builder
  RenderBlockquote(node: MdNode) {
    Column() {
      Text() {
        ForEach(node.children, (child: MdNode) => {
          this.RenderSpanLeaf(child)
        }, (child: MdNode) => this.renderKey(child, 'bq'))
      }
      .fontSize(14)
      .fontColor(AppColors.textSecondary)
      .fontStyle(FontStyle.Italic)
      .lineHeight(24)
      .width('100%')
    }
    .width('100%')
    .padding({ left: 12, top: 6, bottom: 6 })
    .margin({ top: 6, bottom: 4 })
    .border({
      width: { left: 2 },
      color: { left: AppColors.quoteBorders[0] },
      style: { left: BorderStyle.Solid }
    })
    .borderRadius({ topLeft: 4, bottomLeft: 4 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 渲染分隔线。 */
  @Builder
  RenderThematicBreak() {
    Divider()
      .color(AppColors.separator)
      .margin({ top: 10, bottom: 10 })
      .width('100%')
  }

  /** 渲染块级图片。 */
  @Builder
  RenderImageBlock(node: MdNode) {
    Column() {
      Image(node.href)
        .width('100%')
        .constraintSize({ maxHeight: 320 })
        .objectFit(ImageFit.Contain)
        .borderRadius(8)
        .backgroundColor(AppColors.bgSecondary)

      if (node.text.length > 0) {
        Text(node.text)
          .fontSize(11)
          .fontColor(AppColors.textTertiary)
          .margin({ top: 4 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .margin({ top: 6, bottom: 6 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 渲染 GFM 表格。 */
  @Builder
  RenderTable(node: MdNode) {
    Column() {
      ForEach(node.children, (row: MdNode) => {
        Row() {
          ForEach(row.children, (cell: MdNode) => {
            Text() {
              ForEach(cell.children, (child: MdNode) => {
                this.RenderSpanLeaf(child)
              }, (child: MdNode) => this.renderKey(child, 'tc'))
            }
            .fontSize(13)
            .fontWeight(row.level === 1 ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(AppColors.textPrimary)
            .lineHeight(20)
            .layoutWeight(1)
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .textAlign(cell.align === 'center' ? TextAlign.Center :
              (cell.align === 'right' ? TextAlign.End : TextAlign.Start))
          }, (cell: MdNode) => this.renderKey(cell, 'tcell'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .backgroundColor(row.level === 1 ? AppColors.bgTertiary : Color.Transparent)
        .border({
          width: { bottom: 0.5 },
          color: { bottom: AppColors.separator },
          style: { bottom: BorderStyle.Solid }
        })
      }, (row: MdNode) => this.renderKey(row, 'trow'))
    }
    .width('100%')
    .margin({ top: 6, bottom: 6 })
    .borderRadius(8)
    .clip(true)
  }

  /**
   * 返回 ArkUI ForEach 使用的渲染 key。
   *
   * @param node - Markdown AST 节点
   * @param fallbackPrefix - 无稳定 key 时使用的前缀
   * @returns 渲染 key
   */
  private renderKey(node: MdNode, fallbackPrefix: string): string {
    if (node.key.length > 0) {
      return node.key
    }
    return fallbackPrefix + '_' + node.id.toString()
  }

  /**
   * 渲染段落中的内联叶子节点为 Span。
   *
   * @param node - 内联叶子节点
   */
  @Builder
  RenderSpanLeaf(node: MdNode) {
    if (node.type === MdNodeType.CODE_INLINE) {
      Span(node.text)
        .fontFamily('monospace')
        .fontSize(13)
        .fontColor(AppColors.warnText)
        .textBackgroundStyle({ color: AppColors.bgSecondary })
    } else if (node.type === MdNodeType.LINK) {
      Span(node.text)
        .fontColor(AppColors.primary)
        .decoration({ type: TextDecorationType.Underline, color: AppColors.primary })
        .onClick(() => {
          if (node.href.length > 0) {
            this.onLinkClick(node.href)
          }
        })
    } else if (node.type === MdNodeType.IMAGE) {
      // 内联图片无法放进 Text，降级为可点击的「图片」标记
      Span(node.text.length > 0 ? '[图片] ' + node.text : '[图片]')
        .fontColor(AppColors.primary)
        .onClick(() => {
          if (node.href.length > 0) {
            this.onLinkClick(node.href)
          }
        })
    } else if (node.type === MdNodeType.BOLD) {
      Span(this.inlineText(node)).fontWeight(FontWeight.Bold).fontColor(AppColors.textPrimary)
    } else if (node.type === MdNodeType.ITALIC) {
      Span(this.inlineText(node)).fontStyle(FontStyle.Italic).fontColor(AppColors.textPrimary)
    } else if (node.type === MdNodeType.STRIKETHROUGH) {
      Span(this.inlineText(node)).decoration({ type: TextDecorationType.LineThrough }).fontColor(AppColors.textPrimary)
    } else {
      Span(node.text).fontColor(AppColors.textPrimary)
    }
  }

  /**
   * 提取内联节点的纯文本（含嵌套子节点）。
   *
   * 粗体/斜体内部若含裸链接，解析器会拆成多个子节点、text 为空，
   * 此时按子节点递归拼接，保证内容不丢失（链接样式在内联格式内降级）。
   *
   * @param node - 内联节点
   * @returns 纯文本
   */
  private inlineText(node: MdNode): string {
    if (node.text.length > 0) {
      return node.text
    }
    let text: string = ''
    for (let i: number = 0; i < node.children.length; i++) {
      text += this.inlineText(node.children[i])
    }
    return text
  }

  /**
   * 根据标题级别返回对应字号。
   *
   * @param level - 标题级别
   * @returns 字号值
   */
  private headingFontSize(level: number): number {
    if (level === 1) {
      return 22
    }
    if (level === 2) {
      return 19
    }
    if (level === 3) {
      return 17
    }
    if (level === 4) {
      return 15
    }
    if (level === 5) {
      return 14
    }
    return 13
  }

  /**
   * 根据标题级别返回对应字重。
   *
   * @param level - 标题级别
   * @returns 字重
   */
  private headingFontWeight(level: number): FontWeight {
    if (level <= 2) {
      return FontWeight.Bold
    }
    return FontWeight.Medium
  }

  /**
   * 根据标题级别返回对应行高。
   *
   * @param level - 标题级别
   * @returns 行高
   */
  private headingLineHeight(level: number): number {
    if (level === 1) {
      return 30
    }
    if (level === 2) {
      return 27
    }
    if (level === 3) {
      return 24
    }
    return 22
  }
}
