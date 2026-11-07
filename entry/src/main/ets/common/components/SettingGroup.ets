import { AppColors } from '../constants/Constants'

/**
 * 设置页分组容器与辅助行组件。
 *
 * 设置页的组织单位是「分组」：一个组 = 一张圆角卡片，卡片内是一系列设置行。
 * 组与组之间靠留白与卡片边界分隔，**不渲染组标题**——设置行本身已有图标 + 文字，
 * 卡片上方再加一行小标题只会增加视觉噪音（每组只有 2~4 行时尤其明显）。
 *
 * 本文件把原先散落在 `SettingsPanel.build()` 里的三件事收敛到一处：
 *
 * - {@link SettingGroup}：卡片外壳（宽度 92%、圆角 12、组间外边距）
 * - {@link SettingGroupDivider}：行间分隔线（统一左缩进 60，与图标行文字对齐）
 * - {@link SettingDangerRow}：危险操作行（红底图标 + 红字，无箭头）
 *
 * 注意：分隔线**不能**由 `SettingGroup` 自动插入 —— 本地 SDK（API 26）的
 * `ColumnAttribute` 只有 alignItems / justifyContent / reverse，**没有** `divider` 属性
 * （`column.d.ts` 已核对），而组内容是由调用方经 `@BuilderParam` 传入的任意子组件树。
 * 因此分隔线以 `SettingGroupDivider()` 的形式在调用方逐行显式使用：它把颜色与左缩进
 * 收进组件，避免每处再手写 `Divider().margin({ left: 60 }).color(...)` 时参数漂移。
 */

@Component
export struct SettingGroup {
  /** 组顶部外边距（vp）。危险操作区等需要与上方拉开距离时可覆盖。 */
  @Prop topMargin: number = 16
  /**
   * 组内容。
   *
   * 调用方**必须**用箭头函数包装（`content: (): void => { this.xxxContent() }`）：
   * 直接传方法引用会让 @Builder 内部的 `this` 指向本组件而不是调用方组件，
   * 于是读不到调用方的状态、回调也写不回去（见 AGENTS.md 的 @BuilderParam 约定）。
   */
  @BuilderParam content: () => void = this.emptyContent

  /** `content` 的默认空实现（调用方总会传入，这里只用于满足初始化）。 */
  @Builder
  emptyContent() {
  }

  build() {
    Column() {
      this.content()
    }
    .width('92%')
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(12)
    .clip(true)
    .margin({ top: this.topMargin })
  }
}

/** 分组内的行间分隔线：左缩进 60（16 padding + 29 图标 + 12 间距 + 3 视觉微调），与行文字对齐。 */
@Component
export struct SettingGroupDivider {
  build() {
    Divider().margin({ left: 60 }).color(AppColors.separator)
  }
}

/**
 * 危险操作行：红底图标 + 红色标签，无箭头。
 *
 * 与 `SettingRow` 的区别只在配色与尾部：危险动作（退出登录等）不引导用户"继续点进去"，
 * 所以不画箭头；红色标签提示不可逆语义。
 */
@Component
export struct SettingDangerRow {
  /** 图标资源 */
  @Prop iconRes: Resource
  /** 行标签文案 */
  @Prop label: string
  /** 点击行时触发的回调 */
  onAction: () => void = () => {}

  build() {
    Row() {
      Stack() {
        Image(this.iconRes).width(17).height(17).fillColor(AppColors.white)
      }
      .width(29).height(29).borderRadius(6).backgroundColor(AppColors.destructive).margin({ right: 12 })

      Text(this.label).fontSize(17).fontColor(AppColors.destructive).layoutWeight(1)
    }
    .width('100%').height(44).padding({ left: 16, right: 16 }).alignItems(VerticalAlign.Center)
    .onClick(this.onAction)
  }
}
