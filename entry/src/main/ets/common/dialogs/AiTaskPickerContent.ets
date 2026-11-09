/**
 * AI 任务选择对话框的内容构件（帖子页楼层菜单「AI 摘要 / 任务」入口）。
 *
 * 与 `SaveThreadDialogs.ets` / `ThreadTrackDialogs.ets` 同属「官方 `CustomContentDialog`
 * 的自定义内容」：标题与按钮由官方模板渲染，本组件只负责任务列表。
 *
 * 与调用方的契约：
 * - 调用方传 `contentBuilder` 必须写箭头函数（`contentBuilder: (): void => { this.aiTaskContent() }`），
 *   不能传方法引用——@Builder 内的 `this` 会指向对话框组件实例。
 * - `tasks` 只是**当前可用任务**的快照（调用方在打开对话框前按入口过滤好）；本组件不查配置。
 * - 选中后由调用方负责关闭对话框并启动任务（`onPick` 里做），本组件不持有对话框控制器。
 */

import { AiAgentPreset } from '../../model/AiAgentPreset'
import { AppColors } from '../constants/Constants'

@Component
export struct AiTaskPickerContent {
  /** 可选任务（按入口过滤后的快照）。 */
  @Prop tasks: AiAgentPreset[] = []

  /**
   * 选中回调。
   *
   * @param task - 被点击的任务
   */
  onPick?: (task: AiAgentPreset) => void

  build() {
    Column() {
      ForEach(this.tasks, (task: AiAgentPreset) => {
        Row() {
          Column() {
            Text(task.name)
              .fontSize(15)
              .fontColor(AppColors.textPrimary)
            if (task.description.length > 0) {
              Text(task.description)
                .fontSize(11)
                .fontColor(AppColors.textTertiary)
                .lineHeight(16)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 2 })
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text('›')
            .fontSize(18)
            .fontColor(AppColors.chevron)
        }
        .width('100%')
        .padding({ top: 10, bottom: 10 })
        .alignItems(VerticalAlign.Center)
        .onClick((): void => {
          if (this.onPick) {
            this.onPick(task)
          }
        })
      }, (task: AiAgentPreset): string => task.id)
    }
    .width('100%')
  }
}
