import { AppColors } from '../constants/Constants'
import { UIMaterialManager } from '../managers/UIMaterialManager'

/**
 * 加载中页面态组件。
 *
 * 渲染一个 28x28 的 LoadingProgress 配合居中文案（默认“加载中...”），
 * 文案字号 14、颜色为 textTertiary，与 LoadingProgress 间距 8。
 *
 * 仅渲染内部内容，外层容器（居中布局、padding、动画过渡等）由调用方自行包裹。
 */
@Component
export struct LoadingStateView {
  /** 加载中文案，默认“加载中...” */
  @Prop tip: string = '加载中...'

  build() {
    Column() {
      LoadingProgress().width(28).height(28).color(AppColors.textTertiary)
      Text(this.tip).fontSize(14).fontColor(AppColors.textTertiary).margin({ top: 8 })
    }
  }
}

/**
 * 错误页面态组件。
 *
 * 渲染错误文案（字号 14、颜色 textTertiary、下间距 12）与一个“重试”按钮
 * （字号 14、文字色 primary、背景 bgSecondary、圆角 10）。
 *
 * 仅渲染内部内容，外层容器（居中布局、padding、动画过渡等）由调用方自行包裹。
 * onRetry 为普通箭头属性而非 @Prop，因为 ArkTS 不允许 @Prop 传递函数引用。
 */
@Component
export struct ErrorStateView {
  /** 错误文案 */
  @Prop msg: string
  /** 点击“重试”按钮时触发的回调 */
  onRetry: () => void = () => {}

  build() {
    Column() {
      Text(this.msg).fontSize(14).fontColor(AppColors.textTertiary).margin({ bottom: 12 })
      Button('重试').fontSize(14).fontColor(UIMaterialManager.adaptiveForeground)
        .backgroundColor(Color.Transparent)
        .systemMaterial(UIMaterialManager.fabMaterial)
        .borderRadius(10)
        .onClick(() => this.onRetry())
    }
  }
}

/**
 * 空页面态组件。
 *
 * 渲染一个图标（40x40、填充色 textTertiary、透明度 0.4）配合居中空提示文案
 * （字号 15、颜色 textTertiary、与图标间距 8）。
 *
 * 仅渲染内部内容，外层容器（居中布局、padding、动画过渡等）由调用方自行包裹。
 *
 * @param msg - 空提示文案
 * @param icon - 空态图标资源（通过 $r('app.media.xxx') 传入）
 */
@Component
export struct EmptyStateView {
  /** 空提示文案 */
  @Prop msg: string
  /** 空态图标资源 */
  @Prop icon: Resource

  build() {
    Column() {
      Image(this.icon).width(40).height(40).fillColor(AppColors.textTertiary).opacity(0.4)
      Text(this.msg).fontSize(15).fontColor(AppColors.textTertiary).margin({ top: 8 })
    }
  }
}
