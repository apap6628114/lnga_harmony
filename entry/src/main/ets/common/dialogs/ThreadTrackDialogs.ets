/**
 * 跟踪帖子更新的对话框内容构件（ThreadPanel 更多菜单「跟踪帖子更新」打开）。
 *
 * 迁移说明与 `SaveThreadDialogs.ets` 同款：标题与按钮由官方 `CustomContentDialog`
 * 模板渲染，本组件只负责「用途说明 + 已跟踪状态卡 + 跟踪时长选择 + 停止跟踪入口」。
 *
 * 与调用方的契约：
 * - 调用方传 `contentBuilder` 必须写箭头函数（`contentBuilder: (): void => { this.trackContent() }`），
 *   不能传方法引用：@Builder 内的 `this` 会指向对话框组件实例，读到的入参全是 undefined。
 * - 参数用 `@Prop` + 回调，**禁止 `@Link`**（官方 contentBuilder 是 @BuilderParam，
 *   传进去的 @Builder 在对话框组件内部执行，`$变量` 在那一层解析不到源状态会崩溃）。
 * - 跟踪时长经 `onKeepDaysChange` 回写调用方，调用方在官方确认按钮回调里读取提交。
 * - 「停止跟踪」是内容区的破坏色文字按钮（官方按钮区不支持动态禁用/三态按钮，
 *   与凭证导出弹窗自绘按钮同一先例）：点击后由调用方关闭对话框并提示。
 *
 * 状态卡的值全部展开为**标量 @State**，不把 `TrackedThread` 对象本身塞进 @State：
 * `appStore.getTrackedThread()` 返回的是 Store 里同一个对象引用（该类不是 @Observed），
 * 同引用重新赋值在 ArkUI V1 下不保证触发刷新；标量赋值则必然刷新。
 *
 * 取色遵守 `docs/IMMERSIVE_LIGHT_DESIGN.md` §12.3（背板是系统沉浸材质，内容层不使用
 * 应用自定义的暖棕阶文字色），并按 `ReplyDialog.ets` 的浮层配方取色：**说明文字同样取
 * 主前景 `adaptiveForeground`，不用降调的次要前景**——半透明玻璃之上降调文字可读性不足；
 * 只有选中胶囊用品牌色实底 + 白字。状态卡与未选中胶囊的层级改用 `selectionTint`
 * 与 `$r('sys.color.comp_divider')` 描边表达。
 *
 * 面向用户的文案只表达「需要理解的功能」，不写实现细节（检查频率、失效判定条件等不进 UI）。
 */

import { appStore } from '../../store/AppStore'
import { AppColors } from '../constants/Constants'
import { UIMaterialManager } from '../managers/UIMaterialManager'
import {
  TrackedThread,
  TRACK_DEFAULT_KEEP_DAYS,
  TRACK_KEEP_DAYS_OPTIONS,
  TRACK_MAX_COUNT
} from '../../model/TrackedThread'
import { remainingTrackDays, unreadReplyCount } from '../utils/ThreadTrackPolicy'

@Component
export struct ThreadTrackContent {
  /** NGA 主题 ID。 */
  @Prop tid: string = ''
  /**
   * 跟踪时长变化回调（回写调用方，供确认按钮提交）。
   *
   * @param days - 当前选中的跟踪天数
   */
  onKeepDaysChange?: (days: number) => void
  /** 停止跟踪回调（用户点击内容区「停止跟踪」）。 */
  onStopTrack?: () => void

  /** 当前选中的跟踪时长（天）。 */
  @State keepDays: number = TRACK_DEFAULT_KEEP_DAYS
  /** 是否已跟踪该帖。 */
  @State tracked: boolean = false
  /** 状态卡：剩余跟踪天数。 */
  @State remainingDays: number = 0
  /** 状态卡：服务端总回复数。 */
  @State totalReplies: number = 0
  /** 状态卡：未读新增回复数。 */
  @State unreadReplies: number = 0
  /** 状态卡：上次成功检查时间（毫秒，0=尚未检查）。 */
  @State lastCheckAt: number = 0
  /** 状态卡：连续检查失败次数。 */
  @State failCount: number = 0
  /** 状态卡：最近一次检查失败原因。 */
  @State lastError: string = ''
  /**
   * 相对时间基准（毫秒）。
   *
   * 打开对话框时取一次即可：对话框停留通常只有几秒到几十秒，而「上次检查」文案是
   * 分钟级粒度；刻意不做周期刷新——那需要一个定时器，而内容构件的销毁回调依赖
   * 官方模板行为，不值得为一句缓存文案引入这条依赖。
   */
  @State nowTick: number = Date.now()
  /** 跟踪列表版本号（新增/移除/检查到更新时变化，驱动状态卡刷新）。 */
  @StorageProp('trackedThreadVersion') @Watch('onTrackVersionChange') trackedThreadVersion: number = 0

  aboutToAppear(): void {
    const item: TrackedThread | null = appStore.getTrackedThread(this.tid)
    if (item !== null && item.keepDays > 0) {
      this.keepDays = item.keepDays
    }
    if (this.onKeepDaysChange) {
      this.onKeepDaysChange(this.keepDays)
    }
    this.syncTracked()
  }

  /** 跟踪列表版本变化：只刷新状态卡，不覆盖用户已改动的天数选择。 */
  private onTrackVersionChange(): void {
    this.syncTracked()
  }

  /**
   * 从 Store 同步状态卡字段（展开为标量，保证 @State 一定触发刷新）。
   */
  private syncTracked(): void {
    const item: TrackedThread | null = appStore.getTrackedThread(this.tid)
    if (item === null) {
      this.tracked = false
      this.remainingDays = 0
      this.totalReplies = 0
      this.unreadReplies = 0
      this.lastCheckAt = 0
      this.failCount = 0
      this.lastError = ''
      return
    }
    this.tracked = true
    this.remainingDays = remainingTrackDays(item, this.nowTick)
    this.totalReplies = item.totalReplies
    this.unreadReplies = unreadReplyCount(item)
    this.lastCheckAt = item.lastCheckAt
    this.failCount = item.failCount
    this.lastError = item.lastError
  }

  /**
   * 选择跟踪时长。
   *
   * @param days - 目标天数
   */
  private selectKeepDays(days: number): void {
    if (this.keepDays === days) {
      return
    }
    this.keepDays = days
    if (this.onKeepDaysChange) {
      this.onKeepDaysChange(days)
    }
  }

  /**
   * 相对时间文案（「尚未检查 / 刚刚 / N 分钟前 / N 小时前 / N 天前」）。
   *
   * @param timestamp - 毫秒时间戳；<=0 表示尚未发生
   * @returns 文案
   */
  private relativeTime(timestamp: number): string {
    if (timestamp <= 0) {
      return '尚未检查'
    }
    const diff: number = this.nowTick - timestamp
    if (diff < 60 * 1000) {
      return '刚刚'
    }
    if (diff < 60 * 60 * 1000) {
      return String(Math.floor(diff / (60 * 1000))) + ' 分钟前'
    }
    if (diff < 24 * 60 * 60 * 1000) {
      return String(Math.floor(diff / (60 * 60 * 1000))) + ' 小时前'
    }
    return String(Math.floor(diff / (24 * 60 * 60 * 1000))) + ' 天前'
  }

  /** 用途说明（未跟踪时）。 */
  private usageText(): string {
    return '开启后，该帖有新回复时会在「消息 → 跟踪」提醒你。'
  }

  /** 跟踪时长说明（随所选天数变化）。 */
  private keepDaysHint(): string {
    return '连续 ' + String(this.keepDays) + ' 天没有新回复会自动停止跟踪。'
  }

  /** 已跟踪状态卡：状态行文案。 */
  private statusTitle(): string {
    return '正在跟踪 · 剩余 ' + String(this.remainingDays) + ' 天'
  }

  /** 已跟踪状态卡：明细行文案。 */
  private statusDetail(): string {
    let text: string = String(this.totalReplies) + ' 条回复'
    if (this.unreadReplies > 0) {
      text += ' · 未读 ' + String(this.unreadReplies) + ' 条新回复'
    }
    text += ' · 上次检查 ' + this.relativeTime(this.lastCheckAt)
    return text
  }

  /** 已跟踪状态卡：失败提示（连续检查失败时）。 */
  private statusError(): string {
    if (this.failCount <= 0 || this.lastError.length === 0) {
      return ''
    }
    return '最近一次检查失败：' + this.lastError
  }

  /** 跟踪时长胶囊（未选中用描边表达，选中用品牌色实底——材质文档 §12.3 的例外项）。 */
  @Builder
  keepDaysChip(days: number) {
    Text(String(days) + ' 天')
      .fontSize(13)
      .fontColor(this.keepDays === days ? AppColors.white : UIMaterialManager.adaptiveForeground)
      .fontWeight(this.keepDays === days ? FontWeight.Medium : FontWeight.Normal)
      .backgroundColor(this.keepDays === days ? AppColors.primary : Color.Transparent)
      .border({
        width: this.keepDays === days ? 0 : 0.5,
        color: $r('sys.color.comp_divider')
      })
      .borderRadius(14)
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .onClick((): void => {
        this.selectKeepDays(days)
      })
  }

  build() {
    Column() {
      if (this.tracked) {
        Column() {
          Row() {
            Text(this.statusTitle())
              .fontSize(14)
              .fontColor(UIMaterialManager.adaptiveForeground)
              .fontWeight(FontWeight.Medium)
              .layoutWeight(1)
          }.width('100%')
          Text(this.statusDetail())
            .fontSize(12)
            .fontColor(UIMaterialManager.adaptiveForeground)
            .margin({ top: 4 })
            .width('100%')
          if (this.statusError().length > 0) {
            /* 警示文字沿用工程既有配方（ReplyDialog / SaveThreadDialogs 的警示色） */
            Text(this.statusError())
              .fontSize(12)
              .fontColor(AppColors.warning)
              .margin({ top: 4 })
              .width('100%')
          }
        }
        .width('100%')
        .padding(12)
        .backgroundColor(AppColors.selectionTint)
        .border({ width: 0.5, color: $r('sys.color.comp_divider') })
        .borderRadius(10)
        .alignItems(HorizontalAlign.Start)
        .margin({ bottom: 12 })
      } else {
        Text(this.usageText())
          .fontSize(13)
          .fontColor(UIMaterialManager.adaptiveForeground)
          .width('100%')
          .margin({ bottom: 10 })
      }

      Text(this.keepDaysHint())
        .fontSize(13)
        .fontColor(UIMaterialManager.adaptiveForeground)
        .width('100%')
        .margin({ bottom: 10 })

      if (!this.tracked) {
        Text('最多同时跟踪 ' + String(TRACK_MAX_COUNT) + ' 个帖子。')
          .fontSize(13)
          .fontColor(UIMaterialManager.adaptiveForeground)
          .width('100%')
          .margin({ bottom: 10 })
      }

      Text('跟踪时长')
        .fontSize(13)
        .fontColor(UIMaterialManager.adaptiveForeground)
        .alignSelf(ItemAlign.Start)
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Start }) {
        ForEach(TRACK_KEEP_DAYS_OPTIONS, (days: number) => {
          Row() {
            this.keepDaysChip(days)
          }.margin({ right: 8, top: 8 })
        }, (days: number) => String(days))
      }
      .width('100%')

      if (this.tracked) {
        Row() {
          Text('停止跟踪')
            .fontSize(13)
            .fontColor(AppColors.destructive)
            .padding({ left: 2, right: 8, top: 6, bottom: 6 })
            .onClick((): void => {
              if (this.onStopTrack) {
                this.onStopTrack()
              }
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        .margin({ top: 10 })
      }
    }
    .width('100%')
  }
}
