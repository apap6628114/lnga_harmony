import { AppColors } from '../constants/Constants'
import { UIMaterialManager } from '../managers/UIMaterialManager'


/**
 * 通用设置项/操作行组件集。
 *
 * 统一 SettingsPanel / ProfilePanel 两个 Panel 中重复出现的
 * “图标 + 标签 + 尾部控件”行形态，按尾部控件类型拆为三个 struct：
 * （TtsSettingsPanel 行形态为 Slider，与图标行不同，未纳入）
 *
 * - {@link SettingRow}：普通点击行，尾部为可选未读数 badge（红色数字）+ 箭头
 * - {@link SettingToggleRow}：开关行，尾部为 Toggle
 * - {@link SettingPickerRow}：选择器行，尾部为当前值（灰色文字）+ 箭头
 *
 * 行的视觉基线：高度 44、左右 padding 16、垂直居中；左侧图标容器 29x29 圆角 6，
 * 内含 17x17 白色图标，背景色由 iconColor 指定，与标签间距 12。
 *
 * onClick/onChange 为普通箭头属性而非 @Prop，因为 ArkTS 不允许 @Prop 传递函数引用。
 */

/**
 * 普通点击行：图标 + 标签 + 可选未读数 badge + 箭头。
 *
 * 对应原 ProfilePanel.ActionRow @Builder 的形态（badge 为红色数字徽章样式）。
 * badge 为空字符串时不渲染徽章。
 */
@Component
export struct SettingRow {
  /** 图标资源 */
  @Prop iconRes: Resource
  /** 图标容器背景色 */
  @Prop iconColor: string
  /** 行标签文案 */
  @Prop label: string
  /** 未读数徽章文案，为空时不渲染 */
  @Prop badge: string = ''
  /** 点击行时触发的回调 */
  onAction: () => void = () => {}

  build() {
    Row() {
      Stack() {
        Image(this.iconRes).width(17).height(17).fillColor(AppColors.white)
      }
      .width(29).height(29).borderRadius(6).backgroundColor(this.iconColor).margin({ right: 12 })

      Text(this.label).fontSize(17).layoutWeight(1)

      if (this.badge) {
        Text(this.badge)
          .fontSize(12)
          .fontColor(AppColors.white)
          .backgroundColor(AppColors.destructive)
          .borderRadius(10)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .fontWeight(FontWeight.Bold)
          .margin({ right: 8 })
      }

      Text('>').fontSize(16).fontColor(AppColors.chevron)
    }
    .width('100%').height(44).padding({ left: 16, right: 16 }).alignItems(VerticalAlign.Center)
    .onClick(this.onAction)
  }
}

/**
 * 开关行：图标 + 标签 + Toggle。
 *
 * 对应 SettingsPanel 中重复出现的 Toggle 行形态（自动签到 / 智感握姿 / 显示签名）。
 * 高度固定 44；带副标题或非标准高度的 Toggle 行不在本组件覆盖范围内。
 */
@Component
export struct SettingToggleRow {
  /** 图标资源 */
  @Prop iconRes: Resource
  /** 图标容器背景色 */
  @Prop iconColor: string
  /** 行标签文案 */
  @Prop label: string
  /** 开关当前是否开启 */
  @Prop isOn: boolean
  /** 开关状态变化时触发的回调，入参为新的开关状态 */
  onChange: (isOn: boolean) => void = () => {}

  build() {
    Row() {
      Stack() {
        Image(this.iconRes).width(17).height(17).fillColor(AppColors.white)
      }
      .width(29).height(29).borderRadius(6).backgroundColor(this.iconColor).margin({ right: 12 })

      Text(this.label).fontSize(17).layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .onChange(this.onChange)
        .systemMaterial(UIMaterialManager.controlMaterial)
    }
    .width('100%').height(44).padding({ left: 16, right: 16 }).alignItems(VerticalAlign.Center)
  }
}

/**
 * 选择器行：图标 + 标签 + 当前值 badge + 箭头。
 *
 * 对应 SettingsPanel 中图片加载模式 / 帖子楼层导航 / 预加载页数 / 清除缓存等
 * 带当前值的选择器行形态（badgeText 为灰色文字样式，与 SettingRow 的红色数字徽章区分）。
 */
@Component
export struct SettingPickerRow {
  /** 图标资源 */
  @Prop iconRes: Resource
  /** 图标容器背景色 */
  @Prop iconColor: string
  /** 行标签文案 */
  @Prop label: string
  /** 当前值文案，显示在箭头左侧 */
  @Prop badgeText: string
  /** 点击行时触发的回调 */
  onAction: () => void = () => {}

  build() {
    Row() {
      Stack() {
        Image(this.iconRes).width(17).height(17).fillColor(AppColors.white)
      }
      .width(29).height(29).borderRadius(6).backgroundColor(this.iconColor).margin({ right: 12 })

      Text(this.label).fontSize(17).layoutWeight(1)

      Text(this.badgeText).fontSize(15).fontColor(AppColors.textSecondary).margin({ right: 8 })

      Text('>').fontSize(16).fontColor(AppColors.chevron)
    }
    .width('100%').height(44).padding({ left: 16, right: 16 }).alignItems(VerticalAlign.Center)
    .onClick(this.onAction)
  }
}
