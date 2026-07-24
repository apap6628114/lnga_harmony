import { BBNode, BBNodeType } from '../../model/BBCodeNode'
import { AppColors, ImageLoadStrategy } from '../constants/Constants'
import { getEmotionResource, isEmotionCategoryNeedDarkBg } from '../media/EmotionResources'
import { AudioPlayer } from '../media/AudioPlayer'
import { MutedVideo } from '../media/MutedVideo'
import { ImageSize, fetchImageSize, getCachedImageSize } from '../media/ImageSizeUtil'
import { fetchVideoSize, getCachedVideoSize } from '../media/VideoSizeUtil'
import { isWifiConnected, shouldUsePassive } from '../utils/NetworkUtil'
import { LengthMetrics } from '@kit.ArkUI'
import {
  isInlineNode,
  isInlineGroupBlank,
  calcScaleSize,
  calcSubscriptSize,
  calcSubscriptOffset,
  calcSuperscriptSize,
  calcSuperscriptOffset,
} from './bbcode/bbcode-utils'
import {
  RenderContext,
  NodeGroup,
  splitQuoteChildren,
  QUOTE_BORDER_COLORS,
} from './bbcode/BBCodeRenderContext'

@Component
export struct BBCodeContentView {
  nodes: BBNode[] = []
  @State collapseKeys: Set<string> = new Set()
  @State private imageSizes: Map<string, ImageSize> = new Map()
  @State private loadedImages: Set<string> = new Set()
  @State private failedImages: Set<string> = new Set()
  @State private releasedImages: Set<string> = new Set()
  @State private videoSizes: Map<string, ImageSize> = new Map()
  @StorageProp('effectiveColorMode') effectiveColorMode: string = 'light'
  @StorageProp('networkChangeVersion') networkChangeVersion: number = 0
  @StorageProp('imageLoadStrategy') imageLoadStrategy: string = ImageLoadStrategy.ALWAYS
  @StorageProp('enableImageSizePrefetch') enableImageSizePrefetch: boolean = true
  @StorageProp('contentFontSize') contentFontSize: number = 15
  hideFailedImages: boolean = false
  onImageClick: (urls: string[], index: number) => void = (_urls: string[], _index: number) => {}
  onLinkClick: (href: string) => void = (_href: string) => {}

  private allImageUrls: string[] = []

  aboutToAppear(): void {
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
      // 被动模式：仅从缓存恢复已有尺寸，零网络请求
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

  private setImageSize(url: string, size: ImageSize): void {
    this.imageSizes.set(url, size)
    this.releasedImages.add(url)
  }

  private markImageFailed(url: string): void {
    if (!this.failedImages.has(url)) {
      this.failedImages.add(url)
    }
    this.loadedImages.add(url)
  }

  private releaseImage(url: string): void {
    this.releasedImages.add(url)
  }

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

  private getImageAspectRatio(src: string): number {
    const size: ImageSize | undefined = this.imageSizes.get(src)
    if (size && size.width > 0 && size.height > 0) {
      return size.width / size.height
    }
    return 16 / 9
  }

  private getImageIndex(src: string): number {
    for (let i = 0; i < this.allImageUrls.length; i++) {
      if (this.allImageUrls[i] === src) {
        return i
      }
    }
    return 0
  }

  private setVideoSize(url: string, size: ImageSize): void {
    this.videoSizes.set(url, size)
  }

  private getVideoAspectRatio(src: string): number {
    const size: ImageSize | undefined = this.videoSizes.get(src)
    if (size && size.width > 0 && size.height > 0) {
      return size.width / size.height
    }
    return 16 / 9
  }

  private getVideoUrls(): string[] {
    return this.collectVideoUrls(this.nodes)
  }

  private collectVideoUrls(nodes: BBNode[]): string[] {
    const urls: string[] = []
    for (let i = 0; i < nodes.length; i++) {
      const n = nodes[i]
      if (n.type === BBNodeType.VIDEO && n.src.length > 0) {
        urls.push(n.src)
      }
      if (n.children.length > 0) {
        const childUrls = this.collectVideoUrls(n.children)
        for (let j = 0; j < childUrls.length; j++) {
          urls.push(childUrls[j])
        }
      }
    }
    return urls
  }

  private getImageUrls(): string[] {
    return this.collectUrls(this.nodes)
  }

  private collectUrls(nodes: BBNode[]): string[] {
    const urls: string[] = []
    for (let i = 0; i < nodes.length; i++) {
      const n = nodes[i]
      if (n.type === BBNodeType.IMAGE && n.src.length > 0) {
        urls.push(n.src)
      }
      if (n.children.length > 0) {
        const childUrls = this.collectUrls(n.children)
        for (let j = 0; j < childUrls.length; j++) {
          urls.push(childUrls[j])
        }
      }
    }
    return urls
  }

  build() {
    Column() {
      if (this.nodes.length > 0) {
        this.RenderChildren(this.nodes, new RenderContext())
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

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

  private cachedGroups: NodeGroup[] = []
  private groupsReady: boolean = false

  @Builder
  RenderChildren(nodes: BBNode[], ctx: RenderContext) {
    ForEach(nodes === this.nodes && this.groupsReady ? this.cachedGroups : this.splitIntoGroups(nodes), (group: NodeGroup) => {
      if (group.kind === 'inline') {
        if (!isInlineGroupBlank(group.nodes)) {
          Text() {
            ForEach(group.nodes, (node: BBNode) => {
              this.RenderInlineSpan(node, ctx)
            }, (node: BBNode) => node.id.toString())
          }
          .fontSize(ctx.inQuote ? (this.contentFontSize - 1) : this.contentFontSize)
          .fontColor(ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary)
          .fontStyle(ctx.inQuote ? FontStyle.Italic : FontStyle.Normal)
          .lineHeight(ctx.inQuote ? 24 : 26)
          .width('100%')
        }
      } else {
        this.RenderBlockNode(group.nodes[0], ctx)
      }
    }, (group: NodeGroup) => 'g_' + group.nodes[0].id.toString())
  }

  @Builder
  RenderInlineSpan(node: BBNode, ctx: RenderContext) {
    if (node.type === BBNodeType.TEXT) {
      Span(node.text)
        .fontColor(ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary)
    } else if (node.type === BBNodeType.BOLD) {
      this.RenderFormattedSpan(node, ctx, FontWeight.Bold, FontStyle.Italic, TextDecorationType.None, '', 0, '', 0)
    } else if (node.type === BBNodeType.ITALIC) {
      this.RenderFormattedSpan(node, ctx, FontWeight.Normal, FontStyle.Italic, TextDecorationType.None, '', 0, '', 0)
    } else if (node.type === BBNodeType.UNDERLINE) {
      this.RenderFormattedSpan(node, ctx, FontWeight.Normal, FontStyle.Normal, TextDecorationType.Underline, '', 0, '', 0)
    } else if (node.type === BBNodeType.STRIKETHROUGH) {
      this.RenderFormattedSpan(node, ctx, FontWeight.Normal, FontStyle.Normal, TextDecorationType.LineThrough, '', 0, '', 0)
    } else if (node.type === BBNodeType.COLOR) {
      this.RenderFormattedSpan(node, ctx, FontWeight.Normal, FontStyle.Normal, TextDecorationType.None, node.color, 0, '', 0)
    } else if (node.type === BBNodeType.SIZE) {
      this.RenderFormattedSpan(node, ctx, FontWeight.Normal, FontStyle.Normal, TextDecorationType.None, '', calcScaleSize(node.size, ctx.inQuote, this.contentFontSize), '', 0)
    } else if (node.type === BBNodeType.FONT) {
      this.RenderFormattedSpan(node, ctx, FontWeight.Normal, FontStyle.Normal, TextDecorationType.None, '', 0, node.fontFamily, 0)
    } else if (node.type === BBNodeType.URL || node.type === BBNodeType.PID_LINK ||
      node.type === BBNodeType.UID_LINK || node.type === BBNodeType.TID_LINK ||
      node.type === BBNodeType.MENTION) {
      Span(node.text)
        .fontColor(AppColors.primary)
        .decoration({ type: TextDecorationType.Underline, color: AppColors.primary })
        .onClick(() => {
          if (node.href.length > 0) {
            this.onLinkClick(node.href)
          }
        })
    } else if (node.type === BBNodeType.EMOTION) {
      if (getEmotionResource(node.emotionCat, node.emotionCode) !== null) {
        ImageSpan(getEmotionResource(node.emotionCat, node.emotionCode))
          .width(ctx.inQuote ? 26 : 50)
          .height(ctx.inQuote ? 26 : 50)
          .objectFit(ImageFit.Contain)
          .textBackgroundStyle(this.effectiveColorMode === 'dark' &&
            isEmotionCategoryNeedDarkBg(node.emotionCat)
            ? { color: Color.White } : { color: Color.Transparent })
      } else {
        Span(`[表情:${node.emotionCat}:${node.emotionCode}]`)
          .fontSize(ctx.inQuote ? (this.contentFontSize - 3) : (this.contentFontSize - 1))
          .fontColor(AppColors.textTertiary)
      }
    } else if (node.type === BBNodeType.SUBSCRIPT) {
      this.RenderFormattedSpan(node, ctx, FontWeight.Normal, FontStyle.Normal, TextDecorationType.None, '', calcSubscriptSize(ctx.inQuote ? (this.contentFontSize - 1) : this.contentFontSize), '', calcSubscriptOffset(ctx.inQuote ? (this.contentFontSize - 1) : this.contentFontSize))
    } else if (node.type === BBNodeType.SUPERSCRIPT) {
      this.RenderFormattedSpan(node, ctx, FontWeight.Normal, FontStyle.Normal, TextDecorationType.None, '', calcSuperscriptSize(ctx.inQuote ? (this.contentFontSize - 1) : this.contentFontSize), '', calcSuperscriptOffset(ctx.inQuote ? (this.contentFontSize - 1) : this.contentFontSize))
    }
  }

  @Builder
  RenderFormattedSpan(node: BBNode, ctx: RenderContext,
    weight: FontWeight, style: FontStyle, deco: TextDecorationType,
    color: string, size: number, family: string, offset: number) {
    if (node.children.length > 0) {
      ForEach(node.children, (child: BBNode) => {
        this.RenderSpanWithFormat(child, ctx, weight, style, deco, color, size, family, offset)
      }, (child: BBNode) => child.id.toString())
    } else {
      Span(node.text)
        .fontWeight(weight)
        .fontStyle(style)
        .decoration({ type: deco })
        .fontColor(color.length > 0 ? color : (ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary))
        .fontSize(size > 0 ? size : (ctx.inQuote ? (this.contentFontSize - 1) : this.contentFontSize))
        .baselineOffset(new LengthMetrics(offset))
    }
  }

  @Builder
  RenderSpanWithFormat(child: BBNode, ctx: RenderContext,
    weight: FontWeight, style: FontStyle, deco: TextDecorationType,
    color: string, size: number, family: string, offset: number) {
    if (child.type === BBNodeType.URL || child.type === BBNodeType.PID_LINK ||
      child.type === BBNodeType.UID_LINK || child.type === BBNodeType.TID_LINK ||
      child.type === BBNodeType.MENTION) {
      Span(child.text)
        .fontWeight(weight)
        .fontStyle(style)
        .fontColor(AppColors.primary)
        .decoration({ type: TextDecorationType.Underline, color: AppColors.primary })
        .fontSize(size > 0 ? size : (ctx.inQuote ? (this.contentFontSize - 1) : this.contentFontSize))
        .baselineOffset(new LengthMetrics(offset))
        .onClick(() => {
          if (child.href.length > 0) {
            this.onLinkClick(child.href)
          }
        })
    } else if (child.type === BBNodeType.EMOTION) {
      if (getEmotionResource(child.emotionCat, child.emotionCode) !== null) {
        ImageSpan(getEmotionResource(child.emotionCat, child.emotionCode))
          .width(ctx.inQuote ? 26 : 50)
          .height(ctx.inQuote ? 26 : 50)
          .objectFit(ImageFit.Contain)
          .textBackgroundStyle(this.effectiveColorMode === 'dark' &&
            isEmotionCategoryNeedDarkBg(child.emotionCat)
            ? { color: Color.White } : { color: Color.Transparent })
      } else {
        Span(`[表情:${child.emotionCat}:${child.emotionCode}]`)
          .fontSize(ctx.inQuote ? (this.contentFontSize - 3) : (this.contentFontSize - 1))
          .fontColor(AppColors.textTertiary)
      }
    } else if (child.type === BBNodeType.BOLD) {
      Span(child.text)
        .fontWeight(FontWeight.Bold)
        .fontStyle(style)
        .decoration({ type: deco })
        .fontColor(color.length > 0 ? color : (ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary))
        .fontSize(size > 0 ? size : (ctx.inQuote ? (this.contentFontSize - 1) : this.contentFontSize))
        .baselineOffset(new LengthMetrics(offset))
    } else if (child.type === BBNodeType.SUBSCRIPT) {
      Span(child.text)
        .fontSize(calcSubscriptSize(size > 0 ? size : (ctx.inQuote ? (this.contentFontSize - 1) : this.contentFontSize)))
        .baselineOffset(new LengthMetrics(calcSubscriptOffset(size > 0 ? size : (ctx.inQuote ? (this.contentFontSize - 1) : this.contentFontSize))))
        .fontWeight(weight)
        .fontColor(color.length > 0 ? color : (ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary))
    } else if (child.type === BBNodeType.SUPERSCRIPT) {
      Span(child.text)
        .fontSize(calcSuperscriptSize(size > 0 ? size : (ctx.inQuote ? (this.contentFontSize - 1) : this.contentFontSize)))
        .baselineOffset(new LengthMetrics(calcSuperscriptOffset(size > 0 ? size : (ctx.inQuote ? (this.contentFontSize - 1) : this.contentFontSize))))
        .fontWeight(weight)
        .fontColor(color.length > 0 ? color : (ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary))
    } else {
      Span(child.text)
        .fontWeight(weight)
        .fontStyle(style)
        .decoration({ type: deco })
        .fontColor(color.length > 0 ? color : (ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary))
        .fontSize(size > 0 ? size : (ctx.inQuote ? (this.contentFontSize - 1) : this.contentFontSize))
        .baselineOffset(new LengthMetrics(offset))
    }
  }

  @Builder
  RenderBlockNode(node: BBNode, ctx: RenderContext) {
    if (node.type === BBNodeType.IMAGE) {
      this.RenderImage(node, ctx)
    } else if (node.type === BBNodeType.QUOTE) {
      this.RenderQuote(node, ctx)
    } else if (node.type === BBNodeType.COLLAPSE) {
      this.RenderCollapse(node, ctx)
    } else if (node.type === BBNodeType.CODE) {
      this.RenderCode(node, ctx)
    } else if (node.type === BBNodeType.LIST) {
      this.RenderList(node, ctx)
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
      this.RenderWarn(node, ctx)
    } else if (node.type === BBNodeType.ALBUM) {
      this.RenderAlbum(node, ctx)
    } else if (node.type === BBNodeType.FLOAT_LEFT) {
      this.RenderFloat(node, FlexAlign.Start, ctx)
    } else if (node.type === BBNodeType.FLOAT_RIGHT) {
      this.RenderFloat(node, FlexAlign.End, ctx)
    } else if (node.type === BBNodeType.ALIGN) {
      this.RenderAlign(node, ctx)
    } else if (node.type === BBNodeType.TABLE) {
      this.RenderTable(node, ctx)
    } else if (node.type === BBNodeType.STYLE_DIV) {
      this.RenderStyleDiv(node, ctx)
    } else if (node.type === BBNodeType.POST_BY) {
      this.RenderReplyRef(node, ctx)
    }
  }

  @Builder
  RenderImage(node: BBNode, ctx: RenderContext) {
    if (node.src.length > 0 && !(this.hideFailedImages && this.failedImages.has(node.src))) {
      this.RenderImageContent(node.src, ctx.inQuote)
    }
  }

  @Builder
  RenderImageContent(src: string, inQuote: boolean) {
    if (shouldUsePassive(this.imageLoadStrategy)) {
      // 被动式：紧凑占位图
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
      // 主动式：原有加载行为
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

  @Builder
  RenderQuote(node: BBNode, ctx: RenderContext) {
    Column() {
      if (splitQuoteChildren(node.children).hasHeader) {
        this.RenderQuoteHeader(node.children[0], ctx)
        this.RenderChildren(splitQuoteChildren(node.children).body, this.makeQuoteCtx(ctx))
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

  @Builder
  RenderQuoteHeader(node: BBNode, ctx: RenderContext) {
    Row() {
      Text() {
        ForEach(node.children, (child: BBNode) => {
          this.RenderInlineSpan(child, this.makeQuoteCtx(ctx))
        }, (child: BBNode) => child.id.toString())
      }
      .fontSize(14)
      .fontColor(AppColors.textSecondary)
      .fontStyle(FontStyle.Italic)
      .lineHeight(20)
    }
    .width('100%')
    .padding({ bottom: 2 })
  }

  private makeQuoteCtx(parent: RenderContext): RenderContext {
    const c = new RenderContext()
    c.inQuote = true
    c.quoteDepth = parent.quoteDepth + 1
    return c
  }

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

  @Builder
  RenderCode(node: BBNode, ctx: RenderContext) {
    Scroll() {
      Text(node.text)
        .fontSize(13)
        .fontColor(AppColors.textPrimary)
        .fontFamily('monospace')
        .lineHeight(20)
    }
    .width('100%')
    .scrollable(ScrollDirection.Horizontal)
    .padding(10)
    .margin({ top: 6, bottom: 4 })
    .borderRadius(8)
    .backgroundColor(AppColors.bgSecondary)
    .align(Alignment.TopStart)
  }

  @Builder
  RenderList(node: BBNode, ctx: RenderContext) {
    Column() {
      ForEach(node.children, (child: BBNode) => {
        if (child.type === BBNodeType.LIST_ITEM) {
          Row() {
            Text('• ')
              .fontSize(ctx.inQuote ? (this.contentFontSize - 1) : this.contentFontSize)
              .fontColor(ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary)
            if (child.children.length > 0) {
              Column() {
                this.RenderChildren(child.children, ctx)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            } else {
              Text(child.text)
                .fontSize(ctx.inQuote ? (this.contentFontSize - 1) : this.contentFontSize)
                .fontColor(ctx.inQuote ? AppColors.textSecondary : AppColors.textPrimary)
                .layoutWeight(1)
                .lineHeight(ctx.inQuote ? 24 : 26)
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

  @Builder
  RenderWarn(node: BBNode, ctx: RenderContext) {
    Column() {
      if (node.children.length > 0) {
        this.RenderChildren(node.children, ctx)
      } else {
        Text(node.text)
          .fontSize(15)
          .fontColor(AppColors.warnText)
          .lineHeight(26)
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

  @Builder
  RenderAlign(node: BBNode, ctx: RenderContext) {
    Column() {
      this.RenderChildren(node.children, ctx)
    }
    .width('100%')
    .alignItems(node.align === 'center' ? HorizontalAlign.Center :
      node.align === 'right' ? HorizontalAlign.End : HorizontalAlign.Start)
    .margin({ top: 4, bottom: 2 })
  }

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

  @Builder
  RenderStyleDiv(node: BBNode, ctx: RenderContext) {
    Column() {
      this.RenderChildren(node.children, ctx)
    }
    .width('100%')
    .margin({ top: 4, bottom: 2 })
    .alignItems(HorizontalAlign.Start)
  }
}
