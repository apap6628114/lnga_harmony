/**
 * 确认对话框 + ActionSheet 组件 + 备注编辑对话框
 */
import { AppColors } from '../constants/Constants'
import { normalizeBlacklistUserId } from '../utils/BlacklistUtils'

// 确认对话框
@CustomDialog
export struct ConfirmDialog {
  controller: CustomDialogController
  @Prop title: string = ''
  @Prop message: string = ''
  @Prop confirmLabel: string = '确定'
  @Prop destructive: boolean = false
  onConfirm?: () => void
  onCancel?: () => void
  icon?: Resource

  build() {
    Column() {
      if (this.icon !== undefined) {
        Image(this.icon).width(36).height(36).fillColor(AppColors.destructive)
          .margin({ top: 24, bottom: 12 })
      }

      Text(this.title)
        .fontSize(17)
        .fontColor(AppColors.textPrimary)
        .fontWeight(FontWeight.Bold)
        .margin({ top: this.icon !== undefined ? 0 : 20, bottom: 8 })

      Text(this.message)
        .fontSize(14)
        .fontColor(AppColors.textSecondary)
        .margin({ bottom: 20 })
        .textAlign(TextAlign.Center)

      Divider().color(AppColors.separator)

      Row() {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .backgroundColor(Color.Transparent)
          .fontColor(AppColors.primary)
          .onClick(() => {
            this.controller.close()
            if (this.onCancel) this.onCancel()
          })

        Divider().vertical(true).height(24).color(AppColors.separator)

        Button(this.confirmLabel)
          .layoutWeight(1)
          .height(44)
          .backgroundColor(this.destructive ? AppColors.destructive : Color.Transparent)
          .fontColor(this.destructive ? AppColors.white : AppColors.primary)
          .fontWeight(FontWeight.Bold)
          .onClick(() => {
            this.controller.close()
            if (this.onConfirm) this.onConfirm()
          })
      }
    }
    .constraintSize({ maxWidth: 340, minWidth: 260 })
    .padding({ left: 20, right: 20 })
      .backgroundColor(AppColors.bgTertiary)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Center)
  }
}

// ActionSheet 选项接口
export interface ActionOption {
  label: string
  value: number
}

// ActionSheet
@CustomDialog
export struct ActionSheetDialog {
  controller: CustomDialogController
  @Prop title: string = ''
  options: ActionOption[] = []
  selected: number = 0
  onSelect?: (value: number) => void
  onCancel?: () => void
  getLabelFontSize?: (value: number) => number

  build() {
    Column() {
      // 拖拽指示条
      Divider()
        .width(36)
        .height(4)
        .borderRadius(2)
        .color(AppColors.sheetIndicator)
        .margin({ top: 8, bottom: 12 })

      Text(this.title)
        .fontSize(15)
        .fontColor(AppColors.textSecondary)
        .margin({ bottom: 4 })

      // 选项列表
      List() {
        ForEach(this.options, (opt: ActionOption) => {
          ListItem() {
            Row() {
              Text(opt.label)
                .fontSize(this.getLabelFontSize ? this.getLabelFontSize(opt.value) : 17)
                .fontColor(AppColors.textPrimary)
                .fontWeight(opt.value === this.selected ? FontWeight.Medium : FontWeight.Regular)
                .layoutWeight(1)

              if (opt.value === this.selected) {
                Image($r('app.media.icon_checkmark'))
                  .width(18).height(18).fillColor(AppColors.primary)
              }
            }
            .width('100%')
            .height(52)
            .padding({ left: 20, right: 20 })
            .backgroundColor(opt.value === this.selected ? AppColors.primaryLight : Color.Transparent)
            .onClick(() => {
              this.controller.close()
              if (this.onSelect) this.onSelect(opt.value)
            })
          }
        })
      }
      .width('100%')
      .divider({ strokeWidth: 0.5, color: AppColors.separator })

      // 取消按钮
      Divider().color(AppColors.separator).margin({ top: 8 })
      Button('取消')
        .width('100%')
        .height(50)
        .backgroundColor(Color.Transparent)
        .fontColor(AppColors.primary)
        .fontWeight(FontWeight.Bold)
        .onClick(() => {
          this.controller.close()
          if (this.onCancel) this.onCancel()
        })
    }
    .width('100%').constraintSize({ maxWidth: 420 })
      .backgroundColor(AppColors.bgTertiary)
    .borderRadius({ topLeft: 16, topRight: 16 })
    .padding({ bottom: 20 })
  }
}

// 备注编辑对话框
@CustomDialog
export struct CredentialPasswordDialog {
  controller: CustomDialogController
  @Prop title: string = ''
  @Prop message: string = ''
  @Prop confirmLabel: string = '确定'
  @Prop minLength: number = 8
  @State password: string = ''
  onConfirm?: (password: string) => void
  onCancel?: () => void

  build() {
    Column() {
      Text(this.title)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.textPrimary)
        .margin({ top: 20, bottom: 8 })
        .alignSelf(ItemAlign.Center)

      Text(this.message)
        .fontSize(13)
        .fontColor(AppColors.textSecondary)
        .textAlign(TextAlign.Center)
        .margin({ bottom: 12 })

      TextInput({ text: this.password, placeholder: '输入加密密码' })
        .type(InputType.Password)
        .height(44)
        .fontSize(15)
        .borderRadius(12)
        .backgroundColor(AppColors.bgSecondary)
        .onChange((value: string) => { this.password = value })

      Text('至少 ' + this.minLength + ' 位，请妥善保存')
        .fontSize(11)
        .fontColor(AppColors.textTertiary)
        .margin({ top: 6 })
        .alignSelf(ItemAlign.Start)

      Divider().color(AppColors.separator).margin({ top: 12 })

      Row() {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .backgroundColor(Color.Transparent)
          .fontColor(AppColors.primary)
          .fontSize(16)
          .onClick(() => {
            this.controller.close()
            if (this.onCancel) this.onCancel()
          })

        Divider().vertical(true).height(24).color(AppColors.separator)

        Button(this.confirmLabel)
          .layoutWeight(1)
          .height(44)
          .backgroundColor(Color.Transparent)
          .fontColor(this.password.trim().length >= this.minLength ? AppColors.primary : AppColors.textTertiary)
          .fontWeight(FontWeight.Bold)
          .fontSize(16)
          .onClick(() => {
            if (this.password.trim().length >= this.minLength) {
              const password = this.password
              this.controller.close()
              if (this.onConfirm) this.onConfirm(password)
            }
          })
      }
    }
    .constraintSize({ maxWidth: 340 })
    .padding({ left: 20, right: 20, bottom: 12 })
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(14)
  }
}

@CustomDialog
export struct MakeNoteDialog {
  controller: CustomDialogController
  @Prop userName: string = ''
  @Prop uid: string = ''
  @Prop currentNote: string = ''
  @State noteText: string = ''
  onConfirm?: (note: string, uid: string, userName: string) => void

  aboutToAppear(): void {
    this.noteText = this.currentNote
  }

  build() {
    Column() {
      Text('编辑备注')
        .fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppColors.textPrimary)
        .margin({ top: 20, bottom: 4 })
        .alignSelf(ItemAlign.Center)

      Text(this.userName)
        .fontSize(13).fontColor(AppColors.textSecondary)
        .margin({ bottom: 12 })
        .alignSelf(ItemAlign.Center)

      TextInput({ text: this.noteText, placeholder: '输入备注内容(1-20字)' })
        .height(44).fontSize(15).borderRadius(12)
        .backgroundColor(AppColors.bgSecondary)
        .onChange((value: string) => { this.noteText = value })

      Text(String(this.noteText.length) + '/20')
        .fontSize(11).fontColor(AppColors.textTertiary)
        .margin({ top: 4 })
        .alignSelf(ItemAlign.End)

      Divider().color(AppColors.separator).margin({ top: 12 })

      Row() {
        Button('取消')
          .layoutWeight(1).height(44).backgroundColor(Color.Transparent)
          .fontColor(AppColors.primary).fontSize(16)
          .onClick(() => { this.controller.close() })

        Divider().vertical(true).height(24).color(AppColors.separator)

        Button('确认')
          .layoutWeight(1).height(44).backgroundColor(Color.Transparent)
          .fontColor(this.noteText.length >= 1 && this.noteText.length <= 20 ? AppColors.primary : AppColors.textTertiary)
          .fontWeight(FontWeight.Bold).fontSize(16)
          .onClick(() => {
            if (this.noteText.length >= 1 && this.noteText.length <= 20) {
              if (this.onConfirm) this.onConfirm(this.noteText, this.uid, this.userName)
              this.controller.close()
            }
          })
      }
    }
    .constraintSize({ maxWidth: 340 })
    .padding({ left: 20, right: 20, bottom: 12 })
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(14)
  }
}

// 添加黑名单对话框
@CustomDialog
export struct AddBlacklistDialog {
  controller: CustomDialogController
  /** 当前输入的 UID。 */
  @State uid: string = ''
  /** 当前输入校验错误。 */
  @State validationError: string = ''
  /** 当前登录用户 UID。 */
  @Prop currentUserId: string = ''
  /** 已存在的黑名单 UID。 */
  @Prop existingUserIds: string[] = []
  /** UID 校验通过后的确认回调。 */
  onConfirm?: (uid: string) => void

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

  /**
   * 判断当前输入是否可以提交。
   *
   * @returns 是否可以提交
   */
  private canSubmit(): boolean {
    return this.uid.trim().length > 0 && this.getValidationError().length === 0
  }

  build() {
    Column() {
      Text('添加黑名单')
        .fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppColors.textPrimary)
        .margin({ top: 20, bottom: 4 })
        .alignSelf(ItemAlign.Center)

      Text('输入用户 UID')
        .fontSize(13).fontColor(AppColors.textSecondary)
        .margin({ bottom: 12 })
        .alignSelf(ItemAlign.Center)

      TextInput({ text: this.uid, placeholder: '输入 UID' })
        .height(44).fontSize(15).borderRadius(12)
        .backgroundColor(AppColors.bgSecondary)
        .onChange((value: string) => {
          this.uid = value
          this.validationError = ''
        })

      if (this.validationError.length > 0) {
        Text(this.validationError)
          .fontSize(12)
          .fontColor(AppColors.destructive)
          .margin({ top: 6 })
          .alignSelf(ItemAlign.Start)
      }

      Divider().color(AppColors.separator).margin({ top: 12 })

      Row() {
        Button('取消')
          .layoutWeight(1).height(44).backgroundColor(Color.Transparent)
          .fontColor(AppColors.primary).fontSize(16)
          .onClick(() => { this.controller.close() })

        Divider().vertical(true).height(24).color(AppColors.separator)

        Button('确定添加')
          .layoutWeight(1).height(44).backgroundColor(Color.Transparent)
          .fontColor(this.canSubmit() ? AppColors.primary : AppColors.textTertiary)
          .fontWeight(FontWeight.Bold).fontSize(16)
          .onClick(() => {
            const validationError: string = this.getValidationError()
            if (validationError.length > 0 || this.uid.trim().length === 0) {
              this.validationError = validationError || '请输入用户 UID'
              return
            }
            const normalizedUserId: string | null = normalizeBlacklistUserId(this.uid)
            if (normalizedUserId !== null) {
              if (this.onConfirm) this.onConfirm(normalizedUserId)
              this.controller.close()
            }
          })
      }
    }
    .constraintSize({ maxWidth: 340 })
    .padding({ left: 20, right: 20, bottom: 12 })
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(14)
  }
}

// 添加关键词对话框
@CustomDialog
export struct AddKeywordDialog {
  controller: CustomDialogController
  @State keyword: string = ''
  onConfirm?: (keyword: string) => void

  build() {
    Column() {
      Text('添加关键词')
        .fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppColors.textPrimary)
        .margin({ top: 20, bottom: 4 })
        .alignSelf(ItemAlign.Center)

      Text('输入需要屏蔽的关键词')
        .fontSize(13).fontColor(AppColors.textSecondary)
        .margin({ bottom: 12 })
        .alignSelf(ItemAlign.Center)

      TextInput({ text: this.keyword, placeholder: '输入关键词' })
        .height(44).fontSize(15).borderRadius(12)
        .backgroundColor(AppColors.bgSecondary)
        .onChange((value: string) => { this.keyword = value })

      Divider().color(AppColors.separator).margin({ top: 12 })

      Row() {
        Button('取消')
          .layoutWeight(1).height(44).backgroundColor(Color.Transparent)
          .fontColor(AppColors.primary).fontSize(16)
          .onClick(() => { this.controller.close() })

        Divider().vertical(true).height(24).color(AppColors.separator)

        Button('确定添加')
          .layoutWeight(1).height(44).backgroundColor(Color.Transparent)
          .fontColor(this.keyword.trim().length > 0 ? AppColors.primary : AppColors.textTertiary)
          .fontWeight(FontWeight.Bold).fontSize(16)
          .onClick(() => {
            if (this.keyword.trim()) {
              if (this.onConfirm) this.onConfirm(this.keyword.trim())
              this.controller.close()
            }
          })
      }
    }
    .constraintSize({ maxWidth: 340 })
    .padding({ left: 20, right: 20, bottom: 12 })
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(14)
  }
}

// 添加备注对话框
@CustomDialog
export struct AddNoteDialog {
  controller: CustomDialogController
  @State nickName: string = ''
  @State uid: string = ''
  onConfirm?: (nickName: string, uid: string) => void

  build() {
    Column() {
      Text('添加备注')
        .fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppColors.textPrimary)
        .margin({ top: 20, bottom: 4 })
        .alignSelf(ItemAlign.Center)

      Text('输入用户昵称和 UID')
        .fontSize(13).fontColor(AppColors.textSecondary)
        .margin({ bottom: 12 })
        .alignSelf(ItemAlign.Center)

      TextInput({ text: this.nickName, placeholder: '输入用户昵称' })
        .height(44).fontSize(15).borderRadius(12)
        .backgroundColor(AppColors.bgSecondary)
        .onChange((value: string) => { this.nickName = value })

      TextInput({ text: this.uid, placeholder: '输入用户 UID' })
        .height(44).fontSize(15).borderRadius(12)
        .backgroundColor(AppColors.bgSecondary)
        .margin({ top: 8 })
        .onChange((value: string) => { this.uid = value })

      Divider().color(AppColors.separator).margin({ top: 12 })

      Row() {
        Button('取消')
          .layoutWeight(1).height(44).backgroundColor(Color.Transparent)
          .fontColor(AppColors.primary).fontSize(16)
          .onClick(() => { this.controller.close() })

        Divider().vertical(true).height(24).color(AppColors.separator)

        Button('确定添加')
          .layoutWeight(1).height(44).backgroundColor(Color.Transparent)
          .fontColor(this.uid.trim().length > 0 && this.nickName.trim().length > 0 ? AppColors.primary : AppColors.textTertiary)
          .fontWeight(FontWeight.Bold).fontSize(16)
          .onClick(() => {
            if (this.uid.trim() && this.nickName.trim()) {
              if (this.onConfirm) this.onConfirm(this.nickName.trim(), this.uid.trim())
              this.controller.close()
            }
          })
      }
    }
    .constraintSize({ maxWidth: 340 })
    .padding({ left: 20, right: 20, bottom: 12 })
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(14)
  }
}


