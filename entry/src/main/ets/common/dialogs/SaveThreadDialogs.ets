/**
 * 保存帖子对话框内容构件：选择保存的页范围（1~x 页）。
 *
 * 迁移说明：原先这里是 `@CustomDialog` 的 `SaveThreadDialog`（自绘标题、按钮与玻璃面板），
 * 现改为官方 `CustomContentDialog` 的自定义内容构件——标题与按钮由官方模板渲染，
 * 本组件只负责「拉取帖子信息 + 页范围输入与校验」。
 *
 * 与调用方的契约：模型在 `aboutToAppear` 时先拉取第一页确认帖子有效性并取得总页数，
 * 帖子无效（被删除/过期）或拉取失败时显示错误并禁止保存；页范围的合法性、起始页与结束页
 * 经 `onRangeChange` 回调回写调用方，调用方在官方模板的确认按钮回调里读取。
 *
 * **参数用 `@Prop` + 回调，禁止用 `@Link`**：官方 `contentBuilder` 是 `@BuilderParam`，
 * 传进去的 @Builder 在**对话框组件内部**执行，调用方的 `$变量` 在那一层解析不到源状态，
 * 打开对话框时会抛 `source variable in parent/ancestor @Component must be defined` 并崩溃（实测）。
 *
 * 确认后由调用方启动 `SavedThreadService` 后台保存（进度由全局指示组件展示）。
 */

import { getThread } from '../../service/api/ThreadApi'
import { appStore } from '../../store/AppStore'
import { AppColors } from '../constants/Constants'
import { UIMaterialManager } from '../managers/UIMaterialManager'

@Component
export struct SaveThreadContent {
  /** NGA 主题 ID。 */
  @Prop tid: string = ''
  /** 调用方提供的主题标题（加载失败时的兜底展示）。 */
  @Prop initialSubject: string = ''
  /**
   * 页范围变化回调（回写调用方）。
   *
   * @param canSave - 当前页范围是否可提交
   * @param startPage - 起始页；非法时为 -1
   * @param endPage - 结束页；非法时为 -1
   */
  onRangeChange?: (canSave: boolean, startPage: number, endPage: number) => void

  /** 是否正在拉取帖子信息。 */
  @State private loading: boolean = true
  /** 拉取失败原因（空串表示成功）。 */
  @State private loadError: string = ''
  /** 主题标题。 */
  @State private subject: string = ''
  /** 服务端总页数。 */
  @State private totalPages: number = 0
  /** 起始页输入。 */
  @State private startText: string = '1'
  /** 结束页输入。 */
  @State private endText: string = ''

  aboutToAppear(): void {
    this.fetchThreadInfo()
  }

  /**
   * 拉取第一页：确认帖子有效并获取总页数/标题。
   */
  private async fetchThreadInfo(): Promise<void> {
    this.loading = true
    this.loadError = ''
    this.syncOutput()
    try {
      const result = await getThread(appStore.auth.token, this.tid, '', '', '1')
      if (!result.ok || result.error.length > 0) {
        this.loadError = result.error || '无法加载该帖子'
      } else if (result.posts.length === 0) {
        this.loadError = '帖子不存在或已被删除'
      } else {
        if (result.threadInfo && result.threadInfo.subject.length > 0) {
          this.subject = result.threadInfo.subject
        } else {
          this.subject = result.posts[0].subject || this.initialSubject
        }
        this.totalPages = Math.max(1, result.pagination.totalPages)
        this.endText = String(this.totalPages)
      }
    } catch (e) {
      this.loadError = '无法加载该帖子'
    } finally {
      this.loading = false
      this.syncOutput()
    }
  }

  /**
   * 解析起始页输入。
   *
   * @returns 合法页码；非法时为 -1
   */
  private parseStart(): number {
    const raw: string = this.startText.trim()
    const n: number = Number(raw)
    if (raw.length === 0 || isNaN(n) || n < 1) {
      return -1
    }
    return Math.floor(n)
  }

  /**
   * 解析结束页输入。
   *
   * @returns 合法页码；非法时为 -1
   */
  private parseEnd(): number {
    const raw: string = this.endText.trim()
    const n: number = Number(raw)
    if (raw.length === 0 || isNaN(n) || n < 1) {
      return -1
    }
    return Math.floor(n)
  }

  /**
   * 重算页范围并把结果回写给调用方。
   *
   * 官方对话框模板的按钮不支持动态 disabled，因此「能否保存」由调用方在
   * 确认回调里读取回写值判定，而不是靠按钮灰化表达。
   */
  private syncOutput(): void {
    const start: number = this.parseStart()
    const end: number = this.parseEnd()
    const rangeValid: boolean = start >= 1 && end >= start && end <= this.totalPages
    const canSave: boolean = !this.loading && this.loadError.length === 0 &&
      this.totalPages > 0 && rangeValid
    if (this.onRangeChange) {
      this.onRangeChange(canSave, rangeValid ? start : -1, rangeValid ? end : -1)
    }
  }

  /**
   * 当前选择的保存页数；起始/结束页输入非法或结束页超出总页数时返回 0。
   *
   * @returns 页数
   */
  private pageCount(): number {
    const start: number = this.parseStart()
    const end: number = this.parseEnd()
    if (start < 1 || end < start || end > this.totalPages) {
      return 0
    }
    return end - start + 1
  }

  build() {
    Column() {
      if (this.loading) {
        Row({ space: 10 }) {
          LoadingProgress().width(22).height(22).color(AppColors.primary)
          Text('正在确认帖子信息…').fontSize(13).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
        }
        .margin({ top: 8, bottom: 12 })
      } else if (this.loadError.length > 0) {
        Text(this.loadError)
          .fontSize(13).fontColor(AppColors.destructive)
          .alignSelf(ItemAlign.Start)
        Text('该帖子可能已被删除或已过期，无法保存。')
          .fontSize(12).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
          .margin({ top: 4 })
          .alignSelf(ItemAlign.Start)
      } else {
        Text(this.subject)
          .fontSize(14).fontColor(UIMaterialManager.adaptiveForeground).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .alignSelf(ItemAlign.Start)

        Text('共 ' + String(this.totalPages) + ' 页，请选择要保存的页范围')
          .fontSize(12).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
          .margin({ top: 2, bottom: 14 })
          .alignSelf(ItemAlign.Start)

        Row({ space: 10 }) {
          Column() {
            Text('起始页').fontSize(12).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
              .margin({ bottom: 6 }).alignSelf(ItemAlign.Start)
            TextInput({ text: this.startText, placeholder: '1' })
              .type(InputType.Number).height(40).fontSize(15).borderRadius(10)
              .width('100%')
              .fontColor(UIMaterialManager.inputForeground)
              .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
              .caretColor(UIMaterialManager.inputForeground)
              .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
              .attributeModifier(UIMaterialManager.inputMaterial)
              .onChange((value: string) => {
                this.startText = value
                this.syncOutput()
              })
          }
          .layoutWeight(1)

          Column() {
            Text('结束页').fontSize(12).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
              .margin({ bottom: 6 }).alignSelf(ItemAlign.Start)
            TextInput({ text: this.endText, placeholder: String(this.totalPages) })
              .type(InputType.Number).height(40).fontSize(15).borderRadius(10)
              .width('100%')
              .fontColor(UIMaterialManager.inputForeground)
              .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
              .caretColor(UIMaterialManager.inputForeground)
              .keyboardAppearance(KeyboardAppearance.IMMERSIVE)
              .attributeModifier(UIMaterialManager.inputMaterial)
              .onChange((value: string) => {
                this.endText = value
                this.syncOutput()
              })
          }
          .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        if (this.totalPages > 1) {
          Text('将保存 ' + String(this.pageCount()) + ' 页内容')
            .fontSize(12).fontColor(AppColors.warning)
            .margin({ top: 8 })
            .alignSelf(ItemAlign.Start)
          if (this.pageCount() > 50) {
            Text('页数较多，预计耗时较长，保存中可随时取消')
              .fontSize(12).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
              .margin({ top: 4 })
              .alignSelf(ItemAlign.Start)
          }
        }
      }
    }
    .width('100%')
  }
}
