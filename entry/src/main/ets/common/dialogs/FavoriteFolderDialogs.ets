import { AppColors } from '../constants/Constants'

/**
 * 收藏夹名称编辑对话框。
 */
@CustomDialog
export struct FavoriteFolderNameDialog {
  /**
   * 自定义对话框控制器。
   */
  controller: CustomDialogController
  /**
   * 对话框标题。
   */
  @Prop title: string = '新建收藏夹'
  /**
   * 初始收藏夹名称。
   */
  @Prop initialName: string = ''
  /**
   * 确认按钮文字。
   */
  @Prop confirmLabel: string = '完成'
  /**
   * 当前输入名称。
   */
  @State name: string = ''
  /**
   * 名称确认回调。
   */
  onConfirm?: (name: string) => void

  /**
   * 将传入名称同步到输入框。
   */
  aboutToAppear(): void {
    this.name = this.initialName
  }

  /**
   * 构建收藏夹名称编辑对话框。
   */
  build() {
    Column() {
      Text(this.title)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.textPrimary)
        .margin({ top: 20, bottom: 12 })
        .alignSelf(ItemAlign.Center)

      TextInput({ text: this.name, placeholder: '输入收藏夹名称' })
        .height(44)
        .fontSize(15)
        .borderRadius(12)
        .backgroundColor(AppColors.bgSecondary)
        .onChange((value: string): void => {
          this.name = value
        })

      Divider().color(AppColors.separator).margin({ top: 12 })

      Row() {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .backgroundColor(Color.Transparent)
          .fontColor(AppColors.primary)
          .fontSize(16)
          .onClick((): void => {
            this.controller.close()
          })

        Divider().vertical(true).height(24).color(AppColors.separator)

        Button(this.confirmLabel)
          .layoutWeight(1)
          .height(44)
          .backgroundColor(Color.Transparent)
          .fontColor(this.name.trim().length > 0 ? AppColors.primary : AppColors.textTertiary)
          .fontWeight(FontWeight.Bold)
          .fontSize(16)
          .onClick((): void => {
            const normalizedName: string = this.name.trim()
            if (normalizedName.length === 0) {
              return
            }
            this.onConfirm?.(normalizedName)
            this.controller.close()
          })
      }
    }
    .constraintSize({ maxWidth: 340, minWidth: 280 })
    .padding({ left: 20, right: 20, bottom: 12 })
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(14)
  }
}
