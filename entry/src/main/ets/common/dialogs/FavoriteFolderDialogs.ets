/**
 * 收藏夹名称编辑对话框的内容构件。
 *
 * 迁移说明：原先这里是 `@CustomDialog` 的 `FavoriteFolderNameDialog`（自绘标题、按钮与玻璃面板），
 * 现改为官方 `CustomContentDialog` 的自定义内容构件——标题与按钮由官方模板渲染，
 * 本组件只保留名称输入。
 *
 * **参数用 `@Prop` + 回调，禁止用 `@Link`**：官方 `contentBuilder` 是 `@BuilderParam`，
 * 传进去的 @Builder 在**对话框组件内部**执行，调用方的 `$变量` 在那一层解析不到源状态，
 * 打开对话框时会抛 `source variable in parent/ancestor @Component must be defined` 并崩溃（实测）。
 */
import { UIMaterialManager } from '../managers/UIMaterialManager'

@Component
export struct FolderNameEditorContent {
  /** 当前名称（父组件 @State 单向传入）。 */
  @Prop name: string = ''
  /** 名称变化回调（回写父组件状态）。 */
  onNameChange?: (value: string) => void

  build() {
    Column() {
      TextInput({ text: this.name, placeholder: '输入收藏夹名称' })
        .width('100%')
        .height(44)
        .fontSize(15)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .borderRadius(12)
        .attributeModifier(UIMaterialManager.inputMaterial)
        .onChange((value: string): void => {
          if (this.onNameChange) {
            this.onNameChange(value)
          }
        })
    }
    .width('100%')
  }
}
