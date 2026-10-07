/**
 * 「智能去水」确认对话框内容构件。
 *
 * 与 `SaveThreadContent` 同样的定位：标题与按钮由官方 `CustomContentDialog` 模板
 * 渲染，本组件只负责「展示将要发生什么 + 让用户确认严格等级与规则」。必读信息：
 * 1. **要抓多少页**（全帖不限页数，长帖耗时可能很久——用户点之前必须知道）；
 * 2. **预计耗时**（按每页平均耗时估算，明确说「估算」）；
 * 3. **当前严格等级与生效的自定义规则条数**（改了等级/规则会影响结果）；
 * 4. **去水版会存到哪**（用户点完「开始」就离开对话框了，不提前说就找不到产出物）；
 * 5. **AI 规则是否已生成**（按本帖主题生成的规则，只对本次生效）。
 *
 * 参数一律用 `@Prop` + 回调，**禁止 `@Link`**：官方 `contentBuilder` 是
 * `@BuilderParam`，其中的 `$变量` 在对话框组件那一层解析不到源状态，会抛
 * `source variable in parent/ancestor @Component must be defined`（见
 * `SaveThreadDialogs.ets` 头部说明）。
 *
 * 等级选择**直接写回设置**（`setWaterFilterLevel`），不在对话框里另存一份：
 * 等级是全局偏好，若对话框内自己持有一份、点「开始」才写回，用户在这里改了
 * 等级却没点开始就会以为已经生效。
 *
 * AI 规则相反，**只用于本次任务**：它是按这一帖的主题生成的，写进全局自定义规则
 * 会在别的帖子上乱删。因此用 `onAiStateChange` 回传给发起方，而不是落盘。
 */

import { appStore } from '../../store/AppStore'
import { AppColors } from '../constants/Constants'
import { UIMaterialManager } from '../managers/UIMaterialManager'
import { estimateWaterFilterMs, formatDuration } from '../../service/ThreadWaterFilterService'
import {
  generateWaterRules,
  WaterFilterAiRulesResult
} from '../../service/WaterFilterAiRulesService'
import { getActiveAiValidationMessage } from '../../service/ai/ActiveAiService'
import { RequestCanceller } from '../../service/ai/AiChatTypes'
import {
  WaterFilterLevel,
  WaterFilterRule,
  clampWaterLevel,
  waterLevelDescription,
  waterLevelLabel,
  waterRuleTypeDetail
} from '../../model/WaterFilterRule'

/** 出处提示：产出物落在哪一层列表里（用户点完就开始抓，不说就找不到）。 */
const SAVE_LOCATION_HINT: string =
  '去水版会存到「我的 → 收藏、保存与跟踪帖子 → 保存的帖子」，与原帖的「离线保存」并排；不联网也能读。'

@Component
export struct WaterFilterContent {
  /** 主题标题。 */
  @Prop subject: string = ''
  /**
   * 调用方已知的总页数。
   *
   * 仅用于「预计耗时」与页数提示：真实抓取范围由服务在开始时请求末页自行探测
   * （只看楼主等筛选态下调用方手里的页数不是整帖页数）。
   */
  @Prop totalPages: number = 0
  /** 主楼正文纯文本（供 AI 推断帖子类型；为空时 AI 只看标题）。 */
  @Prop opText: string = ''
  /** 打开「去水规则」设置页（调用方负责关闭本对话框再跳转）。 */
  onOpenRules?: () => void
  /**
   * AI 规则状态变化回调（回传给发起方，供本次任务使用）。
   *
   * 同时上报 `generating`：生成过程中用户点「开始」必须被拦住，否则会在
   * 规则还没拿到时就开始抓取——用户以为用了 AI 规则，实际一条都没用上。
   */
  onAiStateChange?: (rules: WaterFilterRule[], generating: boolean) => void

  /** 当前严格等级（进入时从设置读取，改动即时写回设置）。 */
  @State private level: number = WaterFilterLevel.BASIC
  /** 生效中的自定义规则条数。 */
  @State private enabledRules: number = 0
  /** 是否正在向 AI 请求规则。 */
  @State private aiGenerating: boolean = false
  /** AI 本次生成的规则（只用于本次任务）。 */
  @State private aiRules: WaterFilterRule[] = []
  /** AI 区块的说明/错误文案。 */
  @State private aiMessage: string = ''
  /** AI 区块文案是否为错误态。 */
  @State private aiFailed: boolean = false
  /** AI 配置不可用时的提示（空串表示可用）。 */
  @State private aiGateMessage: string = ''

  /** 在途 AI 请求的取消令牌。 */
  private aiCanceller: RequestCanceller | null = null

  aboutToAppear(): void {
    this.level = appStore.settingsStore.getWaterFilterLevel()
    this.enabledRules = appStore.settingsStore.countEnabledWaterRules()
    this.aiGateMessage = getActiveAiValidationMessage()
  }

  aboutToDisappear(): void {
    // 对话框关闭（取消 / 点空白 / 已点开始）时中断在途请求：不中断会留下无人接收的回调
    this.cancelAiRequest()
  }

  /** 中断在途的 AI 请求。 */
  private cancelAiRequest(): void {
    const canceller: RequestCanceller | null = this.aiCanceller
    if (canceller !== null) {
      canceller.cancel()
      this.aiCanceller = null
    }
    this.aiGenerating = false
  }

  /**
   * 切换严格等级并写回设置。
   *
   * @param value - 目标等级
   */
  private selectLevel(value: number): void {
    const next: number = clampWaterLevel(value)
    if (next === this.level) {
      return
    }
    this.level = next
    appStore.settingsStore.setWaterFilterLevel(next)
  }

  /**
   * 上报当前 AI 规则与生成状态给发起方。
   */
  private reportAiState(): void {
    if (this.onAiStateChange) {
      this.onAiStateChange(this.aiRules, this.aiGenerating)
    }
  }

  /** 发起一次 AI 规则生成。 */
  private requestAiRules(): void {
    if (this.aiGenerating) {
      return
    }
    if (this.aiGateMessage.length > 0) {
      appStore.showToast(this.aiGateMessage)
      return
    }
    this.cancelAiRequest()
    const canceller: RequestCanceller = new RequestCanceller()
    this.aiCanceller = canceller
    this.aiGenerating = true
    this.aiRules = []
    this.aiFailed = false
    this.aiMessage = 'AI 正在分析帖子主题…'
    this.reportAiState()
    generateWaterRules(this.subject, this.opText, canceller).then(
      (result: WaterFilterAiRulesResult): void => {
        if (this.aiCanceller !== canceller) {
          return
        }
        this.aiCanceller = null
        this.aiGenerating = false
        if (result.cancelled) {
          this.aiMessage = ''
          this.reportAiState()
          return
        }
        if (!result.ok) {
          this.aiFailed = true
          this.aiMessage = result.message
          this.reportAiState()
          return
        }
        this.aiRules = result.rules
        this.aiMessage = result.message
        this.reportAiState()
      }
    ).catch((error: Error): void => {
      if (this.aiCanceller !== canceller) {
        return
      }
      this.aiCanceller = null
      this.aiGenerating = false
      this.aiFailed = true
      this.aiMessage = '规则生成失败：' + error.message
      this.reportAiState()
    })
  }

  /**
   * 规则的展示文本。
   *
   * @param rule - 目标规则
   * @returns 展示文本
   */
  private ruleText(rule: WaterFilterRule): string {
    return waterRuleTypeDetail(rule.type, rule.value)
  }

  @Builder
  levelChip(value: number) {
    Column({ space: 2 }) {
      Text(waterLevelLabel(value))
        .fontSize(14)
        .fontColor(this.level === value ? AppColors.white : UIMaterialManager.adaptiveForeground)
        .fontWeight(this.level === value ? FontWeight.Medium : FontWeight.Normal)
      Text(waterLevelDescription(value))
        .fontSize(11)
        .fontColor(this.level === value
          ? AppColors.white
          : UIMaterialManager.adaptiveSecondaryForeground)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .borderRadius(10)
    .backgroundColor(this.level === value ? AppColors.primary : AppColors.bgSecondary)
    .onClick(() => {
      this.selectLevel(value)
    })
  }

  /** AI 区块：按钮 / 生成中 / 已生成列表。 */
  @Builder
  aiSection() {
    Column() {
      Row() {
        Text('AI 规则').fontSize(12).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
          .layoutWeight(1)
        if (!this.aiGenerating) {
          Row() {
            Image($r('app.media.icon_ai_water_rules'))
              .width(14).height(14)
              .fillColor(AppColors.primary)
            Text(this.aiRules.length > 0 ? '重新生成' : '按本帖主题生成')
              .fontSize(12).fontColor(AppColors.primary).margin({ left: 4 })
          }
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(15)
          .border({ width: 1, color: AppColors.primary })
          .onClick(() => {
            this.requestAiRules()
          })
        }
      }
      .width('100%').alignItems(VerticalAlign.Center)

      if (this.aiMessage.length > 0) {
        Text(this.aiMessage)
          .fontSize(11)
          .fontColor(this.aiFailed
            ? AppColors.destructive
            : UIMaterialManager.adaptiveSecondaryForeground)
          .margin({ top: 6 })
          .alignSelf(ItemAlign.Start)
      }

      if (this.aiRules.length > 0) {
        Column() {
          ForEach(this.aiRules, (rule: WaterFilterRule) => {
            Text('· ' + this.ruleText(rule))
              .fontSize(11)
              .fontColor(UIMaterialManager.adaptiveForeground)
              .width('100%')
              .padding({ top: 2 })
          }, (rule: WaterFilterRule) => rule.id)
        }
        .width('100%').margin({ top: 6 })
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .borderRadius(8)
        .backgroundColor(AppColors.bgSecondary)
        .alignItems(HorizontalAlign.Start)

        Text('AI 规则只用于本次去水，不会写入你的自定义规则。')
          .fontSize(11).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
          .margin({ top: 6 }).alignSelf(ItemAlign.Start)
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Scroll() {
      Column() {
        Text(this.subject.length > 0 ? this.subject : '（无标题）')
          .fontSize(14).fontColor(UIMaterialManager.adaptiveForeground).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .alignSelf(ItemAlign.Start)

        Text('逐页抓取全帖 ' + (this.totalPages > 0 ? String(this.totalPages) + ' 页' : '所有页') +
          '楼层，剔掉灌水回复后生成一份新的本地帖子，与原帖的离线存档并列。')
          .fontSize(12).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
          .margin({ top: 6 }).alignSelf(ItemAlign.Start)

        if (this.totalPages > 50) {
          Text('该帖较长，预计耗时 ' + formatDuration(estimateWaterFilterMs(this.totalPages)) +
            '（估算，视网速而定）。任务在后台继续，随时可从进度条取消。')
            .fontSize(12).fontColor(AppColors.warning)
            .margin({ top: 6 }).alignSelf(ItemAlign.Start)
        } else if (this.totalPages > 0) {
          Text('预计耗时 ' + formatDuration(estimateWaterFilterMs(this.totalPages)) + ' 左右。')
            .fontSize(12).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
            .margin({ top: 6 }).alignSelf(ItemAlign.Start)
        }

        Text('去水严格程度')
          .fontSize(12).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
          .margin({ top: 16, bottom: 6 }).alignSelf(ItemAlign.Start)

        this.levelChip(WaterFilterLevel.BASIC)
        Row().height(6)
        this.levelChip(WaterFilterLevel.AGGRESSIVE)

        Divider().color(AppColors.separator).margin({ top: 14, bottom: 10 })

        Row() {
          Text(this.enabledRules > 0
            ? '自定义规则：' + String(this.enabledRules) + ' 条生效'
            : '自定义规则：未设置')
            .fontSize(13).fontColor(UIMaterialManager.adaptiveForeground)
            .layoutWeight(1)
          Text('设置')
            .fontSize(13).fontColor(AppColors.primary)
            .padding({ left: 8, right: 2, top: 6, bottom: 6 })
            .onClick(() => {
              if (this.onOpenRules) {
                this.onOpenRules()
              }
            })
        }
        .width('100%').alignItems(VerticalAlign.Center)

        // AI 区块与自定义规则同属「本次用哪些规则」，紧跟其后
        Row().height(12)
        this.aiSection()

        Text('自定义规则在任何严格等级下都生效；主楼、带图片附件、带楼中楼或热评的楼层不会被删除。' +
          '引用别人的内容不计入长度，也不会让本层免于判水。')
          .fontSize(11).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
          .margin({ top: 10 }).alignSelf(ItemAlign.Start)

        // 产出物落点：用户点完「开始」就离开对话框，不提前说就找不到去水版
        Row() {
          Text(SAVE_LOCATION_HINT)
            .fontSize(11).fontColor(UIMaterialManager.adaptiveForeground)
            .lineHeight(16)
        }
        .width('100%')
        .margin({ top: 10 })
        .padding({ left: 8, right: 8, top: 8, bottom: 8 })
        .borderRadius(8)
        .backgroundColor(AppColors.bgSecondary)
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    // 长文案（含 AI 规则列表）必须可滚动：对话框自身不滚动，超出的部分会被裁掉
    .constraintSize({ maxHeight: 400 })
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
  }
}
