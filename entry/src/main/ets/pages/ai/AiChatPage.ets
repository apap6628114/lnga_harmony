import { ChatMessage, RequestCanceller } from '../../service/ai/ResponsesApiClient'
import {
  chatCompleteWithActiveAiStream,
  formatAiCompletionError,
  ToolCallInfo,
  AiChatResult
} from '../../service/ai/ActiveAiService'
import { MdContentView } from '../../common/components/MdContentView'
import { MdStreamingContentView } from '../../common/components/MdStreamingContentView'
import { PanelNavBar } from '../../common/components/PanelNavBar'
import { AppColors } from '../../common/constants/Constants'
import { appStore } from '../../store/AppStore'
import { PageScope } from '../../common/concurrency/PageScope'
import { UIMaterialManager } from '../../common/managers/UIMaterialManager'
import { TitleScrollEffect } from '../../common/utils/TitleScrollEffect'

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
  /** 工具调用信息（仅 assistant 角色，联网搜索时记录搜索过程） */
  toolCallInfo?: ToolCallInfo
  /** 该轮 assistant 响应的原始输出 items（含 web_search_call，多轮回传用） */
  outputItems?: Object[]

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
 * 支持预填充初始问题和连续多轮对话，可用于帖子总结和用户分析等场景。
 *
 * 路由参数：
 * - initialPrompt: string — 预填充的第一条用户消息
 * - title: string — 导航栏标题
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
  /** AI 处理阶段状态文案（联网搜索时显示不同提示） */
  @State private aiStatus: string = ''
  /** 工具调用当前阶段（空字符串=无工具调用，analyzing/searching/compiling/complete） */
  @State private toolPhase: string = ''
  /** 工具调用阶段图标（SVG 资源，按主题着色） */
  @State private toolIcon: Resource = $r('app.media.icon_ai_analyzing')
  /** 工具调用阶段描述 */
  @State private toolDescription: string = ''
  /** 搜索关键词（仅 searching/compiling/complete 阶段） */
  @State private toolSummary: string = ''
  /** 搜索结果数量 */
  @State private toolCount: number = 0
  /** 导航栏标题 */
  @State private title: string = 'AI 对话'
  /** 状态栏高度。 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
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
  /** 当前请求取消令牌（页面销毁时中断进行中的流式请求）。 */
  private requestCanceller: RequestCanceller = new RequestCanceller()

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
   *
   * 此钩子在首次 build() 完成后触发，比 aboutToAppear 中
   * 的 setTimeout(0) 更可靠，能保证布局已完整计算。
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

    const requestId: number = this.scope.begin()
    const userBubble: ChatBubble = new ChatBubble('user', text, false)
    this.bubbles.push(userBubble)
    this.inputText = ''
    this.isSending = true
    this.resetStreamingState()
    this.requestCanceller = new RequestCanceller()

    // 构建对话历史（不含正在生成的 AI 回复）
    const history: ChatMessage[] = this.buildHistory()

    // 延迟到下一帧渲染完成后滚动，避免在旧内容上滚动
    setTimeout((): void => {
      if (this.isActiveRequest(requestId)) {
        this.scrollToBottom()
      }
    }, 0)

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
	        (info: ToolCallInfo): void => {
            if (!this.isActiveRequest(requestId)) {
              return
            }
	          // 原子 @State 字段逐一赋值，确保 ArkUI 可靠检测变化
	          this.toolPhase = info.phase
	          this.toolIcon = info.phaseIcon
	          this.toolDescription = info.phaseDescription
	          this.toolSummary = info.summary
	          this.toolCount = info.count
	        },
	        this.requestCanceller
	      )
        if (!this.isActiveRequest(requestId)) {
          return
        }
	      // 流式完成 — 强制同步缓冲到状态，避免添加气泡前闪现「思考中」帧
	      this.flushStreamingText()
	      // 流式完成 — 添加完整的 AI 气泡
	      let finalText: string = result.text
	      // 部分内容被截断时追加弱提示，避免用户误以为回答已完整结束
	      if (result.truncated) {
	        finalText += '\n\n⚠️ 回答已因长度上限被截断，可增大输出上限后重试'
	      }
	      if (this.toolPhase.length > 0) {
	        const savedInfo: ToolCallInfo = new ToolCallInfo()
	        savedInfo.phase = this.toolPhase
	        savedInfo.phaseIcon = this.toolIcon
	        savedInfo.phaseDescription = this.toolDescription
	        savedInfo.summary = this.toolSummary
	        savedInfo.count = this.toolCount
	        const aiBubble: ChatBubble = new ChatBubble('assistant', finalText, false)
	        aiBubble.toolCallInfo = savedInfo
	        aiBubble.outputItems = result.outputItems.length > 0 ? result.outputItems : undefined
	        this.bubbles.push(aiBubble)
	      } else {
	        const aiBubble: ChatBubble = new ChatBubble('assistant', finalText, false)
	        aiBubble.outputItems = result.outputItems.length > 0 ? result.outputItems : undefined
	        this.bubbles.push(aiBubble)
	      }
    } catch (err) {
      if (!this.isActiveRequest(requestId)) {
        return
      }
      const e: Error = err as Error
      const errorText: string = formatAiCompletionError(e)
      const aiBubble: ChatBubble = new ChatBubble('assistant', errorText, false)
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
        // chunk 快速连续到达 → 指数衰减加速刷新，比线性加减收敛更快
        this.adaptiveFlushMs = Math.max(MIN_FLUSH_INTERVAL_MS, Math.floor(this.adaptiveFlushMs * FLUSH_DECAY_RATE))
      } else if (gap > CHUNK_SPARSE_THRESHOLD_MS) {
        // chunk 稀疏到达 → 线性增加刷新频率节省资源
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
   *
   * 流式输出期间始终强制滚到底部（用户主动生成内容，预期看到滚动）。
   * 使用高 velocity 使滚动接近瞬时完成，避免默认动画追不上内容增长。
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
    this.toolPhase = ''
    this.toolIcon = $r('app.media.icon_ai_analyzing')
    this.toolDescription = ''
    this.toolSummary = ''
    this.toolCount = 0
    this.lastChunkTimeMs = 0
    this.adaptiveFlushMs = DEFAULT_FLUSH_INTERVAL_MS
  }

  /**
   * 从已完成的对话气泡中构建 ChatMessage 数组。
   *
   * 若有场景 system prompt，在消息数组开头插入 system role 消息。
   * assistant 消息携带该轮原始输出 items（含 web_search_call），
   * 由客户端序列化为 Responses API 输入时原样回传。
   *
   * @returns API 调用的对话历史
   */
  private buildHistory(): ChatMessage[] {
    const messages: ChatMessage[] = []
    // 前置 system prompt（用于场景任务的角色设定和输出约束）
    if (this.systemPrompt.length > 0) {
      messages.push(new ChatMessage('system', this.systemPrompt))
    }
    for (let i: number = 0; i < this.bubbles.length; i++) {
      const b: ChatBubble = this.bubbles[i]
      if (b.role === 'user') {
        messages.push(new ChatMessage('user', b.content))
      } else if (b.role === 'assistant' && !b.isStreaming && b.content.length > 0) {
        const assistantMsg: ChatMessage = new ChatMessage('assistant', b.content)
        if (b.outputItems && b.outputItems.length > 0) {
          assistantMsg.outputItems = b.outputItems
        }
        messages.push(assistantMsg)
      }
    }
    return messages
  }

  /** 滚动到底部（用于页面展示、新消息发送等需要强制滚动的场景）。 */
  private scrollToBottom(): void {
    this.scroller.scrollEdge(Edge.Bottom, { velocity: 10000 })
  }

  /**
   * 若用户当前位于底部则滚动到底部（用于流式输出过程）。
   *
   * 防止用户上翻阅读历史内容时被流式滚动干扰。
   */
  private scrollToBottomIfAtEnd(): void {
    if (this.scroller.isAtEnd()) {
      this.scroller.scrollEdge(Edge.Bottom)
    }
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
		            Row() {
		              Column() {
		                // === 工具调用指示器（纯文本沉浸式，无背景无边框） ===
		                if (this.toolPhase.length > 0) {
		                  if (this.toolPhase === 'complete') {
		                    // 完成态：很淡的一行
		                    Row() {
		                      Image($r('app.media.icon_checkmark'))
		                        .width(12).height(12)
		                        .fillColor(AppColors.textTertiary)
		                      Text(this.toolDescription)
		                        .fontSize(12)
		                        .fontColor(AppColors.textTertiary)
		                        .layoutWeight(1)
		                        .maxLines(1)
		                        .textOverflow({ overflow: TextOverflow.Ellipsis })
		                    }
		                    .width('100%')
		                    .alignItems(VerticalAlign.Center)
		                    .padding({ bottom: 6 })
		                  } else {
			                    // 活跃态：统一所有进行中状态（分析/搜索/生成），无装饰
			                    Row() {
			                      Image(this.toolIcon)
			                        .width(15).height(15)
			                        .fillColor(AppColors.primary)
			                      Text(this.streamingText.length > 0 ? '正在生成回答...' : this.toolDescription)
			                        .fontSize(14)
			                        .fontColor(AppColors.textPrimary)
			                        .layoutWeight(1)
			                        .margin({ left: 5 })
			                        .maxLines(2)
			                        .textOverflow({ overflow: TextOverflow.Ellipsis })
			                      if (this.streamingText.length === 0) {
			                        LoadingProgress()
			                          .width(14).height(14)
			                          .color(AppColors.primary)
			                          .margin({ left: 6 })
			                      }
			                    }
		                    .width('100%')
		                    .alignItems(VerticalAlign.Center)
		                    .margin({ bottom: 8 })
		                  }
		                }

		                // === 流式内容或加载状态 ===
		                if (this.streamingText.length > 0) {
		                  MdStreamingContentView({ text: this.streamingText })
		                } else if (this.toolPhase.length === 0) {
		                  Row() {
		                    LoadingProgress()
		                      .width(20).height(20)
		                      .color(AppColors.primary)
		                    if (this.aiStatus.length > 0) {
		                      Text('  ' + this.aiStatus)
		                        .fontSize(15)
		                        .fontColor(AppColors.textSecondary)
		                    } else {
		                      Text('  AI 思考中...')
		                        .fontSize(15)
		                        .fontColor(AppColors.textSecondary)
		                    }
		                  }
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
  // 气泡渲染
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
	          // 工具调用摘要（ChatGPT 风格：紧凑一行，无分隔线）
	          if (bubble.toolCallInfo) {
	            Row() {
	              Image($r('app.media.icon_globe'))
	                .width(12).height(12)
	                .fillColor(AppColors.textTertiary)
		              Text(bubble.toolCallInfo.summary.length > 0 ?
		                '"' + bubble.toolCallInfo.summary + '"' :
		                '已搜索互联网')
		                .fontSize(12)
		                .fontColor(AppColors.textTertiary)
		              if (bubble.toolCallInfo.count > 0) {
		                Text(' · ' + bubble.toolCallInfo.count.toString() + ' 条结果')
	                  .fontSize(12)
	                  .fontColor(AppColors.textTertiary)
	              }
	            }
	            .width('100%')
	            .alignItems(VerticalAlign.Center)
	            .padding({ bottom: 8 })
	          }
          MdContentView({ text: bubble.content })
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
  // 底部输入栏
  // ============================================================

  /** 渲染底部输入栏。 */
  @Builder
  RenderInputBar() {
    Row() {
      TextInput({ text: this.inputText, placeholder: '输入追问内容...' })
        .layoutWeight(1)
        .fontSize(15)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .borderRadius(20)
        .backgroundColor(Color.Transparent)
        .systemMaterial(UIMaterialManager.inputMaterial)
        .height(40)
        .padding({ left: 16, right: 16 })
        .onChange((value: string): void => {
          this.inputText = value
        })
        .onSubmit((): void => {
          this.sendMessage(this.inputText)
        })
      Button('发送')
        .fontSize(14)
        .fontColor(UIMaterialManager.adaptiveForeground)
        .backgroundColor(Color.Transparent)
        .systemMaterial(UIMaterialManager.buttonMaterial)
        .borderRadius(20)
        .height(40)
        .padding({ left: 18, right: 18 })
        .margin({ left: 8 })
        .enabled(!this.isSending && this.inputText.trim().length > 0)
        .onClick((): void => {
          this.sendMessage(this.inputText)
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(Color.Transparent)
    .border({ width: { top: 0.5 }, color: AppColors.separator })
    .alignItems(VerticalAlign.Center)
    .systemMaterial(UIMaterialManager.barMaterial)
  }
}
