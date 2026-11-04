import { AppColors } from '../../constants/Constants'

/**
 * 两层递进树的折叠行（「共 N 条回复，点击查看」）。
 *
 * 职责（`docs/THREAD_TREE_DESIGN.md` §3.4）：某个根节点的后代总数超过折叠阈值
 * （`> 3`）且尚未展开时，在其已显示的子节点行之后插入本行；点击整行让父组件
 * 展开该根的全部子节点并重建可见行。
 *
 * 视觉定值：单行高 40vp、左侧与子节点同缩进（40vp）、文案 13vp
 * `AppColors.textTertiary`（对齐 B 站实测的折叠行灰色 13px）＋ 下箭头
 * `icon_chevron_down` 12×12；无背景块、无分隔线。
 *
 * 本组件不持任何状态（展开态在树模型/父组件），只做展示与回调。
 */

/** 折叠行左侧缩进（vp，与子节点行 `ThreadTreeChildItem` 的缩进保持一致）。 */
const MORE_ITEM_INDENT: number = 40

/** 折叠行右侧内边距（vp）。 */
const MORE_ITEM_RIGHT_PADDING: number = 16

/** 折叠行高度（vp，整行可点，热区 ≥ 36）。 */
const MORE_ITEM_HEIGHT: number = 40

/** 折叠行文案字号（vp）。 */
const MORE_ITEM_FONT_SIZE: number = 13

/** 折叠行下箭头图标尺寸（vp）。 */
const MORE_ITEM_CHEVRON_SIZE: number = 12

/** 折叠行文案与下箭头之间的间距（vp）。 */
const MORE_ITEM_CHEVRON_GAP: number = 4

@Component
export struct ThreadTreeMoreItem {
  /** 该根节点的后代总数（文案「共 N 条回复，点击查看」） */
  @Prop totalCount: number = 0
  /** 点击整行展开该根全部子节点的回调 */
  onExpand: () => void = () => {}

  build() {
    Row() {
      Text('共 ' + String(this.totalCount) + ' 条回复，点击查看')
        .fontSize(MORE_ITEM_FONT_SIZE)
        .fontColor(AppColors.textTertiary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Image($r('app.media.icon_chevron_down'))
        .width(MORE_ITEM_CHEVRON_SIZE)
        .height(MORE_ITEM_CHEVRON_SIZE)
        .fillColor(AppColors.textTertiary)
        .margin({ left: MORE_ITEM_CHEVRON_GAP })
    }
    .width('100%')
    .height(MORE_ITEM_HEIGHT)
    .padding({ left: MORE_ITEM_INDENT, right: MORE_ITEM_RIGHT_PADDING })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => { this.onExpand() })
  }
}
