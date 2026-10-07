/**
 * 「智能去水」规则设置页。
 *
 * 与「关键词屏蔽」同层级：都是设置里的一块**全局**配置。本页管两件事：
 * 1. **严格等级**（二选一）——只影响内置词表的取用范围；
 * 2. **自定义规则**（增删改 + 启用开关）——任何等级下都生效。
 *
 * 页面的职责边界只有「读写配置」：判定口径在 `service/WaterFilterEngine`，
 * 规则值与等级的合法区间在 `model/WaterFilterRule`，本页只做展示与收集。
 *
 * 等级改动**即时落盘**（点即生效），不做「保存」按钮：等级是单选、语义自洽，
 * 再加一层确认只会让用户以为没生效。自定义规则的增删改同样即时落盘，
 * 唯一的二次确认是「删除单条」与「清空全部」。
 */

import { appStore } from '../store/AppStore'
import { AppColors } from '../common/constants/Constants'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { AlertDialog, CustomContentDialog } from '@kit.ArkUI'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'
import { UIMaterialManager } from '../common/managers/UIMaterialManager'
import { WaterRuleDataSource } from '../common/datasource/LazyDataSource'
import {
  WaterFilterLevel,
  WaterFilterRule,
  WaterRuleType,
  clampWaterLevel,
  isWaterRuleType,
  validateWaterRule,
  waterLevelDescription,
  waterLevelLabel,
  waterRuleTypeLabel
} from '../model/WaterFilterRule'

/** 规则编辑器里可选的类型顺序（与词表语义由窄到宽排列）。 */
const RULE_TYPE_ORDER: string[] = [
  WaterRuleType.CONTAINS,
  WaterRuleType.EQUALS,
  WaterRuleType.MAX_LENGTH
]

/**
 * 规则编辑器内容（官方 CustomContentDialog 的 contentBuilder）。
 *
 * 类型与值都通过 `@Prop` + 回调单向流动，**不用 `@Link`**：官方 `contentBuilder`
 * 是 `@BuilderParam`，其中的 `$变量` 在对话框那一层解析不到源状态（同
 * `SaveThreadDialogs.ets` 头部说明）。因此编辑器自己持有一份 `@State` 草稿，
 * 父组件在打开对话框前用 `initialType/initialValue` 灌初值。
 */
@Component
export struct WaterRuleEditorContent {
  /** 打开时的初始类型（新增时给 CONTAINS）。 */
  @Prop initialType: string = WaterRuleType.CONTAINS
  /** 打开时的初始值（新增时为空串）。 */
  @Prop initialValue: string = ''
  /** 值变化回调（父组件保存草稿，确认时取用）。 */
  onValueChange?: (type: string, value: string) => void

  /** 当前选中的规则类型。 */
  @State private type: string = WaterRuleType.CONTAINS
  /** 当前输入的规则值。 */
  @State private value: string = ''

  aboutToAppear(): void {
    this.type = isWaterRuleType(this.initialType) ? this.initialType : WaterRuleType.CONTAINS
    this.value = this.initialValue
  }

  /**
   * 切换规则类型并回报父组件。
   *
   * @param next - 目标类型
   */
  private selectType(next: string): void {
    if (this.type === next) {
      return
    }
    this.type = next
    if (this.onValueChange) {
      this.onValueChange(this.type, this.value)
    }
  }

  /** 当前类型的一句话说明。 */
  private typeHint(): string {
    if (this.type === WaterRuleType.EQUALS) {
      return '纯文本完全等于该内容才判为灌水（忽略大小写与首尾空白）。'
    }
    if (this.type === WaterRuleType.MAX_LENGTH) {
      return '纯文本不超过该字数才判为灌水；引用的内容不计入长度，带图片附件的楼层永远保留。'
    }
    return '纯文本包含该内容即判为灌水（比对前会剥掉 BBCode 标记，引用的内容不计入）。'
  }

  @Builder
  typeChip(value: string) {
    Text(waterRuleTypeLabel(value))
      .fontSize(13)
      .fontColor(this.type === value ? AppColors.white : UIMaterialManager.adaptiveForeground)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(this.type === value ? AppColors.primary : AppColors.bgSecondary)
      .onClick(() => {
        this.selectType(value)
      })
  }

  build() {
    Column() {
      Text('规则类型').fontSize(12).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
        .alignSelf(ItemAlign.Start)

      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(RULE_TYPE_ORDER, (item: string) => {
          Row() {
            this.typeChip(item)
          }.margin({ right: 8, top: 8 })
        }, (item: string) => item)
      }
      .width('100%')

      TextInput({
        text: this.value,
        placeholder: this.type === WaterRuleType.MAX_LENGTH ? '不超过多少字（1~500）' : '输入要判为灌水的内容'
      })
        .type(this.type === WaterRuleType.MAX_LENGTH ? InputType.Number : InputType.Normal)
        .width('100%').height(44).fontSize(15).borderRadius(12)
        .margin({ top: 14 })
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .attributeModifier(UIMaterialManager.dialogFieldMaterial)
        .onChange((text: string) => {
          this.value = text
          if (this.onValueChange) {
            this.onValueChange(this.type, text)
          }
        })

      Text(this.typeHint())
        .fontSize(11).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
        .margin({ top: 8 }).alignSelf(ItemAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

@Component
export struct WaterFilterRulesPanel {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 列表当前视口高度。 */
  @State listViewportHeight: number = 1
  /** 当前严格等级。 */
  @State private level: number = WaterFilterLevel.BASIC
  /** 规则总条数（列表空态与「清空」入口的显隐依据）。 */
  @State private ruleCount: number = 0
  /** 待删除的规则标识（删除确认弹窗用）。 */
  @State private removeTarget: string = ''
  /** 编辑器草稿：类型。 */
  @State private draftType: string = WaterRuleType.CONTAINS
  /** 编辑器草稿：值。 */
  @State private draftValue: string = ''

  /** 页面滚动控制器（标题栏联动用）。 */
  private scroller: Scroller = new Scroller()
  /** 自定义规则列表数据源。 */
  private ruleDataSource: WaterRuleDataSource = new WaterRuleDataSource()
  /** 编辑器正在编辑的规则标识；空串表示新增。 */
  private editingRuleId: string = ''

  /** 规则编辑器对话框控制器。 */
  private ruleDialogController?: CustomDialogController

  /** 删除单条规则的确认对话框。 */
  private deleteDialogController?: CustomDialogController = new CustomDialogController({
    backgroundColor: Color.Transparent,
    systemMaterial: UIMaterialManager.dialogMaterial,
    maskColor: UIMaterialManager.scrim,
    builder: AlertDialog({
      primaryTitle: '删除规则',
      content: '确定要删除这条去水规则吗？',
      primaryButton: {
        value: '删除',
        fontColor: AppColors.white,
        background: AppColors.destructive,
        action: (): void => {
          if (this.removeTarget.length > 0) {
            appStore.settingsStore.removeWaterRule(this.removeTarget)
            this.removeTarget = ''
            this.refreshRules()
          }
        }
      },
      secondaryButton: {
        value: '取消',
        action: (): void => {
          this.removeTarget = ''
        }
      }
    }),
    autoCancel: true
  })

  /** 清空全部规则的确认对话框。 */
  private clearDialogController?: CustomDialogController = new CustomDialogController({
    backgroundColor: Color.Transparent,
    systemMaterial: UIMaterialManager.dialogMaterial,
    maskColor: UIMaterialManager.scrim,
    builder: AlertDialog({
      primaryTitle: '清空自定义规则',
      content: '确定要删除全部自定义规则吗？内置词表不受影响。',
      primaryButton: {
        value: '清空',
        fontColor: AppColors.white,
        background: AppColors.destructive,
        action: (): void => {
          appStore.settingsStore.removeAllWaterRules()
          this.refreshRules()
          appStore.showToast('已清空自定义规则')
        }
      },
      secondaryButton: { value: '取消' }
    }),
    autoCancel: true
  })

  aboutToAppear(): void {
    this.refreshLevel()
    this.refreshRules()
  }

  aboutToDisappear(): void {
    this.ruleDialogController = undefined
    this.deleteDialogController = undefined
    this.clearDialogController = undefined
  }

  /** 按列表绝对滚动偏移同步标题栏视觉效果。 */
  private syncTitleScrollEffect(): void {
    const progress: number = TitleScrollEffect.getProgress(
      this.scroller.currentOffset().yOffset,
      this.statusBarHeight
    )
    if (TitleScrollEffect.shouldUpdateProgress(this.titleScrollEffectProgress, progress)) {
      this.titleScrollEffectProgress = progress
    }
  }

  private refreshLevel(): void {
    this.level = appStore.settingsStore.getWaterFilterLevel()
  }

  private refreshRules(): void {
    const rules: WaterFilterRule[] = appStore.settingsStore.getWaterFilterRules()
    this.ruleCount = rules.length
    this.ruleDataSource.replaceAll(rules)
  }

  /**
   * 切换严格等级并落盘。
   *
   * @param value - 目标等级
   */
  private selectLevel(value: number): void {
    const next: number = clampWaterLevel(value)
    if (next === this.level) {
      return
    }
    appStore.settingsStore.setWaterFilterLevel(next)
    this.level = next
  }

  /**
   * 打开规则编辑器。
   *
   * @param rule - 待编辑的规则；传 `null` 表示新增
   */
  private openRuleDialog(rule: WaterFilterRule | null): void {
    this.editingRuleId = rule !== null ? rule.id : ''
    this.draftType = rule !== null ? rule.type : WaterRuleType.CONTAINS
    this.draftValue = rule !== null ? rule.value : ''
    this.ruleDialogController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: CustomContentDialog({
        primaryTitle: rule !== null ? '编辑去水规则' : '新增去水规则',
        secondaryTitle: '命中的楼层会在生成去水版时被剔除',
        contentBuilder: (): void => { this.ruleEditorContent() },
        buttons: [
          { value: '取消' },
          {
            value: '保存',
            fontColor: AppColors.white,
            background: AppColors.primary,
            action: (): void => {
              this.submitRule()
            }
          }
        ]
      }),
      autoCancel: true
    })
    this.ruleDialogController?.open()
  }

  /** 规则编辑器内容（官方 CustomContentDialog 的 contentBuilder）。 */
  @Builder
  ruleEditorContent() {
    WaterRuleEditorContent({
      initialType: this.draftType,
      initialValue: this.draftValue,
      onValueChange: (type: string, value: string): void => {
        this.draftType = type
        this.draftValue = value
      }
    })
  }

  /**
   * 提交规则编辑器：校验后新增或更新，成功即关框。
   */
  private submitRule(): void {
    const error: string = validateWaterRule(this.draftType, this.draftValue)
    if (error.length > 0) {
      appStore.showToast(error)
      return
    }
    const editing: boolean = this.editingRuleId.length > 0
    const result: string = editing
      ? appStore.settingsStore.updateWaterRule(this.editingRuleId, this.draftType, this.draftValue)
      : appStore.settingsStore.addWaterRule(this.draftType, this.draftValue)
    if (result.length > 0) {
      appStore.showToast(result)
      return
    }
    this.refreshRules()
    this.ruleDialogController?.close()
    appStore.showToast(editing ? '已更新规则' : '已添加规则')
  }

  /**
   * 规则的显示文本：长度上限补上单位，关键词类原样展示。
   *
   * @param rule - 目标规则
   * @returns 展示文本
   */
  private ruleDisplayText(rule: WaterFilterRule): string {
    if (rule.type === WaterRuleType.MAX_LENGTH) {
      return rule.value + ' 字以内'
    }
    return rule.value
  }

  @Builder
  levelRow(value: number) {
    Row() {
      Column() {
        Text(waterLevelLabel(value))
          .fontSize(15)
          .fontColor(this.level === value ? AppColors.primary : AppColors.textPrimary)
          .fontWeight(this.level === value ? FontWeight.Medium : FontWeight.Normal)
        Text(waterLevelDescription(value))
          .fontSize(12).fontColor(AppColors.textTertiary)
          .margin({ top: 2 }).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)

      if (this.level === value) {
        Image($r('app.media.icon_check')).width(18).height(18).fillColor(AppColors.primary)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.selectLevel(value)
    })
  }

  build() {
    Stack() {
      Column() {
        List({ scroller: this.scroller }) {
          // ---- 严格等级 ----
          ListItem() {
            Column() {
              Text('去水严格程度').fontSize(13).fontColor(AppColors.textTertiary)
                .width('100%').padding({ left: 16, top: 4, bottom: 4 })
              this.levelRow(WaterFilterLevel.BASIC)
              this.levelRow(WaterFilterLevel.AGGRESSIVE)
            }
            .width('100%')
          }

          // ---- 自定义规则标题行 ----
          ListItem() {
            Row() {
              Text('自定义规则').fontSize(13).fontColor(AppColors.textTertiary).layoutWeight(1)
              if (this.ruleCount > 0) {
                Text('清空').fontSize(13).fontColor(AppColors.destructive)
                  .padding({ left: 8, right: 0, top: 4, bottom: 4 })
                  .onClick(() => {
                    this.clearDialogController?.open()
                  })
              }
            }
            .width('100%').padding({ left: 16, right: 16, top: 16, bottom: 8 })
          }

          if (this.ruleCount === 0) {
            ListItem() {
              Column() {
                Text('还没有自定义规则').fontSize(15).fontColor(AppColors.textTertiary)
                Text('用右上角的加号添加：例如把「插眼」「马克」加进包含规则')
                  .fontSize(12).fontColor(AppColors.textTertiary)
                  .margin({ top: 6 }).textAlign(TextAlign.Center)
              }
              .width('100%').padding({ left: 32, right: 32, top: 24, bottom: 24 })
              .alignItems(HorizontalAlign.Center)
            }
          } else {
            LazyForEach(this.ruleDataSource, (item: WaterFilterRule) => {
              ListItem() {
                Row() {
                  Stack() {
                    Image($r('app.media.icon_check'))
                      .width(18).height(18)
                      .fillColor(item.enabled ? AppColors.primary : AppColors.textTertiary)
                      .opacity(item.enabled ? 1.0 : 0.3)
                  }
                  .width(40).height(40).borderRadius(20).backgroundColor(AppColors.bgSecondary)

                  Column() {
                    Text(this.ruleDisplayText(item))
                      .fontSize(15)
                      .fontColor(item.enabled ? AppColors.textPrimary : AppColors.textTertiary)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(waterRuleTypeLabel(item.type) + (item.enabled ? '' : ' · 已停用'))
                      .fontSize(12).fontColor(AppColors.textTertiary).margin({ top: 2 })
                  }
                  .layoutWeight(1).margin({ left: 12 }).alignItems(HorizontalAlign.Start)
                  .onClick(() => {
                    appStore.settingsStore.toggleWaterRule(item.id)
                    this.refreshRules()
                  })

                  Text('编辑')
                    .fontSize(13).fontColor(AppColors.primary)
                    .padding({ left: 8, right: 4, top: 10, bottom: 10 })
                    .onClick(() => {
                      this.openRuleDialog(item)
                    })

                  Stack() {
                    Image($r('app.media.icon_delete')).width(18).height(18).fillColor(AppColors.destructive)
                  }
                  .width(40).height(40)
                  .onClick(() => {
                    this.removeTarget = item.id
                    this.deleteDialogController?.open()
                  })
                }
                .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 })
                .alignItems(VerticalAlign.Center)
              }
            }, (item: WaterFilterRule) => item.id)
          }

          // ---- 判定口径说明 ----
          ListItem() {
            Column() {
              Text('判定顺序').fontSize(13).fontColor(AppColors.textTertiary)
                .width('100%').padding({ bottom: 6 })
              Text('1. 主楼、带图片附件、带楼中楼或热评、正文含富内容标记（图片/外链/代码等）的楼层永远保留；\n' +
                '2. 引用的内容不计入判定：别人的话既不会让你被判成灌水，也不能替你「凑够字数」；\n' +
                '3. 再按上方严格等级过滤内置灌水词（mark、插眼、纯表情、纯标点等）；\n' +
                '4. 最后叠加自定义规则——任何等级下都生效。')
                .fontSize(12).fontColor(AppColors.textTertiary).lineHeight(18)
                .width('100%')
            }
            .width('100%').padding({ left: 16, right: 16, top: 16, bottom: 24 })
          }
        }
        .width('100%').layoutWeight(1)
        .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
        .divider({ strokeWidth: 0.5, color: AppColors.separator })
        .edgeEffect(EdgeEffect.Spring)
        .linearGradientBlur(
          TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),
          {
            fractionStops: TitleScrollEffect.getBlurStops(this.listViewportHeight, this.statusBarHeight),
            direction: GradientDirection.Bottom
          }
        )
        .onAreaChange((_oldValue: Area, newValue: Area): void => {
          if (typeof newValue.height === 'number' && newValue.height > 0 &&
            newValue.height !== this.listViewportHeight) {
            this.listViewportHeight = newValue.height
          }
        })
        .onDidScroll((): void => {
          this.syncTitleScrollEffect()
        })
        .onAppear((): void => {
          this.syncTitleScrollEffect()
        })
      }
      .width('100%').height('100%')

      PanelNavBar({
        title: '去水规则',
        rightIcon: $r('app.media.icon_nav_add'),
        rightIconAccessibilityText: '新增规则',
        scrollEffectProgress: this.titleScrollEffectProgress,
        onRightClick: (): void => {
          this.openRuleDialog(null)
        }
      })
        .width('100%').position({ x: 0, y: 0 })
    }
    .width('100%').height('100%').backgroundColor(AppColors.bg)
  }
}
