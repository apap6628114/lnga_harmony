import { ChatMessage, RequestCanceller } from '../../service/ai/AiProtocolTypes'
import {
  chatCompleteWithActiveAiStream,
  formatAiCompletionError,
  getToolAvailabilityHint,
  ToolInvocationCallback,
  AiChatResult
} from '../../service/ai/ActiveAiService'
import { AiToolInvocation, AiToolSource } from '../../service/ai/tools/AiToolAdapter'
import { MdContentView } from '../../common/components/MdContentView'
import { MdStreamingContentView } from '../../common/components/MdStreamingContentView'
import { PanelNavBar } from '../../common/components/PanelNavBar'
import { AppColors } from '../../common/constants/Constants'
import { appStore } from '../../store/AppStore'
import { PageScope } from '../../common/concurrency/PageScope'
import { UIMaterialManager } from '../../common/managers/UIMaterialManager'
import { TitleScrollEffect } from '../../common/utils/TitleScrollEffect'
import { resolveKeyboardAppearance } from '../../common/utils/KeyboardAppearanceUtils'
import { openSystemLink } from '../../common/utils/LinkUtils'
import { pasteboard } from '@kit.BasicServicesKit'
import { common } from '@kit.AbilityKit'

/** 流式输出默认刷新间隔毫秒数 */
const DEFAULT_FLUSH_INTERVAL_MS: number = 80
/** 流式输出最小刷新间隔毫秒数（最快刷新频率） */
const MIN_FLUSH_INTERVAL_MS: number = 30
/** 流式输出最大刷新间隔毫秒数（最慢刷新频率） */
const MAX_FLUSH_INTERVAL_MS: number = 200
/** chunk 间隔小于此值（毫秒）视为密集到达，加速刷新。应略大于 MIN_FLUSH_INTERVAL_MS，避免临界震荡。 */
const CHUNK_BURST_THRESHOLD_MS: number = 40
/** chunk 间隔大于此值（毫秒）视为稀疏到达，减速刷新节省资源。应略小于 MAX_FLUSH_INTERVAL_MS。 */
const CHUNK_SPARSE_THRESHOLD_MS: number = 180
/** 密集到达时刷新间隔的衰减系数（×0.7 ≈ 每步缩短 30%）。指数衰减比线性加减收敛更快。 */
const FLUSH_DECAY_RATE: number = 0.7
/** 稀疏到达时刷新间隔的增量（毫秒）。线性回升，避免极端情况下间隔过小。 */
const FLUSH_IDLE_INCREASE: number = 20
/** 气泡内最多展示的引用来源条数。 */
const MAX_VISIBLE_SOURCES: number = 4

/**
 * 聊天气泡。
 *
 * 每条气泡代表对话中的一轮发言。isStreaming 为 true 时
 * 表示 AI 仍在生成中，UI 应显示加载动画。
 */
class ChatBubble {
  /** 唯一标识，用于 ForEach key 生成。一旦赋值不会改变。 */
  readonly id: string
  /** 发言角色 */
  role: string = 'user'
  /** 消息内容（用户为纯文本，AI 为 Markdown） */
  content: string = ''
  /** AI 是否仍在流式生成中 */
  isStreaming: boolean = false
  /** 本轮工具调用时间线 */
  toolInvocations: AiToolInvocation[] = []
  /** 本轮引用来源 */
  sources: AiToolSource[] = []
  /** 是否被用户主动停止 */
  stopped: boolean = false
  /** 是否调用失败（可重试） */
  failed: boolean = false
  /**
   * 是否为本机生成的提示文案（错误说明、空回答兜底等）。
   *
   * 这类内容不属于模型回复，不能作为 assistant 历史回传给下一轮。
   */
  localOnly: boolean = false

  constructor(role: string, content: string, isStreaming: boolean) {
    this.id = 'cb_' + Date.now() + '_' + Math.floor(Math.random() * 100000)
    this.role = role
    this.content = content
    this.isStreaming = isStreaming
  }
}

/**
 * AI 对话页 — ChatGPT 式流式聊天界面。
 *
 * 支持预填充初始问题、连续多轮对话、工具调用时间线、停止生成、
 * 重新生成与复制回答。
 *
 * 路由参数：
 * - initialPrompt: string — 预填充的第一条用户消息
 * - title: string — 导航栏标题
 * - scenario: string — 场景标识（注入对应 system prompt）
 */
@Entry
@Component
struct AiChatPage {
  /** 对话气泡列表 */
  @State private bubbles: ChatBubble[] = []
  /** 输入框文本 */
  @State private inputText: string = ''
  /** 是否正在等待 AI 响应 */
  @State private isSending: boolean = false
  /** AI 流式输出当前累积文本（渲染用） */
  @State private streamingText: string = ''
  /** AI 处理阶段状态文案 */
  @State private aiStatus: string = ''
  /** 当前轮工具调用时间线 */
  @State private toolInvocations: AiToolInvocation[] = []
  /** 导航栏标题 */
  @State private title: string = 'AI 对话'
  /** 状态栏高度。 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /**
   * 当前生效明暗色模式。
   *
   * 底部追问输入框的键盘沉浸样式必须按**应用主题**（而非系统模式）取色，
   * 否则固定主题与系统模式相反时键盘配色错配（见 `KeyboardAppearanceUtils` 文件头）。
   */
  @StorageProp('effectiveColorMode') effectiveColorMode: string = 'light'
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State private titleScrollEffectProgress: number = 0
  /** 滚动容器当前视口高度。 */
  @State private scrollViewportHeight: number = 1
  /** 初始 prompt */
  private initialPrompt: string = ''
  /** AI 场景标识（空字符串表示自由聊天，不注入 system prompt） */
  private scenario: string = ''
  /** 当前场景的 system prompt 文本 */
  private systemPrompt: string = ''
  /** 流式输出完整缓冲，普通字段更新不会触发 ArkUI 重建。 */
  private streamBuffer: string = ''
  /** 流式输出刷新定时器句柄。 */
  private streamFlushTimer: number = -1
  /** 流式输出滚动定时器句柄。 */
  private streamScrollTimer: number = -1
  /** 上一次收到 chunk 的时间戳（毫秒），用于自适应频率调整。 */
  private lastChunkTimeMs: number = 0
  /** 当前自适应刷新间隔。 */
  private adaptiveFlushMs: number = DEFAULT_FLUSH_INTERVAL_MS
  /** 页面出现会话作用域，驱动异步回调的存活与代际校验。 */
  private scope: PageScope = new PageScope()
  /** 当前请求取消令牌（停止生成 / 页面销毁时中断请求）。 */
  private requestCanceller: RequestCanceller = new RequestCanceller()
  /** 用户是否主动点了「停止」。 */
  private userStopped: boolean = false

  /** 滚动控制器 */
  private scroller: Scroller = new Scroller()

  /** 按滚动容器绝对偏移同步标题栏视觉效果。 */
  private syncTitleScrollEffect(): void {
    const progress: number = TitleScrollEffect.getProgress(
      this.scroller.currentOffset().yOffset,
      this.statusBarHeight
    )
    if (TitleScrollEffect.shouldUpdateProgress(this.titleScrollEffectProgress, progress)) {
      this.titleScrollEffectProgress = progress
    }
  }

  aboutToAppear(): void {
    this.scope.begin()
    const params: Record<string, Object> = this.getUIContext().getRouter().getParams() as Record<string, Object>
    if (params) {
      const prompt: string = (params['initialPrompt'] as string) ?? ''
      const t: string = (params['title'] as string) ?? ''
      const s: string = (params['scenario'] as string) ?? ''
      this.initialPrompt = prompt
      this.scenario = s
      if (t.length > 0) {
        this.title = t
      }
      // 获取场景 system prompt（有 scenario 时生效，自由聊天时不注入）
      if (this.scenario.length > 0) {
        this.systemPrompt = appStore.settingsStore.getScenarioPrompt(this.scenario)
      }
    }
    if (this.initialPrompt.length > 0) {
      this.sendMessage(this.initialPrompt)
    }
    const toolHint: string = getToolAvailabilityHint()
    if (toolHint.length > 0) {
      appStore.showToast(toolHint)
    }
  }

  aboutToDisappear(): void {
    this.scope.end()
    // 中断仍在进行中的 AI 流式请求，避免网络与解析资源空耗
    this.requestCanceller.cancel()
    this.isSending = false
    this.resetStreamingState()
  }

  /**
   * 页面构建完成且可见时触发，确保聊天内容滚动到底部。
   */
  onPageShow(): void {
    this.scrollToBottom()
  }

  /**
   * 发送一条用户消息并获取 AI 回复。
   *
   * @param text - 用户输入的文本
   */
  private async sendMessage(text: string): Promise<void> {
    if (text.trim().length === 0 || this.isSending) {
      return
    }
    const userBubble: ChatBubble = new ChatBubble('user', text, false)
    this.bubbles.push(userBubble)
    this.inputText = ''
    await this.requestAnswer()
  }

  /**
   * 重新生成：移除尾部 AI 气泡后，用同一段历史重新请求。
   */
  private async regenerate(): Promise<void> {
    if (this.isSending) {
      return
    }
    if (this.bubbles.length === 0) {
      return
    }
    const lastIndex: number = this.bubbles.length - 1
    if (this.bubbles[lastIndex].role !== 'assistant') {
      return
    }
    // 只移除最后一条 AI 气泡：按钮只在最后一条显示，避免误删历史
    this.bubbles.pop()
    await this.requestAnswer()
  }

  /**
   * 发起一次 AI 请求（调用方负责维护 bubbles 中的用户消息）。
   */
  private async requestAnswer(): Promise<void> {
    if (this.isSending) {
      return
    }
    const requestId: number = this.scope.begin()
    this.isSending = true
    this.userStopped = false
    this.resetStreamingState()
    this.requestCanceller = new RequestCanceller()

    const history: ChatMessage[] = this.buildHistory()

    // 延迟到下一帧渲染完成后滚动，避免在旧内容上滚动
    setTimeout((): void => {
      if (this.isActiveRequest(requestId)) {
        this.scrollToBottom()
      }
    }, 0)

    const toolCallback: ToolInvocationCallback = (invocations: AiToolInvocation[]): void => {
      if (!this.isActiveRequest(requestId)) {
        return
      }
      this.toolInvocations = invocations
    }

    try {
      const result: AiChatResult = await chatCompleteWithActiveAiStream(
        history,
        (chunk: string): void => {
          if (!this.isActiveRequest(requestId)) {
            return
          }
          this.appendStreamingChunk(chunk)
        },
        (status: string): void => {
          if (!this.isActiveRequest(requestId)) {
            return
          }
          this.aiStatus = status
        },
        toolCallback,
        this.requestCanceller
      )
      if (!this.isActiveRequest(requestId)) {
        return
      }
      // 流式完成 — 强制同步缓冲到状态，避免添加气泡前闪现「思考中」帧
      this.flushStreamingText()
      let finalText: string = result.text
      // 部分内容被截断时追加弱提示，避免用户误以为回答已完整结束
      if (result.truncated) {
        finalText += '\n\n⚠️ 回答已达模型输出上限被截断，可精简对话上下文或更换支持更长输出的模型后重试'
      }
      if (result.hitStepLimit) {
        finalText += '\n\n⚠️ 已达到工具调用轮数上限并强制收尾，可提高「Agent 轮数」或拆分问题后重试'
      }
      const aiBubble: ChatBubble = new ChatBubble('assistant', finalText, false)
      aiBubble.toolInvocations = result.toolInvocations
      aiBubble.sources = result.sources
      aiBubble.localOnly = result.localFallback
      this.bubbles.push(aiBubble)
    } catch (err) {
      if (!this.isActiveRequest(requestId)) {
        return
      }
      if (this.userStopped) {
        // 用户主动停止：用完整缓冲而非已刷新快照，避免丢掉最后 30-200ms 的增量
        const partial: string = this.streamBuffer.trim()
        const stoppedBubble: ChatBubble = new ChatBubble(
          'assistant', partial.length > 0 ? partial : '已停止生成', false)
        stoppedBubble.stopped = true
        stoppedBubble.toolInvocations = this.toolInvocations
        this.bubbles.push(stoppedBubble)
        return
      }
      const e: Error = err as Error
      const errorText: string = formatAiCompletionError(e)
      const aiBubble: ChatBubble = new ChatBubble('assistant', errorText, false)
      aiBubble.failed = true
      aiBubble.localOnly = true
      this.bubbles.push(aiBubble)
    } finally {
      if (this.isActiveRequest(requestId)) {
        this.resetStreamingState()
        this.isSending = false
        setTimeout((): void => {
          if (this.isActiveRequest(requestId)) {
            this.scrollToBottom()
          }
        }, 0)
      }
    }
  }

  /**
   * 停止当前生成。
   */
  private stopGenerating(): void {
    if (!this.isSending) {
      return
    }
    this.userStopped = true
    this.requestCanceller.cancel()
  }

  /**
   * 判断指定请求是否仍允许更新页面状态。
   *
   * @param requestId - 会话代际
   * @returns true 表示请求仍有效
   */
  private isActiveRequest(requestId: number): boolean {
    return this.scope.isActive(requestId)
  }

  /**
   * 追加 AI 流式文本增量并安排一次自适应低频 UI 刷新。
   *
   * @param chunk - 本次收到的文本增量
   */
  private appendStreamingChunk(chunk: string): void {
    if (chunk.length === 0) {
      return
    }
    this.streamBuffer += chunk

    // 自适应调整刷新间隔：chunk 密集到达时缩短间隔以提升流畅度
    const now: number = Date.now()
    if (this.lastChunkTimeMs > 0) {
      const gap: number = now - this.lastChunkTimeMs
      if (gap < CHUNK_BURST_THRESHOLD_MS) {
        this.adaptiveFlushMs = Math.max(MIN_FLUSH_INTERVAL_MS, Math.floor(this.adaptiveFlushMs * FLUSH_DECAY_RATE))
      } else if (gap > CHUNK_SPARSE_THRESHOLD_MS) {
        this.adaptiveFlushMs = Math.min(MAX_FLUSH_INTERVAL_MS, this.adaptiveFlushMs + FLUSH_IDLE_INCREASE)
      }
    }
    this.lastChunkTimeMs = now

    this.scheduleStreamingFlush()
  }

  /**
   * 安排流式文本刷新，避免每个网络 chunk 都触发 ArkUI 重建。
   */
  private scheduleStreamingFlush(): void {
    if (this.streamFlushTimer >= 0) {
      return
    }
    this.streamFlushTimer = setTimeout((): void => {
      this.streamFlushTimer = -1
      if (!this.scope.isAlive()) {
        return
      }
      this.flushStreamingText()
    }, this.adaptiveFlushMs)
  }

  /**
   * 将普通字段缓冲同步到响应式状态。
   */
  private flushStreamingText(): void {
    if (this.streamingText === this.streamBuffer) {
      return
    }
    this.streamingText = this.streamBuffer
    this.scheduleStreamingScroll()
  }

  /**
   * 清理尚未执行的流式刷新定时器。
   */
  private clearStreamingFlushTimer(): void {
    if (this.streamFlushTimer < 0) {
      return
    }
    clearTimeout(this.streamFlushTimer)
    this.streamFlushTimer = -1
  }

  /**
   * 安排一次流式输出滚动，合并同一帧内的重复滚动请求。
   */
  private scheduleStreamingScroll(): void {
    if (this.streamScrollTimer >= 0) {
      return
    }
    this.streamScrollTimer = setTimeout((): void => {
      this.streamScrollTimer = -1
      if (!this.scope.isAlive()) {
        return
      }
      this.scrollToBottom()
    }, 0)
  }

  /**
   * 清理尚未执行的流式滚动定时器。
   */
  private clearStreamingScrollTimer(): void {
    if (this.streamScrollTimer < 0) {
      return
    }
    clearTimeout(this.streamScrollTimer)
    this.streamScrollTimer = -1
  }

  /**
   * 重置流式输出状态与缓冲。
   */
  private resetStreamingState(): void {
    this.clearStreamingFlushTimer()
    this.clearStreamingScrollTimer()
    this.streamBuffer = ''
    this.streamingText = ''
    this.aiStatus = ''
    this.toolInvocations = []
    this.lastChunkTimeMs = 0
    this.adaptiveFlushMs = DEFAULT_FLUSH_INTERVAL_MS
  }

  /**
   * 从已完成的对话气泡中构建 ChatMessage 数组。
   *
   * 若有场景 system prompt，在消息数组开头插入 system role 消息。
   *
   * @returns API 调用的对话历史
   */
  private buildHistory(): ChatMessage[] {
    const messages: ChatMessage[] = []
    if (this.systemPrompt.length > 0) {
      messages.push(new ChatMessage('system', this.systemPrompt))
    }
    for (let i: number = 0; i < this.bubbles.length; i++) {
      const b: ChatBubble = this.bubbles[i]
      if (b.role === 'user') {
        messages.push(new ChatMessage('user', b.content))
      } else if (b.role === 'assistant' && !b.isStreaming && b.content.length > 0 &&
        !b.failed && !b.stopped && !b.localOnly) {
        messages.push(new ChatMessage('assistant', b.content))
      }
    }
    return messages
  }

  /** 滚动到底部（用于页面展示、新消息发送等需要强制滚动的场景）。 */
  private scrollToBottom(): void {
    this.scroller.scrollEdge(Edge.Bottom, { velocity: 10000 })
  }

  /**
   * 复制文本到剪贴板。
   *
   * @param text - 待复制文本
   */
  private copyText(text: string): void {
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
      pasteboard.getSystemPasteboard().setData(data).then((): void => {
        appStore.showToast('已复制')
      }).catch((): void => {
        appStore.showToast('复制失败')
      })
    } catch (e) {
      appStore.showToast('复制失败')
    }
  }

  /**
   * 用系统浏览器打开外部链接。
   *
   * @param href - 链接地址
   */
  private openExternalLink(href: string): void {
    if (href.length === 0) {
      return
    }
    const hostContext: Context | undefined = this.getUIContext().getHostContext()
    if (hostContext !== undefined) {
      openSystemLink(href, hostContext as common.UIAbilityContext)
    }
  }

  /**
   * 判断某条气泡是否需要展示「重试」。
   *
   * @param bubble - 气泡
   * @returns true 表示可重试
   */
  private canRetry(bubble: ChatBubble): boolean {
    if (this.isSending) {
      return false
    }
    if (bubble.role !== 'assistant') {
      return false
    }
    // 只有最后一条 AI 气泡可以重试：regenerate 只弹出尾部气泡，
    // 中段气泡显示「重新生成」会与点击后的实际行为不一致。
    const lastIndex: number = this.bubbles.length - 1
    return lastIndex >= 0 && this.bubbles[lastIndex].id === bubble.id
  }

  build() {
    Stack() {
      Column() {
        Scroll(this.scroller) {
          Column() {
            ForEach(this.bubbles, (bubble: ChatBubble) => {
              this.RenderBubble(bubble)
            }, (bubble: ChatBubble) => bubble.id)

            if (this.isSending) {
              this.RenderStreamingBubble()
            }
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)
        .align(Alignment.TopStart)
        .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
        .linearGradientBlur(
          TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),
          {
            fractionStops: TitleScrollEffect.getBlurStops(this.scrollViewportHeight, this.statusBarHeight),
            direction: GradientDirection.Bottom
          }
        )
        .onAreaChange((oldValue: Area, newValue: Area): void => {
          if (typeof newValue.height === 'number' && newValue.height !== this.scrollViewportHeight) {
            this.scrollViewportHeight = newValue.height
          }
        })
        .onDidScroll((): void => {
          this.syncTitleScrollEffect()
        })
        .onAppear((): void => {
          this.syncTitleScrollEffect()
        })

        this.RenderInputBar()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(AppColors.bg)

      PanelNavBar({
        title: this.title,
        showBack: true,
        scrollEffectProgress: this.titleScrollEffectProgress,
        onBack: (): void => { this.getUIContext().getRouter().back() }
      })
        .width('100%')
        .position({ x: 0, y: 0 })
    }
    .width('100%')
    .height('100%')
  }

  // ============================================================
  // 流式气泡（含工具时间线）
  // ============================================================

  /** 渲染正在生成的 AI 气泡。 */
  @Builder
  RenderStreamingBubble() {
    Row() {
      Column() {
        // === 工具调用时间线 ===
        if (this.toolInvocations.length > 0) {
          ForEach(this.toolInvocations, (invocation: AiToolInvocation) => {
            Row() {
              Image(this.toolIcon(invocation))
                .width(13).height(13)
                .fillColor(invocation.status === 'failed' ? AppColors.destructive :
                  (invocation.status === 'running' ? AppColors.primary : AppColors.textTertiary))
              Text(invocation.displayName)
                .fontSize(12)
                .fontColor(AppColors.textSecondary)
                .margin({ left: 6 })
              Text(this.toolSummaryText(invocation))
                .fontSize(12)
                .fontColor(AppColors.textTertiary)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ left: 6 })
              if (invocation.status === 'running') {
                LoadingProgress()
                  .width(12).height(12)
                  .color(AppColors.primary)
                  .margin({ left: 4 })
              } else if (invocation.status === 'failed') {
                Text('失败')
                  .fontSize(11)
                  .fontColor(AppColors.destructive)
                  .margin({ left: 4 })
              } else if (invocation.count > 0) {
                Text(invocation.count.toString() + ' 条')
                  .fontSize(11)
                  .fontColor(AppColors.textTertiary)
                  .margin({ left: 4 })
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ bottom: 5 })
          }, (invocation: AiToolInvocation): string => invocation.id + '_' + invocation.status)
        }

        // === 状态提示（无正文且无工具时显示） ===
        if (this.streamingText.length === 0 && this.toolInvocations.length === 0) {
          Row() {
            LoadingProgress()
              .width(20).height(20)
              .color(AppColors.primary)
            Text('  ' + (this.aiStatus.length > 0 ? this.aiStatus : 'AI 思考中...'))
              .fontSize(15)
              .fontColor(AppColors.textSecondary)
          }
        } else if (this.streamingText.length === 0) {
          Row() {
            LoadingProgress()
              .width(14).height(14)
              .color(AppColors.primary)
            Text('  ' + (this.aiStatus.length > 0 ? this.aiStatus : '正在生成回答...'))
              .fontSize(13)
              .fontColor(AppColors.textSecondary)
          }
          .margin({ top: 2 })
        }

        // === 流式正文 ===
        if (this.streamingText.length > 0) {
          MdStreamingContentView({
            text: this.streamingText,
            onLinkClick: (href: string): void => { this.openExternalLink(href) }
          })
            .margin({ top: this.toolInvocations.length > 0 ? 6 : 0 })
        }
      }
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor(AppColors.bgSecondary)
      .borderRadius({ topLeft: 4, topRight: 14, bottomLeft: 14, bottomRight: 14 })
      .width('100%')
      .constraintSize({ maxWidth: '85%' })
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
    .margin({ top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Top)
  }

  // ============================================================
  // 已完成气泡
  // ============================================================

  /** 渲染单条已完成的聊天气泡。 */
  @Builder
  RenderBubble(bubble: ChatBubble) {
    Row() {
      if (bubble.role === 'user') {
        // 用户气泡：紧凑包裹文字，右对齐
        Column() {
          Text(bubble.content)
            .fontSize(15)
            .fontColor(AppColors.white)
            .lineHeight(24)
        }
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .backgroundColor(AppColors.primary)
        .borderRadius({ topLeft: 14, topRight: 4, bottomLeft: 14, bottomRight: 14 })
        .constraintSize({ maxWidth: '80%' })
      } else {
        // AI 气泡：撑满宽度（给 MdContentView 确定宽度上下文），左对齐
        Column() {
          // 工具调用时间线（完整轮次）
          if (bubble.toolInvocations.length > 0) {
            ForEach(bubble.toolInvocations, (invocation: AiToolInvocation) => {
              Row() {
                Image(this.toolIcon(invocation))
                  .width(12).height(12)
                  .fillColor(invocation.status === 'failed' ? AppColors.destructive : AppColors.textTertiary)
                Text(invocation.displayName)
                  .fontSize(12)
                  .fontColor(AppColors.textTertiary)
                  .margin({ left: 6 })
                Text(this.toolSummaryText(invocation))
                  .fontSize(12)
                  .fontColor(AppColors.textTertiary)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ left: 6 })
                if (invocation.status === 'failed') {
                  Text('失败')
                    .fontSize(11)
                    .fontColor(AppColors.destructive)
                } else if (invocation.count > 0) {
                  Text(invocation.count.toString() + ' 条')
                    .fontSize(11)
                    .fontColor(AppColors.textTertiary)
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .margin({ bottom: 5 })
            }, (invocation: AiToolInvocation): string => invocation.id + '_' + invocation.status)
          }

          MdContentView({
            text: bubble.content,
            onLinkClick: (href: string): void => { this.openExternalLink(href) }
          })

          // 引用来源
          if (bubble.sources.length > 0) {
            Column() {
              Text('参考来源')
                .fontSize(11)
                .fontColor(AppColors.textTertiary)
                .width('100%')
                .margin({ bottom: 3 })

              ForEach(bubble.sources.slice(0, MAX_VISIBLE_SOURCES), (source: AiToolSource, index: number) => {
                Text((index + 1).toString() + '. ' + (source.title.length > 0 ? source.title : source.url))
                  .fontSize(11)
                  .fontColor(AppColors.primary)
                  .width('100%')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ bottom: 3 })
                  .onClick((): void => {
                    this.openExternalLink(source.url)
                  })
              }, (source: AiToolSource): string => source.url)
            }
            .width('100%')
            .margin({ top: 8 })
            .padding({ top: 6 })
            .border({
              width: { top: 0.5 },
              color: { top: AppColors.separator },
              style: { top: BorderStyle.Solid }
            })
          }

          // 气泡操作行
          Row() {
            if (bubble.stopped) {
              Text('已停止')
                .fontSize(11)
                .fontColor(AppColors.textTertiary)
            }
            Blank()
            if (this.canRetry(bubble) && bubble.content.length > 0) {
              Text('↻ 重新生成')
                .fontSize(11)
                .fontColor(AppColors.textTertiary)
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .onClick((): void => {
                  this.regenerate()
                })
            }
            Text('复制')
              .fontSize(11)
              .fontColor(AppColors.textTertiary)
              .padding({ left: 8, right: 4, top: 4, bottom: 4 })
              .onClick((): void => {
                this.copyText(bubble.content)
              })
          }
          .width('100%')
          .margin({ top: 6 })
          .alignItems(VerticalAlign.Center)
        }
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .backgroundColor(AppColors.bgSecondary)
        .borderRadius({ topLeft: 4, topRight: 14, bottomLeft: 14, bottomRight: 14 })
        .width('100%')
        .constraintSize({ maxWidth: '85%' })
      }
    }
    .width('100%')
    .justifyContent(bubble.role === 'user' ? FlexAlign.End : FlexAlign.Start)
    .margin({ top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Top)
  }

  // ============================================================
  // 工具展示辅助
  // ============================================================

  /**
   * 工具调用图标。
   *
   * @param invocation - 工具调用记录
   * @returns 图标资源
   */
  private toolIcon(invocation: AiToolInvocation): Resource {
    if (invocation.name === 'web_fetch') {
      return $r('app.media.icon_link')
    }
    if (invocation.name === 'web_search') {
      return $r('app.media.icon_search')
    }
    return $r('app.media.icon_ai_analyzing')
  }

  /**
   * 工具调用摘要文案（参数可能是 JSON，截断展示）。
   *
   * @param invocation - 工具调用记录
   * @returns 摘要
   */
  private toolSummaryText(invocation: AiToolInvocation): string {
    let summary: string = invocation.summary.trim()
    if (summary.startsWith('{')) {
      summary = this.extractArgumentPreview(summary)
    }
    if (summary.length > 60) {
      return summary.substring(0, 60) + '…'
    }
    return summary
  }

  /**
   * 从 JSON 参数里提取 query / url 作为展示文案。
   *
   * @param argumentsText - 参数 JSON
   * @returns 展示文案
   */
  private extractArgumentPreview(argumentsText: string): string {
    try {
      const parsed: Record<string, Object> = JSON.parse(argumentsText) as Record<string, Object>
      const query: Object | undefined = parsed['query']
      if (typeof query === 'string') {
        return query as string
      }
      const url: Object | undefined = parsed['url']
      if (typeof url === 'string') {
        return url as string
      }
    } catch (e) {
      return argumentsText
    }
    return argumentsText
  }

  // ============================================================
  // 底部输入栏
  // ============================================================

  /** 渲染底部输入栏。 */
  @Builder
  RenderInputBar() {
    Column() {
      Row() {
        TextInput({ text: this.inputText, placeholder: this.isSending ? '正在生成，可点停止…' : '输入追问…' })
          .layoutWeight(1)
          .fontSize(15)
          .fontColor(UIMaterialManager.inputForeground)
          .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
          .caretColor(UIMaterialManager.inputForeground)
          .height(44)
          .padding({ left: 16, right: 16 })
          .borderRadius(22)
          .attributeModifier(UIMaterialManager.inputMaterial)
          .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
          .enterKeyType(EnterKeyType.Send)
          .enabled(!this.isSending)
          .onChange((value: string): void => {
            this.inputText = value
          })
          .onSubmit((): void => {
            this.sendMessage(this.inputText)
          })

        if (this.isSending) {
          Button('停止')
            .type(ButtonType.Capsule)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColors.white)
            .backgroundColor(AppColors.destructive)
            .height(44)
            .constraintSize({ minWidth: 76 })
            .padding({ left: 16, right: 16 })
            .margin({ left: 8 })
            .onClick((): void => {
              this.stopGenerating()
            })
        } else {
          Button('发送')
            .type(ButtonType.Capsule)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColors.white)
            .backgroundColor(AppColors.primary)
            .height(44)
            .constraintSize({ minWidth: 76 })
            .padding({ left: 16, right: 16 })
            .margin({ left: 8 })
            .enabled(this.inputText.trim().length > 0)
            .onClick((): void => {
              this.sendMessage(this.inputText)
            })
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: 720 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(Color.Transparent)
    .alignItems(HorizontalAlign.Center)
  }
}
