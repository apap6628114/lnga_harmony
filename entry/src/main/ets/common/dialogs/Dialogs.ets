/**
 * 对话框内容构件集（配合官方高级对话框模板使用）。
 *
 * 迁移说明：本文件原先定义 7 个 `@CustomDialog` 自绘弹窗
 * （ConfirmDialog / ActionSheetDialog / CredentialPasswordDialog / MakeNoteDialog /
 * AddBlacklistDialog / AddKeywordDialog / AddNoteDialog），现按官方建议改为
 * 「官方高级对话框模板 + 自定义内容」：
 *
 * - 确认类 → `@ohos.arkui.advanced.Dialog` 的 `AlertDialog`（无图标）/ `TipsDialog`（带图标）。
 *   **不要用 `ConfirmDialog`**：它带 `checkTips` / `isChecked` 复选框字段，即使不传 `checkTips`
 *   也会渲染一个没有文字的孤立复选框（实测截图确认），语义上不合理。
 * - 选项列表 → `SelectDialog`（单选项 + 确认按钮）
 * - 输入类 → `CustomContentDialog`（官方模板中唯一支持自定义内容的），
 *   本文件只保留其内容构件，标题与按钮由官方模板统一渲染
 *
 * **参数一律用 `@Prop` + 回调，禁止用 `@Link`**（实测踩坑，勿改回）：
 * 官方 `contentBuilder` 是 `@BuilderParam`，传进去的 @Builder 是在**对话框组件内部**执行的，
 * 调用方的 `$变量` 语法在那一层解析不到源状态，打开对话框时会抛
 * `SyntaxError: undefined 'xxx': constructor: source variable in parent/ancestor @Component
 * must be defined` 并直接崩溃。改为「父组件 @State --@Prop 单向传入--> 子组件」+
 * 「子组件回调 --> 父组件写回」后不再有跨层绑定。
 *
 * **调用方传 `contentBuilder` 必须用箭头函数包装**（`contentBuilder: (): void => { this.xxxContent() }`），
 * **禁止**写成 `contentBuilder: this.xxxContent`（实测踩坑，勿改回）：@BuilderParam 以「方法引用」
 * 方式赋值时，@Builder 内部的 `this` 指向**对话框组件实例**而不是调用方页面
 * （官方文档《@BuilderParam装饰器：引用@Builder函数》「改变内容UI不刷新」一节）。
 * 症状是静默的：弹窗能打开、输入框能打字，但内容构件读到的父状态全是 undefined，
 * 回调写回也落在对话框实例上，父组件状态永远是初值——表现为「输入了 8 位密码仍提示
 * 密码至少 8 位」「编辑备注时原有内容为空」。
 */
import { AppColors } from '../constants/Constants'
import { UIMaterialManager } from '../managers/UIMaterialManager'
import { normalizeBlacklistUserId } from '../utils/BlacklistUtils'

/**
 * 单选条目。
 *
 * 供调用方构造选项表并映射为官方 `SelectDialog` 的 `radioContent`（`SheetInfo[]`）：
 * 保留此结构可以让「选项生成」与「选中值 → 下标」的换算留在调用方，
 * 与迁移前的 ActionSheetDialog 用法保持一致。
 */
export interface ActionOption {
  /** 选项显示文案。 */
  label: string
  /** 选项取值。 */
  value: number
}

/**
 * 官方 `SelectDialog` 的单选内容与初始选中下标。
 *
 * `items` 的形状即官方 `SheetInfo[]`（`title` + `action`），
 * 单独包一个类是因为 ArkTS 不支持返回多个值的元组解构。
 */
export class SelectRadioResult {
  /** 单选列表内容。 */
  items: SheetInfo[] = []
  /** 初始选中下标。 */
  selectedIndex: number = 0
}

/**
 * 备注编辑内容（1~20 字）。
 *
 * 对应原 MakeNoteDialog 的输入区；标题与按钮交给 `CustomContentDialog`。
 */
@Component
export struct NoteEditorContent {
  /** 备注文本（父组件 @State 单向传入）。 */
  @Prop noteText: string = ''
  /** 目标用户名（作为副标题展示）。 */
  @Prop userName: string = ''
  /** 文本变化回调（回写父组件状态）。 */
  onNoteChange?: (value: string) => void

  build() {
    Column() {
      if (this.userName.length > 0) {
        Text(this.userName)
          .fontSize(13).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
          .margin({ bottom: 8 })
          .alignSelf(ItemAlign.Center)
      }

      TextInput({ text: this.noteText, placeholder: '输入备注内容(1-20字)' })
        .width('100%').height(44).fontSize(15).borderRadius(12)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .attributeModifier(UIMaterialManager.dialogFieldMaterial)
        .onChange((value: string) => {
          if (this.onNoteChange) {
            this.onNoteChange(value)
          }
        })

      Text(String(this.noteText.length) + '/20')
        .fontSize(11).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
        .margin({ top: 6 })
        .alignSelf(ItemAlign.End)
    }
    .width('100%')
  }
}

/**
 * 关键词输入内容。
 *
 * 对应原 AddKeywordDialog 的输入区。
 */
@Component
export struct KeywordEditorContent {
  /** 关键词文本（父组件 @State 单向传入）。 */
  @Prop keyword: string = ''
  /** 文本变化回调（回写父组件状态）。 */
  onKeywordChange?: (value: string) => void

  build() {
    Column() {
      TextInput({ text: this.keyword, placeholder: '输入关键词' })
        .width('100%').height(44).fontSize(15).borderRadius(12)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .attributeModifier(UIMaterialManager.dialogFieldMaterial)
        .onChange((value: string) => {
          if (this.onKeywordChange) {
            this.onKeywordChange(value)
          }
        })
    }
    .width('100%')
  }
}

/**
 * 黑名单 UID 输入内容（含实时校验提示）。
 *
 * 对应原 AddBlacklistDialog 的输入与校验区；校验规则与迁移前一致。
 */
@Component
export struct BlacklistEditorContent {
  /** 输入的 UID（父组件 @State 单向传入）。 */
  @Prop uid: string = ''
  /** 当前登录用户 UID（用于「不能加自己」校验）。 */
  @Prop currentUserId: string = ''
  /** 已存在的黑名单 UID（用于重复校验）。 */
  @Prop existingUserIds: string[] = []
  /** 文本变化回调（回写父组件状态）。 */
  onUidChange?: (value: string) => void

  /**
   * 获取当前 UID 输入的校验错误。
   *
   * @returns 校验错误；输入合法时返回空字符串
   */
  private getValidationError(): string {
    if (this.uid.trim().length === 0) {
      return ''
    }
    const normalizedUserId: string | null = normalizeBlacklistUserId(this.uid)
    if (normalizedUserId === null) {
      return 'UID 必须是大于 0 的整数'
    }
    if (normalizedUserId === normalizeBlacklistUserId(this.currentUserId)) {
      return '不能将自己加入黑名单'
    }
    if (this.existingUserIds.indexOf(normalizedUserId) >= 0) {
      return '该用户已在黑名单中'
    }
    return ''
  }

  build() {
    Column() {
      Text('输入用户 UID')
        .fontSize(13).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
        .margin({ bottom: 8 })
        .alignSelf(ItemAlign.Center)

      TextInput({ text: this.uid, placeholder: '输入 UID' })
        .width('100%').height(44).fontSize(15).borderRadius(12)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .attributeModifier(UIMaterialManager.dialogFieldMaterial)
        .onChange((value: string) => {
          if (this.onUidChange) {
            this.onUidChange(value)
          }
        })

      if (this.getValidationError().length > 0) {
        Text(this.getValidationError())
          .fontSize(12)
          .fontColor(AppColors.destructive)
          .margin({ top: 6 })
          .alignSelf(ItemAlign.Start)
      }
    }
    .width('100%')
  }
}

/**
 * 新增备注内容（用户昵称 + UID）。
 *
 * 对应原 AddNoteDialog 的双输入区。
 */
@Component
export struct NoteAddContent {
  /** 用户昵称（父组件 @State 单向传入）。 */
  @Prop nickName: string = ''
  /** 用户 UID（父组件 @State 单向传入）。 */
  @Prop uid: string = ''
  /** 昵称变化回调（回写父组件状态）。 */
  onNickNameChange?: (value: string) => void
  /** UID 变化回调（回写父组件状态）。 */
  onUidChange?: (value: string) => void

  build() {
    Column() {
      Text('输入用户昵称和 UID')
        .fontSize(13).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
        .margin({ bottom: 8 })
        .alignSelf(ItemAlign.Center)

      TextInput({ text: this.nickName, placeholder: '输入用户昵称' })
        .width('100%').height(44).fontSize(15).borderRadius(12)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .attributeModifier(UIMaterialManager.dialogFieldMaterial)
        .onChange((value: string) => {
          if (this.onNickNameChange) {
            this.onNickNameChange(value)
          }
        })

      TextInput({ text: this.uid, placeholder: '输入用户 UID' })
        .width('100%').height(44).fontSize(15).borderRadius(12)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .attributeModifier(UIMaterialManager.dialogFieldMaterial)
        .margin({ top: 8 })
        .onChange((value: string) => {
          if (this.onUidChange) {
            this.onUidChange(value)
          }
        })
    }
    .width('100%')
  }
}

/**
 * 加密密码输入内容（导出 / 导入凭证口令）。
 *
 * 对应原 CredentialPasswordDialog 的「输入区 + 按钮行」。**按钮必须自绘在内容区**：
 * 官方 `CustomContentDialog` 的 `buttons` 是普通可选参数（`ButtonOptions` 只有
 * value / action / background / fontColor / buttonStyle / role / defaultFocus / textAlign，
 * 没有 enabled 之类的状态字段），且只在 `open()` 时求值一次——弹窗打开后不随输入刷新，
 * 因此官方按钮区做不出「未达位数 → 未激活」的即时反馈。`contentBuilder` 是 @BuilderParam，
 * 其内容在调用方的响应式依赖里，能随父状态实时刷新，所以按钮放这里。
 */
@Component
export struct CredentialPasswordContent {
  /** 密码文本（父组件 @State 单向传入）。 */
  @Prop password: string = ''
  /** 最少位数。 */
  @Prop minLength: number = 8
  /** 主按钮文案。 */
  @Prop confirmLabel: string = '确定'
  /** 文本变化回调（回写父组件状态）。 */
  onPasswordChange?: (value: string) => void
  /** 主按钮回调（密码达到最少位数时才触发，调用方负责关闭对话框）。 */
  onConfirm?: (password: string) => void
  /** 取消回调（调用方负责关闭对话框）。 */
  onCancel?: () => void

  /** 密码是否达到最少位数——决定主按钮的激活 / 未激活外观。 */
  private isActive(): boolean {
    return this.password.trim().length >= this.minLength
  }

  build() {
    Column() {
      TextInput({ text: this.password, placeholder: '输入加密密码' })
        .width('100%').height(44).fontSize(15)
        .type(InputType.Password)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .borderRadius(12)
        .attributeModifier(UIMaterialManager.dialogFieldMaterial)
        .onChange((value: string) => {
          if (this.onPasswordChange) {
            this.onPasswordChange(value)
          }
        })

      Text('至少 ' + String(this.minLength) + ' 位，请妥善保存')
        .fontSize(11).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
        .margin({ top: 6 })
        .alignSelf(ItemAlign.Start)

      Divider().color(AppColors.separator).margin({ top: 12 })

      Row() {
        Button('取消')
          .layoutWeight(1).height(44).fontSize(16)
          .backgroundColor(Color.Transparent)
          .fontColor(AppColors.primary)
          .onClick(() => {
            if (this.onCancel) {
              this.onCancel()
            }
          })

        // 主按钮走实底主题色（材质契约 §12.5）；未达位数时降到 45% 亮度表达未激活。
        Button(this.confirmLabel)
          .layoutWeight(1).height(44).fontSize(16)
          .margin({ left: 12 })
          .backgroundColor(AppColors.primary)
          .fontColor(AppColors.white)
          .fontWeight(FontWeight.Bold)
          .opacity(this.isActive() ? 1 : 0.45)
          .onClick(() => {
            if (!this.isActive()) {
              return
            }
            if (this.onConfirm) {
              this.onConfirm(this.password)
            }
          })
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
  }
}
