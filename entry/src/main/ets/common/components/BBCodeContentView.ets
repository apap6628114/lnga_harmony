import { BBNode, BBNodeType } from '../../model/BBCodeNode'
import { AppColors, ImageLoadStrategy } from '../constants/Constants'
import { getEmotionResource, isEmotionCategoryNeedDarkBg } from '../media/EmotionResources'
import { AudioPlayer } from '../media/AudioPlayer'
import { MutedVideo } from '../media/MutedVideo'
import { ImageSize, fetchImageSize, getCachedImageSize } from '../media/ImageSizeUtil'
import { fetchVideoSize, getCachedVideoSize } from '../media/VideoSizeUtil'
import { isWifiConnected, shouldUsePassive } from '../utils/NetworkUtil'
import {
  ReadingFontRole,
  ReadingLineHeightRole,
  ReadingTypography
} from '../typography/ReadingTypography'
import { LengthMetrics } from '@kit.ArkUI'
import {
  isInlineNode,
  isInlineRunsBlank,
  calcScaleSize,
  calcSubscriptSize,
  calcSubscriptOffset,
  calcSuperscriptSize,
  calcSuperscriptOffset,
  applyInlineFormatTags,
  applyTextStyleDeclaration,
  cloneInlineTextStyle,
  extractTextStyleAlign,
  flattenInlineNodes,
  InlineBaseline,
  InlineRun,
  InlineRunKind,
  InlineTextStyle,
} from './bbcode/bbcode-utils'
import {
  RenderContext,
  NodeGroup,
  splitQuoteChildren,
  isQuoteFromBlacklistedUser,
  QUOTE_BORDER_COLORS,
  QuoteSplit,
} from './bbcode/BBCodeRenderContext'
import { appStore } from '../../store/AppStore'

/** 单个 BBCode 视图允许缓存的最大内联节点组数量。 */
const MAX_INLINE_RUN_CACHE_SIZE: number = 4096

/**
 * 单个内联节点组的样式安全缓存项。
 */
class InlineRunCacheEntry {
  /** 节点组最后一个节点的标识。 */
  lastNodeId: number
  /** 节点组长度。 */
  nodeCount: number
  /** 生成 Run 时使用的继承样式快照。 */
  style: InlineTextStyle
  /** 已完成继承合并的内联 Run。 */
  runs: InlineRun[]

  /**
   * 创建内联 Run 缓存项。
   *
   * @param lastNodeId 节点组最后一个节点的标识
   * @param nodeCount 节点组长度
   * @param style 继承样式快照
   * @param runs 已扁平化的 Run
   */
  constructor(lastNodeId: number, nodeCount: number, style: InlineTextStyle, runs: InlineRun[]) {
    this.lastNodeId = lastNodeId
    this.nodeCount = nodeCount
    this.style = style
    this.runs = runs
  }
}

/**
 * 将 BBCode 语义节点渲染为支持文字、链接、媒体和结构块的 ArkUI 组件。
 */
@Component
export struct BBCodeContentView {
  /** 待渲染的 BBCode 根节点。 */
  nodes: BBNode[] = []
  /** 当前已展开的折叠块键。 */
  @State collapseKeys: Set<string> = new Set()
  /** 已知图片尺寸缓存。 */
  @State private imageSizes: Map<string, ImageSize> = new Map()
  /** 已完成加载的图片地址。 */
  @State private loadedImages: Set<string> = new Set()
  /** 加载失败的图片地址。 */
  @State private failedImages: Set<string> = new Set()
  /** 已允许释放占位约束的图片地址。 */
  @State private releasedImages: Set<string> = new Set()
  /** 已知视频尺寸缓存。 */
  @State private videoSizes: Map<string, ImageSize> = new Map()
  /** 当前生效的亮暗色模式。 */
  @StorageProp('effectiveColorMode') effectiveColorMode: string = 'light'
  /** 网络状态变化版本号。 */
  @StorageProp('networkChangeVersion') networkChangeVersion: number = 0
  /** 图片加载策略。 */
  @StorageProp('imageLoadStrategy') imageLoadStrategy: string = ImageLoadStrategy.ALWAYS
  /** 是否允许预取图片尺寸。 */
  @StorageProp('enableImageSizePrefetch') enableImageSizePrefetch: boolean = true
  /** 用户设置的正文基础字号。 */
  @StorageProp('contentFontSize') contentFontSize: number = 15
  /** 黑名单变更版本号。 */
  @StorageProp('blacklistVersion') @Watch('onBlacklistVersionChange') blacklistVersion: number = 0
  /** 是否隐藏加载失败的图片。 */
  hideFailedImages: boolean = false
  /** 图片点击回调。 */
  onImageClick: (urls: string[], index: number) => void = (_urls: string[], _index: number) => {}
  /** 链接点击回调。 */
  onLinkClick: (href: string) => void = (_href: string) => {}

  /** 当前内容内可供图片查看器浏览的地址。 */
  private allImageUrls: string[] = []
  /** 按节点组与继承样式缓存的内联渲染结果。 */
  private inlineRunCache: Map<number, InlineRunCacheEntry> = new Map<number, InlineRunCacheEntry>()

  /** 初始化节点分组并恢复或预取媒体尺寸。 */
  aboutToAppear(): void {
    this.inlineRunCache.clear()
    this.cachedGroups = this.splitIntoGroups(this.nodes)
    this.groupsReady = true
    this.allImageUrls = this.getImageUrls()
    const urls: string[] = this.allImageUrls
    const strategy: string = this.imageLoadStrategy
    const skipSizePrefetch: boolean = !this.enableImageSizePrefetch || strategy === ImageLoadStrategy.MANUAL || (strategy === ImageLoadStrategy.WIFI_ONLY && !isWifiConnected())
    if (!skipSizePrefetch) {
      for (let i = 0; i < urls.length; i++) {
        const url: string = urls[i]
        const cached: ImageSize | null = getCachedImageSize(url)
        if (cached) {
          this.imageSizes.set(url, cached)
          this.releasedImages.add(url)
        }
      }
      for (let i = 0; i < urls.length; i++) {
        const url: string = urls[i]
        if (!this.imageSizes.has(url)) {
          fetchImageSize(url).then((size: ImageSize | null) => {
            if (size) {
              this.setImageSize(url, size)
            } else {
              this.markImageFailed(url)
            }
          })
        }
      }
    } else {
      /* 被动模式：仅从缓存恢复已有尺寸，零网络请求。 */
      for (let i = 0; i < urls.length; i++) {
        const url: string = urls[i]
        const cached: ImageSize | null = getCachedImageSize(url)
        if (cached) {
          this.imageSizes.set(url, cached)
          this.releasedImages.add(url)
        }
      }
    }

    const vUrls: string[] = this.getVideoUrls()
    for (let i = 0; i < vUrls.length; i++) {
      const url: string = vUrls[i]
      const cached: ImageSize | null = getCachedVideoSize(url)
      if (cached) {
        this.videoSizes.set(url, cached)
      }
    }
    for (let i = 0; i < vUrls.length; i++) {
      const url: string = vUrls[i]
      if (!this.videoSizes.has(url)) {
        fetchVideoSize(url).then((size: ImageSize | null) => {
          if (size) {
            this.setVideoSize(url, size)
          }
        })
      }
    }
  }

  /**
   * 响应黑名单变化，立即更新图片查看器允许访问的图片集合。
   */
  private onBlacklistVersionChange(): void {
    this.allImageUrls = this.getImageUrls()
  }

  /**
   * 写入图片尺寸并解除其占位约束。
   *
   * @param url 图片地址
   * @param size 图片尺寸
   */
  private setImageSize(url: string, size: ImageSize): void {
    this.imageSizes.set(url, size)
    this.releasedImages.add(url)
  }

  /**
   * 记录图片加载失败。
   *
   * @param url 图片地址
   */
  private markImageFailed(url: string): void {
    if (!this.failedImages.has(url)) {
      this.failedImages.add(url)
    }
    this.loadedImages.add(url)
  }

  /**
   * 解除图片占位约束。
   *
   * @param url 图片地址
   */
  private releaseImage(url: string): void {
    this.releasedImages.add(url)
  }

  /**
   * 处理图片加载完成事件并补充实际尺寸。
   *
   * @param src 图片地址
   * @param imgWidth 实际宽度
   * @param imgHeight 实际高度
   */
  private onImageLoaded(src: string, imgWidth?: number, imgHeight?: number): void {
    this.loadedImages.add(src)
    if (imgWidth !== undefined && imgHeight !== undefined && imgWidth > 0 && imgHeight > 0) {
      if (!this.imageSizes.has(src)) {
        const size: ImageSize = new ImageSize()
        size.width = imgWidth
        size.height = imgHeight
        this.imageSizes.set(src, size)
        this.releasedImages.add(src)
      }
    }
  }

  /**
   * 返回图片宽高比，未知时使用安全占位比例。
   *
   * @param src 图片地址
   * @returns 图片宽高比
   */
  private getImageAspectRatio(src: string): number {
    const size: ImageSize | undefined = this.imageSizes.get(src)
    if (size && size.width > 0 && size.height > 0) {
      return size.width / size.height
    }
    return 16 / 9
  }

  /**
   * 返回图片在查看器地址数组中的索引。
   *
   * @param src 图片地址
   * @returns 图片索引
   */
  private getImageIndex(src: string): number {
    for (let i = 0; i < this.allImageUrls.length; i++) {
      if (this.allImageUrls[i] === src) {
        return i
      }
    }
    return 0
  }

  /**
   * 写入视频尺寸。
   *
   * @param url 视频地址
   * @param size 视频尺寸
   */
  private setVideoSize(url: string, size: ImageSize): void {
    this.videoSizes.set(url, size)
  }

  /**
   * 返回视频宽高比，未知时使用安全占位比例。
   *
   * @param src 视频地址
   * @returns 视频宽高比
   */
  private getVideoAspectRatio(src: string): number {
    const size: ImageSize | undefined = this.videoSizes.get(src)
    if (size && size.width > 0 && size.height > 0) {
      return size.width / size.height
    }
    return 16 / 9
  }

  /**
   * 收集当前节点树内允许访问的视频地址。
   *
   * @returns 视频地址数组
   */
  private getVideoUrls(): string[] {
    return this.collectVideoUrls(this.nodes, true)
  }

  /**
   * 递归收集视频地址。
   *
   * @param nodes 当前节点数组
   * @param skipBlacklistedQuotes 是否跳过黑名单引用
   * @returns 视频地址数组
   */
  private collectVideoUrls(nodes: BBNode[], skipBlacklistedQuotes: boolean): string[] {
    const urls: string[] = []
    for (let i = 0; i < nodes.length; i++) {
      const n = nodes[i]
      if (skipBlacklistedQuotes && n.type === BBNodeType.QUOTE && this.isQuoteBlacklisted(n)) {
        continue
      }
      if (n.type === BBNodeType.VIDEO && n.src.length > 0) {
        urls.push(n.src)
      }
      if (n.children.length > 0) {
        const childUrls = this.collectVideoUrls(n.children, skipBlacklistedQuotes)
        for (let j = 0; j < childUrls.length; j++) {
          urls.push(childUrls[j])
        }
      }
    }
    return urls
  }

  /**
   * 收集当前节点树内允许访问的图片地址。
   *
   * @returns 图片地址数组
   */
  private getImageUrls(): string[] {
    return this.collectUrls(this.nodes, true)
  }

  /**
   * 递归收集图片地址。
   *
   * @param nodes 当前节点数组
   * @param skipBlacklistedQuotes 是否跳过黑名单引用
   * @returns 图片地址数组
   */
  private collectUrls(nodes: BBNode[], skipBlacklistedQuotes: boolean): string[] {
    const urls: string[] = []
    for (let i = 0; i < nodes.length; i++) {
      const n = nodes[i]
      if (skipBlacklistedQuotes && n.type === BBNodeType.QUOTE && this.isQuoteBlacklisted(n)) {
        continue
      }
      if (n.type === BBNodeType.IMAGE && n.src.length > 0) {
        urls.push(n.src)
      }
      if (n.children.length > 0) {
        const childUrls = this.collectUrls(n.children, skipBlacklistedQuotes)
        for (let j = 0; j < childUrls.length; j++) {
          urls.push(childUrls[j])
        }
      }
    }
    return urls
  }

  /**
   * 判断引用正文是否来自黑名单用户。
   *
   * @param node - 引用块节点
   * @returns 是否应遮蔽引用正文
   */
  private isQuoteBlacklisted(node: BBNode): boolean {
    return this.blacklistVersion >= 0 &&
      isQuoteFromBlacklistedUser(node.children, appStore.settingsStore.getBlacklistIds())
  }

  /** 构建 BBCode 根布局。 */
  build() {
    Column() {
      if (this.nodes.length > 0) {
        this.RenderChildren(this.nodes, new RenderContext())
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 将连续内联节点和独立块节点分组。
   *
   * @param nodes 当前节点数组
   * @returns 渲染分组数组
   */
  private splitIntoGroups(nodes: BBNode[]): NodeGroup[] {
    const groups: NodeGroup[] = []
    let i = 0
    while (i < nodes.length) {
      if (isInlineNode(nodes[i].type)) {
        const inlineNodes: BBNode[] = []
        while (i < nodes.length && isInlineNode(nodes[i].type)) {
          inlineNodes.push(nodes[i])
          i++
        }
        const g = new NodeGroup()
        g.kind = 'inline'
        g.nodes = inlineNodes
        groups.push(g)
      } else {
        const g = new NodeGroup()
        g.kind = 'block'
        g.nodes = [nodes[i]]
        groups.push(g)
        i++
      }
    }
    return groups
  }

  /**
   * 判断两个继承文字样式是否产生相同的 Run。
   *
   * @param left 缓存中的样式快照
   * @param right 当前渲染上下文样式
   * @returns 是否可安全复用缓存
   */
  private areInlineStylesEqual(left: InlineTextStyle, right: InlineTextStyle): boolean {
    return left.bold === right.bold && left.italic === right.italic && left.underline === right.underline &&
      left.strikethrough === right.strikethrough && left.color === right.color &&
      left.scalePercent === right.scalePercent && left.fontFamily === right.fontFamily &&
      left.baseline === right.baseline
  }

  /**
   * 返回内联节点组的扁平化结果，相同节点与继承样式只计算一次。
   *
   * @param nodes 当前内联节点组
   * @param ctx 渲染上下文
   * @returns 可直接渲染的内联 Run
   */
  private getInlineRuns(nodes: BBNode[], ctx: RenderContext): InlineRun[] {
    if (nodes.length === 0) return []
    const key: number = nodes[0].id
    const cached: InlineRunCacheEntry | undefined = this.inlineRunCache.get(key)
    const lastNodeId: number = nodes[nodes.length - 1].id
    if (cached !== undefined && cached.lastNodeId === lastNodeId && cached.nodeCount === nodes.length &&
      this.areInlineStylesEqual(cached.style, ctx.inlineStyle)) return cached.runs
    const runs: InlineRun[] = flattenInlineNodes(nodes, ctx.inlineStyle)
    if (this.inlineRunCache.size >= MAX_INLINE_RUN_CACHE_SIZE) {
      this.inlineRunCache.clear()
    }
    this.inlineRunCache.set(key, new InlineRunCacheEntry(
      lastNodeId, nodes.length, cloneInlineTextStyle(ctx.inlineStyle), runs))
    return runs
  }

  /**
   * 返回当前正文上下文的语义字号。
   *
   * @param ctx BBCode 渲染上下文
   * @returns 正文或引用正文的实际字号
   */
  private inlineFontSize(ctx: RenderContext): number {
    return calcScaleSize(ctx.inlineStyle.scalePercent, ctx.inQuote, this.contentFontSize)
  }

  /**
   * 返回当前正文上下文的语义行高。
   *
   * @param ctx BBCode 渲染上下文
   * @returns 正文或引用正文的实际行高
   */
  private inlineLineHeight(ctx: RenderContext): number {
    const role: ReadingLineHeightRole =
      ctx.inQuote ? ReadingLineHeightRole.QUOTE : ReadingLineHeightRole.CONTENT
    return ReadingTypography.lineHeight(role, this.inlineFontSize(ctx))
  }

  /**
   * 返回当前正文上下文中辅助文本的语义字号。
   *
   * @param ctx BBCode 渲染上下文
   * @returns 辅助文本的实际字号
   */
  private fallbackFontSize(ctx: RenderContext): number {
    return ReadingTypography.fontSize(ReadingFontRole.FALLBACK, this.inlineFontSize(ctx))
  }

  /**
   * 返回当前正文上下文中代码块的语义字号。
   *
   * @param ctx BBCode 渲染上下文
   * @returns 代码块的实际字号
   */
  private codeFontSize(ctx: RenderContext): number {
    return ReadingTypography.fontSize(ReadingFontRole.CODE, this.inlineFontSize(ctx))
  }

  /**
   * 返回当前正文上下文中代码块的语义行高。
   *
   * @param ctx BBCode 渲染上下文
   * @returns 代码块的实际行高
   */
  private codeLineHeight(ctx: RenderContext): number {
    return ReadingTypography.lineHeight(ReadingLineHeightRole.CODE, this.codeFontSize(ctx))
  }

  /** 顶层节点的预计算渲染分组。 */
  private cachedGroups: NodeGroup[] = []
  /** 顶层渲染分组是否已准备完成。 */
  private groupsReady: boolean = false

  /**
   * 渲染一组 BBCode 子节点。
   *
   * @param nodes 子节点数组
   * @param ctx 渲染上下文
   */
  @Builder
  RenderChildren(nodes: BBNode[], ctx: RenderContext) {
    ForEach(nodes === this.nodes && this.groupsReady ? this.cachedGroups : this.splitIntoGroups(nodes), (group: NodeGroup) => {
      if (group.kind === 'inline') {
        if (!isInlineRunsBlank(this.getInlineRuns(group.nodes, ctx))) {
          Text() {
            ForEach(this.getInlineRuns(group.nodes, ctx), (run: InlineRun) => {
              this.RenderInlineRun(run, ctx)
            }, (run: InlineRun) => run.key)
          }
          .fontSize(this.inlineFontSize(ctx))
          .fontColor(ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary)
          .fontStyle(ctx.inQuote ? FontStyle.Italic : FontStyle.Normal)
          .lineHeight(this.inlineGroupLineHeight(this.getInlineRuns(group.nodes, ctx), ctx))
          .width('100%')
          .textAlign(ctx.textAlign)
        }
      } else {
        this.RenderBlockNode(group.nodes[0], ctx)
      }
    }, (group: NodeGroup) => 'g_' + group.nodes[0].id.toString())
  }

  /**
   * 渲染一个已扁平化的内联 Run。
   *
   * @param run 内联渲染单元
   * @param ctx 渲染上下文
   */
  @Builder
  RenderInlineRun(run: InlineRun, ctx: RenderContext) {
    if (run.kind === InlineRunKind.EMOTION) {
      if (getEmotionResource(run.emotionCat, run.emotionCode) !== null) {
        ImageSpan(getEmotionResource(run.emotionCat, run.emotionCode))
          .width(this.inlineEmotionSize(run, ctx))
          .height(this.inlineEmotionSize(run, ctx))
          .objectFit(ImageFit.Contain)
          .textBackgroundStyle(this.effectiveColorMode === 'dark' &&
            isEmotionCategoryNeedDarkBg(run.emotionCat)
            ? { color: Color.White } : { color: Color.Transparent })
      } else {
        Span(`[表情:${run.emotionCat}:${run.emotionCode}]`)
          .fontSize(this.fallbackFontSize(ctx))
          .fontColor(AppColors.textTertiary)
      }
    } else if (run.kind === InlineRunKind.LINK) {
      Span(run.text)
        .fontWeight(run.style.bold ? FontWeight.Bold : FontWeight.Normal)
        .fontStyle(run.style.italic || ctx.inQuote ? FontStyle.Italic : FontStyle.Normal)
        .fontColor(AppColors.primary)
        .fontFamily(run.style.fontFamily)
        .fontSize(this.inlineRunFontSize(run, ctx))
        .baselineOffset(new LengthMetrics(this.inlineRunBaselineOffset(run, ctx)))
        .decoration({
          type: run.style.strikethrough ? TextDecorationType.LineThrough : TextDecorationType.Underline,
          color: AppColors.primary
        })
        .onClick(() => {
          if (run.href.length > 0) this.onLinkClick(run.href)
        })
    } else {
      Span(run.text)
        .fontWeight(run.style.bold ? FontWeight.Bold : FontWeight.Normal)
        .fontStyle(run.style.italic || ctx.inQuote ? FontStyle.Italic : FontStyle.Normal)
        .fontColor(run.style.color.length > 0 ? run.style.color :
          (ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary))
        .fontFamily(run.style.fontFamily)
        .fontSize(this.inlineRunFontSize(run, ctx))
        .baselineOffset(new LengthMetrics(this.inlineRunBaselineOffset(run, ctx)))
        .decoration({
          type: run.style.strikethrough ? TextDecorationType.LineThrough :
            run.style.underline ? TextDecorationType.Underline : TextDecorationType.None,
          color: run.style.color.length > 0 ? run.style.color :
            (ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary)
        })
    }
  }

  /**
   * 返回 Run 在应用上下标前的继承字号。
   *
   * @param run 内联 Run
   * @param ctx 渲染上下文
   * @returns 基础字号
   */
  private inlineRunBaseFontSize(run: InlineRun, ctx: RenderContext): number {
    return calcScaleSize(run.style.scalePercent, ctx.inQuote, this.contentFontSize)
  }

  /**
   * 返回 Run 的最终字号。
   *
   * @param run 内联 Run
   * @param ctx 渲染上下文
   * @returns 最终字号
   */
  private inlineRunFontSize(run: InlineRun, ctx: RenderContext): number {
    const baseSize: number = this.inlineRunBaseFontSize(run, ctx)
    if (run.style.baseline === InlineBaseline.SUBSCRIPT) return calcSubscriptSize(baseSize)
    if (run.style.baseline === InlineBaseline.SUPERSCRIPT) return calcSuperscriptSize(baseSize)
    return baseSize
  }

  /**
   * 返回 Run 的基线偏移。
   *
   * @param run 内联 Run
   * @param ctx 渲染上下文
   * @returns ArkUI 基线偏移
   */
  private inlineRunBaselineOffset(run: InlineRun, ctx: RenderContext): number {
    const baseSize: number = this.inlineRunBaseFontSize(run, ctx)
    if (run.style.baseline === InlineBaseline.SUBSCRIPT) return calcSubscriptOffset(baseSize)
    if (run.style.baseline === InlineBaseline.SUPERSCRIPT) return calcSuperscriptOffset(baseSize)
    return 0
  }

  /**
   * 根据周围字号计算紧凑的行内表情尺寸。
   *
   * @param run 表情 Run
   * @param ctx 渲染上下文
   * @returns 表情边长
   */
  private inlineEmotionSize(run: InlineRun, ctx: RenderContext): number {
    const factor: number = ctx.inQuote ? 1.8 : 2.4
    return Math.min(50, Math.max(24, Math.round(this.inlineRunBaseFontSize(run, ctx) * factor)))
  }

  /**
   * 根据当前行内组的最大字号计算安全行高，避免放大文字发生裁切或重叠。
   *
   * @param runs 当前行内节点组的扁平化结果
   * @param ctx 渲染上下文
   * @returns 行内组统一行高
   */
  private inlineGroupLineHeight(runs: InlineRun[], ctx: RenderContext): number {
    let largestFontSize: number = this.inlineFontSize(ctx)
    for (let i: number = 0; i < runs.length; i++) {
      largestFontSize = Math.max(largestFontSize, this.inlineRunFontSize(runs[i], ctx))
    }
    const role: ReadingLineHeightRole = ctx.inQuote ? ReadingLineHeightRole.QUOTE : ReadingLineHeightRole.CONTENT
    return ReadingTypography.lineHeight(role, largestFontSize)
  }

  /**
   * 按语义类型分发一个块级节点。
   *
   * @param node 块级节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderBlockNode(node: BBNode, ctx: RenderContext) {
    if (node.type === BBNodeType.HR) {
      this.RenderHorizontalRule()
    } else if (node.type === BBNodeType.HEADING) {
      this.RenderHeading(node, this.makeHeadingCtx(node, ctx))
    } else if (node.type === BBNodeType.PARAGRAPH) {
      this.RenderParagraph(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.IMAGE) {
      this.RenderImage(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.QUOTE) {
      this.RenderQuote(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.COLLAPSE) {
      this.RenderCollapse(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.CODE) {
      this.RenderCode(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.LIST) {
      this.RenderList(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.VIDEO) {
      if (node.src.length > 0) {
        MutedVideo({ src: node.src, videoAspectRatio: this.getVideoAspectRatio(node.src) })
          .margin({ top: 6, bottom: 4 })
      }
    } else if (node.type === BBNodeType.AUDIO) {
      AudioPlayer({ src: node.src })
        .margin({ top: 6, bottom: 4 })
    } else if (node.type === BBNodeType.FLASH) {
      Text('[Flash 内容]')
        .fontSize(15).fontColor(AppColors.primary)
        .decoration({ type: TextDecorationType.Underline, color: AppColors.primary })
        .margin({ top: 6, bottom: 4 })
        .onClick(() => {
          if (node.href.length > 0) this.onLinkClick(node.href)
        })
    } else if (node.type === BBNodeType.DICE) {
      Row() {
        Image($r('app.media.icon_dice')).width(15).height(15).fillColor(AppColors.textPrimary).margin({ right: 4 })
        Text('骰子').fontSize(15).fontColor(AppColors.textPrimary)
      }
    } else if (node.type === BBNodeType.WARN) {
      this.RenderWarn(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.ALBUM) {
      this.RenderAlbum(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.FLOAT_LEFT) {
      this.RenderFloat(node, FlexAlign.Start, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.FLOAT_RIGHT) {
      this.RenderFloat(node, FlexAlign.End, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.ALIGN) {
      this.RenderAlign(node, ctx)
    } else if (node.type === BBNodeType.TABLE) {
      this.RenderTable(node, this.makeBlockCtx(node, ctx))
    } else if (node.type === BBNodeType.STYLE_DIV) {
      this.RenderStyleDiv(node, ctx)
    } else if (node.type === BBNodeType.POST_BY) {
      this.RenderReplyRef(node, this.makeBlockCtx(node, ctx))
    }
  }

  /** 渲染水平分隔线。 */
  @Builder
  RenderHorizontalRule() {
    Divider()
      .width('100%')
      .strokeWidth(1)
      .color(AppColors.separator)
      .margin({ top: 8, bottom: 8 })
  }

  /**
   * 渲染与 HTML `h4.subtitle` 对应的独立标题块。
   *
   * @param node 标题节点
   * @param ctx 标题后代的渲染上下文
   */
  @Builder
  RenderHeading(node: BBNode, ctx: RenderContext) {
    Column() {
      this.RenderChildren(node.children, ctx)
      Divider()
        .width('100%')
        .strokeWidth(1)
        .color(AppColors.separator)
        .margin({ top: 6 })
    }
    .width('100%')
    .alignItems(this.horizontalAlignForText(ctx.textAlign))
    .margin({ top: 10, bottom: 8 })
  }

  /**
   * 渲染独立段落。
   *
   * @param node 段落节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderParagraph(node: BBNode, ctx: RenderContext) {
    Column() {
      this.RenderChildren(node.children, ctx)
    }
    .width('100%')
    .alignItems(this.horizontalAlignForText(ctx.textAlign))
    .margin({ top: 2, bottom: 6 })
  }

  /**
   * 将跨越块节点的内联格式转为块后代可继承的渲染上下文。
   *
   * @param node 当前块节点
   * @param parent 父级渲染上下文
   * @returns 块节点自身使用的上下文
   */
  private makeBlockCtx(node: BBNode, parent: RenderContext): RenderContext {
    if (node.inheritedFormatTags.length === 0) return parent
    const result = new RenderContext()
    result.inQuote = parent.inQuote
    result.quoteDepth = parent.quoteDepth
    result.inlineStyle = applyInlineFormatTags(node.inheritedFormatTags, parent.inlineStyle)
    result.textAlign = parent.textAlign
    return result
  }

  /**
   * 创建四级标题的粗体文字上下文，并保留外层跨块样式。
   *
   * @param node 标题节点
   * @param parent 父级渲染上下文
   * @returns 标题后代使用的渲染上下文
   */
  private makeHeadingCtx(node: BBNode, parent: RenderContext): RenderContext {
    const result: RenderContext = new RenderContext()
    result.inQuote = parent.inQuote
    result.quoteDepth = parent.quoteDepth
    result.inlineStyle = applyInlineFormatTags(node.inheritedFormatTags, parent.inlineStyle)
    result.inlineStyle.bold = true
    result.textAlign = parent.textAlign
    return result
  }

  /**
   * 渲染图片块。
   *
   * @param node 图片节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderImage(node: BBNode, ctx: RenderContext) {
    if (node.src.length > 0 && !(this.hideFailedImages && this.failedImages.has(node.src))) {
      this.RenderImageContent(node.src, ctx.inQuote)
    }
  }

  /**
   * 根据加载策略渲染图片内容或占位视图。
   *
   * @param src 图片地址
   * @param inQuote 是否位于引用块内
   */
  @Builder
  RenderImageContent(src: string, inQuote: boolean) {
    if (shouldUsePassive(this.imageLoadStrategy)) {
      /* 被动式：紧凑占位图。 */
      Row() {
        Stack() {
          Image($r('app.media.icon_image'))
            .width(18).height(18)
            .fillColor(AppColors.textTertiary)
            .opacity(0.45)
        }
        .width(28).height(28)
        .borderRadius(6)
        .backgroundColor(AppColors.bgSecondary)

        Text('点击查看图片').fontSize(13).fontColor(AppColors.textTertiary).margin({ left: 8 })
      }
      .padding({ left: 10, right: 10 })
      .height(40)
      .borderRadius(8)
      .backgroundColor(AppColors.bgSecondary)
      .margin({ top: 6, bottom: 4 })
      .onClick(() => {
        let urls: string[] = this.allImageUrls.length > 0 ? this.allImageUrls : [src]
        let idx: number = this.getImageIndex(src)
        this.onImageClick(urls, idx)
      })
    } else {
      /* 主动式：原有加载行为。 */
      Stack() {
        if (!this.loadedImages.has(src)) {
          Column() {
            LoadingProgress()
              .width(24).height(24)
              .color(AppColors.textTertiary)
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        }

        if (this.releasedImages.has(src) || this.getImageAspectRatio(src) > 0) {
          Image(src)
            .width('100%').height('100%')
            .objectFit(inQuote ? ImageFit.Cover : ImageFit.Contain)
            .borderRadius(inQuote ? 6 : 8)
            .onError(() => {
              this.markImageFailed(src)
            })
            .onComplete((event) => {
              if (event) {
                this.onImageLoaded(src, event.width, event.height)
              } else {
                this.onImageLoaded(src)
              }
            })
            .onClick(() => {
              let urls: string[] = this.allImageUrls.length > 0 ? this.allImageUrls : [src]
              let idx: number = this.getImageIndex(src)
              this.onImageClick(urls, idx)
            })
        }
      }
      .width('100%')
      .aspectRatio(this.getImageAspectRatio(src))
      .constraintSize({
        maxWidth: '100%',
        maxHeight: inQuote ? 200 : 10000,
        minHeight: 60,
      })
      .backgroundColor(this.loadedImages.has(src) ? Color.Transparent : AppColors.bgSecondary)
      .borderRadius(inQuote ? 6 : 8)
      .margin({ top: 6, bottom: 4 })
    }
  }

  /**
   * 渲染引用块及其来源头。
   *
   * @param node 引用节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderQuote(node: BBNode, ctx: RenderContext) {
    Column() {
      if (splitQuoteChildren(node.children).hasHeader) {
        this.RenderQuoteHeader(node.children[0], ctx)
        if (this.isQuoteBlacklisted(node)) {
          Text('该用户已被屏蔽')
            .fontSize(this.inlineFontSize(this.makeQuoteCtx(ctx)))
            .fontColor(AppColors.textTertiary)
            .lineHeight(this.inlineLineHeight(this.makeQuoteCtx(ctx)))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 8, bottom: 8 })
        } else {
          this.RenderChildren(splitQuoteChildren(node.children).body, this.makeQuoteCtx(ctx))
        }
      } else {
        this.RenderChildren(node.children, this.makeQuoteCtx(ctx))
      }
    }
    .width('100%')
    .padding({ left: 12, top: 6, bottom: 6 })
    .margin({ top: 6, bottom: 4 })
    .border({
      width: { left: 2 },
      color: { left: QUOTE_BORDER_COLORS[Math.min(ctx.quoteDepth, QUOTE_BORDER_COLORS.length - 1)] },
      style: { left: BorderStyle.Solid }
    })
    .borderRadius({ topLeft: 4, bottomLeft: 4 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 渲染引用来源头。
   *
   * @param node 来源头节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderQuoteHeader(node: BBNode, ctx: RenderContext) {
    Row() {
      Text() {
        ForEach(flattenInlineNodes(node.children, ctx.inlineStyle), (run: InlineRun) => {
          this.RenderInlineRun(run, this.makeQuoteCtx(ctx))
        }, (run: InlineRun) => run.key)
      }
      .fontSize(14)
      .fontColor(AppColors.textSecondary)
      .fontStyle(FontStyle.Italic)
      .lineHeight(20)
    }
    .width('100%')
    .padding({ bottom: 2 })
  }

  /**
   * 创建引用正文的渲染上下文。
   *
   * @param parent 父级上下文
   * @returns 引用上下文
   */
  private makeQuoteCtx(parent: RenderContext): RenderContext {
    const c = new RenderContext()
    c.inQuote = true
    c.quoteDepth = parent.quoteDepth + 1
    c.inlineStyle = parent.inlineStyle
    c.textAlign = parent.textAlign
    return c
  }

  /**
   * 为白名单 `[style ...]` 块创建继承文字样式的上下文。
   *
   * @param node STYLE_DIV 节点
   * @param parent 父级渲染上下文
   * @returns 样式块子节点上下文
   */
  private makeStyleCtx(node: BBNode, parent: RenderContext): RenderContext {
    const result = new RenderContext()
    result.inQuote = parent.inQuote
    result.quoteDepth = parent.quoteDepth
    const inheritedStyle: InlineTextStyle = applyInlineFormatTags(node.inheritedFormatTags, parent.inlineStyle)
    result.inlineStyle = applyTextStyleDeclaration(node.text, inheritedStyle)
    result.textAlign = this.resolveTextAlign(extractTextStyleAlign(node.text), parent.textAlign)
    return result
  }

  /**
   * 把 BBCode 对齐值转换为 ArkUI 文字对齐方式。
   *
   * @param value left、center、right 或空字符串
   * @param inherited 未显式声明时继承的对齐方式
   * @returns ArkUI 文字对齐方式
   */
  private resolveTextAlign(value: string, inherited: TextAlign): TextAlign {
    if (value === 'center') return TextAlign.Center
    if (value === 'right') return TextAlign.End
    if (value === 'left') return TextAlign.Start
    return inherited
  }

  /**
   * 把文字对齐方式转换为 Column 子项的水平对齐方式。
   *
   * @param textAlign ArkUI 文字对齐方式
   * @returns Column 水平对齐方式
   */
  private horizontalAlignForText(textAlign: TextAlign): HorizontalAlign {
    if (textAlign === TextAlign.Center) return HorizontalAlign.Center
    if (textAlign === TextAlign.End) return HorizontalAlign.End
    return HorizontalAlign.Start
  }

  /**
   * 为显式 `[align]` 块创建可向后代传递的对齐上下文。
   *
   * @param node ALIGN 节点
   * @param parent 父级渲染上下文
   * @returns 对齐块子节点上下文
   */
  private makeAlignCtx(node: BBNode, parent: RenderContext): RenderContext {
    const result = new RenderContext()
    result.inQuote = parent.inQuote
    result.quoteDepth = parent.quoteDepth
    result.inlineStyle = applyInlineFormatTags(node.inheritedFormatTags, parent.inlineStyle)
    result.textAlign = this.resolveTextAlign(node.align, parent.textAlign)
    return result
  }

  /**
   * 渲染回复来源引用。
   *
   * @param node 回复来源节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderReplyRef(node: BBNode, ctx: RenderContext) {
    Column() {
      this.RenderChildren(node.children, this.makeQuoteCtx(ctx))
    }
    .width('100%')
    .padding({ left: 12, top: 6, bottom: 6 })
    .margin({ top: 6, bottom: 4 })
    .border({
      width: { left: 2 },
      color: { left: AppColors.quoteBorders[1] },
      style: { left: BorderStyle.Solid }
    })
    .borderRadius({ topLeft: 4, bottomLeft: 4 })
    .alignItems(HorizontalAlign.Start)
    .constraintSize({ maxHeight: 80 })
    .opacity(0.85)
  }

  /**
   * 渲染可展开或收起的折叠块。
   *
   * @param node 折叠节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderCollapse(node: BBNode, ctx: RenderContext) {
    Column() {
      Row() {
        Text(this.collapseKeys.has(node.title) ? '▾ ' : '▸ ')
          .fontSize(14)
          .fontColor(AppColors.primary)
          .fontWeight(FontWeight.Medium)
        Text(node.title)
          .fontSize(14)
          .fontColor(AppColors.textSecondary)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        if (!this.collapseKeys.has(node.title)) {
          Text('点击展开')
            .fontSize(11)
            .fontColor(AppColors.textTertiary)
            .margin({ right: 4 })
        }
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .backgroundColor(AppColors.bgSecondary)
      .borderRadius(8)
      .onClick(() => {
        if (this.collapseKeys.has(node.title)) {
          this.collapseKeys.delete(node.title)
        } else {
          this.collapseKeys.add(node.title)
        }
      })

      if (this.collapseKeys.has(node.title)) {
        Column() {
          this.RenderChildren(node.children, ctx)
        }
        .width('100%')
        .padding({ left: 12, top: 8, bottom: 8 })
        .alignItems(HorizontalAlign.Start)
        .border({
          width: { left: 2 },
          color: { left: AppColors.quoteBorders[0] },
          style: { left: BorderStyle.Solid }
        })
        .borderRadius({ topLeft: 4, bottomLeft: 4 })
        .margin({ top: 4 })
      }
    }
    .width('100%')
    .margin({ top: 4, bottom: 2 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 渲染等宽字体代码块。
   *
   * @param node 代码节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderCode(node: BBNode, ctx: RenderContext) {
    Scroll() {
      Text(node.text)
        .fontSize(this.codeFontSize(ctx))
        .fontColor(AppColors.textPrimary)
        .fontFamily('monospace')
        .lineHeight(this.codeLineHeight(ctx))
    }
    .width('100%')
    .scrollable(ScrollDirection.Horizontal)
    .padding(10)
    .margin({ top: 6, bottom: 4 })
    .borderRadius(8)
    .backgroundColor(AppColors.bgSecondary)
    .align(Alignment.TopStart)
  }

  /**
   * 渲染列表及其项目。
   *
   * @param node 列表节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderList(node: BBNode, ctx: RenderContext) {
    Column() {
      ForEach(node.children, (child: BBNode) => {
        if (child.type === BBNodeType.LIST_ITEM) {
          Row() {
            Text('• ')
              .fontSize(this.inlineFontSize(ctx))
              .fontColor(ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary)
            if (child.children.length > 0) {
              Column() {
                this.RenderChildren(child.children, ctx)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            } else {
              Text(child.text)
                .fontSize(this.inlineFontSize(ctx))
                .fontColor(ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary)
                .layoutWeight(1)
                .lineHeight(this.inlineLineHeight(ctx))
            }
          }
          .width('100%')
          .padding({ top: 2, bottom: 2 })
          .alignItems(VerticalAlign.Top)
        }
      }, (child: BBNode) => child.id.toString())
    }
    .width('100%')
    .padding({ left: 12 })
    .margin({ top: 4, bottom: 4 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 渲染警告提示块。
   *
   * @param node 警告节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderWarn(node: BBNode, ctx: RenderContext) {
    Column() {
      if (node.children.length > 0) {
        this.RenderChildren(node.children, ctx)
      } else {
        Text(node.text)
          .fontSize(this.inlineFontSize(ctx))
          .fontColor(AppColors.warnText)
          .lineHeight(this.inlineLineHeight(ctx))
      }
    }
    .width('100%')
    .padding(12)
    .margin({ top: 6, bottom: 4 })
    .borderRadius(8)
    .backgroundColor(AppColors.warnBg)
    .border({ width: 1, color: AppColors.warnBorder })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 渲染相册块。
   *
   * @param node 相册节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderAlbum(node: BBNode, ctx: RenderContext) {
    Column() {
      if (node.title.length > 0) {
        Text(node.title)
          .fontSize(14)
          .fontColor(AppColors.textSecondary)
          .fontWeight(FontWeight.Bold)
          .padding({ top: 4, bottom: 4 })
      }
      this.RenderChildren(node.children, ctx)
    }
    .width('100%')
    .padding(10)
    .margin({ top: 6, bottom: 4 })
    .borderRadius(8)
    .backgroundColor(AppColors.bgSecondary)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 渲染左侧或右侧对齐的浮动块。
   *
   * @param node 浮动节点
   * @param flexAlign 水平对齐方式
   * @param ctx 渲染上下文
   */
  @Builder
  RenderFloat(node: BBNode, flexAlign: FlexAlign, ctx: RenderContext) {
    Row() {
      Column() {
        this.RenderChildren(node.children, ctx)
      }
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .justifyContent(flexAlign)
    .margin({ top: 4, bottom: 2 })
  }

  /**
   * 渲染显式文字对齐块。
   *
   * @param node 对齐节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderAlign(node: BBNode, ctx: RenderContext) {
    Column() {
      this.RenderChildren(node.children, this.makeAlignCtx(node, ctx))
    }
    .width('100%')
    .alignItems(this.horizontalAlignForText(this.resolveTextAlign(node.align, ctx.textAlign)))
    .margin({ top: 4, bottom: 2 })
  }

  /**
   * 渲染表格块，暂时保持既有实现。
   *
   * @param node 表格节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderTable(node: BBNode, ctx: RenderContext) {
    Column() {
      ForEach(node.children, (row: BBNode) => {
        if (row.type === BBNodeType.TABLE_ROW) {
          Row() {
            ForEach(row.children, (cell: BBNode) => {
              if (cell.type === BBNodeType.TABLE_CELL) {
                Column() {
                  this.RenderChildren(cell.children, ctx)
                }
                .padding(6)
                .layoutWeight(cell.colSpan > 1 ? cell.colSpan : 1)
                .border({ width: 0.5, color: AppColors.separator })
                .alignItems(HorizontalAlign.Start)
              }
            }, (cell: BBNode) => cell.id.toString())
          }
          .width('100%')
        }
      }, (row: BBNode) => row.id.toString())
    }
    .width('100%')
    .margin({ top: 6, bottom: 4 })
    .border({ width: 0.5, color: AppColors.separator })
    .borderRadius(4)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 渲染经过白名单过滤的样式块。
   *
   * @param node 样式节点
   * @param ctx 渲染上下文
   */
  @Builder
  RenderStyleDiv(node: BBNode, ctx: RenderContext) {
    Column() {
      this.RenderChildren(node.children, this.makeStyleCtx(node, ctx))
    }
    .width('100%')
    .margin({ top: 4, bottom: 2 })
    .alignItems(this.horizontalAlignForText(
      this.resolveTextAlign(extractTextStyleAlign(node.text), ctx.textAlign)))
  }
}
